[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $NetworkSwitchName = 'Default Switch',
    [ValidatePattern('^\d+\.\d+$')] [string] $DotNetChannel = '10.0',
    [string] $ExpectedDotNetSdkVersion,
    [hashtable] $ExpectedInstalledChannelVersions = @{},
    [string] $TargetUserSid,
    [string] $StatusPath,
    [ValidateSet('Automatic', 'Manual')] [string] $GuestRestartMode = 'Automatic',
    [string] $CancellationPath,
    [switch] $AdoptCurrentBaseline,
    [ValidatePattern('^\d{8}T\d{9}Z$')] [string] $ResumeUpdateId,
    [switch] $PreserveRecoveryPrevious,
    [switch] $SkipSmokeTest,
    [switch] $InvocationPreflightOnly
)

$ErrorActionPreference = 'Stop'
if ($InvocationPreflightOnly) {
    [pscustomobject][ordered]@{
        Success = $true
        NoMutationPerformed = $true
        BoundParameterNames = @($PSBoundParameters.Keys | Where-Object { $_ -ne 'InvocationPreflightOnly' } | Sort-Object)
        ResumeUpdateIdBound = $PSBoundParameters.ContainsKey('ResumeUpdateId')
        ResumeUpdateId = if ($PSBoundParameters.ContainsKey('ResumeUpdateId')) { [string]$ResumeUpdateId } else { $null }
        AdoptCurrentBaselineBound = $PSBoundParameters.ContainsKey('AdoptCurrentBaseline')
        PreserveRecoveryPreviousBound = $PSBoundParameters.ContainsKey('PreserveRecoveryPrevious')
        SkipSmokeTestBound = $PSBoundParameters.ContainsKey('SkipSmokeTest')
    }
    return
}
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'image-update-status.json' }
$definitionPath = Join-Path ([string]$layout.HarnessSourceRoot) 'pool-definition.json'
$credentialPath = Join-Path ([string]$layout.HarnessSourceRoot) 'private\guest-credential.json'
$brokerRoot = [string]$layout.BrokerRoot
$maintenancePath = Join-Path $brokerRoot 'State\maintenance.json'
$taskName = [string]$layout.BrokerTaskName
$startedUtc = [DateTime]::UtcNow
$resumeRetainedGeneration = -not [string]::IsNullOrWhiteSpace($ResumeUpdateId)
$updateId = if ($resumeRetainedGeneration) { $ResumeUpdateId } else { $startedUtc.ToString('yyyyMMddTHHmmssfffZ') }
$generationRoot = Join-Path $brokerRoot (Join-Path 'Pool\Generations' $updateId)
$archiveRoot = Join-Path ([string]$layout.InstallRoot) (Join-Path 'Archive\ImageUpdates' $updateId)
$oldDefinition = $null
$oldDefinitionRaw = $null
$oldDefinitionArchive = Join-Path $archiveRoot 'pool-definition.json'
$maintenanceCreated = $false
$taskWasRunning = $false
$checkpointPromoted = $false
$checkpointPromotionStarted = $false
$canonicalCheckpointId = $null
$candidateCheckpointId = $null
$candidateCheckpointName = ([string]$layout.BaselineCheckpointName) + $(if ($resumeRetainedGeneration) { '-failed-' } else { '-candidate-' }) + $updateId
$backupCheckpointName = ([string]$layout.BaselineCheckpointName) + '-backup-' + $updateId
$backupVmNames = @{}
$createdVmNames = New-Object Collections.Generic.List[string]
$touchedWorkerNames = New-Object Collections.Generic.List[string]
$registrationRepairs = New-Object Collections.Generic.List[object]
$candidateCheckpoint = $null
$newDefinitionWritten = $false
$resultDetails = [ordered]@{}

if ($AdoptCurrentBaseline -and $GuestRestartMode -ne 'Manual') {
    throw '-AdoptCurrentBaseline requires GuestRestartMode Manual.'
}
if ($resumeRetainedGeneration -and $AdoptCurrentBaseline) {
    throw '-ResumeUpdateId cannot be combined with -AdoptCurrentBaseline; the retained checkpoint is the approved baseline source.'
}
if ($resumeRetainedGeneration -and $GuestRestartMode -ne 'Manual') {
    throw '-ResumeUpdateId requires GuestRestartMode Manual so no baseline guest restart can be introduced during recovery.'
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Write-UpdateStatus {
    param(
        [Parameter(Mandatory = $true)] [string] $Phase,
        [Parameter(Mandatory = $true)] [string] $Message,
        [Nullable[bool]] $Success = $null,
        $Details = $null
    )

    Write-JsonAtomic -Path $StatusPath -Value ([ordered]@{
        Success = $Success
        Phase = $Phase
        Message = $Message
        StartedUtc = $startedUtc.ToString('o')
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        UpdateId = $updateId
        ConfigPath = $layout.ConfigPath
        Details = $Details
    })
}

function Assert-ImageUpdateNotCancelled {
    if (-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
        throw [OperationCanceledException]::new('Image maintenance was cancelled because the visible launcher exited.')
    }
}

function Assert-SafeGenerationPath {
    $resolved = [IO.Path]::GetFullPath($generationRoot)
    $parent = [IO.Path]::GetFullPath((Join-Path $brokerRoot 'Pool\Generations')).TrimEnd('\') + '\'
    if (-not ($resolved + '\').StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -ne $updateId) {
        throw "Refusing to use an unsafe pool generation path: $resolved"
    }
    $resolved
}

function Convert-PoolBase {
    param(
        [Parameter(Mandatory = $true)] [string] $SourceVmName,
        [Parameter(Mandatory = $true)] [string] $CheckpointName,
        [Parameter(Mandatory = $true)] [string] $DestinationPath
    )

    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    $retryCount = 0
    while ($true) {
        $checkpoint = Get-VMSnapshot -VMName $SourceVmName -Name $CheckpointName -ErrorAction Stop
        $drives = @(Get-VMHardDiskDrive -VMSnapshot $checkpoint -ErrorAction Stop | Where-Object { $_.Path })
        if ($drives.Count -ne 1) { throw "The candidate baseline must contain exactly one OS disk; found $($drives.Count)." }
        $sourcePath = [IO.Path]::GetFullPath([string]$drives[0].Path)
        try {
            Convert-VHD -Path $sourcePath -DestinationPath $DestinationPath -VHDType Dynamic -ErrorAction Stop
            return [pscustomobject][ordered]@{ SourcePath = $sourcePath; RetryCount = $retryCount }
        }
        catch {
            $exception = $_.Exception
            while ($exception.InnerException) { $exception = $exception.InnerException }
            $sharingViolation = (($exception.HResult -band 0xFFFF) -eq 32) -or $_.Exception.Message -match '0x80070020'
            if (-not $sharingViolation -or [DateTime]::UtcNow -ge $deadline) { throw }
            $retryCount++
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }
}

function New-PoolWorkerVm {
    param(
        [Parameter(Mandatory = $true)] [int] $WorkerId,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $OsChildPath,
        [Parameter(Mandatory = $true)] [string] $BaseVhdx,
        [Parameter(Mandatory = $true)] [string] $VmRoot,
        [Parameter(Mandatory = $true)] $SourceFirmware,
        $SourceSecurity,
        [switch] $UseExistingOsChild
    )

    if ($UseExistingOsChild) {
        if (-not (Test-Path -LiteralPath $OsChildPath -PathType Leaf)) {
            throw "Cannot restore $VmName because its existing OS child disk is missing: $OsChildPath"
        }
        $existingChild = Get-VHD -Path $OsChildPath -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$existingChild.ParentPath) -or
            -not [string]::Equals([IO.Path]::GetFullPath([string]$existingChild.ParentPath), [IO.Path]::GetFullPath($BaseVhdx), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Cannot restore $VmName because its OS child disk does not reference the expected pool base."
        }
    }
    else {
        if (Test-Path -LiteralPath $OsChildPath) {
            throw "Refusing to overwrite an existing worker OS child disk: $OsChildPath"
        }
        New-VHD -Path $OsChildPath -ParentPath $BaseVhdx -Differencing -ErrorAction Stop | Out-Null
    }
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ([long]$layout.VmMemoryBytes) -VHDPath $OsChildPath -Path $VmRoot -ErrorAction Stop | Out-Null
    Set-VMProcessor -VMName $VmName -Count ([int]$layout.VmProcessorCount) -ErrorAction Stop
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes ([long]$layout.VmMemoryBytes) -ErrorAction Stop
    Set-VMVideo -VMName $VmName -HorizontalResolution ([int]$layout.GuestDisplayWidth) -VerticalResolution ([int]$layout.GuestDisplayHeight) -ResolutionType Single -ErrorAction Stop
    Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -ErrorAction Stop
    Set-VMFirmware -VMName $VmName -EnableSecureBoot $SourceFirmware.SecureBoot -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
    if (@(Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue).Count -eq 0) {
        Add-VMNetworkAdapter -VMName $VmName -Name 'Network Adapter' | Out-Null
    }
    Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop | Disconnect-VMNetworkAdapter -ErrorAction SilentlyContinue
    if ($SourceSecurity -and $SourceSecurity.TpmEnabled -and (Get-Command Set-VMKeyProtector -ErrorAction SilentlyContinue) -and (Get-Command Enable-VMTPM -ErrorAction SilentlyContinue)) {
        Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector -ErrorAction Stop
        Enable-VMTPM -VMName $VmName -ErrorAction Stop
    }
    $bootDrive = Get-VMHardDiskDrive -VMName $VmName | Where-Object {
        $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), [IO.Path]::GetFullPath($OsChildPath), [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    Set-VMFirmware -VMName $VmName -FirstBootDevice $bootDrive -ErrorAction Stop
    [pscustomobject][ordered]@{
        WorkerId = $WorkerId
        VmName = $VmName
        OsChildPath = $OsChildPath
        OsControllerType = [string]$bootDrive.ControllerType
        OsControllerNumber = [int]$bootDrive.ControllerNumber
        OsControllerLocation = [int]$bootDrive.ControllerLocation
    }
}

function Get-VmDiskOwners {
    param([Parameter(Mandatory = $true)] [string] $DiskPath)

    $resolvedDisk = [IO.Path]::GetFullPath($DiskPath)
    $owners = New-Object Collections.Generic.List[object]
    foreach ($candidateVm in @(Get-VM -ErrorAction Stop)) {
        $matchingDrive = @(Get-VMHardDiskDrive -VM $candidateVm -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), $resolvedDisk, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($matchingDrive.Count -eq 1) {
            [void]$owners.Add([pscustomobject][ordered]@{ Name = [string]$candidateVm.Name; State = [string]$candidateVm.State })
        }
    }
    $owners.ToArray()
}

function New-GuestCredential {
    $credentialData = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    $securePassword = ConvertTo-SecureString ([string]$credentialData.Password) -AsPlainText -Force
    New-Object Management.Automation.PSCredential([string]$credentialData.UserName, $securePassword)
}

function Test-WorkerImage {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $true)] $ExpectedManifest
    )

    if (@(Get-VM | Where-Object { $_.State -eq 'Running' -and $_.Name -like ([string]$layout.PoolVmPrefix + '-*') }).Count -gt 0) {
        throw 'Another pool worker is already running; sequential verification would be violated.'
    }
    Start-VM -Name $VmName | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes(8)
    $session = $null
    $inventory = $null
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $session = New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
                $inventory = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                    $manifestPath = 'C:\CodexGuest\image-manifest.json'
                    $agentStatePath = 'C:\CodexGuest\agent-state.json'
                    if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $agentStatePath)) { return $null }
                    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
                    $agent = Get-Content -Raw -LiteralPath $agentStatePath | ConvertFrom-Json
                    [pscustomobject][ordered]@{
                        Manifest = $manifest
                        AgentReady = [bool]$agent.Ready
                        AgentUserInteractive = [bool]$agent.UserInteractive
                        AgentSessionId = [int]$agent.SessionId
                    }
                }
                if ($inventory -and $inventory.AgentReady -and $inventory.AgentUserInteractive) { break }
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                $session = $null
            }
            catch {
                if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue; $session = $null }
            }
            Start-Sleep -Seconds 2
        }
        if (-not $inventory -or -not $inventory.AgentReady -or -not $inventory.AgentUserInteractive) {
            throw "Timed out waiting for the interactive guest agent in $VmName."
        }
        if ([string]$inventory.Manifest.OsBuildNumber -ne [string]$ExpectedManifest.OsBuildNumber -or
            [string]$inventory.Manifest.DisplayVersion -ne [string]$ExpectedManifest.DisplayVersion) {
            throw "$VmName does not match the updated baseline Windows build."
        }
        $missingSdks = @($ExpectedManifest.ExpectedDotNetSdks | Where-Object { [string]$_ -notin @($inventory.Manifest.DotNetSdks | ForEach-Object { [string]$_ }) })
        if ($missingSdks.Count -gt 0) { throw "$VmName is missing expected .NET SDKs: $($missingSdks -join ', ')." }
        if ([bool]$inventory.Manifest.PendingReboot -or -not [bool]$inventory.Manifest.SdkSmokeBuildPassed) {
            throw "$VmName inherited an unverified or reboot-pending image manifest."
        }
        if (@(Get-VMNetworkAdapter -VMName $VmName | Where-Object { $_.SwitchName }).Count -gt 0) {
            throw "$VmName unexpectedly has a connected network adapter."
        }
        try { Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock { shutdown.exe /s /t 0 } } catch { }
    }
    finally {
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    $shutdownDeadline = [DateTime]::UtcNow.AddMinutes(4)
    while ((Get-VM -Name $VmName).State -ne 'Off' -and [DateTime]::UtcNow -lt $shutdownDeadline) { Start-Sleep -Seconds 2 }
    if ((Get-VM -Name $VmName).State -ne 'Off') {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null
        throw "$VmName did not shut down cleanly after verification."
    }
    [pscustomobject][ordered]@{
        VmName = $VmName
        VerifiedUtc = [DateTime]::UtcNow.ToString('o')
        OsBuildNumber = [string]$inventory.Manifest.OsBuildNumber
        DisplayVersion = [string]$inventory.Manifest.DisplayVersion
        DotNetSdks = @($inventory.Manifest.DotNetSdks)
        NetworkDisconnected = $true
        VmState = 'Off'
    }
}

function Restore-WorkerRegistration {
    param(
        [Parameter(Mandatory = $true)] $WorkerDefinition,
        [Parameter(Mandatory = $true)] $SourceFirmware,
        $SourceSecurity
    )

    $canonicalName = [string]$WorkerDefinition.VmName
    $canonical = Get-VM -Name $canonicalName -ErrorAction SilentlyContinue
    if ($canonical) {
        if ($canonical.State -ne 'Off') { Stop-VM -Name $canonicalName -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null }
        Remove-VM -Name $canonicalName -Force -ErrorAction SilentlyContinue
    }
    $backupName = [string]$backupVmNames[$canonicalName]
    $backup = if ($backupName) { Get-VM -Name $backupName -ErrorAction SilentlyContinue } else { $null }
    if ($backup) {
        Rename-VM -VM $backup -NewName $canonicalName
        return
    }
    if (Test-Path -LiteralPath ([string]$WorkerDefinition.OsChildPath) -PathType Leaf) {
        $oldVmRoot = Join-Path (Split-Path -Parent (Split-Path -Parent ([string]$WorkerDefinition.OsChildPath))) 'VirtualMachines'
        [void](New-PoolWorkerVm -WorkerId ([int]$WorkerDefinition.WorkerId) -VmName $canonicalName -OsChildPath ([string]$WorkerDefinition.OsChildPath) -BaseVhdx ([string]$oldDefinition.BaseVhdx) -VmRoot $oldVmRoot -SourceFirmware $SourceFirmware -SourceSecurity $SourceSecurity -UseExistingOsChild)
    }
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Harness image maintenance must run from an elevated administrator process.'
    }
    foreach ($requiredPath in @($definitionPath, $credentialPath, (Join-Path $PSScriptRoot 'Update-WindowsGuestImage.ps1'), (Join-Path $PSScriptRoot 'Install-PoolHostBroker.ps1'))) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Required maintenance file is missing: $requiredPath" }
    }
    try { [void][Security.Principal.SecurityIdentifier]::new($TargetUserSid) } catch { throw "Invalid target-user SID: $TargetUserSid" }
    [void](Assert-SafeGenerationPath)
    Import-Module Hyper-V -ErrorAction Stop
    Assert-ImageUpdateNotCancelled

    $oldDefinitionRaw = Get-Content -Raw -LiteralPath $definitionPath
    $oldDefinition = $oldDefinitionRaw | ConvertFrom-Json
    if ($resumeRetainedGeneration) {
        if (-not (Test-Path -LiteralPath $oldDefinitionArchive -PathType Leaf)) {
            throw "The retained update archive is missing its rollback pool definition: $oldDefinitionArchive"
        }
        $archivedDefinitionRaw = Get-Content -Raw -LiteralPath $oldDefinitionArchive
        if (-not [string]::Equals($archivedDefinitionRaw.Trim(), $oldDefinitionRaw.Trim(), [StringComparison]::Ordinal)) {
            throw 'The active pool definition no longer matches the retained update rollback definition; refusing an ambiguous resume.'
        }
    }
    else {
        New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
        $oldDefinitionRaw | Set-Content -LiteralPath $oldDefinitionArchive -Encoding UTF8
    }

    $baselineVm = Get-VM -Name ([string]$layout.BaselineVmName) -ErrorAction Stop
    if ($AdoptCurrentBaseline) {
        if ($baselineVm.State -notin @('Off', 'Running')) { throw "The adopted baseline VM must be Off or Running; current state is $($baselineVm.State)." }
    }
    elseif ($baselineVm.State -ne 'Off') {
        throw "Baseline VM must be off before maintenance; current state is $($baselineVm.State)."
    }
    $sourceFirmware = Get-VMFirmware -VMName $baselineVm.Name -ErrorAction Stop
    $sourceSecurity = Get-VMSecurity -VMName $baselineVm.Name -ErrorAction SilentlyContinue
    foreach ($workerDefinition in @($oldDefinition.Workers | Sort-Object WorkerId)) {
        $workerName = [string]$workerDefinition.VmName
        if (Get-VM -Name $workerName -ErrorAction SilentlyContinue) { continue }
        $workerDisk = [IO.Path]::GetFullPath([string]$workerDefinition.OsChildPath)
        if (-not (Test-Path -LiteralPath $workerDisk -PathType Leaf)) {
            throw "Worker registration and its defined OS child disk are both missing: $workerName ($workerDisk)."
        }
        $owners = @(Get-VmDiskOwners -DiskPath $workerDisk)
        $rollbackOwner = @($owners | Where-Object { $_.Name -like "$workerName-preupdate-*" })
        if ($owners.Count -eq 1 -and $rollbackOwner.Count -eq 1) {
            if ([string]$rollbackOwner[0].State -ne 'Off') { throw "Rollback registration $($rollbackOwner[0].Name) must be off before repair." }
            Rename-VM -Name ([string]$rollbackOwner[0].Name) -NewName $workerName -ErrorAction Stop
            [void]$registrationRepairs.Add([pscustomobject][ordered]@{ VmName = $workerName; Action = 'RenamedRollbackRegistration'; PreviousName = [string]$rollbackOwner[0].Name })
            continue
        }
        if ($owners.Count -gt 0) {
            throw "Cannot safely restore $workerName because its OS child disk is attached to: $($owners.Name -join ', ')."
        }
        $oldVmRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $workerDisk)) 'VirtualMachines'
        [void](New-PoolWorkerVm -WorkerId ([int]$workerDefinition.WorkerId) -VmName $workerName -OsChildPath $workerDisk -BaseVhdx ([string]$oldDefinition.BaseVhdx) -VmRoot $oldVmRoot -SourceFirmware $sourceFirmware -SourceSecurity $sourceSecurity -UseExistingOsChild)
        [void]$registrationRepairs.Add([pscustomobject][ordered]@{ VmName = $workerName; Action = 'RecreatedFromExistingDisk'; DiskPath = $workerDisk })
    }

    $queued = @(Get-ChildItem -LiteralPath (Join-Path $brokerRoot 'Requests') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $processing = @(Get-ChildItem -LiteralPath (Join-Path $brokerRoot 'Processing') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($queued.Count -gt 0 -or $processing.Count -gt 0) { throw "Image maintenance requires an empty queue; queued=$($queued.Count), processing=$($processing.Count)." }
    $poolStatePath = Join-Path $brokerRoot 'State\pool-state.json'
    if (Test-Path -LiteralPath $poolStatePath -PathType Leaf) {
        $poolState = Get-Content -Raw -LiteralPath $poolStatePath | ConvertFrom-Json
        $unclean = @($poolState.Workers | Where-Object {
            $activeRequestId = if ($_.PSObject.Properties['ActiveRequestId']) { [string]$_.ActiveRequestId } else { $null }
            -not [bool]$_.OsClean -or -not [string]::IsNullOrWhiteSpace($activeRequestId)
        })
        if ($unclean.Count -gt 0) { throw "Pool state contains leased or unclean workers: $($unclean.VmName -join ', ')." }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $maintenancePath) | Out-Null
    Write-JsonAtomic -Path $maintenancePath -Value ([ordered]@{
        Status = 'MaintenanceRequested'
        Reason = 'Sequential Windows and .NET baseline image update.'
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
        UpdateId = $updateId
    })
    $maintenanceCreated = $true
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        $taskWasRunning = $true
    }

    $workerNames = @($oldDefinition.Workers | Sort-Object WorkerId | ForEach-Object { [string]$_.VmName })
    $drainDeadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        $running = @($workerNames | ForEach-Object { Get-VM -Name $_ -ErrorAction SilentlyContinue } | Where-Object State -ne 'Off')
        if ($running.Count -eq 0) { break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $drainDeadline)
    if ($running.Count -gt 0) { throw "Timed out waiting for workers to shut down: $($running.Name -join ', ')." }
    Assert-ImageUpdateNotCancelled

    $generationBaseRoot = Join-Path $generationRoot 'Base'
    $generationChildrenRoot = Join-Path $generationRoot 'OsChildren'
    $generationVmRoot = Join-Path $generationRoot 'VirtualMachines'
    $newBaseVhdx = Join-Path $generationBaseRoot 'windows11-harness-base.vhdx'
    $canonicalCheckpoint = Get-VMSnapshot -VMName $baselineVm.Name -Name ([string]$layout.BaselineCheckpointName) -ErrorAction Stop
    $canonicalCheckpointId = [string]$canonicalCheckpoint.Id
    $servicing = $null
    $conversion = $null

    if ($resumeRetainedGeneration) {
        if ([string]$oldDefinition.SourceCheckpointId -ne $canonicalCheckpointId) {
            throw 'The canonical checkpoint no longer matches the retained update rollback definition.'
        }
        $candidateCheckpoint = Get-VMSnapshot -VMName $baselineVm.Name -Name $candidateCheckpointName -ErrorAction Stop
        $candidateCheckpointId = [string]$candidateCheckpoint.Id
        if ([string]$candidateCheckpoint.ParentSnapshotId -ne $canonicalCheckpointId) {
            throw 'The retained updated checkpoint is not a direct child of the current rollback checkpoint.'
        }
        $candidateDrives = @(Get-VMHardDiskDrive -VMSnapshot $candidateCheckpoint -ErrorAction Stop | Where-Object Path)
        if ($candidateDrives.Count -ne 1) { throw 'The retained updated checkpoint must contain exactly one OS disk.' }
        $candidateDiskPath = [IO.Path]::GetFullPath([string]$candidateDrives[0].Path)
        if (-not (Test-Path -LiteralPath $candidateDiskPath -PathType Leaf)) { throw "The retained updated checkpoint disk is missing: $candidateDiskPath" }

        $servicingStatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'baseline-servicing-status.json'
        $servicingStatus = Get-Content -Raw -LiteralPath $servicingStatusPath | ConvertFrom-Json
        if (-not [bool]$servicingStatus.Success -or [string]$servicingStatus.Phase -ne 'ReadyToSeal') {
            throw 'The retained update has no successful ReadyToSeal baseline-servicing record.'
        }
        $servicedManifest = $servicingStatus.Details.After
        if ([string]$ExpectedDotNetSdkVersion -notin @($servicedManifest.DotNetSdks | ForEach-Object { [string]$_ }) -or
            [bool]$servicedManifest.PendingReboot -or -not [bool]$servicedManifest.SdkSmokeBuildPassed -or
            [string]$servicingStatus.Details.VmState -ne 'Off' -or -not [bool]$servicingStatus.Details.NetworkDisconnected) {
            throw 'The retained baseline servicing record does not prove the approved SDK, clean reboot state, smoke build, shutdown, and network disconnection.'
        }
        if ([DateTime]::Parse([string]$servicingStatus.UpdatedUtc).ToUniversalTime() -gt $candidateCheckpoint.CreationTime.ToUniversalTime()) {
            throw 'The retained checkpoint predates completion of its baseline-servicing record.'
        }

        $retainedAuditPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'post-image-update-audit.json'
        $retainedAudit = Get-Content -Raw -LiteralPath $retainedAuditPath | ConvertFrom-Json
        if (-not [bool]$retainedAudit.Success -or
            [string]$retainedAudit.Source.CheckpointId -ne $candidateCheckpointId -or
            -not [string]::Equals([IO.Path]::GetFullPath([string]$retainedAudit.Base.Path), [IO.Path]::GetFullPath($newBaseVhdx), [StringComparison]::OrdinalIgnoreCase) -or
            @($retainedAudit.Workers).Count -ne [int]$layout.PoolSize) {
            throw 'The retained generation does not match its successful privileged pool audit.'
        }

        $newBase = Get-VHD -Path $newBaseVhdx -ErrorAction Stop
        if ($newBase.ParentPath -or -not (Get-Item -LiteralPath $newBaseVhdx -Force).IsReadOnly) {
            throw 'The retained pool base is not an immutable standalone VHDX.'
        }
        foreach ($workerDefinition in @($oldDefinition.Workers | Sort-Object WorkerId)) {
            $workerId = [int]$workerDefinition.WorkerId
            $childPath = Join-Path $generationChildrenRoot ('worker-{0:D2}.vhdx' -f $workerId)
            $child = Get-VHD -Path $childPath -ErrorAction Stop
            $auditedWorker = @($retainedAudit.Workers | Where-Object { [int]$_.WorkerId -eq $workerId })
            if ($auditedWorker.Count -ne 1 -or -not [bool]$auditedWorker[0].OsParentMatchesBase -or [string]$auditedWorker[0].State -ne 'Off' -or
                @($auditedWorker[0].NetworkAdapters | Where-Object { [bool]$_.Connected -or -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) }).Count -gt 0 -or
                -not [string]::Equals([IO.Path]::GetFullPath([string]$child.ParentPath), [IO.Path]::GetFullPath($newBaseVhdx), [StringComparison]::OrdinalIgnoreCase) -or
                @(Get-VmDiskOwners -DiskPath $childPath).Count -gt 0) {
                throw "Retained worker $workerId no longer matches its audited disconnected differencing disk."
            }
        }
        $servicing = [pscustomobject][ordered]@{
            Success = $true
            ResumedFromUpdateId = $updateId
            StatusPath = $servicingStatusPath
            After = $servicedManifest
            Details = $servicingStatus.Details
        }
        $conversion = [pscustomobject][ordered]@{ SourcePath = $candidateDiskPath; RetryCount = 0; ReusedRetainedBase = $true }
        Write-UpdateStatus -Phase 'ResumingRetainedGeneration' -Message 'Reusing the audited updated checkpoint and immutable worker generation; Windows Update and baseline guest execution are skipped.' -Details @{
            RetainedCheckpoint = $candidateCheckpointName
            RetainedCheckpointId = $candidateCheckpointId
            GenerationRoot = $generationRoot
            BaselineVmState = [string]$baselineVm.State
        }
    }
    else {
        if ($AdoptCurrentBaseline) {
            $processor = Get-VMProcessor -VMName $baselineVm.Name -ErrorAction Stop
            $memory = Get-VMMemory -VMName $baselineVm.Name -ErrorAction Stop
            $video = Get-VMVideo -VMName $baselineVm.Name -ErrorAction Stop
            if ([int]$processor.Count -ne [int]$layout.VmProcessorCount -or
                [bool]$memory.DynamicMemoryEnabled -or
                [long]$memory.Startup -ne [long]$layout.VmMemoryBytes -or
                [int]$video.HorizontalResolution -ne [int]$layout.GuestDisplayWidth -or
                [int]$video.VerticalResolution -ne [int]$layout.GuestDisplayHeight) {
                throw 'The current baseline hardware no longer matches the approved harness configuration; refusing to alter it during adoption.'
            }
            $connectedAdapters = @(Get-VMNetworkAdapter -VMName $baselineVm.Name -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) })
            if ($connectedAdapters.Count -gt 1 -or ($connectedAdapters.Count -eq 1 -and [string]$connectedAdapters[0].SwitchName -ne $NetworkSwitchName)) {
                throw "The adopted baseline may begin disconnected or connected only to the approved '$NetworkSwitchName' switch."
            }
        }
        else {
            Restore-VMSnapshot -VMSnapshot $canonicalCheckpoint -Confirm:$false
            Set-VMProcessor -VMName $baselineVm.Name -Count ([int]$layout.VmProcessorCount) -ErrorAction Stop
            Set-VMMemory -VMName $baselineVm.Name -DynamicMemoryEnabled $false -StartupBytes ([long]$layout.VmMemoryBytes) -ErrorAction Stop
            Set-VMVideo -VMName $baselineVm.Name -HorizontalResolution ([int]$layout.GuestDisplayWidth) -VerticalResolution ([int]$layout.GuestDisplayHeight) -ResolutionType Single -ErrorAction Stop
            Get-VMNetworkAdapter -VMName $baselineVm.Name -ErrorAction SilentlyContinue | Disconnect-VMNetworkAdapter -ErrorAction SilentlyContinue
        }

        Write-UpdateStatus -Phase 'ServicingBaseline' -Message 'Updating the canonical Windows baseline before creating a candidate checkpoint.' -Details @{
            BaselineVm = $baselineVm.Name
            CanonicalCheckpoint = $canonicalCheckpoint.Name
            NetworkSwitchName = $NetworkSwitchName
            DotNetChannel = $DotNetChannel
            ExpectedDotNetSdkVersion = $ExpectedDotNetSdkVersion
            AdoptCurrentBaseline = [bool]$AdoptCurrentBaseline
        }
        $servicing = & (Join-Path $PSScriptRoot 'Update-WindowsGuestImage.ps1') -VmName $baselineVm.Name -ConfigPath $layout.ConfigPath -CredentialPath $credentialPath -NetworkSwitchName $NetworkSwitchName -DotNetChannel $DotNetChannel -ExpectedDotNetSdkVersion $ExpectedDotNetSdkVersion -ExpectedInstalledChannelVersions $ExpectedInstalledChannelVersions -GuestRestartMode $GuestRestartMode -CancellationPath $CancellationPath -AllowApprovedConnectedStart:$AdoptCurrentBaseline -StatusPath (Get-CodexHarnessManagementStatusPath -Config $layout -Name 'baseline-servicing-status.json')
        $servicingCancelled = ($null -ne $servicing.PSObject.Properties['Cancelled']) -and [bool]$servicing.Cancelled
        $servicingResumeRequired = ($null -ne $servicing.PSObject.Properties['ResumeRequired']) -and [bool]$servicing.ResumeRequired
        if ($servicingCancelled) {
            Write-UpdateStatus -Phase 'Cancelled' -Message 'Image maintenance stopped cooperatively after the current synchronous guest operation; no candidate checkpoint or pool mutation was started.' -Details @{ Baseline = $servicing }
            return [pscustomobject][ordered]@{ Success = $false; Cancelled = $true; ResumeRequired = $false; StatusPath = $StatusPath; Details = @{ Baseline = $servicing } }
        }
        if ($servicingResumeRequired) {
            $resume = [ordered]@{ GuestRestartMode = 'Manual'; AdoptCurrentBaseline = $true }
            Write-UpdateStatus -Phase 'ManualRebootPending' -Message 'The baseline requires a user-controlled restart. Resume in adoption mode so the current guest state is preserved.' -Details @{ Baseline = $servicing; Resume = $resume }
            return [pscustomobject][ordered]@{ Success = $false; Cancelled = $false; ResumeRequired = $true; StatusPath = $StatusPath; Details = @{ Baseline = $servicing; Resume = $resume } }
        }
        if (-not [bool]$servicing.Success) { throw 'Baseline image servicing did not complete successfully.' }
        Assert-ImageUpdateNotCancelled

        Checkpoint-VM -VMName $baselineVm.Name -SnapshotName $candidateCheckpointName
        $candidateCheckpoint = Get-VMSnapshot -VMName $baselineVm.Name -Name $candidateCheckpointName -ErrorAction Stop
        $candidateCheckpointId = [string]$candidateCheckpoint.Id
        New-Item -ItemType Directory -Force -Path $generationBaseRoot, $generationChildrenRoot, $generationVmRoot | Out-Null
        Write-UpdateStatus -Phase 'CreatingPoolBase' -Message 'Converting the verified candidate checkpoint into a new immutable pool base.' -Details @{ CandidateCheckpoint = $candidateCheckpointName; GenerationRoot = $generationRoot }
        $conversion = Convert-PoolBase -SourceVmName $baselineVm.Name -CheckpointName $candidateCheckpointName -DestinationPath $newBaseVhdx
        Assert-ImageUpdateNotCancelled
        $newBase = Get-VHD -Path $newBaseVhdx -ErrorAction Stop
        if ($newBase.ParentPath) { throw 'The new pool base unexpectedly retained a differencing parent.' }
        (Get-Item -LiteralPath $newBaseVhdx -Force).IsReadOnly = $true
    }

    $guestCredential = New-GuestCredential
    $newWorkers = New-Object Collections.Generic.List[object]
    $workerVerifications = New-Object Collections.Generic.List[object]
    foreach ($workerDefinition in @($oldDefinition.Workers | Sort-Object WorkerId)) {
        Assert-ImageUpdateNotCancelled
        $workerId = [int]$workerDefinition.WorkerId
        $vmName = [string]$workerDefinition.VmName
        $backupVmName = "$vmName-preupdate-$updateId"
        Write-UpdateStatus -Phase 'MigratingWorker' -Message "Replacing and verifying $vmName; no other worker will run concurrently." -Details @{
            WorkerId = $workerId
            CompletedWorkers = $workerVerifications.ToArray()
            BackupVmName = $backupVmName
        }
        $existingVm = Get-VM -Name $vmName -ErrorAction Stop
        if ($existingVm.State -ne 'Off') { throw "$vmName must be off before sequential replacement." }
        Assert-ImageUpdateNotCancelled
        Rename-VM -VM $existingVm -NewName $backupVmName
        $backupVmNames[$vmName] = $backupVmName
        [void]$touchedWorkerNames.Add($vmName)
        $osChildPath = Join-Path $generationChildrenRoot ('worker-{0:D2}.vhdx' -f $workerId)
        $newWorker = New-PoolWorkerVm -WorkerId $workerId -VmName $vmName -OsChildPath $osChildPath -BaseVhdx $newBaseVhdx -VmRoot $generationVmRoot -SourceFirmware $sourceFirmware -SourceSecurity $sourceSecurity -UseExistingOsChild:$resumeRetainedGeneration
        $createdVmNames.Add($vmName)
        $verification = Test-WorkerImage -VmName $vmName -Credential $guestCredential -ExpectedManifest $servicing.After
        $newWorkers.Add($newWorker)
        $workerVerifications.Add($verification)
    }

    Assert-ImageUpdateNotCancelled
    $checkpointPromotionStarted = $true
    Rename-VMSnapshot -VMSnapshot $canonicalCheckpoint -NewName $backupCheckpointName
    Rename-VMSnapshot -VMSnapshot $candidateCheckpoint -NewName ([string]$layout.BaselineCheckpointName)
    $checkpointPromoted = $true
    $promotedCheckpoint = Get-VMSnapshot -VMName $baselineVm.Name -Name ([string]$layout.BaselineCheckpointName) -ErrorAction Stop
    if ($resumeRetainedGeneration) {
        Restore-VMSnapshot -VMSnapshot $promotedCheckpoint -Confirm:$false
    }
    $definition = [ordered]@{
        FormatVersion = 1
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        SourceVmName = $baselineVm.Name
        SourceVmId = [string]$baselineVm.Id
        SourceCheckpointName = [string]$layout.BaselineCheckpointName
        SourceCheckpointId = [string]$promotedCheckpoint.Id
        SourceCheckpointDisk = [string]$conversion.SourcePath
        BaselineConvertRetryCount = [int]$conversion.RetryCount
        PoolRoot = [IO.Path]::GetFullPath((Join-Path $brokerRoot 'Pool'))
        BaseVhdx = $newBaseVhdx
        PoolSize = [int]$layout.PoolSize
        VmMemoryBytes = [long]$layout.VmMemoryBytes
        VmProcessorCount = [int]$layout.VmProcessorCount
        GuestDisplayWidth = [int]$layout.GuestDisplayWidth
        GuestDisplayHeight = [int]$layout.GuestDisplayHeight
        Workers = $newWorkers.ToArray()
        PreviousGeneration = [ordered]@{
            DefinitionArchive = $oldDefinitionArchive
            BaseVhdx = [string]$oldDefinition.BaseVhdx
            RetainedOnDisk = $true
        }
    }
    Write-JsonAtomic -Path $definitionPath -Value $definition
    $newDefinitionWritten = $true

    Write-UpdateStatus -Phase 'InstallingBroker' -Message 'Installing the broker against the sequentially verified pool generation.' -Details @{ Definition = $definition; Workers = $workerVerifications.ToArray() }
    & (Join-Path $PSScriptRoot 'Install-PoolHostBroker.ps1') -SourceRoot $PSScriptRoot -BrokerRoot $brokerRoot -PoolDefinitionPath $definitionPath -StatusPath (Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-broker-install-status.json') -ConfigPath $layout.ConfigPath -ClientSid $TargetUserSid
    $taskWasRunning = $true
    $auditPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'post-image-update-audit.json'
    & (Join-Path $PSScriptRoot 'Audit-HyperVTestPool.ps1') -DefinitionPath $definitionPath -BrokerRoot $brokerRoot -StatusPath $auditPath -ExpectedIdleTimeoutSeconds ([int]$layout.PoolIdleTimeoutSeconds) -ConfigPath $layout.ConfigPath -ClientSid $TargetUserSid
    $audit = Get-Content -Raw -LiteralPath $auditPath | ConvertFrom-Json
    if (-not [bool]$audit.Success) { throw 'The updated pool failed its privileged audit.' }

    $smoke = $null
    if (-not $SkipSmokeTest) {
        $runner = Join-Path ([string]$layout.SkillSourceRoot) 'scripts\Invoke-HyperVExecutableTest.ps1'
        $smokeJson = & $runner -ArtifactPath (Join-Path ([string]$layout.SoftwareRoot) 'Canaries\PoolCanary.exe') -ActionsPath (Join-Path ([string]$layout.SoftwareRoot) 'Canaries\smoke-actions.json') -BrokerRoot $brokerRoot -QueueTimeoutSeconds 900 -ExecutionTimeoutSeconds 300
        $smoke = $smokeJson | ConvertFrom-Json
        if (-not [bool]$smoke.Success -or -not [bool]$smoke.PayloadChildDeleted) { throw "The updated pool canary failed: $($smoke.Error)" }
    }

    Assert-ImageUpdateNotCancelled
    $archivedPrevious = $null
    if ($PreserveRecoveryPrevious) {
        $previousRoot = Join-Path ([string]$layout.RecoveryRoot) 'Previous'
        if (Test-Path -LiteralPath (Join-Path $previousRoot 'manifest.json') -PathType Leaf) {
            $recoveryArchiveRoot = Join-Path ([string]$layout.RecoveryRoot) (Join-Path 'Archive' $updateId)
            New-Item -ItemType Directory -Force -Path $recoveryArchiveRoot | Out-Null
            $archivedPrevious = Join-Path $recoveryArchiveRoot 'Previous'
            Move-Item -LiteralPath $previousRoot -Destination $archivedPrevious
        }
    }
    Assert-ImageUpdateNotCancelled

    Write-UpdateStatus -Phase 'RefreshingRecovery' -Message 'Exporting and deep-verifying the updated baseline as the current local recovery image.' -Details @{ ArchivedPrevious = $archivedPrevious }
    & (Join-Path ([string]$layout.SoftwareRoot) 'Recovery\New-CodexHyperVRecovery.ps1') -ConfigPath $layout.ConfigPath -ActiveBrokerRoot $brokerRoot -NoElevation | Out-Null
    Assert-ImageUpdateNotCancelled
    $currentRecovery = Join-Path ([string]$layout.RecoveryRoot) 'Current'
    $recoveryVerification = & (Join-Path ([string]$layout.SoftwareRoot) 'Recovery\Test-CodexHyperVRecovery.ps1') -BundleRoot $currentRecovery -NoElevation
    if (-not [bool]$recoveryVerification.Success) { throw 'The updated local recovery bundle failed deep hash verification.' }
    Assert-ImageUpdateNotCancelled

    foreach ($workerDefinition in @($oldDefinition.Workers)) {
        $backupName = [string]$backupVmNames[[string]$workerDefinition.VmName]
        $backupVm = if ($backupName) { Get-VM -Name $backupName -ErrorAction SilentlyContinue } else { $null }
        if ($backupVm) { Remove-VM -VM $backupVm -Force -ErrorAction Stop }
    }

    $resultDetails = [ordered]@{
        Baseline = $servicing
        CheckpointId = [string]$promotedCheckpoint.Id
        PoolDefinition = $definitionPath
        PoolGeneration = $generationRoot
        PreviousPoolDefinition = $oldDefinitionArchive
        PreviousPoolFilesRetained = $true
        RetainedRollbackCheckpoint = $backupCheckpointName
        Workers = $workerVerifications.ToArray()
        AuditPath = $auditPath
        Smoke = $smoke
        RecoveryRoot = $currentRecovery
        RecoveryVerification = $recoveryVerification
        ArchivedPreviousRecovery = $archivedPrevious
        RegistrationRepairs = $registrationRepairs.ToArray()
        ResumedFromRetainedUpdateId = if ($resumeRetainedGeneration) { $updateId } else { $null }
        NetworkDisconnected = $true
        Licensing = 'Windows activation and licensing were intentionally not configured.'
    }
    Write-UpdateStatus -Phase 'Ready' -Message 'The baseline, four sequential workers, broker, and local recovery image are updated and verified.' -Success $true -Details $resultDetails
    [pscustomobject][ordered]@{ Success = $true; StatusPath = $StatusPath; Details = $resultDetails }
}
catch {
    $failure = $_
    $cancelledByRequest = $failure.Exception -is [OperationCanceledException]
    try {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $sourceVm = Get-VM -Name ([string]$layout.BaselineVmName) -ErrorAction SilentlyContinue
        $sourceFirmware = if ($sourceVm) { Get-VMFirmware -VMName $sourceVm.Name -ErrorAction SilentlyContinue } else { $null }
        $sourceSecurity = if ($sourceVm) { Get-VMSecurity -VMName $sourceVm.Name -ErrorAction SilentlyContinue } else { $null }
        if ($oldDefinition -and $sourceFirmware) {
            foreach ($workerDefinition in @($oldDefinition.Workers)) {
                if ([string]$workerDefinition.VmName -in $touchedWorkerNames) {
                    Restore-WorkerRegistration -WorkerDefinition $workerDefinition -SourceFirmware $sourceFirmware -SourceSecurity $sourceSecurity
                }
            }
        }
        if ($oldDefinitionRaw) { $oldDefinitionRaw | Set-Content -LiteralPath $definitionPath -Encoding UTF8 }
        if ($sourceVm) {
            if ($checkpointPromotionStarted) {
                $snapshots = @(Get-VMSnapshot -VMName $sourceVm.Name -ErrorAction SilentlyContinue)
                $oldCheckpoint = @($snapshots | Where-Object { [string]$_.Id -eq $canonicalCheckpointId } | Select-Object -First 1)
                $newCheckpoint = @($snapshots | Where-Object { [string]$_.Id -eq $candidateCheckpointId } | Select-Object -First 1)
                if ($oldCheckpoint.Count -eq 1) {
                    Restore-VMSnapshot -VMSnapshot $oldCheckpoint[0] -Confirm:$false
                    if ($newCheckpoint.Count -eq 1 -and [string]$newCheckpoint[0].Name -eq [string]$layout.BaselineCheckpointName) {
                        Rename-VMSnapshot -VMSnapshot $newCheckpoint[0] -NewName (([string]$layout.BaselineCheckpointName) + '-failed-' + $updateId)
                    }
                    if ([string]$oldCheckpoint[0].Name -ne [string]$layout.BaselineCheckpointName) {
                        Rename-VMSnapshot -VMSnapshot $oldCheckpoint[0] -NewName ([string]$layout.BaselineCheckpointName)
                    }
                }
            }
            elseif (-not $AdoptCurrentBaseline -and $GuestRestartMode -eq 'Automatic') {
                $oldCheckpoint = Get-VMSnapshot -VMName $sourceVm.Name -Name ([string]$layout.BaselineCheckpointName) -ErrorAction SilentlyContinue
                if ($oldCheckpoint) { Restore-VMSnapshot -VMSnapshot $oldCheckpoint -Confirm:$false }
            }
        }
        if ($oldDefinition -and $sourceFirmware) {
            & (Join-Path $PSScriptRoot 'Install-PoolHostBroker.ps1') -SourceRoot $PSScriptRoot -BrokerRoot $brokerRoot -PoolDefinitionPath $definitionPath -StatusPath (Get-CodexHarnessManagementStatusPath -Config $layout -Name 'rollback-broker-install-status.json') -ConfigPath $layout.ConfigPath -ClientSid $TargetUserSid
            $taskWasRunning = $true
        }
    }
    catch {
        $resultDetails.RollbackError = $_.Exception.Message
    }
    $resultDetails.Error = $failure.Exception.Message
    $resultDetails.ScriptStackTrace = $failure.ScriptStackTrace
    $resultDetails.RollbackAttempted = $true
    $resultDetails.NewDefinitionWritten = $newDefinitionWritten
    $resultDetails.AdoptedBaselineStateRetained = [bool]($AdoptCurrentBaseline -and -not $checkpointPromoted)
    $resultDetails.ManualBaselineStateRetained = [bool]($GuestRestartMode -eq 'Manual' -and -not $checkpointPromoted)
    $resultDetails.RetainedGenerationPreserved = [bool]$resumeRetainedGeneration
    if ($cancelledByRequest) {
        Write-UpdateStatus -Phase 'Cancelled' -Message 'Image maintenance stopped cooperatively and restored broker, maintenance, and pool state.' -Success $false -Details $resultDetails
        return [pscustomobject][ordered]@{ Success = $false; Cancelled = $true; ResumeRequired = $false; StatusPath = $StatusPath; Details = $resultDetails }
    }
    Write-UpdateStatus -Phase 'Failed' -Message $failure.Exception.Message -Success $false -Details $resultDetails
    throw $failure
}
finally {
    if ($maintenanceCreated) { Remove-Item -LiteralPath $maintenancePath -Force -ErrorAction SilentlyContinue }
    if ($taskWasRunning) { Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue }
}
