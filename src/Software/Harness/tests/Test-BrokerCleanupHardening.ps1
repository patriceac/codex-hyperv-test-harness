[CmdletBinding()]
param(
    [string] $SourceRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent $PSScriptRoot
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Get-FunctionExtent {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $tokens = $null
    $parseIssues = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseIssues)
    if ($parseIssues.Count -gt 0) { throw "$Path has a parse error: $($parseIssues[0].Message)" }
    $definition = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name in $Path" }
    $definition.Extent.Text
}

$hostPath = Join-Path $SourceRoot 'HostBroker.ps1'
$poolPath = Join-Path $SourceRoot 'PoolBroker.ps1'
$lifecyclePath = Join-Path $SourceRoot 'PoolLifecycle.ps1'
$hostText = Get-Content -Raw -LiteralPath $hostPath
$poolText = Get-Content -Raw -LiteralPath $poolPath
$lifecycleText = Get-Content -Raw -LiteralPath $lifecyclePath
$invokeGuestRequest = Get-FunctionExtent -Path $hostPath -Name 'Invoke-GuestRequest'
$scenarios = New-Object 'Collections.Generic.List[string]'

foreach ($path in @($hostPath, $poolPath, $lifecyclePath, $PSCommandPath)) {
    $tokens = $null
    $parseIssues = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseIssues)
    Assert-True ($parseIssues.Count -eq 0) "PowerShell parse failure in $path"
}
$scenarios.Add('owned-scripts-parse')

$requestRecoveryCall = [regex]::Matches($hostText, 'Recover-OrphanedRequestNetworkResources\s+-BrokerRoot\s+\$BrokerRoot(?:\s+-ExcludeRequestId\s+\$requestId)?')
Assert-True ($requestRecoveryCall.Count -ge 1) 'Host broker no longer performs request-network recovery.'
Assert-True (-not ($requestRecoveryCall | Where-Object Value -match 'ExcludeRequestId')) 'Per-request network recovery still excludes stale leases sharing RequestId.'
$scenarios.Add('same-request-network-lease-is-recoverable')

$startPoolRequest = Get-FunctionExtent -Path $poolPath -Name 'Start-PoolRequest'
Assert-True ($startPoolRequest.Contains('$hostWorkerStarted = $true')) 'HostWorker start identity is not retained for post-launch failures.'
Assert-True ($startPoolRequest.Contains('Stop-PoolProcessAndWait -Process $process')) 'A HostWorker state-update failure does not stop and wait the process.'
Assert-True ($startPoolRequest.Contains("Status = 'RunCompleted'")) 'A post-launch state-update failure does not retain a terminal lease for recycle.'
Assert-True ($startPoolRequest.Contains('Complete-PoolWorkerRun -State $recoveryState -RecycleBeforeRequeue')) 'A retained post-launch lease is not routed through recycle-before-requeue recovery.'
Assert-True ($startPoolRequest.Contains('# Deliberately do not move the processing file or mark Ready here.')) 'The post-launch failure path can still requeue or mark the worker Ready immediately.'
$recoveryMarker = Get-FunctionExtent -Path $poolPath -Name 'Mark-PoolRequestRecoveryPending'
$recoveryReconciler = Get-FunctionExtent -Path $poolPath -Name 'Reconcile-PoolRequestRecoveryMarkers'
Assert-True ($startPoolRequest.Contains('Mark-PoolRequestRecoveryPending') -and $recoveryMarker.Contains('PoolRecoveryPending')) 'A mismatched or unreadable post-launch state has no durable Processing recovery marker.'
Assert-True ($recoveryMarker.Contains('Durable = [bool]($markerWritten -or $requestWritten)') -and $startPoolRequest.Contains('if (-not $recoveryMark.Durable)')) 'A dual-write recovery failure is not surfaced instead of silently stranding Processing.'
Assert-True ($recoveryReconciler.Contains('PoolRecoveryPending') -and $recoveryReconciler.Contains('if (-not $state)') -and $recoveryReconciler.Contains('if ($hasCurrentOwner -and -not $sameOwner)') -and $recoveryReconciler.Contains('Move-Item -LiteralPath $processingFile')) 'Post-launch recovery does not scan flagged Processing files, fail closed on unreadable state, or protect another owner before reconciliation.'
$completePoolWorkerRun = Get-FunctionExtent -Path $poolPath -Name 'Complete-PoolWorkerRun'
Assert-True ($completePoolWorkerRun.Contains('[switch] $RecycleBeforeRequeue') -and $completePoolWorkerRun.Contains('RecoveryRequestId = $requestId') -and $completePoolWorkerRun.Contains("Status 'RetryPendingRecycle'")) 'Recycle-before-requeue recovery does not retain Processing until lifecycle reconciliation.'
$scenarios.Add('host-worker-state-failure-retains-recycle-lease')

$stoppingVmBlockStart = $invokeGuestRequest.IndexOf('if ($Request.StopAfter)', [StringComparison]::Ordinal)
$stoppingVmBlockEnd = $invokeGuestRequest.IndexOf('if ($hostInputShareRuntime)', $stoppingVmBlockStart, [StringComparison]::Ordinal)
Assert-True ($stoppingVmBlockStart -ge 0 -and $stoppingVmBlockEnd -gt $stoppingVmBlockStart) 'The HostBroker finally block lost its StopAfter cleanup section.'
$stoppingVmBlock = $invokeGuestRequest.Substring($stoppingVmBlockStart, $stoppingVmBlockEnd - $stoppingVmBlockStart)
Assert-True ($stoppingVmBlock -match '(?s)try\s*\{\s*Write-RequestState\b.*?\}\s*catch\s*\{\s*\$evidenceWarnings\.Add') 'StoppingVm request-state publication is not advisory.'
Assert-True ($stoppingVmBlock.IndexOf('Write-RequestState', [StringComparison]::Ordinal) -lt $stoppingVmBlock.IndexOf('Stop-TestVm', [StringComparison]::Ordinal)) 'StoppingVm status publication was moved after the VM stop unexpectedly.'
Assert-True ($stoppingVmBlock.Contains('Could not publish StoppingVm broker state')) 'StoppingVm broker-state publication failure is not captured.'
$scenarios.Add('stopping-vm-status-failure-cannot-skip-cleanup')

$lifecycleBody = Get-FunctionExtent -Path $lifecyclePath -Name 'Reset-WorkerNetworkIsolation'
$preStopReset = $lifecycleText.IndexOf('Reset-WorkerNetworkIsolation', [StringComparison]::Ordinal)
$stopIndex = $lifecycleText.IndexOf('Stop-TestVm -VmName $vmName -Immediate', [StringComparison]::Ordinal)
$catchIndex = $lifecycleText.IndexOf('$failureMessage = $_.Exception.Message', [StringComparison]::Ordinal)
$catchReset = $lifecycleText.IndexOf('Reset-WorkerNetworkIsolation', $catchIndex, [StringComparison]::Ordinal)
Assert-True ($lifecycleBody.Contains('Recover-OrphanedRequestNetworkResources') -and $lifecycleBody.Contains('Remove-ManagedRequestNetworkAdapters')) 'Lifecycle reset does not recover leases and remove managed adapters.'
Assert-True ($preStopReset -ge 0 -and $stopIndex -gt $preStopReset) 'Lifecycle stop does not disconnect request networking before stopping the VM.'
Assert-True ($catchIndex -ge 0 -and $catchReset -gt $catchIndex) 'Lifecycle stop-failure recovery does not repeat network reset.'
Assert-True ($lifecycleText.IndexOf('$stopSucceeded = $true', $catchIndex, [StringComparison]::Ordinal) -ge 0 -and $lifecycleText.IndexOf('if ($initialNetworkResetFailed -and $stopSucceeded)', $catchIndex, [StringComparison]::Ordinal) -gt $lifecycleText.IndexOf('$stopSucceeded = $true', $catchIndex, [StringComparison]::Ordinal)) 'Lifecycle recovery does not retry network reset immediately after a successful stop.'
$scenarios.Add('lifecycle-reset-precedes-stop-and-repeats-on-failure')

$finallyStart = $invokeGuestRequest.LastIndexOf('finally {', [StringComparison]::Ordinal)
$networkCleanupIndex = $invokeGuestRequest.IndexOf('Remove-RequestNetworkRuntime -Runtime $requestNetworkRuntime', $finallyStart, [StringComparison]::Ordinal)
$networkStatusIndex = $invokeGuestRequest.IndexOf("Write-BrokerState -Status 'CleaningNetwork'", $finallyStart, [StringComparison]::Ordinal)
Assert-True ($networkCleanupIndex -ge 0 -and $networkStatusIndex -gt $networkCleanupIndex) 'Request-network cleanup status is written before network revocation.'
Assert-True ($hostText.Contains('Guest-job completion is the network-use boundary. Revoke the')) 'The broker does not disconnect request networking before evidence collection.'
Assert-True ($hostText.Contains('$evidenceSnapshotSucceeded = $false') -and $hostText.Contains('$evidenceTransferSucceeded = $false') -and $hostText.Contains('$evidenceValidationSucceeded = $false')) 'Evidence lifecycle fields are not pessimistically initialized.'
Assert-True ($hostText.Contains('$finalNetworkInventorySucceeded = $false') -and $hostText.Contains('FinalAllAdaptersDisconnected = [bool]$finalNetworkInventorySucceeded')) 'Failed network inventory can still be reported as final disconnection.'
$scenarios.Add('cleanup-precedes-status-and-failed-inventory-stays-unknown')

$failureKindIndex = $invokeGuestRequest.IndexOf('if ($cancelled)', $finallyStart, [StringComparison]::Ordinal)
$timeoutKindIndex = $invokeGuestRequest.IndexOf('elseif ($executionTimedOut)', $failureKindIndex, [StringComparison]::Ordinal)
$cleanupKindIndex = $invokeGuestRequest.IndexOf('elseif ($cleanupFailureObserved)', $timeoutKindIndex, [StringComparison]::Ordinal)
Assert-True ($failureKindIndex -gt 0 -and $timeoutKindIndex -gt $failureKindIndex -and $cleanupKindIndex -gt $timeoutKindIndex) 'Typed cancellation/timeout failure kinds can be overwritten by cleanup classification.'
Assert-True ($hostText.Contains('CleanupFailure = [bool]$cleanupFailureObserved')) 'Cleanup failure is not surfaced in broker result evidence.'
$scenarios.Add('typed-failure-kind-survives-cleanup-failure')

. $poolPath
$nullResult = Stop-PoolProcessAndWait -Process $null
Assert-True ([bool]$nullResult.Stopped -and $null -eq $nullResult.Error) 'The process cleanup helper did not treat an absent process as already stopped.'
$scenarios.Add('process-cleanup-helper-is-idempotent')

$recycleRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-recycle-before-requeue-' + [Guid]::NewGuid().ToString('N'))
$script:BrokerRoot = $recycleRoot
$script:processingPath = Join-Path $recycleRoot 'Processing'
$script:requestPath = Join-Path $recycleRoot 'Requests'
$script:resultsPath = Join-Path $recycleRoot 'Results'
$script:archivePath = Join-Path $recycleRoot 'Archive'
$script:cancellationPath = Join-Path $recycleRoot 'Cancellations'
$script:Config = [pscustomobject]@{ PoolIdleTimeoutSeconds = 600 }
foreach ($path in @($script:processingPath, $script:requestPath, $script:resultsPath, $script:archivePath, $script:cancellationPath)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}
$recycleRequestId = 'synthetic-recycle-before-requeue'
$recycleProcessingFile = Join-Path $script:processingPath ($recycleRequestId + '.json')
[ordered]@{
    RequestId = $recycleRequestId
    CreatedUtc = [DateTime]::UtcNow.ToString('o')
    PendingInfrastructureRetry = $true
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recycleProcessingFile -Encoding UTF8
$script:recycleState = [pscustomobject][ordered]@{
    WorkerId = 1
    Status = 'RunCompleted'
    RequestId = $recycleRequestId
    RecoveryRequestId = $null
    OperationId = 'synthetic-operation'
    ProcessId = $null
    ProcessStartUtc = $null
    LastReleasedUtc = [DateTime]::UtcNow.ToString('o')
}
function Get-PoolIdleDeadline {
    param($Config, [DateTime] $FromUtc)
    $FromUtc.AddMinutes(10)
}
function Write-PoolJsonAtomic {
    param([string] $Path, $Value)
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Update-PoolWorkerState {
    param([string] $BrokerRoot, [int] $WorkerId, [Collections.IDictionary] $Patch)
    foreach ($key in $Patch.Keys) {
        if ($script:recycleState.PSObject.Properties.Name -contains [string]$key) {
            $script:recycleState.([string]$key) = $Patch[$key]
        }
        else {
            $script:recycleState | Add-Member -NotePropertyName ([string]$key) -NotePropertyValue $Patch[$key]
        }
    }
    $script:recycleState
}
function Read-PoolWorkerState { param([string] $BrokerRoot, [int] $WorkerId) $script:recycleState }
function Set-PoolLifecycleQueued {
    param($State, [string] $Mode, [string] $IdleDeadlineUtc)
    $State.Status = $Mode + 'Queued'
}
function Write-RequestState {
    param([string] $ResultRoot, [string] $RequestId, [string] $Status, [string] $Message, [DateTime] $CreatedUtc)
    $script:recycleRequestStatus = $Status
}
try {
    Complete-PoolWorkerRun -State $script:recycleState -RecycleBeforeRequeue
    $recycleQueuedFile = Join-Path $script:requestPath ($recycleRequestId + '.json')
    $recycleQueuedRequest = Get-Content -Raw -LiteralPath $recycleProcessingFile | ConvertFrom-Json
    Assert-True ((Test-Path -LiteralPath $recycleProcessingFile -PathType Leaf) -and (-not (Test-Path -LiteralPath $recycleQueuedFile -PathType Leaf))) 'Recycle-before-requeue moved the request out of Processing too early.'
    Assert-True (-not [bool]$recycleQueuedRequest.PendingInfrastructureRetry) 'Recycle-before-requeue did not consume the bounded retry marker.'
    Assert-True ($script:recycleState.RecoveryRequestId -eq $recycleRequestId -and $script:recycleState.Status -eq 'RecycleQueued') 'Recycle-before-requeue did not retain the recovery lease until lifecycle reconciliation.'
    Assert-True ($script:recycleRequestStatus -eq 'RetryPendingRecycle') 'Recycle-before-requeue did not publish its pending lifecycle status.'
}
finally {
    Remove-Item -LiteralPath $recycleRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$scenarios.Add('recycle-before-requeue-retains-processing-file')

# Exercise both post-launch state races through Start-PoolRequest itself. The
# synthetic updater returns null for the expected launch-state write, then the
# readback either reports another owner or throws as an unreadable state file.
# No VM, broker task, or network resource is touched by these scenarios.
function Get-BoundedTimeout {
    param($Value, [int] $Default, [int] $Minimum, [int] $Maximum)
    $Default
}
function Start-PoolProcess {
    param([string] $ScriptPath, [string[]] $ScriptArguments)
    [pscustomobject]@{ Id = 4242; StartTime = [DateTime]::UtcNow }
}
function Stop-PoolProcessAndWait {
    param($Process, [int] $ProcessId, [int] $WaitMilliseconds)
    $script:postLaunchStopCalls++
    [pscustomobject]@{ Stopped = $true; Error = $null }
}
function Write-RequestState {
    param($ResultRoot, $RequestId, $Status, $Message, $CreatedUtc, $ClaimedUtc, $ExecutionDeadlineUtc, $WorkerId)
    $script:postLaunchStatuses.Add([string]$Status)
}
function Update-PoolWorkerState {
    param(
        [string] $BrokerRoot,
        [int] $WorkerId,
        [Collections.IDictionary] $Patch,
        [string] $ExpectedOperationId,
        [string] $ExpectedRequestId,
        [switch] $RequireExpectation
    )
    $script:postLaunchPatches.Add([pscustomobject]@{
        ExpectedOperationId = $ExpectedOperationId
        ExpectedRequestId = $ExpectedRequestId
        Patch = $Patch
    })
    if ($RequireExpectation) { return $null }
    [pscustomobject][ordered]@{
        WorkerId = $WorkerId
        VmName = 'Synthetic-01'
        Status = 'Leased'
        RequestId = $script:postLaunchRequestId
        OperationId = 'synthetic-operation'
        ProcessId = $null
        ProcessStartUtc = $null
        OsClean = $false
    }
}
function Read-PoolWorkerState {
    param([string] $BrokerRoot, [int] $WorkerId)
    if ($script:postLaunchStateMode -eq 'unreadable') { throw 'synthetic unreadable latest worker state' }
    if ($script:postLaunchStateMode -eq 'safe') {
        return [pscustomobject]@{
            WorkerId = $WorkerId
            VmName = 'Synthetic-01'
            Status = 'Ready'
            RequestId = $null
            OperationId = $null
            ProcessId = $null
            ProcessStartUtc = $null
            OsClean = $true
        }
    }
    [pscustomobject]@{
        WorkerId = $WorkerId
        VmName = 'Synthetic-01'
        Status = 'Leased'
        RequestId = 'another-request'
        OperationId = 'another-operation'
        ProcessId = 9898
        ProcessStartUtc = [DateTime]::UtcNow.ToString('o')
        OsClean = $false
    }
}

foreach ($stateMode in @('mismatched', 'unreadable')) {
    $postLaunchRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-post-launch-recovery-' + $stateMode + '-' + [Guid]::NewGuid().ToString('N'))
    $script:BrokerRoot = $postLaunchRoot
    $script:requestPath = Join-Path $postLaunchRoot 'Requests'
    $script:processingPath = Join-Path $postLaunchRoot 'Processing'
    $script:resultsPath = Join-Path $postLaunchRoot 'Results'
    $script:archivePath = Join-Path $postLaunchRoot 'Archive'
    $script:cancellationPath = Join-Path $postLaunchRoot 'Cancellations'
    $script:Config = [pscustomobject]@{ PoolIdleTimeoutSeconds = 600 }
    $script:postLaunchRequestId = 'post-launch-' + $stateMode
    $script:postLaunchStateMode = $stateMode
    $script:postLaunchStopCalls = 0
    $script:postLaunchStatuses = New-Object 'Collections.Generic.List[string]'
    $script:postLaunchPatches = New-Object 'Collections.Generic.List[object]'
    foreach ($path in @($script:requestPath, $script:processingPath, $script:resultsPath, $script:archivePath, $script:cancellationPath)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    $postLaunchRequestFile = Join-Path $script:requestPath ($script:postLaunchRequestId + '.json')
    [ordered]@{
        RequestId = $script:postLaunchRequestId
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        ExecutionTimeoutSeconds = 120
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $postLaunchRequestFile -Encoding UTF8
    try {
        $postLaunchResult = Start-PoolRequest -State ([pscustomobject]@{ WorkerId = 1; VmName = 'Synthetic-01'; OsClean = $true }) -RequestFile (Get-Item -LiteralPath $postLaunchRequestFile)
        Assert-True (-not [bool]$postLaunchResult) "Post-launch $stateMode state mismatch unexpectedly reported success."
        $postLaunchProcessingFile = Join-Path $script:processingPath ($script:postLaunchRequestId + '.json')
        $postLaunchMarkerFile = Join-Path $postLaunchRoot ('State\PoolRequestRecovery\' + $script:postLaunchRequestId + '.json')
        Assert-True ((Test-Path -LiteralPath $postLaunchProcessingFile -PathType Leaf) -and (Test-Path -LiteralPath $postLaunchMarkerFile -PathType Leaf)) "Post-launch $stateMode state did not retain a durable Processing recovery marker."
        $postLaunchRequest = Get-Content -Raw -LiteralPath $postLaunchProcessingFile | ConvertFrom-Json
        Assert-True ([bool]$postLaunchRequest.PoolRecoveryPending) "Post-launch $stateMode state did not mark the Processing request for recovery."
        Assert-True ($script:postLaunchStopCalls -eq 1) "Post-launch $stateMode state did not stop and wait the launched HostWorker."
        Assert-True (-not (@($script:postLaunchPatches | Where-Object { $_.Patch -is [Collections.IDictionary] -and $_.Patch.Contains('Status') -and [string]$_.Patch['Status'] -eq 'Ready' }).Count)) "Post-launch $stateMode state clobbered a worker owned by another operation."
        $scenarios.Add("post-launch-$stateMode-state-is-recoverable")
    }
    finally {
        Remove-Item -LiteralPath $postLaunchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Recovery-write matrix: a marker failure must still be recoverable from the
# Processing flag; a Processing-write failure must still be recoverable from
# the marker; and losing both authorities must surface as the broker crash path.
function Write-PoolJsonAtomic {
    param([string] $Path, $Value)
    $normalizedPath = $Path.Replace('/', '\')
    if ($script:recoveryWriteMode -eq 'marker-fails' -and $normalizedPath -like '*\PoolRequestRecovery\*') {
        throw 'synthetic marker write failure'
    }
    if ($script:recoveryWriteMode -eq 'request-fails' -and $normalizedPath -like '*\Processing\*') {
        throw 'synthetic Processing write failure'
    }
    if ($script:recoveryWriteMode -eq 'both-fail' -and ($normalizedPath -like '*\PoolRequestRecovery\*' -or $normalizedPath -like '*\Processing\*')) {
        throw 'synthetic dual recovery write failure'
    }
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-RecoveryMatrixRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('codex-recovery-write-matrix-' + [Guid]::NewGuid().ToString('N'))
    $script:BrokerRoot = $root
    $script:requestPath = Join-Path $root 'Requests'
    $script:processingPath = Join-Path $root 'Processing'
    $script:resultsPath = Join-Path $root 'Results'
    $script:archivePath = Join-Path $root 'Archive'
    $script:cancellationPath = Join-Path $root 'Cancellations'
    foreach ($path in @($script:requestPath, $script:processingPath, $script:resultsPath, $script:archivePath, $script:cancellationPath)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    $root
}

$matrixRoot = New-RecoveryMatrixRoot
$matrixRequestId = 'marker-write-failure-request'
$matrixProcessingFile = Join-Path $script:processingPath ($matrixRequestId + '.json')
[ordered]@{
    RequestId = $matrixRequestId
    CreatedUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $matrixProcessingFile -Encoding UTF8
$script:postLaunchStateMode = 'mismatched'
$script:recoveryWriteMode = 'marker-fails'
try {
    $markerFailure = Mark-PoolRequestRecoveryPending -RequestId $matrixRequestId -WorkerId 1 -OperationId 'old-operation' -VmName 'Synthetic-01' -ProcessingFile $matrixProcessingFile -ResultRoot (Join-Path $script:resultsPath $matrixRequestId) -FailureMessage 'synthetic marker failure'
    Assert-True (-not [bool]$markerFailure.MarkerWritten -and [bool]$markerFailure.RequestWritten -and [bool]$markerFailure.Durable) 'Marker-write failure did not preserve the Processing recovery authority.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:BrokerRoot ('State\PoolRequestRecovery\' + $matrixRequestId + '.json')) -PathType Leaf)) 'Synthetic marker-write failure unexpectedly created the marker.'

    # A newer owner must be left untouched while the request remains marked.
    Reconcile-PoolRequestRecoveryMarkers
    Assert-True ((Test-Path -LiteralPath $matrixProcessingFile -PathType Leaf) -and (-not (Test-Path -LiteralPath (Join-Path $script:requestPath ($matrixRequestId + '.json')) -PathType Leaf))) 'Flagged Processing recovery clobbered a newer worker owner.'

    # Once the worker is safe, the flagged Processing payload is discovered and
    # requeued even though marker reconstruction continues to fail.
    $script:postLaunchStateMode = 'safe'
    Reconcile-PoolRequestRecoveryMarkers
    $matrixQueuedFile = Join-Path $script:requestPath ($matrixRequestId + '.json')
    Assert-True ((Test-Path -LiteralPath $matrixQueuedFile -PathType Leaf) -and (-not (Test-Path -LiteralPath $matrixProcessingFile -PathType Leaf))) 'Flagged Processing recovery was skipped after the worker became safe.'
    $scenarios.Add('marker-write-failure-processing-flag-reconciles-safely')
}
finally {
    Remove-Item -LiteralPath $matrixRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$inverseRoot = New-RecoveryMatrixRoot
$inverseRequestId = 'processing-write-failure-request'
$inverseProcessingFile = Join-Path $script:processingPath ($inverseRequestId + '.json')
[ordered]@{ RequestId = $inverseRequestId; CreatedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inverseProcessingFile -Encoding UTF8
$script:postLaunchStateMode = 'safe'
$script:recoveryWriteMode = 'request-fails'
try {
    $inverse = Mark-PoolRequestRecoveryPending -RequestId $inverseRequestId -WorkerId 1 -OperationId 'inverse-operation' -VmName 'Synthetic-01' -ProcessingFile $inverseProcessingFile -ResultRoot (Join-Path $script:resultsPath $inverseRequestId) -FailureMessage 'synthetic Processing failure'
    Assert-True ([bool]$inverse.MarkerWritten -and -not [bool]$inverse.RequestWritten -and [bool]$inverse.Durable) ("Processing-write failure did not preserve the marker recovery authority: marker=$($inverse.MarkerWritten), request=$($inverse.RequestWritten), durable=$($inverse.Durable).")
    Reconcile-PoolRequestRecoveryMarkers
    Assert-True ((Test-Path -LiteralPath $inverseProcessingFile -PathType Leaf) -and (-not (Test-Path -LiteralPath (Join-Path $script:requestPath ($inverseRequestId + '.json')) -PathType Leaf))) 'Marker-only recovery did not fail closed while Processing writes remained unavailable.'
    $script:recoveryWriteMode = 'none'
    Reconcile-PoolRequestRecoveryMarkers
    Assert-True (Test-Path -LiteralPath (Join-Path $script:requestPath ($inverseRequestId + '.json')) -PathType Leaf) 'Marker-only recovery was not reconciled after Processing writes recovered.'
    $scenarios.Add('processing-write-failure-marker-reconciles-safely')
}
finally {
    Remove-Item -LiteralPath $inverseRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$dualRoot = New-RecoveryMatrixRoot
$dualRequestId = 'dual-recovery-write-failure-request'
$dualRequestFile = Join-Path $script:requestPath ($dualRequestId + '.json')
[ordered]@{ RequestId = $dualRequestId; CreatedUtc = [DateTime]::UtcNow.ToString('o'); ExecutionTimeoutSeconds = 120 } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $dualRequestFile -Encoding UTF8
$script:postLaunchRequestId = $dualRequestId
$script:postLaunchStateMode = 'mismatched'
$script:recoveryWriteMode = 'both-fail'
try {
    $dualFailed = $false
    try {
        Start-PoolRequest -State ([pscustomobject]@{ WorkerId = 1; VmName = 'Synthetic-01'; OsClean = $true }) -RequestFile (Get-Item -LiteralPath $dualRequestFile) | Out-Null
    }
    catch {
        $dualFailed = $true
    }
    Assert-True $dualFailed 'A dual recovery-write failure did not surface the broker crash/restart path.'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:processingPath ($dualRequestId + '.json')) -PathType Leaf) 'Dual recovery-write failure did not leave the request inspectable in Processing.'
    $scenarios.Add('dual-recovery-write-failure-surfaces')
}
finally {
    Remove-Item -LiteralPath $dualRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
