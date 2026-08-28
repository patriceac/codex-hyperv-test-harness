$script:LiveEvidenceFormatVersion = 1
$script:LiveEvidenceMaximumGuestFileCount = 16
$script:LiveEvidenceMaximumGuestFileBytes = 4MB
$script:LiveEvidenceMaximumGuestFilesTotalBytes = 16MB
$script:LiveEvidenceMaximumScreenshotBytes = 32MB
$script:LiveEvidenceSupportedStages = @('ApplicationRunning', 'GuestAction')
$script:LiveEvidenceTerminalStages = @('CollectingEvidence', 'StoppingVm', 'CleaningNetwork', 'Completed', 'TestFailed', 'Failed', 'Cancelled', 'QueueTimedOut', 'ExecutionTimedOut')

function Get-LiveEvidenceLayout {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)

    $root = Join-Path $BrokerRoot 'LiveEvidence'
    [pscustomobject][ordered]@{
        Root = $root
        Requests = Join-Path $root 'Requests'
        Processing = Join-Path $root 'Processing'
        Responses = Join-Path $root 'Responses'
    }
}

function Initialize-LiveEvidenceDirectories {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)

    $layout = Get-LiveEvidenceLayout -BrokerRoot $BrokerRoot
    foreach ($path in @($layout.Root, $layout.Requests, $layout.Processing, $layout.Responses)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    $layout
}

function Test-LiveEvidenceIdentifier {
    param([string] $Value)

    -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$'
}

function ConvertTo-LiveEvidenceUtcString {
    param([Parameter(Mandatory = $true)] $Value)

    $timestamp = if ($Value -is [DateTime]) {
        ([DateTime]$Value).ToUniversalTime()
    }
    else {
        [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    $timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Assert-LiveEvidenceRelativePaths {
    param([AllowEmptyCollection()] [string[]] $Paths)

    $normalized = New-Object Collections.Generic.List[string]
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw 'Guest evidence paths must not be empty.'
        }
        if ($path.Length -gt 240) {
            throw "Guest evidence path exceeds 240 characters: $path"
        }
        if ([IO.Path]::IsPathRooted($path) -or $path.StartsWith('\\', [StringComparison]::Ordinal) -or $path.Contains(':')) {
            throw "Guest evidence path must be relative to {OUTDIR}: $path"
        }
        if ($path.IndexOfAny([char[]]'*?') -ge 0) {
            throw "Guest evidence paths do not support wildcards: $path"
        }
        $parts = @($path -split '[\\/]')
        if ($parts.Count -eq 0 -or @($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }).Count -gt 0) {
            throw "Guest evidence path contains an empty, current-directory, or parent-directory segment: $path"
        }
        foreach ($part in $parts) {
            if ($part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw "Guest evidence path contains an invalid filename character: $path"
            }
        }
        $canonical = $parts -join '\'
        if (-not $seen.Add($canonical)) {
            throw "Guest evidence paths must be unique (case-insensitive): $canonical"
        }
        $normalized.Add($canonical)
    }
    if ($normalized.Count -gt $script:LiveEvidenceMaximumGuestFileCount) {
        throw "No more than $script:LiveEvidenceMaximumGuestFileCount guest evidence files may be requested per capture."
    }
    $normalized.ToArray()
}

function Read-LiveEvidenceJsonSafe {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [ValidateRange(1, 8)] [int] $MaximumAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                if ($item.Length -gt 256KB) { return $null }
                if ($item.Length -gt 0) {
                    return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
                }
            }
        }
        catch {
            # The broker replaces state files atomically. A reader can briefly
            # collide with the replace operation, so retry without trusting a
            # less-authoritative client projection.
        }

        if ($attempt -lt $MaximumAttempts) {
            Start-Sleep -Milliseconds ([Math]::Min(100, 10 * $attempt))
        }
    }
    $null
}

function Test-LiveEvidenceProcessAlive {
    param($ProcessId, [string] $ProcessStartUtc)

    if ($null -eq $ProcessId -or [int]$ProcessId -le 0) { return $false }
    try {
        $process = Get-Process -Id ([int]$ProcessId) -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($ProcessStartUtc)) { return $true }
        $expected = [DateTime]::Parse($ProcessStartUtc).ToUniversalTime()
        [Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -le 2
    }
    catch { $false }
}

function New-LiveEvidenceOutcome {
    param(
        [Parameter(Mandatory = $true)] [string] $CaptureId,
        [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $Status,
        [Parameter(Mandatory = $true)] [string] $Message,
        [bool] $Success = $false,
        [string] $FailureKind,
        [Nullable[int]] $WorkerId,
        [string] $LifecycleStage,
        [Nullable[int]] $ApplicationProcessId,
        [string] $EvidencePath,
        $Details
    )

    [ordered]@{
        FormatVersion = $script:LiveEvidenceFormatVersion
        CaptureId = $CaptureId
        RequestId = $RequestId
        Success = $Success
        Status = $Status
        FailureKind = $FailureKind
        Message = $Message
        WorkerId = if ($null -ne $WorkerId) { [int]$WorkerId } else { $null }
        LifecycleStage = $LifecycleStage
        ApplicationProcessId = if ($null -ne $ApplicationProcessId) { [int]$ApplicationProcessId } else { $null }
        EvidencePath = $EvidencePath
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Details = $Details
    }
}

function Write-LiveEvidenceOutcome {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] [string] $CaptureId,
        [Parameter(Mandatory = $true)] $Outcome
    )

    if (-not (Test-LiveEvidenceIdentifier -Value $CaptureId)) {
        throw "Invalid live evidence capture id: $CaptureId"
    }
    $layout = Initialize-LiveEvidenceDirectories -BrokerRoot $BrokerRoot
    $responsePath = Join-Path $layout.Responses ($CaptureId + '.json')
    if (-not (Test-Path -LiteralPath $responsePath -PathType Leaf)) {
        Write-JsonAtomic -Path $responsePath -Value $Outcome
    }
    $responsePath
}

function Invoke-WithLiveEvidenceMutex {
    param(
        [Parameter(Mandatory = $true)] [string] $CaptureId,
        [Parameter(Mandatory = $true)] [scriptblock] $Operation,
        [ValidateRange(1, 30)] [int] $TimeoutSeconds = 10
    )

    if (-not (Test-LiveEvidenceIdentifier -Value $CaptureId)) {
        throw "Invalid live evidence capture id: $CaptureId"
    }
    $mutex = New-Object Threading.Mutex($false, ('Global\CodexHyperVLiveEvidence-' + $CaptureId))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { return $null }
        & $Operation
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-LiveEvidenceLifecycleDisposition {
    param([string] $LifecycleStage, [Nullable[int]] $ApplicationProcessId)

    if ($LifecycleStage -in $script:LiveEvidenceTerminalStages) { return 'Terminal' }
    if ($LifecycleStage -in $script:LiveEvidenceSupportedStages -and $null -ne $ApplicationProcessId -and [int]$ApplicationProcessId -gt 0) { return 'Supported' }
    'DesktopNotReady'
}

function Get-LiveEvidencePoolBinding {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Nullable[int]] $ExpectedWorkerId,
        [string] $ExpectedOperationId
    )

    $processingFile = Join-Path (Join-Path $BrokerRoot 'Processing') ($RequestId + '.json')
    $processingRequest = Read-LiveEvidenceJsonSafe -Path $processingFile
    if (-not $processingRequest -or -not [string]::Equals([string]$processingRequest.RequestId, $RequestId, [StringComparison]::Ordinal)) {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = 'The broker processing record is missing or does not match the request ID.'; WorkerId = $null; OperationId = $null }
    }

    if (-not [bool]$Config.PoolEnabled) {
        return [pscustomobject][ordered]@{ Valid = $true; Reason = $null; WorkerId = $null; OperationId = $null }
    }

    $matches = @(Get-PoolWorkerStates -BrokerRoot $BrokerRoot -Config $Config | Where-Object {
        [string]::Equals([string]$_.RequestId, $RequestId, [StringComparison]::Ordinal) -and
        [string]$_.Status -eq 'Leased'
    })
    if ($matches.Count -ne 1) {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = "Expected exactly one leased worker for the request; found $($matches.Count)."; WorkerId = $null; OperationId = $null }
    }
    $state = $matches[0]
    if ($null -ne $ExpectedWorkerId -and [int]$state.WorkerId -ne [int]$ExpectedWorkerId) {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = 'The request is no longer bound to the expected worker.'; WorkerId = [int]$state.WorkerId; OperationId = [string]$state.OperationId }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedOperationId) -and -not [string]::Equals([string]$state.OperationId, $ExpectedOperationId, [StringComparison]::Ordinal)) {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = 'The worker operation ID no longer matches the capture binding.'; WorkerId = [int]$state.WorkerId; OperationId = [string]$state.OperationId }
    }
    if (-not (Test-LiveEvidenceProcessAlive -ProcessId $state.ProcessId -ProcessStartUtc $state.ProcessStartUtc)) {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = 'The bound worker process is not alive.'; WorkerId = [int]$state.WorkerId; OperationId = [string]$state.OperationId }
    }
    [pscustomobject][ordered]@{ Valid = $true; Reason = $null; WorkerId = [int]$state.WorkerId; OperationId = [string]$state.OperationId }
}

function Complete-LiveEvidenceCommandFailure {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] $Command,
        [Parameter(Mandatory = $true)] [string] $Status,
        [Parameter(Mandatory = $true)] [string] $FailureKind,
        [Parameter(Mandatory = $true)] [string] $Message,
        [string] $LifecycleStage,
        [Nullable[int]] $WorkerId,
        [Nullable[int]] $ApplicationProcessId,
        $Details
    )

    $outcome = New-LiveEvidenceOutcome -CaptureId ([string]$Command.CaptureId) -RequestId ([string]$Command.RequestId) -Status $Status -FailureKind $FailureKind -Message $Message -LifecycleStage $LifecycleStage -WorkerId $WorkerId -ApplicationProcessId $ApplicationProcessId -Details $Details
    Write-LiveEvidenceOutcome -BrokerRoot $BrokerRoot -CaptureId ([string]$Command.CaptureId) -Outcome $outcome | Out-Null
}

function Route-LiveEvidenceRequests {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] $Config
    )

    $layout = Initialize-LiveEvidenceDirectories -BrokerRoot $BrokerRoot
    foreach ($requestFile in @(Get-ChildItem -LiteralPath $layout.Requests -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc, Name)) {
        $captureId = [IO.Path]::GetFileNameWithoutExtension($requestFile.Name)
        if (-not (Test-LiveEvidenceIdentifier -Value $captureId)) {
            Remove-Item -LiteralPath $requestFile.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        Invoke-WithLiveEvidenceMutex -CaptureId $captureId -Operation {
            $responsePath = Join-Path $layout.Responses ($captureId + '.json')
            if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
                Remove-Item -LiteralPath $requestFile.FullName -Force -ErrorAction SilentlyContinue
                return
            }

            $claimedPath = Join-Path $layout.Processing ($captureId + '.' + [Guid]::NewGuid().ToString('N') + '.claimed')
            try { [IO.File]::Move($requestFile.FullName, $claimedPath) }
            catch {
                if (-not (Test-Path -LiteralPath $requestFile.FullName -PathType Leaf)) { return }
                throw
            }

            $command = $null
            try {
                $claimedItem = Get-Item -LiteralPath $claimedPath -Force
                if ($claimedItem.Length -le 0 -or $claimedItem.Length -gt 256KB) { throw 'Live evidence request JSON must be between 1 byte and 256 KiB.' }
                $command = Get-Content -LiteralPath $claimedPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if (-not $command.PSObject.Properties['FormatVersion'] -or [int]$command.FormatVersion -ne $script:LiveEvidenceFormatVersion) { throw 'Unsupported live evidence request format version.' }
                if (-not $command.PSObject.Properties['CaptureId'] -or -not [string]::Equals([string]$command.CaptureId, $captureId, [StringComparison]::Ordinal)) { throw 'CaptureId must match the request filename.' }
                if (-not $command.PSObject.Properties['RequestId'] -or -not (Test-LiveEvidenceIdentifier -Value ([string]$command.RequestId))) { throw 'RequestId is invalid.' }
                $guestPathInput = if ($command.PSObject.Properties['GuestEvidencePaths']) { @($command.GuestEvidencePaths) } else { @() }
                $guestPaths = @(Assert-LiveEvidenceRelativePaths -Paths $guestPathInput)
                $captureTimeoutMilliseconds = if ($command.PSObject.Properties['CaptureTimeoutMilliseconds'] -and $null -ne $command.CaptureTimeoutMilliseconds) { [int]$command.CaptureTimeoutMilliseconds } else { 30000 }
                if ($captureTimeoutMilliseconds -lt 3000 -or $captureTimeoutMilliseconds -gt 30000) { throw 'CaptureTimeoutMilliseconds must be between 3000 and 30000.' }
                $command | Add-Member -NotePropertyName GuestEvidencePaths -NotePropertyValue $guestPaths -Force
                $command | Add-Member -NotePropertyName CaptureTimeoutMilliseconds -NotePropertyValue $captureTimeoutMilliseconds -Force
                if (-not $command.PSObject.Properties['RequestedUtc'] -or [string]::IsNullOrWhiteSpace([string]$command.RequestedUtc)) { throw 'RequestedUtc is required.' }
                try { $normalizedRequestedUtc = ConvertTo-LiveEvidenceUtcString -Value $command.RequestedUtc }
                catch { throw "RequestedUtc must be a valid timestamp: $($_.Exception.Message)" }
                $command | Add-Member -NotePropertyName RequestedUtc -NotePropertyValue $normalizedRequestedUtc -Force
            }
            catch {
                $fallbackRequestId = if ($command -and $command.PSObject.Properties['RequestId']) { [string]$command.RequestId } else { $null }
                $fallback = [pscustomobject]@{ CaptureId = $captureId; RequestId = $fallbackRequestId }
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $fallback -Status 'Rejected' -FailureKind 'Validation' -Message $_.Exception.Message
                Remove-Item -LiteralPath $claimedPath -Force -ErrorAction SilentlyContinue
                return
            }

            $requestId = [string]$command.RequestId
            $resultRoot = Join-Path (Join-Path $BrokerRoot 'Results') $requestId
            $brokerResultPath = Join-Path $resultRoot 'broker-result.json'
            # Only the broker-authored request state may authorize a live
            # capture. client-state.json is an informational projection and
            # deliberately cannot supply lifecycle/PID binding authority.
            $requestState = Read-LiveEvidenceJsonSafe -Path (Join-Path $resultRoot 'request-state.json')
            $lifecycleStage = if ($requestState) { [string]$requestState.Status } else { $null }
            $applicationProcessId = if ($requestState -and $requestState.PSObject.Properties['ApplicationProcessId'] -and $null -ne $requestState.ApplicationProcessId) { [Nullable[int]]([int]$requestState.ApplicationProcessId) } else { $null }

            $disposition = Get-LiveEvidenceLifecycleDisposition -LifecycleStage $lifecycleStage -ApplicationProcessId $applicationProcessId
            if ((Test-Path -LiteralPath $brokerResultPath -PathType Leaf) -or $disposition -eq 'Terminal') {
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $command -Status 'RequestAlreadyTerminal' -FailureKind 'RequestAlreadyTerminal' -Message 'The request has already entered a terminal lifecycle stage.' -LifecycleStage $lifecycleStage -ApplicationProcessId $applicationProcessId
                Remove-Item -LiteralPath $claimedPath -Force -ErrorAction SilentlyContinue
                return
            }
            $queuedFile = Join-Path (Join-Path $BrokerRoot 'Requests') ($requestId + '.json')
            $processingFile = Join-Path (Join-Path $BrokerRoot 'Processing') ($requestId + '.json')
            if (Test-Path -LiteralPath $queuedFile -PathType Leaf) {
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $command -Status 'QueuedNotRunning' -FailureKind 'QueuedNotRunning' -Message 'The request is queued and has not been bound to a worker.' -LifecycleStage $lifecycleStage
                Remove-Item -LiteralPath $claimedPath -Force -ErrorAction SilentlyContinue
                return
            }
            if (-not (Test-Path -LiteralPath $processingFile -PathType Leaf)) {
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $command -Status 'RequestNotFound' -FailureKind 'RequestNotFound' -Message 'No queued, broker-owned running, or terminal request was found with this ID.' -LifecycleStage $lifecycleStage
                Remove-Item -LiteralPath $claimedPath -Force -ErrorAction SilentlyContinue
                return
            }

            if ($disposition -ne 'Supported') {
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $command -Status 'GuestDesktopNotReady' -FailureKind 'GuestDesktopNotReady' -Message "Live capture is not available at lifecycle stage '$lifecycleStage'; the interactive application session is not confirmed ready." -LifecycleStage $lifecycleStage -ApplicationProcessId $applicationProcessId
                Remove-Item -LiteralPath $claimedPath -Force -ErrorAction SilentlyContinue
                return
            }

            $binding = Get-LiveEvidencePoolBinding -BrokerRoot $BrokerRoot -Config $Config -RequestId $requestId
            if (-not $binding.Valid) {
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $command -Status 'StaleWorkerRequestBinding' -FailureKind 'StaleWorkerRequestBinding' -Message ([string]$binding.Reason) -LifecycleStage $lifecycleStage -WorkerId $binding.WorkerId -ApplicationProcessId $applicationProcessId
                Remove-Item -LiteralPath $claimedPath -Force -ErrorAction SilentlyContinue
                return
            }

            $bound = [ordered]@{
                FormatVersion = $script:LiveEvidenceFormatVersion
                CaptureId = $captureId
                RequestId = $requestId
                RequestedUtc = [string]$command.RequestedUtc
                RequestedBy = if ($command.PSObject.Properties['RequestedBy']) { [string]$command.RequestedBy } else { $null }
                GuestEvidencePaths = @($command.GuestEvidencePaths)
                CaptureTimeoutMilliseconds = [int]$command.CaptureTimeoutMilliseconds
                Status = 'Bound'
                BoundUtc = [DateTime]::UtcNow.ToString('o')
                ExpectedWorkerId = if ($null -ne $binding.WorkerId) { [int]$binding.WorkerId } else { $null }
                ExpectedOperationId = [string]$binding.OperationId
                ExpectedApplicationProcessId = [int]$applicationProcessId
                BoundLifecycleStage = $lifecycleStage
                HostWorkerProcessId = $null
                HostWorkerProcessStartUtc = $null
                GuestSubmittedUtc = $null
            }
            $boundPath = Join-Path $layout.Processing ($captureId + '.json')
            Write-JsonAtomic -Path $boundPath -Value $bound
            Remove-Item -LiteralPath $claimedPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Reconcile-LiveEvidenceCommands {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] $Config
    )

    $layout = Initialize-LiveEvidenceDirectories -BrokerRoot $BrokerRoot
    $temporaryCutoff = [DateTime]::UtcNow.AddHours(-1)
    Get-ChildItem -LiteralPath $layout.Requests -Filter '*.tmp' -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTimeUtc -lt $temporaryCutoff |
        Remove-Item -Force -ErrorAction SilentlyContinue

    foreach ($claimedFile in @(Get-ChildItem -LiteralPath $layout.Processing -Filter '*.claimed' -File -ErrorAction SilentlyContinue)) {
        $captureId = ($claimedFile.Name -split '\.')[0]
        if (-not (Test-LiveEvidenceIdentifier -Value $captureId)) {
            Remove-Item -LiteralPath $claimedFile.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        Invoke-WithLiveEvidenceMutex -CaptureId $captureId -TimeoutSeconds 2 -Operation {
            $boundPath = Join-Path $layout.Processing ($captureId + '.json')
            $responsePath = Join-Path $layout.Responses ($captureId + '.json')
            $requestPath = Join-Path $layout.Requests ($captureId + '.json')
            if ((Test-Path -LiteralPath $boundPath -PathType Leaf) -or (Test-Path -LiteralPath $responsePath -PathType Leaf)) {
                Remove-Item -LiteralPath $claimedFile.FullName -Force -ErrorAction SilentlyContinue
            }
            elseif (-not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
                [IO.File]::Move($claimedFile.FullName, $requestPath)
            }
            else {
                Remove-Item -LiteralPath $claimedFile.FullName -Force -ErrorAction SilentlyContinue
            }
        } | Out-Null
    }

    foreach ($commandFile in @(Get-ChildItem -LiteralPath $layout.Processing -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $captureId = [IO.Path]::GetFileNameWithoutExtension($commandFile.Name)
        if (-not (Test-LiveEvidenceIdentifier -Value $captureId)) { continue }
        Invoke-WithLiveEvidenceMutex -CaptureId $captureId -TimeoutSeconds 2 -Operation {
            $command = Read-LiveEvidenceJsonSafe -Path $commandFile.FullName
            if (-not $command) { return }
            $responsePath = Join-Path $layout.Responses ($captureId + '.json')
            if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
                Remove-Item -LiteralPath $commandFile.FullName -Force -ErrorAction SilentlyContinue
                return
            }
            $requestId = [string]$command.RequestId
            $resultRoot = Join-Path (Join-Path $BrokerRoot 'Results') $requestId
            $requestState = Read-LiveEvidenceJsonSafe -Path (Join-Path $resultRoot 'request-state.json')
            $lifecycleStage = if ($requestState) { [string]$requestState.Status } else { $null }
            $applicationProcessId = if ($requestState -and $requestState.PSObject.Properties['ApplicationProcessId'] -and $null -ne $requestState.ApplicationProcessId) { [Nullable[int]]([int]$requestState.ApplicationProcessId) } else { $null }
            $expectedWorkerId = if ($command.PSObject.Properties['ExpectedWorkerId'] -and $null -ne $command.ExpectedWorkerId) { [Nullable[int]]([int]$command.ExpectedWorkerId) } else { $null }
            $expectedOperationId = if ($command.PSObject.Properties['ExpectedOperationId']) { [string]$command.ExpectedOperationId } else { $null }
            $binding = Get-LiveEvidencePoolBinding -BrokerRoot $BrokerRoot -Config $Config -RequestId $requestId -ExpectedWorkerId $expectedWorkerId -ExpectedOperationId $expectedOperationId
            $terminal = (Test-Path -LiteralPath (Join-Path $resultRoot 'broker-result.json') -PathType Leaf) -or (Get-LiveEvidenceLifecycleDisposition -LifecycleStage $lifecycleStage -ApplicationProcessId $applicationProcessId) -eq 'Terminal'
            $hostWorkerAlive = $false
            if ($command.PSObject.Properties['Status'] -and [string]$command.Status -eq 'Capturing' -and $command.PSObject.Properties['HostWorkerProcessId'] -and $command.HostWorkerProcessId) {
                $hostWorkerStartUtc = if ($command.PSObject.Properties['HostWorkerProcessStartUtc']) { [string]$command.HostWorkerProcessStartUtc } else { $null }
                $hostWorkerAlive = Test-LiveEvidenceProcessAlive -ProcessId $command.HostWorkerProcessId -ProcessStartUtc $hostWorkerStartUtc
            }
            if ($terminal) {
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $command -Status 'RequestAlreadyTerminal' -FailureKind 'RequestAlreadyTerminal' -Message 'The request became terminal before live evidence publication completed.' -LifecycleStage $lifecycleStage -WorkerId $binding.WorkerId -ApplicationProcessId $applicationProcessId
                Remove-Item -LiteralPath $commandFile.FullName -Force -ErrorAction SilentlyContinue
            }
            elseif (-not $binding.Valid -and -not $hostWorkerAlive) {
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $command -Status 'StaleWorkerRequestBinding' -FailureKind 'StaleWorkerRequestBinding' -Message ([string]$binding.Reason) -LifecycleStage $lifecycleStage -WorkerId $binding.WorkerId -ApplicationProcessId $applicationProcessId
                Remove-Item -LiteralPath $commandFile.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
