function Get-PoolQueuedFiles {
    @(Get-ChildItem -LiteralPath $requestPath -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$' } |
        Sort-Object CreationTimeUtc, Name)
}

function Get-PoolProcessingFiles {
    @(Get-ChildItem -LiteralPath $processingPath -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$' } |
        Sort-Object CreationTimeUtc, Name)
}

function Test-PoolPayloadCleanupDue {
    param(
        [Parameter(Mandatory = $true)] [bool] $MaintenanceActive,
        [Parameter(Mandatory = $true)] [bool] $MaintenanceCleanupCompleted,
        [Parameter(Mandatory = $true)] [bool] $AllWorkerStatesOff,
        [Parameter(Mandatory = $true)] [DateTime] $NowUtc,
        [Parameter(Mandatory = $true)] [DateTime] $NextCleanupUtc
    )

    $AllWorkerStatesOff -and (
        $NowUtc -ge $NextCleanupUtc -or
        ($MaintenanceActive -and -not $MaintenanceCleanupCompleted)
    )
}

function Start-PoolProcess {
    param(
        [Parameter(Mandatory = $true)] [string] $ScriptPath,
        [Parameter(Mandatory = $true)] [string[]] $ScriptArguments
    )

    $argumentList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'))
    foreach ($argument in $ScriptArguments) {
        $argumentList += $argument
    }
    Start-Process -FilePath (Get-PoolPowerShellExecutable) -ArgumentList $argumentList -WindowStyle Hidden -PassThru
}

function Set-PoolLifecycleQueued {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] [ValidateSet('Start', 'Recycle', 'Stop')] [string] $Mode,
        [string] $IdleDeadlineUtc
    )

    $queuedStatus = switch ($Mode) {
        'Start' { 'StartQueued' }
        'Recycle' { 'RecycleQueued' }
        'Stop' { 'StopQueued' }
    }
    Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$State.WorkerId) -Patch ([ordered]@{
        Status = $queuedStatus
        PendingLifecycleMode = $Mode
        OperationId = $null
        ProcessId = $null
        ProcessStartUtc = $null
        RequestId = if ($Mode -eq 'Recycle') { $null } else { $State.RequestId }
        IdleDeadlineUtc = $IdleDeadlineUtc
        OsClean = if ($Mode -eq 'Recycle') { $false } else { [bool]$State.OsClean }
    }) | Out-Null
}

function Start-PoolLifecycleNow {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] [ValidateSet('Start', 'Recycle', 'Stop')] [string] $Mode
    )

    $operationId = [Guid]::NewGuid().ToString('N')
    $status = switch ($Mode) {
        'Start' { 'Starting' }
        'Recycle' { 'Recycling' }
        'Stop' { 'Stopping' }
    }
    $idleDeadline = if (-not [string]::IsNullOrWhiteSpace([string]$State.IdleDeadlineUtc)) {
        [string]$State.IdleDeadlineUtc
    }
    else {
        (Get-PoolIdleDeadline -Config $Config -FromUtc ([DateTime]::UtcNow)).ToString('o')
    }
    Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$State.WorkerId) -Patch ([ordered]@{
        Status = $status
        PendingLifecycleMode = $null
        OperationId = $operationId
        ProcessId = $null
        ProcessStartUtc = $null
        RequestId = $null
        IdleDeadlineUtc = if ($Mode -eq 'Stop') { $null } else { $idleDeadline }
    }) | Out-Null

    $script = Join-Path $PSScriptRoot 'PoolLifecycle.ps1'
    $arguments = @(
        '-BrokerRoot', ('"' + $BrokerRoot + '"'),
        '-WorkerId', ([string][int]$State.WorkerId),
        '-Mode', $Mode,
        '-OperationId', $operationId
    )
    if ($Mode -ne 'Stop') {
        $arguments += @('-IdleDeadlineUtc', ('"' + $idleDeadline + '"'))
    }
    try {
        $process = Start-PoolProcess -ScriptPath $script -ScriptArguments $arguments
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$State.WorkerId) -ExpectedOperationId $operationId -RequireExpectation -Patch ([ordered]@{
            ProcessId = $process.Id
            ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
        }) | Out-Null
    }
    catch {
        $latest = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$State.WorkerId)
        $faultPatch = New-PoolFaultStatePatch -State $latest -Config $Config -ErrorMessage $_.Exception.Message
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$State.WorkerId) -ExpectedOperationId $operationId -RequireExpectation -Patch $faultPatch | Out-Null
    }
}

function Start-PendingPoolLifecycles {
    $states = Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config
    $maxConcurrent = if ($Config.PoolLifecycleConcurrency) { [int]$Config.PoolLifecycleConcurrency } else { 2 }
    $maxConcurrent = [Math]::Max(1, [Math]::Min([int]$Config.PoolMaxWorkers, $maxConcurrent))
    $activeCount = @($states | Where-Object { $_.Status -in @('Starting', 'Recycling', 'Stopping') }).Count
    if ($activeCount -ge $maxConcurrent) {
        return
    }
    $pendingOrder = @('StartQueued', 'RecycleQueued', 'StopQueued')
    foreach ($pendingStatus in $pendingOrder) {
        foreach ($state in @($states | Where-Object Status -eq $pendingStatus | Sort-Object { [int]$_.WorkerId })) {
            if ($activeCount -ge $maxConcurrent) { return }
            $mode = switch ($pendingStatus) {
                'StartQueued' { 'Start' }
                'RecycleQueued' { 'Recycle' }
                'StopQueued' { 'Stop' }
            }
            Start-PoolLifecycleNow -State $state -Mode $mode
            $activeCount++
        }
    }
}

function Complete-PoolQueuedTerminalRequests {
    foreach ($requestFile in Get-PoolQueuedFiles) {
        $requestId = [IO.Path]::GetFileNameWithoutExtension($requestFile.Name)
        if (Move-QueuedRequestWithTerminalResult -QueuedFile $requestFile -RequestId $requestId -Reason 'queued-after-terminal') {
            continue
        }
        $request = $null
        try { $request = Get-Content -Raw -LiteralPath $requestFile.FullName | ConvertFrom-Json } catch { }
        if (-not $request) { continue }
        $createdUtc = $requestFile.CreationTimeUtc
        try { $createdUtc = [DateTime]::Parse([string]$request.CreatedUtc).ToUniversalTime() } catch { }
        $queueTimeoutSeconds = Get-BoundedTimeout -Value $request.QueueTimeoutSeconds -Default 1800 -Minimum 5 -Maximum 86400
        $queueDeadlineUtc = $createdUtc.AddSeconds($queueTimeoutSeconds)
        $cancelFile = Join-Path $cancellationPath ($requestId + '.json')
        $cancelled = Test-Path -LiteralPath $cancelFile -PathType Leaf
        $timedOut = [DateTime]::UtcNow -ge $queueDeadlineUtc
        if (-not $cancelled -and -not $timedOut) { continue }

        $resultRoot = Join-Path $resultsPath $requestId
        New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
        $message = if ($timedOut) { 'Queue timeout expired before a pool worker became available.' } else { 'Cancellation requested before execution.' }
        $terminalResult = [ordered]@{
            RequestId = $requestId
            Success = $false
            HarnessSucceeded = $false
            OverallSucceeded = $false
            TestEvaluated = $false
            TestPassed = $null
            FailureKind = if ($timedOut) { 'QueueTimeout' } else { 'Cancelled' }
            Error = $message
            CreatedUtc = [string]$request.CreatedUtc
            ClaimedUtc = $null
            QueueWaitSeconds = [Math]::Round(([DateTime]::UtcNow - $createdUtc).TotalSeconds, 3)
            QueueTimeoutSeconds = $queueTimeoutSeconds
            QueueDeadlineUtc = $queueDeadlineUtc.ToString('o')
            Cancelled = [bool](-not $timedOut)
            QueueTimedOut = [bool]$timedOut
            ExecutionTimedOut = $false
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
            BrokerIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            BrokerSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
            VmName = $null
            VmFinalState = 'NotStarted'
            PoolWorkerId = $null
        }
        $terminalStatus = if ($timedOut) { 'QueueTimedOut' } else { 'Cancelled' }
        $archiveKind = if ($timedOut) { 'queue-timeout-' } else { 'cancelled-' }
        Invoke-WithTerminalResultPublicationMutex -RequestId $requestId -ScopeRoot $resultRoot -Operation {
            if (-not (Test-Path -LiteralPath (Join-Path $resultRoot 'broker-result.json') -PathType Leaf)) {
                Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status $terminalStatus -Message $message -CreatedUtc $createdUtc
                Write-TerminalJsonAtomic -Path (Join-Path $resultRoot 'broker-result.json') -Value $terminalResult | Out-Null
            }
        }
        $archiveName = $requestId + '-' + $archiveKind + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json'
        try { Move-Item -LiteralPath $requestFile.FullName -Destination (Join-Path $archivePath $archiveName) -Force } catch { }
        Remove-Item -LiteralPath $cancelFile -Force -ErrorAction SilentlyContinue
    }
}

function Write-PoolQueuePositions {
    param([Parameter(Mandatory = $true)] $Config)

    $queued = Get-PoolQueuedFiles
    $activeRequestIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($processingFile in @(Get-ChildItem -LiteralPath $processingPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $null = $activeRequestIds.Add([IO.Path]::GetFileNameWithoutExtension($processingFile.Name))
    }
    try {
        foreach ($workerState in @(Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config)) {
            foreach ($ownedRequestId in @([string]$workerState.RequestId, [string]$workerState.RecoveryRequestId)) {
                if (-not [string]::IsNullOrWhiteSpace($ownedRequestId)) { $null = $activeRequestIds.Add($ownedRequestId) }
            }
        }
    }
    catch {
        # A partial worker inventory is not a safe basis for rewriting shared
        # request state. Leave queue files untouched for the next broker pass.
        return
    }
    foreach ($terminalQueuedFile in @($queued)) {
        $terminalQueuedId = [IO.Path]::GetFileNameWithoutExtension($terminalQueuedFile.Name)
        if (Move-QueuedRequestWithTerminalResult -QueuedFile $terminalQueuedFile -RequestId $terminalQueuedId -Reason 'queued-after-terminal') {
            $queued = @($queued | Where-Object { -not [string]::Equals($_.FullName, $terminalQueuedFile.FullName, [StringComparison]::OrdinalIgnoreCase) })
        }
        elseif ($activeRequestIds.Contains($terminalQueuedId)) {
            # A same-ID queued file is a duplicate, never a new attempt. Move it
            # away before it can rewrite the original request's no-replay state.
            $duplicateArchive = Join-Path $archivePath ($terminalQueuedId + '-duplicate-active-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N') + '.json')
            Move-Item -LiteralPath $terminalQueuedFile.FullName -Destination $duplicateArchive -ErrorAction Stop
            $queued = @($queued | Where-Object { -not [string]::Equals($_.FullName, $terminalQueuedFile.FullName, [StringComparison]::OrdinalIgnoreCase) })
        }
    }
    $queueDepth = $queued.Count
    for ($index = 0; $index -lt $queued.Count; $index++) {
        $file = $queued[$index]
        $requestId = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $resultRoot = Join-Path $resultsPath $requestId
        New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
        $createdUtc = $file.CreationTimeUtc
        try {
            $request = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
            $createdUtc = [DateTime]::Parse([string]$request.CreatedUtc).ToUniversalTime()
        }
        catch { }
        Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'Queued' -Message 'Waiting for an available Hyper-V pool worker.' -QueuePosition ($index + 1) -QueueDepth $queueDepth -CreatedUtc $createdUtc
    }
}

function Start-PoolRequest {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] [IO.FileInfo] $RequestFile
    )

    $workerId = [int]$State.WorkerId
    $requestId = [IO.Path]::GetFileNameWithoutExtension($RequestFile.Name)
    $processingFile = Join-Path $processingPath $RequestFile.Name
    $resultRoot = Join-Path $resultsPath $requestId
    New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
    $claimedUtc = [DateTime]::UtcNow
    $operationId = [Guid]::NewGuid().ToString('N')
    $request = $null
    $exactExpectedPowerOff = $false
    $deliveryMayHaveStarted = $false
    $workerProcess = $null

    try {
        Move-Item -LiteralPath $RequestFile.FullName -Destination $processingFile -ErrorAction Stop
        if (Move-QueuedRequestWithTerminalResult -QueuedFile ([IO.FileInfo]$processingFile) -RequestId $requestId -Reason 'claimed-after-terminal') {
            return $true
        }
        $request = Get-Content -Raw -LiteralPath $processingFile | ConvertFrom-Json
        if (-not [string]::Equals([string]$request.RequestId, $requestId, [StringComparison]::Ordinal)) {
            throw 'RequestId must match the request filename.'
        }
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
            Status = 'Leased'
            RequestId = $requestId
            OperationId = $operationId
            ProcessId = $null
            ProcessStartUtc = $null
            IdleDeadlineUtc = $null
            LeasedUtc = $claimedUtc.ToString('o')
            OsClean = $false
            LastError = $null
        }) | Out-Null
        $createdUtc = [DateTime]::Parse([string]$request.CreatedUtc).ToUniversalTime()
        $executionTimeoutSeconds = Get-BoundedTimeout -Value $request.ExecutionTimeoutSeconds -Default 900 -Minimum 10 -Maximum 7200
        Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'Claimed' -Message ("Pool worker {0:D2} claimed this request." -f $workerId) -CreatedUtc $createdUtc -ClaimedUtc $claimedUtc -ExecutionDeadlineUtc $claimedUtc.AddSeconds($executionTimeoutSeconds) -WorkerId $workerId
        $exactExpectedPowerOff = Test-ExactExpectedGuestPowerOffRequest -Request $request
        if ($exactExpectedPowerOff) {
            $submissionStartedUtc = [DateTime]::UtcNow.ToString('o')
            Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'LaunchingWorker' -Message 'Expected-power-off worker launch is starting; automatic replay is now prohibited.' -CreatedUtc $createdUtc -ClaimedUtc $claimedUtc -ExecutionDeadlineUtc $claimedUtc.AddSeconds($executionTimeoutSeconds) -WorkerId $workerId -ExpectGuestPowerOff $true -ExpectedGuestPowerOffSubmissionStartedUtc $submissionStartedUtc -GuestJobMayHaveLaunched $true
            $deliveryMayHaveStarted = $true
        }

        $script = Join-Path $PSScriptRoot 'HostWorker.ps1'
        $arguments = @(
            '-BrokerRoot', ('"' + $BrokerRoot + '"'),
            '-WorkerId', ([string]$workerId),
            '-RequestId', $requestId,
            '-OperationId', $operationId,
            '-ClaimedUtc', ('"' + $claimedUtc.ToString('o') + '"')
        )
        $process = Start-PoolProcess -ScriptPath $script -ScriptArguments $arguments
        $workerProcess = $process
        $pidState = Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -ExpectedOperationId $operationId -ExpectedRequestId $requestId -RequireExpectation -Patch ([ordered]@{
            ProcessId = $process.Id
            ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
        })
        if (-not $pidState) {
            throw 'Pool worker process identity could not be durably bound to its request assignment.'
        }
        $true
    }
    catch {
        $startFailure = $_
        $requestStateAtFailure = $null
        $requestStateReadFailure = $null
        $requestStatePathAtFailure = Join-Path $resultRoot 'request-state.json'
        if (Test-Path -LiteralPath $requestStatePathAtFailure -PathType Leaf) {
            try { $requestStateAtFailure = Read-BrokerJsonWithRetry -Path $requestStatePathAtFailure }
            catch { $requestStateReadFailure = $_ }
        }
        if (-not $request -and (Test-Path -LiteralPath $processingFile -PathType Leaf)) {
            try { $request = Read-BrokerJsonWithRetry -Path $processingFile } catch { }
        }
        $exactExpectedPowerOffAtFailure = $request -and (Test-ExactExpectedGuestPowerOffRequest -Request $request)
        $launchInterruption = $null
        if ($exactExpectedPowerOffAtFailure) {
            if ($requestStateReadFailure) {
                $launchInterruption = [pscustomobject]@{
                    FailureKind = 'InterruptedRequestStateUnreadable'
                    Message = 'The exact expected-power-off request state was unreadable during pool-worker launch failure; safe replay could not be established.'
                }
            }
            elseif (-not $requestStateAtFailure) {
                $launchInterruption = [pscustomobject]@{
                    FailureKind = 'ExpectedGuestPowerOffStateMissing'
                    Message = 'The exact expected-power-off request had no durable state during pool-worker launch failure; a prior launch could not be excluded safely.'
                }
            }
            else {
                $launchClassification = Get-PoolInterruptedExpectedGuestPowerOffState -Request $request -RequestState $requestStateAtFailure
                if ($launchClassification.Disposition -eq 'InvalidState') {
                    $launchInterruption = [pscustomobject]@{
                        FailureKind = 'ExpectedGuestPowerOffStateInvalid'
                        Message = "The exact expected-power-off request state was invalid during pool-worker launch failure: $([string]$launchClassification.Reason)"
                    }
                }
                elseif ($launchClassification.Disposition -eq 'ProtectedNoReplay') {
                    $launchInterruption = [pscustomobject]@{
                        FailureKind = 'ExpectedGuestPowerOffWorkerLaunchInterrupted'
                        Message = 'Durable expected-power-off delivery state prohibits replay after the pool-worker launch failure.'
                    }
                }
            }
        }
        elseif ($exactExpectedPowerOff -and $deliveryMayHaveStarted) {
            $launchInterruption = [pscustomobject]@{
                FailureKind = 'ExpectedGuestPowerOffWorkerLaunchInterrupted'
                Message = 'Expected-power-off delivery may have started, and the request could not be reclassified safely after pool-worker launch failure.'
            }
        }

        if ($launchInterruption) {
            if ($workerProcess) {
                try {
                    $workerProcess.Refresh()
                    if (-not $workerProcess.HasExited) {
                        $workerProcess.Kill()
                        [void]$workerProcess.WaitForExit(5000)
                    }
                }
                catch {
                    # Cleanup verification below remains authoritative and will
                    # surface any process/VM handoff residue as a failure.
                }
            }
            $workerDefinition = Get-PoolWorkerDefinition -Config $Config -WorkerId $workerId
            $cleanup = Invoke-InterruptedRequestCleanup -BrokerRoot $BrokerRoot -VmName ([string]$workerDefinition.VmName) -RequestId $requestId
            $message = "$([string]$launchInterruption.Message) The request was failed terminally and will not be replayed. $($startFailure.Exception.Message)"
            Publish-InterruptedRequestTerminalResult -ResultRoot $resultRoot -RequestId $requestId -Request $request -RequestState $requestStateAtFailure -FailureKind ([string]$launchInterruption.FailureKind) -FailureStage 'PoolWorkerLaunch' -Message $message -VmName ([string]$workerDefinition.VmName) -WorkerId $workerId -Cleanup $cleanup -PoolWorkerRecyclePending $true | Out-Null
            if (Test-Path -LiteralPath $processingFile -PathType Leaf) {
                Move-Item -LiteralPath $processingFile -Destination (Join-Path $archivePath ($requestId + '-pool-worker-launch-interrupted-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')) -Force
            }
            $queuedDuplicate = Join-Path $requestPath $RequestFile.Name
            if (Test-Path -LiteralPath $queuedDuplicate -PathType Leaf) {
                Move-QueuedRequestWithTerminalResult -QueuedFile ([IO.FileInfo]$queuedDuplicate) -RequestId $requestId -Reason 'worker-launch-queued-after-terminal' | Out-Null
            }
            Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
                Status = 'Faulted'
                RequestId = $null
                OperationId = $null
                ProcessId = $null
                ProcessStartUtc = $null
                OsClean = $false
                LastError = $message
            }) | Out-Null
            return $false
        }
        if (Test-Path -LiteralPath $processingFile -PathType Leaf) {
            try { Move-Item -LiteralPath $processingFile -Destination (Join-Path $requestPath $RequestFile.Name) -Force } catch { }
        }
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
            Status = 'Ready'
            RequestId = $null
            OperationId = $null
            ProcessId = $null
            ProcessStartUtc = $null
            OsClean = $true
            IdleDeadlineUtc = (Get-PoolIdleDeadline -Config $Config -FromUtc ([DateTime]::UtcNow)).ToString('o')
            LastError = $startFailure.Exception.Message
        }) | Out-Null
        $false
    }
}

function Get-PoolInterruptedExpectedGuestPowerOffState {
    [CmdletBinding()]
    param(
        [AllowNull()] $Request,
        [AllowNull()] $RequestState
    )

    if (-not $Request) { return $null }
    $requestExpectation = @($Request.PSObject.Properties | Where-Object { $_.Name -ceq 'ExpectGuestPowerOff' }) | Select-Object -First 1
    if (-not $requestExpectation -or $requestExpectation.Value -isnot [bool] -or -not [bool]$requestExpectation.Value) { return $null }

    $newClassification = {
        param([string] $Disposition, [string] $Reason, [AllowNull()] $State)
        [pscustomobject][ordered]@{
            Disposition = $Disposition
            Reason = $Reason
            RequestState = $State
        }
    }
    if (-not $RequestState) {
        return (& $newClassification -Disposition 'InvalidState' -Reason 'The exact expected-power-off request state is missing.' -State $null)
    }

    $contractPropertyNames = @(
        'ExpectGuestPowerOff',
        'ExpectedGuestPowerOffSubmissionStartedUtc',
        'GuestJobMayHaveLaunched',
        'GuestApplicationEraRunningObservedUtc',
        'GuestPowerOffObservedUtc',
        'GuestPowerOffBeforeCleanup',
        'PowerOffRecoveryDeadlineUtc',
        'BrokerCleanupStartedUtc'
    )
    $contractProperties = @{}
    foreach ($propertyName in $contractPropertyNames) {
        $matches = @($RequestState.PSObject.Properties | Where-Object {
            [string]::Equals([string]$_.Name, $propertyName, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -gt 1 -or ($matches.Count -eq 1 -and $matches[0].Name -cne $propertyName)) {
            return (& $newClassification -Disposition 'InvalidState' -Reason "Persisted property $propertyName is duplicated or has incorrect casing." -State $RequestState)
        }
        $contractProperties[$propertyName] = if ($matches.Count -eq 1) { $matches[0] } else { $null }
    }

    $stateExpectation = $contractProperties['ExpectGuestPowerOff']
    if (-not $stateExpectation) {
        $otherContractProperty = @($contractPropertyNames | Where-Object {
            $_ -cne 'ExpectGuestPowerOff' -and $null -ne $contractProperties[$_]
        }) | Select-Object -First 1
        $historicalContractProperty = $false
        foreach ($historyEntry in @($RequestState.History | Where-Object { $null -ne $_ })) {
            foreach ($propertyName in $contractPropertyNames) {
                if (@($historyEntry.PSObject.Properties | Where-Object {
                    [string]::Equals([string]$_.Name, $propertyName, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0) {
                    $historicalContractProperty = $true
                    break
                }
            }
            if ($historicalContractProperty) { break }
        }
        if ($otherContractProperty -or $historicalContractProperty) {
            return (& $newClassification -Disposition 'InvalidState' -Reason 'Expected-power-off contract markers exist without an exact ExpectGuestPowerOff state opt-in.' -State $RequestState)
        }
        return (& $newClassification -Disposition 'SafePreDelivery' -Reason 'No expected-power-off delivery marker has been persisted.' -State $RequestState)
    }
    if ($stateExpectation.Value -isnot [bool] -or -not [bool]$stateExpectation.Value) {
        return (& $newClassification -Disposition 'InvalidState' -Reason 'ExpectGuestPowerOff must be the exact JSON Boolean true once the contract is persisted.' -State $RequestState)
    }

    foreach ($booleanPropertyName in @('GuestJobMayHaveLaunched', 'GuestPowerOffBeforeCleanup')) {
        $booleanProperty = $contractProperties[$booleanPropertyName]
        if ($booleanProperty -and $null -ne $booleanProperty.Value -and $booleanProperty.Value -isnot [bool]) {
            return (& $newClassification -Disposition 'InvalidState' -Reason "Persisted property $booleanPropertyName must be an exact JSON Boolean or null." -State $RequestState)
        }
    }

    $timestampValues = @{}
    foreach ($timestampPropertyName in @(
        'ExpectedGuestPowerOffSubmissionStartedUtc',
        'GuestApplicationEraRunningObservedUtc',
        'GuestPowerOffObservedUtc',
        'PowerOffRecoveryDeadlineUtc',
        'BrokerCleanupStartedUtc'
    )) {
        $timestampProperty = $contractProperties[$timestampPropertyName]
        if (-not $timestampProperty -or $null -eq $timestampProperty.Value) {
            $timestampValues[$timestampPropertyName] = $null
            continue
        }
        if ($timestampProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$timestampProperty.Value)) {
            return (& $newClassification -Disposition 'InvalidState' -Reason "Persisted property $timestampPropertyName must be a non-empty timestamp string or null." -State $RequestState)
        }
        $parsedTimestamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse(
            [string]$timestampProperty.Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AllowWhiteSpaces,
            [ref]$parsedTimestamp
        )) {
            return (& $newClassification -Disposition 'InvalidState' -Reason "Persisted property $timestampPropertyName is not a valid timestamp." -State $RequestState)
        }
        $timestampValues[$timestampPropertyName] = [string]$timestampProperty.Value
    }

    $submissionPersisted = $null -ne $timestampValues['ExpectedGuestPowerOffSubmissionStartedUtc']
    $mayHaveLaunchedProperty = $contractProperties['GuestJobMayHaveLaunched']
    $mayHaveLaunchedSet = $mayHaveLaunchedProperty -and $null -ne $mayHaveLaunchedProperty.Value
    $mayHaveLaunched = $mayHaveLaunchedSet -and [bool]$mayHaveLaunchedProperty.Value
    if ($mayHaveLaunchedSet -and -not $mayHaveLaunched) {
        return (& $newClassification -Disposition 'InvalidState' -Reason 'GuestJobMayHaveLaunched cannot be false in a persisted exact expected-power-off delivery contract.' -State $RequestState)
    }
    if ($submissionPersisted -ne $mayHaveLaunched) {
        return (& $newClassification -Disposition 'InvalidState' -Reason 'ExpectedGuestPowerOffSubmissionStartedUtc and exact GuestJobMayHaveLaunched=true must be persisted together.' -State $RequestState)
    }

    $applicationRunningPersisted = $null -ne $timestampValues['GuestApplicationEraRunningObservedUtc']
    $powerOffPersisted = $null -ne $timestampValues['GuestPowerOffObservedUtc']
    $powerOffBeforeCleanupProperty = $contractProperties['GuestPowerOffBeforeCleanup']
    $powerOffBeforeCleanupSet = $powerOffBeforeCleanupProperty -and $null -ne $powerOffBeforeCleanupProperty.Value
    $powerOffBeforeCleanup = $powerOffBeforeCleanupSet -and [bool]$powerOffBeforeCleanupProperty.Value
    if ($powerOffBeforeCleanupSet -and -not $powerOffBeforeCleanup) {
        return (& $newClassification -Disposition 'InvalidState' -Reason 'GuestPowerOffBeforeCleanup cannot be false in a persisted exact expected-power-off contract.' -State $RequestState)
    }
    if ($powerOffPersisted -ne $powerOffBeforeCleanup) {
        return (& $newClassification -Disposition 'InvalidState' -Reason 'GuestPowerOffObservedUtc and exact GuestPowerOffBeforeCleanup=true must be persisted together.' -State $RequestState)
    }
    if ($powerOffPersisted -and -not $applicationRunningPersisted) {
        return (& $newClassification -Disposition 'InvalidState' -Reason 'Guest power-off markers exist without an application-era Running observation.' -State $RequestState)
    }
    if ($null -ne $timestampValues['PowerOffRecoveryDeadlineUtc'] -and -not $powerOffPersisted) {
        return (& $newClassification -Disposition 'InvalidState' -Reason 'PowerOffRecoveryDeadlineUtc exists without complete guest power-off markers.' -State $RequestState)
    }

    if ($submissionPersisted -or $applicationRunningPersisted -or $powerOffPersisted) {
        return (& $newClassification -Disposition 'ProtectedNoReplay' -Reason 'Durable expected-power-off delivery or execution evidence prohibits replay.' -State $RequestState)
    }
    if ($null -ne $timestampValues['BrokerCleanupStartedUtc']) {
        return (& $newClassification -Disposition 'InvalidState' -Reason 'BrokerCleanupStartedUtc exists without durable expected-power-off delivery or execution evidence.' -State $RequestState)
    }

    (& $newClassification -Disposition 'InvalidState' -Reason 'ExpectGuestPowerOff was persisted without a complete delivery marker, so safe pre-delivery cannot be established.' -State $RequestState)
}

function Invoke-PoolInterruptedRequestCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Config,
        [string] $RequestId,
        [AllowNull()] [Nullable[int]] $WorkerId
    )

    $startedUtc = [DateTime]::UtcNow
    $errors = New-Object Collections.Generic.List[string]
    $cleanup = $null
    $worker = if ($null -ne $WorkerId) { @($Config.PoolWorkers | Where-Object { [int]$_.WorkerId -eq [int]$WorkerId }) | Select-Object -First 1 } else { $null }
    $currentState = if ($worker) { Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$worker.WorkerId) } else { $null }
    if (-not $worker -or -not $currentState) {
        $errors.Add('No pool worker could be safely identified for interrupted-request cleanup verification.')
    }
    else {
        $workerProcessAlive = Test-PoolProcessAlive -ProcessId $currentState.ProcessId -ProcessStartUtc $currentState.ProcessStartUtc
        $ownsCurrentRequest = [string]::Equals([string]$currentState.RequestId, $RequestId, [StringComparison]::Ordinal)
        $ownsRecoveryRequest = [string]::Equals([string]$currentState.RecoveryRequestId, $RequestId, [StringComparison]::Ordinal)
        $destructiveCleanupSafe = -not $workerProcessAlive -and ($ownsCurrentRequest -or ($ownsRecoveryRequest -and $currentState.Status -in @('Off', 'Faulted', 'RecycleQueued', 'Recycling', 'RecoveringInterruptedRun')))
        $cleanRecycleAlreadyVerified = -not $workerProcessAlive -and $ownsRecoveryRequest -and [bool]$currentState.OsClean -and $currentState.Status -in @('Ready', 'Off')
        if ($destructiveCleanupSafe) {
            $cleanup = Invoke-InterruptedRequestCleanup -BrokerRoot $BrokerRoot -VmName ([string]$worker.VmName) -RequestId $RequestId
            foreach ($cleanupError in @($cleanup.Errors)) { $errors.Add([string]$cleanupError) }
        }
        elseif ($cleanRecycleAlreadyVerified) {
            $vmFinalState = 'Unknown'
            try { $vmFinalState = [string](Get-VM -Name ([string]$worker.VmName) -ErrorAction Stop).State }
            catch { $errors.Add("Could not verify the recycled worker VM state: $($_.Exception.Message)") }
            try {
                $connectedAdapters = @(Get-VMNetworkAdapter -VMName ([string]$worker.VmName) -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) })
                if ($connectedAdapters.Count -ne 0) { $errors.Add('The recycled worker still has a connected network adapter.') }
            }
            catch { $errors.Add("Could not verify the recycled worker network inventory: $($_.Exception.Message)") }
            try {
                $hostInputLeases = @(Get-ChildItem -LiteralPath (Get-HostInputStateRoot -BrokerRoot $BrokerRoot) -Filter '*.json' -File -ErrorAction Stop | ForEach-Object { Read-BrokerJsonWithRetry -Path $_.FullName })
                if (@($hostInputLeases | Where-Object { [string]::Equals([string]$_.RequestId, $RequestId, [StringComparison]::Ordinal) }).Count -ne 0) {
                    $errors.Add('A host-input lease for the interrupted request remains after clean-worker recycle.')
                }
            }
            catch { $errors.Add("Could not verify recycled host-input lease cleanup: $($_.Exception.Message)") }
            try {
                $networkLeases = @(Get-RequestNetworkLeaseInventory -BrokerRoot $BrokerRoot)
                if (@($networkLeases | Where-Object { [string]::Equals([string]$_.RequestId, $RequestId, [StringComparison]::Ordinal) }).Count -ne 0) {
                    $errors.Add('A request-network lease for the interrupted request remains after clean-worker recycle.')
                }
            }
            catch { $errors.Add("Could not verify recycled request-network lease cleanup: $($_.Exception.Message)") }
            $cleanup = [pscustomobject][ordered]@{
                Attempted = $false
                VerificationOnly = $true
                Success = $errors.Count -eq 0
                StartedUtc = $startedUtc.ToString('o')
                CompletedUtc = [DateTime]::UtcNow.ToString('o')
                RequestId = $RequestId
                VmName = [string]$worker.VmName
                VmFinalState = $vmFinalState
                Errors = $errors.ToArray()
            }
        }
        else {
            $errors.Add("Worker $([int]$worker.WorkerId) is live, ready for unrelated work, or no longer owns this request; cleanup mutation was refused.")
        }
    }
    if ($cleanup) { return $cleanup }
    [pscustomobject][ordered]@{
        Attempted = $false
        Success = $false
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        RequestId = $RequestId
        VmName = if ($worker) { [string]$worker.VmName } else { $null }
        VmFinalState = 'Unknown'
        Errors = $errors.ToArray()
    }
}

function Complete-PoolWorkerRun {
    param([Parameter(Mandatory = $true)] $State)

    $workerId = [int]$State.WorkerId
    $requestId = [string]$State.RequestId
    if ([string]::IsNullOrWhiteSpace($requestId)) {
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
            Status = 'Faulted'
            OperationId = $null
            ProcessId = $null
            ProcessStartUtc = $null
            LastError = 'A completed request worker had no RequestId.'
        }) | Out-Null
        return
    }
    $latestAssignment = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId
    if (-not $latestAssignment -or
        -not [string]::Equals([string]$latestAssignment.RequestId, $requestId, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$latestAssignment.OperationId, [string]$State.OperationId, [StringComparison]::Ordinal)) {
        return
    }
    if (Test-PoolProcessAlive -ProcessId $latestAssignment.ProcessId -ProcessStartUtc $latestAssignment.ProcessStartUtc) {
        # The child may have published its own PID after the parent snapshot was
        # taken. Never clean, recycle, or terminalize a still-live assignment.
        return
    }
    $expectedProcessId = if ($null -ne $latestAssignment.ProcessId) { [Nullable[int]]([int]$latestAssignment.ProcessId) } else { $null }
    $invalidatedAssignment = Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -ExpectedOperationId ([string]$latestAssignment.OperationId) -ExpectedRequestId $requestId -ExpectedProcessId $expectedProcessId -RequireExpectation -RequireProcessExpectation -Patch ([ordered]@{
        Status = 'RecoveringInterruptedRun'
        OperationId = $null
        ProcessId = $null
        ProcessStartUtc = $null
        OsClean = $false
    })
    if (-not $invalidatedAssignment) {
        # A concurrently starting child won the state mutex and published its
        # identity. The next broker loop will re-evaluate its live lease.
        return
    }
    $State = $invalidatedAssignment
    $processingFile = Join-Path $processingPath ($requestId + '.json')
    $resultRoot = Join-Path $resultsPath $requestId
    $brokerResult = Join-Path $resultRoot 'broker-result.json'
    $requestStatePath = Join-Path $resultRoot 'request-state.json'
    $releasedUtc = if (-not [string]::IsNullOrWhiteSpace([string]$State.LastReleasedUtc)) {
        [DateTime]::Parse([string]$State.LastReleasedUtc).ToUniversalTime()
    }
    else { [DateTime]::UtcNow }
    $idleDeadline = Get-PoolIdleDeadline -Config $Config -FromUtc $releasedUtc

    if (-not (Test-Path -LiteralPath $brokerResult -PathType Leaf) -and
        (Test-Path -LiteralPath $processingFile -PathType Leaf)) {
        $interruptedRequest = $null
        $interruptedRequestState = $null
        $interruptionTerminal = $null
        try {
            $interruptedRequest = Read-BrokerJsonWithRetry -Path $processingFile
        }
        catch {
            $interruptionTerminal = [pscustomobject]@{
                FailureKind = 'InterruptedRequestUnreadable'
                Message = 'The interrupted pool processing request could not be read reliably. It was failed terminally and quarantined rather than risk replaying an unknown application job.'
            }
        }
        if (-not $interruptionTerminal -and (Test-Path -LiteralPath $requestStatePath -PathType Leaf)) {
            try { $interruptedRequestState = Read-BrokerJsonWithRetry -Path $requestStatePath }
            catch {
                $interruptionTerminal = [pscustomobject]@{
                    FailureKind = 'InterruptedRequestStateUnreadable'
                    Message = 'The interrupted pool request state remained unreadable after bounded retries. It was failed terminally because replay safety could not be established.'
                }
            }
        }
        elseif (-not $interruptionTerminal -and (Test-ExactExpectedGuestPowerOffRequest -Request $interruptedRequest)) {
            $interruptionTerminal = [pscustomobject]@{
                FailureKind = 'ExpectedGuestPowerOffStateMissing'
                Message = 'The exact expected-power-off pool request had no durable state after worker interruption. It was failed terminally because a prior launch could not be excluded.'
            }
        }
        $powerOffInterruption = if (-not $interruptionTerminal) { Get-PoolInterruptedExpectedGuestPowerOffState -Request $interruptedRequest -RequestState $interruptedRequestState } else { $null }
        if ($powerOffInterruption -and $powerOffInterruption.Disposition -eq 'InvalidState') {
            $interruptionTerminal = [pscustomobject]@{
                FailureKind = 'ExpectedGuestPowerOffStateInvalid'
                Message = "The interrupted exact expected-power-off request state was invalid: $([string]$powerOffInterruption.Reason) The request was failed terminally because safe replay could not be established."
            }
        }
        $protectedPowerOffState = if ($powerOffInterruption -and $powerOffInterruption.Disposition -eq 'ProtectedNoReplay') { $powerOffInterruption.RequestState } else { $null }
        if ($protectedPowerOffState) {
            $shutdownBeforeCleanupProperty = $protectedPowerOffState.PSObject.Properties['GuestPowerOffBeforeCleanup']
            $causalPowerOffPersisted = -not [string]::IsNullOrWhiteSpace([string]$protectedPowerOffState.GuestPowerOffObservedUtc) -and
                $shutdownBeforeCleanupProperty -and $shutdownBeforeCleanupProperty.Value -is [bool] -and [bool]$shutdownBeforeCleanupProperty.Value
            $applicationRunningPersisted = -not [string]::IsNullOrWhiteSpace([string]$protectedPowerOffState.GuestApplicationEraRunningObservedUtc)
            $submissionAmbiguous = -not [string]::IsNullOrWhiteSpace([string]$protectedPowerOffState.ExpectedGuestPowerOffSubmissionStartedUtc) -and
                $protectedPowerOffState.PSObject.Properties['GuestJobMayHaveLaunched'] -and
                $protectedPowerOffState.GuestJobMayHaveLaunched -is [bool] -and [bool]$protectedPowerOffState.GuestJobMayHaveLaunched
            $interruptionTerminal = [pscustomobject]@{
                FailureKind = if ($causalPowerOffPersisted) { 'GuestPowerOffEvidenceRecoveryInterrupted' } elseif ($applicationRunningPersisted) { 'ExpectedGuestPowerOffWorkerInterrupted' } else { 'ExpectedGuestPowerOffSubmissionInterrupted' }
                Message = if ($causalPowerOffPersisted) {
                    'The request worker exited after host-observed application-era Running-to-Off causality but before evidence recovery completed. The request was failed terminally and will not be replayed.'
                }
                elseif ($applicationRunningPersisted) {
                    'The request worker exited after the expected-power-off application was confirmed running. A later shutdown may already have been scheduled, so the request was failed terminally and will not be replayed.'
                }
                elseif ($submissionAmbiguous) {
                    'The request worker exited after expected-power-off job delivery began but before launch outcome was known. The request was failed terminally and will not be replayed.'
                }
                else {
                    'The request worker exited with ambiguous expected-power-off delivery state. The request was failed terminally and will not be replayed.'
                }
            }
        }
        if ($interruptionTerminal) {
            $cleanup = Invoke-InterruptedRequestCleanup -BrokerRoot $BrokerRoot -VmName ([string]$State.VmName) -RequestId $requestId
            Publish-InterruptedRequestTerminalResult -ResultRoot $resultRoot -RequestId $requestId -Request $interruptedRequest -RequestState $interruptedRequestState -FailureKind ([string]$interruptionTerminal.FailureKind) -FailureStage 'PoolWorkerRecovery' -Message ([string]$interruptionTerminal.Message) -VmName ([string]$State.VmName) -WorkerId $workerId -Cleanup $cleanup -PoolWorkerRecyclePending $true | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $brokerResult -PathType Leaf)) {
        $retryRequest = $null
        try {
            if (Test-Path -LiteralPath $processingFile -PathType Leaf) {
                $retryRequest = Get-Content -Raw -LiteralPath $processingFile | ConvertFrom-Json
            }
        }
        catch {
            $retryRequest = $null
        }
        $pendingRetryProperty = if ($retryRequest) { $retryRequest.PSObject.Properties['PendingInfrastructureRetry'] } else { $null }
        $pendingRetryIsExact = $pendingRetryProperty -and $pendingRetryProperty.Value -is [bool] -and [bool]$pendingRetryProperty.Value
        if ($retryRequest -and $pendingRetryIsExact -and -not (Test-ExactExpectedGuestPowerOffRequest -Request $retryRequest)) {
            try {
                $retryRequest.PendingInfrastructureRetry = $false
                $retryRequest | Add-Member -NotePropertyName InfrastructureRetryQueuedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                Write-PoolJsonAtomic -Path $processingFile -Value $retryRequest
                $queuedFile = Join-Path $requestPath ($requestId + '.json')
                if (Test-Path -LiteralPath $queuedFile -PathType Leaf) {
                    throw 'A duplicate queued file already exists for the infrastructure retry.'
                }
                Move-Item -LiteralPath $processingFile -Destination $queuedFile
                Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
                    RecoveryRequestId = $null
                    RequestId = $null
                    OperationId = $null
                    ProcessId = $null
                    ProcessStartUtc = $null
                    IdleDeadlineUtc = $idleDeadline.ToString('o')
                    LastError = 'Transient capture failure; request was requeued once while this worker recycles.'
                }) | Out-Null
                $refreshed = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId
                Set-PoolLifecycleQueued -State $refreshed -Mode Recycle -IdleDeadlineUtc $idleDeadline.ToString('o')
                $createdUtc = [DateTime]::Parse([string]$retryRequest.CreatedUtc).ToUniversalTime()
                Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'RetryQueued' -Message 'Transient capture failure; waiting for a different clean worker while the failed worker recycles.' -CreatedUtc $createdUtc
                return
            }
            catch {
                Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
                    LastError = "Could not requeue the transient capture retry asynchronously: $($_.Exception.Message)"
                }) | Out-Null
            }
        }
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
            RecoveryRequestId = $requestId
            RequestId = $null
            OperationId = $null
            ProcessId = $null
            ProcessStartUtc = $null
            IdleDeadlineUtc = $idleDeadline.ToString('o')
            LastError = 'The request worker exited before publishing broker-result.json; it will be requeued after the VM is clean.'
        }) | Out-Null
        $refreshed = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId
        Set-PoolLifecycleQueued -State $refreshed -Mode Recycle -IdleDeadlineUtc $idleDeadline.ToString('o')
        return
    }

    if (Test-Path -LiteralPath $processingFile -PathType Leaf) {
        $archiveFile = Join-Path $archivePath ($requestId + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
        Move-Item -LiteralPath $processingFile -Destination $archiveFile -Force
    }
    $queuedDuplicate = Join-Path $requestPath ($requestId + '.json')
    if (Test-Path -LiteralPath $queuedDuplicate -PathType Leaf) {
        Move-QueuedRequestWithTerminalResult -QueuedFile ([IO.FileInfo]$queuedDuplicate) -RequestId $requestId -Reason 'queued-after-worker-terminal' | Out-Null
    }
    Remove-Item -LiteralPath (Join-Path $cancellationPath ($requestId + '.json')) -Force -ErrorAction SilentlyContinue
    try { Remove-StagedPayloadSafe -RequestId $requestId } catch { }
    Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
        RequestId = $null
        OperationId = $null
        ProcessId = $null
        ProcessStartUtc = $null
        IdleDeadlineUtc = $idleDeadline.ToString('o')
        LastReleasedUtc = $releasedUtc.ToString('o')
    }) | Out-Null
    $refreshed = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId
    Set-PoolLifecycleQueued -State $refreshed -Mode Recycle -IdleDeadlineUtc $idleDeadline.ToString('o')
}

function Reconcile-PoolRecoveryRequests {
    foreach ($state in Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config) {
        $requestId = [string]$state.RecoveryRequestId
        if ([string]::IsNullOrWhiteSpace($requestId) -or $state.Status -notin @('Ready', 'Off', 'Faulted')) { continue }
        $processingFile = Join-Path $processingPath ($requestId + '.json')
        $queuedFile = Join-Path $requestPath ($requestId + '.json')
        if (Test-Path -LiteralPath $processingFile -PathType Leaf) {
            $resultRoot = Join-Path $resultsPath $requestId
            $brokerResult = Join-Path $resultRoot 'broker-result.json'
            $requestStatePath = Join-Path $resultRoot 'request-state.json'
            $recoveryTerminal = $null
            $recoveryRequest = $null
            $recoveryRequestState = $null
            if (-not (Test-Path -LiteralPath $brokerResult -PathType Leaf)) {
                try { $recoveryRequest = Read-BrokerJsonWithRetry -Path $processingFile }
                catch {
                    $recoveryTerminal = [pscustomobject]@{
                        FailureKind = 'InterruptedRequestUnreadable'
                        Message = 'The recycled pool worker request could not be read reliably before replay. It was failed terminally and quarantined rather than risk an unknown second launch.'
                    }
                }
                if (-not $recoveryTerminal -and (Test-Path -LiteralPath $requestStatePath -PathType Leaf)) {
                    try { $recoveryRequestState = Read-BrokerJsonWithRetry -Path $requestStatePath }
                    catch {
                        $recoveryTerminal = [pscustomobject]@{
                            FailureKind = 'InterruptedRequestStateUnreadable'
                            Message = 'The recycled pool request state remained unreadable after bounded retries. It was failed terminally because replay safety could not be established.'
                        }
                    }
                }
                elseif (-not $recoveryTerminal -and (Test-ExactExpectedGuestPowerOffRequest -Request $recoveryRequest)) {
                    $recoveryTerminal = [pscustomobject]@{
                        FailureKind = 'ExpectedGuestPowerOffStateMissing'
                        Message = 'The recycled exact expected-power-off request had no durable state. It was failed terminally because a prior launch could not be excluded.'
                    }
                }
                $powerOffInterruption = if (-not $recoveryTerminal) { Get-PoolInterruptedExpectedGuestPowerOffState -Request $recoveryRequest -RequestState $recoveryRequestState } else { $null }
                if ($powerOffInterruption -and $powerOffInterruption.Disposition -eq 'InvalidState') {
                    $recoveryTerminal = [pscustomobject]@{
                        FailureKind = 'ExpectedGuestPowerOffStateInvalid'
                        Message = "The recycled exact expected-power-off request state was invalid: $([string]$powerOffInterruption.Reason) Replay was refused because safe pre-delivery could not be established."
                    }
                }
                $protectedPowerOffState = if ($powerOffInterruption -and $powerOffInterruption.Disposition -eq 'ProtectedNoReplay') { $powerOffInterruption.RequestState } else { $null }
                if ($protectedPowerOffState) {
                    $runningPersisted = -not [string]::IsNullOrWhiteSpace([string]$protectedPowerOffState.GuestApplicationEraRunningObservedUtc)
                    $shutdownBeforeCleanupProperty = $protectedPowerOffState.PSObject.Properties['GuestPowerOffBeforeCleanup']
                    $causalPowerOffPersisted = -not [string]::IsNullOrWhiteSpace([string]$protectedPowerOffState.GuestPowerOffObservedUtc) -and
                        $shutdownBeforeCleanupProperty -and $shutdownBeforeCleanupProperty.Value -is [bool] -and [bool]$shutdownBeforeCleanupProperty.Value
                    $recoveryTerminal = [pscustomobject]@{
                        FailureKind = if ($causalPowerOffPersisted) { 'GuestPowerOffEvidenceRecoveryInterrupted' } elseif ($runningPersisted) { 'ExpectedGuestPowerOffWorkerInterrupted' } else { 'ExpectedGuestPowerOffSubmissionInterrupted' }
                        Message = if ($causalPowerOffPersisted) {
                            'Replay was refused after host-observed expected-power-off Running-to-Off causality because evidence recovery was interrupted.'
                        }
                        elseif ($runningPersisted) {
                            'Replay was refused after the expected-power-off application was confirmed running because a later shutdown may already have been scheduled.'
                        }
                        else {
                            'Replay was refused because expected-power-off job delivery had begun and the original launch outcome was ambiguous.'
                        }
                    }
                }
                if ($recoveryTerminal) {
                    $cleanup = Invoke-PoolInterruptedRequestCleanup -Config $Config -RequestId $requestId -WorkerId ([Nullable[int]]([int]$state.WorkerId))
                    $cleanupVmName = if ($cleanup.VmName) { [string]$cleanup.VmName } else { [string]$state.VmName }
                    Publish-InterruptedRequestTerminalResult -ResultRoot $resultRoot -RequestId $requestId -Request $recoveryRequest -RequestState $recoveryRequestState -FailureKind ([string]$recoveryTerminal.FailureKind) -FailureStage 'PoolRecoveryRequeue' -Message ([string]$recoveryTerminal.Message) -VmName $cleanupVmName -WorkerId ([int]$state.WorkerId) -Cleanup $cleanup -PoolWorkerRecyclePending $false | Out-Null
                }
            }

            if (Test-Path -LiteralPath $brokerResult -PathType Leaf) {
                Move-Item -LiteralPath $processingFile -Destination (Join-Path $archivePath ($requestId + '-recovery-terminal-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')) -Force
                if (Test-Path -LiteralPath $queuedFile -PathType Leaf) {
                    Move-QueuedRequestWithTerminalResult -QueuedFile ([IO.FileInfo]$queuedFile) -RequestId $requestId -Reason 'recovery-queued-after-terminal' | Out-Null
                }
            }
            elseif (Test-Path -LiteralPath $queuedFile -PathType Leaf) {
                Move-Item -LiteralPath $processingFile -Destination (Join-Path $archivePath ($requestId + '-recovery-duplicate-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')) -Force
            }
            else {
                Move-Item -LiteralPath $processingFile -Destination $queuedFile
            }
        }
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$state.WorkerId) -Patch ([ordered]@{
            RecoveryRequestId = $null
            LastError = $null
        }) | Out-Null
    }
}

function Reap-PoolProcesses {
    foreach ($state in Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config) {
        $alive = Test-PoolProcessAlive -ProcessId $state.ProcessId -ProcessStartUtc $state.ProcessStartUtc
        if ($state.Status -in @('Leased', 'RunCompleted') -and -not $alive) {
            Complete-PoolWorkerRun -State $state
            continue
        }
        if ($state.Status -in @('Starting', 'Recycling', 'Stopping') -and -not $alive) {
            $latest = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$state.WorkerId)
            if ($latest.Status -in @('Starting', 'Recycling', 'Stopping')) {
                try { Stop-TestVm -VmName ([string]$state.VmName) -Immediate } catch { }
                $faultPatch = New-PoolFaultStatePatch -State $latest -Config $Config -ErrorMessage 'The VM lifecycle process exited before reaching a terminal state.'
                Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$state.WorkerId) -Patch $faultPatch | Out-Null
            }
        }
    }
}

function Queue-FaultedPoolWorkerRecovery {
    $now = [DateTime]::UtcNow
    $candidate = @(Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config | Where-Object {
        Test-PoolWorkerFaultRecoveryEligible -State $_ -NowUtc $now
    } | Sort-Object FaultRecoveryNotBeforeUtc, @{ Expression = { [int]$_.WorkerId } }) | Select-Object -First 1
    if (-not $candidate) {
        return
    }

    Set-PoolLifecycleQueued -State $candidate -Mode Recycle -IdleDeadlineUtc (Get-PoolIdleDeadline -Config $Config -FromUtc $now).ToString('o')
}

function Ensure-PoolDemandCapacity {
    $queued = Get-PoolQueuedFiles
    if ($queued.Count -eq 0) { return }
    $states = Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config
    $potential = @($states | Where-Object { $_.Status -in @('Ready', 'Starting', 'StartQueued', 'Recycling', 'RecycleQueued') })
    if ($potential.Count -gt 0) { return }
    $candidate = @($states | Where-Object { $_.Status -eq 'Off' -and [bool]$_.OsClean } | Sort-Object { [int]$_.WorkerId }) | Select-Object -First 1
    if (-not $candidate) {
        $candidate = @($states | Where-Object { Test-PoolWorkerFaultRecoveryEligible -State $_ } | Sort-Object { [int]$_.WorkerId }) | Select-Object -First 1
        if ($candidate) {
            Set-PoolLifecycleQueued -State $candidate -Mode Recycle -IdleDeadlineUtc (Get-PoolIdleDeadline -Config $Config -FromUtc ([DateTime]::UtcNow)).ToString('o')
        }
    }
    else {
        Set-PoolLifecycleQueued -State $candidate -Mode Start -IdleDeadlineUtc (Get-PoolIdleDeadline -Config $Config -FromUtc ([DateTime]::UtcNow)).ToString('o')
    }
}

function Get-PoolWarmSpareSummary {
    param([Parameter(Mandatory = $true)] [object[]] $States)

    $maxWorkers = [Math]::Max(1, [int]$Config.PoolMaxWorkers)
    $warmAhead = if ($Config.PoolWarmAhead) { [int]$Config.PoolWarmAhead } else { 1 }
    $warmAhead = [Math]::Max(1, [Math]::Min($maxWorkers, $warmAhead))
    $leasedCount = @($States | Where-Object { $_.Status -in @('Leased', 'RunCompleted') }).Count
    $remainingCapacity = [Math]::Max(0, $maxWorkers - $leasedCount)
    $requiredCount = if ($leasedCount -gt 0) { [Math]::Min($warmAhead, $remainingCapacity) } else { 0 }
    $readyCount = @($States | Where-Object { $_.Status -eq 'Ready' -and [bool]$_.OsClean }).Count
    $potentialCount = @($States | Where-Object {
        ($_.Status -eq 'Ready' -and [bool]$_.OsClean) -or
        $_.Status -in @('Starting', 'StartQueued', 'Recycling', 'RecycleQueued')
    }).Count

    [pscustomobject][ordered]@{
        LeasedCount = $leasedCount
        WarmAhead = $warmAhead
        RequiredCount = $requiredCount
        ReadyCount = $readyCount
        PotentialCount = $potentialCount
        Satisfied = $potentialCount -ge $requiredCount
    }
}

function Ensure-PoolWarmSpareInvariant {
    $states = Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config
    $summary = Get-PoolWarmSpareSummary -States $states
    if ($summary.Satisfied) { return }

    $needed = [int]$summary.RequiredCount - [int]$summary.PotentialCount
    while ($needed -gt 0) {
        $states = Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config

        # A stop that is queued but has not started can be cancelled safely.
        # This matters after broker upgrades and lifecycle-concurrency bursts;
        # the last usable spare must not be allowed to drain under a lease.
        $candidate = @($states | Where-Object { $_.Status -eq 'StopQueued' -and [bool]$_.OsClean } | Sort-Object { [int]$_.WorkerId }) | Select-Object -First 1
        if ($candidate) {
            Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$candidate.WorkerId) -Patch ([ordered]@{
                Status = 'Ready'
                PendingLifecycleMode = $null
                OperationId = $null
                ProcessId = $null
                ProcessStartUtc = $null
                IdleDeadlineUtc = (Get-PoolIdleDeadline -Config $Config -FromUtc ([DateTime]::UtcNow)).ToString('o')
                LastError = $null
            }) | Out-Null
            $needed--
            continue
        }

        $candidate = @($states | Where-Object { $_.Status -eq 'Off' -and [bool]$_.OsClean } | Sort-Object { [int]$_.WorkerId }) | Select-Object -First 1
        if ($candidate) {
            Set-PoolLifecycleQueued -State $candidate -Mode Start -IdleDeadlineUtc (Get-PoolIdleDeadline -Config $Config -FromUtc ([DateTime]::UtcNow)).ToString('o')
            $needed--
            continue
        }

        $candidate = @($states | Where-Object {
            ($_.Status -eq 'Off' -and -not [bool]$_.OsClean) -or (Test-PoolWorkerFaultRecoveryEligible -State $_)
        } | Sort-Object { [int]$_.WorkerId }) | Select-Object -First 1
        if ($candidate) {
            Set-PoolLifecycleQueued -State $candidate -Mode Recycle -IdleDeadlineUtc (Get-PoolIdleDeadline -Config $Config -FromUtc ([DateTime]::UtcNow)).ToString('o')
            $needed--
            continue
        }

        # Every remaining worker is leased or already in a non-cancellable
        # lifecycle operation. Reconcile again on the next 300 ms broker loop.
        break
    }
}

function Assign-PoolRequests {
    while ($true) {
        $state = @(Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config | Where-Object { $_.Status -eq 'Ready' -and [bool]$_.OsClean } | Sort-Object LastReadyUtc, @{ Expression = { [int]$_.WorkerId } }) | Select-Object -First 1
        $requestFile = Get-PoolQueuedFiles | Select-Object -First 1
        if (-not $state -or -not $requestFile) { break }
        if (Start-PoolRequest -State $state -RequestFile $requestFile) {
            Ensure-PoolWarmSpareInvariant
        }
        else {
            break
        }
    }
}

function Queue-ExpiredPoolWorkersForStop {
    $now = [DateTime]::UtcNow
    $states = Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config
    $summary = Get-PoolWarmSpareSummary -States $states
    $readyStates = @($states | Where-Object Status -eq 'Ready')
    $stoppableBudget = [Math]::Max(0, $readyStates.Count - [int]$summary.RequiredCount)
    foreach ($state in @($readyStates | Sort-Object IdleDeadlineUtc, @{ Expression = { [int]$_.WorkerId } })) {
        if ($stoppableBudget -le 0) { break }
        if ($state.Status -ne 'Ready' -or [string]::IsNullOrWhiteSpace([string]$state.IdleDeadlineUtc)) { continue }
        try { $deadline = [DateTime]::Parse([string]$state.IdleDeadlineUtc).ToUniversalTime() } catch { $deadline = $now }
        if ($now -ge $deadline) {
            Set-PoolLifecycleQueued -State $state -Mode Stop
            $stoppableBudget--
        }
    }
}

function Write-PoolBrokerSnapshot {
    $states = Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config
    $warmSpare = Get-PoolWarmSpareSummary -States $states
    $maintenanceActive = Test-Path -LiteralPath $maintenancePath -PathType Leaf
    $vmStates = @()
    foreach ($worker in @($Config.PoolWorkers)) {
        $vm = Get-VM -Name ([string]$worker.VmName) -ErrorAction SilentlyContinue
        $vmStates += [ordered]@{
            WorkerId = [int]$worker.WorkerId
            VmName = [string]$worker.VmName
            HyperVState = if ($vm) { [string]$vm.State } else { 'Missing' }
        }
    }
    Write-PoolJsonAtomic -Path (Join-Path $BrokerRoot 'State\pool-state.json') -Value ([ordered]@{
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        MaxWorkers = [int]$Config.PoolMaxWorkers
        WarmAhead = [int]$warmSpare.WarmAhead
        IdleTimeoutSeconds = [int]$Config.PoolIdleTimeoutSeconds
        LifecycleConcurrency = [int]$Config.PoolLifecycleConcurrency
        RunningCount = @($vmStates | Where-Object HyperVState -ne 'Off').Count
        ReadyCount = @($states | Where-Object Status -eq 'Ready').Count
        ActiveCount = @($states | Where-Object Status -in @('Leased', 'RunCompleted')).Count
        RequiredWarmSpareCount = [int]$warmSpare.RequiredCount
        ReadyWarmSpareCount = [int]$warmSpare.ReadyCount
        WarmSparePotentialCount = [int]$warmSpare.PotentialCount
        WarmSpareInvariantSatisfied = [bool]$warmSpare.Satisfied
        MaintenanceActive = [bool]$maintenanceActive
        WarmSparePolicyApplicable = [bool](-not $maintenanceActive)
        WarmSpareInvariantViolation = [bool](-not $maintenanceActive -and -not $warmSpare.Satisfied)
        QueueDepth = @(Get-PoolQueuedFiles).Count
        Workers = @($states)
        VirtualMachines = @($vmStates)
    })
}

function Recover-PoolBrokerState {
    Initialize-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config
    $mappedRequests = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($state in Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config) {
        if (-not [string]::IsNullOrWhiteSpace([string]$state.RequestId)) { [void]$mappedRequests.Add([string]$state.RequestId) }
        if (-not [string]::IsNullOrWhiteSpace([string]$state.RecoveryRequestId)) { [void]$mappedRequests.Add([string]$state.RecoveryRequestId) }
        $alive = Test-PoolProcessAlive -ProcessId $state.ProcessId -ProcessStartUtc $state.ProcessStartUtc
        if ($alive) { continue }
        $vm = Get-VM -Name ([string]$state.VmName) -ErrorAction SilentlyContinue
        if ($state.Status -eq 'Ready' -and $vm -and $vm.State -eq 'Running') { continue }
        if ($state.Status -eq 'Off' -and $vm -and $vm.State -eq 'Off') { continue }
        if ($state.Status -eq 'Faulted' -and -not (Test-PoolWorkerFaultRecoveryEligible -State $state)) { continue }
        if ($state.Status -in @('Leased', 'RunCompleted')) {
            Complete-PoolWorkerRun -State $state
            continue
        }
        if ($vm -and $vm.State -ne 'Off') {
            try { Stop-TestVm -VmName ([string]$state.VmName) -Immediate } catch { }
        }
        $latest = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$state.WorkerId)
        Set-PoolLifecycleQueued -State $latest -Mode Recycle -IdleDeadlineUtc (Get-PoolIdleDeadline -Config $Config -FromUtc ([DateTime]::UtcNow)).ToString('o')
    }

    foreach ($processingFile in Get-PoolProcessingFiles) {
        $requestId = [IO.Path]::GetFileNameWithoutExtension($processingFile.Name)
        if ($mappedRequests.Contains($requestId)) { continue }
        $existingBrokerResult = Join-Path (Join-Path $resultsPath $requestId) 'broker-result.json'
        if (Test-Path -LiteralPath $existingBrokerResult -PathType Leaf) {
            Move-Item -LiteralPath $processingFile.FullName -Destination (Join-Path $archivePath ($requestId + '-pool-startup-after-terminal-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')) -Force
            $queuedDuplicate = Join-Path $requestPath $processingFile.Name
            if (Test-Path -LiteralPath $queuedDuplicate -PathType Leaf) {
                Move-QueuedRequestWithTerminalResult -QueuedFile ([IO.FileInfo]$queuedDuplicate) -RequestId $requestId -Reason 'pool-startup-queued-after-terminal' | Out-Null
            }
            continue
        }
        foreach ($state in Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config) {
            if (-not (Test-PoolProcessAlive -ProcessId $state.ProcessId -ProcessStartUtc $state.ProcessStartUtc)) {
                $vm = Get-VM -Name ([string]$state.VmName) -ErrorAction SilentlyContinue
                if ($vm -and $vm.State -ne 'Off') {
                    try { Stop-TestVm -VmName ([string]$state.VmName) -Immediate } catch { }
                }
            }
        }
        $resultRoot = Join-Path $resultsPath $requestId
        $requestStatePath = Join-Path $resultRoot 'request-state.json'
        $orphanedRequest = $null
        $orphanedRequestState = $null
        $startupTerminal = $null
        try {
            $orphanedRequest = Read-BrokerJsonWithRetry -Path $processingFile.FullName
        }
        catch {
            $startupTerminal = [pscustomobject]@{
                FailureKind = 'InterruptedRequestUnreadable'
                Message = 'The orphaned pool processing request could not be read reliably during startup recovery. It was failed terminally and quarantined rather than risk replaying an unknown application job.'
            }
        }
        if (-not $startupTerminal -and (Test-Path -LiteralPath $requestStatePath -PathType Leaf)) {
            try { $orphanedRequestState = Read-BrokerJsonWithRetry -Path $requestStatePath }
            catch {
                $startupTerminal = [pscustomobject]@{
                    FailureKind = 'InterruptedRequestStateUnreadable'
                    Message = 'The orphaned pool request state remained unreadable after bounded retries. It was failed terminally because replay safety could not be established.'
                }
            }
        }
        elseif (-not $startupTerminal -and (Test-ExactExpectedGuestPowerOffRequest -Request $orphanedRequest)) {
            $startupTerminal = [pscustomobject]@{
                FailureKind = 'ExpectedGuestPowerOffStateMissing'
                Message = 'The orphaned exact expected-power-off request had no durable state during pool startup recovery. It was failed terminally because a prior launch could not be excluded.'
            }
        }
        $powerOffInterruption = if (-not $startupTerminal) { Get-PoolInterruptedExpectedGuestPowerOffState -Request $orphanedRequest -RequestState $orphanedRequestState } else { $null }
        if ($powerOffInterruption -and $powerOffInterruption.Disposition -eq 'InvalidState') {
            $startupTerminal = [pscustomobject]@{
                FailureKind = 'ExpectedGuestPowerOffStateInvalid'
                Message = "The orphaned exact expected-power-off request state was invalid: $([string]$powerOffInterruption.Reason) It was failed terminally because safe startup replay could not be established."
            }
        }
        $protectedPowerOffState = if ($powerOffInterruption -and $powerOffInterruption.Disposition -eq 'ProtectedNoReplay') { $powerOffInterruption.RequestState } else { $null }
        if ($protectedPowerOffState) {
            $shutdownBeforeCleanupProperty = $protectedPowerOffState.PSObject.Properties['GuestPowerOffBeforeCleanup']
            $causalPowerOffPersisted = -not [string]::IsNullOrWhiteSpace([string]$protectedPowerOffState.GuestPowerOffObservedUtc) -and
                $shutdownBeforeCleanupProperty -and $shutdownBeforeCleanupProperty.Value -is [bool] -and [bool]$shutdownBeforeCleanupProperty.Value
            $applicationRunningPersisted = -not [string]::IsNullOrWhiteSpace([string]$protectedPowerOffState.GuestApplicationEraRunningObservedUtc)
            $submissionAmbiguous = -not [string]::IsNullOrWhiteSpace([string]$protectedPowerOffState.ExpectedGuestPowerOffSubmissionStartedUtc) -and
                $protectedPowerOffState.PSObject.Properties['GuestJobMayHaveLaunched'] -and
                $protectedPowerOffState.GuestJobMayHaveLaunched -is [bool] -and [bool]$protectedPowerOffState.GuestJobMayHaveLaunched
            $startupTerminal = [pscustomobject]@{
                FailureKind = if ($causalPowerOffPersisted) { 'GuestPowerOffEvidenceRecoveryInterrupted' } elseif ($applicationRunningPersisted) { 'ExpectedGuestPowerOffPoolStateInterrupted' } else { 'ExpectedGuestPowerOffSubmissionInterrupted' }
                Message = if ($causalPowerOffPersisted) {
                    'Pool state was lost after host-observed application-era Running-to-Off causality but before evidence recovery completed. The request was failed terminally and will not be replayed.'
                }
                elseif ($applicationRunningPersisted) {
                    'Pool state was lost after the expected-power-off application was confirmed running. A later shutdown may already have been scheduled, so the request was failed terminally and will not be replayed.'
                }
                elseif ($submissionAmbiguous) {
                    'Pool state was lost after expected-power-off job delivery began but before launch outcome was known. The request was failed terminally and will not be replayed.'
                }
                else {
                    'Pool state was lost with ambiguous expected-power-off delivery state. The request was failed terminally and will not be replayed.'
                }
            }
        }
        if ($startupTerminal) {
            $protectedWorkerId = if ($orphanedRequestState -and $null -ne $orphanedRequestState.WorkerId) { [Nullable[int]]([int]$orphanedRequestState.WorkerId) } else { $null }
            $cleanup = Invoke-PoolInterruptedRequestCleanup -Config $Config -RequestId $requestId -WorkerId $protectedWorkerId
            $cleanupVmName = if ($cleanup.VmName) { [string]$cleanup.VmName } else { '' }
            Publish-InterruptedRequestTerminalResult -ResultRoot $resultRoot -RequestId $requestId -Request $orphanedRequest -RequestState $orphanedRequestState -FailureKind ([string]$startupTerminal.FailureKind) -FailureStage 'PoolStartupRecovery' -Message ([string]$startupTerminal.Message) -VmName $cleanupVmName -WorkerId $protectedWorkerId -Cleanup $cleanup -PoolWorkerRecyclePending $true | Out-Null
            Move-Item -LiteralPath $processingFile.FullName -Destination (Join-Path $archivePath ($requestId + '-pool-startup-expected-poweroff-interrupted-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')) -Force
            $queuedFile = Join-Path $requestPath $processingFile.Name
            if (Test-Path -LiteralPath $queuedFile -PathType Leaf) {
                Move-QueuedRequestWithTerminalResult -QueuedFile ([IO.FileInfo]$queuedFile) -RequestId $requestId -Reason 'pool-startup-interrupted-queued-after-terminal' | Out-Null
            }
            try { Remove-StagedPayloadSafe -RequestId $requestId } catch { }
            continue
        }
        $queuedFile = Join-Path $requestPath $processingFile.Name
        if (-not (Test-Path -LiteralPath $queuedFile -PathType Leaf)) {
            Move-Item -LiteralPath $processingFile.FullName -Destination $queuedFile
        }
        else {
            Move-Item -LiteralPath $processingFile.FullName -Destination (Join-Path $archivePath ($requestId + '-startup-recovery-duplicate-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')) -Force
        }
    }
}

function Invoke-PoolBrokerLoop {
    param([Parameter(Mandatory = $true)] $Config)

    $script:Config = $Config
    foreach ($directory in @(
        (Get-PoolWorkerStateRoot -BrokerRoot $BrokerRoot),
        (Join-Path $BrokerRoot 'State\WorkerProgress'),
        (Join-Path $BrokerRoot 'State\PayloadLeases')
    )) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Recover-PoolBrokerState
    $null = Recover-OrphanedHostInputResources -BrokerRoot $BrokerRoot
    $null = Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
        Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot
    }
    $nextCleanupUtc = [DateTime]::MinValue
    $nextHostInputCleanupUtc = [DateTime]::UtcNow.AddSeconds(2)
    $nextRequestNetworkCleanupUtc = [DateTime]::UtcNow.AddSeconds(2)
    $maintenanceCleanupCompleted = $false

    while ($true) {
        Reap-PoolProcesses
        if ([DateTime]::UtcNow -ge $nextHostInputCleanupUtc) {
            $null = Recover-OrphanedHostInputResources -BrokerRoot $BrokerRoot
            $nextHostInputCleanupUtc = [DateTime]::UtcNow.AddSeconds(2)
        }
        if ([DateTime]::UtcNow -ge $nextRequestNetworkCleanupUtc) {
            $null = Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
                Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot
            }
            $nextRequestNetworkCleanupUtc = [DateTime]::UtcNow.AddSeconds(2)
        }
        Reconcile-PoolRecoveryRequests
        Complete-PoolQueuedTerminalRequests
        Write-PoolQueuePositions -Config $config
        try {
            Route-LiveEvidenceRequests -BrokerRoot $BrokerRoot -Config $Config
            Reconcile-LiveEvidenceCommands -BrokerRoot $BrokerRoot -Config $Config
        }
        catch {
            # Live observation is auxiliary and must not interrupt queue,
            # worker, deadline, network, or terminal-evidence processing.
        }

        $maintenance = Test-Path -LiteralPath $maintenancePath -PathType Leaf
        if ($maintenance) {
            foreach ($state in Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config) {
                if ($state.Status -eq 'Ready') {
                    Set-PoolLifecycleQueued -State $state -Mode Stop
                }
            }
        }
        else {
            $maintenanceCleanupCompleted = $false
            Assign-PoolRequests
            Ensure-PoolDemandCapacity
            Ensure-PoolWarmSpareInvariant
            Queue-FaultedPoolWorkerRecovery
            Queue-ExpiredPoolWorkersForStop
        }

        Start-PendingPoolLifecycles
        $states = Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config
        $nowUtc = [DateTime]::UtcNow
        $allWorkerStatesOff = @($states | Where-Object Status -ne 'Off').Count -eq 0
        $cleanupDue = Test-PoolPayloadCleanupDue `
            -MaintenanceActive $maintenance `
            -MaintenanceCleanupCompleted $maintenanceCleanupCompleted `
            -AllWorkerStatesOff $allWorkerStatesOff `
            -NowUtc $nowUtc `
            -NextCleanupUtc $nextCleanupUtc
        if ($cleanupDue) {
            $runningWorkerVms = @($Config.PoolWorkers | Where-Object {
                $workerVm = Get-VM -Name ([string]$_.VmName) -ErrorAction SilentlyContinue
                $workerVm -and $workerVm.State -ne 'Off'
            })
            if ($runningWorkerVms.Count -eq 0) {
                Remove-StaleQueueArtifacts
                Invoke-PayloadCacheGarbageCollection -Config $Config -VmName @($Config.PoolWorkers | ForEach-Object { [string]$_.VmName })
                $nextCleanupUtc = [DateTime]::UtcNow.AddMinutes(5)
                if ($maintenance) {
                    $maintenanceCleanupCompleted = $false
                    try {
                        $maintenanceGcState = Get-Content -LiteralPath $payloadGcStatePath -Raw | ConvertFrom-Json
                        $maintenanceGcStartedUtc = [DateTime]::Parse([string]$maintenanceGcState.StartedUtc).ToUniversalTime()
                        $maintenanceCleanupCompleted = [string]$maintenanceGcState.Status -eq 'Completed' -and $maintenanceGcStartedUtc -ge $nowUtc
                    }
                    catch { }
                }
            }
        }

        Write-PoolBrokerSnapshot
        $states = Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config
        $active = @($states | Where-Object Status -in @('Leased', 'RunCompleted')).Count
        $ready = @($states | Where-Object Status -eq 'Ready').Count
        $queued = @(Get-PoolQueuedFiles).Count
        $status = if ($maintenance) { 'Maintenance' } elseif ($active -gt 0) { 'PoolActive' } elseif ($ready -gt 0) { 'PoolWarm' } else { 'Idle' }
        Write-BrokerState -Status $status -Message ("Pool: active=$active ready=$ready queued=$queued.")
        Start-Sleep -Milliseconds 300
    }
}
