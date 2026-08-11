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
}

. (Join-Path $SourceRoot 'PoolBroker.ps1')

$script:states = @()
$script:lifecycleCalls = New-Object Collections.Generic.List[object]

function Get-PoolWorkerStates {
    param([string] $BrokerRoot, $Config)
    @($script:states)
}

function Get-PoolIdleDeadline {
    param($Config, [DateTime] $FromUtc = ([DateTime]::UtcNow))
    $FromUtc.ToUniversalTime().AddSeconds(600)
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
    $state = @($script:states | Where-Object { [int]$_.WorkerId -eq $WorkerId }) | Select-Object -First 1
    if (-not $state) { throw "Synthetic worker is missing: $WorkerId" }
    foreach ($key in $Patch.Keys) {
        if ($state.PSObject.Properties.Name -contains [string]$key) {
            $state.([string]$key) = $Patch[$key]
        }
        else {
            $state | Add-Member -NotePropertyName ([string]$key) -NotePropertyValue $Patch[$key]
        }
    }
    $state
}

function Set-PoolLifecycleQueued {
    param($State, [string] $Mode, [string] $IdleDeadlineUtc)
    $script:lifecycleCalls.Add([pscustomobject]@{ WorkerId = [int]$State.WorkerId; Mode = $Mode })
    $status = switch ($Mode) {
        'Start' { 'StartQueued' }
        'Recycle' { 'RecycleQueued' }
        'Stop' { 'StopQueued' }
    }
    $State.Status = $status
    $State.PendingLifecycleMode = $Mode
    $State.IdleDeadlineUtc = $IdleDeadlineUtc
}

function New-SyntheticState {
    param(
        [int] $WorkerId,
        [string] $Status,
        [bool] $OsClean = $true,
        [string] $IdleDeadlineUtc = $null
    )
    [pscustomobject]@{
        WorkerId = $WorkerId
        VmName = ('Synthetic-{0:D2}' -f $WorkerId)
        Status = $Status
        OsClean = $OsClean
        IdleDeadlineUtc = $IdleDeadlineUtc
        PendingLifecycleMode = $null
        OperationId = $null
        ProcessId = $null
        ProcessStartUtc = $null
        RequestId = if ($Status -in @('Leased', 'RunCompleted')) { 'request-' + $WorkerId } else { $null }
        LastError = $null
    }
}

function Reset-SyntheticPool {
    param([object[]] $States)
    $script:states = @($States)
    $script:lifecycleCalls.Clear()
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$expired = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
$future = [DateTime]::UtcNow.AddMinutes(10).ToString('o')
$scenarios = New-Object Collections.Generic.List[string]

Reset-SyntheticPool -States @(
    (New-SyntheticState 1 'Leased'),
    (New-SyntheticState 2 'Off'),
    (New-SyntheticState 3 'Off'),
    (New-SyntheticState 4 'Off')
)
Ensure-PoolWarmSpareInvariant
Assert-True ($script:lifecycleCalls.Count -eq 1 -and $script:lifecycleCalls[0].Mode -eq 'Start' -and $script:lifecycleCalls[0].WorkerId -eq 2) 'A lone lease did not queue exactly one clean spare.'
$scenarios.Add('lone-lease-starts-one-spare')

Reset-SyntheticPool -States @(
    (New-SyntheticState 1 'Leased'),
    (New-SyntheticState 2 'StopQueued' $true $null),
    (New-SyntheticState 3 'Off'),
    (New-SyntheticState 4 'Off')
)
Ensure-PoolWarmSpareInvariant
Assert-True ($script:lifecycleCalls.Count -eq 0 -and $script:states[1].Status -eq 'Ready') 'A cancellable stop was not reclaimed as the protected spare.'
$scenarios.Add('queued-stop-is-cancelled')

Reset-SyntheticPool -States @(
    (New-SyntheticState 1 'Leased'),
    (New-SyntheticState 2 'Starting'),
    (New-SyntheticState 3 'Off'),
    (New-SyntheticState 4 'Off')
)
Ensure-PoolWarmSpareInvariant
Assert-True ($script:lifecycleCalls.Count -eq 0) 'An already-starting spare caused an unnecessary additional start.'
$scenarios.Add('starting-spare-counts-as-potential')

Reset-SyntheticPool -States @(
    (New-SyntheticState 1 'Leased'),
    (New-SyntheticState 2 'Ready' $true $expired),
    (New-SyntheticState 3 'Off'),
    (New-SyntheticState 4 'Off')
)
Queue-ExpiredPoolWorkersForStop
Assert-True ($script:lifecycleCalls.Count -eq 0 -and $script:states[1].Status -eq 'Ready') 'The final ready spare was stopped under an active lease.'
$scenarios.Add('last-ready-spare-is-protected')

Reset-SyntheticPool -States @(
    (New-SyntheticState 1 'Leased'),
    (New-SyntheticState 2 'Ready' $true $expired),
    (New-SyntheticState 3 'Ready' $true $expired),
    (New-SyntheticState 4 'Off')
)
Queue-ExpiredPoolWorkersForStop
$readyAfterStop = @($script:states | Where-Object Status -eq 'Ready').Count
Assert-True ($script:lifecycleCalls.Count -eq 1 -and $script:lifecycleCalls[0].Mode -eq 'Stop' -and $readyAfterStop -eq 1) 'Expired excess spares did not stop while retaining exactly one ready spare.'
$scenarios.Add('excess-ready-spares-may-stop')

Reset-SyntheticPool -States @(
    (New-SyntheticState 1 'Ready' $true $expired),
    (New-SyntheticState 2 'Off'),
    (New-SyntheticState 3 'Off'),
    (New-SyntheticState 4 'Off')
)
Queue-ExpiredPoolWorkersForStop
Assert-True ($script:lifecycleCalls.Count -eq 1 -and $script:lifecycleCalls[0].Mode -eq 'Stop') 'An expired ready VM was retained with no active leases.'
$scenarios.Add('zero-leases-preserves-zero-spares')

Reset-SyntheticPool -States @(
    (New-SyntheticState 1 'Leased'),
    (New-SyntheticState 2 'Leased'),
    (New-SyntheticState 3 'Leased'),
    (New-SyntheticState 4 'Ready' $true $expired)
)
Queue-ExpiredPoolWorkersForStop
Assert-True ($script:lifecycleCalls.Count -eq 0) 'The only available fourth worker was stopped under three leases.'
$scenarios.Add('three-leases-protect-fourth-worker')

Reset-SyntheticPool -States @(
    (New-SyntheticState 1 'Leased'),
    (New-SyntheticState 2 'Leased'),
    (New-SyntheticState 3 'Leased'),
    (New-SyntheticState 4 'Leased')
)
$fullSummary = Get-PoolWarmSpareSummary -States $script:states
Assert-True ($fullSummary.RequiredCount -eq 0 -and $fullSummary.Satisfied) 'A fully leased four-worker pool incorrectly required a fifth VM.'
$scenarios.Add('four-worker-cap-needs-no-impossible-spare')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 6
