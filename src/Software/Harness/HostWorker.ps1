[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BrokerRoot,
    [Parameter(Mandatory = $true)] [ValidateRange(1, 64)] [int] $WorkerId,
    [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')] [string] $RequestId,
    [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Fa-f0-9]{32}$')] [string] $OperationId,
    [Parameter(Mandatory = $true)] [string] $ClaimedUtc
)

$ErrorActionPreference = 'Stop'
$global:CodexBrokerStateOverridePath = Join-Path $BrokerRoot ('State\WorkerProgress\request-{0:D2}.json' -f $WorkerId)

. (Join-Path $PSScriptRoot 'PoolCommon.ps1')
. (Join-Path $PSScriptRoot 'HostBroker.ps1') -BrokerRoot $BrokerRoot -LibraryOnly

$config = Get-Content -Raw -LiteralPath (Join-Path $BrokerRoot 'Private\config.json') | ConvertFrom-Json
$worker = Get-PoolWorkerDefinition -Config $config -WorkerId $WorkerId
$processingFile = Join-Path (Join-Path $BrokerRoot 'Processing') ($RequestId + '.json')
$resultRoot = Join-Path (Join-Path $BrokerRoot 'Results') $RequestId
$exitCode = 0
$retryRequested = $false

function Test-WorkerCaptureRetryAllowed {
    param(
        [Parameter(Mandatory = $true)] $AttemptResult,
        [Parameter(Mandatory = $true)] [int] $RetryCount,
        [Parameter(Mandatory = $true)] [bool] $CancellationRequested
    )

    -not [bool]$AttemptResult.Success -and
        [string]$AttemptResult.FailureKind -eq 'CaptureInfrastructure' -and
        $RetryCount -lt 1 -and
        -not $CancellationRequested
}

function Publish-WorkerAttemptResult {
    param(
        [Parameter(Mandatory = $true)] [string] $AttemptRoot,
        [Parameter(Mandatory = $true)] [string] $DestinationRoot,
        [hashtable] $TerminalStateParameters
    )

    $attemptBrokerResult = Join-Path $AttemptRoot 'broker-result.json'
    if (-not (Test-Path -LiteralPath $attemptBrokerResult -PathType Leaf)) {
        throw 'The worker attempt did not publish broker-result.json.'
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $AttemptRoot -Force | Where-Object Name -ne 'broker-result.json')) {
        Move-Item -LiteralPath $item.FullName -Destination (Join-Path $DestinationRoot $item.Name) -Force
    }
    if ($TerminalStateParameters) {
        Write-RequestState @TerminalStateParameters
    }
    # The client treats this filename as the terminal publication marker, so it
    # must be promoted only after every other evidence file is in place.
    Move-Item -LiteralPath $attemptBrokerResult -Destination (Join-Path $DestinationRoot 'broker-result.json') -Force
    Remove-Item -LiteralPath $AttemptRoot -Force -ErrorAction SilentlyContinue
}

function Set-WorkerCaptureRetry {
    param(
        [Parameter(Mandatory = $true)] $Request,
        [Parameter(Mandatory = $true)] $AttemptResult,
        [Parameter(Mandatory = $true)] [string] $AttemptRoot
    )

    $retryCount = if ($null -ne $Request.InfrastructureRetryCount) { [int]$Request.InfrastructureRetryCount } else { 0 }
    $history = @($Request.InfrastructureRetryHistory)
    $history += [pscustomobject][ordered]@{
        Attempt = $retryCount + 1
        WorkerId = $WorkerId
        VmName = [string]$worker.VmName
        FailureKind = [string]$AttemptResult.FailureKind
        FailedUtc = [DateTime]::UtcNow.ToString('o')
        AttemptResultPath = $AttemptRoot
    }
    $Request | Add-Member -NotePropertyName InfrastructureRetryCount -NotePropertyValue ($retryCount + 1) -Force
    $Request | Add-Member -NotePropertyName InfrastructureRetryHistory -NotePropertyValue $history -Force
    $Request | Add-Member -NotePropertyName PendingInfrastructureRetry -NotePropertyValue $true -Force
    $Request | Add-Member -NotePropertyName LastInfrastructureFailureKind -NotePropertyValue ([string]$AttemptResult.FailureKind) -Force
    $Request | Add-Member -NotePropertyName LastInfrastructureFailureUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Write-JsonAtomic -Path $processingFile -Value $Request
}

$state = Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $WorkerId -ExpectedOperationId $OperationId -ExpectedRequestId $RequestId -RequireExpectation -Patch ([ordered]@{
    Status = 'Leased'
    VmName = [string]$worker.VmName
    ProcessId = $PID
    ProcessStartUtc = ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o'))
    OsClean = $false
    LastError = $null
})
if (-not $state) {
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $processingFile -PathType Leaf)) {
        throw "Processing request is missing: $processingFile"
    }
    New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
    $request = Get-Content -Raw -LiteralPath $processingFile | ConvertFrom-Json
    if (-not [string]::Equals([string]$request.RequestId, $RequestId, [StringComparison]::Ordinal)) {
        throw 'The processing request ID does not match the worker assignment.'
    }

    $workerConfig = $config | Select-Object *
    $workerConfig | Add-Member -NotePropertyName VmName -NotePropertyValue ([string]$worker.VmName) -Force
    $workerConfig | Add-Member -NotePropertyName PoolWorkerId -NotePropertyValue $WorkerId -Force
    $workerConfig | Add-Member -NotePropertyName PoolOperationId -NotePropertyValue $OperationId -Force
    $retryCount = if ($null -ne $request.InfrastructureRetryCount) { [int]$request.InfrastructureRetryCount } else { 0 }
    $attemptNumber = $retryCount + 1
    $attemptRoot = Join-Path $resultRoot (Join-Path 'Attempts' (('attempt-{0:D2}-worker-{1:D2}-{2}' -f $attemptNumber, $WorkerId, $OperationId.Substring(0, 8))))
    New-Item -ItemType Directory -Force -Path $attemptRoot | Out-Null
    $attemptError = $null
    try {
        Invoke-GuestRequest -Request $request -ResultRoot $attemptRoot -RequestStateRoot $resultRoot -Config $workerConfig -ClaimedUtc ([DateTime]::Parse($ClaimedUtc).ToUniversalTime())
    }
    catch {
        $attemptError = $_
    }

    $attemptBrokerPath = Join-Path $attemptRoot 'broker-result.json'
    if (-not (Test-Path -LiteralPath $attemptBrokerPath -PathType Leaf)) {
        if ($attemptError) { throw $attemptError }
        throw 'The guest request attempt ended without broker-result.json.'
    }
    $attemptResult = Get-Content -Raw -LiteralPath $attemptBrokerPath | ConvertFrom-Json
    $captureRetryAllowed = Test-WorkerCaptureRetryAllowed -AttemptResult $attemptResult -RetryCount $retryCount -CancellationRequested (Test-Path -LiteralPath (Join-Path (Join-Path $BrokerRoot 'Cancellations') ($RequestId + '.json')) -PathType Leaf)
    if ($captureRetryAllowed) {
        Set-WorkerCaptureRetry -Request $request -AttemptResult $attemptResult -AttemptRoot $attemptRoot
        Write-RequestState -ResultRoot $resultRoot -RequestId $RequestId -Status 'RetryPendingRecycle' -Message 'A transient capture failure will be replayed once on a clean pool worker.' -CreatedUtc ([DateTime]::Parse([string]$request.CreatedUtc).ToUniversalTime()) -ClaimedUtc ([DateTime]::Parse($ClaimedUtc).ToUniversalTime())
        $retryRequested = $true
        $exitCode = 1
    }
    else {
        $terminalStatus = if ([bool]$attemptResult.Success -and [bool]$attemptResult.TestEvaluated -and -not [bool]$attemptResult.TestPassed) {
            'TestFailed'
        }
        elseif ([bool]$attemptResult.Success) { 'Completed' }
        elseif ([bool]$attemptResult.Cancelled) { 'Cancelled' }
        elseif ([bool]$attemptResult.ExecutionTimedOut) { 'ExecutionTimedOut' }
        else { 'Failed' }
        $terminalMessage = if ($terminalStatus -eq 'Completed') {
            'Terminal result is ready; evidence collection and VM cleanup completed.'
        }
        elseif ($terminalStatus -eq 'TestFailed' -and $attemptResult.GuestResult -and -not [string]::IsNullOrWhiteSpace([string]$attemptResult.GuestResult.TestFailureMessage)) {
            [string]$attemptResult.GuestResult.TestFailureMessage
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$attemptResult.Error)) { [string]$attemptResult.Error }
        else { "Terminal result: $terminalStatus." }
        $terminalStateParameters = @{
            ResultRoot = $resultRoot
            RequestId = $RequestId
            Status = $terminalStatus
            Message = $terminalMessage
            CreatedUtc = [DateTime]::Parse([string]$request.CreatedUtc).ToUniversalTime()
            ClaimedUtc = [DateTime]::Parse($ClaimedUtc).ToUniversalTime()
            WorkerId = $WorkerId
        }
        Publish-WorkerAttemptResult -AttemptRoot $attemptRoot -DestinationRoot $resultRoot -TerminalStateParameters $terminalStateParameters
        if ($attemptError) { throw $attemptError }
    }
}
catch {
    $exitCode = 1
    $brokerResultPath = Join-Path $resultRoot 'broker-result.json'
    if (-not $retryRequested -and -not (Test-Path -LiteralPath $brokerResultPath -PathType Leaf)) {
        $vmFinalState = 'Unknown'
        try { $vmFinalState = [string](Get-VM -Name ([string]$worker.VmName)).State } catch { }
        $requestCreatedUtc = if ($request -and -not [string]::IsNullOrWhiteSpace([string]$request.CreatedUtc)) { [DateTime]::Parse([string]$request.CreatedUtc).ToUniversalTime() } else { $null }
        Write-RequestState -ResultRoot $resultRoot -RequestId $RequestId -Status 'Failed' -Message $_.Exception.Message -CreatedUtc $requestCreatedUtc -ClaimedUtc ([DateTime]::Parse($ClaimedUtc).ToUniversalTime()) -WorkerId $WorkerId
        Write-JsonAtomic -Path $brokerResultPath -Value ([ordered]@{
            RequestId = $RequestId
            Success = $false
            HarnessSucceeded = $false
            OverallSucceeded = $false
            TestEvaluated = $false
            TestPassed = $null
            FailureKind = 'Harness'
            Error = $_.Exception.Message
            FailureStage = 'WorkerProcess'
            ClaimedUtc = $ClaimedUtc
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
            VmName = [string]$worker.VmName
            VmFinalState = $vmFinalState
            PoolWorkerId = $WorkerId
            PoolWorkerRecyclePending = $true
        })
    }
}
finally {
    $releasedUtc = [DateTime]::UtcNow
    Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $WorkerId -ExpectedOperationId $OperationId -ExpectedRequestId $RequestId -RequireExpectation -Patch ([ordered]@{
        Status = 'RunCompleted'
        LastReleasedUtc = $releasedUtc.ToString('o')
        IdleDeadlineUtc = (Get-PoolIdleDeadline -Config $config -FromUtc $releasedUtc).ToString('o')
        LastError = if ($retryRequested) { 'A transient capture failure is pending one clean-worker replay.' } elseif ($exitCode -eq 0) { $null } else { 'The request worker exited with a failure.' }
    }) | Out-Null
}

exit $exitCode
