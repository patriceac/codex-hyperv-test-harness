param(
    [string] $BrokerRoot,
    [switch] $LibraryOnly
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BrokerRoot)) {
    $pointerPath = Join-Path $env:ProgramData 'CodexHyperVBroker\location.json'
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) { throw "BrokerRoot was not supplied and the location pointer is missing: $pointerPath" }
    $pointer = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$pointer.BrokerRoot)) { throw "The broker location pointer has no BrokerRoot: $pointerPath" }
    $BrokerRoot = [IO.Path]::GetFullPath([string]$pointer.BrokerRoot)
}

$configPath = Join-Path $BrokerRoot 'Private\config.json'
$credentialPath = Join-Path $BrokerRoot 'Private\guest-credential.json'
$requestPath = Join-Path $BrokerRoot 'Requests'
$processingPath = Join-Path $BrokerRoot 'Processing'
$archivePath = Join-Path $BrokerRoot 'Archive'
$resultsPath = Join-Path $BrokerRoot 'Results'
$stagingPath = Join-Path $BrokerRoot 'Staging'
$payloadManifestPath = Join-Path $BrokerRoot 'PayloadManifests'
$payloadCachePath = Join-Path $BrokerRoot 'PayloadCache'
$payloadCacheTempPath = Join-Path $BrokerRoot 'PayloadCacheTemp'
$payloadMountPath = Join-Path $BrokerRoot 'PayloadMounts'
$payloadChildrenPath = Join-Path $BrokerRoot 'PayloadChildren'
$cancellationPath = Join-Path $BrokerRoot 'Cancellations'
$cancelledPath = Join-Path $BrokerRoot 'Cancelled'
$statePath = Join-Path $BrokerRoot 'State\broker-state.json'
$maintenancePath = Join-Path $BrokerRoot 'State\maintenance.json'
$probePath = Join-Path $BrokerRoot 'State\GuestProbes'
$payloadGcStatePath = Join-Path $BrokerRoot 'State\payload-cache-gc.json'
$payloadLeasePath = Join-Path $BrokerRoot 'State\PayloadLeases'
$hostInputStatePath = Join-Path $BrokerRoot 'State\HostInputs'
$requestNetworkStatePath = Join-Path $BrokerRoot 'State\NetworkLeases'
$fatalStatePath = Join-Path $BrokerRoot 'State\broker-fatal.json'

foreach ($path in @($requestPath, $processingPath, $archivePath, $resultsPath, $stagingPath, $payloadManifestPath, $payloadCachePath, $payloadCacheTempPath, $payloadMountPath, $payloadChildrenPath, $cancellationPath, $cancelledPath, (Split-Path -Parent $statePath), $probePath, $payloadLeasePath, $hostInputStatePath, $requestNetworkStatePath)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporaryPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $temporaryPath + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                    [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
                }
                else {
                    [IO.File]::Move($temporaryPath, $Path)
                }
                return
            }
            catch [IO.IOException] {
                if ($attempt -ge 20) { throw }
            }
            catch [UnauthorizedAccessException] {
                if ($attempt -ge 20) { throw }
            }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

$payloadCacheModulePath = Join-Path $PSScriptRoot 'PayloadCache.ps1'
if (-not (Test-Path -LiteralPath $payloadCacheModulePath -PathType Leaf)) {
    throw "Payload cache module not found: $payloadCacheModulePath"
}
. $payloadCacheModulePath
$hostInputModulePath = Join-Path $PSScriptRoot 'HostInputShare.ps1'
if (-not (Test-Path -LiteralPath $hostInputModulePath -PathType Leaf)) {
    throw "Host-input sharing module not found: $hostInputModulePath"
}
. $hostInputModulePath
$requestNetworkModulePath = Join-Path $PSScriptRoot 'RequestNetwork.ps1'
if (-not (Test-Path -LiteralPath $requestNetworkModulePath -PathType Leaf)) {
    throw "Request-network module not found: $requestNetworkModulePath"
}
. $requestNetworkModulePath

function Write-BrokerState {
    param(
        [string] $Status = 'Idle',
        [string] $RequestId = $null,
        [string] $Message = $null
    )

    $targetStatePath = if (-not [string]::IsNullOrWhiteSpace([string]$global:CodexBrokerStateOverridePath)) {
        [string]$global:CodexBrokerStateOverridePath
    }
    else {
        $statePath
    }
    Write-JsonAtomic -Path $targetStatePath -Value ([ordered]@{
        Ready = $true
        Status = $Status
        RequestId = $RequestId
        Message = $Message
        HeartbeatUtc = [DateTime]::UtcNow.ToString('o')
        ProcessId = $PID
        SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        IdentitySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        MachineName = $env:COMPUTERNAME
    })
}

function Write-RequestState {
    param(
        [Parameter(Mandatory = $true)] [string] $ResultRoot,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $Status,
        [string] $Message = $null,
        [Nullable[int]] $QueuePosition = $null,
        [Nullable[int]] $QueueDepth = $null,
        [Nullable[DateTime]] $CreatedUtc = $null,
        [Nullable[DateTime]] $ClaimedUtc = $null,
        [Nullable[DateTime]] $ExecutionDeadlineUtc = $null,
        [Nullable[int]] $WorkerId = $null,
        [Nullable[int]] $ApplicationProcessId = $null,
        [string] $ApplicationStartedUtc = $null,
        [Nullable[int]] $GuestActionIndex = $null,
        [string] $GuestActionType = $null
    )

    $requestStatePath = Join-Path $ResultRoot 'request-state.json'
    $previousState = $null
    if (Test-Path -LiteralPath $requestStatePath -PathType Leaf) {
        try { $previousState = Get-Content -Raw -LiteralPath $requestStatePath | ConvertFrom-Json }
        catch { $previousState = $null }
    }

    $resetWorker = $Status -in @('Submitted', 'Queued', 'RetryQueued')
    $effectiveWorkerId = if ($PSBoundParameters.ContainsKey('WorkerId')) {
        if ($null -ne $WorkerId) { [int]$WorkerId } else { $null }
    }
    elseif (-not $resetWorker -and $previousState -and $null -ne $previousState.WorkerId) {
        [int]$previousState.WorkerId
    }
    else { $null }

    $resetApplication = $Status -in @('Submitted', 'Queued', 'RetryQueued', 'Claimed', 'RetryPendingRecycle')
    $effectiveApplicationProcessId = if ($PSBoundParameters.ContainsKey('ApplicationProcessId')) {
        if ($null -ne $ApplicationProcessId) { [int]$ApplicationProcessId } else { $null }
    }
    elseif (-not $resetApplication -and $previousState -and $null -ne $previousState.ApplicationProcessId) {
        [int]$previousState.ApplicationProcessId
    }
    else { $null }
    $effectiveApplicationStartedUtc = if ($PSBoundParameters.ContainsKey('ApplicationStartedUtc')) {
        if ([string]::IsNullOrWhiteSpace($ApplicationStartedUtc)) { $null } else { $ApplicationStartedUtc }
    }
    elseif (-not $resetApplication -and $previousState) {
        if ([string]::IsNullOrWhiteSpace([string]$previousState.ApplicationStartedUtc)) { $null } else { [string]$previousState.ApplicationStartedUtc }
    }
    else { $null }

    $effectiveGuestActionIndex = if ($Status -eq 'GuestAction' -and $null -ne $GuestActionIndex) { [Nullable[int]]([int]$GuestActionIndex) } else { $null }
    $effectiveGuestActionType = if ($Status -eq 'GuestAction' -and -not [string]::IsNullOrWhiteSpace($GuestActionType)) { $GuestActionType } else { $null }
    $updatedUtc = [DateTime]::UtcNow.ToString('o')
    $currentComparable = [ordered]@{
        Status = $Status
        Message = $Message
        QueuePosition = if ($null -ne $QueuePosition) { [int]$QueuePosition } else { $null }
        QueueDepth = if ($null -ne $QueueDepth) { [int]$QueueDepth } else { $null }
        WorkerId = $effectiveWorkerId
        ApplicationProcessId = $effectiveApplicationProcessId
        ApplicationStartedUtc = $effectiveApplicationStartedUtc
        GuestActionIndex = if ($null -ne $effectiveGuestActionIndex) { [int]$effectiveGuestActionIndex } else { $null }
        GuestActionType = $effectiveGuestActionType
    }
    $previousComparable = if ($previousState) {
        [ordered]@{
            Status = [string]$previousState.Status
            Message = if ([string]::IsNullOrWhiteSpace([string]$previousState.Message)) { $null } else { [string]$previousState.Message }
            QueuePosition = if ($null -ne $previousState.QueuePosition) { [int]$previousState.QueuePosition } else { $null }
            QueueDepth = if ($null -ne $previousState.QueueDepth) { [int]$previousState.QueueDepth } else { $null }
            WorkerId = if ($null -ne $previousState.WorkerId) { [int]$previousState.WorkerId } else { $null }
            ApplicationProcessId = if ($null -ne $previousState.ApplicationProcessId) { [int]$previousState.ApplicationProcessId } else { $null }
            ApplicationStartedUtc = if ([string]::IsNullOrWhiteSpace([string]$previousState.ApplicationStartedUtc)) { $null } else { [string]$previousState.ApplicationStartedUtc }
            GuestActionIndex = if ($null -ne $previousState.GuestActionIndex) { [int]$previousState.GuestActionIndex } else { $null }
            GuestActionType = if ([string]::IsNullOrWhiteSpace([string]$previousState.GuestActionType)) { $null } else { [string]$previousState.GuestActionType }
        }
    }
    else { $null }
    $stateChanged = -not $previousState -or
        ($currentComparable | ConvertTo-Json -Depth 4 -Compress) -ne ($previousComparable | ConvertTo-Json -Depth 4 -Compress)
    $revision = if ($previousState -and $null -ne $previousState.Revision) { [int64]$previousState.Revision } else { 0 }
    $history = @(if ($previousState -and $previousState.History) { $previousState.History | Where-Object { $null -ne $_ } })
    if ($stateChanged) {
        $revision++
        $history += [pscustomobject][ordered]@{
            Revision = $revision
            Status = $Status
            Message = $Message
            QueuePosition = $currentComparable.QueuePosition
            QueueDepth = $currentComparable.QueueDepth
            WorkerId = $effectiveWorkerId
            ApplicationProcessId = $effectiveApplicationProcessId
            ApplicationStartedUtc = $effectiveApplicationStartedUtc
            GuestActionIndex = $currentComparable.GuestActionIndex
            GuestActionType = $effectiveGuestActionType
            UpdatedUtc = $updatedUtc
        }
        if ($history.Count -gt 128) {
            $history = @($history[($history.Count - 128)..($history.Count - 1)])
        }
    }

    Write-JsonAtomic -Path $requestStatePath -Value ([ordered]@{
        RequestId = $RequestId
        Status = $Status
        Message = $Message
        QueuePosition = if ($null -ne $QueuePosition) { [int]$QueuePosition } else { $null }
        QueueDepth = if ($null -ne $QueueDepth) { [int]$QueueDepth } else { $null }
        CreatedUtc = if ($null -ne $CreatedUtc) { ([DateTime]$CreatedUtc).ToString('o') } else { $null }
        ClaimedUtc = if ($null -ne $ClaimedUtc) { ([DateTime]$ClaimedUtc).ToString('o') } else { $null }
        ExecutionDeadlineUtc = if ($null -ne $ExecutionDeadlineUtc) { ([DateTime]$ExecutionDeadlineUtc).ToString('o') } else { $null }
        WorkerId = $effectiveWorkerId
        ApplicationProcessId = $effectiveApplicationProcessId
        ApplicationStartedUtc = $effectiveApplicationStartedUtc
        GuestActionIndex = if ($null -ne $effectiveGuestActionIndex) { [int]$effectiveGuestActionIndex } else { $null }
        GuestActionType = $effectiveGuestActionType
        Revision = $revision
        History = @($history)
        UpdatedUtc = $updatedUtc
        BrokerProcessId = $PID
        BrokerSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    })
}

function Get-BoundedTimeout {
    param(
        $Value,
        [int] $Default,
        [int] $Minimum,
        [int] $Maximum
    )

    $timeout = $Default
    if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) {
        $timeout = [int]$Value
    }
    [Math]::Max($Minimum, [Math]::Min($Maximum, $timeout))
}

function Assert-RequestActive {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc
    )

    # The broker's execution deadline is authoritative. If the client sends a
    # cancellation at the same boundary, retain the more specific timeout
    # terminal state instead of reporting an ordinary cancellation.
    if ([DateTime]::UtcNow -ge $ExecutionDeadlineUtc) {
        throw [TimeoutException]::new("Execution timeout expired for request $RequestId.")
    }

    $cancelFile = Join-Path $cancellationPath ($RequestId + '.json')
    if (Test-Path -LiteralPath $cancelFile -PathType Leaf) {
        $reason = 'Cancellation requested.'
        try {
            $cancelData = Get-Content -Raw -LiteralPath $cancelFile | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$cancelData.Reason)) {
                $reason = [string]$cancelData.Reason
            }
        }
        catch {
        }
        throw [OperationCanceledException]::new($reason)
    }
}

function Remove-StagedPayloadSafe {
    param([Parameter(Mandatory = $true)] [string] $RequestId)

    $rootPrefix = [IO.Path]::GetFullPath($stagingPath).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath((Join-Path $stagingPath $RequestId))
    if (-not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing staging cleanup outside the broker root: $target"
    }
    if (Test-Path -LiteralPath $target -PathType Container) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

function Remove-StaleQueueArtifacts {
    $temporaryCutoffUtc = [DateTime]::UtcNow.AddHours(-1)
    $orphanedStagingCutoffUtc = [DateTime]::UtcNow.AddMinutes(-15)
    foreach ($root in @($requestPath, $cancellationPath, (Split-Path -Parent $statePath))) {
        Get-ChildItem -LiteralPath $root -Filter '*.tmp' -File -ErrorAction SilentlyContinue |
            Where-Object LastWriteTimeUtc -lt $temporaryCutoffUtc |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    foreach ($directory in Get-ChildItem -LiteralPath $stagingPath -Directory -ErrorAction SilentlyContinue) {
        $requestId = $directory.Name
        if ($requestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
            continue
        }
        $isQueued = Test-Path -LiteralPath (Join-Path $requestPath ($requestId + '.json')) -PathType Leaf
        $isProcessing = Test-Path -LiteralPath (Join-Path $processingPath ($requestId + '.json')) -PathType Leaf
        $hasBrokerResult = Test-Path -LiteralPath (Join-Path (Join-Path $resultsPath $requestId) 'broker-result.json') -PathType Leaf
        $hasCancelledRecord = $null -ne (Get-ChildItem -LiteralPath $cancelledPath -Filter ($requestId + '-*.json') -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        $stagingLeaseActive = $false
        $stagingLeasePath = Join-Path $directory.FullName '.codex-staging-lease.json'
        if (Test-Path -LiteralPath $stagingLeasePath -PathType Leaf) {
            try {
                $stagingLease = Get-Content -Raw -LiteralPath $stagingLeasePath | ConvertFrom-Json
                $stagingProcess = Get-Process -Id ([int]$stagingLease.ProcessId) -ErrorAction SilentlyContinue
                if ($stagingProcess -and $stagingProcess.ProcessName -in @('powershell', 'pwsh')) {
                    $expectedStartUtc = [DateTime]::Parse([string]$stagingLease.ProcessStartUtc).ToUniversalTime()
                    $actualStartUtc = $stagingProcess.StartTime.ToUniversalTime()
                    $stagingLeaseActive = [Math]::Abs(($actualStartUtc - $expectedStartUtc).TotalSeconds) -le 2
                }
            }
            catch {
            }
        }
        $terminalStaging = $hasBrokerResult -or $hasCancelledRecord
        $abandonedStaging = -not $terminalStaging -and -not $stagingLeaseActive -and $directory.LastWriteTimeUtc -lt $orphanedStagingCutoffUtc
        if (-not $isQueued -and -not $isProcessing -and ($terminalStaging -or $abandonedStaging)) {
            try {
                Remove-StagedPayloadSafe -RequestId $requestId
            }
            catch {
            }
        }
    }

    foreach ($cancellationFile in Get-ChildItem -LiteralPath $cancellationPath -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $requestId = [IO.Path]::GetFileNameWithoutExtension($cancellationFile.Name)
        if ($requestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
            continue
        }
        $isQueued = Test-Path -LiteralPath (Join-Path $requestPath ($requestId + '.json')) -PathType Leaf
        $isProcessing = Test-Path -LiteralPath (Join-Path $processingPath ($requestId + '.json')) -PathType Leaf
        $hasBrokerResult = Test-Path -LiteralPath (Join-Path (Join-Path $resultsPath $requestId) 'broker-result.json') -PathType Leaf
        if (-not $isQueued -and -not $isProcessing -and $hasBrokerResult) {
            Remove-Item -LiteralPath $cancellationFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Recover-InterruptedRequests {
    param([Parameter(Mandatory = $true)] $Config)

    $interruptedFiles = @(Get-ChildItem -LiteralPath $processingPath -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc, Name)
    if ($interruptedFiles.Count -eq 0) {
        return
    }

    Write-BrokerState -Status 'RecoveringQueue' -Message "Recovering $($interruptedFiles.Count) request(s) left by an interrupted broker."
    $unfinishedFiles = @($interruptedFiles | Where-Object {
        $id = [IO.Path]::GetFileNameWithoutExtension($_.Name)
        -not (Test-Path -LiteralPath (Join-Path (Join-Path $resultsPath $id) 'broker-result.json') -PathType Leaf)
    })
    if ($unfinishedFiles.Count -gt 0) {
        # The previous broker may have died after launching the disposable VM.
        # Power it off before requeueing so no old application can overlap the
        # clean retry.
        Stop-TestVm -VmName ([string]$Config.VmName) -Immediate
    }

    foreach ($processingFile in $interruptedFiles) {
        $requestId = [IO.Path]::GetFileNameWithoutExtension($processingFile.Name)
        if ($requestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
            $invalidArchive = Join-Path $archivePath ('invalid-recovered-' + [Guid]::NewGuid().ToString('N') + '.json')
            Move-Item -LiteralPath $processingFile.FullName -Destination $invalidArchive -Force
            continue
        }
        $resultRoot = Join-Path $resultsPath $requestId
        $brokerResultFile = Join-Path $resultRoot 'broker-result.json'
        if (Test-Path -LiteralPath $brokerResultFile -PathType Leaf) {
            $archiveFile = Join-Path $archivePath ($requestId + '-recovered-terminal-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
            Move-Item -LiteralPath $processingFile.FullName -Destination $archiveFile -Force
            try {
                Remove-StagedPayloadSafe -RequestId $requestId
            }
            catch {
            }
            continue
        }

        New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
        Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'RecoveredAfterBrokerRestart' -Message 'The previous broker stopped mid-run; the VM was powered off and the request was safely requeued.'
        $queuedFile = Join-Path $requestPath $processingFile.Name
        if (Test-Path -LiteralPath $queuedFile -PathType Leaf) {
            $duplicateArchive = Join-Path $archivePath ($requestId + '-recovered-duplicate-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
            Move-Item -LiteralPath $processingFile.FullName -Destination $duplicateArchive -Force
        }
        else {
            Move-Item -LiteralPath $processingFile.FullName -Destination $queuedFile
        }
    }
}

function Get-HostLockEvidence {
    $activeConsoleSessionId = [CodexHostSession]::GetActiveConsoleSessionId()
    # WTSSessionInfoEx is the authoritative Windows 11 lock signal: level-1
    # SessionFlags is 0 while locked and 1 while unlocked. LogonUI can disappear
    # while the lock screen remains active, so process presence is fallback-only.
    $wtsSessionFlags = [CodexHostSession]::GetSessionFlags($activeConsoleSessionId)
    $lockProcesses = @(Get-Process -Name LogonUI -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $activeConsoleSessionId } |
        Select-Object Id, ProcessName, SessionId, StartTime)

    $latestEvent = $null
    try {
        $latestEvent = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = @(4800, 4801) } -MaxEvents 1 -ErrorAction Stop
    }
    catch {
        # Security auditing may be disabled; current LogonUI/LockApp presence is
        # still recorded as the live lock-state signal.
    }

    $processSaysLocked = $lockProcesses.Count -gt 0
    $hasWtsSignal = $wtsSessionFlags -in @(0, 1)
    $isLocked = if ($hasWtsSignal) { $wtsSessionFlags -eq 0 } else { $processSaysLocked }
    [ordered]@{
        IsLocked = [bool]$isLocked
        CheckedUtc = [DateTime]::UtcNow.ToString('o')
        ActiveConsoleSessionId = [uint32]$activeConsoleSessionId
        WtsSessionFlags = [int]$wtsSessionFlags
        LockSignal = if ($hasWtsSignal) { 'WTSSessionInfoEx' } else { 'LogonUIFallback' }
        LockProcesses = @($lockProcesses)
        LatestSecurityEvent = if ($latestEvent) {
            [ordered]@{
                Id = [int]$latestEvent.Id
                RecordId = [long]$latestEvent.RecordId
                TimeCreated = $latestEvent.TimeCreated.ToUniversalTime().ToString('o')
            }
        }
        else {
            $null
        }
    }
}

function Wait-ForHostLock {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc,
        [Parameter(Mandatory = $true)] [string] $ResultRoot,
        [Parameter(Mandatory = $true)] [DateTime] $ClaimedUtc
    )

    $consecutiveLockedChecks = 0
    while ($true) {
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        $evidence = Get-HostLockEvidence
        if ($evidence.IsLocked) {
            $consecutiveLockedChecks++
            if ($consecutiveLockedChecks -ge 3) {
                return $evidence
            }
        }
        else {
            $consecutiveLockedChecks = 0
        }
        Write-BrokerState -Status 'WaitingForHostLock' -RequestId $RequestId -Message 'Waiting for the physical workstation to lock.'
        Write-RequestState -ResultRoot $ResultRoot -RequestId $RequestId -Status 'WaitingForHostLock' -Message 'Waiting for the physical workstation to lock.' -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        Start-Sleep -Seconds 1
    }
}

function Get-GuestCredential {
    $credentialData = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
    $securePassword = ConvertTo-SecureString ([string]$credentialData.Password) -AsPlainText -Force
    New-Object Management.Automation.PSCredential([string]$credentialData.UserName, $securePassword)
}

function Wait-TestVmOff {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [ValidateRange(1, 60)] [int] $TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ((Get-VM -Name $VmName -ErrorAction Stop).State -eq 'Off') {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "The VM did not reach the Off state within $TimeoutSeconds seconds: $VmName"
}

function Stop-TestVm {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [switch] $Immediate
    )

    $vm = Get-VM -Name $VmName
    if ($vm.State -eq 'Off') {
        return
    }
    if ($Immediate) {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop | Out-Null
        Wait-TestVmOff -VmName $VmName
        return
    }
    try {
        Stop-VM -Name $VmName -Shutdown -ErrorAction Stop
    }
    catch {
        # The graceful request can fail while the guest is still starting.
    }
    # Each run is restored from the clean checkpoint, and all requested
    # evidence is copied to the host before shutdown. Do not hold the global
    # queue for a guest that ignores a graceful shutdown request.
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ((Get-VM -Name $VmName).State -ne 'Off' -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
    }
    if ((Get-VM -Name $VmName).State -ne 'Off') {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop | Out-Null
        Wait-TestVmOff -VmName $VmName
    }
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([Parameter(Mandatory = $true)] [string] $Value)

    "'" + $Value.Replace("'", "''") + "'"
}

function Stop-GuestProbeProcess {
    param(
        [Diagnostics.Process] $Process,
        [string] $LeasePath
    )

    if ($Process) {
        try {
            $Process.Refresh()
            if (-not $Process.HasExited) {
                Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
                [void]$Process.WaitForExit(1000)
            }
        }
        catch {
        }
        finally {
            $Process.Dispose()
        }
    }
    if ($LeasePath) {
        Remove-Item -LiteralPath $LeasePath -Force -ErrorAction SilentlyContinue
    }
}

function Recover-OrphanedGuestProbes {
    foreach ($leaseFile in Get-ChildItem -LiteralPath $probePath -Filter '*.process.json' -File -ErrorAction SilentlyContinue) {
        try {
            $lease = Get-Content -Raw -LiteralPath $leaseFile.FullName | ConvertFrom-Json
            $process = Get-Process -Id ([int]$lease.ProcessId) -ErrorAction SilentlyContinue
            if ($process -and $process.ProcessName -ieq 'powershell') {
                $expectedStartUtc = [DateTime]::Parse([string]$lease.ProcessStartUtc).ToUniversalTime()
                $actualStartUtc = $process.StartTime.ToUniversalTime()
                if ([Math]::Abs(($actualStartUtc - $expectedStartUtc).TotalSeconds) -le 2) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
            }
        }
        catch {
        }
        finally {
            $probeBase = $leaseFile.FullName.Substring(0, $leaseFile.FullName.Length - '.process.json'.Length)
            Remove-Item -LiteralPath $leaseFile.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($probeBase + '.json') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($probeBase + '.json.tmp') -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-GuestSessionProbe {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $OutputPath
    )

    $probeTemplate = @'
$ErrorActionPreference = 'Stop'
$outputPath = __OUTPUT_PATH__
$exitCode = 0
try {
    $credentialData = Get-Content -Raw -LiteralPath __CREDENTIAL_PATH__ | ConvertFrom-Json
    $securePassword = ConvertTo-SecureString ([string]$credentialData.Password) -AsPlainText -Force
    $credential = New-Object Management.Automation.PSCredential([string]$credentialData.UserName, $securePassword)
    $state = Invoke-Command -VMName __VM_NAME__ -Credential $credential -ErrorAction Stop -ScriptBlock {
        $statePath = 'C:\CodexGuest\agent-state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            return $null
        }
        Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    } | Select-Object -Last 1
    $result = [ordered]@{ Success = $true; State = $state; Error = $null }
}
catch {
    $exitCode = 1
    $result = [ordered]@{
        Success = $false
        State = $null
        Error = $_.Exception.Message
        ErrorType = $_.Exception.GetType().FullName
        ErrorFullyQualifiedId = $_.FullyQualifiedErrorId
    }
}
$temporaryPath = $outputPath + '.tmp'
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
exit $exitCode
'@
    $probeCommand = $probeTemplate.
        Replace('__OUTPUT_PATH__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $OutputPath)).
        Replace('__CREDENTIAL_PATH__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $credentialPath)).
        Replace('__VM_NAME__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $VmName))
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCommand))
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand
    ) -WindowStyle Hidden -PassThru
    $leasePath = [IO.Path]::ChangeExtension($OutputPath, 'process.json')
    Write-JsonAtomic -Path $leasePath -Value ([ordered]@{
        ProcessId = $process.Id
        ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
    })
    [pscustomobject]@{
        Process = $process
        LeasePath = $leasePath
    }
}

function Wait-GuestSession {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $true)] [DateTime] $NotBeforeUtc,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc
    )

    # Credential is retained in the signature so callers cannot accidentally
    # bypass the same validated credential path used for later PSSessions. The
    # disposable child reads that protected file itself.
    $null = $Credential
    while ($true) {
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        Write-BrokerState -Status 'StartingVm' -RequestId $RequestId -Message 'Waiting for the interactive guest agent.'
        $probeId = $RequestId + '-' + [Guid]::NewGuid().ToString('N')
        $probeOutputPath = Join-Path $probePath ($probeId + '.json')
        $probe = $null
        try {
            # PowerShell Direct can block inside connection setup. Isolate it in
            # a disposable process so the single queue worker remains able to
            # enforce cancellation and execution deadlines.
            $probe = Start-GuestSessionProbe -VmName $VmName -OutputPath $probeOutputPath
            $nextProbeHeartbeatUtc = [DateTime]::MinValue
            while ($true) {
                Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
                if ([DateTime]::UtcNow -ge $nextProbeHeartbeatUtc) {
                    Write-BrokerState -Status 'StartingVm' -RequestId $RequestId -Message 'Waiting for the interactive guest agent.'
                    $nextProbeHeartbeatUtc = [DateTime]::UtcNow.AddSeconds(1)
                }
                $probe.Process.Refresh()
                if ($probe.Process.HasExited) {
                    break
                }
                Start-Sleep -Milliseconds 200
            }
            if (Test-Path -LiteralPath $probeOutputPath -PathType Leaf) {
                $probeResult = Get-Content -Raw -LiteralPath $probeOutputPath | ConvertFrom-Json
                $guestState = $probeResult.State
                if ($probeResult.Success -and $guestState -and $guestState.Ready -and $guestState.UserInteractive) {
                    $heartbeat = [DateTime]::Parse([string]$guestState.HeartbeatUtc).ToUniversalTime()
                    if ($heartbeat -ge $NotBeforeUtc.AddSeconds(-5)) {
                        return $guestState
                    }
                }
            }
        }
        catch [OperationCanceledException] {
            throw
        }
        catch [TimeoutException] {
            throw
        }
        catch {
            # PowerShell Direct and the autologon session take time to become ready.
        }
        finally {
            if ($probe) {
                Stop-GuestProbeProcess -Process $probe.Process -LeasePath $probe.LeasePath
            }
            Remove-Item -LiteralPath $probeOutputPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($probeOutputPath + '.tmp') -Force -ErrorAction SilentlyContinue
        }
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        Start-Sleep -Seconds 2
    }
}

function Open-GuestSessionReliable {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc,
        [ValidateRange(1, 5)] [int] $Attempts = 3
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        try {
            return New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
        }
        catch {
            $lastError = $_
            if ($attempt -ge $Attempts) {
                break
            }
            Write-BrokerState -Status 'RetryingGuestConnection' -RequestId $RequestId -Message "Hyper-V Direct connection attempt $attempt failed; retrying."
            Start-Sleep -Seconds 2
        }
    }

    throw $lastError
}

function Expand-GuestJobTokens {
    param(
        [AllowNull()] [string] $Value,
        [AllowNull()] [string] $GuestPayloadRoot,
        [Parameter(Mandatory = $true)] [string] $GuestOutputRoot,
        [Parameter(Mandatory = $true)] [string] $Context,
        [string[]] $AllowedTokens = @('PAYLOAD', 'OUTDIR'),
        [Collections.IDictionary] $GuestHostInputRoots
    )

    if ($null -eq $Value) {
        return $null
    }

    $reservedTokenPattern = '\{(?<Name>(?i:PAYLOAD|OUTDIR|HOSTINPUT:[A-Za-z][A-Za-z0-9_-]{0,31})|[A-Z][A-Z0-9_:.-]*)\}'
    foreach ($match in [regex]::Matches($Value, $reservedTokenPattern)) {
        $tokenName = [string]$match.Groups['Name'].Value
        $isHostInput = $tokenName.StartsWith('HOSTINPUT:', [StringComparison]::OrdinalIgnoreCase)
        $isAllowed = if ($isHostInput) {
            $tokenName.StartsWith('HOSTINPUT:', [StringComparison]::Ordinal) -and $AllowedTokens -contains $tokenName
        }
        else { $AllowedTokens -ccontains $tokenName }
        if (-not $isAllowed) {
            throw "$Context contains unresolved reserved token $($match.Value)."
        }
    }

    $expanded = $Value
    if ($expanded.Contains('{PAYLOAD}')) {
        if ([string]::IsNullOrWhiteSpace($GuestPayloadRoot)) {
            throw "$Context refers to {PAYLOAD}, but the attached payload VHDX was not resolved."
        }
        $expanded = $expanded.Replace('{PAYLOAD}', $GuestPayloadRoot.TrimEnd('\'))
    }
    if ($expanded.Contains('{OUTDIR}')) {
        $expanded = $expanded.Replace('{OUTDIR}', $GuestOutputRoot.TrimEnd('\'))
    }
    foreach ($match in @([regex]::Matches($expanded, '\{HOSTINPUT:(?<Alias>[A-Za-z][A-Za-z0-9_-]{0,31})\}'))) {
        $alias = [string]$match.Groups['Alias'].Value
        $root = $null
        if ($GuestHostInputRoots) {
            foreach ($key in @($GuestHostInputRoots.Keys)) {
                if ([string]::Equals([string]$key, $alias, [StringComparison]::OrdinalIgnoreCase)) {
                    $root = [string]$GuestHostInputRoots[$key]
                    break
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($root)) {
            throw "$Context refers to $($match.Value), but that read-only host input was not mounted."
        }
        $expanded = $expanded.Replace($match.Value, $root.TrimEnd('\'))
    }

    $unresolved = [regex]::Match($expanded, $reservedTokenPattern)
    if ($unresolved.Success) {
        throw "$Context contains unresolved reserved token $($unresolved.Value)."
    }
    $expanded
}

function Get-GuestLifecycleProgress {
    param(
        [Parameter(Mandatory = $true)] $CompletionState,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [bool] $ApplicationRunningPublished
    )

    $lease = $CompletionState.ApplicationLease
    $leaseConfirmed = $lease -and
        [string]::Equals([string]$lease.JobId, $RequestId, [StringComparison]::Ordinal) -and
        $null -ne $lease.ProcessId -and
        [int]$lease.ProcessId -gt 0
    $agentState = $CompletionState.AgentState

    if (-not $ApplicationRunningPublished) {
        if ($leaseConfirmed) {
            return [pscustomobject][ordered]@{
                Status = 'ApplicationRunning'
                Message = "Guest Start-Process confirmation received for application PID $([int]$lease.ProcessId)."
                ApplicationConfirmed = $true
                ApplicationProcessId = [int]$lease.ProcessId
                ApplicationStartedUtc = [string]$lease.StartedUtc
                GuestActionIndex = $null
                GuestActionType = $null
            }
        }
        if ($agentState -and
            [string]::Equals([string]$agentState.JobId, $RequestId, [StringComparison]::Ordinal) -and
            [string]::Equals([string]$agentState.Status, 'PreparingHostInputs', [StringComparison]::Ordinal)) {
            return [pscustomobject][ordered]@{
                Status = 'PreparingHostInputs'
                Message = 'The guest is mounting ephemeral read-only host inputs; the application has not started.'
                ApplicationConfirmed = $false
                ApplicationProcessId = $null
                ApplicationStartedUtc = $null
                GuestActionIndex = $null
                GuestActionType = $null
            }
        }
        return [pscustomobject][ordered]@{
            Status = 'LaunchingApplication'
            Message = 'Guest job submitted; waiting for Start-Process confirmation.'
            ApplicationConfirmed = $false
            ApplicationProcessId = $null
            ApplicationStartedUtc = $null
            GuestActionIndex = $null
            GuestActionType = $null
        }
    }

    if ($agentState -and
        [string]::Equals([string]$agentState.JobId, $RequestId, [StringComparison]::Ordinal) -and
        -not [string]::IsNullOrWhiteSpace([string]$agentState.ActionType)) {
        return [pscustomobject][ordered]@{
            Status = 'GuestAction'
            Message = "Guest action $([int]$agentState.ActionIndex): $([string]$agentState.ActionType)."
            ApplicationConfirmed = $true
            ApplicationProcessId = if ($leaseConfirmed) { [int]$lease.ProcessId } else { $null }
            ApplicationStartedUtc = if ($leaseConfirmed) { [string]$lease.StartedUtc } else { $null }
            GuestActionIndex = [int]$agentState.ActionIndex
            GuestActionType = [string]$agentState.ActionType
        }
    }
    if (-not [bool]$CompletionState.AgentAlive) {
        return [pscustomobject][ordered]@{
            Status = 'GuestAgentRecovery'
            Message = 'Application launch was confirmed; waiting for guest-agent supervisor recovery.'
            ApplicationConfirmed = $true
            ApplicationProcessId = if ($leaseConfirmed) { [int]$lease.ProcessId } else { $null }
            ApplicationStartedUtc = if ($leaseConfirmed) { [string]$lease.StartedUtc } else { $null }
            GuestActionIndex = $null
            GuestActionType = $null
        }
    }

    if ($leaseConfirmed) {
        return [pscustomobject][ordered]@{
            Status = 'ApplicationRunning'
            Message = 'The guest application lease remains present; waiting for guest action or completion.'
            ApplicationConfirmed = $true
            ApplicationProcessId = [int]$lease.ProcessId
            ApplicationStartedUtc = [string]$lease.StartedUtc
            GuestActionIndex = $null
            GuestActionType = $null
        }
    }
    [pscustomobject][ordered]@{
        Status = 'AwaitingGuestCompletion'
        Message = 'Application launch was confirmed; waiting for guest terminal evidence.'
        ApplicationConfirmed = $true
        ApplicationProcessId = $null
        ApplicationStartedUtc = $null
        GuestActionIndex = $null
        GuestActionType = $null
    }
}

function New-GuestEvidenceSnapshot {
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $GuestOutbox,
        [Parameter(Mandatory = $true)] [string] $RequestId
    )

    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($SourceRoot, $JobId, $StageBaseRoot = 'C:\CodexGuest\EvidenceStage')

        if ($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
            throw "Invalid evidence snapshot request id: $JobId"
        }
        $sourceRootFull = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $sourceRootFull -PathType Container)) {
            throw "Guest evidence source is missing: $sourceRootFull"
        }

        $stageRoot = Join-Path $StageBaseRoot $JobId
        if (Test-Path -LiteralPath $stageRoot -PathType Container) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

        $copiedFiles = New-Object Collections.Generic.List[object]
        $skippedFiles = New-Object Collections.Generic.List[object]
        $enumerationErrors = @()
        $files = @(Get-ChildItem -LiteralPath $sourceRootFull -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable enumerationErrors |
            Sort-Object FullName)
        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($sourceRootFull.Length).TrimStart('\')
            $destinationPath = Join-Path $stageRoot $relativePath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
            $copied = $false
            $lastError = $null
            $attemptUsed = 0
            for ($attempt = 1; $attempt -le 4; $attempt++) {
                $attemptUsed = $attempt
                $sourceStream = $null
                $destinationStream = $null
                try {
                    $shareMode = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
                    $sourceStream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $shareMode)
                    $destinationStream = [IO.File]::Open($destinationPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $sourceStream.CopyTo($destinationStream)
                    $destinationStream.Flush()
                    $copied = $true
                    break
                }
                catch {
                    $lastError = $_.Exception.Message
                }
                finally {
                    if ($destinationStream) { $destinationStream.Dispose() }
                    if ($sourceStream) { $sourceStream.Dispose() }
                }
                Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
                if ($attempt -lt 4) {
                    Start-Sleep -Milliseconds ([int](100 * [Math]::Pow(2, $attempt - 1)))
                }
            }

            if ($copied) {
                $copiedFiles.Add([ordered]@{
                    RelativePath = $relativePath
                    Length = [long](Get-Item -LiteralPath $destinationPath).Length
                    Attempts = $attemptUsed
                })
            }
            else {
                $skippedFiles.Add([ordered]@{
                    RelativePath = $relativePath
                    Length = [long]$file.Length
                    Attempts = $attemptUsed
                    Error = $lastError
                })
            }
        }

        $manifest = [ordered]@{
            FormatVersion = 1
            RequestId = $JobId
            SourceRoot = $sourceRootFull
            StageRoot = $stageRoot
            CreatedUtc = [DateTime]::UtcNow.ToString('o')
            EnumeratedFileCount = $files.Count
            CopiedFiles = $copiedFiles.ToArray()
            SkippedFiles = $skippedFiles.ToArray()
            EnumerationErrors = @($enumerationErrors | ForEach-Object { $_.Exception.Message })
        }
        $manifestPath = Join-Path $stageRoot 'evidence-copy-manifest.json'
        $temporaryManifestPath = $manifestPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryManifestPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryManifestPath -Destination $manifestPath -Force
        [pscustomobject]$manifest
    } -ArgumentList $GuestOutbox, $RequestId
}

function Remove-GuestEvidenceSnapshot {
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $StageRoot
    )

    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($Path)
        $allowedRoot = [IO.Path]::GetFullPath('C:\CodexGuest\EvidenceStage').TrimEnd('\') + '\'
        $resolved = [IO.Path]::GetFullPath($Path)
        if (-not $resolved.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove an evidence stage outside $allowedRoot"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    } -ArgumentList $StageRoot
}

function Invoke-GuestRequest {
    param(
        [Parameter(Mandatory = $true)] $Request,
        [Parameter(Mandatory = $true)] [string] $ResultRoot,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [DateTime] $ClaimedUtc,
        [string] $RequestStateRoot
    )

    if ([string]::IsNullOrWhiteSpace($RequestStateRoot)) { $RequestStateRoot = $ResultRoot }
    $requestId = [string]$Request.RequestId
    $vmName = [string]$Config.VmName
    $baselineName = [string]$Config.BaselineName
    $credential = Get-GuestCredential
    $lockEvidenceBefore = $null
    $lockEvidenceAfter = $null
    $guestState = $null
    $guestResult = $null
    $vmStartUtc = $null
    $session = $null
    $success = $false
    $errorMessage = $null
    $cancelled = $false
    $executionTimedOut = $false
    $payloadTransferAttempts = 0
    $payloadManifest = $null
    $payloadCache = $null
    $payloadChild = $null
    $payloadChildDeleted = $false
    $payloadLeaseCreated = $false
    $hostInputDefinitions = @()
    $hostInputVhdxRuntimes = New-Object Collections.Generic.List[object]
    $hostInputShareDefinitions = @()
    $hostInputShareRuntime = $null
    $hostInputShareNetwork = $null
    $hostInputGuestRoots = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $hostInputGuestJobMappings = @()
    $hostInputCleanup = [pscustomobject][ordered]@{ Attempted = $false; Success = $true; Errors = @(); StateDeleted = $true }
    $hostInputSetupWatch = New-Object Diagnostics.Stopwatch
    $requestNetworkDefinition = $null
    $requestNetworkRuntime = $null
    $requestNetworkAttachment = $null
    $requestNetworkConnection = $null
    $requestNetworkResidueCleanup = $null
    $requestNetworkGuestEvidence = $null
    $requestNetworkPrelaunchHostEvidence = $null
    $requestNetworkLastHostEvidence = $null
    $requestNetworkHostPolicyCheckCount = 0
    $requestNetworkCleanup = [pscustomobject][ordered]@{
        Attempted = $false
        Success = $false
        Errors = @('Request-network cleanup was not attempted.')
        Disconnected = $false
        AdapterRemoved = $false
        SwitchRemoved = $false
        StateDeleted = $false
    }
    $requestNetworkCleanupPerformed = $false
    $poolMode = [bool]$Config.PoolEnabled
    $workerId = if ($poolMode) { [Nullable[int]]([int]$Config.PoolWorkerId) } else { $null }
    $guestSessionReconnects = 0
    $jobSubmissionAttempts = 0
    $jobSubmittedUtc = $null
    $failureStage = 'Initializing'
    $errorType = $null
    $errorFullyQualifiedId = $null
    $errorScriptStackTrace = $null
    $errorPositionMessage = $null
    $failureKind = $null
    $cleanupFailureObserved = $false
    # Evidence is untrusted until each stage has completed and been validated.
    # Keep an explicit pessimistic manifest so a cleanup/status failure cannot
    # accidentally serialize missing evidence as an empty successful snapshot.
    $evidenceManifest = [pscustomobject][ordered]@{
        StageRoot = $null
        EnumeratedFileCount = $null
        CopiedFiles = @()
        SkippedFiles = @()
        EnumerationErrors = @()
    }
    $evidenceSnapshotSucceeded = $false
    $evidenceTransferSucceeded = $false
    $evidenceValidationSucceeded = $false
    $guestEvidenceStage = $null
    $evidenceSnapshotAttempts = 0
    $evidenceTransferAttempts = 0
    $evidenceWarnings = New-Object Collections.Generic.List[string]
    $executionTimeoutSeconds = Get-BoundedTimeout -Value $Request.ExecutionTimeoutSeconds -Default 900 -Minimum 10 -Maximum 7200
    $executionDeadlineUtc = $ClaimedUtc.AddSeconds($executionTimeoutSeconds)
    $createdUtc = [DateTime]::Parse([string]$Request.CreatedUtc).ToUniversalTime()

    [CodexHostSession]::PreventSleep()
    try {
        $null = Recover-OrphanedHostInputResources -BrokerRoot $BrokerRoot -ExcludeRequestId $requestId
        # Recovery is owner/identity-aware. Do not exclude the current
        # RequestId: a crashed attempt can leave a stale lease with the same
        # RequestId, and retries must reclaim it before reserving a new one.
        $null = Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot
        $failureStage = 'ValidatingRequest'
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        $requestNetworkDefinition = Resolve-RequestNetworkProfile -Request $Request -Config $Config
        if ([string]$requestNetworkDefinition.EffectiveProfile -eq 'None') {
            $requestNetworkCleanup = [pscustomobject][ordered]@{
                Attempted = $false
                Success = $true
                Errors = @()
                Disconnected = $true
                AdapterRemoved = $true
                SwitchRemoved = $false
                StateDeleted = $true
            }
        }
        if ($Request.Payload) {
            $payloadManifest = Read-AndValidatePayloadManifest -Request $Request
            if ([string]$payloadManifest.CacheScope -ne 'Application') {
                throw 'The canonical ArtifactPath must use the application payload-cache scope.'
            }
            New-PayloadGenerationLease -PayloadId ([string]$payloadManifest.PayloadId) -ContentKey ([string]$payloadManifest.ContentKey) -RequestId $requestId -VmName $vmName | Out-Null
            $payloadLeaseCreated = $true
        }
        elseif (-not [string]::Equals([string]$Request.Job.executable, 'C:\CodexGuest\InputProbe.exe', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Every external application-under-test must include canonical ArtifactPath payload metadata.'
        }
        $hostInputNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $hostInputDefinitions = @($Request.HostInputs)
        if ($hostInputDefinitions.Count -gt 8) { throw 'A request may expose at most eight read-only host inputs.' }
        foreach ($input in $hostInputDefinitions) {
            $inputName = [string]$input.Name
            if ($inputName -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$' -or -not $hostInputNames.Add($inputName)) {
                throw "Invalid or duplicate read-only host input name: $inputName"
            }
            if (-not [string]::Equals([string]$input.TokenName, ('HOSTINPUT:' + $inputName), [StringComparison]::Ordinal)) {
                throw "Read-only host input '$inputName' has an invalid token identity."
            }
            $hostPath = [string]$input.HostPath
            if ([string]::IsNullOrWhiteSpace($hostPath) -or -not [IO.Path]::IsPathRooted($hostPath) -or $hostPath.StartsWith('\\', [StringComparison]::Ordinal)) {
                throw "Read-only host input '$inputName' must use an absolute local host path."
            }
            $hostItem = Get-Item -LiteralPath $hostPath -Force -ErrorAction Stop
            $canonicalHostPath = [IO.Path]::GetFullPath($hostItem.FullName)
            if ($hostItem.PSIsContainer) { $canonicalHostPath = $canonicalHostPath.TrimEnd('\') }
            if (-not [string]::Equals($canonicalHostPath, [IO.Path]::GetFullPath($hostPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
                [bool]$hostItem.PSIsContainer -ne [bool]$input.IsDirectory) {
                throw "Read-only host input '$inputName' changed after submission."
            }
            $transport = [string]$input.SelectedTransport
            if ($transport -notin @('Share', 'Vhdx')) { throw "Read-only host input '$inputName' has an unsupported transport: $transport" }
            if ($transport -eq 'Share') {
                $hostInputShareDefinitions += $input
            }
            else {
                if (-not $input.Payload) { throw "VHDX read-only host input '$inputName' has no payload manifest metadata." }
                $inputManifest = Read-AndValidatePayloadManifest -Request ([pscustomobject]@{ Payload = $input.Payload })
                if ([string]$inputManifest.CacheScope -ne 'ReadOnlyHostInput') {
                    throw "VHDX read-only host input '$inputName' must use the isolated read-only cache scope."
                }
                if (-not [string]::Equals([string]$inputManifest.ArtifactPath, $canonicalHostPath, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "VHDX read-only host input '$inputName' manifest does not identify its declared host path."
                }
                $leaseId = "$requestId-hostinput-$inputName"
                New-PayloadGenerationLease -PayloadId ([string]$inputManifest.PayloadId) -ContentKey ([string]$inputManifest.ContentKey) -RequestId $leaseId -VmName $vmName | Out-Null
                $hostInputVhdxRuntimes.Add([pscustomobject][ordered]@{
                    Definition = $input
                    Manifest = $inputManifest
                    LeaseId = $leaseId
                    LeaseCreated = $true
                    Cache = $null
                    Child = $null
                    ChildDeleted = $false
                    GuestRoot = $null
                })
            }
        }
        $failureStage = 'CheckingHostLock'
        if ($Request.RequireHostLocked) {
            $lockEvidenceBefore = Wait-ForHostLock -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc -ResultRoot $RequestStateRoot -ClaimedUtc $ClaimedUtc
        }
        else {
            $lockEvidenceBefore = Get-HostLockEvidence
        }

        if ($payloadManifest) {
            $failureStage = 'SynchronizingPayloadCache'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            Write-BrokerState -Status 'StagingGuestPayload' -RequestId $requestId -Message 'Synchronizing additions, changes, and deletions into an immutable VHDX generation.'
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'StagingGuestPayload' -Message 'Synchronizing the canonical ArtifactPath into its incremental VHDX cache.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            $payloadCache = Get-OrUpdatePayloadCache -Manifest $payloadManifest -Config $Config -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            Update-PayloadGenerationLease -RequestId $requestId -ParentVhdx ([string]$payloadCache.ParentVhdx) -Stage 'ParentPinned'
        }
        if ($hostInputVhdxRuntimes.Count -gt 0) {
            $failureStage = 'SynchronizingHostInputCache'
            $hostInputIndex = 0
            foreach ($inputRuntime in $hostInputVhdxRuntimes) {
                $hostInputIndex++
                Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                $inputName = [string]$inputRuntime.Definition.Name
                Write-BrokerState -Status 'PreparingHostInputs' -RequestId $requestId -Message "Synchronizing read-only host input '$inputName' into its incremental VHDX cache."
                Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'PreparingHostInputs' -Message "Synchronizing cached input $hostInputIndex of $($hostInputVhdxRuntimes.Count): $inputName." -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
                $inputRuntime.Cache = Get-OrUpdatePayloadCache -Manifest $inputRuntime.Manifest -Config $Config -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                Update-PayloadGenerationLease -RequestId $inputRuntime.LeaseId -ParentVhdx ([string]$inputRuntime.Cache.ParentVhdx) -Stage 'ParentPinned'
            }
        }

        $failureStage = 'PreparingVm'
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        Write-BrokerState -Status 'PreparingVm' -RequestId $requestId -Message 'Preparing the isolated guest baseline.'
        Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'PreparingVm' -Message 'Preparing the isolated guest baseline and attaching the disposable payload disk.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
        $connectedSwitches = @(Get-VMNetworkAdapter -VMName $vmName | Where-Object { -not [string]::IsNullOrWhiteSpace($_.SwitchName) })
        if ($connectedSwitches.Count -gt 0) {
            throw 'The broker refuses to run because the test VM has a connected network adapter.'
        }

        $vm = Get-VM -Name $vmName -ErrorAction Stop
        if ($poolMode) {
            if ($vm.State -ne 'Running') {
                throw "Pool worker $vmName was not running when its lease began."
            }
        }
        elseif ($Request.ResetToBaseline) {
            if ($vm.State -ne 'Off') {
                Stop-TestVm -VmName $vmName -Immediate
            }
            $baseline = Get-VMSnapshot -VMName $vmName -Name $baselineName -ErrorAction Stop
            Restore-VMSnapshot -VMSnapshot $baseline -Confirm:$false
        }
        elseif ($vm.State -ne 'Off') {
            throw 'The VM must be off when ResetToBaseline is false.'
        }

        if ($payloadCache) {
            $failureStage = 'AttachingPayloadChild'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $payloadChild = New-AndAttachPayloadChild -VmName $vmName -RequestId $requestId -ParentVhdx ([string]$payloadCache.ParentVhdx)
            Update-PayloadGenerationLease -RequestId $requestId -ParentVhdx ([string]$payloadCache.ParentVhdx) -ChildVhdx ([string]$payloadChild.Path) -Stage 'Attached'
        }
        foreach ($inputRuntime in $hostInputVhdxRuntimes) {
            $failureStage = 'AttachingHostInputChild'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $inputRuntime.Child = New-AndAttachPayloadChild -VmName $vmName -RequestId $inputRuntime.LeaseId -ParentVhdx ([string]$inputRuntime.Cache.ParentVhdx)
            Update-PayloadGenerationLease -RequestId $inputRuntime.LeaseId -ParentVhdx ([string]$inputRuntime.Cache.ParentVhdx) -ChildVhdx ([string]$inputRuntime.Child.Path) -Stage 'Attached'
        }

        if ([string]$requestNetworkDefinition.EffectiveProfile -ne 'None') {
            $failureStage = 'PreparingNetwork'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            Write-BrokerState -Status 'PreparingNetwork' -RequestId $requestId -Message "Preparing the approved $($requestNetworkDefinition.EffectiveProfile) request network."
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'PreparingNetwork' -Message "Reserving and securing the approved $($requestNetworkDefinition.EffectiveProfile) adapter before it is connected." -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            $requestNetworkWorkerId = if ($poolMode) { [int]$workerId } else { 1 }
            $requestNetworkRuntime = New-RequestNetworkRuntime -BrokerRoot $BrokerRoot -Definition $requestNetworkDefinition -RequestId $requestId -VmName $vmName -WorkerId $requestNetworkWorkerId
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $requestNetworkAttachment = Prepare-RequestVmNetwork -Runtime $requestNetworkRuntime -VmName $vmName -BrokerRoot $BrokerRoot
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        }

        if ($hostInputShareDefinitions.Count -gt 0) {
            $failureStage = 'CreatingHostInputShares'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            Write-BrokerState -Status 'PreparingHostInputs' -RequestId $requestId -Message 'Creating ephemeral read-only host shares and isolated VM connectivity.'
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'PreparingHostInputs' -Message "Creating $($hostInputShareDefinitions.Count) ephemeral read-only host input share(s)." -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            $hostInputSetupWatch.Start()
            $hostInputWorkerId = if ($poolMode) { [int]$workerId } else { 1 }
            $hostInputShareRuntime = New-HostInputShareRuntime -BrokerRoot $BrokerRoot -Config $Config -RequestId $requestId -VmName $vmName -WorkerId $hostInputWorkerId -Inputs $hostInputShareDefinitions
            $hostInputShareNetwork = Connect-HostInputVmNetwork -Runtime $hostInputShareRuntime -VmName $vmName
        }

        $failureStage = 'StartingVm'
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        $vmStartUtc = [DateTime]::UtcNow
        if ($poolMode) {
            Write-BrokerState -Status 'PreparingVm' -RequestId $requestId -Message 'Using the already-started clean warm worker.'
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'PreparingVm' -Message 'Using the already-started clean warm worker.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
        }
        else {
            Write-BrokerState -Status 'StartingVm' -RequestId $requestId -Message 'Starting the Windows 11 guest.'
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'StartingVm' -Message 'Starting the Windows 11 guest.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            Start-VM -Name $vmName | Out-Null
        }
        $failureStage = 'WaitingForGuestAgent'
        Write-BrokerState -Status 'WaitingForGuestAgent' -RequestId $requestId -Message 'Waiting for the interactive guest agent.'
        Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'WaitingForGuestAgent' -Message 'Waiting for the interactive guest agent and Hyper-V Direct readiness.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
        $guestState = Wait-GuestSession -VmName $vmName -Credential $credential -NotBeforeUtc $vmStartUtc -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc

        $session = Open-GuestSessionReliable -VmName $vmName -Credential $credential -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        $failureStage = 'NormalizingGuestNetwork'
        $activityCheck = { Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc }
        $requestNetworkResidueCleanup = Reset-GuestRequestNetworkResidue -Session $session -Policy $requestNetworkDefinition.Policy -ActivityCheck $activityCheck
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        if ($requestNetworkRuntime) {
            $failureStage = 'VerifyingNetwork'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            Write-BrokerState -Status 'VerifyingNetwork' -RequestId $requestId -Message "Connecting, configuring, and attesting the approved $($requestNetworkRuntime.Profile) guest adapter."
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'VerifyingNetwork' -Message 'Revalidating host policy, connecting the secured adapter last, and attesting exact guest address, route, DNS, and IPv6 state.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $requestNetworkConnection = Connect-RequestVmNetwork -Runtime $requestNetworkRuntime -VmName $vmName -BrokerRoot $BrokerRoot
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $requestNetworkLastHostEvidence = $requestNetworkConnection.HostPolicyCheck
            $requestNetworkHostPolicyCheckCount++
            $requestNetworkGuestEvidence = Initialize-GuestRequestNetwork -Session $session -Runtime $requestNetworkRuntime -ActivityCheck $activityCheck
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $requestNetworkPrelaunchHostEvidence = Assert-RequestNetworkHostPolicyCurrent -Runtime $requestNetworkRuntime -BrokerRoot $BrokerRoot
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $requestNetworkLastHostEvidence = $requestNetworkPrelaunchHostEvidence
            $requestNetworkHostPolicyCheckCount++
        }
        if ($hostInputShareRuntime) {
            $failureStage = 'MountingHostInputShares'
            Write-BrokerState -Status 'PreparingHostInputs' -RequestId $requestId -Message 'Configuring isolated host-only networking and guest read-only mappings.'
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'PreparingHostInputs' -Message 'Configuring the guest host-only adapter and read-only input drive mappings.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            $null = Initialize-GuestHostInputNetwork -Session $session -Runtime $hostInputShareRuntime -MacAddress ([string]$hostInputShareNetwork.MacAddress)
            $driveLetters = @(Get-GuestHostInputDriveLetters -Session $session -Count $hostInputShareRuntime.Inputs.Count)
            for ($shareIndex = 0; $shareIndex -lt $hostInputShareRuntime.Inputs.Count; $shareIndex++) {
                $share = $hostInputShareRuntime.Inputs[$shareIndex]
                $driveLetter = [string]$driveLetters[$shareIndex]
                $guestRoot = "$driveLetter`:"
                if (-not [string]::IsNullOrWhiteSpace([string]$share.GuestSubPath)) {
                    $guestRoot = $guestRoot + '\' + [string]$share.GuestSubPath
                }
                $hostInputGuestRoots[[string]$share.Name] = $guestRoot
                $hostInputGuestJobMappings += [ordered]@{
                    Name = [string]$share.Name
                    DriveLetter = $driveLetter
                    RemotePath = '\\' + [string]$hostInputShareRuntime.HostAddress + '\' + [string]$share.ShareName
                    Username = [string]$hostInputShareRuntime.Username
                    Password = [string]$hostInputShareRuntime.Password
                    GuestSubPath = [string]$share.GuestSubPath
                }
            }
            $hostInputSetupWatch.Stop()
            Write-HostInputLeaseState -Runtime $hostInputShareRuntime -Status 'GuestMappingsPrepared'
        }
        $guestPayloadRoot = $null
        if ($payloadManifest) {
            $failureStage = 'ResolvingGuestPayload'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            Write-BrokerState -Status 'StagingGuestPayload' -RequestId $requestId -Message 'Resolving the attached disposable payload disk in the guest.'
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'StagingGuestPayload' -Message 'Resolving the attached immutable payload generation in the guest.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            $guestPayloadRoot = Resolve-GuestPayloadRoot -Session $session -PayloadId $payloadManifest.PayloadId -ContentKey $payloadManifest.ContentKey
        }
        foreach ($inputRuntime in $hostInputVhdxRuntimes) {
            $failureStage = 'ResolvingHostInputPayload'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $resolvedRoot = Resolve-GuestPayloadRoot -Session $session -PayloadId $inputRuntime.Manifest.PayloadId -ContentKey $inputRuntime.Manifest.ContentKey -ReadOnly
            if (-not [bool]$inputRuntime.Definition.IsDirectory) {
                $resolvedRoot = [IO.Path]::Combine($resolvedRoot, [string]$inputRuntime.Definition.LeafName)
            }
            $inputRuntime.GuestRoot = $resolvedRoot
            $hostInputGuestRoots[[string]$inputRuntime.Definition.Name] = $resolvedRoot
        }
        $failureStage = 'ValidatingGuestJob'
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        $job = $Request.Job
        if ([string]$job.id -ne $requestId) {
            throw 'Guest job id must exactly match RequestId.'
        }

        $guestOutbox = "C:\CodexGuest\Outbox\$requestId"

        $guestExecutable = [string]$job.executable
        $payloadToken = '{PAYLOAD}\'
        if ($guestExecutable.StartsWith($payloadToken, [StringComparison]::OrdinalIgnoreCase)) {
            if (-not $guestPayloadRoot) {
                throw 'The job refers to {PAYLOAD}, but the attached payload VHDX was not resolved.'
            }
            $relativeExecutable = $guestExecutable.Substring($payloadToken.Length)
            if ([string]::IsNullOrWhiteSpace($relativeExecutable) -or [IO.Path]::IsPathRooted($relativeExecutable)) {
                throw 'The payload executable path must be a non-empty relative path.'
            }
            $guestPayloadPrefix = [IO.Path]::GetFullPath($guestPayloadRoot).TrimEnd('\') + '\'
            # The guest-assigned drive letter does not necessarily exist on the
            # host. Use pure path arithmetic rather than the provider-aware
            # Join-Path cmdlet.
            $guestExecutable = [IO.Path]::GetFullPath([IO.Path]::Combine($guestPayloadRoot, $relativeExecutable))
            if (-not $guestExecutable.StartsWith($guestPayloadPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The payload executable path escapes its attached VHDX payload directory.'
            }
        }
        elseif (-not [string]::Equals($guestExecutable, 'C:\CodexGuest\InputProbe.exe', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Executable must be the built-in probe or reside in the request payload directory.'
        }
        $job.executable = $guestExecutable

        if ($hostInputGuestJobMappings.Count -gt 0) {
            $job | Add-Member -NotePropertyName hostInputs -NotePropertyValue $hostInputGuestJobMappings -Force
        }
        $hostInputTokenNames = @($hostInputDefinitions | ForEach-Object { [string]$_.TokenName })
        $job.arguments = Expand-GuestJobTokens -Value ([string]$job.arguments) -GuestPayloadRoot $guestPayloadRoot -GuestOutputRoot $guestOutbox -Context 'Arguments' -AllowedTokens (@('PAYLOAD', 'OUTDIR') + $hostInputTokenNames) -GuestHostInputRoots $hostInputGuestRoots
        for ($actionIndex = 0; $actionIndex -lt @($job.actions).Count; $actionIndex++) {
            $action = @($job.actions)[$actionIndex]
            $actionType = [string]$action.type
            foreach ($property in @($action.PSObject.Properties)) {
                if ($property.Value -isnot [string]) {
                    continue
                }
                $tokensAllowedHere = if ($property.Name -eq 'type' -or ($actionType -eq 'screenshot' -and $property.Name -eq 'name')) {
                    @()
                }
                elseif ($actionType -eq 'wait_result_file' -and $property.Name -eq 'path') {
                    @('OUTDIR')
                }
                else {
                    @('PAYLOAD', 'OUTDIR') + $hostInputTokenNames
                }
                $property.Value = Expand-GuestJobTokens -Value ([string]$property.Value) -GuestPayloadRoot $guestPayloadRoot -GuestOutputRoot $guestOutbox -Context "Action $($actionIndex + 1) '$($property.Name)'" -AllowedTokens $tokensAllowedHere -GuestHostInputRoots $hostInputGuestRoots
            }
        }
        if ($job.PSObject.Properties.Name -contains 'assertResultFile' -and -not [string]::IsNullOrWhiteSpace([string]$job.assertResultFile)) {
            $job.assertResultFile = Expand-GuestJobTokens -Value ([string]$job.assertResultFile) -GuestPayloadRoot $guestPayloadRoot -GuestOutputRoot $guestOutbox -Context 'AssertResultFile' -AllowedTokens @('OUTDIR')
        }
        $hasAssertionPointer = $job.PSObject.Properties.Name -contains 'assertResultJsonPointer'
        $hasAssertionExpected = $job.PSObject.Properties.Name -contains 'assertResultEqualsJson'
        if ($hasAssertionPointer -xor $hasAssertionExpected) {
            throw 'The guest job JSON assertion is incomplete.'
        }
        if ($hasAssertionPointer) {
            $pointer = [string]$job.assertResultJsonPointer
            if ($pointer.Length -gt 0 -and -not $pointer.StartsWith('/', [StringComparison]::Ordinal)) {
                throw 'assertResultJsonPointer must be empty or start with a slash.'
            }
            if ([regex]::IsMatch($pointer, '~(?![01])')) {
                throw 'assertResultJsonPointer contains an invalid escape.'
            }
            try { $null = ('{"value":' + [string]$job.assertResultEqualsJson + '}') | ConvertFrom-Json -ErrorAction Stop }
            catch { throw "assertResultEqualsJson is invalid JSON: $($_.Exception.Message)" }
        }

        if ($requestNetworkRuntime) {
            $failureStage = 'VerifyingNetwork'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $requestNetworkLastHostEvidence = Assert-RequestNetworkHostPolicyCurrent -Runtime $requestNetworkRuntime -BrokerRoot $BrokerRoot
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $requestNetworkHostPolicyCheckCount++
        }
        $failureStage = 'SubmittingGuestJob'
        $guestJobPath = Join-Path $ResultRoot ($requestId + '.json')
        Write-JsonAtomic -Path $guestJobPath -Value $job
        Write-BrokerState -Status 'LaunchingApplication' -RequestId $requestId -Message 'Submitting the guest job and waiting for Start-Process confirmation.'
        Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'LaunchingApplication' -Message 'Submitting the guest job; the application has not yet been confirmed started.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
        # PowerShell Direct exposes the destination filename before Copy-Item
        # has necessarily finished writing it. Copy into an unwatched directory
        # first, then rename on the guest so the inbox only sees complete JSON.
        $guestTransferRoot = 'C:\CodexGuest\Transfer'
        $guestTransferFile = Join-Path $guestTransferRoot ($requestId + '.json')
        $guestInboxFile = Join-Path 'C:\CodexGuest\Inbox' ($requestId + '.json')
        $guestProcessingFile = Join-Path 'C:\CodexGuest\Processing' ($requestId + '.json')
        $guestCompletedFile = Join-Path 'C:\CodexGuest\Completed' ($requestId + '.json')
        $jobSubmitted = $false
        for ($submissionAttempt = 1; $submissionAttempt -le 3; $submissionAttempt++) {
            $jobSubmissionAttempts = $submissionAttempt
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            try {
                if (-not $session -or [string]$session.State -ne 'Opened') {
                    if ($session) {
                        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    }
                    $session = Open-GuestSessionReliable -VmName $vmName -Credential $credential -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                    $guestSessionReconnects++
                }

                # A connection can drop after the atomic guest rename but
                # before the host receives confirmation. Inspect every guest
                # lifecycle location before deciding to resubmit, preventing a
                # duplicate application launch.
                $presence = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                    param($InboxFile, $ProcessingFile, $CompletedFile, $Outbox)
                    [ordered]@{
                        Inbox = Test-Path -LiteralPath $InboxFile -PathType Leaf
                        Processing = Test-Path -LiteralPath $ProcessingFile -PathType Leaf
                        Completed = Test-Path -LiteralPath $CompletedFile -PathType Leaf
                        Result = Test-Path -LiteralPath (Join-Path $Outbox 'result.json') -PathType Leaf
                        AgentError = Test-Path -LiteralPath (Join-Path $Outbox 'agent-error.json') -PathType Leaf
                    }
                } -ArgumentList $guestInboxFile, $guestProcessingFile, $guestCompletedFile, $guestOutbox

                if (-not ($presence.Inbox -or $presence.Processing -or $presence.Completed -or $presence.Result -or $presence.AgentError)) {
                    Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                        param($TransferRoot, $TransferFile)
                        New-Item -ItemType Directory -Force -Path $TransferRoot | Out-Null
                        Remove-Item -LiteralPath $TransferFile -Force -ErrorAction SilentlyContinue
                    } -ArgumentList $guestTransferRoot, $guestTransferFile
                    Copy-Item -LiteralPath $guestJobPath -Destination $guestTransferRoot -ToSession $session -Force -ErrorAction Stop
                    Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                        param($TransferFile, $InboxFile)
                        Move-Item -LiteralPath $TransferFile -Destination $InboxFile -Force
                    } -ArgumentList $guestTransferFile, $guestInboxFile
                }

                $jobSubmitted = $true
                $jobSubmittedUtc = [DateTime]::UtcNow
                break
            }
            catch {
                $submissionError = $_
                if ($session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    $session = $null
                }
                Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                if ($submissionAttempt -ge 3) {
                    throw $submissionError
                }
                Write-BrokerState -Status 'RetryingGuestConnection' -RequestId $requestId -Message 'Guest job submission lost its Hyper-V Direct session; reconciling before retry.'
                Start-Sleep -Seconds 2
            }
        }
        if (-not $jobSubmitted) {
            throw 'The guest job could not be submitted.'
        }
        Write-BrokerState -Status 'LaunchingApplication' -RequestId $requestId -Message 'Guest job submitted; waiting for Start-Process confirmation.'
        Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'LaunchingApplication' -Message 'Guest job submitted; waiting for Start-Process confirmation.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId

        $failureStage = 'WaitingForGuestJob'
        $completionState = $null
        $applicationRunningPublished = $false
        $agentMissingSinceUtc = $null
        $inboxFirstSeenUtc = $null
        $lifecycleMissingSinceUtc = $null
        $nextNetworkHostPolicyCheckUtc = [DateTime]::UtcNow
        while ($true) {
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            if ($requestNetworkRuntime -and [DateTime]::UtcNow -ge $nextNetworkHostPolicyCheckUtc) {
                $failureStage = 'VerifyingNetwork'
                Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                $requestNetworkLastHostEvidence = Assert-RequestNetworkHostPolicyCurrent -Runtime $requestNetworkRuntime -BrokerRoot $BrokerRoot
                Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                $requestNetworkHostPolicyCheckCount++
                $nextNetworkHostPolicyCheckUtc = [DateTime]::UtcNow.AddSeconds(2)
                $failureStage = 'WaitingForGuestJob'
            }
            try {
                if (-not $session -or [string]$session.State -ne 'Opened') {
                    if ($session) {
                        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    }
                    $session = Open-GuestSessionReliable -VmName $vmName -Credential $credential -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                    $guestSessionReconnects++
                }
                $completionState = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                    param($InboxFile, $ProcessingFile, $CompletedFile, $Outbox)
                    $agentState = $null
                    try {
                        $agentStatePath = 'C:\CodexGuest\agent-state.json'
                        if (Test-Path -LiteralPath $agentStatePath -PathType Leaf) {
                            $agentState = Get-Content -Raw -LiteralPath $agentStatePath | ConvertFrom-Json
                        }
                    }
                    catch {
                    }
                    $agentAlive = $false
                    $agentHeartbeatAgeSeconds = $null
                    if ($agentState -and $agentState.ProcessId) {
                        $agentAlive = $null -ne (Get-Process -Id ([int]$agentState.ProcessId) -ErrorAction SilentlyContinue)
                        try {
                            $agentHeartbeatUtc = [DateTime]::Parse([string]$agentState.HeartbeatUtc).ToUniversalTime()
                            $agentHeartbeatAgeSeconds = [Math]::Max(0, ([DateTime]::UtcNow - $agentHeartbeatUtc).TotalSeconds)
                            if ($agentHeartbeatAgeSeconds -le 5) {
                                $agentAlive = $true
                            }
                        }
                        catch {
                        }
                    }
                    $applicationLease = $null
                    try {
                        $leasePath = Join-Path $Outbox 'lease.json'
                        if (Test-Path -LiteralPath $leasePath -PathType Leaf) {
                            $applicationLease = Get-Content -Raw -LiteralPath $leasePath | ConvertFrom-Json
                        }
                    }
                    catch {
                        $applicationLease = $null
                    }
                    [ordered]@{
                        Result = Test-Path -LiteralPath (Join-Path $Outbox 'result.json') -PathType Leaf
                        AgentError = Test-Path -LiteralPath (Join-Path $Outbox 'agent-error.json') -PathType Leaf
                        Inbox = Test-Path -LiteralPath $InboxFile -PathType Leaf
                        Processing = Test-Path -LiteralPath $ProcessingFile -PathType Leaf
                        Completed = Test-Path -LiteralPath $CompletedFile -PathType Leaf
                        AgentAlive = $agentAlive
                        AgentHeartbeatAgeSeconds = $agentHeartbeatAgeSeconds
                        AgentState = $agentState
                        ApplicationLease = $applicationLease
                    }
                } -ArgumentList $guestInboxFile, $guestProcessingFile, $guestCompletedFile, $guestOutbox
            }
            catch {
                if ($session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    $session = $null
                }
                Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                Write-BrokerState -Status 'RetryingGuestConnection' -RequestId $requestId -Message 'Lost the Hyper-V Direct result channel; reconnecting without resubmitting the job.'
                Start-Sleep -Seconds 2
                continue
            }

            $guestLifecycle = Get-GuestLifecycleProgress -CompletionState $completionState -RequestId $requestId -ApplicationRunningPublished $applicationRunningPublished
            $lifecycleStateParameters = @{
                ResultRoot = $RequestStateRoot
                RequestId = $requestId
                Status = [string]$guestLifecycle.Status
                Message = [string]$guestLifecycle.Message
                CreatedUtc = $createdUtc
                ClaimedUtc = $ClaimedUtc
                ExecutionDeadlineUtc = $executionDeadlineUtc
                WorkerId = $workerId
            }
            if ($null -ne $guestLifecycle.ApplicationProcessId) {
                $lifecycleStateParameters['ApplicationProcessId'] = [int]$guestLifecycle.ApplicationProcessId
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$guestLifecycle.ApplicationStartedUtc)) {
                $lifecycleStateParameters['ApplicationStartedUtc'] = [string]$guestLifecycle.ApplicationStartedUtc
            }
            if ([string]$guestLifecycle.Status -eq 'GuestAction') {
                $lifecycleStateParameters['GuestActionIndex'] = [int]$guestLifecycle.GuestActionIndex
                $lifecycleStateParameters['GuestActionType'] = [string]$guestLifecycle.GuestActionType
            }
            Write-BrokerState -Status ([string]$guestLifecycle.Status) -RequestId $requestId -Message ([string]$guestLifecycle.Message)
            Write-RequestState @lifecycleStateParameters

            $firstApplicationConfirmation = -not $applicationRunningPublished -and [bool]$guestLifecycle.ApplicationConfirmed
            if ($firstApplicationConfirmation) {
                $applicationRunningPublished = $true
                # Leave the confirmation visible for at least one runner poll
                # before publishing guest-action progress.
                Start-Sleep -Milliseconds 750
                continue
            }

            if ($completionState.Result -or $completionState.AgentError) {
                break
            }
            if ($completionState.Completed) {
                throw 'The guest marked the job completed but produced neither result.json nor agent-error.json.'
            }
            if (-not $completionState.AgentAlive) {
                if (-not $agentMissingSinceUtc) {
                    $agentMissingSinceUtc = [DateTime]::UtcNow
                }
                elseif (([DateTime]::UtcNow - $agentMissingSinceUtc).TotalSeconds -ge 30) {
                    throw 'The interactive guest agent stopped and its supervisor did not recover it within 30 seconds.'
                }
            }
            else {
                $agentMissingSinceUtc = $null
            }
            if ($completionState.Inbox) {
                if (-not $inboxFirstSeenUtc) {
                    $inboxFirstSeenUtc = [DateTime]::UtcNow
                }
                elseif (([DateTime]::UtcNow - $inboxFirstSeenUtc).TotalSeconds -ge 30) {
                    throw 'The guest agent did not claim the submitted or recovered job within 30 seconds.'
                }
            }
            else {
                $inboxFirstSeenUtc = $null
            }
            if (-not $completionState.Inbox -and -not $completionState.Processing) {
                if (-not $lifecycleMissingSinceUtc) {
                    $lifecycleMissingSinceUtc = [DateTime]::UtcNow
                }
                elseif (([DateTime]::UtcNow - $lifecycleMissingSinceUtc).TotalSeconds -ge 15) {
                    throw 'The guest job disappeared before reaching a terminal state.'
                }
            }
            else {
                $lifecycleMissingSinceUtc = $null
            }

            Start-Sleep -Milliseconds 500
        }

        if ($requestNetworkRuntime) {
            $failureStage = 'VerifyingNetwork'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc

            # Guest-job completion is the network-use boundary. Revoke the
            # request adapter before taking a potentially long evidence
            # snapshot or publishing any best-effort status update.
            $requestNetworkCleanup = Remove-RequestNetworkRuntime -Runtime $requestNetworkRuntime -BrokerRoot $BrokerRoot -SuppressErrors
            if ($requestNetworkCleanup.Success) {
                $requestNetworkCleanupPerformed = $true
            }
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            if (-not $requestNetworkCleanup.Success) {
                $cleanupFailureObserved = $true
                throw ('Request-network cleanup failed before evidence collection: ' + (@($requestNetworkCleanup.Errors) -join ' | '))
            }
            try {
                Write-BrokerState -Status 'CollectingEvidence' -RequestId $requestId -Message 'Request network revoked; collecting a stable guest evidence snapshot.'
            }
            catch {
            }
            try {
                Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'CollectingEvidence' -Message 'Request network revoked; creating a stable guest evidence snapshot.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            }
            catch {
            }
        }
        $failureStage = 'StagingGuestEvidence'
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        Write-BrokerState -Status 'CollectingEvidence' -RequestId $requestId -Message 'Creating a stable guest evidence snapshot.'
        Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'CollectingEvidence' -Message 'Creating a stable guest evidence snapshot.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
        for ($evidenceAttempt = 1; $evidenceAttempt -le 3; $evidenceAttempt++) {
            $evidenceSnapshotAttempts = $evidenceAttempt
            try {
                if (-not $session -or [string]$session.State -ne 'Opened') {
                    if ($session) {
                        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    }
                    $session = Open-GuestSessionReliable -VmName $vmName -Credential $credential -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                    $guestSessionReconnects++
                }
                $evidenceManifest = New-GuestEvidenceSnapshot -Session $session -GuestOutbox $guestOutbox -RequestId $requestId
                $guestEvidenceStage = [string]$evidenceManifest.StageRoot
                if ([string]::IsNullOrWhiteSpace($guestEvidenceStage)) {
                    throw 'The guest evidence snapshot returned no stable stage root.'
                }
                $evidenceSnapshotSucceeded = $true
                break
            }
            catch {
                $evidenceError = $_
                if ($session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    $session = $null
                }
                Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                if ($evidenceAttempt -ge 3) {
                    throw $evidenceError
                }
                Write-BrokerState -Status 'CollectingEvidence' -RequestId $requestId -Message 'Guest evidence snapshot interrupted; reconnecting.'
                Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'CollectingEvidence' -Message 'Guest evidence snapshot interrupted; reconnecting.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
                Start-Sleep -Seconds 2
            }
        }
        if (-not $evidenceManifest -or [string]::IsNullOrWhiteSpace($guestEvidenceStage)) {
            throw 'The guest evidence snapshot was not created.'
        }
        foreach ($skippedFile in @($evidenceManifest.SkippedFiles)) {
            $evidenceWarnings.Add("Skipped optional guest evidence '$([string]$skippedFile.RelativePath)' after $([int]$skippedFile.Attempts) attempts: $([string]$skippedFile.Error)")
        }
        foreach ($enumerationError in @($evidenceManifest.EnumerationErrors)) {
            $evidenceWarnings.Add("Guest evidence enumeration warning: $([string]$enumerationError)")
        }

        $failureStage = 'CopyingGuestEvidence'
        Write-BrokerState -Status 'CollectingEvidence' -RequestId $requestId -Message 'Copying the stable guest evidence snapshot to the host.'
        Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'CollectingEvidence' -Message 'Copying the stable guest evidence snapshot to the host.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
        $evidenceCopied = $false
        for ($evidenceAttempt = 1; $evidenceAttempt -le 3; $evidenceAttempt++) {
            $evidenceTransferAttempts = $evidenceAttempt
            try {
                if (-not $session -or [string]$session.State -ne 'Opened') {
                    if ($session) {
                        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    }
                    $session = Open-GuestSessionReliable -VmName $vmName -Credential $credential -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                    $guestSessionReconnects++
                }
                Copy-Item -Path "$guestEvidenceStage\*" -Destination $ResultRoot -FromSession $session -Recurse -Force -ErrorAction Stop
                $evidenceCopied = $true
                $evidenceTransferSucceeded = $true
                break
            }
            catch {
                $evidenceError = $_
                if ($session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    $session = $null
                }
                Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
                if ($evidenceAttempt -ge 3) {
                    throw $evidenceError
                }
                Write-BrokerState -Status 'CollectingEvidence' -RequestId $requestId -Message 'Stable evidence transfer interrupted; reconnecting.'
                Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'CollectingEvidence' -Message 'Stable evidence transfer interrupted; reconnecting.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
                Start-Sleep -Seconds 2
            }
        }
        if (-not $evidenceCopied) {
            throw 'Guest evidence could not be copied to the host.'
        }
        try {
            Remove-GuestEvidenceSnapshot -Session $session -StageRoot $guestEvidenceStage
            $guestEvidenceStage = $null
        }
        catch {
            $evidenceWarnings.Add("The disposable guest evidence stage will be removed with the VM: $($_.Exception.Message)")
        }
        $failureStage = 'ValidatingGuestEvidence'
        Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'CollectingEvidence' -Message 'Validating collected guest evidence.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
        $guestResultPath = Join-Path $ResultRoot 'result.json'
        if (-not (Test-Path -LiteralPath $guestResultPath)) {
            $agentErrorPath = Join-Path $ResultRoot 'agent-error.json'
            $agentError = if (Test-Path -LiteralPath $agentErrorPath) {
                Get-Content -Raw -LiteralPath $agentErrorPath | ConvertFrom-Json
            }
            else {
                $null
            }
            throw "Guest agent failed before producing result.json: $($agentError.Error)"
        }
        $guestResult = Get-Content -Raw -LiteralPath $guestResultPath | ConvertFrom-Json
        if (-not $guestResult.Success) {
            if (-not [string]::IsNullOrWhiteSpace([string]$guestResult.FailureKind)) {
                $failureKind = [string]$guestResult.FailureKind
            }
            throw "Guest agent reported failure: $($guestResult.Error)"
        }
        $evidenceValidationSucceeded = $true

        $failureStage = 'CheckingCompletionLockState'
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        $lockEvidenceAfter = Get-HostLockEvidence
        if ($Request.RequireHostLocked -and -not $lockEvidenceAfter.IsLocked) {
            throw 'The host was no longer locked when the guest job completed.'
        }
        $success = $true
    }
    catch {
        $errorMessage = $_.Exception.Message
        $errorType = $_.Exception.GetType().FullName
        $errorFullyQualifiedId = $_.FullyQualifiedErrorId
        $errorScriptStackTrace = $_.ScriptStackTrace
        $errorPositionMessage = if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            $_.InvocationInfo.PositionMessage.Trim()
        }
        else {
            $null
        }
        $typedException = $_.Exception
        if ($typedException.InnerException) {
            $typedException = $typedException.InnerException
        }
        $cancelled = $typedException -is [OperationCanceledException]
        $executionTimedOut = $typedException -is [TimeoutException]
        if ([string]::IsNullOrWhiteSpace($failureKind)) {
            $failureKind = if ($cancelled) { 'Cancelled' } elseif ($executionTimedOut) { 'ExecutionTimeout' } else { 'Harness' }
        }
        $lockEvidenceAfter = Get-HostLockEvidence
    }
    finally {
        if ($requestNetworkRuntime -and -not $requestNetworkCleanupPerformed) {
            $failureStageBeforeCleanup = $failureStage
            $requestNetworkCleanup.Attempted = $true
            try {
                # Revoke first. Status publication is deliberately best effort
                # and must never run ahead of a still-connected adapter.
                $cleanup = Remove-RequestNetworkRuntime -Runtime $requestNetworkRuntime -BrokerRoot $BrokerRoot -SuppressErrors
                $requestNetworkCleanup = [pscustomobject][ordered]@{
                    Attempted = $true
                    Success = [bool]$cleanup.Success
                    Errors = @($cleanup.Errors)
                    Disconnected = [bool]$cleanup.Disconnected
                    AdapterRemoved = [bool]$cleanup.AdapterRemoved
                    SwitchRemoved = [bool]$cleanup.SwitchRemoved
                    StateDeleted = [bool]$cleanup.StateDeleted
                }
                if (-not $cleanup.Success) { throw ($cleanup.Errors -join ' | ') }
                $requestNetworkCleanupPerformed = $true
                try {
                    Write-BrokerState -Status 'CleaningNetwork' -RequestId $requestId -Message 'Request network revoked; completing guest cleanup.'
                }
                catch {
                }
                try {
                    Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'CleaningNetwork' -Message 'Request network revoked; completing guest cleanup.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
                }
                catch {
                }
                $failureStage = $failureStageBeforeCleanup
            }
            catch {
                $cleanupFailureObserved = $true
                $requestNetworkCleanup = [pscustomobject][ordered]@{
                    Attempted = $true
                    Success = $false
                    Errors = if (@($requestNetworkCleanup.Errors).Count -gt 0) { @($requestNetworkCleanup.Errors) + @($_.Exception.Message) } else { @($_.Exception.Message) }
                    Disconnected = [bool]$requestNetworkCleanup.Disconnected
                    AdapterRemoved = [bool]$requestNetworkCleanup.AdapterRemoved
                    SwitchRemoved = [bool]$requestNetworkCleanup.SwitchRemoved
                    StateDeleted = [bool]$requestNetworkCleanup.StateDeleted
                }
                $cleanupMessage = "Could not revoke the request network: $($_.Exception.Message)"
                $errorMessage = if ($errorMessage) { "$errorMessage $cleanupMessage" } else { $cleanupMessage }
                $failureStage = 'CleaningNetwork'
                $success = $false
                try { Stop-TestVm -VmName $vmName -Immediate } catch { }
            }
        }

        if ($Request.StopAfter -and $session) {
            try {
                Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                    shutdown.exe /s /t 0
                }
            }
            catch {
                # The PowerShell Direct transport normally drops as shutdown begins.
            }
        }
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
        if ($Request.StopAfter) {
            # StoppingVm status publication is advisory. A request-state file
            # can be in the middle of an atomic replacement (and broker-state
            # publication can fail for the same reason); neither failure may
            # skip the VM stop or the cleanup/inventory/result work below.
            try {
                Write-BrokerState -Status 'StoppingVm' -RequestId $requestId -Message 'Stopping the isolated guest before asynchronous worker recycling.'
            }
            catch {
                $evidenceWarnings.Add("Could not publish StoppingVm broker state: $($_.Exception.Message)")
            }
            try {
                Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'StoppingVm' -Message 'Stopping the isolated guest; the pool worker will recycle asynchronously.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            }
            catch {
                $evidenceWarnings.Add("Could not publish StoppingVm request state: $($_.Exception.Message)")
            }
            try {
                Stop-TestVm -VmName $vmName -Immediate:(-not $success)
            }
            catch {
                $cleanupFailureObserved = $true
                $stopMessage = "Could not stop test VM: $($_.Exception.Message)"
                $errorMessage = if ($errorMessage) { "$errorMessage $stopMessage" } else { $stopMessage }
                $failureStage = 'StoppingVm'
                $success = $false
            }
        }

        if ($hostInputShareRuntime) {
            $failureStageBeforeCleanup = $failureStage
            $hostInputCleanup.Attempted = $true
            try {
                if ((Get-VM -Name $vmName).State -ne 'Off') {
                    Stop-TestVm -VmName $vmName -Immediate
                }
                $shareCleanup = Remove-HostInputShareRuntime -Runtime $hostInputShareRuntime -BrokerRoot $BrokerRoot
                $hostInputCleanup = [pscustomobject][ordered]@{
                    Attempted = $true
                    Success = [bool]$shareCleanup.Success
                    Errors = @($shareCleanup.Errors)
                    StateDeleted = [bool]$shareCleanup.StateDeleted
                }
            }
            catch {
                $cleanupFailureObserved = $true
                $hostInputCleanup = [pscustomobject][ordered]@{
                    Attempted = $true
                    Success = $false
                    Errors = @($_.Exception.Message)
                    StateDeleted = -not (Test-Path -LiteralPath ([string]$hostInputShareRuntime.StatePath) -PathType Leaf)
                }
                $cleanupMessage = "Could not revoke read-only host inputs: $($_.Exception.Message)"
                $errorMessage = if ($errorMessage) { "$errorMessage $cleanupMessage" } else { $cleanupMessage }
                $failureStage = 'CleaningHostInputs'
                $success = $false
            }
            if ($success) { $failureStage = $failureStageBeforeCleanup }
        }

        foreach ($inputRuntime in $hostInputVhdxRuntimes) {
            if ($inputRuntime.Child) {
                $failureStageBeforeCleanup = $failureStage
                try {
                    if ((Get-VM -Name $vmName).State -ne 'Off') {
                        Stop-TestVm -VmName $vmName -Immediate
                    }
                    $inputRuntime.ChildDeleted = Remove-PayloadChildSafe -VmName $vmName -ChildPath ([string]$inputRuntime.Child.Path)
                    if (-not $inputRuntime.ChildDeleted) { throw "Read-only host input '$($inputRuntime.Definition.Name)' child still exists after cleanup." }
                }
                catch {
                    $cleanupFailureObserved = $true
                    $cleanupMessage = "Could not detach read-only host input '$($inputRuntime.Definition.Name)' VHDX child: $($_.Exception.Message)"
                    $errorMessage = if ($errorMessage) { "$errorMessage $cleanupMessage" } else { $cleanupMessage }
                    $failureStage = 'CleaningHostInputs'
                    $success = $false
                }
                if ($success) { $failureStage = $failureStageBeforeCleanup }
            }
            if ($inputRuntime.LeaseCreated -and (-not $inputRuntime.Child -or $inputRuntime.ChildDeleted)) {
                try {
                    Remove-PayloadGenerationLease -RequestId $inputRuntime.LeaseId
                    $inputRuntime.LeaseCreated = $false
                }
                catch {
                    $cleanupFailureObserved = $true
                    $cleanupMessage = "Could not release read-only host input '$($inputRuntime.Definition.Name)' payload lease: $($_.Exception.Message)"
                    $errorMessage = if ($errorMessage) { "$errorMessage $cleanupMessage" } else { $cleanupMessage }
                    $failureStage = 'CleaningHostInputs'
                    $success = $false
                }
            }
        }

        if ($payloadChild) {
            $failureStageBeforeCleanup = $failureStage
            try {
                if ((Get-VM -Name $vmName).State -ne 'Off') {
                    Stop-TestVm -VmName $vmName -Immediate
                }
                $payloadChildDeleted = Remove-PayloadChildSafe -VmName $vmName -ChildPath ([string]$payloadChild.Path)
                if (-not $payloadChildDeleted) {
                    throw 'The disposable payload child still exists after cleanup.'
                }
            }
            catch {
                $cleanupFailureObserved = $true
                $cleanupMessage = "Could not detach and delete the disposable payload child: $($_.Exception.Message)"
                $errorMessage = if ($errorMessage) { "$errorMessage $cleanupMessage" } else { $cleanupMessage }
                $failureStage = 'CleaningPayloadChild'
                $success = $false
            }
            if ($success) {
                $failureStage = $failureStageBeforeCleanup
            }
        }

        if ($payloadLeaseCreated -and (-not $payloadChild -or $payloadChildDeleted)) {
            try {
                Remove-PayloadGenerationLease -RequestId $requestId
                $payloadLeaseCreated = $false
            }
            catch {
                $cleanupFailureObserved = $true
                $cleanupMessage = "Could not release the payload generation lease: $($_.Exception.Message)"
                $errorMessage = if ($errorMessage) { "$errorMessage $cleanupMessage" } else { $cleanupMessage }
                $failureStage = 'CleaningPayloadChild'
                $success = $false
            }
        }

        $finalConnectedNetworkAdapters = @()
        $finalNetworkInventorySucceeded = $false
        try {
            $finalConnectedNetworkAdapters = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) } | ForEach-Object {
                [ordered]@{ Name = [string]$_.Name; SwitchName = [string]$_.SwitchName; MacAddress = [string]$_.MacAddress }
            })
            $finalNetworkInventorySucceeded = $true
            if ($finalConnectedNetworkAdapters.Count -gt 0) {
                $cleanupFailureObserved = $true
                $cleanupMessage = 'One or more VM network adapters remained connected after request cleanup.'
                $errorMessage = if ($errorMessage) { "$errorMessage $cleanupMessage" } else { $cleanupMessage }
                $failureStage = 'CleaningNetwork'
                $success = $false
            }
        }
        catch {
            $cleanupFailureObserved = $true
            $cleanupMessage = "Could not verify final VM network disconnection: $($_.Exception.Message)"
            $errorMessage = if ($errorMessage) { "$errorMessage $cleanupMessage" } else { $cleanupMessage }
            $failureStage = 'CleaningNetwork'
            $success = $false
        }

        [CodexHostSession]::AllowSleep()
        if ($hostInputSetupWatch.IsRunning) { $hostInputSetupWatch.Stop() }
        $vmFinalState = 'Unknown'
        try {
            $vmFinalState = [string](Get-VM -Name $vmName).State
        }
        catch {
        }
        if (-not $success) {
            # Preserve typed cancellation/timeout outcomes even when cleanup
            # also fails; the appended cleanup error still surfaces below.
            if ($cancelled) {
                $failureKind = 'Cancelled'
            }
            elseif ($executionTimedOut) {
                $failureKind = 'ExecutionTimeout'
            }
            elseif ($cleanupFailureObserved) {
                $failureKind = 'HarnessCleanup'
            }
            elseif ([string]::IsNullOrWhiteSpace($failureKind)) {
                $failureKind = 'Harness'
            }
        }

        $applicationTestFailed = $success -and $guestResult -and [bool]$guestResult.TestEvaluated -and -not [bool]$guestResult.TestPassed
        $cleanupFailed = -not $success -and $cleanupFailureObserved
        $finalStatus = if ($applicationTestFailed) { 'TestFailed' } elseif ($success) { 'Completed' } elseif ($cancelled) { 'Cancelled' } elseif ($executionTimedOut) { 'ExecutionTimedOut' } elseif ($cleanupFailed) { 'Failed' } else { 'Failed' }
        $finalMessage = if ($applicationTestFailed) {
            if (-not [string]::IsNullOrWhiteSpace([string]$guestResult.TestFailureMessage)) { [string]$guestResult.TestFailureMessage } else { 'The application assertion failed.' }
        }
        elseif ($success) { 'Terminal result is ready; evidence collection and VM cleanup completed.' }
        else { $errorMessage }
        if (-not $poolMode) {
            try {
                Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status $finalStatus -Message $finalMessage -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
            }
            catch {
                # Request-state publication is advisory. Never let a transient
                # status-file race hide the terminal broker-result or a cleanup
                # failure that has already been captured above.
                $evidenceWarnings.Add("Could not publish final request state: $($_.Exception.Message)")
            }
        }

        Write-JsonAtomic -Path (Join-Path $ResultRoot 'broker-result.json') -Value ([ordered]@{
            RequestId = $requestId
            Success = $success
            HarnessSucceeded = $success
            TestEvaluated = [bool]($guestResult -and $guestResult.TestEvaluated)
            TestPassed = if ($guestResult -and $guestResult.TestEvaluated) { [bool]$guestResult.TestPassed } else { $null }
            OverallSucceeded = [bool]$success -and (-not ($guestResult -and $guestResult.TestEvaluated) -or [bool]$guestResult.TestPassed)
            FailureKind = if (-not $success) { $failureKind } elseif ($guestResult -and $guestResult.TestEvaluated -and -not [bool]$guestResult.TestPassed) { [string]$guestResult.TestFailureKind } else { $null }
            CleanupFailure = [bool]$cleanupFailureObserved
            Error = $errorMessage
            FailureStage = if ($success) { $null } else { $failureStage }
            ErrorType = $errorType
            ErrorFullyQualifiedId = $errorFullyQualifiedId
            ErrorScriptStackTrace = $errorScriptStackTrace
            ErrorPositionMessage = $errorPositionMessage
            CreatedUtc = $Request.CreatedUtc
            ClaimedUtc = $ClaimedUtc.ToString('o')
            QueueWaitSeconds = [Math]::Round(($ClaimedUtc - $createdUtc).TotalSeconds, 3)
            ExecutionTimeoutSeconds = $executionTimeoutSeconds
            ExecutionDeadlineUtc = $executionDeadlineUtc.ToString('o')
            Cancelled = $cancelled
            QueueTimedOut = $false
            ExecutionTimedOut = $executionTimedOut
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
            BrokerIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            BrokerSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
            VmName = $vmName
            PoolWorkerId = if ($poolMode) { [int]$Config.PoolWorkerId } else { $null }
            PoolWorkerRecyclePending = [bool]$poolMode
            VmStartUtc = if ($vmStartUtc) { $vmStartUtc.ToString('o') } else { $null }
            VmFinalState = $vmFinalState
            PayloadTransferAttempts = $payloadTransferAttempts
            PayloadId = if ($payloadManifest) { [string]$payloadManifest.PayloadId } else { $null }
            PayloadContentKey = if ($payloadManifest) { [string]$payloadManifest.ContentKey } else { $null }
            PayloadArtifactPath = if ($payloadManifest) { [string]$payloadManifest.ArtifactPath } else { $null }
            PayloadFingerprintEnumerationMilliseconds = if ($Request.Payload) { [double]$Request.Payload.FingerprintEnumerationMilliseconds } else { 0 }
            PayloadCandidateHashMilliseconds = if ($Request.Payload) { [double]$Request.Payload.CandidateHashMilliseconds } else { 0 }
            PayloadDetectionTotalMilliseconds = if ($Request.Payload) { [double]$Request.Payload.DetectionTotalMilliseconds } else { 0 }
            PayloadFilesHashed = if ($Request.Payload) { [int]$Request.Payload.FilesHashed } else { 0 }
            PayloadHashesReused = if ($Request.Payload) { [int]$Request.Payload.HashesReused } else { 0 }
            PayloadCacheHit = if ($payloadCache) { [bool]$payloadCache.CacheHit } else { $false }
            PayloadCacheOperationMilliseconds = if ($payloadCache) { [double]$payloadCache.CacheOperationMilliseconds } else { 0 }
            PayloadVhdxSyncMilliseconds = if ($payloadCache) { [double]$payloadCache.SyncMilliseconds } else { 0 }
            PayloadSyncMode = if ($payloadCache) { [string]$payloadCache.SyncMode } else { $null }
            PayloadFilesCopied = if ($payloadCache) { [int]$payloadCache.FilesCopied } else { 0 }
            PayloadFilesDeleted = if ($payloadCache) { [int]$payloadCache.FilesDeleted } else { 0 }
            PayloadFilesReused = if ($payloadCache) { [int]$payloadCache.FilesReused } else { 0 }
            PayloadDirectoriesDeleted = if ($payloadCache) { [int]$payloadCache.DirectoriesDeleted } else { 0 }
            PayloadCacheChainDepth = if ($payloadCache) { [int]$payloadCache.ChainDepth } else { 0 }
            PayloadCacheCompacted = if ($payloadCache) { [bool]$payloadCache.Compacted } else { $false }
            PayloadParentVhdx = if ($payloadCache) { [string]$payloadCache.ParentVhdx } else { $null }
            PayloadChildVhdx = if ($payloadChild) { [string]$payloadChild.Path } else { $null }
            PayloadChildDeleted = $payloadChildDeleted
            HostInputSetupMilliseconds = [Math]::Round($hostInputSetupWatch.Elapsed.TotalMilliseconds, 3)
            HostInputCleanup = $hostInputCleanup
            Network = [ordered]@{
                ContractVersion = if ([string]$Request.Operation -eq 'RunGuestJobNetworkV1') { 1 } else { 0 }
                RequestedProfile = if ($requestNetworkDefinition) { [string]$requestNetworkDefinition.RequestedProfile } else { 'None' }
                EffectiveProfile = if ($requestNetworkDefinition) { [string]$requestNetworkDefinition.EffectiveProfile } else { 'None' }
                Cohort = if ($requestNetworkDefinition -and [string]$requestNetworkDefinition.EffectiveProfile -eq 'IsolatedTestNet') { [string]$requestNetworkDefinition.Cohort } else { $null }
                SwitchName = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.SwitchName } else { $null }
                SwitchId = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.SwitchId } else { $null }
                SwitchType = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.SwitchType } else { $null }
                AdapterName = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.AdapterName } else { $null }
                AdapterMacAddress = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.AdapterMacAddress } else { $null }
                GuestAddress = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.GuestAddress } else { $null }
                GatewayAddress = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.GatewayAddress } else { $null }
                GatewayMacAddress = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.GatewayMacAddress } else { $null }
                DnsServers = if ($requestNetworkRuntime) { @($requestNetworkRuntime.DnsServers) } else { @() }
                EnforcedLocalAddress = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.EnforcedLocalAddress } else { $null }
                AllowedRemoteAddress = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.AllowedRemoteAddress } else { $null }
                AllowedRemoteMacAddress = if ($requestNetworkRuntime) { [string]$requestNetworkRuntime.AllowedRemoteMacAddress } else { $null }
                DenyRemotePrefixes = if ($requestNetworkRuntime) { @($requestNetworkRuntime.DenyRemotePrefixes) } else { @() }
                ResidueCleanup = $requestNetworkResidueCleanup
                AdapterEnforcement = $requestNetworkAttachment
                Connection = $requestNetworkConnection
                HostPolicyChecks = [ordered]@{
                    Count = $requestNetworkHostPolicyCheckCount
                    Prelaunch = $requestNetworkPrelaunchHostEvidence
                    Last = $requestNetworkLastHostEvidence
                }
                GuestAttestation = $requestNetworkGuestEvidence
                Cleanup = $requestNetworkCleanup
                FinalNetworkInventorySucceeded = [bool]$finalNetworkInventorySucceeded
                FinalConnectedAdapters = if ($finalNetworkInventorySucceeded) { @($finalConnectedNetworkAdapters) } else { $null }
                FinalAllAdaptersDisconnected = [bool]$finalNetworkInventorySucceeded -and $finalConnectedNetworkAdapters.Count -eq 0
            }
            HostInputs = @(
                foreach ($definition in $hostInputDefinitions) {
                    $inputName = [string]$definition.Name
                    $vhdxRuntime = @($hostInputVhdxRuntimes | Where-Object { [string]::Equals([string]$_.Definition.Name, $inputName, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                    $shareRuntime = if ($hostInputShareRuntime) { @($hostInputShareRuntime.Inputs | Where-Object { [string]::Equals([string]$_.Name, $inputName, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1 } else { $null }
                    [ordered]@{
                        Name = $inputName
                        Token = [string]$definition.Token
                        HostPath = [string]$definition.HostPath
                        IsDirectory = [bool]$definition.IsDirectory
                        RequestedMode = [string]$definition.RequestedMode
                        SelectedTransport = [string]$definition.SelectedTransport
                        SelectionReason = [string]$definition.SelectionReason
                        ReadOnly = $true
                        FileCount = [int]$definition.FileCount
                        DirectoryCount = [int]$definition.DirectoryCount
                        TotalBytes = [long]$definition.TotalBytes
                        CandidateCount = [int]$definition.CandidateCount
                        CandidateBytes = [long]$definition.CandidateBytes
                        FingerprintEnumerationMilliseconds = [double]$definition.FingerprintEnumerationMilliseconds
                        CandidateHashMilliseconds = [double]$definition.CandidateHashMilliseconds
                        DetectionTotalMilliseconds = [double]$definition.DetectionTotalMilliseconds
                        FilesHashed = [int]$definition.FilesHashed
                        HashesReused = [int]$definition.HashesReused
                        CacheHit = if ($vhdxRuntime -and $vhdxRuntime.Cache) { [bool]$vhdxRuntime.Cache.CacheHit } else { $false }
                        CacheOperationMilliseconds = if ($vhdxRuntime -and $vhdxRuntime.Cache) { [double]$vhdxRuntime.Cache.CacheOperationMilliseconds } else { 0 }
                        VhdxSyncMilliseconds = if ($vhdxRuntime -and $vhdxRuntime.Cache) { [double]$vhdxRuntime.Cache.SyncMilliseconds } else { 0 }
                        FilesCopied = if ($vhdxRuntime -and $vhdxRuntime.Cache) { [int]$vhdxRuntime.Cache.FilesCopied } else { 0 }
                        ParentVhdx = if ($vhdxRuntime -and $vhdxRuntime.Cache) { [string]$vhdxRuntime.Cache.ParentVhdx } else { $null }
                        ChildVhdx = if ($vhdxRuntime -and $vhdxRuntime.Child) { [string]$vhdxRuntime.Child.Path } else { $null }
                        ChildDeleted = if ($vhdxRuntime) { [bool]$vhdxRuntime.ChildDeleted } else { $null }
                        ShareName = if ($shareRuntime) { [string]$shareRuntime.ShareName } else { $null }
                        ShareRemoved = if ($shareRuntime) { [bool]$hostInputCleanup.Success } else { $null }
                        BytesExposedWithoutCopy = if ($shareRuntime) { [long]$definition.TotalBytes } else { 0 }
                        GuestRoot = if ($hostInputGuestRoots.ContainsKey($inputName)) { [string]$hostInputGuestRoots[$inputName] } else { $null }
                        IsolatedSwitch = if ($shareRuntime) { [string]$hostInputShareRuntime.SwitchName } else { $null }
                        HostAddress = if ($shareRuntime) { [string]$hostInputShareRuntime.HostAddress } else { $null }
                        GuestAddress = if ($shareRuntime) { [string]$hostInputShareRuntime.GuestAddress } else { $null }
                        CleanupSucceeded = if ($shareRuntime) { [bool]$hostInputCleanup.Success } elseif ($vhdxRuntime) { [bool]$vhdxRuntime.ChildDeleted } else { $true }
                    }
                }
            )
            EvidenceSnapshotAttempts = $evidenceSnapshotAttempts
            EvidenceTransferAttempts = $evidenceTransferAttempts
            EvidenceSnapshotSucceeded = [bool]$evidenceSnapshotSucceeded
            EvidenceTransferSucceeded = [bool]$evidenceTransferSucceeded
            EvidenceValidationSucceeded = [bool]$evidenceValidationSucceeded
            EvidenceFilesEnumerated = if ($evidenceSnapshotSucceeded -and $null -ne $evidenceManifest.EnumeratedFileCount) { [int]$evidenceManifest.EnumeratedFileCount } else { $null }
            EvidenceFilesCopied = if ($evidenceSnapshotSucceeded) { @($evidenceManifest.CopiedFiles).Count } else { $null }
            EvidenceFilesSkipped = if ($evidenceSnapshotSucceeded) { @($evidenceManifest.SkippedFiles).Count } else { $null }
            EvidenceSkippedFiles = if ($evidenceSnapshotSucceeded) { @($evidenceManifest.SkippedFiles) } else { $null }
            EvidenceWarnings = $evidenceWarnings.ToArray()
            GuestSessionReconnects = $guestSessionReconnects
            JobSubmissionAttempts = $jobSubmissionAttempts
            JobSubmittedUtc = if ($jobSubmittedUtc) { $jobSubmittedUtc.ToString('o') } else { $null }
            InfrastructureRetryCount = if ($null -ne $Request.InfrastructureRetryCount) { [int]$Request.InfrastructureRetryCount } else { 0 }
            InfrastructureRetryHistory = if ($Request.InfrastructureRetryHistory) { @($Request.InfrastructureRetryHistory) } else { @() }
            GuestAgentState = $guestState
            GuestResult = $guestResult
            RequireHostLocked = [bool]$Request.RequireHostLocked
            HostLockEvidenceBefore = $lockEvidenceBefore
            HostLockEvidenceAfter = $lockEvidenceAfter
        })
    }

    if (-not $success) {
        throw $errorMessage
    }
}

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class CodexHostSession
{
    private const uint ES_CONTINUOUS = 0x80000000;
    private const uint ES_SYSTEM_REQUIRED = 0x00000001;

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQuerySessionInformation(
        IntPtr server,
        uint sessionId,
        int infoClass,
        out IntPtr buffer,
        out uint bytesReturned);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr buffer);

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint executionState);

    public static uint GetActiveConsoleSessionId()
    {
        return WTSGetActiveConsoleSessionId();
    }

    public static int GetSessionFlags(uint sessionId)
    {
        const int WTSSessionInfoEx = 25;
        IntPtr buffer;
        uint bytesReturned;
        if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, WTSSessionInfoEx, out buffer, out bytesReturned))
        {
            return -1;
        }
        try
        {
            // WTSINFOEX starts with DWORD Level, followed by the level-1 union.
            // SessionFlags is the third DWORD in WTSINFOEX_LEVEL1.
            if (bytesReturned < 16 || Marshal.ReadInt32(buffer, 0) != 1)
            {
                return -1;
            }
            return Marshal.ReadInt32(buffer, 12);
        }
        finally
        {
            WTSFreeMemory(buffer);
        }
    }

    public static void PreventSleep()
    {
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
    }

    public static void AllowSleep()
    {
        SetThreadExecutionState(ES_CONTINUOUS);
    }
}
'@

if ($LibraryOnly) {
    return
}

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, 'Global\CodexHyperVBroker', [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

try {
    Import-Module Hyper-V
    Remove-Item -LiteralPath $fatalStatePath -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $configPath) -or -not (Test-Path -LiteralPath $credentialPath)) {
        throw 'Broker configuration or guest credential is missing.'
    }
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    Recover-OrphanedGuestProbes
    if ([bool]$config.PoolEnabled) {
        $poolCommonPath = Join-Path $PSScriptRoot 'PoolCommon.ps1'
        $poolBrokerPath = Join-Path $PSScriptRoot 'PoolBroker.ps1'
        foreach ($poolModule in @($poolCommonPath, $poolBrokerPath)) {
            if (-not (Test-Path -LiteralPath $poolModule -PathType Leaf)) {
                throw "Pool broker module not found: $poolModule"
            }
        }
        . $poolCommonPath
        . $poolBrokerPath
        Invoke-PoolBrokerLoop -Config $config
        return
    }
    Recover-OrphanedPayloadChildren -VmName ([string]$config.VmName)
    Recover-InterruptedRequests -Config $config
    $nextCleanupUtc = [DateTime]::MinValue

    while ($true) {
        Write-BrokerState
        if (Test-Path -LiteralPath $maintenancePath -PathType Leaf) {
            Write-BrokerState -Status 'Maintenance' -Message 'The queue is paused for broker or baseline maintenance.'
            Start-Sleep -Milliseconds 500
            continue
        }
        if ([DateTime]::UtcNow -ge $nextCleanupUtc) {
            Remove-StaleQueueArtifacts
            Invoke-PayloadCacheGarbageCollection -Config $config -VmName ([string]$config.VmName)
            $nextCleanupUtc = [DateTime]::UtcNow.AddMinutes(5)
        }
        $requestFiles = @(Get-ChildItem -LiteralPath $requestPath -Filter '*.json' -File | Sort-Object CreationTimeUtc, Name)
        foreach ($invalidRequestFile in @($requestFiles | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$' })) {
            $invalidArchive = Join-Path $archivePath ('invalid-request-' + [Guid]::NewGuid().ToString('N') + '.json')
            Move-Item -LiteralPath $invalidRequestFile.FullName -Destination $invalidArchive -Force
        }
        $requestFiles = @($requestFiles | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$' })
        $queueDepth = $requestFiles.Count
        for ($queueIndex = 0; $queueIndex -lt $requestFiles.Count; $queueIndex++) {
            $queuedFile = $requestFiles[$queueIndex]
            $queuedId = [IO.Path]::GetFileNameWithoutExtension($queuedFile.Name)
            if ($queuedId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
                continue
            }
            $queuedResultRoot = Join-Path $resultsPath $queuedId
            New-Item -ItemType Directory -Force -Path $queuedResultRoot | Out-Null
            $queuedCreatedUtc = $null
            try {
                $queuedRequest = Get-Content -Raw -LiteralPath $queuedFile.FullName | ConvertFrom-Json
                $parsedCreatedUtc = [DateTime]::MinValue
                if ([DateTime]::TryParse([string]$queuedRequest.CreatedUtc, [ref]$parsedCreatedUtc)) {
                    $queuedCreatedUtc = $parsedCreatedUtc.ToUniversalTime()
                }
            }
            catch {
            }
            Write-RequestState -ResultRoot $queuedResultRoot -RequestId $queuedId -Status 'Queued' -Message 'Waiting for the single-VM broker.' -QueuePosition ($queueIndex + 1) -QueueDepth $queueDepth -CreatedUtc $queuedCreatedUtc
        }

        foreach ($requestFile in $requestFiles) {
            if (Test-Path -LiteralPath $maintenancePath -PathType Leaf) {
                break
            }
            $requestId = [IO.Path]::GetFileNameWithoutExtension($requestFile.Name)
            if ($requestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
                continue
            }
            $processingFile = Join-Path $processingPath $requestFile.Name
            $resultRoot = Join-Path $resultsPath $requestId
            New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
            $request = $null
            $createdUtc = $null
            $claimedUtc = $null
            try {
                if (-not (Test-Path -LiteralPath $requestFile.FullName -PathType Leaf)) {
                    continue
                }
                try {
                    Move-Item -LiteralPath $requestFile.FullName -Destination $processingFile -Force -ErrorAction Stop
                }
                catch {
                    if (-not (Test-Path -LiteralPath $requestFile.FullName -PathType Leaf)) {
                        continue
                    }
                    throw
                }
                $claimedUtc = [DateTime]::UtcNow
                $request = Get-Content -Raw -LiteralPath $processingFile | ConvertFrom-Json
                if ([string]$request.RequestId -ne $requestId) {
                    throw 'RequestId must match the request filename.'
                }
                $parsedCreatedUtc = [DateTime]::MinValue
                if (-not [DateTime]::TryParse([string]$request.CreatedUtc, [ref]$parsedCreatedUtc)) {
                    throw 'CreatedUtc must be a valid timestamp.'
                }
                $createdUtc = $parsedCreatedUtc.ToUniversalTime()
                $queueTimeoutSeconds = Get-BoundedTimeout -Value $request.QueueTimeoutSeconds -Default 1800 -Minimum 5 -Maximum 86400
                $queueDeadlineUtc = $createdUtc.AddSeconds($queueTimeoutSeconds)
                $cancelFile = Join-Path $cancellationPath ($requestId + '.json')
                $cancelledBeforeStart = Test-Path -LiteralPath $cancelFile -PathType Leaf
                $queueTimedOut = [DateTime]::UtcNow -ge $queueDeadlineUtc

                if ($cancelledBeforeStart -or $queueTimedOut) {
                    $errorMessage = if ($queueTimedOut) { 'Queue timeout expired before execution.' } else { 'Cancellation requested before execution.' }
                    $vmFinalState = 'Unknown'
                    try {
                        $vmFinalState = [string](Get-VM -Name ([string]$config.VmName)).State
                    }
                    catch {
                    }
                    Write-JsonAtomic -Path (Join-Path $resultRoot 'broker-result.json') -Value ([ordered]@{
                        RequestId = $requestId
                        Success = $false
                        Error = $errorMessage
                        CreatedUtc = $request.CreatedUtc
                        ClaimedUtc = $claimedUtc.ToString('o')
                        QueueWaitSeconds = [Math]::Round(($claimedUtc - $createdUtc).TotalSeconds, 3)
                        QueueTimeoutSeconds = $queueTimeoutSeconds
                        QueueDeadlineUtc = $queueDeadlineUtc.ToString('o')
                        Cancelled = $true
                        QueueTimedOut = $queueTimedOut
                        ExecutionTimedOut = $false
                        CompletedUtc = [DateTime]::UtcNow.ToString('o')
                        BrokerIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                        BrokerSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
                        VmName = [string]$config.VmName
                        VmFinalState = $vmFinalState
                    })
                    $status = if ($queueTimedOut) { 'QueueTimedOut' } else { 'Cancelled' }
                    Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status $status -Message $errorMessage -CreatedUtc $createdUtc -ClaimedUtc $claimedUtc
                    continue
                }

                $executionTimeoutSeconds = Get-BoundedTimeout -Value $request.ExecutionTimeoutSeconds -Default 900 -Minimum 10 -Maximum 7200
                Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'Claimed' -Message 'The broker claimed this request.' -CreatedUtc $createdUtc -ClaimedUtc $claimedUtc -ExecutionDeadlineUtc $claimedUtc.AddSeconds($executionTimeoutSeconds)
                Invoke-GuestRequest -Request $request -ResultRoot $resultRoot -Config $config -ClaimedUtc $claimedUtc
            }
            catch {
                $brokerResultFile = Join-Path $resultRoot 'broker-result.json'
                if (-not (Test-Path -LiteralPath $brokerResultFile)) {
                    Write-JsonAtomic -Path (Join-Path $resultRoot 'broker-result.json') -Value ([ordered]@{
                        RequestId = $requestId
                        Success = $false
                        Error = $_.Exception.Message
                        CreatedUtc = if ($request) { $request.CreatedUtc } else { $null }
                        ClaimedUtc = if ($claimedUtc) { $claimedUtc.ToString('o') } else { $null }
                        Cancelled = $false
                        QueueTimedOut = $false
                        ExecutionTimedOut = $false
                        CompletedUtc = [DateTime]::UtcNow.ToString('o')
                        BrokerIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                        BrokerSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
                    })
                    Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'Failed' -Message $_.Exception.Message -CreatedUtc $createdUtc -ClaimedUtc $claimedUtc
                }
            }
            finally {
                if (Test-Path -LiteralPath $processingFile) {
                    $archiveFile = Join-Path $archivePath ($requestId + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.json')
                    Move-Item -LiteralPath $processingFile -Destination $archiveFile -Force
                }
                $cancelFile = Join-Path $cancellationPath ($requestId + '.json')
                Remove-Item -LiteralPath $cancelFile -Force -ErrorAction SilentlyContinue
                try {
                    Remove-StagedPayloadSafe -RequestId $requestId
                }
                catch {
                    # Queue progress must not stop because cleanup failed. The
                    # exact request-specific staging path remains inspectable.
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
}
catch {
    try {
        Write-JsonAtomic -Path $fatalStatePath -Value ([ordered]@{
            Error = $_.Exception.Message
            ErrorType = $_.Exception.GetType().FullName
            FullyQualifiedErrorId = $_.FullyQualifiedErrorId
            ScriptStackTrace = $_.ScriptStackTrace
            PositionMessage = if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) { $_.InvocationInfo.PositionMessage.Trim() } else { $null }
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            ProcessId = $PID
            Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        })
    }
    catch { }
    throw
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
