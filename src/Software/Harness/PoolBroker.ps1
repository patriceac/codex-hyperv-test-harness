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
        Write-JsonAtomic -Path (Join-Path $resultRoot 'broker-result.json') -Value ([ordered]@{
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
        })
        $terminalStatus = if ($timedOut) { 'QueueTimedOut' } else { 'Cancelled' }
        $archiveKind = if ($timedOut) { 'queue-timeout-' } else { 'cancelled-' }
        Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status $terminalStatus -Message $message -CreatedUtc $createdUtc
        $archiveName = $requestId + '-' + $archiveKind + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json'
        try { Move-Item -LiteralPath $requestFile.FullName -Destination (Join-Path $archivePath $archiveName) -Force } catch { }
        Remove-Item -LiteralPath $cancelFile -Force -ErrorAction SilentlyContinue
    }
}

function Write-PoolQueuePositions {
    $queued = Get-PoolQueuedFiles
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

    try {
        Move-Item -LiteralPath $RequestFile.FullName -Destination $processingFile -ErrorAction Stop
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

        $script = Join-Path $PSScriptRoot 'HostWorker.ps1'
        $arguments = @(
            '-BrokerRoot', ('"' + $BrokerRoot + '"'),
            '-WorkerId', ([string]$workerId),
            '-RequestId', $requestId,
            '-OperationId', $operationId,
            '-ClaimedUtc', ('"' + $claimedUtc.ToString('o') + '"')
        )
        $process = Start-PoolProcess -ScriptPath $script -ScriptArguments $arguments
        Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -ExpectedOperationId $operationId -ExpectedRequestId $requestId -RequireExpectation -Patch ([ordered]@{
            ProcessId = $process.Id
            ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
        }) | Out-Null
        $true
    }
    catch {
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
            LastError = $_.Exception.Message
        }) | Out-Null
        $false
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
    $processingFile = Join-Path $processingPath ($requestId + '.json')
    $resultRoot = Join-Path $resultsPath $requestId
    $brokerResult = Join-Path $resultRoot 'broker-result.json'
    $releasedUtc = if (-not [string]::IsNullOrWhiteSpace([string]$State.LastReleasedUtc)) {
        [DateTime]::Parse([string]$State.LastReleasedUtc).ToUniversalTime()
    }
    else { [DateTime]::UtcNow }
    $idleDeadline = Get-PoolIdleDeadline -Config $Config -FromUtc $releasedUtc

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
        if ($retryRequest -and [bool]$retryRequest.PendingInfrastructureRetry) {
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
            if (Test-Path -LiteralPath $queuedFile -PathType Leaf) {
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
        foreach ($state in Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config) {
            if (-not (Test-PoolProcessAlive -ProcessId $state.ProcessId -ProcessStartUtc $state.ProcessStartUtc)) {
                $vm = Get-VM -Name ([string]$state.VmName) -ErrorAction SilentlyContinue
                if ($vm -and $vm.State -ne 'Off') {
                    try { Stop-TestVm -VmName ([string]$state.VmName) -Immediate } catch { }
                }
            }
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
        Write-PoolQueuePositions

        $maintenance = Test-Path -LiteralPath $maintenancePath -PathType Leaf
        if ($maintenance) {
            foreach ($state in Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config) {
                if ($state.Status -eq 'Ready') {
                    Set-PoolLifecycleQueued -State $state -Mode Stop
                }
            }
        }
        else {
            Assign-PoolRequests
            Ensure-PoolDemandCapacity
            Ensure-PoolWarmSpareInvariant
            Queue-FaultedPoolWorkerRecovery
            Queue-ExpiredPoolWorkersForStop
        }

        Start-PendingPoolLifecycles
        $states = Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config
        if ([DateTime]::UtcNow -ge $nextCleanupUtc -and @($states | Where-Object Status -ne 'Off').Count -eq 0) {
            Remove-StaleQueueArtifacts
            Invoke-PayloadCacheGarbageCollection -Config $Config -VmName @($Config.PoolWorkers | ForEach-Object { [string]$_.VmName })
            $nextCleanupUtc = [DateTime]::UtcNow.AddMinutes(5)
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
