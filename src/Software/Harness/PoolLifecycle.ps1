[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BrokerRoot,
    [Parameter(Mandatory = $true)] [ValidateRange(1, 64)] [int] $WorkerId,
    [Parameter(Mandatory = $true)] [ValidateSet('Start', 'Recycle', 'Stop')] [string] $Mode,
    [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Fa-f0-9]{32}$')] [string] $OperationId,
    [string] $IdleDeadlineUtc
)

$ErrorActionPreference = 'Stop'
$global:CodexBrokerStateOverridePath = Join-Path $BrokerRoot ('State\WorkerProgress\lifecycle-{0:D2}.json' -f $WorkerId)

. (Join-Path $PSScriptRoot 'PoolCommon.ps1')
. (Join-Path $PSScriptRoot 'HostBroker.ps1') -BrokerRoot $BrokerRoot -LibraryOnly

$config = Get-Content -Raw -LiteralPath (Join-Path $BrokerRoot 'Private\config.json') | ConvertFrom-Json
$worker = Get-PoolWorkerDefinition -Config $config -WorkerId $WorkerId
$vmName = [string]$worker.VmName
$baseVhdx = [IO.Path]::GetFullPath([string]$config.PoolBaseVhdx)
$osChildPath = [IO.Path]::GetFullPath([string]$worker.OsChildPath)
$statePatch = [ordered]@{
    VmName = $vmName
    ProcessId = $PID
    ProcessStartUtc = ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o'))
    LifecycleMode = $Mode
    LastError = $null
}
$expectedStatus = switch ($Mode) {
    'Start' { 'Starting' }
    'Recycle' { 'Recycling' }
    'Stop' { 'Stopping' }
}
$statePatch.Status = $expectedStatus
if (-not (Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $WorkerId -Patch $statePatch -ExpectedOperationId $OperationId -RequireExpectation)) {
    exit 0
}

function Remove-WorkerPayloadAttachments {
    $payloadRoot = [IO.Path]::GetFullPath((Join-Path $BrokerRoot 'PayloadChildren')).TrimEnd('\') + '\'
    foreach ($drive in @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and [IO.Path]::GetFullPath([string]$_.Path).StartsWith($payloadRoot, [StringComparison]::OrdinalIgnoreCase)
    })) {
        $path = [IO.Path]::GetFullPath([string]$drive.Path)
        Remove-VMHardDiskDrive -VMHardDiskDrive $drive -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Dismount-VHD -Path $path -ErrorAction SilentlyContinue
            try { (Get-Item -LiteralPath $path -Force).IsReadOnly = $false } catch { }
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Reset-WorkerNetworkIsolation {
    $null = Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot
    Remove-ManagedRequestNetworkAdapters -VmName $vmName -BrokerRoot $BrokerRoot
    Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'CodexHostInput-*' } |
        Remove-VMNetworkAdapter -ErrorAction SilentlyContinue
    $connected = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName)
    })
    if ($connected.Count -gt 0) {
        throw "The pool refuses to continue while $vmName has a connected network adapter: $($connected.SwitchName -join ', ')."
    }
}

function Reset-WorkerOperatingSystemDisk {
    if (-not (Test-Path -LiteralPath $baseVhdx -PathType Leaf)) {
        throw "Pool base VHDX is missing: $baseVhdx"
    }
    if (-not (Get-Item -LiteralPath $baseVhdx -Force).IsReadOnly) {
        throw 'The pool base VHDX must remain read-only.'
    }

    $configuredDrive = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), $osChildPath, [StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
    $controllerType = if ($configuredDrive) { [string]$configuredDrive.ControllerType } else { [string]$worker.OsControllerType }
    $controllerNumber = if ($configuredDrive) { [int]$configuredDrive.ControllerNumber } else { [int]$worker.OsControllerNumber }
    $controllerLocation = if ($configuredDrive) { [int]$configuredDrive.ControllerLocation } else { [int]$worker.OsControllerLocation }
    if ([string]::IsNullOrWhiteSpace($controllerType)) { $controllerType = 'SCSI' }

    if ($configuredDrive) {
        Remove-VMHardDiskDrive -VMHardDiskDrive $configuredDrive -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $osChildPath -PathType Leaf) {
        Dismount-VHD -Path $osChildPath -ErrorAction SilentlyContinue
        try { (Get-Item -LiteralPath $osChildPath -Force).IsReadOnly = $false } catch { }
        Remove-Item -LiteralPath $osChildPath -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $osChildPath) | Out-Null
    New-VHD -Path $osChildPath -ParentPath $baseVhdx -Differencing -ErrorAction Stop | Out-Null
    Add-VMHardDiskDrive -VMName $vmName -ControllerType $controllerType -ControllerNumber $controllerNumber -ControllerLocation $controllerLocation -Path $osChildPath -ErrorAction Stop | Out-Null
    $bootDrive = Get-VMHardDiskDrive -VMName $vmName | Where-Object {
        $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), $osChildPath, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if (-not $bootDrive) {
        throw 'The freshly created worker OS disk was not attached.'
    }
    Set-VMFirmware -VMName $vmName -FirstBootDevice $bootDrive -ErrorAction Stop
}

try {
    Import-Module Hyper-V
    $vm = Get-VM -Name $vmName -ErrorAction Stop
    # Disconnect broker-managed request/host-input adapters before attempting
    # to stop a worker. A stop can hang or fail while a guest/network teardown
    # is in flight, so the isolation gate is intentionally repeated after the
    # stop as well.
    Reset-WorkerNetworkIsolation
    if ($vm.State -ne 'Off') {
        Stop-TestVm -VmName $vmName -Immediate
    }

    Reset-WorkerNetworkIsolation
    Remove-WorkerPayloadAttachments

    if ($Mode -eq 'Stop') {
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $WorkerId -ExpectedOperationId $OperationId -RequireExpectation -Patch ([ordered]@{
            Status = 'Off'
            OperationId = $null
            ProcessId = $null
            ProcessStartUtc = $null
            LifecycleMode = $null
            IdleDeadlineUtc = $null
            RequestId = $null
        }) | Out-Null
        exit 0
    }

    $mustReset = $Mode -eq 'Recycle' -or -not (Test-Path -LiteralPath $osChildPath -PathType Leaf)
    if (-not $mustReset) {
        try {
            $existingVhd = Get-VHD -Path $osChildPath -ErrorAction Stop
            $mustReset = -not [string]::Equals([IO.Path]::GetFullPath([string]$existingVhd.ParentPath), $baseVhdx, [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $mustReset = $true
        }
    }
    if ($mustReset) {
        Reset-WorkerOperatingSystemDisk
        $currentState = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $WorkerId
        $nextGeneration = if ($currentState -and $currentState.OsGeneration) { [int]$currentState.OsGeneration + 1 } else { 1 }
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $WorkerId -ExpectedOperationId $OperationId -RequireExpectation -Patch ([ordered]@{
            OsGeneration = $nextGeneration
            OsClean = $true
        }) | Out-Null
    }

    Reset-WorkerNetworkIsolation

    $vmStartUtc = [DateTime]::UtcNow
    Start-VM -Name $vmName -ErrorAction Stop | Out-Null
    $credential = Get-GuestCredential
    $readyDeadlineUtc = [DateTime]::UtcNow.AddMinutes(4)
    $syntheticRequestId = 'pool-lifecycle-' + ('{0:D2}' -f $WorkerId) + '-' + $OperationId.Substring(0, 12)
    $guestState = Wait-GuestSession -VmName $vmName -Credential $credential -NotBeforeUtc $vmStartUtc -RequestId $syntheticRequestId -ExecutionDeadlineUtc $readyDeadlineUtc

    $deadline = $null
    if (-not [string]::IsNullOrWhiteSpace($IdleDeadlineUtc)) {
        $deadline = [DateTime]::Parse($IdleDeadlineUtc).ToUniversalTime()
    }
    if (-not $deadline) {
        $deadline = Get-PoolIdleDeadline -Config $config -FromUtc ([DateTime]::UtcNow)
    }
    Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $WorkerId -ExpectedOperationId $OperationId -RequireExpectation -Patch ([ordered]@{
        Status = 'Ready'
        OperationId = $null
        ProcessId = $null
        ProcessStartUtc = $null
        LifecycleMode = $null
        RequestId = $null
        OsClean = $true
        LastReadyUtc = [DateTime]::UtcNow.ToString('o')
        IdleDeadlineUtc = $deadline.ToString('o')
        GuestAgentHeartbeatUtc = [string]$guestState.HeartbeatUtc
        LastError = $null
        FaultRecoveryAttempts = 0
        FaultRecoveryNotBeforeUtc = $null
    }) | Out-Null
}
catch {
    $failureMessage = $_.Exception.Message
    # Even when the initial stop or state update fails, retry network
    # disconnection and then retry the stop. Never publish a recyclable worker
    # while a managed adapter may still be connected.
    $initialNetworkResetFailed = $false
    try { Reset-WorkerNetworkIsolation }
    catch {
        $initialNetworkResetFailed = $true
        $failureMessage = "$failureMessage Network reset also failed: $($_.Exception.Message)"
    }
    $stopSucceeded = $false
    try {
        Stop-TestVm -VmName $vmName -Immediate
        $stopSucceeded = $true
    }
    catch {
        $failureMessage = "$failureMessage VM stop also failed: $($_.Exception.Message)"
    }
    if ($initialNetworkResetFailed -and $stopSucceeded) {
        # The VM stop can release an adapter lock held by the guest. Retry
        # immediately after that successful stop, before publishing a fault.
        try { Reset-WorkerNetworkIsolation }
        catch { $failureMessage = "$failureMessage Final network reset also failed: $($_.Exception.Message)" }
    }
    $latest = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $WorkerId
    $faultPatch = New-PoolFaultStatePatch -State $latest -Config $config -ErrorMessage $failureMessage
    Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $WorkerId -ExpectedOperationId $OperationId -RequireExpectation -Patch $faultPatch | Out-Null
    exit 1
}
