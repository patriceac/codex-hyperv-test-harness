[CmdletBinding()]
param([string] $SourceRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
$brokerSource = Join-Path $SourceRoot 'HostBroker.ps1'
. (Join-Path $SourceRoot 'PoolCommon.ps1')

$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$scratchRoot = Join-Path $repositoryRoot 'work\request-groups'
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null
$testRoot = Join-Path $scratchRoot ('broker-test-' + [Guid]::NewGuid().ToString('N'))
$script:BrokerRoot = Join-Path $testRoot 'Broker'
New-Item -ItemType Directory -Force -Path $script:BrokerRoot | Out-Null
. $brokerSource -BrokerRoot $script:BrokerRoot -LibraryOnly
. (Join-Path $SourceRoot 'PoolBroker.ps1')

$script:Config = [pscustomobject]@{ PoolMaxWorkers = 2; PoolWarmAhead = 1; PoolIdleTimeoutSeconds = 600 }
$script:states = @()
$script:assignments = New-Object Collections.Generic.List[object]
$script:lifecycleCalls = New-Object Collections.Generic.List[object]
$script:queueOrder = New-Object Collections.Generic.List[string]
$script:scenarios = New-Object Collections.Generic.List[string]

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Get-PoolQueuedFiles {
    @($script:queueOrder | ForEach-Object { Get-Item -LiteralPath (Join-Path $requestPath ($_ + '.json')) -ErrorAction SilentlyContinue } | Where-Object { $_ })
}

function Get-PoolWorkerStates {
    param([string] $BrokerRoot, $Config)
    @($script:states)
}

function Read-PoolWorkerState {
    param([string] $BrokerRoot, [int] $WorkerId)
    @($script:states | Where-Object { [int]$_.WorkerId -eq $WorkerId }) | Select-Object -First 1
}

function Ensure-PoolWarmSpareInvariant { }

function Set-PoolLifecycleQueued {
    param($State, [string] $Mode, [string] $IdleDeadlineUtc)
    $script:lifecycleCalls.Add([pscustomobject]@{ WorkerId = [int]$State.WorkerId; Mode = $Mode })
}

function Start-PoolRequest {
    param($State, [IO.FileInfo] $RequestFile)
    $request = Get-Content -Raw -LiteralPath $RequestFile.FullName -Encoding UTF8 | ConvertFrom-Json
    $groupPath = Join-Path (Join-Path $BrokerRoot 'State\RequestGroups') ([string]$request.Group.Id + '.json')
    $journal = Get-Content -Raw -LiteralPath $groupPath -Encoding UTF8 | ConvertFrom-Json
    $reservation = @($journal.Assignments | Where-Object { $_.RequestId -ceq [string]$request.RequestId -and [int]$_.WorkerId -eq [int]$State.WorkerId })
    if ($journal.Status -cne 'Admitting' -or @($journal.Assignments).Count -ne [int]$request.Group.Size -or $reservation.Count -ne 1) {
        throw 'A group member launch started before its complete worker assignment was durable.'
    }
    $script:assignments.Add([pscustomobject]@{ RequestId = [string]$request.RequestId; WorkerId = [int]$State.WorkerId })
    $State.Status = 'Leased'
    $State.RequestId = [string]$request.RequestId
    Move-Item -LiteralPath $RequestFile.FullName -Destination (Join-Path $processingPath $RequestFile.Name) -ErrorAction Stop
    $true
}

function New-WorkerState {
    param([int] $WorkerId, [string] $Status = 'Ready')
    [pscustomobject]@{
        WorkerId = $WorkerId
        Status = $Status
        OsClean = $true
        LastReadyUtc = ([DateTime]::UtcNow.AddSeconds($WorkerId)).ToString('o')
        IdleDeadlineUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        RequestId = $null
    }
}

function New-GroupMember {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $GroupId,
        [Parameter(Mandatory = $true)] [int] $GroupSize,
        [string] $Operation = 'RunGuestJob'
    )
    $request = [ordered]@{
        RequestId = $RequestId
        Operation = 'RunGuestJobGroupV1'
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        QueueTimeoutSeconds = 300
        Job = [ordered]@{ Arguments = $RequestId }
        Group = [ordered]@{ Id = $GroupId; Size = $GroupSize; Operation = $Operation }
    }
    $path = Join-Path $requestPath ($RequestId + '.json')
    $request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    $script:queueOrder.Add($RequestId)
    Get-Item -LiteralPath $path
}

function New-SingleRequest {
    param([Parameter(Mandatory = $true)] [string] $RequestId)
    $request = [ordered]@{ RequestId = $RequestId; Operation = 'RunGuestJob'; CreatedUtc = [DateTime]::UtcNow.ToString('o'); QueueTimeoutSeconds = 300 }
    $path = Join-Path $requestPath ($RequestId + '.json')
    $request | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
    $script:queueOrder.Add($RequestId)
    Get-Item -LiteralPath $path
}

function Reset-AdmissionFixture {
    param([object[]] $WorkerStates)
    $script:states = @($WorkerStates)
    $script:assignments.Clear()
    $script:lifecycleCalls.Clear()
    $script:queueOrder.Clear()
    foreach ($directory in @($requestPath, $processingPath, $resultsPath, $cancellationPath, $archivePath, (Join-Path $BrokerRoot 'State\RequestGroups'))) {
        if (Test-Path -LiteralPath $directory) {
            $resolved = (Resolve-Path -LiteralPath $directory).Path
            $expectedRoot = [IO.Path]::GetFullPath($BrokerRoot).TrimEnd('\') + '\'
            if (-not $resolved.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup target: $resolved" }
            Remove-Item -LiteralPath $resolved -Recurse
        }
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
}

try {
    Reset-AdmissionFixture -WorkerStates @((New-WorkerState 1), (New-WorkerState 2 'Off'))
    $firstGroupId = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
    $first = New-GroupMember -RequestId 'group-a-01' -GroupId $firstGroupId -GroupSize 2
    Update-PoolRequestGroups
    Assign-PoolRequests
    Assert-True ($script:assignments.Count -eq 0 -and $script:states[0].Status -eq 'Ready' -and (Test-Path -LiteralPath $first.FullName)) 'An incomplete group claimed a worker or left the queue.'
    Queue-ExpiredPoolWorkersForStop
    Assert-True ($script:lifecycleCalls.Count -eq 0) 'The pool stopped a ready worker while a valid group was waiting.'
    $single = New-SingleRequest -RequestId 'later-single'
    $script:states[1].Status = 'Ready'
    Assign-PoolRequests
    Assert-True ($script:assignments.Count -eq 0 -and (Test-Path -LiteralPath $single.FullName)) 'A later singleton bypassed the FIFO group at the queue head.'
    $script:scenarios.Add('incomplete-group-waits-blocks-later-work-and-protects-ready-workers')

    Reset-AdmissionFixture -WorkerStates @((New-WorkerState 1), (New-WorkerState 2 'Off'))
    $groupId = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
    $memberOne = New-GroupMember -RequestId 'group-b-01' -GroupId $groupId -GroupSize 2
    $memberTwo = New-GroupMember -RequestId 'group-b-02' -GroupId $groupId -GroupSize 2
    Update-PoolRequestGroups
    Assign-PoolRequests
    Assert-True ($script:assignments.Count -eq 0 -and @($script:states | Where-Object Status -eq 'Leased').Count -eq 0) 'A full group partially claimed work while fewer than two workers were ready.'
    Assert-True ((Test-Path -LiteralPath $memberOne.FullName) -and (Test-Path -LiteralPath $memberTwo.FullName)) 'A waiting group member left the queue before full capacity was available.'

    $script:states[1].Status = 'Ready'
    Assign-PoolRequests
    Assert-True ($script:assignments.Count -eq 2 -and @($script:assignments.WorkerId | Sort-Object -Unique).Count -eq 2) 'The group was not admitted in full onto distinct workers.'
    Assert-True (@($script:states | Where-Object Status -eq 'Leased').Count -eq 2) 'Successful group admission did not lease every assigned worker.'
    Assert-True (-not (Test-Path -LiteralPath $memberOne.FullName) -and -not (Test-Path -LiteralPath $memberTwo.FullName)) 'Successful group admission left a member in the request queue.'
    $journalPath = Join-Path (Join-Path $BrokerRoot 'State\RequestGroups') ($groupId + '.json')
    $journal = Get-Content -Raw -LiteralPath $journalPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($journal.Status -eq 'Running' -and @($journal.Assignments).Count -eq 2) 'The group journal did not publish a complete running assignment.'
    Assert-True (@($journal.Assignments.WorkerId | Sort-Object -Unique).Count -eq 2) 'The group journal did not reserve distinct workers.'
    $memberRequest = Get-Content -Raw -LiteralPath (Join-Path $processingPath 'group-b-01.json') -Encoding UTF8 | ConvertFrom-Json
    $resolvedMember = Resolve-PoolGroupMemberRequest -Request $memberRequest -WorkerId ([int]$journal.Assignments[0].WorkerId)
    Assert-True ($resolvedMember.Operation -eq 'RunGuestJob' -and -not $resolvedMember.PSObject.Properties['Group'] -and $resolvedMember.Job.Arguments -eq 'group-b-01') 'The worker did not resolve the journal-pinned member operation and arguments.'
    $strippedMember = $memberRequest | Select-Object *
    $strippedMember.Operation = 'RunGuestJob'
    $strippedMember.PSObject.Properties.Remove('Group')
    $strippedMetadataRejected = $false
    try { Resolve-PoolGroupMemberRequest -Request $strippedMember -WorkerId ([int]$journal.Assignments[0].WorkerId) | Out-Null } catch { $strippedMetadataRejected = $true }
    Assert-True $strippedMetadataRejected 'A durable group member executed after its wrapper metadata was stripped.'
    $wrongWorkerRejected = $false
    try { Resolve-PoolGroupMemberRequest -Request $memberRequest -WorkerId 99 | Out-Null } catch { $wrongWorkerRejected = $true }
    Assert-True $wrongWorkerRejected 'The group member wrapper resolved without its journal-pinned worker ID.'
    $script:scenarios.Add('full-group-waits-then-claims-all-workers-atomically')

    Reset-AdmissionFixture -WorkerStates @((New-WorkerState 1), (New-WorkerState 2 'Off'))
    $oversizedId = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
    New-GroupMember -RequestId 'group-too-large-01' -GroupId $oversizedId -GroupSize 3 | Out-Null
    New-GroupMember -RequestId 'group-too-large-02' -GroupId $oversizedId -GroupSize 3 | Out-Null
    Update-PoolRequestGroups
    Ensure-PoolDemandCapacity
    Assert-True ($script:lifecycleCalls.Count -eq 0) 'An over-capacity group started a worker before terminal rejection.'
    Assign-PoolRequests
    $invalidRequestIds = @('group-too-large-01', 'group-too-large-02')
    $invalidResults = @($invalidRequestIds | ForEach-Object { Get-Content -Raw -LiteralPath (Join-Path (Join-Path $resultsPath $_) 'broker-result.json') -Encoding UTF8 | ConvertFrom-Json })
    Assert-True ($invalidResults.Count -eq 2 -and @($invalidResults | Where-Object FailureKind -ne 'RequestGroupInvalid').Count -eq 0) 'An over-capacity group was not rejected with terminal RequestGroupInvalid results.'
    Assert-True ($script:assignments.Count -eq 0 -and @($script:states | Where-Object Status -eq 'Leased').Count -eq 0) 'An over-capacity group claimed a worker.'
    $script:scenarios.Add('group-over-pool-capacity-is-terminally-rejected')

    Reset-AdmissionFixture -WorkerStates @((New-WorkerState 1 'Leased'), (New-WorkerState 2 'Leased'))
    $restartGroupId = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
    $restartOne = New-GroupMember -RequestId 'group-restart-01' -GroupId $restartGroupId -GroupSize 2
    $restartTwo = New-GroupMember -RequestId 'group-restart-02' -GroupId $restartGroupId -GroupSize 2
    Save-PoolRequestGroup -Group ([pscustomobject]@{ Id = $restartGroupId; Size = 2; Status = 'Admitting'; Members = @('group-restart-01','group-restart-02'); Assignments = @([pscustomobject]@{ RequestId = 'group-restart-01'; WorkerId = 1 }, [pscustomobject]@{ RequestId = 'group-restart-02'; WorkerId = 2 }); Reason = $null })
    Move-Item -LiteralPath $restartOne.FullName -Destination (Join-Path $processingPath $restartOne.Name)
    Update-PoolRequestGroups
    $restartJournal = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $BrokerRoot 'State\RequestGroups') ($restartGroupId + '.json')) -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($restartJournal.Status -eq 'Cancelling' -and (Test-Path -LiteralPath (Join-Path $cancellationPath 'group-restart-01.json')) -and (Test-Path -LiteralPath (Join-Path $cancellationPath 'group-restart-02.json'))) 'An interrupted Admitting journal did not cancel every member.'
    $script:scenarios.Add('admitting-journal-restart-cancels-all-members')

    Reset-AdmissionFixture -WorkerStates @((New-WorkerState 1 'Leased'), (New-WorkerState 2 'Leased'))
    $cancelGroupId = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
    $cancelOne = New-GroupMember -RequestId 'group-cancel-01' -GroupId $cancelGroupId -GroupSize 2
    $cancelTwo = New-GroupMember -RequestId 'group-cancel-02' -GroupId $cancelGroupId -GroupSize 2
    Save-PoolRequestGroup -Group ([pscustomobject]@{ Id = $cancelGroupId; Size = 2; Status = 'Running'; Members = @('group-cancel-01','group-cancel-02'); Assignments = @(); Reason = $null })
    Move-Item -LiteralPath $cancelOne.FullName -Destination (Join-Path $processingPath $cancelOne.Name)
    Move-Item -LiteralPath $cancelTwo.FullName -Destination (Join-Path $processingPath $cancelTwo.Name)
    Write-PoolJsonAtomic -Path (Join-Path $cancellationPath 'group-cancel-01.json') -Value ([ordered]@{ RequestId = 'group-cancel-01'; Reason = 'synthetic cancellation' })
    Update-PoolRequestGroups
    $cancelJournal = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $BrokerRoot 'State\RequestGroups') ($cancelGroupId + '.json')) -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($cancelJournal.Status -eq 'Cancelling' -and (Test-Path -LiteralPath (Join-Path $cancellationPath 'group-cancel-02.json'))) 'A cancelled member did not propagate cancellation to its peer.'
    $script:scenarios.Add('member-cancellation-propagates-to-peers')

    Reset-AdmissionFixture -WorkerStates @((New-WorkerState 1 'Leased'), (New-WorkerState 2 'Leased'))
    $failureGroupId = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
    $failedOne = New-GroupMember -RequestId 'group-failed-01' -GroupId $failureGroupId -GroupSize 2
    $failedTwo = New-GroupMember -RequestId 'group-failed-02' -GroupId $failureGroupId -GroupSize 2
    Save-PoolRequestGroup -Group ([pscustomobject]@{ Id = $failureGroupId; Size = 2; Status = 'Running'; Members = @('group-failed-01','group-failed-02'); Assignments = @(); Reason = $null })
    Move-Item -LiteralPath $failedOne.FullName -Destination (Join-Path $processingPath $failedOne.Name)
    Move-Item -LiteralPath $failedTwo.FullName -Destination (Join-Path $processingPath $failedTwo.Name)
    $failedResultRoot = Join-Path $resultsPath 'group-failed-01'
    New-Item -ItemType Directory -Force -Path $failedResultRoot | Out-Null
    Write-PoolJsonAtomic -Path (Join-Path $failedResultRoot 'broker-result.json') -Value ([ordered]@{ RequestId = 'group-failed-01'; Success = $false; TestEvaluated = $false; TestPassed = $null })
    Update-PoolRequestGroups
    $failureJournal = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $BrokerRoot 'State\RequestGroups') ($failureGroupId + '.json')) -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($failureJournal.Status -eq 'Cancelling' -and (Test-Path -LiteralPath (Join-Path $cancellationPath 'group-failed-02.json'))) 'A terminally failed member did not cancel its peer.'
    $script:scenarios.Add('terminal-member-failure-propagates-to-peers')

    $noReplay = Get-PoolInterruptedExpectedGuestPowerOffState -Request ([pscustomobject]@{ Operation = 'RunGuestJobGroupV1' }) -RequestState ([pscustomobject]@{ Status = 'Claimed' })
    Assert-True ($noReplay.Disposition -eq 'InvalidState' -and $noReplay.FailureKind -eq 'RequestGroupInterrupted') 'An interrupted group was not classified as terminal without replay.'
    $hostWorkerText = Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'HostWorker.ps1')
    Assert-True ($hostWorkerText -match '\$request\.Operation -notin @\(''RunGuestJobPowerTestV1'',''RunGuestInstallerV2'',''RunGuestJobGroupV1''\)') 'Grouped work became eligible for automatic capture retry.'
    $script:scenarios.Add('interrupted-group-no-replay-and-no-capture-retry')

    [pscustomobject][ordered]@{ Success = $true; ScenarioCount = $script:scenarios.Count; Scenarios = $script:scenarios.ToArray() } | ConvertTo-Json -Depth 8
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $expectedScratchPrefix = [IO.Path]::GetFullPath($scratchRoot).TrimEnd('\') + '\broker-test-'
        if ($resolvedTestRoot -ne [IO.Path]::GetFullPath($testRoot) -or -not $resolvedTestRoot.StartsWith($expectedScratchPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe request-group test cleanup path.' }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse
    }
}
