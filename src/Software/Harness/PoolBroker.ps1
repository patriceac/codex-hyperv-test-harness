function ConvertTo-PoolUtcDateTime {
    param([Parameter(Mandatory = $true)] [object] $Value)

    # PowerShell 7's JSON parser may materialize ISO-8601 values as DateTime,
    # while Windows PowerShell 5.1 leaves the same values as strings.  Handle
    # both representations without depending on the host's display culture.
    if ($Value -is [DateTime]) {
        return ([DateTime]$Value).ToUniversalTime()
    }
    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).UtcDateTime
    }
    return [DateTime]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
}

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

function Stop-PoolProcessAndWait {
    param(
        [object] $Process,
        [int] $ProcessId = 0,
        [int] $WaitMilliseconds = 5000
    )

    $target = $Process
    if (-not $target -and $ProcessId -gt 0) {
        $target = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    }
    if (-not $target) {
        return [pscustomobject][ordered]@{ Stopped = $true; Error = $null }
    }

    try {
        $target.Refresh()
        if (-not $target.HasExited) {
            Stop-Process -Id $target.Id -Force -ErrorAction Stop
            if (-not $target.WaitForExit($WaitMilliseconds)) {
                throw "Process $($target.Id) did not exit within $WaitMilliseconds milliseconds."
            }
        }
        [pscustomobject][ordered]@{ Stopped = $true; Error = $null }
    }
    catch {
        [pscustomobject][ordered]@{ Stopped = $false; Error = $_.Exception.Message }
    }
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

function Get-PoolRequestRecoveryRoot {
    Join-Path $BrokerRoot 'State\PoolRequestRecovery'
}

function Get-PoolRequestRecoveryPath {
    param([Parameter(Mandatory = $true)] [string] $RequestId)

    if ($RequestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
        throw "Invalid pool request recovery id: $RequestId"
    }
    Join-Path (Get-PoolRequestRecoveryRoot) ($RequestId + '.json')
}

function Mark-PoolRequestRecoveryPending {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [int] $WorkerId,
        [Parameter(Mandatory = $true)] [string] $OperationId,
        [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $ProcessingFile,
        [Parameter(Mandatory = $true)] [string] $ResultRoot,
        [Parameter(Mandatory = $true)] [string] $FailureMessage
    )

    $recoveryRoot = Get-PoolRequestRecoveryRoot
    New-Item -ItemType Directory -Force -Path $recoveryRoot | Out-Null
    $markedUtc = [DateTime]::UtcNow.ToString('o')
    $marker = [ordered]@{
        FormatVersion = 1
        RequestId = $RequestId
        WorkerId = $WorkerId
        VmName = $VmName
        OperationId = $OperationId
        ProcessingFile = $ProcessingFile
        MarkedUtc = $markedUtc
        Reason = $FailureMessage
    }
    $markerWritten = $false
    $requestWritten = $false
    $request = $null
    $markerPath = Get-PoolRequestRecoveryPath -RequestId $RequestId
    try {
        Write-PoolJsonAtomic -Path $markerPath -Value $marker
        $markerWritten = $true
    }
    catch {
        $marker.WriteError = $_.Exception.Message
    }

    try {
        if (Test-Path -LiteralPath $ProcessingFile -PathType Leaf) {
            $request = Get-Content -Raw -LiteralPath $ProcessingFile | ConvertFrom-Json
            $request | Add-Member -NotePropertyName PoolRecoveryPending -NotePropertyValue $true -Force
            $request | Add-Member -NotePropertyName PoolRecoveryWorkerId -NotePropertyValue $WorkerId -Force
            $request | Add-Member -NotePropertyName PoolRecoveryOperationId -NotePropertyValue $OperationId -Force
            $request | Add-Member -NotePropertyName PoolRecoveryMarkedUtc -NotePropertyValue $markedUtc -Force
            $request | Add-Member -NotePropertyName PoolRecoveryReason -NotePropertyValue $FailureMessage -Force
            Write-PoolJsonAtomic -Path $ProcessingFile -Value $request
            $requestWritten = $true
        }
    }
    catch {
        $marker.RequestWriteError = $_.Exception.Message
    }

    try {
        $createdUtc = $null
        if ($request) { $createdUtc = ConvertTo-PoolUtcDateTime -Value $request.CreatedUtc }
        Write-RequestState -ResultRoot $ResultRoot -RequestId $RequestId -Status 'RetryPendingRecycle' -Message ('The request is retained in Processing until worker recovery: ' + $FailureMessage) -CreatedUtc $createdUtc -WorkerId $WorkerId
    }
    catch {
        # Request lifecycle reporting is advisory; the durable marker and the
        # Processing payload are the recovery authority.
    }

    [pscustomobject][ordered]@{
        MarkerPath = $markerPath
        MarkerWritten = $markerWritten
        RequestWritten = $requestWritten
        Durable = [bool]($markerWritten -or $requestWritten)
    }
}

function Reconcile-PoolRequestRecoveryMarkers {
    $recoveryRoot = Get-PoolRequestRecoveryRoot
    $candidates = @{}
    if (Test-Path -LiteralPath $recoveryRoot -PathType Container) {
        foreach ($markerFile in @(Get-ChildItem -LiteralPath $recoveryRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $marker = $null
            try { $marker = Get-Content -Raw -LiteralPath $markerFile.FullName | ConvertFrom-Json } catch { continue }
            $requestId = [IO.Path]::GetFileNameWithoutExtension($markerFile.Name)
            if ($marker -and $marker.PSObject.Properties['RequestId'] -and -not [string]::IsNullOrWhiteSpace([string]$marker.RequestId)) {
                $requestId = [string]$marker.RequestId
            }
            if ($requestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') { continue }
            $candidates[$requestId] = [pscustomobject][ordered]@{
                RequestId = $requestId
                WorkerId = if ($marker.PSObject.Properties['WorkerId']) { [int]$marker.WorkerId } else { 0 }
                OperationId = if ($marker.PSObject.Properties['OperationId']) { [string]$marker.OperationId } else { $null }
                VmName = if ($marker.PSObject.Properties['VmName']) { [string]$marker.VmName } else { $null }
                Reason = if ($marker.PSObject.Properties['Reason']) { [string]$marker.Reason } else { 'Post-launch worker recovery.' }
                Marker = $marker
                MarkerPath = $markerFile.FullName
            }
        }
    }

    # The Processing payload is a second durable recovery authority. It is
    # intentionally scanned even when marker creation failed: a successful
    # PoolRecoveryPending write must never become an invisible orphan.
    foreach ($processingFile in @(Get-ChildItem -LiteralPath $processingPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $request = $null
        try { $request = Get-Content -Raw -LiteralPath $processingFile.FullName | ConvertFrom-Json } catch { continue }
        $pending = $false
        if ($request -and $request.PSObject.Properties['PoolRecoveryPending']) {
            $pending = [bool]$request.PoolRecoveryPending
        }
        if (-not $pending) { continue }
        $requestId = [IO.Path]::GetFileNameWithoutExtension($processingFile.Name)
        if ($requestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') { continue }
        $workerId = if ($request.PSObject.Properties['PoolRecoveryWorkerId']) { [int]$request.PoolRecoveryWorkerId } else { 0 }
        $operationId = if ($request.PSObject.Properties['PoolRecoveryOperationId']) { [string]$request.PoolRecoveryOperationId } else { $null }
        $reason = if ($request.PSObject.Properties['PoolRecoveryReason']) { [string]$request.PoolRecoveryReason } else { 'Post-launch worker recovery.' }
        if (-not $candidates.ContainsKey($requestId)) {
            $candidates[$requestId] = [pscustomobject][ordered]@{
                RequestId = $requestId
                WorkerId = $workerId
                OperationId = $operationId
                VmName = $null
                Reason = $reason
                Marker = $null
                MarkerPath = $null
            }
        }
        else {
            $candidate = $candidates[$requestId]
            if ([int]$candidate.WorkerId -le 0 -and $workerId -gt 0) { $candidate.WorkerId = $workerId }
            if ([string]::IsNullOrWhiteSpace([string]$candidate.OperationId) -and -not [string]::IsNullOrWhiteSpace($operationId)) { $candidate.OperationId = $operationId }
            if ([string]::IsNullOrWhiteSpace([string]$candidate.Reason) -and -not [string]::IsNullOrWhiteSpace($reason)) { $candidate.Reason = $reason }
        }
    }

    foreach ($requestId in @($candidates.Keys)) {
        $candidate = $candidates[$requestId]
        $marker = $null
        if ($candidate.Marker) { $marker = $candidate.Marker }
        $processingFile = Join-Path $processingPath ($requestId + '.json')
        if (-not (Test-Path -LiteralPath $processingFile -PathType Leaf)) {
            if ($candidate.MarkerPath) { Remove-Item -LiteralPath $candidate.MarkerPath -Force -ErrorAction SilentlyContinue }
            continue
        }

        $workerId = [int]$candidate.WorkerId
        if ($workerId -lt 1 -or $workerId -gt 64) { continue }
        $state = $null
        try { $state = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId } catch { }
        # A missing or unreadable authoritative state is fail-closed. The
        # marker remains so a later broker pass can reconcile it; never assume
        # the VM is free and never overwrite a state owned by another op.
        if (-not $state) { continue }

        $markerOperationId = [string]$candidate.OperationId
        $currentOperationId = [string]$state.OperationId
        $currentRequestId = [string]$state.RequestId
        $hasCurrentOwner = -not [string]::IsNullOrWhiteSpace($currentOperationId) -or -not [string]::IsNullOrWhiteSpace($currentRequestId)
        $sameOwner = [string]::Equals($currentOperationId, $markerOperationId, [StringComparison]::Ordinal) -and
            ([string]::IsNullOrWhiteSpace($currentRequestId) -or [string]::Equals($currentRequestId, $requestId, [StringComparison]::Ordinal))
        if ($hasCurrentOwner -and -not $sameOwner) { continue }
        if ([string]$state.Status -notin @('Ready', 'Off', 'Faulted', 'RunCompleted')) { continue }
        if ([string]$state.Status -eq 'Ready' -and -not [bool]$state.OsClean) { continue }

        # Reconstruct a missing marker when possible. If the marker store is
        # still unavailable, the flagged Processing payload remains sufficient
        # to complete this safe reconciliation; it is not silently skipped.
        $markerPath = $candidate.MarkerPath
        if ([string]::IsNullOrWhiteSpace([string]$markerPath)) {
            try {
                $markerPath = Get-PoolRequestRecoveryPath -RequestId $requestId
                Write-PoolJsonAtomic -Path $markerPath -Value ([ordered]@{
                    FormatVersion = 1
                    RequestId = $requestId
                    WorkerId = $workerId
                    VmName = [string]$candidate.VmName
                    OperationId = $markerOperationId
                    ProcessingFile = $processingFile
                    MarkedUtc = [DateTime]::UtcNow.ToString('o')
                    Reason = [string]$candidate.Reason
                })
            }
            catch {
                # Continue using the Processing authority. The safe-owner
                # checks above are independent of marker-file availability.
            }
        }

        try {
            $request = Get-Content -Raw -LiteralPath $processingFile | ConvertFrom-Json
            $request | Add-Member -NotePropertyName PoolRecoveryPending -NotePropertyValue $false -Force
            Write-PoolJsonAtomic -Path $processingFile -Value $request
            $queuedFile = Join-Path $requestPath ($requestId + '.json')
            if (Test-Path -LiteralPath $queuedFile -PathType Leaf) {
                Move-Item -LiteralPath $processingFile -Destination (Join-Path $archivePath ($requestId + '-recovery-duplicate-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')) -Force
            }
            else {
                Move-Item -LiteralPath $processingFile -Destination $queuedFile
            }
            try {
                $createdUtc = ConvertTo-PoolUtcDateTime -Value $request.CreatedUtc
                Write-RequestState -ResultRoot (Join-Path $resultsPath $requestId) -RequestId $requestId -Status 'RetryQueued' -Message 'Worker recovery completed; the request returned to the queue.' -CreatedUtc $createdUtc
            }
            catch { }
            if (-not [string]::IsNullOrWhiteSpace([string]$markerPath)) {
                Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Leave both files in place for the next reconciliation pass.
        }
    }
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
    $process = $null
    try {
        $process = Start-PoolProcess -ScriptPath $script -ScriptArguments $arguments
        $processStartUtc = $null
        try { $processStartUtc = $process.StartTime.ToUniversalTime().ToString('o') } catch { }
        $processState = Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$State.WorkerId) -ExpectedOperationId $operationId -RequireExpectation -Patch ([ordered]@{
            ProcessId = $process.Id
            ProcessStartUtc = $processStartUtc
        })
        if (-not $processState) {
            throw "Pool worker $([int]$State.WorkerId) lifecycle state no longer matches operation $operationId after process start."
        }
    }
    catch {
        $faultMessage = $_.Exception.Message
        if ($process) {
            $stopped = Stop-PoolProcessAndWait -Process $process
            if (-not $stopped.Stopped) {
                $faultMessage = "$faultMessage Lifecycle process cleanup also failed: $($stopped.Error)"
            }
        }
        $latest = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$State.WorkerId)
        $faultPatch = New-PoolFaultStatePatch -State $latest -Config $Config -ErrorMessage $faultMessage
        $faultUpdate = Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$State.WorkerId) -ExpectedOperationId $operationId -RequireExpectation -Patch $faultPatch
        if (-not $faultUpdate) {
            # The worker remains dirty and is intentionally left for the next
            # reconciliation pass; never make it Ready after a mismatched
            # post-start state update.
            $null = $latest
        }
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
        try { $createdUtc = ConvertTo-PoolUtcDateTime -Value $request.CreatedUtc } catch { }
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
            $createdUtc = ConvertTo-PoolUtcDateTime -Value $request.CreatedUtc
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
    $process = $null
    $hostWorkerStarted = $false

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
        $createdUtc = ConvertTo-PoolUtcDateTime -Value $request.CreatedUtc
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
        $hostWorkerStarted = $true
        $processStartUtc = $null
        try { $processStartUtc = $process.StartTime.ToUniversalTime().ToString('o') } catch { }
        $processState = Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -ExpectedOperationId $operationId -ExpectedRequestId $requestId -RequireExpectation -Patch ([ordered]@{
            ProcessId = $process.Id
            ProcessStartUtc = $processStartUtc
        })
        if (-not $processState) {
            throw "Pool worker $workerId assignment no longer matches operation $operationId and request $requestId after HostWorker start."
        }
        $true
    }
    catch {
        $failureMessage = $_.Exception.Message
        if ($hostWorkerStarted) {
            # The HostWorker may already have attached payloads or changed the
            # VM. Stop and wait for it before touching the lease state. Keep the
            # request in Processing and recycle the worker; only the later
            # recovery pass may move it back to Requests.
            $stopped = Stop-PoolProcessAndWait -Process $process
            if (-not $stopped.Stopped) {
                $failureMessage = "$failureMessage HostWorker cleanup also failed: $($stopped.Error)"
            }
            $latest = $null
            $latestReadable = $false
            try {
                $latest = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId
                $latestReadable = $null -ne $latest
            }
            catch {
                $failureMessage = "$failureMessage Latest worker state could not be read: $($_.Exception.Message)"
            }
            $recoveryState = $null
            if ($latestReadable -and
                [string]::Equals([string]$latest.OperationId, $operationId, [StringComparison]::Ordinal) -and
                [string]::Equals([string]$latest.RequestId, $requestId, [StringComparison]::Ordinal)) {
                try {
                    $recoveryState = Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -ExpectedOperationId $operationId -ExpectedRequestId $requestId -RequireExpectation -Patch ([ordered]@{
                        Status = 'RunCompleted'
                        ProcessId = $null
                        ProcessStartUtc = $null
                        LastError = "HostWorker launch state update failed; worker will recycle before request requeue. $failureMessage"
                    })
                }
                catch {
                    $failureMessage = "$failureMessage Recovery lease update also failed: $($_.Exception.Message)"
                }
            }
            if ($recoveryState) {
                try {
                    Complete-PoolWorkerRun -State $recoveryState -RecycleBeforeRequeue
                }
                catch {
                    $failureMessage = "$failureMessage Recovery publication also failed: $($_.Exception.Message)"
                    $recoveryState = $null
                }
            }
            if (-not $recoveryState) {
                # A state mismatch means another operation may now own this
                # worker. Persist request recovery separately, without writing
                # the worker state, so the request is reconciled only after
                # that owner reaches a safe terminal state. This also covers a
                # transiently unreadable latest state; never strand Processing
                # and never mark a newly owned worker Ready.
                try {
                    $recoveryMark = Mark-PoolRequestRecoveryPending -RequestId $requestId -WorkerId $workerId -OperationId $operationId -VmName ([string]$State.VmName) -ProcessingFile $processingFile -ResultRoot $resultRoot -FailureMessage $failureMessage
                    if (-not $recoveryMark.Durable) {
                        throw "Could not persist post-launch recovery for request $requestId; both the recovery marker and Processing recovery flag failed."
                    }
                }
                catch {
                    # With no durable recovery authority left, surface the
                    # failure so the broker crashes/restarts rather than
                    # silently stranding Processing. Do not touch a newer
                    # worker owner here.
                    throw $_
                }
            }
            # Deliberately do not move the processing file or mark Ready here.
            # A state mismatch means ownership is uncertain until recycle.
        }
        else {
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
                LastError = $failureMessage
            }) | Out-Null
        }
        $false
    }
}

function Complete-PoolWorkerRun {
    param(
        [Parameter(Mandatory = $true)] $State,
        [switch] $RecycleBeforeRequeue
    )

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
        ConvertTo-PoolUtcDateTime -Value $State.LastReleasedUtc
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
                $createdUtc = ConvertTo-PoolUtcDateTime -Value $retryRequest.CreatedUtc
                if ($RecycleBeforeRequeue) {
                    # A post-launch ownership mismatch has already required
                    # stopping the HostWorker. Keep the request in Processing
                    # while the worker is queued for recycle; reconciliation
                    # moves it back to Requests only after the VM is clean.
                    Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
                        RecoveryRequestId = $requestId
                        RequestId = $null
                        OperationId = $null
                        ProcessId = $null
                        ProcessStartUtc = $null
                        IdleDeadlineUtc = $idleDeadline.ToString('o')
                        LastError = 'Transient capture failure retained in Processing until the failed worker recycles.'
                    }) | Out-Null
                    $refreshed = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId
                    Set-PoolLifecycleQueued -State $refreshed -Mode Recycle -IdleDeadlineUtc $idleDeadline.ToString('o')
                    Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'RetryPendingRecycle' -Message 'Transient capture failure; the request will return to the queue after the failed worker recycles.' -CreatedUtc $createdUtc
                    return
                }
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
    # Recoveries created after a HostWorker launch are deliberately independent
    # of the worker state file. Reconcile them first so an unreadable or
    # differently-owned worker cannot make Processing look like a free queue
    # entry.
    Reconcile-PoolRequestRecoveryMarkers
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
        try { $deadline = ConvertTo-PoolUtcDateTime -Value $state.IdleDeadlineUtc } catch { $deadline = $now }
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
    Reconcile-PoolRequestRecoveryMarkers
    $mappedRequests = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $recoveryRoot = Get-PoolRequestRecoveryRoot
    foreach ($markerFile in @(Get-ChildItem -LiteralPath $recoveryRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        # Protect a marked Processing request even when its worker state is
        # temporarily unreadable; the marker must be reconciled before queue
        # recovery is allowed to move the request.
        [void]$mappedRequests.Add([IO.Path]::GetFileNameWithoutExtension($markerFile.Name))
    }
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
        try {
            $processingRequest = Get-Content -Raw -LiteralPath $processingFile.FullName | ConvertFrom-Json
            if ([bool]$processingRequest.PoolRecoveryPending) { continue }
        }
        catch { }
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
        (Join-Path $BrokerRoot 'State\PayloadLeases'),
        (Get-PoolRequestRecoveryRoot)
    )) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Recover-PoolBrokerState
    $null = Recover-OrphanedHostInputResources -BrokerRoot $BrokerRoot
    $null = Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot
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
            $null = Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot
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
