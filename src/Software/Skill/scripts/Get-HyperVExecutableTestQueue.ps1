[CmdletBinding()]
param(
    [string] $BrokerRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HyperVBrokerLocation.ps1')
$BrokerRoot = Resolve-HyperVBrokerRoot -BrokerRoot $BrokerRoot

$requestsRoot = Join-Path $BrokerRoot 'Requests'
$processingRoot = Join-Path $BrokerRoot 'Processing'
$resultsRoot = Join-Path $BrokerRoot 'Results'
$brokerStatePath = Join-Path $BrokerRoot 'State\broker-state.json'
$poolStatePath = Join-Path $BrokerRoot 'State\pool-state.json'
$maintenancePath = Join-Path $BrokerRoot 'State\maintenance.json'

foreach ($requiredRoot in @($requestsRoot, $processingRoot, $resultsRoot)) {
    if (-not (Test-Path -LiteralPath $requiredRoot -PathType Container)) {
        throw "Broker directory not found: $requiredRoot"
    }
}

function Read-JsonSafe {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $null
    }
}

function Get-RequestDetails {
    param(
        [Parameter(Mandatory = $true)] [IO.FileInfo] $File,
        [Parameter(Mandatory = $true)] [string] $Status,
        [Parameter(Mandatory = $true)] [int] $Position,
        [Nullable[int]] $WorkerId = $null
    )

    $requestId = [IO.Path]::GetFileNameWithoutExtension($File.Name)
    $request = Read-JsonSafe -Path $File.FullName

    $createdUtc = $null
    if ($request -and -not [string]::IsNullOrWhiteSpace([string]$request.CreatedUtc)) {
        try {
            $createdUtc = ([DateTime]$request.CreatedUtc).ToUniversalTime()
        }
        catch {
        }
    }
    if (-not $createdUtc) {
        $createdUtc = $File.CreationTimeUtc
    }

    $queueTimeoutSeconds = if ($request -and $null -ne $request.QueueTimeoutSeconds) { [int]$request.QueueTimeoutSeconds } else { 1800 }
    $executionTimeoutSeconds = if ($request -and $null -ne $request.ExecutionTimeoutSeconds) { [int]$request.ExecutionTimeoutSeconds } else { 900 }
    $requestState = Read-JsonSafe -Path (Join-Path (Join-Path $resultsRoot $requestId) 'request-state.json')
    $effectiveStatus = if ($requestState -and -not [string]::IsNullOrWhiteSpace([string]$requestState.Status)) { [string]$requestState.Status } else { $Status }
    $effectiveWorkerId = if ($requestState -and $null -ne $requestState.WorkerId) { [Nullable[int]]([int]$requestState.WorkerId) } else { $WorkerId }
    $effectiveMessage = if ($requestState -and -not [string]::IsNullOrWhiteSpace([string]$requestState.Message)) {
        [string]$requestState.Message
    }
    elseif ($Status -eq 'Queued') { 'Waiting for an available Hyper-V pool worker.' }
    elseif ($null -ne $effectiveWorkerId) { "Assigned to pool worker $([int]$effectiveWorkerId); per-request lifecycle details are not yet available." }
    else { 'Assigned by the broker; per-request lifecycle details are not yet available.' }

    $queueDeadlineUtc = $createdUtc.AddSeconds($queueTimeoutSeconds)
    [ordered]@{
        RequestId = $requestId
        OwnershipStatus = $Status
        Status = $effectiveStatus
        Message = $effectiveMessage
        Position = $Position
        WorkerId = if ($null -ne $effectiveWorkerId) { [int]$effectiveWorkerId } else { $null }
        RequestStateUpdatedUtc = if ($requestState) { [string]$requestState.UpdatedUtc } else { $null }
        ApplicationProcessId = if ($requestState -and $null -ne $requestState.ApplicationProcessId) { [int]$requestState.ApplicationProcessId } else { $null }
        ApplicationStartedUtc = if ($requestState) { [string]$requestState.ApplicationStartedUtc } else { $null }
        GuestActionIndex = if ($requestState -and $null -ne $requestState.GuestActionIndex) { [int]$requestState.GuestActionIndex } else { $null }
        GuestActionType = if ($requestState) { [string]$requestState.GuestActionType } else { $null }
        CreatedUtc = $createdUtc.ToString('o')
        AgeSeconds = [Math]::Max(0, [Math]::Round(([DateTime]::UtcNow - $createdUtc).TotalSeconds, 1))
        QueueTimeoutSeconds = $queueTimeoutSeconds
        QueueDeadlineUtc = $queueDeadlineUtc.ToString('o')
        QueueSecondsRemaining = if ($Status -eq 'Queued') { [Math]::Max(0, [Math]::Round(($queueDeadlineUtc - [DateTime]::UtcNow).TotalSeconds, 1)) } else { $null }
        ExecutionTimeoutSeconds = $executionTimeoutSeconds
        ResultPath = Join-Path $resultsRoot $requestId
    }
}

$brokerState = Read-JsonSafe -Path $brokerStatePath
$poolState = Read-JsonSafe -Path $poolStatePath
$brokerProcessAlive = $false
if ($brokerState -and $null -ne $brokerState.ProcessId) {
    $brokerProcessAlive = $null -ne (Get-Process -Id ([int]$brokerState.ProcessId) -ErrorAction SilentlyContinue)
}
$heartbeatUtc = $null
if ($brokerState -and -not [string]::IsNullOrWhiteSpace([string]$brokerState.HeartbeatUtc)) {
    try {
        $heartbeatUtc = ([DateTime]$brokerState.HeartbeatUtc).ToUniversalTime()
    }
    catch {
    }
}
$processingFiles = @(Get-ChildItem -LiteralPath $processingRoot -Filter '*.json' -File | Sort-Object CreationTimeUtc, Name)
$queuedFiles = @(Get-ChildItem -LiteralPath $requestsRoot -Filter '*.json' -File | Sort-Object CreationTimeUtc, Name)
$processingIds = @($processingFiles | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
$workerRequestMap = @{}
if ($poolState -and $poolState.Workers) {
    foreach ($worker in @($poolState.Workers)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$worker.RequestId)) {
            $workerRequestMap[[string]$worker.RequestId] = [int]$worker.WorkerId
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$worker.RecoveryRequestId)) {
            $workerRequestMap[[string]$worker.RecoveryRequestId] = [int]$worker.WorkerId
        }
    }
}
$orphanedProcessing = $processingFiles.Count -gt 0 -and
    [string]$brokerState.Status -ne 'RecoveringQueue' -and
    @($processingIds | Where-Object { -not $workerRequestMap.ContainsKey($_) }).Count -gt 0
$jobs = @()
$poolMaxWorkers = if ($poolState -and $poolState.MaxWorkers) { [int]$poolState.MaxWorkers } else { 1 }
$poolWorkers = if ($poolState) { @($poolState.Workers) } else { @() }
$poolLeasedCount = @($poolWorkers | Where-Object Status -in @('Leased', 'RunCompleted')).Count
$poolWarmAhead = if ($poolState -and $poolState.WarmAhead) { [int]$poolState.WarmAhead } else { 1 }
$poolRequiredWarmSpareCount = if ($poolLeasedCount -gt 0) {
    [Math]::Min([Math]::Max(1, $poolWarmAhead), [Math]::Max(0, $poolMaxWorkers - $poolLeasedCount))
}
else { 0 }
$poolReadyWarmSpareCount = @($poolWorkers | Where-Object { $_.Status -eq 'Ready' -and [bool]$_.OsClean }).Count
$poolWarmSparePotentialCount = @($poolWorkers | Where-Object {
    ($_.Status -eq 'Ready' -and [bool]$_.OsClean) -or
    $_.Status -in @('Starting', 'StartQueued', 'Recycling', 'RecycleQueued')
}).Count
$poolWarmSpareInvariantSatisfied = $poolWarmSparePotentialCount -ge $poolRequiredWarmSpareCount
$maintenanceActive = (Test-Path -LiteralPath $maintenancePath -PathType Leaf) -or [bool]($poolState -and $poolState.MaintenanceActive)
$warmSparePolicyApplicable = -not $maintenanceActive
$warmSpareInvariantViolation = $warmSparePolicyApplicable -and -not $poolWarmSpareInvariantSatisfied

foreach ($processingFile in $processingFiles) {
    $processingId = [IO.Path]::GetFileNameWithoutExtension($processingFile.Name)
    $workerId = if ($workerRequestMap.ContainsKey($processingId)) { [Nullable[int]]([int]$workerRequestMap[$processingId]) } else { $null }
    $jobs += Get-RequestDetails -File $processingFile -Status 'Claimed' -Position 0 -WorkerId $workerId
}
for ($index = 0; $index -lt $queuedFiles.Count; $index++) {
    $jobs += Get-RequestDetails -File $queuedFiles[$index] -Status 'Queued' -Position ($index + 1)
}

[ordered]@{
    BrokerStatus = if ($brokerState) { [string]$brokerState.Status } else { 'Unknown' }
    BrokerRequestId = if ($brokerState) { [string]$brokerState.RequestId } else { $null }
    BrokerHeartbeatUtc = if ($brokerState) { [string]$brokerState.HeartbeatUtc } else { $null }
    BrokerHeartbeatAgeSeconds = if ($heartbeatUtc) { [Math]::Max(0, [Math]::Round(([DateTime]::UtcNow - $heartbeatUtc).TotalSeconds, 1)) } else { $null }
    BrokerProcessAlive = $brokerProcessAlive
    # Some Hyper-V operations are synchronously blocking. Distinguish a stale
    # progress heartbeat from a dead broker process instead of conflating them.
    BrokerHeartbeatStale = $null -eq $heartbeatUtc -or ([DateTime]::UtcNow - $heartbeatUtc).TotalSeconds -ge 45
    BrokerHealthy = $brokerProcessAlive -and $null -ne $heartbeatUtc -and ([DateTime]::UtcNow - $heartbeatUtc).TotalSeconds -lt 300
    ActiveCount = $processingFiles.Count
    QueueDepth = $queuedFiles.Count
    OrphanedProcessing = $orphanedProcessing
    PoolMaxWorkers = $poolMaxWorkers
    PoolRunningCount = if ($poolState) { [int]$poolState.RunningCount } else { $null }
    PoolReadyCount = if ($poolState) { [int]$poolState.ReadyCount } else { $null }
    PoolLeasedCount = $poolLeasedCount
    PoolWarmAhead = $poolWarmAhead
    PoolRequiredWarmSpareCount = $poolRequiredWarmSpareCount
    PoolReadyWarmSpareCount = $poolReadyWarmSpareCount
    PoolWarmSparePotentialCount = $poolWarmSparePotentialCount
    PoolWarmSpareInvariantSatisfied = $poolWarmSpareInvariantSatisfied
    MaintenanceActive = [bool]$maintenanceActive
    WarmSparePolicyApplicable = [bool]$warmSparePolicyApplicable
    WarmSpareInvariantViolation = [bool]$warmSpareInvariantViolation
    PoolWorkers = if ($poolState) { @($poolState.Workers) } else { @() }
    InvariantViolation = $processingFiles.Count -gt $poolMaxWorkers -or $orphanedProcessing -or $warmSpareInvariantViolation
    Jobs = @($jobs)
} | ConvertTo-Json -Depth 8
