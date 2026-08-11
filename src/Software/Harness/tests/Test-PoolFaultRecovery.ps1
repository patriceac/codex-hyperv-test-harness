[CmdletBinding()]
param(
    [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
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

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
