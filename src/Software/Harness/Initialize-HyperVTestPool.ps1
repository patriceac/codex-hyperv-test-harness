[CmdletBinding()]
param(
    [string] $SourceVmName = 'Codex-Harness-Baseline',
    [string] $BaselineName = 'Clean-Windows11-Harness',
    [ValidateRange(1, 4)] [int] $PoolSize = 4,
    [string] $PoolVmPrefix = 'Codex-Harness',
    [string] $BrokerRoot,
    [string] $DefinitionPath,
    [string] $StatusPath,
    [string] $ConfigPath,
    [switch] $ForceRecreate
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($BrokerRoot)) { $BrokerRoot = [string]$layout.BrokerRoot }
if ([string]::IsNullOrWhiteSpace($DefinitionPath)) { $DefinitionPath = Join-Path ([string]$layout.HarnessSourceRoot) 'pool-definition.json' }
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-provision-status.json' }
$vmMemoryBytes = [long]$layout.VmMemoryBytes
$vmProcessorCount = [int]$layout.VmProcessorCount
$displayWidth = [int]$layout.GuestDisplayWidth
$displayHeight = [int]$layout.GuestDisplayHeight
$taskName = [string]$layout.BrokerTaskName
$maintenancePath = Join-Path $BrokerRoot 'State\maintenance.json'
$poolRoot = [IO.Path]::GetFullPath((Join-Path $BrokerRoot 'Pool'))
$brokerPrefix = [IO.Path]::GetFullPath($BrokerRoot).TrimEnd('\') + '\'
$createdVmNames = New-Object Collections.Generic.List[string]
$taskWasRunning = $false
$maintenanceCreated = $false

function Write-ProvisionStatus {
    param(
        [Parameter(Mandatory = $true)] [bool] $Success,
        [Parameter(Mandatory = $true)] [string] $Message,
        $Details
    )

    $parent = Split-Path -Parent $StatusPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [ordered]@{
        Success = $Success
        Message = $Message
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        SourceVmName = $SourceVmName
        BaselineName = $BaselineName
        PoolRoot = $poolRoot
        Details = $Details
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}

function Assert-SafePoolPath {
    if (-not $poolRoot.StartsWith($brokerPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($poolRoot) -ne 'Pool') {
        throw "Refusing to manage an unsafe pool path: $poolRoot"
    }
}

function Convert-PoolBaseAfterCheckpointMerge {
    param(
        [Parameter(Mandatory = $true)] [string] $SourceVmName,
        [Parameter(Mandatory = $true)] [string] $CheckpointName,
        [Parameter(Mandatory = $true)] [string] $InitialSourcePath,
        [Parameter(Mandatory = $true)] [string] $DestinationPath,
        [ValidateRange(30, 600)] [int] $TimeoutSeconds = 300
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $retryCount = 0
    $sourcePath = [IO.Path]::GetFullPath($InitialSourcePath)
    while ($true) {
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            $checkpoint = Get-VMSnapshot -VMName $SourceVmName -Name $CheckpointName -ErrorAction Stop
            $drives = @(Get-VMHardDiskDrive -VMSnapshot $checkpoint -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Path) })
            if ($drives.Count -ne 1) { throw "The clean checkpoint must contain exactly one OS disk; found $($drives.Count)." }
            $sourcePath = [IO.Path]::GetFullPath([string]$drives[0].Path)
        }
        try {
            Convert-VHD -Path $sourcePath -DestinationPath $DestinationPath -VHDType Dynamic -ErrorAction Stop
            return [pscustomobject][ordered]@{ RetryCount = $retryCount; SourcePath = $sourcePath }
        }
        catch {
            $exception = $_.Exception
            while ($exception.InnerException) { $exception = $exception.InnerException }
            $sharingViolation = (($exception.HResult -band 0xFFFF) -eq 32) -or $_.Exception.Message -match '0x80070020'
            $resolvedPath = $sourcePath
            try {
                $checkpoint = Get-VMSnapshot -VMName $SourceVmName -Name $CheckpointName -ErrorAction Stop
                $drives = @(Get-VMHardDiskDrive -VMSnapshot $checkpoint -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Path) })
                if ($drives.Count -eq 1) { $resolvedPath = [IO.Path]::GetFullPath([string]$drives[0].Path) }
            }
            catch {
            }
            $pathTransition = -not [string]::Equals($resolvedPath, $sourcePath, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)
            if ((-not $sharingViolation -and -not $pathTransition) -or [DateTime]::UtcNow -ge $deadline) { throw }
            $retryCount++
            $sourcePath = $resolvedPath
            if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
                Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 2
        }
    }
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Hyper-V pool provisioning must run from an elevated administrator process.'
    }
    Assert-SafePoolPath
    Import-Module Hyper-V

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $maintenancePath) | Out-Null
    [ordered]@{
        Status = 'MaintenanceRequested'
        Reason = 'Provisioning the elastic Hyper-V worker pool.'
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $maintenancePath -Encoding UTF8
    $maintenanceCreated = $true

    $drainDeadline = [DateTime]::UtcNow.AddMinutes(20)
    while (@(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'Processing') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0 -and [DateTime]::UtcNow -lt $drainDeadline) {
        Start-Sleep -Seconds 1
    }
    if (@(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'Processing') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Timed out waiting for active executable tests to drain before pool provisioning.'
    }

    $brokerTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($brokerTask -and $brokerTask.State -eq 'Running') {
        $taskWasRunning = $true
        Stop-ScheduledTask -TaskName $taskName
        $stopDeadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            $brokerTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        } while ($brokerTask -and $brokerTask.State -eq 'Running' -and [DateTime]::UtcNow -lt $stopDeadline)
    }

    $sourceVm = Get-VM -Name $SourceVmName -ErrorAction Stop
    if ($sourceVm.State -ne 'Off') {
        Stop-VM -Name $SourceVmName -TurnOff -Force -ErrorAction Stop | Out-Null
    }
    $baseline = Get-VMSnapshot -VMName $SourceVmName -Name $BaselineName -ErrorAction Stop
    $snapshotDrives = @(Get-VMHardDiskDrive -VMSnapshot $baseline -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Path) })
    if ($snapshotDrives.Count -ne 1) {
        throw "The clean checkpoint must contain exactly one OS disk; found $($snapshotDrives.Count)."
    }
    $sourceDiskPath = [IO.Path]::GetFullPath([string]$snapshotDrives[0].Path)
    if (-not (Test-Path -LiteralPath $sourceDiskPath -PathType Leaf)) {
        throw "The checkpoint OS disk is missing: $sourceDiskPath"
    }

    $expectedNames = @(1..$PoolSize | ForEach-Object { '{0}-{1:D2}' -f $PoolVmPrefix, $_ })
    $existingDefinition = $null
    if (Test-Path -LiteralPath $DefinitionPath -PathType Leaf) {
        try { $existingDefinition = Get-Content -Raw -LiteralPath $DefinitionPath | ConvertFrom-Json } catch { }
    }
    $existingPoolComplete = $existingDefinition -and
        [string]$existingDefinition.SourceCheckpointId -eq [string]$baseline.Id -and
        [int]$existingDefinition.PoolSize -eq $PoolSize -and
        [long]$existingDefinition.VmMemoryBytes -eq $vmMemoryBytes -and
        [int]$existingDefinition.VmProcessorCount -eq $vmProcessorCount -and
        [int]$existingDefinition.GuestDisplayWidth -eq $displayWidth -and
        [int]$existingDefinition.GuestDisplayHeight -eq $displayHeight -and
        (Test-Path -LiteralPath ([string]$existingDefinition.BaseVhdx) -PathType Leaf) -and
        @($expectedNames | Where-Object { -not (Get-VM -Name $_ -ErrorAction SilentlyContinue) }).Count -eq 0
    if ($existingPoolComplete -and -not $ForceRecreate) {
        Write-ProvisionStatus -Success $true -Message 'The requested Hyper-V pool already exists and matches the current clean checkpoint.' -Details $existingDefinition
        return
    }

    foreach ($name in $expectedNames) {
        $existingVm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $existingVm) { continue }
        if (-not $ForceRecreate -and -not $existingDefinition) {
            throw "A VM named $name already exists, but no matching pool definition proves that it is safe to replace."
        }
        if ($existingVm.State -ne 'Off') {
            Stop-VM -Name $name -TurnOff -Force -ErrorAction Stop | Out-Null
        }
        Remove-VM -Name $name -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $poolRoot -PathType Container) {
        Get-ChildItem -LiteralPath $poolRoot -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.IsReadOnly = $false } catch { } }
        Remove-Item -LiteralPath $poolRoot -Recurse -Force
    }

    $baseRoot = Join-Path $poolRoot 'Base'
    $childrenRoot = Join-Path $poolRoot 'OsChildren'
    $vmRoot = Join-Path $poolRoot 'VirtualMachines'
    New-Item -ItemType Directory -Force -Path $baseRoot, $childrenRoot, $vmRoot | Out-Null
    $baseVhdx = Join-Path $baseRoot 'windows11-harness-base.vhdx'
    $temporaryBase = Join-Path $baseRoot ('windows11-harness-base.' + [Guid]::NewGuid().ToString('N') + '.tmp.vhdx')
    $baselineConversion = Convert-PoolBaseAfterCheckpointMerge -SourceVmName $SourceVmName -CheckpointName $BaselineName -InitialSourcePath $sourceDiskPath -DestinationPath $temporaryBase
    $baselineConvertRetryCount = [int]$baselineConversion.RetryCount
    $sourceDiskPath = [string]$baselineConversion.SourcePath
    $standalone = Get-VHD -Path $temporaryBase -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace([string]$standalone.ParentPath)) {
        throw 'The converted pool base unexpectedly retained a differencing parent.'
    }
    Move-Item -LiteralPath $temporaryBase -Destination $baseVhdx
    (Get-Item -LiteralPath $baseVhdx -Force).IsReadOnly = $true

    $sourceFirmware = Get-VMFirmware -VMName $SourceVmName
    $sourceSecurity = Get-VMSecurity -VMName $SourceVmName -ErrorAction SilentlyContinue
    $workers = New-Object Collections.Generic.List[object]
    for ($workerId = 1; $workerId -le $PoolSize; $workerId++) {
        $vmName = '{0}-{1:D2}' -f $PoolVmPrefix, $workerId
        $osChildPath = Join-Path $childrenRoot ('worker-{0:D2}.vhdx' -f $workerId)
        New-VHD -Path $osChildPath -ParentPath $baseVhdx -Differencing -ErrorAction Stop | Out-Null
        New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $vmMemoryBytes -VHDPath $osChildPath -Path $vmRoot -ErrorAction Stop | Out-Null
        $createdVmNames.Add($vmName)
        Set-VMProcessor -VMName $vmName -Count $vmProcessorCount -ErrorAction Stop
        Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -StartupBytes $vmMemoryBytes -ErrorAction Stop
        Set-VMVideo -VMName $vmName -HorizontalResolution $displayWidth -VerticalResolution $displayHeight -ResolutionType Single -ErrorAction Stop
        Set-VM -Name $vmName -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -ErrorAction Stop
        Set-VMFirmware -VMName $vmName -EnableSecureBoot $sourceFirmware.SecureBoot -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
        if (@(Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue).Count -eq 0) {
            Add-VMNetworkAdapter -VMName $vmName -Name 'Network Adapter' | Out-Null
        }
        Get-VMNetworkAdapter -VMName $vmName | Disconnect-VMNetworkAdapter -ErrorAction SilentlyContinue
        if ($sourceSecurity -and $sourceSecurity.TpmEnabled -and (Get-Command Set-VMKeyProtector -ErrorAction SilentlyContinue) -and (Get-Command Enable-VMTPM -ErrorAction SilentlyContinue)) {
            Set-VMKeyProtector -VMName $vmName -NewLocalKeyProtector -ErrorAction Stop
            Enable-VMTPM -VMName $vmName -ErrorAction Stop
        }
        $bootDrive = Get-VMHardDiskDrive -VMName $vmName | Where-Object { $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), [IO.Path]::GetFullPath($osChildPath), [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        Set-VMFirmware -VMName $vmName -FirstBootDevice $bootDrive -ErrorAction Stop
        $workers.Add([pscustomobject][ordered]@{
            WorkerId = $workerId
            VmName = $vmName
            OsChildPath = $osChildPath
            OsControllerType = [string]$bootDrive.ControllerType
            OsControllerNumber = [int]$bootDrive.ControllerNumber
            OsControllerLocation = [int]$bootDrive.ControllerLocation
        })
    }

    $definition = [ordered]@{
        FormatVersion = 1
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        SourceVmName = $SourceVmName
        SourceVmId = [string]$sourceVm.Id
        SourceCheckpointName = $BaselineName
        SourceCheckpointId = [string]$baseline.Id
        SourceCheckpointDisk = $sourceDiskPath
        BaselineConvertRetryCount = $baselineConvertRetryCount
        PoolRoot = $poolRoot
        BaseVhdx = $baseVhdx
        PoolSize = $PoolSize
        VmMemoryBytes = $vmMemoryBytes
        VmProcessorCount = $vmProcessorCount
        GuestDisplayWidth = $displayWidth
        GuestDisplayHeight = $displayHeight
        Workers = $workers.ToArray()
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DefinitionPath) | Out-Null
    $definition | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $DefinitionPath -Encoding UTF8
    Write-ProvisionStatus -Success $true -Message 'The four-slot Hyper-V pool was provisioned from the clean Windows 11 Pro baseline.' -Details $definition
}
catch {
    foreach ($name in @($createdVmNames)) {
        try {
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if ($vm -and $vm.State -ne 'Off') { Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null }
            if ($vm) { Remove-VM -Name $name -Force -ErrorAction SilentlyContinue }
        }
        catch { }
    }
    Write-ProvisionStatus -Success $false -Message $_.Exception.Message -Details $null
    throw
}
finally {
    if ($maintenanceCreated) {
        Remove-Item -LiteralPath $maintenancePath -Force -ErrorAction SilentlyContinue
    }
    if ($taskWasRunning) {
        Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    }
}
