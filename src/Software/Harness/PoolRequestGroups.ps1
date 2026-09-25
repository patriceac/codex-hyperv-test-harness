$groupContractPath = Join-Path $PSScriptRoot 'RequestGroupContract.ps1'
if (-not (Test-Path -LiteralPath $groupContractPath)) { $groupContractPath = Join-Path $PSScriptRoot '..\Skill\scripts\RequestGroupContract.ps1' }
. $groupContractPath

function Get-PoolRequestGroupPath {
    param([Parameter(Mandatory = $true)] [ValidatePattern('^[a-f0-9]{32}$')] [string] $Id)
    Join-Path $BrokerRoot ('State\RequestGroups\' + $Id + '.json')
}

function Save-PoolRequestGroup {
    param([Parameter(Mandatory = $true)] $Group)
    Write-PoolJsonAtomic -Path (Get-PoolRequestGroupPath -Id $Group.Id) -Value $Group
}

function Complete-PoolInvalidGroupRequest {
    param([Parameter(Mandatory = $true)] [IO.FileInfo] $File, [Parameter(Mandatory = $true)] [string] $Message)
    $id = [IO.Path]::GetFileNameWithoutExtension($File.Name)
    $root = Join-Path $resultsPath $id
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Invoke-WithTerminalResultPublicationMutex -RequestId $id -ScopeRoot $root -Operation {
        if (-not (Test-Path -LiteralPath (Join-Path $root 'broker-result.json'))) {
            Write-RequestState -ResultRoot $root -RequestId $id -Status 'Failed' -Message $Message
            Write-TerminalJsonAtomic -Path (Join-Path $root 'broker-result.json') -Value ([ordered]@{
                RequestId = $id; Success = $false; HarnessSucceeded = $false; OverallSucceeded = $false
                TestEvaluated = $false; TestPassed = $null; FailureKind = 'RequestGroupInvalid'; Error = $Message
                CompletedUtc = [DateTime]::UtcNow.ToString('o'); VmFinalState = 'NotStarted'; PoolWorkerId = $null
            }) | Out-Null
        }
    }
    Move-QueuedRequestWithTerminalResult -QueuedFile $File -RequestId $id -Reason 'invalid-group' | Out-Null
}

function Stop-PoolRequestGroup {
    param([Parameter(Mandatory = $true)] $Group, [Parameter(Mandatory = $true)] [string] $Reason)
    if ($Group.Status -ne 'Cancelling') {
        $Group.Status = 'Cancelling'
        $Group.Reason = $Reason
        Save-PoolRequestGroup -Group $Group
    }
    foreach ($id in $Group.Members) {
        if (-not (Test-Path -LiteralPath (Join-Path $resultsPath ($id + '\broker-result.json')))) {
            Write-PoolJsonAtomic -Path (Join-Path $cancellationPath ($id + '.json')) -Value ([ordered]@{
                RequestId = $id; Reason = $Group.Reason; RequestedUtc = [DateTime]::UtcNow.ToString('o'); RequestedBy = 'Pool request group'
            })
        }
    }
}

function Update-PoolRequestGroups {
    # Only the singleton broker admits groups. Its protected journal is written
    # before launching any member; a crash during admission cancels the group.
    foreach ($file in Get-PoolQueuedFiles) {
        try { $request = Read-BrokerJsonWithRetry -Path $file.FullName }
        catch { continue } # Ordinary malformed requests retain their existing failure path.
        if (-not $request) { continue }
        if (-not $request.PSObject.Properties['Group'] -and $request.Operation -ne 'RunGuestJobGroupV1') { continue }
        try { $definition = Get-RequestGroupDefinition -Request $request -MaxWorkers ([int]$Config.PoolMaxWorkers) }
        catch { Complete-PoolInvalidGroupRequest -File $file -Message $_.Exception.Message; continue }
        $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($request.RequestId -cne $id) { Complete-PoolInvalidGroupRequest -File $file -Message 'RequestId must match the request filename.'; continue }
        $path = Get-PoolRequestGroupPath -Id $definition.Id
        $group = if (Test-Path -LiteralPath $path) { Read-BrokerJsonWithRetry -Path $path } else { $null }
        if (-not $group) {
            $group = [pscustomobject]@{ Id = $definition.Id; Size = [int]$definition.Size; Status = 'Queued'; Members = @(); Assignments = @(); Reason = $null }
        }
        if ($id -notin @($group.Members)) {
            if ($group.Status -ne 'Queued') {
                Complete-PoolInvalidGroupRequest -File $file -Message 'This group has already been admitted or closed. Use a new group ID for a new run.'
                continue
            }
            $group.Members = @($group.Members) + $id
            Save-PoolRequestGroup -Group $group
        }
        if ([int]$definition.Size -ne [int]$group.Size -or @($group.Members).Count -gt [int]$group.Size) {
            Stop-PoolRequestGroup -Group $group -Reason 'Group members disagree on size or exceed the declared member count.'
        }
    }
    $root = Join-Path $BrokerRoot 'State\RequestGroups'
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $group = Read-BrokerJsonWithRetry -Path $file.FullName
        if ($group.Status -eq 'Completed') { continue }
        $reason = if ($group.Status -eq 'Admitting') { 'Group admission was interrupted. Every member is cancelled; resubmit the complete group with a new ID.' } else { $null }
        $completed = 0
        foreach ($id in $group.Members) {
            $result = Join-Path $resultsPath ($id + '\broker-result.json')
            if (Test-Path -LiteralPath $result) {
                $terminal = Read-BrokerJsonWithRetry -Path $result
                $completed++
                if (-not $terminal.Success -or ($terminal.TestEvaluated -and -not $terminal.TestPassed)) { $reason = "Group member $id failed or was cancelled." }
            }
            elseif (Test-Path -LiteralPath (Join-Path $cancellationPath ($id + '.json'))) { $reason = "Cancellation requested for group member $id." }
            elseif ($group.Status -eq 'Running' -and (Test-Path -LiteralPath (Join-Path $requestPath ($id + '.json')))) { $reason = "Group member $id was interrupted; individual replay is prohibited." }
            elseif (-not (Test-Path -LiteralPath (Join-Path $requestPath ($id + '.json'))) -and -not (Test-Path -LiteralPath (Join-Path $processingPath ($id + '.json')))) { $reason = "Group member $id disappeared from the queue or processing inventory." }
        }
        if ($completed -eq @($group.Members).Count) {
            $group.Status = 'Completed'
            Save-PoolRequestGroup -Group $group
        }
        elseif ($reason -or $group.Status -eq 'Cancelling') {
            Stop-PoolRequestGroup -Group $group -Reason $(if ($reason) { $reason } else { $group.Reason })
        }
    }
}

function Start-PoolRequestGroup {
    param([Parameter(Mandatory = $true)] [IO.FileInfo] $RequestFile, [AllowEmptyCollection()] [object[]] $ReadyStates)
    $request = Read-BrokerJsonWithRetry -Path $RequestFile.FullName
    $definition = Get-RequestGroupDefinition -Request $request -MaxWorkers ([int]$Config.PoolMaxWorkers)
    $group = Read-BrokerJsonWithRetry -Path (Get-PoolRequestGroupPath -Id $definition.Id)
    if ($group.Status -ne 'Queued' -or @($group.Members).Count -ne [int]$group.Size -or @($ReadyStates).Count -lt [int]$group.Size) { return $false }
    $files = @($group.Members | ForEach-Object { Get-Item -LiteralPath (Join-Path $requestPath ($_ + '.json')) -ErrorAction SilentlyContinue })
    if ($files.Count -ne [int]$group.Size) { return $false }
    foreach ($file in $files) {
        $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        try {
            $member = Read-BrokerJsonWithRetry -Path $file.FullName
            $memberGroup = Get-RequestGroupDefinition -Request $member -MaxWorkers ([int]$Config.PoolMaxWorkers)
            if (-not $memberGroup -or $memberGroup.Id -cne $group.Id -or $memberGroup.Size -ne $group.Size -or $member.RequestId -cne $id) { throw 'Group membership changed before admission.' }
            if ((Test-Path -LiteralPath (Join-Path $cancellationPath ($id + '.json'))) -or
                (Test-Path -LiteralPath (Join-Path $resultsPath ($id + '\broker-result.json')))) { throw 'A group member was cancelled or completed before admission.' }
        }
        catch { Stop-PoolRequestGroup -Group $group -Reason $_.Exception.Message; return $false }
    }
    # Bind every member to its worker in one durable write. No other request can
    # interleave this admission, and workers validate this assignment before use.
    $group.Assignments = @(for ($i = 0; $i -lt $files.Count; $i++) {
        [pscustomobject]@{ RequestId = [IO.Path]::GetFileNameWithoutExtension($files[$i].Name); WorkerId = [int]$ReadyStates[$i].WorkerId }
    })
    $group.Status = 'Admitting'
    Save-PoolRequestGroup -Group $group
    try {
        for ($i = 0; $i -lt $files.Count; $i++) {
            if (-not (Start-PoolRequest -State $ReadyStates[$i] -RequestFile $files[$i])) { throw 'A group member could not start.' }
            $assigned = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$ReadyStates[$i].WorkerId)
            if ($assigned.RequestId -cne $group.Assignments[$i].RequestId -or $assigned.Status -notin @('Leased','RunCompleted')) { throw 'A group assignment was lost during launch.' }
        }
        $group.Status = 'Running'
        Save-PoolRequestGroup -Group $group
    }
    catch { Stop-PoolRequestGroup -Group $group -Reason ("Group launch failed: " + $_.Exception.Message) }
    return $true
}

function Resolve-PoolGroupMemberRequest {
    param([Parameter(Mandatory = $true)] $Request, [Parameter(Mandatory = $true)] [int] $WorkerId)
    $definition = Get-RequestGroupDefinition -Request $Request -MaxWorkers ([int]$config.PoolMaxWorkers)
    if (-not $definition) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'State\RequestGroups') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $reservation = Read-BrokerJsonWithRetry -Path $file.FullName
            if ($Request.RequestId -cin @($reservation.Members)) {
                throw 'A reserved group member cannot execute without its original group metadata.'
            }
        }
        return $Request
    }
    $group = Read-BrokerJsonWithRetry -Path (Get-PoolRequestGroupPath -Id $definition.Id)
    $assignment = @($group.Assignments | Where-Object { $_.RequestId -ceq $Request.RequestId -and [int]$_.WorkerId -eq $WorkerId })
    if ($group.Status -notin @('Admitting','Running') -or $assignment.Count -ne 1 -or [int]$group.Size -ne [int]$definition.Size) {
        throw 'The worker has no active reservation for this group member.'
    }
    $member = $Request | Select-Object *
    $member.Operation = $definition.Operation
    $member.PSObject.Properties.Remove('Group')
    $member
}
