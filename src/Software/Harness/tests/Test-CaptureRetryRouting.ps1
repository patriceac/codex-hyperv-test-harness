[CmdletBinding()]
param(
    [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Import-NamedFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw $errors[0].Message }
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

Import-NamedFunction -Path (Join-Path $SourceRoot 'HostWorker.ps1') -Name 'Test-WorkerCaptureRetryAllowed'
$captureFailure = [pscustomobject]@{ Success = $false; FailureKind = 'CaptureInfrastructure' }
Assert-True (Test-WorkerCaptureRetryAllowed -AttemptResult $captureFailure -RetryCount 0 -CancellationRequested $false) 'The first capture infrastructure failure was not retryable.'
Assert-True (-not (Test-WorkerCaptureRetryAllowed -AttemptResult $captureFailure -RetryCount 1 -CancellationRequested $false)) 'A second capture infrastructure failure was incorrectly retryable.'
Assert-True (-not (Test-WorkerCaptureRetryAllowed -AttemptResult $captureFailure -RetryCount 0 -CancellationRequested $true)) 'A cancelled request was incorrectly retryable.'
Assert-True (-not (Test-WorkerCaptureRetryAllowed -AttemptResult ([pscustomobject]@{ Success = $false; FailureKind = 'TestAssertion' }) -RetryCount 0 -CancellationRequested $false)) 'An application test failure was incorrectly treated as capture infrastructure.'
Assert-True (-not (Test-WorkerCaptureRetryAllowed -AttemptResult ([pscustomobject]@{ Success = $true; FailureKind = $null }) -RetryCount 0 -CancellationRequested $false)) 'A successful attempt was incorrectly retryable.'

$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-capture-routing-' + [Guid]::NewGuid().ToString('N'))
$script:BrokerRoot = $root
$script:requestPath = Join-Path $root 'Requests'
$script:processingPath = Join-Path $root 'Processing'
$script:resultsPath = Join-Path $root 'Results'
$script:archivePath = Join-Path $root 'Archive'
$script:cancellationPath = Join-Path $root 'Cancellations'
foreach ($path in @($requestPath, $processingPath, $resultsPath, $archivePath, $cancellationPath)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}
$script:Config = [pscustomobject]@{ PoolIdleTimeoutSeconds = 600 }
. (Join-Path $SourceRoot 'PoolBroker.ps1')

$requestId = 'synthetic-capture-retry'
$resultRoot = Join-Path $resultsPath $requestId
New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
$processingFile = Join-Path $processingPath ($requestId + '.json')
[ordered]@{
    RequestId = $requestId
    CreatedUtc = [DateTime]::UtcNow.ToString('o')
    PendingInfrastructureRetry = $true
    InfrastructureRetryCount = 1
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $processingFile -Encoding UTF8

$script:state = [pscustomobject]@{
    WorkerId = 2
    VmName = 'Synthetic-02'
    Status = 'RunCompleted'
    RequestId = $requestId
    RecoveryRequestId = $null
    OperationId = 'operation'
    ProcessId = 123
    ProcessStartUtc = [DateTime]::UtcNow.ToString('o')
    LastReleasedUtc = [DateTime]::UtcNow.ToString('o')
    IdleDeadlineUtc = $null
    LastError = $null
}
$script:lifecycleMode = $null
$script:requestStatus = $null

function Get-PoolIdleDeadline {
    param($Config, [DateTime] $FromUtc)
    $FromUtc.AddSeconds(600)
}
function Write-PoolJsonAtomic {
    param([string] $Path, $Value)
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Update-PoolWorkerState {
    param([string] $BrokerRoot, [int] $WorkerId, [Collections.IDictionary] $Patch)
    foreach ($key in $Patch.Keys) {
        if ($script:state.PSObject.Properties.Name -contains [string]$key) { $script:state.([string]$key) = $Patch[$key] }
        else { $script:state | Add-Member -NotePropertyName ([string]$key) -NotePropertyValue $Patch[$key] }
    }
    $script:state
}
function Read-PoolWorkerState { param([string] $BrokerRoot, [int] $WorkerId) $script:state }
function Set-PoolLifecycleQueued {
    param($State, [string] $Mode, [string] $IdleDeadlineUtc)
    $script:lifecycleMode = $Mode
    $State.Status = $Mode + 'Queued'
}
function Write-RequestState {
    param([string] $ResultRoot, [string] $RequestId, [string] $Status, [string] $Message, [DateTime] $CreatedUtc)
    $script:requestStatus = $Status
}

try {
    Complete-PoolWorkerRun -State $script:state
    $queuedFile = Join-Path $requestPath ($requestId + '.json')
    Assert-True (Test-Path -LiteralPath $queuedFile -PathType Leaf) 'The retry request was not moved back to the queue immediately.'
    Assert-True (-not (Test-Path -LiteralPath $processingFile -PathType Leaf)) 'The retry request remained stranded in Processing.'
    $queuedRequest = Get-Content -Raw -LiteralPath $queuedFile | ConvertFrom-Json
    Assert-True (-not [bool]$queuedRequest.PendingInfrastructureRetry) 'The pending retry marker was not consumed atomically.'
    Assert-True ($script:lifecycleMode -eq 'Recycle' -and $script:state.Status -eq 'RecycleQueued') 'The failed worker was not queued for asynchronous recycling.'
    Assert-True ($script:requestStatus -eq 'RetryQueued') 'The request did not publish its retry queue status.'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = 6
    Scenarios = @(
        'first-capture-failure-retryable',
        'retry-bounded-to-one',
        'cancellation-disables-retry',
        'test-failure-not-retried',
        'success-not-retried',
        'retry-requeued-before-worker-recycle'
    )
} | ConvertTo-Json -Depth 8
