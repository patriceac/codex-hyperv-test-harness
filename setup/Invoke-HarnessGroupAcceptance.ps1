[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $InstallRoot,
    [Parameter(Mandatory = $true)] [string] $EvidenceRoot,
    [ValidateRange(120, 3600)] [int] $TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) { throw 'InstallRoot must be a specific non-root directory.' }
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\')
if (-not ($EvidenceRoot + '\').StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'EvidenceRoot must remain below InstallRoot.'
}

$softwareRoot = Join-Path $InstallRoot 'Software'
$brokerRoot = Join-Path $InstallRoot 'Live\Broker'
$runner = Join-Path $softwareRoot 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
$cancelRunner = Join-Path $softwareRoot 'Skill\scripts\Cancel-HyperVExecutableTest.ps1'
$artifactPath = Join-Path $softwareRoot 'Canaries\PoolCanary.exe'
$poolStatePath = Join-Path $brokerRoot 'State\pool-state.json'
$maintenancePath = Join-Path $brokerRoot 'State\maintenance.json'
$requestPath = Join-Path $brokerRoot 'Requests'
$processingPath = Join-Path $brokerRoot 'Processing'
$resultsPath = Join-Path $brokerRoot 'Results'
$groupJournalRoot = Join-Path $brokerRoot 'State\RequestGroups'
$powerShellExecutable = Join-Path $PSHOME 'powershell.exe'
foreach ($path in @($runner, $cancelRunner, $artifactPath, $poolStatePath, $requestPath, $processingPath, $resultsPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -and -not (Test-Path -LiteralPath $path -PathType Container)) { throw "Grouped acceptance input is missing: $path" }
}

$runRoot = Join-Path $EvidenceRoot ('run-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$resultPath = Join-Path $runRoot 'result.json'
$actionsPath = Join-Path $runRoot 'pool-canary-actions.json'
$timelinePath = Join-Path $runRoot 'timeline.json'
$status = 'Preparing'
$failureText = $null
$processes = New-Object Collections.Generic.List[object]
$timeline = New-Object Collections.Generic.List[object]
$startedUtc = [DateTime]::UtcNow
$groupAId = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
$groupBId = [Guid]::NewGuid().ToString('N').ToLowerInvariant()
$capacity = 0
$groupBFirstClaimUtc = $null
$groupACompletedBeforeBClaim = $null
$sawWaitingGroupBWithoutPartialAssignment = $false

function Write-GroupAcceptanceJson {
    param([Parameter(Mandatory = $true)] [string] $Path, [Parameter(Mandatory = $true)] $Value)
    $temporaryPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $temporaryPath + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true) }
        else { [IO.File]::Move($temporaryPath, $Path) }
    }
    finally {
        [IO.File]::Delete($temporaryPath)
        [IO.File]::Delete($backupPath)
    }
}

function Read-GroupAcceptanceJson {
    param([Parameter(Mandatory = $true)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}

function Get-GroupJournal {
    param([Parameter(Mandatory = $true)] [string] $GroupId)
    Read-GroupAcceptanceJson -Path (Join-Path $groupJournalRoot ($GroupId + '.json'))
}

function Get-GroupMemberRequestIds {
    param([Parameter(Mandatory = $true)] [string] $GroupId)
    $journal = Get-GroupJournal -GroupId $GroupId
    if ($journal) { return @($journal.Members | ForEach-Object { [string]$_ } | Select-Object -Unique) }
    $ids = New-Object Collections.Generic.List[string]
    foreach ($root in @($requestPath, $processingPath)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $request = Read-GroupAcceptanceJson -Path $file.FullName
            if ($request -and [string]$request.Group.Id -ceq $GroupId) { $ids.Add([string]$request.RequestId) }
        }
    }
    $ids.ToArray()
}

function Get-GroupCompletedMemberCount {
    param([Parameter(Mandatory = $true)] [string] $GroupId)
    $count = 0
    foreach ($requestId in @(Get-GroupMemberRequestIds -GroupId $GroupId)) {
        $result = Read-GroupAcceptanceJson -Path (Join-Path (Join-Path $resultsPath $requestId) 'broker-result.json')
        if ($result -and [bool]$result.Success) { $count++ }
    }
    $count
}

function Get-QueueAndProcessingRequestCount {
    $queued = @(Get-ChildItem -LiteralPath $requestPath -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $processing = @(Get-ChildItem -LiteralPath $processingPath -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    [pscustomobject]@{ Queued = $queued; Processing = $processing }
}

function Get-RunnerRequestId {
    param([Parameter(Mandatory = $true)] $Entry)
    $text = if (Test-Path -LiteralPath $Entry.StdOut -PathType Leaf) { Get-Content -LiteralPath $Entry.StdOut -Raw -ErrorAction SilentlyContinue } else { '' }
    if ($text -match 'Submitted\s+(executable-test-[A-Za-z0-9_-]+)') { return [string]$Matches[1] }
    $null
}

function Get-GroupResultSummary {
    param([Parameter(Mandatory = $true)] [string] $GroupId, [Parameter(Mandatory = $true)] [int] $ExpectedSize)
    $journal = Get-GroupJournal -GroupId $GroupId
    if (-not $journal) { throw "Group journal is missing: $GroupId" }
    $memberIds = @($journal.Members | ForEach-Object { [string]$_ })
    $assignments = @($journal.Assignments)
    if ($memberIds.Count -ne $ExpectedSize -or $assignments.Count -ne $ExpectedSize) { throw "Group $GroupId did not retain a complete member and assignment journal." }
    if (@($assignments.WorkerId | Sort-Object -Unique).Count -ne $ExpectedSize) { throw "Group $GroupId did not reserve distinct workers for every member." }
    $members = New-Object Collections.Generic.List[object]
    foreach ($requestId in $memberIds) {
        $resultFile = Join-Path (Join-Path $resultsPath $requestId) 'broker-result.json'
        $result = Read-GroupAcceptanceJson -Path $resultFile
        if (-not $result -or -not [bool]$result.Success -or [string]$result.VmFinalState -ne 'Off' -or -not [bool]$result.PayloadChildDeleted) {
            throw "Group member $requestId did not complete successfully with a powered-off guest and deleted payload child."
        }
        $assignment = @($assignments | Where-Object { [string]$_.RequestId -ceq $requestId })
        if ($assignment.Count -ne 1 -or [int]$assignment[0].WorkerId -ne [int]$result.PoolWorkerId) { throw "Group member $requestId completed on a worker different from its durable reservation." }
        $members.Add([pscustomobject][ordered]@{
            RequestId = $requestId
            WorkerId = [int]$result.PoolWorkerId
            ResultPath = Join-Path (Join-Path $resultsPath $requestId) ''
            Success = [bool]$result.Success
            VmFinalState = [string]$result.VmFinalState
            PayloadChildDeleted = [bool]$result.PayloadChildDeleted
        })
    }
    [pscustomobject][ordered]@{ Id = $GroupId; Size = $ExpectedSize; Status = [string]$journal.Status; Members = $members.ToArray(); Assignments = $assignments }
}

function Get-AvailableWorkerRequestIds {
    param([AllowNull()] $PoolState)
    if (-not $PoolState) { return @() }
    @($PoolState.Workers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.RequestId) } | ForEach-Object { [string]$_.RequestId })
}

function Add-GroupAcceptanceSnapshot {
    param([AllowNull()] $PoolState, [AllowNull()] $JournalA, [AllowNull()] $JournalB)
    $aMemberCount = if ($JournalA) { @($JournalA.Members).Count } else { 0 }
    $bMemberCount = if ($JournalB) { @($JournalB.Members).Count } else { 0 }
    $aAssignmentCount = if ($JournalA) { @($JournalA.Assignments).Count } else { 0 }
    $bAssignmentCount = if ($JournalB) { @($JournalB.Assignments).Count } else { 0 }
    $entry = [pscustomobject][ordered]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        QueueDepth = if ($PoolState) { [int]$PoolState.QueueDepth } else { $null }
        ActiveCount = if ($PoolState) { [int]$PoolState.ActiveCount } else { $null }
        GroupAStatus = if ($JournalA) { [string]$JournalA.Status } else { $null }
        GroupAMembers = $aMemberCount
        GroupAAssignments = $aAssignmentCount
        GroupBStatus = if ($JournalB) { [string]$JournalB.Status } else { $null }
        GroupBMembers = $bMemberCount
        GroupBAssignments = $bAssignmentCount
        GroupACompleted = Get-GroupCompletedMemberCount -GroupId $groupAId
    }
    $timeline.Add($entry)
    Write-GroupAcceptanceJson -Path $timelinePath -Value $timeline.ToArray()
}

function Observe-GroupReservationState {
    $pool = Read-GroupAcceptanceJson -Path $poolStatePath
    $journalA = Get-GroupJournal -GroupId $groupAId
    $journalB = Get-GroupJournal -GroupId $groupBId
    if ($journalA -and [string]$journalA.Status -eq 'Queued' -and @($journalA.Members).Count -eq $capacity) {
        if (@($journalA.Assignments).Count -ne 0) { throw 'Group A retained a partial assignment while waiting.' }
        $memberIds = @($journalA.Members | ForEach-Object { [string]$_ })
        if (@(Get-AvailableWorkerRequestIds -PoolState $pool | Where-Object { $_ -in $memberIds }).Count -gt 0) { throw 'Group A held a worker before its complete admission.' }
    }
    if ($journalB -and [string]$journalB.Status -eq 'Queued' -and @($journalB.Members).Count -eq ($capacity - 1)) {
        if (@($journalB.Assignments).Count -ne 0) { throw 'Group B retained a partial assignment while waiting.' }
        $memberIds = @($journalB.Members | ForEach-Object { [string]$_ })
        if (@(Get-AvailableWorkerRequestIds -PoolState $pool | Where-Object { $_ -in $memberIds }).Count -gt 0) { throw 'Group B held a worker before its complete admission.' }
        if (@(Get-ChildItem -LiteralPath $requestPath -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -in $memberIds }).Count -eq ($capacity - 1)) {
        $script:sawWaitingGroupBWithoutPartialAssignment = $true
        }
    }
    if ($journalB -and [string]$journalB.Status -in @('Admitting','Running') -and $null -eq $groupBFirstClaimUtc) {
        if (@($journalB.Assignments).Count -ne ($capacity - 1)) { throw 'Group B began admission without a complete durable worker reservation.' }
        $completedA = Get-GroupCompletedMemberCount -GroupId $groupAId
        if ($completedA -lt ($capacity - 1)) { throw "Group B was first claimed after only $completedA of $($capacity - 1) Group A members had finished." }
        $script:groupBFirstClaimUtc = [DateTime]::UtcNow.ToString('o')
        $script:groupACompletedBeforeBClaim = $completedA
    }
    if ($journalB -and [string]$journalB.Status -in @('Admitting','Running') -and @($journalB.Assignments).Count -ne ($capacity - 1)) {
        throw 'Group B became active with a partial assignment journal.'
    }
    $signature = '{0}|{1}|{2}:{3}:{4}|{5}:{6}:{7}' -f `
        $(if ($pool) { [int]$pool.QueueDepth } else { -1 }),
        $(if ($pool) { [int]$pool.ActiveCount } else { -1 }),
        $(if ($journalA) { [string]$journalA.Status } else { '-' }), $(@($journalA.Members).Count), $(@($journalA.Assignments).Count),
        $(if ($journalB) { [string]$journalB.Status } else { '-' }), $(@($journalB.Members).Count), $(@($journalB.Assignments).Count)
    if ($signature -ne $script:lastSignature) {
        $script:lastSignature = $signature
        Add-GroupAcceptanceSnapshot -PoolState $pool -JournalA $journalA -JournalB $journalB
    }
    [pscustomobject]@{ Pool = $pool; GroupA = $journalA; GroupB = $journalB }
}

function Start-GroupRunner {
    param([Parameter(Mandatory = $true)] $Member)
    $stdout = Join-Path $runRoot ($Member.LogName + '.stdout.txt')
    $stderr = Join-Path $runRoot ($Member.LogName + '.stderr.txt')
    $arguments = @(
        '-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
        '-File', ('"' + $runner + '"'),
        '-ArtifactPath', ('"' + $artifactPath + '"'),
        '-ActionsPath', ('"' + $actionsPath + '"'),
        '-GroupId', [string]$Member.GroupId,
        '-GroupSize', [string][int]$Member.GroupSize,
        '-BrokerRoot', ('"' + $brokerRoot + '"'),
        '-QueueTimeoutSeconds', '1800',
        '-ExecutionTimeoutSeconds', '900',
        '-ThrowOnFailure'
    )
    $process = Start-Process -FilePath $powerShellExecutable -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $entry = [pscustomobject]@{ Index = [int]$Member.Index; Group = [string]$Member.Group; GroupId = [string]$Member.GroupId; GroupSize = [int]$Member.GroupSize; Process = $process; StdOut = $stdout; StdErr = $stderr; MemberIndex = [int]$Member.MemberIndex }
    $processes.Add($entry)
    $entry
}

function Wait-ForSubmittedGroupCall {
    param([Parameter(Mandatory = $true)] [string] $GroupId, [Parameter(Mandatory = $true)] [int] $ExpectedCount, [Parameter(Mandatory = $true)] $Entry, [Parameter(Mandatory = $true)] [DateTime] $DeadlineUtc)
    while ([DateTime]::UtcNow -lt $DeadlineUtc) {
        $queuedIds = New-Object Collections.Generic.List[string]
        foreach ($root in @($requestPath, $processingPath)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                $request = Read-GroupAcceptanceJson -Path $file.FullName
                if ($request -and [string]$request.Group.Id -ceq $GroupId) { $queuedIds.Add([string]$request.RequestId) }
            }
        }
        $journal = Get-GroupJournal -GroupId $GroupId
        $count = [Math]::Max($queuedIds.Count, $(if ($journal) { @($journal.Members).Count } else { 0 }))
        if ($count -ge $ExpectedCount) { return }
        $Entry.Process.Refresh()
        if ($Entry.Process.HasExited) { throw "Runner $($Entry.Index) exited before its group request was queued (exit $($Entry.Process.ExitCode))." }
        if ([DateTime]::UtcNow -ge $DeadlineUtc) { break }
        [void](Observe-GroupReservationState)
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for interleaved runner $($Entry.Index) to enter its group queue."
}

function Get-ProcessRequestIds {
    $ids = New-Object Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($groupId in @($groupAId, $groupBId)) {
        foreach ($requestId in @(Get-GroupMemberRequestIds -GroupId $groupId)) { [void]$ids.Add([string]$requestId) }
    }
    foreach ($entry in $processes) {
        $requestId = Get-RunnerRequestId -Entry $entry
        if ($requestId) { [void]$ids.Add($requestId) }
    }
    @($ids)
}

function Cancel-OwnedGroupRequests {
    foreach ($requestId in @(Get-ProcessRequestIds)) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $resultsPath $requestId) 'broker-result.json') -PathType Leaf) { continue }
        try { & $cancelRunner -RequestId $requestId -BrokerRoot $brokerRoot -Reason 'Grouped acceptance stopped; cancel the exact owned group request.' | Out-Null } catch { }
    }
}

try {
    $status = 'Running'
    $actions = @(
        [ordered]@{ type = 'wait_window'; timeoutMs = 30000 },
        [ordered]@{ type = 'screenshot'; name = 'group-start.png'; timeoutMs = 30000; attempts = 5 },
        [ordered]@{ type = 'wait'; ms = 10000 },
        [ordered]@{ type = 'screenshot'; name = 'group-end.png'; timeoutMs = 30000; attempts = 5 }
    )
    $actions | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $actionsPath -Encoding UTF8

    $readyDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Min(300, $TimeoutSeconds))
    $initialPool = $null
    do {
        if (Test-Path -LiteralPath $maintenancePath -PathType Leaf) { Start-Sleep -Milliseconds 250; continue }
        $candidatePool = Read-GroupAcceptanceJson -Path $poolStatePath
        $counts = Get-QueueAndProcessingRequestCount
        if ($candidatePool -and [int]$candidatePool.MaxWorkers -ge 2 -and $counts.Queued -eq 0 -and $counts.Processing -eq 0 -and [int]$candidatePool.ActiveCount -eq 0 -and [int]$candidatePool.QueueDepth -eq 0) {
            $initialPool = $candidatePool
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $readyDeadline)
    if (-not $initialPool) { throw 'The installed broker did not reach an idle, empty queue within the bounded preflight; no group request was submitted.' }
    $capacity = [int]$initialPool.MaxWorkers
    if (@($initialPool.Workers).Count -ne $capacity) { throw 'The installed pool-state worker inventory does not match MaxWorkers.' }
    if ($capacity -lt 2) { throw 'Grouped reservation acceptance requires at least two configured workers.' }
    $groupBSize = [Math]::Max(1, $capacity - 1)

    $members = New-Object Collections.Generic.List[object]
    $nextIndex = 1
    for ($memberIndex = 1; $memberIndex -le $capacity; $memberIndex++) {
        $members.Add([pscustomobject]@{ Index = $nextIndex; Group = 'A'; GroupId = $groupAId; GroupSize = $capacity; MemberIndex = $memberIndex; LogName = ('member-{0:D2}-A' -f $memberIndex) })
        $nextIndex++
        if ($memberIndex -le $groupBSize) {
            $members.Add([pscustomobject]@{ Index = $nextIndex; Group = 'B'; GroupId = $groupBId; GroupSize = $groupBSize; MemberIndex = $memberIndex; LogName = ('member-{0:D2}-B' -f $memberIndex) })
            $nextIndex++
        }
    }

    $submissionDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Min(180, $TimeoutSeconds))
    foreach ($member in $members) {
        $entry = Start-GroupRunner -Member $member
        $alreadySubmitted = @($processes | Where-Object { $_.GroupId -ceq $member.GroupId }).Count
        Wait-ForSubmittedGroupCall -GroupId $member.GroupId -ExpectedCount $alreadySubmitted -Entry $entry -DeadlineUtc $submissionDeadline
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $observed = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $observed = Observe-GroupReservationState
        foreach ($entry in $processes) {
            $entry.Process.Refresh()
            if ($entry.Process.HasExited -and [int]$entry.Process.ExitCode -ne 0) {
                $stderrText = if (Test-Path -LiteralPath $entry.StdErr) { Get-Content -LiteralPath $entry.StdErr -Raw -ErrorAction SilentlyContinue } else { '' }
                throw "Group runner $($entry.Index) failed with exit $($entry.Process.ExitCode): $stderrText"
            }
        }
        $journalA = $observed.GroupA
        $journalB = $observed.GroupB
        $aComplete = $journalA -and @($journalA.Members).Count -eq $capacity -and [string]$journalA.Status -eq 'Completed'
        $bComplete = $journalB -and @($journalB.Members).Count -eq $groupBSize -and [string]$journalB.Status -eq 'Completed'
        $allExited = @($processes | Where-Object { -not $_.Process.HasExited }).Count -eq 0
        if ($aComplete -and $bComplete -and $allExited) { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $observed -or -not $observed.GroupA -or -not $observed.GroupB -or
        [string]$observed.GroupA.Status -ne 'Completed' -or [string]$observed.GroupB.Status -ne 'Completed' -or
        @($processes | Where-Object { -not $_.Process.HasExited }).Count -gt 0) {
        throw "Grouped reservation acceptance timed out after $TimeoutSeconds seconds."
    }
    if (-not $sawWaitingGroupBWithoutPartialAssignment) { throw 'The acceptance run never observed the complete Group B waiting without any partial lease.' }
    if ($null -eq $groupBFirstClaimUtc -or [int]$groupACompletedBeforeBClaim -lt $groupBSize) { throw 'Group B was claimed before enough Group A members finished.' }

    $groupASummary = Get-GroupResultSummary -GroupId $groupAId -ExpectedSize $capacity
    $groupBSummary = Get-GroupResultSummary -GroupId $groupBId -ExpectedSize $groupBSize
    $status = 'Completed'
    $summary = [pscustomobject][ordered]@{
        Success = $true
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        InstallRoot = $InstallRoot
        EvidenceRoot = $runRoot
        ResultPath = $resultPath
        ArtifactPath = $artifactPath
        PoolMaxWorkers = $capacity
        GroupSizes = @($capacity, $groupBSize)
        InterleavedSubmissionOrder = @($processes | ForEach-Object { [pscustomobject]@{ Index = [int]$_.Index; Group = [string]$_.Group; MemberIndex = [int]$_.MemberIndex; GroupId = [string]$_.GroupId } })
        GroupBWaitingObservedWithoutPartialAssignment = [bool]$sawWaitingGroupBWithoutPartialAssignment
        GroupBFirstClaimUtc = $script:groupBFirstClaimUtc
        GroupACompletedBeforeGroupBFirstClaim = [int]$script:groupACompletedBeforeBClaim
        Groups = @($groupASummary, $groupBSummary)
        RunnerLogs = @($processes | ForEach-Object { [pscustomobject]@{ Index = [int]$_.Index; StdOut = [string]$_.StdOut; StdErr = [string]$_.StdErr; ExitCode = [int]$_.Process.ExitCode } })
        TimelinePath = $timelinePath
    }
    Write-GroupAcceptanceJson -Path $resultPath -Value $summary
}
catch {
    $failureText = $_.Exception.Message
    $status = 'Failed'
    Cancel-OwnedGroupRequests
    $graceDeadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        $running = @($processes | Where-Object { -not $_.Process.HasExited })
        if ($running.Count -eq 0 -or [DateTime]::UtcNow -ge $graceDeadline) { break }
        Start-Sleep -Milliseconds 250
    } while ($true)
    foreach ($entry in $processes) {
        $entry.Process.Refresh()
        if (-not $entry.Process.HasExited) { Stop-Process -Id $entry.Process.Id -Force -ErrorAction SilentlyContinue }
    }
    $failure = [pscustomobject][ordered]@{
        Success = $false
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        InstallRoot = $InstallRoot
        EvidenceRoot = $runRoot
        ResultPath = $resultPath
        PoolMaxWorkers = $capacity
        GroupSizes = if ($capacity -ge 2) { @($capacity, [Math]::Max(1, $capacity - 1)) } else { @() }
        Error = $failureText
        GroupA = Get-GroupJournal -GroupId $groupAId
        GroupB = Get-GroupJournal -GroupId $groupBId
        RunnerLogs = @($processes | ForEach-Object { [pscustomobject]@{ Index = [int]$_.Index; RequestId = Get-RunnerRequestId -Entry $_; StdOut = [string]$_.StdOut; StdErr = [string]$_.StdErr; ExitCode = if ($_.Process.HasExited) { [int]$_.Process.ExitCode } else { $null } } })
        TimelinePath = $timelinePath
    }
    try { Write-GroupAcceptanceJson -Path $resultPath -Value $failure } catch { }
    throw "Grouped reservation acceptance failed; evidence is at $resultPath. $failureText"
}
finally {
    foreach ($entry in $processes) {
        try { $entry.Process.Dispose() } catch { }
    }
}

$summary
