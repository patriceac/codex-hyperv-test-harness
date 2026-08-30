param(
    [string] $VmName = 'Codex-Harness-Baseline',
    [string] $BaselineName = 'Clean-Windows11-Harness',
    [string] $GuestAgentSource,
    [string] $GuestSupervisorSource,
    [string] $GuestLiveEvidenceSource,
    [string] $CredentialPath,
    [string] $SourceRoot,
    [string] $PoolDefinitionPath,
    [string] $BrokerRoot,
    [string] $StatusPath,
    [string] $ConfigPath,
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = [string]$layout.HarnessSourceRoot }
if ([string]::IsNullOrWhiteSpace($GuestAgentSource)) { $GuestAgentSource = Join-Path $SourceRoot 'seed\guest\GuestAgent.ps1' }
if ([string]::IsNullOrWhiteSpace($GuestSupervisorSource)) { $GuestSupervisorSource = Join-Path $SourceRoot 'seed\guest\GuestAgentSupervisor.ps1' }
if ([string]::IsNullOrWhiteSpace($GuestLiveEvidenceSource)) { $GuestLiveEvidenceSource = Join-Path $SourceRoot 'seed\guest\GuestLiveEvidence.ps1' }
if ([string]::IsNullOrWhiteSpace($CredentialPath)) { $CredentialPath = Join-Path $SourceRoot 'private\guest-credential.json' }
if ([string]::IsNullOrWhiteSpace($PoolDefinitionPath)) { $PoolDefinitionPath = Join-Path $SourceRoot 'pool-definition.json' }
if ([string]::IsNullOrWhiteSpace($BrokerRoot)) { $BrokerRoot = [string]$layout.BrokerRoot }
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'guest-update-status.json' }
$taskName = [string]$layout.BrokerTaskName
$taskWasStopped = $false
$maintenanceCreated = $false
$maintenancePath = Join-Path $BrokerRoot 'State\maintenance.json'
$snapshotBackupName = $null

function Get-GuestHarnessSourceInventory {
    $inventory = New-Object Collections.Generic.List[object]
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'GuestAgent'; Path = $GuestAgentSource },
        [pscustomobject]@{ Name = 'GuestSupervisor'; Path = $GuestSupervisorSource },
        [pscustomobject]@{ Name = 'GuestLiveEvidence'; Path = $GuestLiveEvidenceSource },
        [pscustomobject]@{ Name = 'HostBroker'; Path = Join-Path $SourceRoot 'HostBroker.ps1' },
        [pscustomobject]@{ Name = 'LiveEvidence'; Path = Join-Path $SourceRoot 'LiveEvidence.ps1' },
        [pscustomobject]@{ Name = 'InstallPoolHostBroker'; Path = Join-Path $SourceRoot 'Install-PoolHostBroker.ps1' },
        [pscustomobject]@{ Name = 'InitializeHyperVTestPool'; Path = Join-Path $SourceRoot 'Initialize-HyperVTestPool.ps1' }
    )) {
        if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) { throw "Required guest-harness update source is missing: $($entry.Path)" }
        $item = Get-Item -LiteralPath $entry.Path -Force
        $inventory.Add([pscustomobject][ordered]@{
            Name = [string]$entry.Name
            Path = [IO.Path]::GetFullPath([string]$entry.Path)
            Length = [long]$item.Length
            Sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        })
    }
    $inventory.ToArray()
}

function Get-GuestHarnessBaselineUpdatePlan {
    $queued = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'Requests') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $processing = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'Processing') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $liveQueued = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'LiveEvidence\Requests') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $liveProcessing = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'LiveEvidence\Processing') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $poolDefinition = Get-Content -LiteralPath $PoolDefinitionPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    [pscustomobject][ordered]@{
        PlanOnly = [bool]$PlanOnly
        NoMutationPerformed = [bool]$PlanOnly
        ApprovalReady = $queued -eq 0 -and $processing -eq 0 -and $liveQueued -eq 0 -and $liveProcessing -eq 0
        ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
        SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
        BrokerRoot = [IO.Path]::GetFullPath($BrokerRoot)
        BaselineVmName = $VmName
        BaselineCheckpointName = $BaselineName
        PoolSize = [int]$poolDefinition.PoolSize
        PoolVmNames = @($poolDefinition.Workers | ForEach-Object { [string]$_.VmName })
        VmMemoryBytes = [long]$layout.VmMemoryBytes
        VmProcessorCount = [int]$layout.VmProcessorCount
        GuestDisplayWidth = [int]$layout.GuestDisplayWidth
        GuestDisplayHeight = [int]$layout.GuestDisplayHeight
        Queue = [ordered]@{ Queued = $queued; Processing = $processing; LiveQueued = $liveQueued; LiveProcessing = $liveProcessing }
        Source = @(Get-GuestHarnessSourceInventory)
        PersistentChanges = @(
            'Install the reviewed guest-agent and live-evidence module into the canonical clean baseline.',
            'Transactionally replace the canonical clean checkpoint after preserving the prior checkpoint until promotion succeeds.',
            'Force-recreate only the pool workers named by the installed pool definition from the new checkpoint.',
            'Transactionally reinstall and restart the ACL-restricted SYSTEM broker from the reviewed source.'
        )
        SafetyBoundaries = @(
            'No Windows media, SDK, or update download.',
            'No host reboot.',
            'No network profile or virtual-switch change; the baseline remains disconnected.',
            'No application-under-test execution on the physical host.',
            'No request cancellation or deadline extension; apply waits for active processing to drain.'
        )
        DestructiveApprovalRequired = $true
        DestructiveScope = 'Replace the canonical baseline checkpoint and force-recreate only the four named disposable pool workers.'
        RecoveryRefreshRequired = $true
        LiveCanaryRequired = $true
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = $temporaryPath + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                    [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
                }
                else { [IO.File]::Move($temporaryPath, $Path) }
                return
            }
            catch [IO.IOException] { if ($attempt -ge 20) { throw } }
            catch [UnauthorizedAccessException] { if ($attempt -ge 20) { throw } }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Write-UpdateResult {
    param([bool] $Success, [string] $Message, [hashtable] $Details = @{})
    [ordered]@{
        Success = $Success
        Message = $Message
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        VmName = $VmName
        BaselineName = $BaselineName
        Details = $Details
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}

$sourceInventory = @(Get-GuestHarnessSourceInventory)
if (-not (Test-Path -LiteralPath $PoolDefinitionPath -PathType Leaf)) { throw "Pool definition not found: $PoolDefinitionPath" }
$plan = Get-GuestHarnessBaselineUpdatePlan
if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 20
    return
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Guest baseline refresh must run from an elevated administrator process.'
    }
    foreach ($guestSourceFile in @($GuestAgentSource, $GuestSupervisorSource, $GuestLiveEvidenceSource)) {
        if (-not (Test-Path -LiteralPath $guestSourceFile -PathType Leaf)) {
            throw "Updated guest harness file not found: $guestSourceFile"
        }
        $parseTokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($guestSourceFile, [ref]$parseTokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "Updated guest harness file has PowerShell parse errors: $guestSourceFile - $($parseErrors[0].Message)"
        }
    }

    Import-Module Hyper-V
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $maintenancePath) | Out-Null
    Write-JsonAtomic -Path $maintenancePath -Value ([ordered]@{
        Status = 'MaintenanceRequested'
        Reason = 'Updating the clean guest harness baseline.'
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
        RequestedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    })
    $maintenanceCreated = $true

    $drainDeadline = [DateTime]::UtcNow.AddMinutes(15)
    $processingRoot = Join-Path $BrokerRoot 'Processing'
    while (@(Get-ChildItem -LiteralPath $processingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0 -and [DateTime]::UtcNow -lt $drainDeadline) {
        Start-Sleep -Seconds 1
    }
    if (@(Get-ChildItem -LiteralPath $processingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Timed out waiting for the active VM request to finish before maintenance.'
    }

    # Keep the broker alive long enough to finish in-flight asynchronous
    # recycling and to stop every Ready worker under the maintenance policy.
    # Rebuilding the pool while a lifecycle child still owns a VM or VHDX can
    # otherwise race the force-recreate transaction.
    $poolDefinition = Get-Content -Raw -LiteralPath $PoolDefinitionPath | ConvertFrom-Json
    $poolVmNames = @($poolDefinition.Workers | ForEach-Object { [string]$_.VmName })
    $poolDrainDeadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        $runningPoolVms = @($poolVmNames | Where-Object {
            $poolVm = Get-VM -Name $_ -ErrorAction SilentlyContinue
            $poolVm -and $poolVm.State -ne 'Off'
        })
        if ($runningPoolVms.Count -eq 0) { break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $poolDrainDeadline)
    if ($runningPoolVms.Count -gt 0) {
        throw 'Timed out waiting for asynchronous pool lifecycle work to drain before baseline maintenance: ' + ($runningPoolVms -join ', ')
    }

    if ((Get-ScheduledTask -TaskName $taskName -ErrorAction Stop).State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        $taskWasStopped = $true
        Start-Sleep -Seconds 2
    }

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        # This is a disposable test guest, and the clean checkpoint is the
        # source of truth. Discard the in-flight failed control run.
        Stop-VM -Name $VmName -TurnOff -Force
    }
    $baseline = Get-VMSnapshot -VMName $VmName -Name $BaselineName -ErrorAction Stop
    Restore-VMSnapshot -VMSnapshot $baseline -Confirm:$false
    Set-VMProcessor -VMName $VmName -Count ([int]$layout.VmProcessorCount) -ErrorAction Stop
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes ([long]$layout.VmMemoryBytes) -ErrorAction Stop
    Set-VMVideo -VMName $VmName -HorizontalResolution ([int]$layout.GuestDisplayWidth) -VerticalResolution ([int]$layout.GuestDisplayHeight) -ResolutionType Single -ErrorAction Stop
    Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue | Disconnect-VMNetworkAdapter -ErrorAction SilentlyContinue
    Start-VM -Name $VmName | Out-Null

    $credentialData = Get-Content -Raw -LiteralPath $CredentialPath | ConvertFrom-Json
    $securePassword = ConvertTo-SecureString ([string]$credentialData.Password) -AsPlainText -Force
    $credential = New-Object Management.Automation.PSCredential([string]$credentialData.UserName, $securePassword)

    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    $session = $null
    while (-not $session -and [DateTime]::UtcNow -lt $deadline) {
        try {
            $session = New-PSSession -VMName $VmName -Credential $credential -ErrorAction Stop
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $session) {
        throw 'Timed out waiting for PowerShell Direct during guest-agent refresh.'
    }

    try {
        Copy-Item -LiteralPath $GuestAgentSource -Destination 'C:\CodexGuest' -ToSession $session -Force
        Copy-Item -LiteralPath $GuestSupervisorSource -Destination 'C:\CodexGuest' -ToSession $session -Force
        Copy-Item -LiteralPath $GuestLiveEvidenceSource -Destination 'C:\CodexGuest' -ToSession $session -Force
        Invoke-Command -Session $session -ScriptBlock {
            foreach ($directoryName in @('Inbox', 'Processing', 'Completed', 'Outbox', 'Payloads', 'Transfer', 'LiveEvidence')) {
                $directory = Join-Path 'C:\CodexGuest' $directoryName
                if (Test-Path -LiteralPath $directory) {
                    Get-ChildItem -LiteralPath $directory -Force | Remove-Item -Recurse -Force
                }
            }
            $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            $supervisorCommand = 'powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\CodexGuest\GuestAgentSupervisor.ps1"'
            New-ItemProperty -LiteralPath $runKey -Name CodexGuestAgent -PropertyType String -Value $supervisorCommand -Force | Out-Null
        }
        $guestHarness = Invoke-Command -Session $session -ScriptBlock {
            [ordered]@{
                GuestAgentSha256 = (Get-FileHash -LiteralPath 'C:\CodexGuest\GuestAgent.ps1' -Algorithm SHA256).Hash
                GuestSupervisorSha256 = (Get-FileHash -LiteralPath 'C:\CodexGuest\GuestAgentSupervisor.ps1' -Algorithm SHA256).Hash
                GuestLiveEvidenceSha256 = (Get-FileHash -LiteralPath 'C:\CodexGuest\GuestLiveEvidence.ps1' -Algorithm SHA256).Hash
                RunCommand = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name CodexGuestAgent).CodexGuestAgent
            }
        }
        $sourceHash = (Get-FileHash -LiteralPath $GuestAgentSource -Algorithm SHA256).Hash
        $supervisorSourceHash = (Get-FileHash -LiteralPath $GuestSupervisorSource -Algorithm SHA256).Hash
        $liveEvidenceSourceHash = (Get-FileHash -LiteralPath $GuestLiveEvidenceSource -Algorithm SHA256).Hash
        if ($guestHarness.GuestAgentSha256 -ne $sourceHash) {
            throw 'Updated guest-agent hash does not match the source file.'
        }
        if ($guestHarness.GuestSupervisorSha256 -ne $supervisorSourceHash) {
            throw 'Updated guest-agent supervisor hash does not match the source file.'
        }
        if ($guestHarness.GuestLiveEvidenceSha256 -ne $liveEvidenceSourceHash) {
            throw 'Updated guest live-evidence module hash does not match the source file.'
        }
        if ([string]$guestHarness.RunCommand -notlike '*GuestAgentSupervisor.ps1*') {
            throw 'The guest Run entry does not launch the agent supervisor.'
        }

        try {
            Invoke-Command -Session $session -ScriptBlock { shutdown.exe /s /t 0 }
        }
        catch {
        }
    }
    finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }

    $shutdownDeadline = [DateTime]::UtcNow.AddMinutes(3)
    while ((Get-VM -Name $VmName).State -ne 'Off' -and [DateTime]::UtcNow -lt $shutdownDeadline) {
        Start-Sleep -Seconds 2
    }
    if ((Get-VM -Name $VmName).State -ne 'Off') {
        Stop-VM -Name $VmName -TurnOff -Force
    }

    # Replace the baseline transactionally. The prior known-good checkpoint
    # remains available until the new checkpoint exists and has taken over the
    # canonical name.
    $snapshotSuffix = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $temporarySnapshotName = "$BaselineName-update-$snapshotSuffix"
    $snapshotBackupName = "$BaselineName-backup-$snapshotSuffix"
    Checkpoint-VM -VMName $VmName -SnapshotName $temporarySnapshotName
    $temporarySnapshot = Get-VMSnapshot -VMName $VmName -Name $temporarySnapshotName -ErrorAction Stop
    $currentBaseline = Get-VMSnapshot -VMName $VmName -Name $BaselineName -ErrorAction Stop
    Rename-VMSnapshot -VMSnapshot $currentBaseline -NewName $snapshotBackupName
    try {
        Rename-VMSnapshot -VMSnapshot $temporarySnapshot -NewName $BaselineName
        $verifiedBaseline = Get-VMSnapshot -VMName $VmName -Name $BaselineName -ErrorAction Stop
        Get-VMSnapshot -VMName $VmName -Name $snapshotBackupName -ErrorAction Stop | Remove-VMSnapshot -Confirm:$false
        $snapshotBackupName = $null
    }
    catch {
        if (-not (Get-VMSnapshot -VMName $VmName -Name $BaselineName -ErrorAction SilentlyContinue)) {
            $backupSnapshot = Get-VMSnapshot -VMName $VmName -Name $snapshotBackupName -ErrorAction SilentlyContinue
            if ($backupSnapshot) {
                Rename-VMSnapshot -VMSnapshot $backupSnapshot -NewName $BaselineName
                $snapshotBackupName = $null
            }
        }
        throw
    }

    # The pool base is a sealed copy of this checkpoint. Rebuild the four
    # disposable shells now so a successful baseline refresh cannot leave the
    # broker serving an older guest harness.
    & (Join-Path $SourceRoot 'Initialize-HyperVTestPool.ps1') `
        -SourceVmName $VmName `
        -BaselineName $BaselineName `
        -BrokerRoot $BrokerRoot `
        -DefinitionPath $PoolDefinitionPath `
        -StatusPath (Join-Path $SourceRoot 'pool-provision-status.json') `
        -ConfigPath $ConfigPath `
        -ForceRecreate
    & (Join-Path $SourceRoot 'Install-PoolHostBroker.ps1') `
        -SourceRoot $SourceRoot `
        -BrokerRoot $BrokerRoot `
        -PoolDefinitionPath $PoolDefinitionPath `
        -StatusPath (Join-Path $SourceRoot 'pool-broker-install-status.json') `
        -ConfigPath $ConfigPath
    $refreshedPoolDefinition = Get-Content -LiteralPath $PoolDefinitionPath -Raw | ConvertFrom-Json
    if ([string]$refreshedPoolDefinition.SourceCheckpointId -ne [string]$verifiedBaseline.Id) {
        throw 'The rebuilt pool definition does not reference the refreshed clean checkpoint.'
    }

    Write-UpdateResult -Success $true -Message 'Updated guest agent is installed in the clean baseline and the four-VM pool was rebuilt from it.' -Details @{
        GuestAgentSha256 = $sourceHash
        GuestSupervisorSha256 = $supervisorSourceHash
        GuestLiveEvidenceSha256 = $liveEvidenceSourceHash
        RunCommand = [string]$guestHarness.RunCommand
        VmState = [string](Get-VM -Name $VmName).State
        BaselineId = [string]$verifiedBaseline.Id
        PoolBaseVhdx = [string]$refreshedPoolDefinition.BaseVhdx
        PoolSize = [int]$refreshedPoolDefinition.PoolSize
        VmMemoryBytes = [long]$refreshedPoolDefinition.VmMemoryBytes
        GuestDisplayWidth = [int]$refreshedPoolDefinition.GuestDisplayWidth
        GuestDisplayHeight = [int]$refreshedPoolDefinition.GuestDisplayHeight
    }
}
catch {
    if ($snapshotBackupName -and -not (Get-VMSnapshot -VMName $VmName -Name $BaselineName -ErrorAction SilentlyContinue)) {
        try {
            $backupSnapshot = Get-VMSnapshot -VMName $VmName -Name $snapshotBackupName -ErrorAction Stop
            Rename-VMSnapshot -VMSnapshot $backupSnapshot -NewName $BaselineName
            $snapshotBackupName = $null
        }
        catch {
        }
    }
    Write-UpdateResult -Success $false -Message $_.Exception.Message -Details @{
        ScriptStackTrace = $_.ScriptStackTrace
    }
    throw
}
finally {
    if ($maintenanceCreated) {
        Remove-Item -LiteralPath $maintenancePath -Force -ErrorAction SilentlyContinue
    }
    try {
        Start-ScheduledTask -TaskName $taskName
    }
    catch {
    }
}
