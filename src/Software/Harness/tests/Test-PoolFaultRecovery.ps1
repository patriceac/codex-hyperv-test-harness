[CmdletBinding()]
param([string] $SourceRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent $PSScriptRoot
}
$BrokerRoot = 'SyntheticBroker'
$Config = [pscustomobject]@{
    PoolMaxWorkers = 4
    PoolWarmAhead = 1
    PoolIdleTimeoutSeconds = 600
    PoolFaultRecoveryBaseSeconds = 5
    PoolFaultRecoveryMaxSeconds = 600
}

. (Join-Path $SourceRoot 'PoolCommon.ps1')
. (Join-Path $SourceRoot 'PoolBroker.ps1')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function New-SyntheticFaultState {
    param(
        [int] $WorkerId,
        [string] $Status = 'Faulted',
        [int] $Attempts = 0,
        [string] $NotBeforeUtc = $null
    )
    [pscustomobject]@{
        WorkerId = $WorkerId
        VmName = ('Synthetic-{0:D2}' -f $WorkerId)
        Status = $Status
        OsClean = $false
        RequestId = $null
        OperationId = $null
        ProcessId = $null
        ProcessStartUtc = $null
        IdleDeadlineUtc = $null
        PendingLifecycleMode = $null
        FaultRecoveryAttempts = $Attempts
        FaultRecoveryNotBeforeUtc = $NotBeforeUtc
        LastError = 'synthetic fault'
    }
}

$script:states = @()
$script:lifecycleCalls = New-Object Collections.Generic.List[object]
function Get-PoolWorkerStates {
    param([string] $BrokerRoot, $Config)
    @($script:states)
}
function Set-PoolLifecycleQueued {
    param($State, [string] $Mode, [string] $IdleDeadlineUtc)
    $script:lifecycleCalls.Add([pscustomobject]@{ WorkerId = [int]$State.WorkerId; Mode = $Mode })
    $State.Status = if ($Mode -eq 'Recycle') { 'RecycleQueued' } else { $Mode + 'Queued' }
}
function Move-QueuedRequestWithTerminalResult { param($QueuedFile, [string] $RequestId, [string] $Reason) $false }
$script:queueStateWrites = 0
function Write-RequestState { param([Parameter(ValueFromRemainingArguments = $true)] $Remaining) $script:queueStateWrites++ }

$scenarios = New-Object Collections.Generic.List[string]
$now = [DateTime]::Parse('2026-08-11T12:00:00Z').ToUniversalTime()

Assert-True ((Get-PoolFaultRecoveryDelaySeconds -Config $Config -Attempt 1 -WorkerId 1) -eq 5) 'The first recovery delay is incorrect.'
Assert-True ((Get-PoolFaultRecoveryDelaySeconds -Config $Config -Attempt 2 -WorkerId 1) -eq 10) 'The exponential recovery delay is incorrect.'
Assert-True ((Get-PoolFaultRecoveryDelaySeconds -Config $Config -Attempt 50 -WorkerId 4) -eq 600) 'The recovery delay did not honor its upper bound.'
$scenarios.Add('recovery-backoff-is-exponential-and-bounded')

$faulted = New-SyntheticFaultState -WorkerId 2 -Attempts 2
$patch = New-PoolFaultStatePatch -State $faulted -Config $Config -ErrorMessage 'again' -FailureUtc $now
Assert-True ([int]$patch.FaultRecoveryAttempts -eq 3) 'A repeated worker fault did not increment its recovery attempt.'
Assert-True ([DateTime]::Parse([string]$patch.FaultRecoveryNotBeforeUtc).ToUniversalTime() -eq $now.AddSeconds(22)) 'The worker-specific backoff deadline is incorrect.'
Assert-True (-not [bool]$patch.OsClean -and [string]$patch.Status -eq 'Faulted') 'A faulted worker was not marked dirty and faulted.'
$scenarios.Add('fault-state-records-next-retry')

$future = $now.AddMinutes(1).ToString('o')
$past = $now.AddMinutes(-1).ToString('o')
Assert-True (-not (Test-PoolWorkerFaultRecoveryEligible -State (New-SyntheticFaultState 1 -NotBeforeUtc $future) -NowUtc $now)) 'A worker was eligible before its recovery deadline.'
Assert-True (Test-PoolWorkerFaultRecoveryEligible -State (New-SyntheticFaultState 1 -NotBeforeUtc $past) -NowUtc $now) 'A worker was not eligible after its recovery deadline.'
Assert-True (Test-PoolWorkerFaultRecoveryEligible -State (New-SyntheticFaultState 1) -NowUtc $now) 'A legacy faulted worker without backoff metadata was not recoverable.'
$scenarios.Add('recovery-deadline-is-enforced-and-legacy-safe')

$script:states = @(
    (New-SyntheticFaultState 1 -NotBeforeUtc ([DateTime]::UtcNow.AddMinutes(5).ToString('o'))),
    (New-SyntheticFaultState 2 -NotBeforeUtc ([DateTime]::UtcNow.AddMinutes(-2).ToString('o'))),
    (New-SyntheticFaultState 3 -NotBeforeUtc ([DateTime]::UtcNow.AddMinutes(-1).ToString('o'))),
    (New-SyntheticFaultState 4 -Status 'Ready')
)
$script:lifecycleCalls.Clear()
Queue-FaultedPoolWorkerRecovery
Assert-True ($script:lifecycleCalls.Count -eq 1 -and $script:lifecycleCalls[0].WorkerId -eq 2 -and $script:lifecycleCalls[0].Mode -eq 'Recycle') 'The broker did not queue exactly the oldest eligible faulted worker.'
$scenarios.Add('broker-queues-one-eligible-recovery-per-pass')

$script:states = @(
    (New-SyntheticFaultState 1 -NotBeforeUtc ([DateTime]::UtcNow.AddMinutes(5).ToString('o'))),
    (New-SyntheticFaultState 2 -Status 'Ready'),
    (New-SyntheticFaultState 3 -Status 'Off'),
    (New-SyntheticFaultState 4 -Status 'Off')
)
$script:lifecycleCalls.Clear()
Queue-FaultedPoolWorkerRecovery
Assert-True ($script:lifecycleCalls.Count -eq 0) 'The broker ignored the fault-recovery backoff.'
$scenarios.Add('broker-does-not-spin-on-faulted-worker')

$lifecycleText = Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'PoolLifecycle.ps1')
Assert-True ($lifecycleText -like '*FaultRecoveryAttempts = 0*' -and $lifecycleText -like '*FaultRecoveryNotBeforeUtc = $null*') 'A successfully readied worker does not reset consecutive failure backoff.'
$brokerText = Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'PoolBroker.ps1')
Assert-True ($brokerText -like '*Queue-FaultedPoolWorkerRecovery*' -and $brokerText -like '*Test-PoolWorkerFaultRecoveryEligible*') 'The main pool loop does not contain proactive, deadline-aware fault recovery.'
$scenarios.Add('successful-ready-resets-backoff')

$duplicateRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-pool-active-duplicate-' + [Guid]::NewGuid().ToString('N'))
try {
    $script:requestPath = Join-Path $duplicateRoot 'Requests'
    $script:processingPath = Join-Path $duplicateRoot 'Processing'
    $script:archivePath = Join-Path $duplicateRoot 'Archive'
    $script:resultsPath = Join-Path $duplicateRoot 'Results'
    foreach ($path in @($script:requestPath, $script:processingPath, $script:archivePath, $script:resultsPath)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    $duplicateRequestId = 'same-id-active'
    [ordered]@{ RequestId = $duplicateRequestId; CreatedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:requestPath ($duplicateRequestId + '.json')) -Encoding UTF8
    [ordered]@{ RequestId = $duplicateRequestId; CreatedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:processingPath ($duplicateRequestId + '.json')) -Encoding UTF8
    $script:states = @([pscustomobject]@{ WorkerId = 1; RequestId = $duplicateRequestId; RecoveryRequestId = $null })
    $script:queueStateWrites = 0
    Write-PoolQueuePositions -Config $Config
    Assert-True (
        -not (Test-Path -LiteralPath (Join-Path $script:requestPath ($duplicateRequestId + '.json'))) -and
        (Test-Path -LiteralPath (Join-Path $script:processingPath ($duplicateRequestId + '.json'))) -and
        @(Get-ChildItem -LiteralPath $script:archivePath -Filter ($duplicateRequestId + '-duplicate-active-*.json') -File).Count -eq 1 -and
        $script:queueStateWrites -eq 0
    ) 'A same-ID queued duplicate remained live or rewrote state while the original request was active.'
    $scenarios.Add('same-id-active-queue-duplicate-is-quarantined')
}
finally {
    Remove-Item -LiteralPath $duplicateRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$expectedPowerOffRequest = [pscustomobject]@{ ExpectGuestPowerOff = $true }
$causalPowerOffState = [pscustomobject]@{
    ExpectGuestPowerOff = $true
    GuestApplicationEraRunningObservedUtc = '2026-08-31T00:00:01Z'
    GuestPowerOffObservedUtc = '2026-08-31T00:00:10Z'
    GuestPowerOffBeforeCleanup = $true
}
$causalClassification = Get-PoolInterruptedExpectedGuestPowerOffState -Request $expectedPowerOffRequest -RequestState $causalPowerOffState
Assert-True ([string]$causalClassification.Disposition -eq 'ProtectedNoReplay') 'A causally observed expected power-off was not protected from legacy replay after worker interruption.'
Assert-True ($null -eq (Get-PoolInterruptedExpectedGuestPowerOffState -Request ([pscustomobject]@{ ExpectGuestPowerOff = 'true' }) -RequestState $causalPowerOffState)) 'A string request opt-in enabled fail-closed expected-power-off interruption handling.'
Assert-True ($null -eq (Get-PoolInterruptedExpectedGuestPowerOffState -Request ([pscustomobject]@{ expectGuestPowerOff = $true }) -RequestState $causalPowerOffState)) 'A case-variant request opt-in enabled fail-closed expected-power-off interruption handling.'
$runningClassification = Get-PoolInterruptedExpectedGuestPowerOffState -Request $expectedPowerOffRequest -RequestState ([pscustomobject]@{
    ExpectGuestPowerOff = $true
    GuestApplicationEraRunningObservedUtc = '2026-08-31T00:00:01Z'
})
$submissionClassification = Get-PoolInterruptedExpectedGuestPowerOffState -Request $expectedPowerOffRequest -RequestState ([pscustomobject]@{
    ExpectGuestPowerOff = $true
    ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'
    GuestJobMayHaveLaunched = $true
})
Assert-True ([string]$runningClassification.Disposition -eq 'ProtectedNoReplay') 'A worker crash immediately after durable application-era Running confirmation could still replay the shutdown application.'
Assert-True ([string]$submissionClassification.Disposition -eq 'ProtectedNoReplay') 'A worker crash during an ambiguously completed expected-power-off submission could still replay the application.'
$scenarios.Add('protected-poweroff-worker-crash-is-never-replayed')

$safePreDeliveryClassification = Get-PoolInterruptedExpectedGuestPowerOffState -Request $expectedPowerOffRequest -RequestState ([pscustomobject]@{
    RequestId = 'safe-pre-delivery'
    Status = 'Claimed'
    History = @([pscustomobject]@{ Status = 'Claimed' })
})
Assert-True ([string]$safePreDeliveryClassification.Disposition -eq 'SafePreDelivery') 'A marker-free exact request state was not recognized as definitely pre-delivery and requeueable.'

$invalidExpectedPowerOffStates = @(
    [pscustomobject]@{ Name = 'state-opt-in-string'; State = [pscustomobject]@{ ExpectGuestPowerOff = 'true' } },
    [pscustomobject]@{ Name = 'state-opt-in-false'; State = [pscustomobject]@{ ExpectGuestPowerOff = $false } },
    [pscustomobject]@{ Name = 'state-opt-in-without-delivery-marker'; State = [pscustomobject]@{ ExpectGuestPowerOff = $true } },
    [pscustomobject]@{ Name = 'submission-timestamp-without-true-marker'; State = [pscustomobject]@{ ExpectGuestPowerOff = $true; ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z' } },
    [pscustomobject]@{ Name = 'true-marker-without-submission-timestamp'; State = [pscustomobject]@{ ExpectGuestPowerOff = $true; GuestJobMayHaveLaunched = $true } },
    [pscustomobject]@{ Name = 'string-may-have-launched'; State = [pscustomobject]@{ ExpectGuestPowerOff = $true; ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'; GuestJobMayHaveLaunched = 'true' } },
    [pscustomobject]@{ Name = 'false-may-have-launched'; State = [pscustomobject]@{ ExpectGuestPowerOff = $true; GuestJobMayHaveLaunched = $false } },
    [pscustomobject]@{ Name = 'poweroff-without-running'; State = [pscustomobject]@{ ExpectGuestPowerOff = $true; GuestPowerOffObservedUtc = '2026-08-31T00:00:10Z'; GuestPowerOffBeforeCleanup = $true } },
    [pscustomobject]@{ Name = 'poweroff-timestamp-without-true-marker'; State = [pscustomobject]@{ ExpectGuestPowerOff = $true; GuestApplicationEraRunningObservedUtc = '2026-08-31T00:00:01Z'; GuestPowerOffObservedUtc = '2026-08-31T00:00:10Z' } },
    [pscustomobject]@{ Name = 'true-poweroff-marker-without-timestamp'; State = [pscustomobject]@{ ExpectGuestPowerOff = $true; GuestApplicationEraRunningObservedUtc = '2026-08-31T00:00:01Z'; GuestPowerOffBeforeCleanup = $true } },
    [pscustomobject]@{ Name = 'string-poweroff-marker'; State = [pscustomobject]@{ ExpectGuestPowerOff = $true; ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'; GuestJobMayHaveLaunched = $true; GuestPowerOffBeforeCleanup = 'true' } },
    [pscustomobject]@{ Name = 'case-variant-state-opt-in'; State = [pscustomobject]@{ expectGuestPowerOff = $true; ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'; GuestJobMayHaveLaunched = $true } },
    [pscustomobject]@{ Name = 'historical-marker-without-current-opt-in'; State = [pscustomobject]@{ Status = 'Claimed'; History = @([pscustomobject]@{ ExpectGuestPowerOff = $true; ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'; GuestJobMayHaveLaunched = $true }) } }
)
foreach ($invalidCase in $invalidExpectedPowerOffStates) {
    $classification = Get-PoolInterruptedExpectedGuestPowerOffState -Request $expectedPowerOffRequest -RequestState $invalidCase.State
    Assert-True ([string]$classification.Disposition -eq 'InvalidState') "Malformed expected-power-off state '$([string]$invalidCase.Name)' was treated as replayable or normally protected."
}
$scenarios.Add('malformed-or-incomplete-exact-poweroff-state-fails-closed')

Assert-True (
    $brokerText.Contains("FailureKind = if (`$causalPowerOffPersisted) { 'GuestPowerOffEvidenceRecoveryInterrupted'") -and
    $brokerText.Contains('The request was failed terminally and will not be replayed.') -and
    $brokerText.Contains("FailureKind = 'ExpectedGuestPowerOffStateMissing'") -and
    $brokerText.Contains("FailureKind = 'ExpectedGuestPowerOffStateInvalid'") -and
    $brokerText.Contains("FailureKind = 'InterruptedRequestStateUnreadable'") -and
    $brokerText.Contains('Publish-InterruptedRequestTerminalResult')
) 'The pool does not publish an explicit fail-closed terminal result for unreadable, missing, or protected expected-power-off work.'
Assert-True (
    [regex]::Matches($brokerText, "Disposition -eq 'InvalidState'").Count -ge 4 -and
    $brokerText.Contains("FailureStage 'PoolWorkerLaunch'") -and
    $brokerText.Contains("FailureStage 'PoolWorkerRecovery'") -and
    $brokerText.Contains("FailureStage 'PoolRecoveryRequeue'") -and
    $brokerText.Contains("FailureStage 'PoolStartupRecovery'")
) 'At least one pool recovery/requeue caller can still treat invalid exact expected-power-off state as replayable.'
Assert-True (
    $brokerText.Contains('ExpectedGuestPowerOffPoolStateInterrupted') -and
    $brokerText.Contains('Get-PoolInterruptedExpectedGuestPowerOffState -Request $orphanedRequest') -and
    $brokerText.Contains("Reason 'pool-startup-interrupted-queued-after-terminal'")
) 'Pool startup can replay an expected-power-off request or leave a same-ID queued duplicate live when its worker-state mapping is lost.'
$scenarios.Add('causal-poweroff-worker-crash-publishes-terminal-failure')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
