[CmdletBinding()]
param(
    [string] $RunnerPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'),
    [string] $HostBrokerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'HostBroker.ps1'),
    [string] $QueueInspectorPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill\scripts\Get-HyperVExecutableTestQueue.ps1')
)

$ErrorActionPreference = 'Stop'

function Get-ScriptAst {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has a parse error: $($errors[0].Message)" }
    $ast
}

function Import-AstFunction {
    param(
        [Parameter(Mandatory = $true)] $Ast,
        [Parameter(Mandatory = $true)] [string] $Name
    )
    $definition = @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$runnerAst = Get-ScriptAst -Path $RunnerPath
$brokerAst = Get-ScriptAst -Path $HostBrokerPath
$queueAst = Get-ScriptAst -Path $QueueInspectorPath
foreach ($name in @('Read-RequestStateSafe', 'Resolve-RequestStateWithLastReadable', 'Get-RequestLifecycleDisplay', 'Test-LifecycleProgressChanged')) { Import-AstFunction -Ast $runnerAst -Name $name }
foreach ($name in @('Write-JsonAtomic', 'Write-RequestState', 'Get-GuestLifecycleProgress')) { Import-AstFunction -Ast $brokerAst -Name $name }
foreach ($name in @('Read-JsonSafe', 'Get-RequestDetails')) { Import-AstFunction -Ast $queueAst -Name $name }

$scenarios = New-Object Collections.Generic.List[string]
$requestId = 'lifecycle-contract-request'

function Test-Path { throw [UnauthorizedAccessException]::new('synthetic atomic-replace ACL race') }
$safeRead = Read-RequestStateSafe -Path 'synthetic-request-state.json'
Remove-Item -LiteralPath 'Function:\Test-Path' -Force
Assert-True ($null -eq $safeRead) 'The request-state safe reader did not absorb a transient access failure.'
$scenarios.Add('request-state-access-race-is-tolerated')

$preRunningStates = @(
    [pscustomobject]@{ Status = 'Claimed'; Message = 'Worker claimed request.'; WorkerId = 2 },
    [pscustomobject]@{ Status = 'StagingGuestPayload'; Message = 'Syncing payload.'; WorkerId = 2 },
    [pscustomobject]@{ Status = 'PreparingHostInputs'; Message = 'Preparing read-only host inputs.'; WorkerId = 2 },
    [pscustomobject]@{ Status = 'PreparingVm'; Message = 'Preparing VM.'; WorkerId = 2 },
    [pscustomobject]@{ Status = 'StartingVm'; Message = 'Starting VM.'; WorkerId = 2 },
    [pscustomobject]@{ Status = 'WaitingForGuestAgent'; Message = 'Waiting for agent.'; WorkerId = 2 },
    [pscustomobject]@{ Status = 'LaunchingApplication'; Message = 'Job submitted.'; WorkerId = 2 },
    [pscustomobject]@{ Status = 'RunningGuestJob'; Message = 'Legacy broker submission state.'; WorkerId = 2 }
)
foreach ($state in $preRunningStates) {
    $display = Get-RequestLifecycleDisplay -RequestState $state -RequestId $requestId -ProcessingPresent:$true
    Assert-True ($display.Status -ne 'ApplicationRunning') "Pre-confirmation state $($state.Status) became ApplicationRunning."
    Assert-True ($display.Text -notmatch '(?i)\brunning\b') "Pre-confirmation output used running wording for $($state.Status): $($display.Text)"
}
$scenarios.Add('pre-confirmation-stages-never-say-running')

$withoutLease = [pscustomobject]@{
    ApplicationLease = $null
    AgentAlive = $true
    AgentState = [pscustomobject]@{ JobId = $requestId; Status = 'RunningJob'; ActionIndex = 1; ActionType = 'wait_window' }
}
$launching = Get-GuestLifecycleProgress -CompletionState $withoutLease -RequestId $requestId -ApplicationRunningPublished:$false
Assert-True ($launching.Status -eq 'LaunchingApplication' -and -not $launching.ApplicationConfirmed) 'Guest submission or action state incorrectly confirmed application start without a lease.'
$scenarios.Add('job-submission-is-launching-only')

$withLease = [pscustomobject]@{
    ApplicationLease = [pscustomobject]@{ JobId = $requestId; ProcessId = 4242; StartedUtc = '2026-08-10T20:00:00Z' }
    AgentAlive = $true
    AgentState = [pscustomobject]@{ JobId = $requestId; Status = 'RunningJob'; ActionIndex = 1; ActionType = 'wait_window' }
}
$confirmed = Get-GuestLifecycleProgress -CompletionState $withLease -RequestId $requestId -ApplicationRunningPublished:$false
Assert-True ($confirmed.Status -eq 'ApplicationRunning' -and $confirmed.ApplicationConfirmed -and $confirmed.ApplicationProcessId -eq 4242) 'A valid guest Start-Process lease did not publish ApplicationRunning.'
$scenarios.Add('application-running-requires-guest-lease')

$action = Get-GuestLifecycleProgress -CompletionState $withLease -RequestId $requestId -ApplicationRunningPublished:$true
Assert-True ($action.Status -eq 'GuestAction' -and $action.GuestActionIndex -eq 1 -and $action.GuestActionType -eq 'wait_window') 'Guest action progress was not exposed after application confirmation.'
$scenarios.Add('guest-action-after-application-confirmation')

$afterLease = Get-GuestLifecycleProgress -CompletionState ([pscustomobject]@{
    ApplicationLease = $null
    AgentAlive = $true
    AgentState = [pscustomobject]@{ JobId = $null; Status = 'Idle'; ActionIndex = $null; ActionType = $null }
}) -RequestId $requestId -ApplicationRunningPublished:$true
Assert-True ($afterLease.Status -eq 'AwaitingGuestCompletion') 'A vanished application lease was still reported as ApplicationRunning.'
$afterLeaseDisplay = Get-RequestLifecycleDisplay -RequestState $afterLease -RequestId $requestId -ProcessingPresent:$true
Assert-True ($afterLeaseDisplay.Text -notmatch '(?i)\brunning\b') 'Post-lease completion waiting used running wording.'
$scenarios.Add('post-lease-state-does-not-claim-running')

$displayOne = Get-RequestLifecycleDisplay -RequestState ([pscustomobject]@{ Status = 'PreparingVm'; Message = 'Preparing.'; WorkerId = 1 }) -RequestId $requestId -ProcessingPresent:$true
$displaySame = Get-RequestLifecycleDisplay -RequestState ([pscustomobject]@{ Status = 'PreparingVm'; Message = 'Preparing.'; WorkerId = 1; UpdatedUtc = 'later' }) -RequestId $requestId -ProcessingPresent:$true
$displayChanged = Get-RequestLifecycleDisplay -RequestState ([pscustomobject]@{ Status = 'PreparingVm'; Message = 'Attaching payload child.'; WorkerId = 1 }) -RequestId $requestId -ProcessingPresent:$true
Assert-True (Test-LifecycleProgressChanged -LastKey $null -Display $displayOne) 'The first lifecycle update was suppressed.'
Assert-True (-not (Test-LifecycleProgressChanged -LastKey $displayOne.Key -Display $displaySame)) 'An identical lifecycle status/message was emitted twice.'
Assert-True (Test-LifecycleProgressChanged -LastKey $displayOne.Key -Display $displayChanged) 'A meaningful lifecycle message change was suppressed.'
$scenarios.Add('identical-updates-suppressed')

foreach ($terminalStatus in @('Completed', 'TestFailed', 'Failed', 'Cancelled', 'QueueTimedOut', 'ExecutionTimedOut')) {
    $terminal = Get-RequestLifecycleDisplay -RequestState ([pscustomobject]@{ Status = $terminalStatus; Message = 'terminal'; WorkerId = 4 }) -RequestId $requestId
    Assert-True ($terminal.Text -like "Terminal result: $terminalStatus.*") "Terminal state $terminalStatus was not rendered correctly."
}
$scenarios.Add('terminal-and-cancellation-rendered')

$fallback = Get-RequestLifecycleDisplay -RequestState $null -RequestId $requestId -ProcessingPresent:$true -FallbackWorkerId 3
Assert-True ($fallback.Status -eq 'Assigned' -and $fallback.Text -like 'Assigned to worker 3:*' -and $fallback.Text -notmatch '(?i)\brunning\b') 'Older/missing request state did not use conservative assignment wording.'
$scenarios.Add('missing-state-conservative-assignment')

$lastReadable = [pscustomobject]@{ Status = 'GuestAction'; Message = 'action remains current'; WorkerId = 2; GuestActionIndex = 4; GuestActionType = 'screenshot' }
$transientlyUnreadable = Resolve-RequestStateWithLastReadable -CurrentRequestState $null -LastReadableRequestState $lastReadable
Assert-True ($transientlyUnreadable.Status -eq 'GuestAction' -and $transientlyUnreadable.GuestActionIndex -eq 4) 'A transient request-state read failure regressed lifecycle reporting to Assigned.'
$initiallyMissing = Resolve-RequestStateWithLastReadable -CurrentRequestState $null -LastReadableRequestState $null
Assert-True ($null -eq $initiallyMissing) 'An initially missing request state did not preserve conservative fallback behavior.'
$scenarios.Add('transient-state-read-keeps-last-truthful-stage')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-lifecycle-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    Write-RequestState -ResultRoot $testRoot -RequestId $requestId -Status 'Queued' -Message 'waiting' -QueuePosition 1 -QueueDepth 1
    Write-RequestState -ResultRoot $testRoot -RequestId $requestId -Status 'Queued' -Message 'waiting' -QueuePosition 1 -QueueDepth 1
    $queuedDeduplicated = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'request-state.json') | ConvertFrom-Json
    Assert-True ([int64]$queuedDeduplicated.Revision -eq 1 -and @($queuedDeduplicated.History).Count -eq 1 -and $null -ne @($queuedDeduplicated.History)[0]) 'Repeated queued state or null normalization created duplicate/empty history events.'
    $scenarios.Add('queued-history-null-normalization-deduplicated')
    Write-RequestState -ResultRoot $testRoot -RequestId $requestId -Status 'Claimed' -Message 'claimed' -WorkerId 2
    Write-RequestState -ResultRoot $testRoot -RequestId $requestId -Status 'ApplicationRunning' -Message 'confirmed' -WorkerId 2 -ApplicationProcessId 4242 -ApplicationStartedUtc '2026-08-10T20:00:00Z'
    Write-RequestState -ResultRoot $testRoot -RequestId $requestId -Status 'GuestAction' -Message 'action' -WorkerId 2 -GuestActionIndex 3 -GuestActionType 'screenshot'
    $preserved = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'request-state.json') | ConvertFrom-Json
    Assert-True ($preserved.WorkerId -eq 2 -and $preserved.ApplicationProcessId -eq 4242 -and $preserved.GuestActionIndex -eq 3) 'Atomic request-state updates did not preserve worker/application metadata.'
    $revisionBeforeDuplicate = [int64]$preserved.Revision
    $historyCountBeforeDuplicate = @($preserved.History).Count
    Write-RequestState -ResultRoot $testRoot -RequestId $requestId -Status 'GuestAction' -Message 'action' -WorkerId 2 -GuestActionIndex 3 -GuestActionType 'screenshot'
    $deduplicated = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'request-state.json') | ConvertFrom-Json
    Assert-True ([int64]$deduplicated.Revision -eq $revisionBeforeDuplicate -and @($deduplicated.History).Count -eq $historyCountBeforeDuplicate) 'Identical atomic request-state updates created duplicate lifecycle history.'
    $scenarios.Add('request-state-history-deduplicated')
    Write-RequestState -ResultRoot $testRoot -RequestId $requestId -Status 'RetryQueued' -Message 'retry'
    $reset = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'request-state.json') | ConvertFrom-Json
    Assert-True ($null -eq $reset.WorkerId -and $null -eq $reset.ApplicationProcessId) 'Retry queue transition retained stale worker/application metadata.'
    $scenarios.Add('request-state-metadata-preserved-and-reset')

    $script:resultsRoot = Join-Path $testRoot 'Results'
    New-Item -ItemType Directory -Force -Path $script:resultsRoot | Out-Null
    $requestFile = Join-Path $testRoot ($requestId + '.json')
    [ordered]@{ RequestId = $requestId; CreatedUtc = [DateTime]::UtcNow.ToString('o'); QueueTimeoutSeconds = 300; ExecutionTimeoutSeconds = 120 } | ConvertTo-Json | Set-Content -LiteralPath $requestFile -Encoding UTF8
    $requestResultRoot = Join-Path $script:resultsRoot $requestId
    New-Item -ItemType Directory -Force -Path $requestResultRoot | Out-Null
    [ordered]@{ Status = 'PreparingVm'; Message = 'Attaching child.'; WorkerId = 3; UpdatedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $requestResultRoot 'request-state.json') -Encoding UTF8
    $details = Get-RequestDetails -File (Get-Item $requestFile) -Status 'Claimed' -Position 0 -WorkerId 3
    Assert-True ($details.OwnershipStatus -eq 'Claimed' -and $details.Status -eq 'PreparingVm' -and $details.Message -eq 'Attaching child.' -and $details.WorkerId -eq 3) 'Queue inspector hid the current claimed-request lifecycle state/message.'
    $scenarios.Add('queue-inspector-exposes-current-stage')
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
