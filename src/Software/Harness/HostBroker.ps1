param(
    [string] $BrokerRoot,
    [switch] $LibraryOnly
)

$ErrorActionPreference = 'Stop'

function Get-ValidatedKeyChord {
    param(
        [Parameter(Mandatory = $true)] $Action,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    $allowedProperties = @('type', 'keys', 'holdMs')
    $unexpectedProperties = @($Action.PSObject.Properties.Name | Where-Object { $_ -notin $allowedProperties })
    if ($unexpectedProperties.Count -gt 0) { throw "$Context send_keys contains unsupported properties: $($unexpectedProperties -join ', ')." }
    $keySpec = [string]$Action.keys
    if ([string]::IsNullOrWhiteSpace($keySpec)) { throw "$Context send_keys requires keys." }
    if ($keySpec.Length -gt 64 -or $keySpec -cnotmatch '^[A-Z0-9]+(?:\+[A-Z0-9]+)*$') {
        throw "$Context send_keys keys must be an uppercase '+'-separated chord of at most 64 characters."
    }
    $allowedKeys = @(
        'CTRL', 'ALT', 'SHIFT', 'WIN', 'LEFT', 'UP', 'RIGHT', 'DOWN', 'ENTER', 'ESCAPE', 'TAB', 'SPACE',
        'BACKSPACE', 'DELETE', 'INSERT', 'HOME', 'END', 'PAGEUP', 'PAGEDOWN',
        'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12',
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S',
        'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'
    )
    $modifiers = @('CTRL', 'ALT', 'SHIFT', 'WIN')
    $keys = @($keySpec.Split([char]'+'))
    if ($keys.Count -gt 5) { throw "$Context send_keys may contain at most four modifiers and one non-modifier key." }
    if (@($keys | Select-Object -Unique).Count -ne $keys.Count) { throw "$Context send_keys does not allow duplicate keys." }
    foreach ($key in $keys) {
        if ($key -notin $allowedKeys) { throw "$Context send_keys key '$key' is not supported." }
    }
    if ($keys.Count -gt 1 -and ($keys[-1] -in $modifiers -or @($keys[0..($keys.Count - 2)] | Where-Object { $_ -notin $modifiers }).Count -gt 0)) {
        throw "$Context send_keys chords must list one or more modifiers followed by exactly one non-modifier key."
    }
    if ($Action.PSObject.Properties.Name -contains 'holdMs') {
        try {
            $holdMilliseconds = [int]$Action.holdMs
            if ([double]$Action.holdMs -ne [double]$holdMilliseconds) { throw 'not an integer' }
        }
        catch { throw "$Context send_keys holdMs must be a whole number between 10 and 2000." }
        if ($holdMilliseconds -lt 10 -or $holdMilliseconds -gt 2000) { throw "$Context send_keys holdMs must be between 10 and 2000." }
    }
    $keys
}

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
                    [IO.File]::Delete($backupPath)
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
        [IO.File]::Delete($temporaryPath)
        [IO.File]::Delete($backupPath)
    }
}

function Write-TerminalJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporaryPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.terminal.tmp'
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                # File.Move without overwrite is the first-writer-wins terminal
                # publication primitive on Windows/.NET Framework. A competing
                # terminal result can never be replaced after it becomes visible.
                [IO.File]::Move($temporaryPath, $Path)
                return $true
            }
            catch [IO.IOException] {
                if ([IO.File]::Exists($Path)) { return $false }
                if ($attempt -ge 20) { throw }
            }
            catch [UnauthorizedAccessException] {
                if ([IO.File]::Exists($Path)) { return $false }
                if ($attempt -ge 20) { throw }
            }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        [IO.File]::Delete($temporaryPath)
    }
}

function Invoke-WithTerminalResultPublicationMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $ScopeRoot,
        [Parameter(Mandatory = $true)] [scriptblock] $Operation
    )

    $scopeText = ([IO.Path]::GetFullPath($ScopeRoot).TrimEnd('\') + '|' + $RequestId).ToUpperInvariant()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $scopeHash = ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($scopeText)))).Replace('-', '').Substring(0, 32) }
    finally { $sha256.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Global\CodexHyperVTerminalPublish-' + $scopeHash))
    $lockTaken = $false
    try {
        try { $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $lockTaken = $true }
        if (-not $lockTaken) { throw "Timed out acquiring terminal publication lock for request $RequestId." }
        & $Operation
    }
    finally {
        if ($lockTaken) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Read-BrokerJsonWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [ValidateRange(1, 20)] [int] $Attempts = 6,
        [ValidateRange(10, 1000)] [int] $DelayMilliseconds = 50
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw [IO.FileNotFoundException]::new("JSON file not found: $Path")
            }
            return Get-Content -Raw -LiteralPath $Path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds $DelayMilliseconds }
        }
    }
    throw [IO.InvalidDataException]::new("Could not read a stable JSON document after $Attempts attempts: $Path", $lastError.Exception)
}

function Test-ExactExpectedGuestPowerOffRequest {
    param([AllowNull()] $Request)

    if (-not $Request) { return $false }
    $expectation = @($Request.PSObject.Properties | Where-Object { $_.Name -ceq 'ExpectGuestPowerOff' }) | Select-Object -First 1
    $expectation -and $expectation.Value -is [bool] -and [bool]$expectation.Value
}

function ConvertTo-BrokerTimestampText {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime().ToString('o') }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime.ToString('o') }
    [string]$Value
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
$liveEvidenceModulePath = Join-Path $PSScriptRoot 'LiveEvidence.ps1'
if (-not (Test-Path -LiteralPath $liveEvidenceModulePath -PathType Leaf)) {
    throw "Live-evidence module not found: $liveEvidenceModulePath"
}
. $liveEvidenceModulePath
$null = Initialize-LiveEvidenceDirectories -BrokerRoot $BrokerRoot

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
        [string] $GuestActionType = $null,
        [Nullable[bool]] $ExpectGuestPowerOff = $null,
        [string] $ExpectedGuestPowerOffSubmissionStartedUtc = $null,
        [Nullable[bool]] $GuestJobMayHaveLaunched = $null,
        [string] $GuestApplicationEraRunningObservedUtc = $null,
        [string] $GuestPowerOffObservedUtc = $null,
        [Nullable[bool]] $GuestPowerOffBeforeCleanup = $null,
        [string] $PowerOffRecoveryDeadlineUtc = $null,
        [string] $BrokerCleanupStartedUtc = $null
    )

    $requestStateBoundParameters = @{} + $PSBoundParameters
    Invoke-WithTerminalResultPublicationMutex -RequestId $RequestId -ScopeRoot $ResultRoot -Operation {
    $requestStatePath = Join-Path $ResultRoot 'request-state.json'
    if (Test-Path -LiteralPath (Join-Path $ResultRoot 'broker-result.json') -PathType Leaf) {
        # A terminal marker closes the request-state transaction. Refuse all
        # later mutations so recovery and a surviving worker cannot publish
        # contradictory terminal state/evidence combinations.
        return
    }
    $previousState = $null
    if (Test-Path -LiteralPath $requestStatePath -PathType Leaf) {
        # Never overwrite a durable at-most-once marker merely because a
        # concurrent reader caught a transient replace/ACL race.
        $previousState = Read-BrokerJsonWithRetry -Path $requestStatePath
    }
    $previousPowerOffProperties = @{}
    foreach ($propertyName in @(
        'ExpectGuestPowerOff',
        'ExpectedGuestPowerOffSubmissionStartedUtc',
        'GuestJobMayHaveLaunched',
        'GuestApplicationEraRunningObservedUtc',
        'GuestPowerOffObservedUtc',
        'GuestPowerOffBeforeCleanup',
        'PowerOffRecoveryDeadlineUtc',
        'BrokerCleanupStartedUtc'
    )) {
        $previousPowerOffProperties[$propertyName] = if ($previousState) {
            @($previousState.PSObject.Properties | Where-Object { $_.Name -ceq $propertyName }) | Select-Object -First 1
        }
        else { $null }
    }
    foreach ($booleanPropertyName in @('ExpectGuestPowerOff', 'GuestJobMayHaveLaunched', 'GuestPowerOffBeforeCleanup')) {
        $booleanProperty = $previousPowerOffProperties[$booleanPropertyName]
        if ($booleanProperty -and $null -ne $booleanProperty.Value -and $booleanProperty.Value -isnot [bool]) {
            throw "Persisted request state property $booleanPropertyName must be an exact JSON Boolean or null."
        }
    }
    $previousPowerOffContract = [ordered]@{
        ExpectGuestPowerOff = if ($previousPowerOffProperties.ExpectGuestPowerOff) { $previousPowerOffProperties.ExpectGuestPowerOff.Value } else { $null }
        ExpectedGuestPowerOffSubmissionStartedUtc = if ($previousPowerOffProperties.ExpectedGuestPowerOffSubmissionStartedUtc) { ConvertTo-BrokerTimestampText $previousPowerOffProperties.ExpectedGuestPowerOffSubmissionStartedUtc.Value } else { $null }
        GuestJobMayHaveLaunched = if ($previousPowerOffProperties.GuestJobMayHaveLaunched) { $previousPowerOffProperties.GuestJobMayHaveLaunched.Value } else { $null }
        GuestApplicationEraRunningObservedUtc = if ($previousPowerOffProperties.GuestApplicationEraRunningObservedUtc) { ConvertTo-BrokerTimestampText $previousPowerOffProperties.GuestApplicationEraRunningObservedUtc.Value } else { $null }
        GuestPowerOffObservedUtc = if ($previousPowerOffProperties.GuestPowerOffObservedUtc) { ConvertTo-BrokerTimestampText $previousPowerOffProperties.GuestPowerOffObservedUtc.Value } else { $null }
        GuestPowerOffBeforeCleanup = if ($previousPowerOffProperties.GuestPowerOffBeforeCleanup) { $previousPowerOffProperties.GuestPowerOffBeforeCleanup.Value } else { $null }
        PowerOffRecoveryDeadlineUtc = if ($previousPowerOffProperties.PowerOffRecoveryDeadlineUtc) { ConvertTo-BrokerTimestampText $previousPowerOffProperties.PowerOffRecoveryDeadlineUtc.Value } else { $null }
        BrokerCleanupStartedUtc = if ($previousPowerOffProperties.BrokerCleanupStartedUtc) { ConvertTo-BrokerTimestampText $previousPowerOffProperties.BrokerCleanupStartedUtc.Value } else { $null }
    }

    $resetWorker = $Status -in @('Submitted', 'Queued', 'RetryQueued')
    $effectiveWorkerId = if ($requestStateBoundParameters.ContainsKey('WorkerId')) {
        if ($null -ne $WorkerId) { [int]$WorkerId } else { $null }
    }
    elseif (-not $resetWorker -and $previousState -and $null -ne $previousState.WorkerId) {
        [int]$previousState.WorkerId
    }
    else { $null }

    $resetApplication = $Status -in @('Submitted', 'Queued', 'RetryQueued', 'Claimed', 'RetryPendingRecycle')
    $effectiveApplicationProcessId = if ($requestStateBoundParameters.ContainsKey('ApplicationProcessId')) {
        if ($null -ne $ApplicationProcessId) { [int]$ApplicationProcessId } else { $null }
    }
    elseif (-not $resetApplication -and $previousState -and $null -ne $previousState.ApplicationProcessId) {
        [int]$previousState.ApplicationProcessId
    }
    else { $null }
    $effectiveApplicationStartedUtc = if ($requestStateBoundParameters.ContainsKey('ApplicationStartedUtc')) {
        if ([string]::IsNullOrWhiteSpace($ApplicationStartedUtc)) { $null } else { $ApplicationStartedUtc }
    }
    elseif (-not $resetApplication -and $previousState) {
        if ([string]::IsNullOrWhiteSpace([string]$previousState.ApplicationStartedUtc)) { $null } else { [string]$previousState.ApplicationStartedUtc }
    }
    else { $null }

    # Exact-power-off at-most-once evidence is monotonic for the lifetime of a
    # RequestId. Queue duplicates, retry bookkeeping, or stale writers may add
    # evidence, but they may never clear or downgrade an existing marker.
    $effectiveExpectGuestPowerOff = if ($previousPowerOffContract.ExpectGuestPowerOff -is [bool] -and [bool]$previousPowerOffContract.ExpectGuestPowerOff) {
        [Nullable[bool]]$true
    }
    elseif ($requestStateBoundParameters.ContainsKey('ExpectGuestPowerOff')) {
        if ($null -ne $ExpectGuestPowerOff) { [Nullable[bool]]([bool]$ExpectGuestPowerOff) } else { $null }
    }
    elseif ($null -ne $previousPowerOffContract.ExpectGuestPowerOff) {
        [Nullable[bool]]([bool]$previousPowerOffContract.ExpectGuestPowerOff)
    }
    else { $null }
    $effectiveExpectedPowerOffSubmissionStartedUtc = if (-not [string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.ExpectedGuestPowerOffSubmissionStartedUtc)) {
        [string]$previousPowerOffContract.ExpectedGuestPowerOffSubmissionStartedUtc
    }
    elseif ($requestStateBoundParameters.ContainsKey('ExpectedGuestPowerOffSubmissionStartedUtc')) {
        if ([string]::IsNullOrWhiteSpace($ExpectedGuestPowerOffSubmissionStartedUtc)) { $null } else { $ExpectedGuestPowerOffSubmissionStartedUtc }
    }
    else { $null }
    $effectiveGuestJobMayHaveLaunched = if ($previousPowerOffContract.GuestJobMayHaveLaunched -is [bool] -and [bool]$previousPowerOffContract.GuestJobMayHaveLaunched) {
        [Nullable[bool]]$true
    }
    elseif ($requestStateBoundParameters.ContainsKey('GuestJobMayHaveLaunched')) {
        if ($null -ne $GuestJobMayHaveLaunched) { [Nullable[bool]]([bool]$GuestJobMayHaveLaunched) } else { $null }
    }
    elseif ($null -ne $previousPowerOffContract.GuestJobMayHaveLaunched) {
        [Nullable[bool]]([bool]$previousPowerOffContract.GuestJobMayHaveLaunched)
    }
    else { $null }
    $effectiveApplicationEraRunningObservedUtc = if (-not [string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.GuestApplicationEraRunningObservedUtc)) {
        [string]$previousPowerOffContract.GuestApplicationEraRunningObservedUtc
    }
    elseif ($requestStateBoundParameters.ContainsKey('GuestApplicationEraRunningObservedUtc')) {
        if ([string]::IsNullOrWhiteSpace($GuestApplicationEraRunningObservedUtc)) { $null } else { $GuestApplicationEraRunningObservedUtc }
    }
    else { $null }
    $effectiveGuestPowerOffObservedUtc = if (-not [string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.GuestPowerOffObservedUtc)) {
        [string]$previousPowerOffContract.GuestPowerOffObservedUtc
    }
    elseif ($requestStateBoundParameters.ContainsKey('GuestPowerOffObservedUtc')) {
        if ([string]::IsNullOrWhiteSpace($GuestPowerOffObservedUtc)) { $null } else { $GuestPowerOffObservedUtc }
    }
    else { $null }
    $effectiveGuestPowerOffBeforeCleanup = if ($previousPowerOffContract.GuestPowerOffBeforeCleanup -is [bool] -and [bool]$previousPowerOffContract.GuestPowerOffBeforeCleanup) {
        [Nullable[bool]]$true
    }
    elseif ($requestStateBoundParameters.ContainsKey('GuestPowerOffBeforeCleanup')) {
        if ($null -ne $GuestPowerOffBeforeCleanup) { [Nullable[bool]]([bool]$GuestPowerOffBeforeCleanup) } else { $null }
    }
    elseif ($null -ne $previousPowerOffContract.GuestPowerOffBeforeCleanup) {
        [Nullable[bool]]([bool]$previousPowerOffContract.GuestPowerOffBeforeCleanup)
    }
    else { $null }
    $effectivePowerOffRecoveryDeadlineUtc = if (-not [string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.PowerOffRecoveryDeadlineUtc)) {
        [string]$previousPowerOffContract.PowerOffRecoveryDeadlineUtc
    }
    elseif ($requestStateBoundParameters.ContainsKey('PowerOffRecoveryDeadlineUtc')) {
        if ([string]::IsNullOrWhiteSpace($PowerOffRecoveryDeadlineUtc)) { $null } else { $PowerOffRecoveryDeadlineUtc }
    }
    else { $null }
    $effectiveBrokerCleanupStartedUtc = if (-not [string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.BrokerCleanupStartedUtc)) {
        [string]$previousPowerOffContract.BrokerCleanupStartedUtc
    }
    elseif ($requestStateBoundParameters.ContainsKey('BrokerCleanupStartedUtc')) {
        if ([string]::IsNullOrWhiteSpace($BrokerCleanupStartedUtc)) { $null } else { $BrokerCleanupStartedUtc }
    }
    else { $null }

    $hasPowerOffContract = $null -ne $effectiveExpectGuestPowerOff -or
        -not [string]::IsNullOrWhiteSpace($effectiveExpectedPowerOffSubmissionStartedUtc) -or
        $null -ne $effectiveGuestJobMayHaveLaunched -or
        -not [string]::IsNullOrWhiteSpace($effectiveApplicationEraRunningObservedUtc) -or
        -not [string]::IsNullOrWhiteSpace($effectiveGuestPowerOffObservedUtc) -or
        $null -ne $effectiveGuestPowerOffBeforeCleanup -or
        -not [string]::IsNullOrWhiteSpace($effectivePowerOffRecoveryDeadlineUtc) -or
        -not [string]::IsNullOrWhiteSpace($effectiveBrokerCleanupStartedUtc)

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
        ExpectGuestPowerOff = if ($null -ne $effectiveExpectGuestPowerOff) { [bool]$effectiveExpectGuestPowerOff } else { $null }
        ExpectedGuestPowerOffSubmissionStartedUtc = $effectiveExpectedPowerOffSubmissionStartedUtc
        GuestJobMayHaveLaunched = if ($null -ne $effectiveGuestJobMayHaveLaunched) { [bool]$effectiveGuestJobMayHaveLaunched } else { $null }
        GuestApplicationEraRunningObservedUtc = $effectiveApplicationEraRunningObservedUtc
        GuestPowerOffObservedUtc = $effectiveGuestPowerOffObservedUtc
        GuestPowerOffBeforeCleanup = if ($null -ne $effectiveGuestPowerOffBeforeCleanup) { [bool]$effectiveGuestPowerOffBeforeCleanup } else { $null }
        PowerOffRecoveryDeadlineUtc = $effectivePowerOffRecoveryDeadlineUtc
        BrokerCleanupStartedUtc = $effectiveBrokerCleanupStartedUtc
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
            ExpectGuestPowerOff = if ($null -ne $previousPowerOffContract.ExpectGuestPowerOff) { [bool]$previousPowerOffContract.ExpectGuestPowerOff } else { $null }
            ExpectedGuestPowerOffSubmissionStartedUtc = if ([string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.ExpectedGuestPowerOffSubmissionStartedUtc)) { $null } else { [string]$previousPowerOffContract.ExpectedGuestPowerOffSubmissionStartedUtc }
            GuestJobMayHaveLaunched = if ($null -ne $previousPowerOffContract.GuestJobMayHaveLaunched) { [bool]$previousPowerOffContract.GuestJobMayHaveLaunched } else { $null }
            GuestApplicationEraRunningObservedUtc = if ([string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.GuestApplicationEraRunningObservedUtc)) { $null } else { [string]$previousPowerOffContract.GuestApplicationEraRunningObservedUtc }
            GuestPowerOffObservedUtc = if ([string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.GuestPowerOffObservedUtc)) { $null } else { [string]$previousPowerOffContract.GuestPowerOffObservedUtc }
            GuestPowerOffBeforeCleanup = if ($null -ne $previousPowerOffContract.GuestPowerOffBeforeCleanup) { [bool]$previousPowerOffContract.GuestPowerOffBeforeCleanup } else { $null }
            PowerOffRecoveryDeadlineUtc = if ([string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.PowerOffRecoveryDeadlineUtc)) { $null } else { [string]$previousPowerOffContract.PowerOffRecoveryDeadlineUtc }
            BrokerCleanupStartedUtc = if ([string]::IsNullOrWhiteSpace([string]$previousPowerOffContract.BrokerCleanupStartedUtc)) { $null } else { [string]$previousPowerOffContract.BrokerCleanupStartedUtc }
        }
    }
    else { $null }
    $stateChanged = -not $previousState -or
        ($currentComparable | ConvertTo-Json -Depth 4 -Compress) -ne ($previousComparable | ConvertTo-Json -Depth 4 -Compress)
    $revision = if ($previousState -and $null -ne $previousState.Revision) { [int64]$previousState.Revision } else { 0 }
    $history = @(if ($previousState -and $previousState.History) { $previousState.History | Where-Object { $null -ne $_ } })
    if ($stateChanged) {
        $revision++
        $historyEntry = [ordered]@{
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
        if ($hasPowerOffContract) {
            $historyEntry['ExpectGuestPowerOff'] = $currentComparable.ExpectGuestPowerOff
            $historyEntry['ExpectedGuestPowerOffSubmissionStartedUtc'] = $effectiveExpectedPowerOffSubmissionStartedUtc
            $historyEntry['GuestJobMayHaveLaunched'] = $currentComparable.GuestJobMayHaveLaunched
            $historyEntry['GuestApplicationEraRunningObservedUtc'] = $effectiveApplicationEraRunningObservedUtc
            $historyEntry['GuestPowerOffObservedUtc'] = $effectiveGuestPowerOffObservedUtc
            $historyEntry['GuestPowerOffBeforeCleanup'] = $currentComparable.GuestPowerOffBeforeCleanup
            $historyEntry['PowerOffRecoveryDeadlineUtc'] = $effectivePowerOffRecoveryDeadlineUtc
            $historyEntry['BrokerCleanupStartedUtc'] = $effectiveBrokerCleanupStartedUtc
        }
        $history += [pscustomobject]$historyEntry
        if ($history.Count -gt 128) {
            $history = @($history[($history.Count - 128)..($history.Count - 1)])
        }
    }

    $stateEnvelope = [ordered]@{
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
    }
    if ($hasPowerOffContract) {
        $stateEnvelope['ExpectGuestPowerOff'] = if ($null -ne $effectiveExpectGuestPowerOff) { [bool]$effectiveExpectGuestPowerOff } else { $null }
        $stateEnvelope['ExpectedGuestPowerOffSubmissionStartedUtc'] = $effectiveExpectedPowerOffSubmissionStartedUtc
        $stateEnvelope['GuestJobMayHaveLaunched'] = if ($null -ne $effectiveGuestJobMayHaveLaunched) { [bool]$effectiveGuestJobMayHaveLaunched } else { $null }
        $stateEnvelope['GuestApplicationEraRunningObservedUtc'] = $effectiveApplicationEraRunningObservedUtc
        $stateEnvelope['GuestPowerOffObservedUtc'] = $effectiveGuestPowerOffObservedUtc
        $stateEnvelope['GuestPowerOffBeforeCleanup'] = if ($null -ne $effectiveGuestPowerOffBeforeCleanup) { [bool]$effectiveGuestPowerOffBeforeCleanup } else { $null }
        $stateEnvelope['PowerOffRecoveryDeadlineUtc'] = $effectivePowerOffRecoveryDeadlineUtc
        $stateEnvelope['BrokerCleanupStartedUtc'] = $effectiveBrokerCleanupStartedUtc
    }
    Write-JsonAtomic -Path $requestStatePath -Value $stateEnvelope
    }
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

function Get-ExpectedGuestPowerOffObservation {
    param(
        [Parameter(Mandatory = $true)] [bool] $Enabled,
        [Parameter(Mandatory = $true)] [string] $VmState,
        [Parameter(Mandatory = $true)] [bool] $ApplicationConfirmed,
        [AllowNull()] [string] $ApplicationEraRunningObservedUtc,
        [AllowNull()] [string] $BrokerCleanupStartedUtc
    )

    $observation = [ordered]@{
        Action = 'None'
        FailureKind = $null
        Message = $null
    }
    if (-not $Enabled) {
        return [pscustomobject]$observation
    }

    if ([string]::Equals($VmState, 'Running', [StringComparison]::OrdinalIgnoreCase)) {
        if ($ApplicationConfirmed -and [string]::IsNullOrWhiteSpace($ApplicationEraRunningObservedUtc)) {
            $observation.Action = 'RecordApplicationEraRunning'
        }
        return [pscustomobject]$observation
    }

    if (-not [string]::Equals($VmState, 'Off', [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]$observation
    }

    if (-not [string]::IsNullOrWhiteSpace($BrokerCleanupStartedUtc)) {
        $observation.Action = 'Fail'
        $observation.FailureKind = 'ExpectedGuestPowerOffAfterCleanup'
        $observation.Message = 'The VM reached Off only after broker cleanup began, so guest shutdown causality was not proven.'
    }
    elseif (-not $ApplicationConfirmed) {
        $observation.Action = 'Fail'
        $observation.FailureKind = 'ExpectedGuestPowerOffPremature'
        $observation.Message = 'The VM powered off before the broker confirmed that the application started.'
    }
    elseif ([string]::IsNullOrWhiteSpace($ApplicationEraRunningObservedUtc)) {
        $observation.Action = 'Fail'
        $observation.FailureKind = 'ExpectedGuestPowerOffUnproven'
        $observation.Message = 'The VM powered off without a broker-observed application-era Running state.'
    }
    else {
        $observation.Action = 'RecordGuestPowerOff'
    }
    [pscustomobject]$observation
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
        $deadlineException = [TimeoutException]::new("Execution timeout expired for request $RequestId.")
        $deadlineException.Data['CodexBrokerDeadlineExpired'] = $true
        throw $deadlineException
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

function Get-InterruptedExpectedGuestPowerOffRecoveryClassification {
    [CmdletBinding()]
    param(
        [AllowNull()] $Request,
        [AllowNull()] $RequestState
    )

    $classification = [ordered]@{
        Disposition = 'NotApplicable'
        State = $RequestState
        Reason = $null
    }
    if (-not $Request) { return [pscustomobject]$classification }
    $requestExpectation = @($Request.PSObject.Properties | Where-Object { $_.Name -ceq 'ExpectGuestPowerOff' }) | Select-Object -First 1
    if (-not $requestExpectation -or $requestExpectation.Value -isnot [bool] -or -not [bool]$requestExpectation.Value) {
        return [pscustomobject]$classification
    }
    if (-not $RequestState) {
        $classification.Disposition = 'Invalid'
        $classification.Reason = 'The exact expected-power-off request has no readable durable request state.'
        return [pscustomobject]$classification
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
    foreach ($contractPropertyName in $contractPropertyNames) {
        $caseInsensitiveMatches = @($RequestState.PSObject.Properties | Where-Object { [string]::Equals($_.Name, $contractPropertyName, [StringComparison]::OrdinalIgnoreCase) })
        if ($caseInsensitiveMatches.Count -gt 1 -or ($caseInsensitiveMatches.Count -eq 1 -and $caseInsensitiveMatches[0].Name -cne $contractPropertyName)) {
            $classification.Disposition = 'Invalid'
            $classification.Reason = "Persisted expected-power-off property $contractPropertyName is duplicated or has incorrect casing."
            return [pscustomobject]$classification
        }
    }

    $stateExpectation = @($RequestState.PSObject.Properties | Where-Object { $_.Name -ceq 'ExpectGuestPowerOff' }) | Select-Object -First 1
    $timestampNames = @(
        'ExpectedGuestPowerOffSubmissionStartedUtc',
        'GuestApplicationEraRunningObservedUtc',
        'GuestPowerOffObservedUtc',
        'PowerOffRecoveryDeadlineUtc',
        'BrokerCleanupStartedUtc'
    )
    $timestampValues = @{}
    foreach ($timestampName in $timestampNames) {
        $property = @($RequestState.PSObject.Properties | Where-Object { $_.Name -ceq $timestampName }) | Select-Object -First 1
        if (-not $property -or $null -eq $property.Value) {
            $timestampValues[$timestampName] = $null
            continue
        }
        if ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $classification.Disposition = 'Invalid'
            $classification.Reason = "Persisted expected-power-off property $timestampName must be a non-empty timestamp string or null."
            return [pscustomobject]$classification
        }
        try { $null = [DateTimeOffset]::Parse([string]$property.Value, [Globalization.CultureInfo]::InvariantCulture) }
        catch {
            $classification.Disposition = 'Invalid'
            $classification.Reason = "Persisted expected-power-off property $timestampName is not a valid timestamp."
            return [pscustomobject]$classification
        }
        $timestampValues[$timestampName] = [string]$property.Value
    }

    $booleanValues = @{}
    foreach ($booleanName in @('GuestJobMayHaveLaunched', 'GuestPowerOffBeforeCleanup')) {
        $property = @($RequestState.PSObject.Properties | Where-Object { $_.Name -ceq $booleanName }) | Select-Object -First 1
        if (-not $property -or $null -eq $property.Value) {
            $booleanValues[$booleanName] = $null
            continue
        }
        if ($property.Value -isnot [bool]) {
            $classification.Disposition = 'Invalid'
            $classification.Reason = "Persisted expected-power-off property $booleanName must be an exact JSON Boolean or null."
            return [pscustomobject]$classification
        }
        $booleanValues[$booleanName] = [bool]$property.Value
    }

    $hasAnyContractMarker = @($timestampValues.Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0 -or
        @($booleanValues.Values | Where-Object { $null -ne $_ }).Count -gt 0
    if ($stateExpectation) {
        if ($null -eq $stateExpectation.Value -or $stateExpectation.Value -isnot [bool] -or -not [bool]$stateExpectation.Value) {
            $classification.Disposition = 'Invalid'
            $classification.Reason = 'Persisted exact expected-power-off state must attest exact Boolean ExpectGuestPowerOff=true.'
            return [pscustomobject]$classification
        }
    }
    elseif ($hasAnyContractMarker) {
        $classification.Disposition = 'Invalid'
        $classification.Reason = 'Persisted expected-power-off lifecycle markers exist without exact Boolean ExpectGuestPowerOff=true.'
        return [pscustomobject]$classification
    }

    $submissionStarted = -not [string]::IsNullOrWhiteSpace([string]$timestampValues.ExpectedGuestPowerOffSubmissionStartedUtc)
    $mayHaveLaunched = $booleanValues.GuestJobMayHaveLaunched -is [bool] -and [bool]$booleanValues.GuestJobMayHaveLaunched
    $mayHaveLaunchedProperty = @($RequestState.PSObject.Properties | Where-Object { $_.Name -ceq 'GuestJobMayHaveLaunched' }) | Select-Object -First 1
    if ($mayHaveLaunchedProperty -and $mayHaveLaunchedProperty.Value -is [bool] -and -not [bool]$mayHaveLaunchedProperty.Value) {
        $classification.Disposition = 'Invalid'
        $classification.Reason = 'Persisted exact expected-power-off state cannot contain GuestJobMayHaveLaunched=false.'
        return [pscustomobject]$classification
    }
    if ($submissionStarted -ne $mayHaveLaunched) {
        $classification.Disposition = 'Invalid'
        $classification.Reason = 'Persisted expected-power-off submission ambiguity markers are incomplete or contradictory.'
        return [pscustomobject]$classification
    }

    $applicationRunning = -not [string]::IsNullOrWhiteSpace([string]$timestampValues.GuestApplicationEraRunningObservedUtc)
    $powerOffObserved = -not [string]::IsNullOrWhiteSpace([string]$timestampValues.GuestPowerOffObservedUtc)
    $powerOffBeforeCleanup = $booleanValues.GuestPowerOffBeforeCleanup -is [bool] -and [bool]$booleanValues.GuestPowerOffBeforeCleanup
    $powerOffBeforeCleanupProperty = @($RequestState.PSObject.Properties | Where-Object { $_.Name -ceq 'GuestPowerOffBeforeCleanup' }) | Select-Object -First 1
    if ($powerOffBeforeCleanupProperty -and $powerOffBeforeCleanupProperty.Value -is [bool] -and -not [bool]$powerOffBeforeCleanupProperty.Value) {
        $classification.Disposition = 'Invalid'
        $classification.Reason = 'Persisted exact expected-power-off state cannot contain GuestPowerOffBeforeCleanup=false.'
        return [pscustomobject]$classification
    }
    $recoveryDeadline = -not [string]::IsNullOrWhiteSpace([string]$timestampValues.PowerOffRecoveryDeadlineUtc)
    $cleanupStarted = -not [string]::IsNullOrWhiteSpace([string]$timestampValues.BrokerCleanupStartedUtc)
    if (($applicationRunning -and -not $submissionStarted) -or
        ($powerOffObserved -and (-not $applicationRunning -or -not $powerOffBeforeCleanup)) -or
        ($powerOffBeforeCleanup -and -not $powerOffObserved) -or
        ($recoveryDeadline -and -not $powerOffObserved) -or
        ($cleanupStarted -and -not $submissionStarted)) {
        $classification.Disposition = 'Invalid'
        $classification.Reason = 'Persisted expected-power-off lifecycle markers are out of order or incomplete.'
        return [pscustomobject]$classification
    }

    if ($stateExpectation -and -not $submissionStarted) {
        $classification.Disposition = 'Invalid'
        $classification.Reason = 'Persisted ExpectGuestPowerOff=true is incomplete without the paired durable delivery ambiguity markers.'
        return [pscustomobject]$classification
    }

    $classification.Disposition = if ($submissionStarted -or $applicationRunning -or $powerOffObserved -or $cleanupStarted) { 'ProtectedNoReplay' } else { 'SafePreDelivery' }
    [pscustomobject]$classification
}

function Get-InterruptedExpectedGuestPowerOffNoReplayState {
    [CmdletBinding()]
    param(
        [AllowNull()] $Request,
        [AllowNull()] $RequestState
    )

    $classification = Get-InterruptedExpectedGuestPowerOffRecoveryClassification -Request $Request -RequestState $RequestState
    if ([string]$classification.Disposition -eq 'ProtectedNoReplay') { return $RequestState }
    $null
}

function Move-QueuedRequestWithTerminalResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [IO.FileInfo] $QueuedFile,
        [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')] [string] $RequestId,
        [string] $Reason = 'terminal-duplicate'
    )

    $terminalResultPath = Join-Path (Join-Path $resultsPath $RequestId) 'broker-result.json'
    if (-not (Test-Path -LiteralPath $terminalResultPath -PathType Leaf)) {
        return $false
    }

    if (Test-Path -LiteralPath $QueuedFile.FullName -PathType Leaf) {
        $safeReason = if ($Reason -match '^[A-Za-z0-9_-]{1,64}$') { $Reason } else { 'terminal-duplicate' }
        $destination = Join-Path $archivePath ($RequestId + '-' + $safeReason + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
        Move-Item -LiteralPath $QueuedFile.FullName -Destination $destination -Force -ErrorAction Stop
    }
    $true
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
    $interruptedTerminal = @{}
    foreach ($unfinishedFile in $unfinishedFiles) {
        $unfinishedRequestId = [IO.Path]::GetFileNameWithoutExtension($unfinishedFile.Name)
        if ($unfinishedRequestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') { continue }
        $unfinishedResultRoot = Join-Path $resultsPath $unfinishedRequestId
        $unfinishedStatePath = Join-Path $unfinishedResultRoot 'request-state.json'
        $unfinishedRequest = $null
        $unfinishedState = $null
        try {
            $unfinishedRequest = Read-BrokerJsonWithRetry -Path $unfinishedFile.FullName
        }
        catch {
            $interruptedTerminal[$unfinishedRequestId] = [pscustomobject]@{
                Request = $null
                State = $null
                FailureKind = 'InterruptedRequestUnreadable'
                Message = 'The interrupted processing request could not be read reliably. It was failed terminally and quarantined rather than risk replaying an unknown application job.'
            }
            continue
        }
        if (Test-Path -LiteralPath $unfinishedStatePath -PathType Leaf) {
            try {
                $unfinishedState = Read-BrokerJsonWithRetry -Path $unfinishedStatePath
            }
            catch {
                $interruptedTerminal[$unfinishedRequestId] = [pscustomobject]@{
                    Request = $unfinishedRequest
                    State = $null
                    FailureKind = 'InterruptedRequestStateUnreadable'
                    Message = 'The interrupted request state remained unreadable after bounded retries. It was failed terminally because replay safety could not be established.'
                }
                continue
            }
        }
        elseif (Test-ExactExpectedGuestPowerOffRequest -Request $unfinishedRequest) {
            $interruptedTerminal[$unfinishedRequestId] = [pscustomobject]@{
                Request = $unfinishedRequest
                State = $null
                FailureKind = 'ExpectedGuestPowerOffStateMissing'
                Message = 'The exact expected-power-off request had no durable state after broker interruption. It was failed terminally because a prior launch could not be excluded.'
            }
            continue
        }
        $powerOffRecoveryClassification = Get-InterruptedExpectedGuestPowerOffRecoveryClassification -Request $unfinishedRequest -RequestState $unfinishedState
        if ([string]$powerOffRecoveryClassification.Disposition -eq 'Invalid') {
            $interruptedTerminal[$unfinishedRequestId] = [pscustomobject]@{
                Request = $unfinishedRequest
                State = $unfinishedState
                FailureKind = 'ExpectedGuestPowerOffStateInvalid'
                Message = ([string]$powerOffRecoveryClassification.Reason + ' The request was failed terminally because a prior application launch cannot be excluded safely.')
            }
            continue
        }
        $protectedState = if ([string]$powerOffRecoveryClassification.Disposition -eq 'ProtectedNoReplay') { $unfinishedState } else { $null }
        if ($protectedState) {
            $applicationRunningPersisted = -not [string]::IsNullOrWhiteSpace([string]$protectedState.GuestApplicationEraRunningObservedUtc)
            $submissionAmbiguous = -not [string]::IsNullOrWhiteSpace([string]$protectedState.ExpectedGuestPowerOffSubmissionStartedUtc) -and
                $protectedState.PSObject.Properties['GuestJobMayHaveLaunched'] -and
                $protectedState.GuestJobMayHaveLaunched -is [bool] -and [bool]$protectedState.GuestJobMayHaveLaunched
            $shutdownBeforeCleanupProperty = $protectedState.PSObject.Properties['GuestPowerOffBeforeCleanup']
            $causalPowerOffPersisted = -not [string]::IsNullOrWhiteSpace([string]$protectedState.GuestPowerOffObservedUtc) -and
                $shutdownBeforeCleanupProperty -and $shutdownBeforeCleanupProperty.Value -is [bool] -and [bool]$shutdownBeforeCleanupProperty.Value
            $interruptedTerminal[$unfinishedRequestId] = [pscustomobject]@{
                Request = $unfinishedRequest
                State = $protectedState
                FailureKind = if ($causalPowerOffPersisted) { 'GuestPowerOffEvidenceRecoveryInterrupted' } elseif ($applicationRunningPersisted) { 'ExpectedGuestPowerOffBrokerInterrupted' } else { 'ExpectedGuestPowerOffSubmissionInterrupted' }
                Message = if ($causalPowerOffPersisted) {
                    'The broker restarted after host-observed application-era Running-to-Off causality but before evidence recovery completed. The request was failed terminally and will not be replayed.'
                }
                elseif ($applicationRunningPersisted) {
                    'The broker restarted after the expected-power-off application was confirmed running. A later shutdown may already have been scheduled, so the request was failed terminally and will not be replayed.'
                }
                elseif ($submissionAmbiguous) {
                    'The broker restarted after expected-power-off job delivery began but before launch outcome was known. The request was failed terminally and will not be replayed.'
                }
                else {
                    'The broker restarted with ambiguous expected-power-off delivery state. The request was failed terminally and will not be replayed.'
                }
            }
        }
    }
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
        if ($interruptedTerminal.ContainsKey($requestId)) {
            $protected = $interruptedTerminal[$requestId]
            $protectedState = $protected.State
            $protectedRequest = $protected.Request
            $interruptedCleanup = Invoke-InterruptedRequestCleanup -BrokerRoot $BrokerRoot -VmName ([string]$Config.VmName) -RequestId $requestId
            Publish-InterruptedRequestTerminalResult -ResultRoot $resultRoot -RequestId $requestId -Request $protectedRequest -RequestState $protectedState -FailureKind ([string]$protected.FailureKind) -FailureStage 'BrokerRestartRecovery' -Message ([string]$protected.Message) -VmName ([string]$Config.VmName) -Cleanup $interruptedCleanup | Out-Null
            $archiveFile = Join-Path $archivePath ($requestId + '-recovered-expected-poweroff-interrupted-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
            Move-Item -LiteralPath $processingFile.FullName -Destination $archiveFile -Force
            $queuedFile = Join-Path $requestPath $processingFile.Name
            if (Test-Path -LiteralPath $queuedFile -PathType Leaf) {
                Move-Item -LiteralPath $queuedFile -Destination (Join-Path $archivePath ($requestId + '-recovered-expected-poweroff-queued-duplicate-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')) -Force
            }
            try { Remove-StagedPayloadSafe -RequestId $requestId } catch { }
            continue
        }
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
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Value)

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
        [Parameter(Mandatory = $true)] [string] $OutputPath,
        [string] $InboxFile,
        [string] $ProcessingFile,
        [string] $CompletedFile,
        [string] $Outbox
    )

    $probeTemplate = @'
$ErrorActionPreference = 'Stop'
$outputPath = __OUTPUT_PATH__
$exitCode = 0
try {
    $credentialData = Get-Content -Raw -LiteralPath __CREDENTIAL_PATH__ | ConvertFrom-Json
    $securePassword = ConvertTo-SecureString ([string]$credentialData.Password) -AsPlainText -Force
    $credential = New-Object Management.Automation.PSCredential([string]$credentialData.UserName, $securePassword)
    $probeData = Invoke-Command -VMName __VM_NAME__ -Credential $credential -ErrorAction Stop -ScriptBlock {
        param($InboxFile, $ProcessingFile, $CompletedFile, $Outbox)
        $statePath = 'C:\CodexGuest\agent-state.json'
        $state = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        }
        else { $null }
        $currentGuestUtc = [DateTime]::UtcNow
        $agentAlive = $false
        $agentHeartbeatAgeSeconds = $null
        if ($state -and $state.ProcessId) {
            $agentAlive = $null -ne (Get-Process -Id ([int]$state.ProcessId) -ErrorAction SilentlyContinue)
            try {
                $agentHeartbeatUtc = [DateTimeOffset]::Parse([string]$state.HeartbeatUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                $agentHeartbeatAgeSeconds = [Math]::Max(0, ($currentGuestUtc - $agentHeartbeatUtc).TotalSeconds)
                if ($agentHeartbeatAgeSeconds -le 5) { $agentAlive = $true }
            }
            catch { }
        }
        $applicationLease = $null
        if (-not [string]::IsNullOrWhiteSpace($Outbox)) {
            try {
                $leasePath = Join-Path $Outbox 'lease.json'
                if (Test-Path -LiteralPath $leasePath -PathType Leaf) {
                    $applicationLease = Get-Content -Raw -LiteralPath $leasePath | ConvertFrom-Json
                }
            }
            catch { $applicationLease = $null }
        }
        $bootValue = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $bootTime = if ($bootValue -is [DateTime]) {
            [DateTime]$bootValue
        }
        else {
            [Management.ManagementDateTimeConverter]::ToDateTime([string]$bootValue)
        }
        [ordered]@{
            State = $state
            CurrentGuestBootTimeUtc = $bootTime.ToUniversalTime().ToString('o')
            CurrentGuestUtc = $currentGuestUtc.ToString('o')
            AgentAlive = [bool]$agentAlive
            AgentHeartbeatAgeSeconds = $agentHeartbeatAgeSeconds
            ApplicationLease = $applicationLease
            Presence = if ([string]::IsNullOrWhiteSpace($Outbox)) {
                $null
            }
            else {
                [ordered]@{
                    Inbox = Test-Path -LiteralPath $InboxFile -PathType Leaf
                    Processing = Test-Path -LiteralPath $ProcessingFile -PathType Leaf
                    Completed = Test-Path -LiteralPath $CompletedFile -PathType Leaf
                    Result = Test-Path -LiteralPath (Join-Path $Outbox 'result.json') -PathType Leaf
                    AgentError = Test-Path -LiteralPath (Join-Path $Outbox 'agent-error.json') -PathType Leaf
                }
            }
        }
    } -ArgumentList __INBOX_FILE__, __PROCESSING_FILE__, __COMPLETED_FILE__, __OUTBOX__ | Select-Object -Last 1
    $result = [ordered]@{
        Success = $true
        State = $probeData.State
        CurrentGuestBootTimeUtc = [string]$probeData.CurrentGuestBootTimeUtc
        CurrentGuestUtc = [string]$probeData.CurrentGuestUtc
        AgentAlive = [bool]$probeData.AgentAlive
        AgentHeartbeatAgeSeconds = $probeData.AgentHeartbeatAgeSeconds
        ApplicationLease = $probeData.ApplicationLease
        Presence = $probeData.Presence
        Error = $null
    }
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
        Replace('__VM_NAME__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $VmName)).
        Replace('__INBOX_FILE__', (ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$InboxFile))).
        Replace('__PROCESSING_FILE__', (ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$ProcessingFile))).
        Replace('__COMPLETED_FILE__', (ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$CompletedFile))).
        Replace('__OUTBOX__', (ConvertTo-PowerShellSingleQuotedLiteral -Value ([string]$Outbox)))
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

function Invoke-InterruptedRequestCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [string] $RequestId
    )

    $cleanupStartedUtc = [DateTime]::UtcNow
    $errors = New-Object Collections.Generic.List[string]
    $hostInputRecovery = @()
    $requestNetworkRecovery = @()
    try {
        Stop-TestVm -VmName $VmName -Immediate
    }
    catch {
        $errors.Add("VM power-off cleanup failed: $($_.Exception.Message)")
    }

    try {
        $hostInputRecovery = @(Recover-OrphanedHostInputResources -BrokerRoot $BrokerRoot)
        foreach ($failure in @($hostInputRecovery | Where-Object { -not [bool]$_.Success })) {
            $errors.Add('Host-input orphan cleanup failed: ' + (@($failure.Errors) -join ' | '))
        }
    }
    catch {
        $errors.Add("Host-input orphan cleanup could not be verified: $($_.Exception.Message)")
    }

    try {
        $requestNetworkRecovery = @(Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
            Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot
        })
        foreach ($failure in @($requestNetworkRecovery | Where-Object { -not [bool]$_.Success })) {
            $errors.Add('Request-network orphan cleanup failed: ' + (@($failure.Errors) -join ' | '))
        }
    }
    catch {
        $errors.Add("Request-network orphan cleanup could not be verified: $($_.Exception.Message)")
    }

    $vmFinalState = 'Unknown'
    $finalNetworkInventorySucceeded = $false
    $finalConnectedAdapters = @()
    try {
        $vmFinalState = [string](Get-VM -Name $VmName -ErrorAction Stop).State
        if (-not [string]::Equals($vmFinalState, 'Off', [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add("Interrupted-request cleanup left VM '$VmName' in state '$vmFinalState'.")
        }
    }
    catch {
        $errors.Add("Interrupted-request cleanup could not verify VM state: $($_.Exception.Message)")
    }
    try {
        $finalConnectedAdapters = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) })
        $finalNetworkInventorySucceeded = $true
        if ($finalConnectedAdapters.Count -ne 0) {
            $errors.Add("Interrupted-request cleanup left $($finalConnectedAdapters.Count) connected VM network adapter(s).")
        }
    }
    catch {
        $errors.Add("Interrupted-request cleanup could not verify final network inventory: $($_.Exception.Message)")
    }

    [pscustomobject][ordered]@{
        Attempted = $true
        Success = $errors.Count -eq 0
        StartedUtc = $cleanupStartedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        RequestId = $RequestId
        VmName = $VmName
        VmFinalState = $vmFinalState
        HostInputRecovery = @($hostInputRecovery)
        RequestNetworkRecovery = @($requestNetworkRecovery)
        FinalNetworkInventorySucceeded = [bool]$finalNetworkInventorySucceeded
        FinalConnectedAdapterCount = @($finalConnectedAdapters).Count
        Errors = $errors.ToArray()
    }
}

function Publish-InterruptedRequestTerminalResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ResultRoot,
        [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')] [string] $RequestId,
        [AllowNull()] $Request,
        [AllowNull()] $RequestState,
        [Parameter(Mandatory = $true)] [string] $FailureKind,
        [Parameter(Mandatory = $true)] [string] $FailureStage,
        [Parameter(Mandatory = $true)] [string] $Message,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $VmName,
        [AllowNull()] [Nullable[int]] $WorkerId,
        [Parameter(Mandatory = $true)] $Cleanup,
        [bool] $PoolWorkerRecyclePending = $false
    )

    return Invoke-WithTerminalResultPublicationMutex -RequestId $RequestId -ScopeRoot $ResultRoot -Operation {
    New-Item -ItemType Directory -Force -Path $ResultRoot | Out-Null
    $brokerResultPath = Join-Path $ResultRoot 'broker-result.json'
    if (Test-Path -LiteralPath $brokerResultPath -PathType Leaf) {
        return Read-BrokerJsonWithRetry -Path $brokerResultPath
    }

    $completedUtc = [DateTime]::UtcNow
    $createdUtc = $null
    $createdUtcText = if ($Request -and -not [string]::IsNullOrWhiteSpace([string]$Request.CreatedUtc)) { [string]$Request.CreatedUtc } else { $null }
    try { if ($createdUtcText) { $createdUtc = [DateTime]::Parse($createdUtcText).ToUniversalTime() } } catch { $createdUtc = $null }
    $claimedUtc = $null
    $claimedUtcText = if ($RequestState -and -not [string]::IsNullOrWhiteSpace([string]$RequestState.ClaimedUtc)) { [string]$RequestState.ClaimedUtc } else { $null }
    try { if ($claimedUtcText) { $claimedUtc = [DateTime]::Parse($claimedUtcText).ToUniversalTime() } } catch { $claimedUtc = $null }
    if (-not $claimedUtc) { $claimedUtc = if ($createdUtc) { $createdUtc } else { $completedUtc } }

    $expectGuestPowerOff = Test-ExactExpectedGuestPowerOffRequest -Request $Request
    $submissionStartedUtc = if ($RequestState -and -not [string]::IsNullOrWhiteSpace([string]$RequestState.ExpectedGuestPowerOffSubmissionStartedUtc)) { [string]$RequestState.ExpectedGuestPowerOffSubmissionStartedUtc } else { $null }
    $guestJobMayHaveLaunchedProperty = if ($RequestState) { $RequestState.PSObject.Properties['GuestJobMayHaveLaunched'] } else { $null }
    $guestJobMayHaveLaunched = $guestJobMayHaveLaunchedProperty -and $guestJobMayHaveLaunchedProperty.Value -is [bool] -and [bool]$guestJobMayHaveLaunchedProperty.Value
    $applicationRunningObservedUtc = if ($RequestState -and -not [string]::IsNullOrWhiteSpace([string]$RequestState.GuestApplicationEraRunningObservedUtc)) { [string]$RequestState.GuestApplicationEraRunningObservedUtc } else { $null }
    $powerOffObservedUtc = if ($RequestState -and -not [string]::IsNullOrWhiteSpace([string]$RequestState.GuestPowerOffObservedUtc)) { [string]$RequestState.GuestPowerOffObservedUtc } else { $null }
    $powerOffBeforeCleanupProperty = if ($RequestState) { $RequestState.PSObject.Properties['GuestPowerOffBeforeCleanup'] } else { $null }
    $powerOffBeforeCleanup = $powerOffBeforeCleanupProperty -and $powerOffBeforeCleanupProperty.Value -is [bool] -and [bool]$powerOffBeforeCleanupProperty.Value
    $powerOffRecoveryDeadlineUtc = if ($RequestState -and -not [string]::IsNullOrWhiteSpace([string]$RequestState.PowerOffRecoveryDeadlineUtc)) { [string]$RequestState.PowerOffRecoveryDeadlineUtc } else { $null }
    $requestStatePublicationError = $null
    try {
        $stateParameters = @{
            ResultRoot = $ResultRoot
            RequestId = $RequestId
            Status = 'Failed'
            Message = $Message
            CreatedUtc = $createdUtc
            ClaimedUtc = $claimedUtc
            WorkerId = $WorkerId
        }
        if ($expectGuestPowerOff) {
            $stateParameters['ExpectGuestPowerOff'] = [Nullable[bool]]$true
            # No-replay evidence is monotonic. A stale/unreadable caller must
            # never erase a newer durable marker that Write-RequestState can
            # now read while terminal publication is in progress.
            if (-not [string]::IsNullOrWhiteSpace($submissionStartedUtc)) { $stateParameters['ExpectedGuestPowerOffSubmissionStartedUtc'] = $submissionStartedUtc }
            if ($guestJobMayHaveLaunchedProperty -and $guestJobMayHaveLaunchedProperty.Value -is [bool] -and [bool]$guestJobMayHaveLaunchedProperty.Value) { $stateParameters['GuestJobMayHaveLaunched'] = [Nullable[bool]]$true }
            if (-not [string]::IsNullOrWhiteSpace($applicationRunningObservedUtc)) { $stateParameters['GuestApplicationEraRunningObservedUtc'] = $applicationRunningObservedUtc }
            if (-not [string]::IsNullOrWhiteSpace($powerOffObservedUtc)) { $stateParameters['GuestPowerOffObservedUtc'] = $powerOffObservedUtc }
            if ($powerOffBeforeCleanupProperty -and $powerOffBeforeCleanupProperty.Value -is [bool] -and [bool]$powerOffBeforeCleanupProperty.Value) { $stateParameters['GuestPowerOffBeforeCleanup'] = [Nullable[bool]]$true }
            if (-not [string]::IsNullOrWhiteSpace($powerOffRecoveryDeadlineUtc)) { $stateParameters['PowerOffRecoveryDeadlineUtc'] = $powerOffRecoveryDeadlineUtc }
            $stateParameters['BrokerCleanupStartedUtc'] = [string]$Cleanup.StartedUtc
        }
        Write-RequestState @stateParameters
    }
    catch {
        $requestStatePublicationError = $_.Exception.Message
    }

    $result = [ordered]@{
        RequestId = $RequestId
        Success = $false
        HarnessSucceeded = $false
        TestEvaluated = $false
        TestPassed = $null
        OverallSucceeded = $false
        FailureKind = $FailureKind
        CleanupFailure = -not [bool]$Cleanup.Success
        Cleanup = $Cleanup
        Error = $Message
        FailureStage = $FailureStage
        RequestStatePublicationError = $requestStatePublicationError
        CreatedUtc = $createdUtcText
        ClaimedUtc = $claimedUtc.ToString('o')
        ExecutionDeadlineUtc = if ($RequestState) { [string]$RequestState.ExecutionDeadlineUtc } else { $null }
        Cancelled = $false
        QueueTimedOut = $false
        ExecutionTimedOut = $false
        CompletedUtc = $completedUtc.ToString('o')
        VmName = if ([string]::IsNullOrWhiteSpace($VmName)) { $null } else { $VmName }
        VmFinalState = [string]$Cleanup.VmFinalState
        PoolWorkerId = if ($null -ne $WorkerId) { [int]$WorkerId } else { $null }
        PoolWorkerRecyclePending = [bool]$PoolWorkerRecyclePending
    }
    if ($expectGuestPowerOff) {
        $result['ExpectGuestPowerOff'] = $true
        $result['GuestPowerOffRecoveryTimeoutSeconds'] = if ($null -ne $Request.GuestPowerOffRecoveryTimeoutSeconds) { [int]$Request.GuestPowerOffRecoveryTimeoutSeconds } else { $null }
        $result['ExpectedGuestPowerOffSubmissionStartedUtc'] = $submissionStartedUtc
        $result['GuestJobMayHaveLaunched'] = if ($guestJobMayHaveLaunchedProperty) { [bool]$guestJobMayHaveLaunched } else { $null }
        $result['GuestApplicationEraRunningObservedUtc'] = $applicationRunningObservedUtc
        $result['GuestPowerOffObservedUtc'] = $powerOffObservedUtc
        $result['GuestPowerOffBeforeCleanup'] = if ($powerOffBeforeCleanupProperty) { [bool]$powerOffBeforeCleanup } else { $null }
        $result['BrokerCleanupStartedUtc'] = [string]$Cleanup.StartedUtc
        $result['PowerOffRecoveryDeadlineUtc'] = $powerOffRecoveryDeadlineUtc
        $result['GuestPowerOffEvidenceRecoveryMode'] = $null
        $result['GuestPowerOffEvidenceRecoveryBootedUtc'] = $null
        $result['GuestPowerOffEvidenceRecoveryGuestBootTimeUtc'] = $null
        $result['GuestPowerOffEvidenceRecoveryCompletedUtc'] = $null
        $result['GuestPowerOffEvidenceRecoveryTimedOut'] = $false
        $result['ApplicationRelaunchedByHarnessAfterGuestPowerOff'] = $null
        $result['ExpectedGuestPowerOffContractSatisfied'] = $false
    }
    if (Write-TerminalJsonAtomic -Path $brokerResultPath -Value $result) {
        return [pscustomobject]$result
    }
    Read-BrokerJsonWithRetry -Path $brokerResultPath
    }
}

function Test-GuestSessionBootIdentity {
    param(
        [AllowNull()] $GuestState,
        [AllowNull()] $CurrentGuestBootTimeUtc,
        [bool] $Required = $false
    )

    if (-not $Required) { return $true }
    if (-not $GuestState -or [string]::IsNullOrWhiteSpace([string]$CurrentGuestBootTimeUtc)) { return $false }
    $stateBootProperty = @($GuestState.PSObject.Properties | Where-Object { $_.Name -ceq 'GuestBootTimeUtc' }) | Select-Object -First 1
    if (-not $stateBootProperty -or [string]::IsNullOrWhiteSpace([string]$stateBootProperty.Value)) { return $false }
    try {
        $stateBootUtc = [DateTimeOffset]::Parse([string]$stateBootProperty.Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $currentBootUtc = [DateTimeOffset]::Parse([string]$CurrentGuestBootTimeUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $stateBootUtc -eq $currentBootUtc
    }
    catch {
        $false
    }
}

function Wait-GuestSession {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $true)] [DateTime] $NotBeforeUtc,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc,
        [switch] $RequireCurrentGuestBootTime
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
                    $guestBootIsFresh = Test-GuestSessionBootIdentity -GuestState $guestState -CurrentGuestBootTimeUtc $probeResult.CurrentGuestBootTimeUtc -Required ([bool]$RequireCurrentGuestBootTime)
                    $heartbeatIsFresh = if ($RequireCurrentGuestBootTime) {
                        try {
                            $currentGuestUtc = [DateTimeOffset]::Parse([string]$probeResult.CurrentGuestUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                            $heartbeatAgeSeconds = ($currentGuestUtc - $heartbeat).TotalSeconds
                            $heartbeatAgeSeconds -ge -5 -and $heartbeatAgeSeconds -le 10
                        }
                        catch { $false }
                    }
                    else { $heartbeat -ge $NotBeforeUtc.AddSeconds(-5) }
                    if ($heartbeatIsFresh -and $guestBootIsFresh) {
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

function Get-ExpectedPowerOffRecoveryPresence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc,
        [Parameter(Mandatory = $true)] [string] $InboxFile,
        [Parameter(Mandatory = $true)] [string] $ProcessingFile,
        [Parameter(Mandatory = $true)] [string] $CompletedFile,
        [Parameter(Mandatory = $true)] [string] $Outbox,
        [ValidateRange(5, 60)] [int] $ObservationTimeoutSeconds = 15
    )

    Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    $probeId = $RequestId + '-recovery-' + [Guid]::NewGuid().ToString('N')
    $probeOutputPath = Join-Path $probePath ($probeId + '.json')
    $probe = $null
    $candidateProbeDeadlineUtc = [DateTime]::UtcNow.AddSeconds($ObservationTimeoutSeconds)
    $probeDeadlineUtc = if ($candidateProbeDeadlineUtc -lt $ExecutionDeadlineUtc) { $candidateProbeDeadlineUtc } else { $ExecutionDeadlineUtc }
    try {
        $probe = Start-GuestSessionProbe -VmName $VmName -OutputPath $probeOutputPath -InboxFile $InboxFile -ProcessingFile $ProcessingFile -CompletedFile $CompletedFile -Outbox $Outbox
        while ($true) {
            Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
            if ([DateTime]::UtcNow -ge $probeDeadlineUtc) {
                throw [InvalidOperationException]::new("The bounded expected-power-off recovery probe exceeded $ObservationTimeoutSeconds seconds.")
            }
            $probe.Process.Refresh()
            if ($probe.Process.HasExited) { break }
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-Path -LiteralPath $probeOutputPath -PathType Leaf)) {
            throw 'The bounded expected-power-off recovery probe exited without a result.'
        }
        $probeResult = Read-BrokerJsonWithRetry -Path $probeOutputPath
        if (-not [bool]$probeResult.Success) {
            throw "Expected-power-off recovery probe failed: $([string]$probeResult.Error)"
        }
        if (-not (Test-GuestSessionBootIdentity -GuestState $probeResult.State -CurrentGuestBootTimeUtc $probeResult.CurrentGuestBootTimeUtc -Required $true)) {
            throw 'Expected-power-off recovery probe did not belong to the current guest OS boot.'
        }
        $heartbeatUtc = [DateTimeOffset]::Parse([string]$probeResult.State.HeartbeatUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $currentGuestUtc = [DateTimeOffset]::Parse([string]$probeResult.CurrentGuestUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $heartbeatAgeSeconds = ($currentGuestUtc - $heartbeatUtc).TotalSeconds
        if ($heartbeatAgeSeconds -lt -5 -or $heartbeatAgeSeconds -gt 10) {
            throw 'Expected-power-off recovery probe returned a stale guest-agent heartbeat.'
        }
        if (-not $probeResult.Presence) {
            throw 'Expected-power-off recovery probe returned no job-presence evidence.'
        }
        $probeResult.Presence
    }
    finally {
        if ($probe) { Stop-GuestProbeProcess -Process $probe.Process -LeasePath $probe.LeasePath }
        Remove-Item -LiteralPath $probeOutputPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($probeOutputPath + '.tmp') -Force -ErrorAction SilentlyContinue
    }
}

function Get-ExpectedPowerOffJobObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc,
        [Parameter(Mandatory = $true)] [string] $InboxFile,
        [Parameter(Mandatory = $true)] [string] $ProcessingFile,
        [Parameter(Mandatory = $true)] [string] $CompletedFile,
        [Parameter(Mandatory = $true)] [string] $Outbox,
        [ValidateRange(5, 60)] [int] $ObservationTimeoutSeconds = 15
    )

    Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    $probeId = $RequestId + '-job-observation-' + [Guid]::NewGuid().ToString('N')
    $probeOutputPath = Join-Path $probePath ($probeId + '.json')
    $probe = $null
    $candidateProbeDeadlineUtc = [DateTime]::UtcNow.AddSeconds($ObservationTimeoutSeconds)
    $probeDeadlineUtc = if ($candidateProbeDeadlineUtc -lt $ExecutionDeadlineUtc) { $candidateProbeDeadlineUtc } else { $ExecutionDeadlineUtc }
    try {
        $probe = Start-GuestSessionProbe -VmName $VmName -OutputPath $probeOutputPath -InboxFile $InboxFile -ProcessingFile $ProcessingFile -CompletedFile $CompletedFile -Outbox $Outbox
        while ($true) {
            Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
            if ([DateTime]::UtcNow -ge $probeDeadlineUtc) {
                throw [InvalidOperationException]::new("The bounded expected-power-off job observation exceeded $ObservationTimeoutSeconds seconds.")
            }
            $probe.Process.Refresh()
            if ($probe.Process.HasExited) { break }
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-Path -LiteralPath $probeOutputPath -PathType Leaf)) {
            throw 'The bounded expected-power-off job observation exited without a result.'
        }
        $probeResult = Read-BrokerJsonWithRetry -Path $probeOutputPath
        if (-not [bool]$probeResult.Success) {
            throw "Expected-power-off job observation failed: $([string]$probeResult.Error)"
        }
        if (-not (Test-GuestSessionBootIdentity -GuestState $probeResult.State -CurrentGuestBootTimeUtc $probeResult.CurrentGuestBootTimeUtc -Required $true)) {
            throw 'Expected-power-off job observation did not belong to the current guest OS boot.'
        }
        $heartbeatUtc = [DateTimeOffset]::Parse([string]$probeResult.State.HeartbeatUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $currentGuestUtc = [DateTimeOffset]::Parse([string]$probeResult.CurrentGuestUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $heartbeatAgeSeconds = ($currentGuestUtc - $heartbeatUtc).TotalSeconds
        if ($heartbeatAgeSeconds -lt -5 -or $heartbeatAgeSeconds -gt 10) {
            throw 'Expected-power-off job observation returned a stale guest-agent heartbeat.'
        }
        if (-not $probeResult.Presence) {
            throw 'Expected-power-off job observation returned no lifecycle presence evidence.'
        }
        [pscustomobject][ordered]@{
            Result = [bool]$probeResult.Presence.Result
            AgentError = [bool]$probeResult.Presence.AgentError
            Inbox = [bool]$probeResult.Presence.Inbox
            Processing = [bool]$probeResult.Presence.Processing
            Completed = [bool]$probeResult.Presence.Completed
            AgentAlive = [bool]$probeResult.AgentAlive
            AgentHeartbeatAgeSeconds = $probeResult.AgentHeartbeatAgeSeconds
            AgentState = $probeResult.State
            ApplicationLease = $probeResult.ApplicationLease
        }
    }
    finally {
        if ($probe) { Stop-GuestProbeProcess -Process $probe.Process -LeasePath $probe.LeasePath }
        Remove-Item -LiteralPath $probeOutputPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($probeOutputPath + '.tmp') -Force -ErrorAction SilentlyContinue
    }
}

function Start-ExpectedPowerOffJobSubmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $JobPath,
        [Parameter(Mandatory = $true)] [string] $GuestTransferRoot,
        [Parameter(Mandatory = $true)] [string] $GuestTransferFile,
        [Parameter(Mandatory = $true)] [string] $GuestInboxFile,
        [Parameter(Mandatory = $true)] [string] $GuestProcessingFile,
        [Parameter(Mandatory = $true)] [string] $GuestCompletedFile,
        [Parameter(Mandatory = $true)] [string] $GuestOutbox,
        [Parameter(Mandatory = $true)] [string] $OutputPath
    )

    $childTemplate = @'
$ErrorActionPreference = 'Stop'
$outputPath = __OUTPUT_PATH__
$exitCode = 0
$session = $null
$deliveryAttempted = $false
$deliveryMadeVisible = $false
try {
    $credentialData = Get-Content -Raw -LiteralPath __CREDENTIAL_PATH__ | ConvertFrom-Json
    $securePassword = ConvertTo-SecureString ([string]$credentialData.Password) -AsPlainText -Force
    $credential = New-Object Management.Automation.PSCredential([string]$credentialData.UserName, $securePassword)
    $sessionOption = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 15000 -CancelTimeout 1000
    $session = New-PSSession -VMName __VM_NAME__ -Credential $credential -SessionOption $sessionOption -ErrorAction Stop
    $presenceScript = {
        param($InboxFile, $ProcessingFile, $CompletedFile, $Outbox)
        [ordered]@{
            Inbox = Test-Path -LiteralPath $InboxFile -PathType Leaf
            Processing = Test-Path -LiteralPath $ProcessingFile -PathType Leaf
            Completed = Test-Path -LiteralPath $CompletedFile -PathType Leaf
            Result = Test-Path -LiteralPath (Join-Path $Outbox 'result.json') -PathType Leaf
            AgentError = Test-Path -LiteralPath (Join-Path $Outbox 'agent-error.json') -PathType Leaf
        }
    }
    $presence = Invoke-Command -Session $session -ScriptBlock $presenceScript -ArgumentList __GUEST_INBOX_FILE__, __GUEST_PROCESSING_FILE__, __GUEST_COMPLETED_FILE__, __GUEST_OUTBOX__ -ErrorAction Stop | Select-Object -Last 1
    if (-not ($presence.Inbox -or $presence.Processing -or $presence.Completed -or $presence.Result -or $presence.AgentError)) {
        Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            param($TransferRoot, $TransferFile)
            New-Item -ItemType Directory -Force -Path $TransferRoot | Out-Null
            Remove-Item -LiteralPath $TransferFile -Force -ErrorAction SilentlyContinue
        } -ArgumentList __GUEST_TRANSFER_ROOT__, __GUEST_TRANSFER_FILE__
        $deliveryAttempted = $true
        Copy-Item -LiteralPath __JOB_PATH__ -Destination __GUEST_TRANSFER_ROOT__ -ToSession $session -Force -ErrorAction Stop
        Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            param($TransferFile, $InboxFile)
            Move-Item -LiteralPath $TransferFile -Destination $InboxFile -Force -ErrorAction Stop
        } -ArgumentList __GUEST_TRANSFER_FILE__, __GUEST_INBOX_FILE__
        $deliveryMadeVisible = $true
    }
    $presence = Invoke-Command -Session $session -ScriptBlock $presenceScript -ArgumentList __GUEST_INBOX_FILE__, __GUEST_PROCESSING_FILE__, __GUEST_COMPLETED_FILE__, __GUEST_OUTBOX__ -ErrorAction Stop | Select-Object -Last 1
    if (-not ($presence.Inbox -or $presence.Processing -or $presence.Completed -or $presence.Result -or $presence.AgentError)) {
        throw 'Expected-power-off submission returned without durable guest lifecycle presence.'
    }
    $result = [ordered]@{
        Success = $true
        Presence = $presence
        DeliveryAttempted = [bool]$deliveryAttempted
        DeliveryMadeVisible = [bool]$deliveryMadeVisible
        Error = $null
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
}
catch {
    $exitCode = 1
    $result = [ordered]@{
        Success = $false
        Presence = $null
        DeliveryAttempted = [bool]$deliveryAttempted
        DeliveryMadeVisible = [bool]$deliveryMadeVisible
        Error = $_.Exception.Message
        ErrorType = $_.Exception.GetType().FullName
        ErrorFullyQualifiedId = $_.FullyQualifiedErrorId
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
}
finally {
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
}
$temporaryPath = $outputPath + '.tmp'
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
exit $exitCode
'@
    $childCommand = $childTemplate.
        Replace('__OUTPUT_PATH__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $OutputPath)).
        Replace('__CREDENTIAL_PATH__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $credentialPath)).
        Replace('__VM_NAME__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $VmName)).
        Replace('__JOB_PATH__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $JobPath)).
        Replace('__GUEST_TRANSFER_ROOT__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $GuestTransferRoot)).
        Replace('__GUEST_TRANSFER_FILE__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $GuestTransferFile)).
        Replace('__GUEST_INBOX_FILE__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $GuestInboxFile)).
        Replace('__GUEST_PROCESSING_FILE__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $GuestProcessingFile)).
        Replace('__GUEST_COMPLETED_FILE__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $GuestCompletedFile)).
        Replace('__GUEST_OUTBOX__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $GuestOutbox))
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand
    ) -WindowStyle Hidden -PassThru
    $leasePath = [IO.Path]::ChangeExtension($OutputPath, 'process.json')
    Write-JsonAtomic -Path $leasePath -Value ([ordered]@{
        ProcessId = $process.Id
        ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        RequestId = $RequestId
        Purpose = 'ExpectedGuestPowerOffSubmission'
    })
    [pscustomobject]@{ Process = $process; LeasePath = $leasePath }
}

function Invoke-ExpectedPowerOffJobSubmissionBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc,
        [Parameter(Mandatory = $true)] [string] $JobPath,
        [Parameter(Mandatory = $true)] [string] $GuestTransferRoot,
        [Parameter(Mandatory = $true)] [string] $GuestTransferFile,
        [Parameter(Mandatory = $true)] [string] $GuestInboxFile,
        [Parameter(Mandatory = $true)] [string] $GuestProcessingFile,
        [Parameter(Mandatory = $true)] [string] $GuestCompletedFile,
        [Parameter(Mandatory = $true)] [string] $GuestOutbox,
        [ValidateRange(5, 60)] [int] $AttemptTimeoutSeconds = 30
    )

    Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    $operationId = $RequestId + '-submission-' + [Guid]::NewGuid().ToString('N')
    $outputPath = Join-Path $probePath ($operationId + '.json')
    $operation = $null
    $candidateAttemptDeadlineUtc = [DateTime]::UtcNow.AddSeconds($AttemptTimeoutSeconds)
    $attemptDeadlineUtc = if ($candidateAttemptDeadlineUtc -lt $ExecutionDeadlineUtc) { $candidateAttemptDeadlineUtc } else { $ExecutionDeadlineUtc }
    try {
        $operation = Start-ExpectedPowerOffJobSubmission -VmName $VmName -RequestId $RequestId -JobPath $JobPath -GuestTransferRoot $GuestTransferRoot -GuestTransferFile $GuestTransferFile -GuestInboxFile $GuestInboxFile -GuestProcessingFile $GuestProcessingFile -GuestCompletedFile $GuestCompletedFile -GuestOutbox $GuestOutbox -OutputPath $outputPath
        while ($true) {
            Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
            if ([DateTime]::UtcNow -ge $attemptDeadlineUtc) {
                throw [InvalidOperationException]::new("The bounded expected-power-off submission exceeded $AttemptTimeoutSeconds seconds; automatic replay remains prohibited.")
            }
            $operation.Process.Refresh()
            if ($operation.Process.HasExited) { break }
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw 'The bounded expected-power-off submission exited without a result; automatic replay remains prohibited.'
        }
        $operationResult = Read-BrokerJsonWithRetry -Path $outputPath
        if (-not [bool]$operationResult.Success) {
            throw "Expected-power-off submission failed without replay: $([string]$operationResult.Error)"
        }
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        $operationResult
    }
    finally {
        if ($operation) { Stop-GuestProbeProcess -Process $operation.Process -LeasePath $operation.LeasePath }
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($outputPath + '.tmp') -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ExpectedPowerOffEvidenceStageMatchesManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $HostStageRoot,
        [Parameter(Mandatory = $true)] $Manifest,
        [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')] [string] $RequestId,
        [Parameter(Mandatory = $true)] [ValidatePattern('^[a-f0-9]{32}$')] [string] $SnapshotId
    )

    $integralTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    $getExactProperty = {
        param($InputObject, [string] $Name)
        if (-not $InputObject) { return $null }
        @($InputObject.PSObject.Properties | Where-Object { $_.Name -ceq $Name }) | Select-Object -First 1
    }
    $assertManifestIdentity = {
        param($Candidate, [string] $SourceDescription)
        $formatProperty = & $getExactProperty $Candidate 'FormatVersion'
        $requestProperty = & $getExactProperty $Candidate 'RequestId'
        $snapshotProperty = & $getExactProperty $Candidate 'SnapshotId'
        $stageProperty = & $getExactProperty $Candidate 'StageRoot'
        if (-not $formatProperty -or $null -eq $formatProperty.Value -or $formatProperty.Value.GetType() -notin $integralTypes -or [int64]$formatProperty.Value -ne 2) {
            throw "$SourceDescription did not attest exact evidence manifest FormatVersion 2."
        }
        if (-not $requestProperty -or $requestProperty.Value -isnot [string] -or -not [string]::Equals([string]$requestProperty.Value, $RequestId, [StringComparison]::Ordinal)) {
            throw "$SourceDescription was not bound to the exact request id."
        }
        if (-not $snapshotProperty -or $snapshotProperty.Value -isnot [string] -or -not [string]::Equals([string]$snapshotProperty.Value, $SnapshotId, [StringComparison]::Ordinal)) {
            throw "$SourceDescription was not bound to the exact snapshot id."
        }
        $expectedGuestStageRoot = [IO.Path]::GetFullPath((Join-Path 'C:\CodexGuest\EvidenceStage' $SnapshotId)).TrimEnd('\')
        if (-not $stageProperty -or $stageProperty.Value -isnot [string] -or
            -not [string]::Equals([IO.Path]::GetFullPath([string]$stageProperty.Value).TrimEnd('\'), $expectedGuestStageRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$SourceDescription did not identify the exact private guest evidence stage."
        }
    }

    $resolvedStageRoot = [IO.Path]::GetFullPath($HostStageRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $resolvedStageRoot -PathType Container)) {
        throw "The copied host evidence stage is missing: $resolvedStageRoot"
    }
    $stageRootItem = Get-Item -LiteralPath $resolvedStageRoot -Force -ErrorAction Stop
    if (($stageRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The copied host evidence stage must not be a reparse point.'
    }
    $stagePrefix = $resolvedStageRoot + '\'
    $manifestPath = Join-Path $resolvedStageRoot 'evidence-copy-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The copied host evidence stage is missing evidence-copy-manifest.json.'
    }

    & $assertManifestIdentity $Manifest 'The returned guest evidence manifest'
    try { $hostManifest = Get-Content -Raw -LiteralPath $manifestPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "The copied host evidence manifest is unreadable: $($_.Exception.Message)" }
    & $assertManifestIdentity $hostManifest 'The copied host evidence manifest'
    $returnedManifestJson = $Manifest | ConvertTo-Json -Depth 20 -Compress
    $copiedManifestJson = $hostManifest | ConvertTo-Json -Depth 20 -Compress
    if (-not [string]::Equals($returnedManifestJson, $copiedManifestJson, [StringComparison]::Ordinal)) {
        throw 'The copied host evidence manifest does not match the manifest returned over the control channel.'
    }

    $copiedFilesProperty = & $getExactProperty $Manifest 'CopiedFiles'
    $skippedFilesProperty = & $getExactProperty $Manifest 'SkippedFiles'
    $enumeratedCountProperty = & $getExactProperty $Manifest 'EnumeratedFileCount'
    if (-not $copiedFilesProperty -or -not $skippedFilesProperty -or -not $enumeratedCountProperty -or
        $null -eq $enumeratedCountProperty.Value -or $enumeratedCountProperty.Value.GetType() -notin $integralTypes) {
        throw 'The returned guest evidence manifest is missing exact file inventory fields.'
    }
    $copiedFiles = @($copiedFilesProperty.Value)
    $skippedFiles = @($skippedFilesProperty.Value)
    if ([int64]$enumeratedCountProperty.Value -ne ($copiedFiles.Count + $skippedFiles.Count)) {
        throw 'The returned guest evidence manifest file count is inconsistent.'
    }

    $manifestPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $expectedHostFiles = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $null = $expectedHostFiles.Add('evidence-copy-manifest.json')
    $resolveRelativePath = {
        param([string] $RelativePath)
        if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
            throw 'The evidence manifest contains an empty or rooted relative path.'
        }
        $normalizedRelativePath = $RelativePath.Replace('/', '\')
        $segments = @($normalizedRelativePath.Split([char]92))
        if ($segments.Count -eq 0 -or @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }).Count -gt 0) {
            throw "The evidence manifest contains an unsafe relative path: $RelativePath"
        }
        $resolvedPath = [IO.Path]::GetFullPath((Join-Path $resolvedStageRoot $normalizedRelativePath))
        if (-not $resolvedPath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The evidence manifest path escaped the private host stage: $RelativePath"
        }
        $canonicalRelativePath = $resolvedPath.Substring($stagePrefix.Length)
        if (-not [string]::Equals($canonicalRelativePath, $normalizedRelativePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The evidence manifest path is not canonical: $RelativePath"
        }
        [pscustomobject]@{ RelativePath = $canonicalRelativePath; FullPath = $resolvedPath }
    }

    foreach ($copiedFile in $copiedFiles) {
        $relativeProperty = & $getExactProperty $copiedFile 'RelativePath'
        $lengthProperty = & $getExactProperty $copiedFile 'Length'
        $hashProperty = & $getExactProperty $copiedFile 'Sha256'
        $sourceWriteProperty = & $getExactProperty $copiedFile 'SourceLastWriteUtc'
        if (-not $relativeProperty -or $relativeProperty.Value -isnot [string] -or
            -not $lengthProperty -or $null -eq $lengthProperty.Value -or $lengthProperty.Value.GetType() -notin $integralTypes -or [int64]$lengthProperty.Value -lt 0 -or
            -not $hashProperty -or $hashProperty.Value -isnot [string] -or [string]$hashProperty.Value -notmatch '^[A-Fa-f0-9]{64}$' -or
            -not $sourceWriteProperty -or $sourceWriteProperty.Value -isnot [string]) {
            throw 'The evidence manifest contains an incomplete copied-file record.'
        }
        try { $null = [DateTimeOffset]::Parse([string]$sourceWriteProperty.Value, [Globalization.CultureInfo]::InvariantCulture) }
        catch { throw 'The evidence manifest contains an invalid source last-write timestamp.' }
        $resolvedEntry = & $resolveRelativePath ([string]$relativeProperty.Value)
        if ([string]::Equals([string]$resolvedEntry.RelativePath, 'evidence-copy-manifest.json', [StringComparison]::OrdinalIgnoreCase) -or
            -not $manifestPaths.Add([string]$resolvedEntry.RelativePath)) {
            throw "The evidence manifest contains a duplicate or reserved copied-file path: $([string]$relativeProperty.Value)"
        }
        $null = $expectedHostFiles.Add([string]$resolvedEntry.RelativePath)
        if (-not (Test-Path -LiteralPath $resolvedEntry.FullPath -PathType Leaf)) {
            throw "A copied evidence file is missing from the private host stage: $([string]$resolvedEntry.RelativePath)"
        }
        $hostItem = Get-Item -LiteralPath $resolvedEntry.FullPath -Force -ErrorAction Stop
        if (($hostItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [int64]$hostItem.Length -ne [int64]$lengthProperty.Value -or
            -not [string]::Equals((Get-FileHash -LiteralPath $resolvedEntry.FullPath -Algorithm SHA256 -ErrorAction Stop).Hash, [string]$hashProperty.Value, [StringComparison]::OrdinalIgnoreCase)) {
            throw "A copied evidence file failed host-side length/SHA-256 verification: $([string]$resolvedEntry.RelativePath)"
        }
    }

    foreach ($skippedFile in $skippedFiles) {
        $relativeProperty = & $getExactProperty $skippedFile 'RelativePath'
        if (-not $relativeProperty -or $relativeProperty.Value -isnot [string]) {
            throw 'The evidence manifest contains an incomplete skipped-file record.'
        }
        $resolvedEntry = & $resolveRelativePath ([string]$relativeProperty.Value)
        if (-not $manifestPaths.Add([string]$resolvedEntry.RelativePath)) {
            throw "The evidence manifest contains a duplicate skipped-file path: $([string]$relativeProperty.Value)"
        }
        if (Test-Path -LiteralPath $resolvedEntry.FullPath) {
            throw "A file recorded as skipped was present in the copied host stage: $([string]$resolvedEntry.RelativePath)"
        }
    }

    $expectedHostDirectories = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($manifestPathEntry in $manifestPaths) {
        $parentRelativePath = Split-Path -Parent $manifestPathEntry
        while (-not [string]::IsNullOrWhiteSpace($parentRelativePath)) {
            $null = $expectedHostDirectories.Add($parentRelativePath)
            $parentRelativePath = Split-Path -Parent $parentRelativePath
        }
    }

    $actualHostDirectories = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pendingDirectories = New-Object 'Collections.Generic.Stack[IO.DirectoryInfo]'
    $pendingDirectories.Push([IO.DirectoryInfo]$stageRootItem)
    $actualHostFileCount = 0
    while ($pendingDirectories.Count -gt 0) {
        $directory = $pendingDirectories.Pop()
        foreach ($hostItem in @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)) {
            $hostRelativePath = $hostItem.FullName.Substring($stagePrefix.Length)
            if ($hostItem.PSIsContainer) {
                if (($hostItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    -not $expectedHostDirectories.Contains($hostRelativePath) -or
                    -not $actualHostDirectories.Add($hostRelativePath)) {
                    throw "The copied host evidence stage contains an unmanifested or unsafe directory: $hostRelativePath"
                }
                $pendingDirectories.Push([IO.DirectoryInfo]$hostItem)
            }
            else {
                $actualHostFileCount++
                if (($hostItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $expectedHostFiles.Contains($hostRelativePath)) {
                    throw "The copied host evidence stage contains an unmanifested or unsafe file: $hostRelativePath"
                }
            }
        }
    }
    if ($actualHostFileCount -ne $expectedHostFiles.Count -or $actualHostDirectories.Count -ne $expectedHostDirectories.Count) {
        throw 'The copied host evidence stage file inventory does not match its manifest.'
    }
    $true
}

function Start-ExpectedPowerOffEvidenceTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [ValidatePattern('^[a-f0-9]{32}$')] [string] $SnapshotId,
        [Parameter(Mandatory = $true)] [string] $GuestOutbox,
        [Parameter(Mandatory = $true)] [string] $HostResultRoot,
        [Parameter(Mandatory = $true)] [string] $OutputPath
    )

    $childTemplate = @'
$ErrorActionPreference = 'Stop'
$outputPath = __OUTPUT_PATH__
$exitCode = 0
$session = $null
try {
    . __HOST_BROKER_PATH__ -BrokerRoot __BROKER_ROOT__ -LibraryOnly
    $credential = Get-GuestCredential
    $session = New-PSSession -VMName __VM_NAME__ -Credential $credential -ErrorAction Stop
    $manifest = New-GuestEvidenceSnapshot -Session $session -GuestOutbox __GUEST_OUTBOX__ -RequestId __REQUEST_ID__ -SnapshotId __SNAPSHOT_ID__
    Copy-Item -Path (([string]$manifest.StageRoot).TrimEnd('\') + '\*') -Destination __HOST_RESULT_ROOT__ -FromSession $session -Recurse -Force -ErrorAction Stop
    Remove-GuestEvidenceSnapshot -Session $session -StageRoot ([string]$manifest.StageRoot)
    $result = [ordered]@{
        Success = $true
        Manifest = $manifest
        Error = $null
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
}
catch {
    $exitCode = 1
    $result = [ordered]@{
        Success = $false
        Manifest = $null
        Error = $_.Exception.Message
        ErrorType = $_.Exception.GetType().FullName
        ErrorFullyQualifiedId = $_.FullyQualifiedErrorId
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
}
finally {
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
}
$temporaryPath = $outputPath + '.tmp'
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
exit $exitCode
'@
    $childCommand = $childTemplate.
        Replace('__OUTPUT_PATH__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $OutputPath)).
        Replace('__HOST_BROKER_PATH__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $PSCommandPath)).
        Replace('__BROKER_ROOT__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $BrokerRoot)).
        Replace('__VM_NAME__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $VmName)).
        Replace('__GUEST_OUTBOX__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $GuestOutbox)).
        Replace('__REQUEST_ID__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $RequestId)).
        Replace('__SNAPSHOT_ID__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $SnapshotId)).
        Replace('__HOST_RESULT_ROOT__', (ConvertTo-PowerShellSingleQuotedLiteral -Value $HostResultRoot))
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand
    ) -WindowStyle Hidden -PassThru
    $leasePath = [IO.Path]::ChangeExtension($OutputPath, 'process.json')
    Write-JsonAtomic -Path $leasePath -Value ([ordered]@{
        ProcessId = $process.Id
        ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Purpose = 'ExpectedGuestPowerOffEvidenceTransfer'
    })
    [pscustomobject]@{ Process = $process; LeasePath = $leasePath }
}

function Invoke-ExpectedPowerOffEvidenceTransferBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc,
        [Parameter(Mandatory = $true)] [string] $GuestOutbox,
        [Parameter(Mandatory = $true)] [string] $HostResultRoot,
        [ValidateRange(5, 60)] [int] $AttemptTimeoutSeconds = 30
    )

    Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    $operationId = $RequestId + '-evidence-' + [Guid]::NewGuid().ToString('N')
    $snapshotId = [Guid]::NewGuid().ToString('N')
    $outputPath = Join-Path $probePath ($operationId + '.json')
    $hostStageRoot = Join-Path (Join-Path $probePath 'EvidenceTransfers') $operationId
    New-Item -ItemType Directory -Force -Path $hostStageRoot | Out-Null
    $operation = $null
    $preserveHostStage = $false
    $candidateAttemptDeadlineUtc = [DateTime]::UtcNow.AddSeconds($AttemptTimeoutSeconds)
    $attemptDeadlineUtc = if ($candidateAttemptDeadlineUtc -lt $ExecutionDeadlineUtc) { $candidateAttemptDeadlineUtc } else { $ExecutionDeadlineUtc }
    try {
        $operation = Start-ExpectedPowerOffEvidenceTransfer -VmName $VmName -RequestId $RequestId -SnapshotId $snapshotId -GuestOutbox $GuestOutbox -HostResultRoot $hostStageRoot -OutputPath $outputPath
        while ($true) {
            Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
            if ([DateTime]::UtcNow -ge $attemptDeadlineUtc) {
                throw [InvalidOperationException]::new("The bounded evidence-transfer attempt exceeded $AttemptTimeoutSeconds seconds.")
            }
            $operation.Process.Refresh()
            if ($operation.Process.HasExited) { break }
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw 'The bounded evidence-transfer child exited without a result.'
        }
        $operationResult = Read-BrokerJsonWithRetry -Path $outputPath
        if (-not [bool]$operationResult.Success) {
            throw "Expected-power-off evidence transfer failed: $([string]$operationResult.Error)"
        }
        Assert-ExpectedPowerOffEvidenceStageMatchesManifest -HostStageRoot $hostStageRoot -Manifest $operationResult.Manifest -RequestId $RequestId -SnapshotId $snapshotId | Out-Null
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        $preserveHostStage = $true
        [pscustomobject][ordered]@{
            Manifest = $operationResult.Manifest
            HostStageRoot = $hostStageRoot
            SnapshotId = $snapshotId
        }
    }
    finally {
        if ($operation) { Stop-GuestProbeProcess -Process $operation.Process -LeasePath $operation.LeasePath }
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($outputPath + '.tmp') -Force -ErrorAction SilentlyContinue
        if (-not $preserveHostStage) {
            Remove-Item -LiteralPath $hostStageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
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
            $remainingMilliseconds = [Math]::Max(1000, [Math]::Floor(($ExecutionDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds))
            $remoteOperationTimeout = [int][Math]::Min(15000, $remainingMilliseconds)
            $sessionOption = New-PSSessionOption -OpenTimeout $remoteOperationTimeout -OperationTimeout $remoteOperationTimeout -CancelTimeout 1000
            return New-PSSession -VMName $VmName -Credential $Credential -SessionOption $sessionOption -ErrorAction Stop
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
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [ValidatePattern('^[a-f0-9]{32}$')] [string] $SnapshotId
    )

    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($SourceRoot, $JobId, $StageId, $StageBaseRoot = 'C:\CodexGuest\EvidenceStage')

        if ($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
            throw "Invalid evidence snapshot request id: $JobId"
        }
        if ($StageId -notmatch '^[a-f0-9]{32}$') {
            throw "Invalid evidence snapshot operation id: $StageId"
        }
        $sourceRootFull = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $sourceRootFull -PathType Container)) {
            throw "Guest evidence source is missing: $sourceRootFull"
        }

        # Every attempt owns an immutable stage. A killed PowerShell Direct
        # child may still unwind remotely; retries must never delete or reuse
        # the directory that an earlier pipeline could still be writing.
        $stageRoot = Join-Path $StageBaseRoot $StageId
        New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop | Out-Null

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
                    $sourceBefore = Get-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $sourceBeforeLength = [int64]$sourceBefore.Length
                    $sourceBeforeWriteTicks = $sourceBefore.LastWriteTimeUtc.Ticks
                    $shareMode = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
                    $sourceStream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $shareMode)
                    $destinationStream = [IO.File]::Open($destinationPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $sourceStream.CopyTo($destinationStream)
                    $destinationStream.Flush()
                    $destinationStream.Dispose()
                    $destinationStream = $null
                    $sourceStream.Dispose()
                    $sourceStream = $null
                    $sourceAfterCopy = Get-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $destinationAfterCopy = Get-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
                    $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                    $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
                    $sourceAfterHash = Get-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    if ($sourceBeforeLength -ne [int64]$sourceAfterCopy.Length -or
                        $sourceBeforeLength -ne [int64]$sourceAfterHash.Length -or
                        $sourceBeforeWriteTicks -ne $sourceAfterCopy.LastWriteTimeUtc.Ticks -or
                        $sourceBeforeWriteTicks -ne $sourceAfterHash.LastWriteTimeUtc.Ticks -or
                        [int64]$destinationAfterCopy.Length -ne [int64]$sourceAfterHash.Length -or
                        -not [string]::Equals($sourceHash, $destinationHash, [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'The evidence file changed while its snapshot was being copied.'
                    }
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
                    Sha256 = [string](Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
                    SourceLastWriteUtc = $sourceAfterHash.LastWriteTimeUtc.ToString('o')
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
            FormatVersion = 2
            RequestId = $JobId
            SnapshotId = $StageId
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
    } -ArgumentList $GuestOutbox, $RequestId, $SnapshotId
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

function Remove-HostLiveEvidenceCommand {
    param(
        [Parameter(Mandatory = $true)] [string] $CaptureId,
        [Parameter(Mandatory = $true)] [string] $CommandPath
    )

    Invoke-WithLiveEvidenceMutex -CaptureId $CaptureId -Operation {
        Remove-Item -LiteralPath $CommandPath -Force -ErrorAction SilentlyContinue
    } | Out-Null
}

function Complete-HostLiveEvidenceFailure {
    param(
        [Parameter(Mandatory = $true)] $Context,
        [Parameter(Mandatory = $true)] [string] $Status,
        [Parameter(Mandatory = $true)] [string] $FailureKind,
        [Parameter(Mandatory = $true)] [string] $Message,
        [string] $LifecycleStage,
        [Nullable[int]] $ApplicationProcessId,
        [string] $EvidencePath,
        $Details
    )

    $command = $Context.Command
    $outcome = New-LiveEvidenceOutcome -CaptureId ([string]$command.CaptureId) -RequestId ([string]$command.RequestId) -Status $Status -FailureKind $FailureKind -Message $Message -WorkerId $command.ExpectedWorkerId -LifecycleStage $LifecycleStage -ApplicationProcessId $ApplicationProcessId -EvidencePath $EvidencePath -Details $Details
    Write-LiveEvidenceOutcome -BrokerRoot $BrokerRoot -CaptureId ([string]$command.CaptureId) -Outcome $outcome | Out-Null
    Remove-HostLiveEvidenceCommand -CaptureId ([string]$command.CaptureId) -CommandPath ([string]$Context.CommandPath)
}

function Get-HostLiveEvidenceContext {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [int] $ApplicationProcessId
    )

    Route-LiveEvidenceRequests -BrokerRoot $BrokerRoot -Config $Config
    Reconcile-LiveEvidenceCommands -BrokerRoot $BrokerRoot -Config $Config
    $layout = Get-LiveEvidenceLayout -BrokerRoot $BrokerRoot
    foreach ($commandFile in @(Get-ChildItem -LiteralPath $layout.Processing -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc, Name)) {
        $candidate = Read-LiveEvidenceJsonSafe -Path $commandFile.FullName
        if (-not $candidate -or -not [string]::Equals([string]$candidate.RequestId, $RequestId, [StringComparison]::Ordinal)) { continue }
        $captureId = [string]$candidate.CaptureId
        $claimed = Invoke-WithLiveEvidenceMutex -CaptureId $captureId -Operation {
            $command = Read-LiveEvidenceJsonSafe -Path $commandFile.FullName
            if (-not $command -or [string]$command.Status -ne 'Bound') { return $null }
            $responsePath = Join-Path $layout.Responses ($captureId + '.json')
            if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
                Remove-Item -LiteralPath $commandFile.FullName -Force -ErrorAction SilentlyContinue
                return $null
            }
            $binding = Get-LiveEvidencePoolBinding -BrokerRoot $BrokerRoot -Config $Config -RequestId $RequestId -ExpectedWorkerId $command.ExpectedWorkerId -ExpectedOperationId ([string]$command.ExpectedOperationId)
            if (-not $binding.Valid) {
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $command -Status 'StaleWorkerRequestBinding' -FailureKind 'StaleWorkerRequestBinding' -Message ([string]$binding.Reason) -LifecycleStage ([string]$command.BoundLifecycleStage) -WorkerId $binding.WorkerId -ApplicationProcessId $ApplicationProcessId
                Remove-Item -LiteralPath $commandFile.FullName -Force -ErrorAction SilentlyContinue
                return $null
            }
            if ([int]$command.ExpectedApplicationProcessId -ne $ApplicationProcessId) {
                Complete-LiveEvidenceCommandFailure -BrokerRoot $BrokerRoot -Command $command -Status 'StaleWorkerRequestBinding' -FailureKind 'StaleWorkerRequestBinding' -Message 'The application PID no longer matches the broker-bound capture command.' -LifecycleStage ([string]$command.BoundLifecycleStage) -WorkerId $binding.WorkerId -ApplicationProcessId $ApplicationProcessId
                Remove-Item -LiteralPath $commandFile.FullName -Force -ErrorAction SilentlyContinue
                return $null
            }
            $command | Add-Member -NotePropertyName Status -NotePropertyValue 'Capturing' -Force
            $command | Add-Member -NotePropertyName HostWorkerProcessId -NotePropertyValue $PID -Force
            $command | Add-Member -NotePropertyName HostWorkerProcessStartUtc -NotePropertyValue ([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')) -Force
            Write-JsonAtomic -Path $commandFile.FullName -Value $command
            [pscustomobject][ordered]@{
                Command = $command
                CommandPath = $commandFile.FullName
                State = 'Claimed'
                GuestSubmittedUtc = $null
                CaptureDeadlineUtc = $null
            }
        }
        if ($claimed) { return $claimed }
    }
    $null
}

function Get-GuestLiveEvidenceInventory {
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $ResponseRoot,
        [Parameter(Mandatory = $true)] [string] $CaptureId,
        [Parameter(Mandatory = $true)] [object[]] $AllowedFiles
    )

    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($Path, $Id, $Allowed)
        if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') { throw 'Invalid live evidence capture ID.' }
        $allowedRoot = [IO.Path]::GetFullPath('C:\CodexGuest\LiveEvidence\Responses').TrimEnd('\') + '\'
        $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        if (-not ($root + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Live evidence response path escaped the guest response root.' }
        $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Live evidence response root is invalid or reparse-backed.' }
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force -ErrorAction Stop)) {
            if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Live evidence response contains a reparse directory: $($directory.FullName)" }
        }

        $allowedByPath = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($definition in @($Allowed)) {
            $relative = [string]$definition.RelativePath
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or $relative -match '(^|[\\/])\.\.?([\\/]|$)') {
                throw "Invalid broker allowlist path: $relative"
            }
            if ($allowedByPath.ContainsKey($relative)) { throw "Duplicate broker allowlist path: $relative" }
            $allowedByPath[$relative] = $definition
        }
        $sourceFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction Stop | Sort-Object FullName)
        if ($sourceFiles.Count -ne $allowedByPath.Count) { throw 'The guest response file count does not match the broker allowlist.' }

        $stageBase = 'C:\Windows\Temp\CodexLiveEvidenceHostStage'
        New-Item -ItemType Directory -Force -Path $stageBase | Out-Null
        $stageRoot = Join-Path $stageBase ($Id + '-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
        $stageAcl = [Security.AccessControl.DirectorySecurity]::new()
        $stageAcl.SetAccessRuleProtection($true, $false)
        $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $stageAcl.SetOwner($administratorsSid)
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach ($sid in @($administratorsSid, $systemSid)) {
            $stageAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        }
        [IO.Directory]::SetAccessControl($stageRoot, $stageAcl)

        $inventory = New-Object Collections.Generic.List[object]
        $aggregateGuestBytes = [long]0
        try {
            foreach ($file in $sourceFiles) {
                if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Live evidence response contains a reparse file: $($file.FullName)" }
                $relativePath = $file.FullName.Substring($root.Length).TrimStart('\')
                if (-not $allowedByPath.ContainsKey($relativePath)) { throw "Guest live evidence returned an unrequested file: $relativePath" }
                $definition = $allowedByPath[$relativePath]
                $maximumBytes = [long]$definition.MaximumBytes
                if ($maximumBytes -le 0 -or $file.Length -le 0 -or $file.Length -gt $maximumBytes) { throw "Live evidence file exceeded its broker bound: $relativePath" }
                if ([string]$definition.Kind -eq 'guest-file') {
                    $aggregateGuestBytes += [long]$file.Length
                    if ($aggregateGuestBytes -gt 16MB) { throw 'Guest evidence files exceeded the 16 MiB aggregate bound.' }
                }

                $destination = Join-Path $stageRoot $relativePath
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                $copied = $false
                $lastError = $null
                for ($attempt = 1; $attempt -le 4; $attempt++) {
                    $temporary = $destination + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
                    try {
                        $before = Get-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                        if ($before.Attributes -band [IO.FileAttributes]::ReparsePoint -or $before.Length -le 0 -or $before.Length -gt $maximumBytes) { throw 'Source validation changed before bounded copy.' }
                        $beforeHash = (Get-FileHash -LiteralPath $before.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                        $sourceStream = $null
                        $destinationStream = $null
                        try {
                            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
                            $sourceStream = [IO.File]::Open($before.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
                            $destinationStream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                            $buffer = New-Object byte[] 65536
                            $copiedBytes = [long]0
                            while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                                $copiedBytes += $read
                                if ($copiedBytes -gt $maximumBytes) { throw 'Source grew beyond its broker transfer bound.' }
                                $destinationStream.Write($buffer, 0, $read)
                            }
                            $destinationStream.Flush($true)
                        }
                        finally {
                            if ($destinationStream) { $destinationStream.Dispose() }
                            if ($sourceStream) { $sourceStream.Dispose() }
                        }
                        $after = Get-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                        $destinationItem = Get-Item -LiteralPath $temporary -Force -ErrorAction Stop
                        $destinationHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256 -ErrorAction Stop).Hash
                        $afterHash = (Get-FileHash -LiteralPath $after.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                        if ($before.Length -ne $after.Length -or $before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc -or $destinationItem.Length -ne $after.Length -or $beforeHash -ne $destinationHash -or $destinationHash -ne $afterHash) {
                            throw 'Source changed during the broker-owned bounded snapshot.'
                        }
                        [IO.File]::Move($temporary, $destination)
                        $inventory.Add([ordered]@{
                            FullName = $destination
                            RelativePath = $relativePath
                            Length = [long]$destinationItem.Length
                            LastWriteUtc = $after.LastWriteTimeUtc.ToString('o')
                            Sha256 = $destinationHash
                        })
                        $copied = $true
                        break
                    }
                    catch {
                        $lastError = $_.Exception.Message
                        [IO.File]::Delete($temporary)
                        if ($attempt -lt 4) { Start-Sleep -Milliseconds ([int](100 * [Math]::Pow(2, $attempt - 1))) }
                    }
                }
                if (-not $copied) { throw "Could not create a stable broker-owned snapshot for '$relativePath': $lastError" }
            }
            [pscustomobject][ordered]@{ StageRoot = $stageRoot; Files = $inventory.ToArray() }
        }
        catch {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }
    } -ArgumentList $ResponseRoot, $CaptureId, $AllowedFiles
}

function Copy-GuestLiveEvidenceBounded {
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $GuestResponseRoot,
        [Parameter(Mandatory = $true)] [string] $HostStageRoot,
        [Parameter(Mandatory = $true)] $GuestResult,
        [Parameter(Mandatory = $true)] [string[]] $RequestedGuestPaths
    )

    $allowed = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $allowed['live-evidence-result.json'] = 'manifest'
    if ([bool]$GuestResult.Success) { $allowed['live-screenshot.png'] = 'screenshot' }
    if ([bool]$GuestResult.Success) {
        foreach ($relativePath in @(Assert-LiveEvidenceRelativePaths -Paths $RequestedGuestPaths)) {
            $allowed['files\' + $relativePath] = 'guest-file'
        }
    }
    $allowedFiles = @(
        foreach ($relativePath in $allowed.Keys) {
            $kind = $allowed[$relativePath]
            [pscustomobject][ordered]@{
                RelativePath = $relativePath
                Kind = $kind
                MaximumBytes = switch ($kind) {
                    'manifest' { 256KB }
                    'screenshot' { $script:LiveEvidenceMaximumScreenshotBytes }
                    default { $script:LiveEvidenceMaximumGuestFileBytes }
                }
            }
        }
    )
    $snapshot = Get-GuestLiveEvidenceInventory -Session $Session -ResponseRoot $GuestResponseRoot -CaptureId ([string]$GuestResult.CaptureId) -AllowedFiles $allowedFiles
    $inventory = @($snapshot.Files)
    if ($inventory.Count -lt 1 -or $inventory.Count -gt (2 + $script:LiveEvidenceMaximumGuestFileCount)) {
        throw "The guest live evidence response contains an invalid file count: $($inventory.Count)."
    }

    $guestFileBytes = [long]0
    foreach ($entry in $inventory) {
        $relativePath = [string]$entry.RelativePath
        if (-not $allowed.ContainsKey($relativePath)) { throw "Guest live evidence returned an unrequested file: $relativePath" }
        switch ($allowed[$relativePath]) {
            'manifest' { if ([long]$entry.Length -le 0 -or [long]$entry.Length -gt 256KB) { throw 'The guest live evidence manifest exceeded its size bound.' } }
            'screenshot' { if ([long]$entry.Length -le 0 -or [long]$entry.Length -gt $script:LiveEvidenceMaximumScreenshotBytes) { throw 'The live screenshot exceeded its size bound.' } }
            'guest-file' {
                if ([long]$entry.Length -le 0 -or [long]$entry.Length -gt $script:LiveEvidenceMaximumGuestFileBytes) { throw "Guest evidence file exceeded its size bound: $relativePath" }
                $guestFileBytes += [long]$entry.Length
                if ($guestFileBytes -gt $script:LiveEvidenceMaximumGuestFilesTotalBytes) { throw 'Guest evidence files exceeded their aggregate size bound.' }
            }
        }
    }
    foreach ($requiredPath in $allowed.Keys) {
        if ($allowed[$requiredPath] -eq 'guest-file' -and -not [bool]$GuestResult.Success) { continue }
        if (@($inventory | Where-Object { [string]::Equals([string]$_.RelativePath, $requiredPath, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
            throw "Guest live evidence response is missing an expected file: $requiredPath"
        }
    }

    try {
        New-Item -ItemType Directory -Force -Path $HostStageRoot | Out-Null
        foreach ($entry in $inventory) {
            $destination = Join-Path $HostStageRoot ([string]$entry.RelativePath)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath ([string]$entry.FullName) -Destination $destination -FromSession $Session -Force -ErrorAction Stop
            $hostItem = Get-Item -LiteralPath $destination -Force
            $hostHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            if ([long]$hostItem.Length -ne [long]$entry.Length -or $hostHash -ne [string]$entry.Sha256) {
                throw "Bounded live evidence transfer verification failed: $([string]$entry.RelativePath)"
            }
        }
        $inventory
    }
    finally {
        Invoke-Command -Session $Session -ErrorAction SilentlyContinue -ScriptBlock {
            param($StageRoot)
            $allowedStageRoot = [IO.Path]::GetFullPath('C:\Windows\Temp\CodexLiveEvidenceHostStage').TrimEnd('\') + '\'
            $resolved = [IO.Path]::GetFullPath($StageRoot)
            if ($resolved.StartsWith($allowedStageRoot, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
            }
        } -ArgumentList ([string]$snapshot.StageRoot) | Out-Null
    }
}

function New-HostLiveEvidenceDirectorySecurity {
    param(
        [Parameter(Mandatory = $true)] [string] $ClientSid,
        [switch] $ClientRead
    )

    $clientIdentity = [Security.Principal.SecurityIdentifier]::new($ClientSid)
    $administratorsIdentity = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $systemIdentity = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($administratorsIdentity, $systemIdentity)) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    if ($ClientRead) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $clientIdentity,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    $security
}

function Initialize-HostLiveEvidencePublicationRoot {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestStateRoot,
        [Parameter(Mandatory = $true)] [string] $ClientSid
    )

    $requestRoot = [IO.Path]::GetFullPath($RequestStateRoot).TrimEnd('\')
    $liveRoot = Join-Path $requestRoot 'live-evidence'
    if (-not (Test-Path -LiteralPath $liveRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $liveRoot -ErrorAction Stop | Out-Null
    }
    $item = Get-Item -LiteralPath $liveRoot -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The request-scoped live evidence root is invalid or reparse-backed.'
    }
    [IO.Directory]::SetAccessControl($liveRoot, (New-HostLiveEvidenceDirectorySecurity -ClientSid $ClientSid -ClientRead))
    $liveRoot
}

function Set-HostLiveEvidencePublishedAcl {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ClientSid
    )

    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The completed live evidence staging root is invalid or reparse-backed.'
    }
    foreach ($descendant in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)) {
        if ($descendant.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "The completed live evidence staging tree contains a reparse point: $($descendant.FullName)"
        }
    }
    [IO.Directory]::SetAccessControl($root, (New-HostLiveEvidenceDirectorySecurity -ClientSid $ClientSid -ClientRead))
}

function Get-HostLiveEvidenceInventoryTotalBytes {
    param([AllowEmptyCollection()] [object[]] $Inventory)

    $total = [long]0
    foreach ($entry in @($Inventory)) {
        if ($null -eq $entry -or $null -eq $entry.Length) {
            throw 'A bounded live-evidence inventory entry is missing its Length value.'
        }
        $length = [long]$entry.Length
        if ($length -lt 0 -or $total -gt ([long]::MaxValue - $length)) {
            throw 'The bounded live-evidence inventory byte total is invalid.'
        }
        $total += $length
    }
    $total
}

function Publish-HostLiveEvidenceDirectoryAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $IncomingPath,
        [Parameter(Mandatory = $true)] [string] $FinalPath
    )

    $incoming = [IO.Path]::GetFullPath($IncomingPath).TrimEnd('\')
    $final = [IO.Path]::GetFullPath($FinalPath).TrimEnd('\')
    $incomingVolume = [IO.Path]::GetPathRoot($incoming)
    $finalVolume = [IO.Path]::GetPathRoot($final)
    if (-not [string]::Equals($incomingVolume, $finalVolume, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFileName($incoming).StartsWith('.incoming-', [StringComparison]::Ordinal)) {
        throw 'Live evidence publication requires a broker-private .incoming-* staging tree on the destination volume.'
    }
    if (-not (Test-Path -LiteralPath $incoming -PathType Container)) { throw 'Live evidence staging directory is missing.' }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $final) -PathType Container)) { throw 'Live evidence destination parent is missing.' }
    if (Test-Path -LiteralPath $final) { throw 'Live evidence destination already exists.' }
    [IO.Directory]::Move($incoming, $final)
}

function Remove-GuestLiveEvidenceArtifacts {
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $CaptureId
    )

    Invoke-Command -Session $Session -ErrorAction SilentlyContinue -ScriptBlock {
        param($Id)
        if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') { return }
        foreach ($path in @(
            (Join-Path 'C:\CodexGuest\LiveEvidence\Inbox' ($Id + '.json')),
            (Join-Path 'C:\CodexGuest\LiveEvidence\Processing' ($Id + '.json')),
            (Join-Path 'C:\CodexGuest\LiveEvidence\Responses' $Id),
            (Join-Path 'C:\CodexGuest\LiveEvidence\Transfer' ($Id + '.json'))
        )) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    } -ArgumentList $CaptureId | Out-Null
}

function Invoke-HostLiveEvidenceService {
    param(
        $Context,
        [Parameter(Mandatory = $true)] [System.Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $RequestStateRoot,
        [Parameter(Mandatory = $true)] [string] $LifecycleStage,
        [Parameter(Mandatory = $true)] [int] $ApplicationProcessId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc
    )

    if (-not $Context) {
        $Context = Get-HostLiveEvidenceContext -RequestId $RequestId -Config $Config -ApplicationProcessId $ApplicationProcessId
        if (-not $Context) { return $null }
    }
    $command = $Context.Command
    $captureId = [string]$command.CaptureId
    $layout = Get-LiveEvidenceLayout -BrokerRoot $BrokerRoot
    $responsePath = Join-Path $layout.Responses ($captureId + '.json')
    if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
        Remove-HostLiveEvidenceCommand -CaptureId $captureId -CommandPath ([string]$Context.CommandPath)
        return $null
    }

    $disposition = Get-LiveEvidenceLifecycleDisposition -LifecycleStage $LifecycleStage -ApplicationProcessId $ApplicationProcessId
    if ($disposition -eq 'Terminal' -or [DateTime]::UtcNow -ge $ExecutionDeadlineUtc) {
        Complete-HostLiveEvidenceFailure -Context $Context -Status 'RequestAlreadyTerminal' -FailureKind 'RequestAlreadyTerminal' -Message 'The request became terminal before the live capture could be published.' -LifecycleStage $LifecycleStage -ApplicationProcessId $ApplicationProcessId
        return $null
    }
    if ($disposition -ne 'Supported' -or [int]$command.ExpectedApplicationProcessId -ne $ApplicationProcessId) {
        Complete-HostLiveEvidenceFailure -Context $Context -Status 'StaleWorkerRequestBinding' -FailureKind 'StaleWorkerRequestBinding' -Message 'The request lifecycle or application PID changed after the capture was bound.' -LifecycleStage $LifecycleStage -ApplicationProcessId $ApplicationProcessId
        return $null
    }

    try {
        if ([string]$Context.State -eq 'Claimed') {
            $guestTransferRoot = 'C:\CodexGuest\LiveEvidence\Transfer'
            $guestTransferFile = Join-Path $guestTransferRoot ($captureId + '.json')
            $guestInboxFile = Join-Path 'C:\CodexGuest\LiveEvidence\Inbox' ($captureId + '.json')
            Remove-GuestLiveEvidenceArtifacts -Session $Session -CaptureId $captureId
            Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                param($Root)
                New-Item -ItemType Directory -Force -Path $Root | Out-Null
            } -ArgumentList $guestTransferRoot
            Copy-Item -LiteralPath ([string]$Context.CommandPath) -Destination $guestTransferFile -ToSession $Session -Force -ErrorAction Stop
            Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                param($Transfer, $Inbox)
                Move-Item -LiteralPath $Transfer -Destination $Inbox -Force
            } -ArgumentList $guestTransferFile, $guestInboxFile
            $Context.State = 'GuestSubmitted'
            $Context.GuestSubmittedUtc = [DateTime]::UtcNow
            $captureLimit = $Context.GuestSubmittedUtc.AddMilliseconds([int]$command.CaptureTimeoutMilliseconds + 10000)
            $Context.CaptureDeadlineUtc = if ($captureLimit -lt $ExecutionDeadlineUtc) { $captureLimit } else { $ExecutionDeadlineUtc }
            $command | Add-Member -NotePropertyName GuestSubmittedUtc -NotePropertyValue $Context.GuestSubmittedUtc.ToString('o') -Force
            Write-JsonAtomic -Path ([string]$Context.CommandPath) -Value $command
            return $Context
        }

        $guestResponseRoot = Join-Path 'C:\CodexGuest\LiveEvidence\Responses' $captureId
        $guestResult = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
            param($Root)
            $resultPath = Join-Path $Root 'live-evidence-result.json'
            if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { return $null }
            $item = Get-Item -LiteralPath $resultPath -Force
            if ($item.Length -le 0 -or $item.Length -gt 256KB) { throw 'Guest live evidence result exceeded its size bound.' }
            Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } -ArgumentList $guestResponseRoot
        if (-not $guestResult) {
            if ([DateTime]::UtcNow -ge [DateTime]$Context.CaptureDeadlineUtc) {
                Complete-HostLiveEvidenceFailure -Context $Context -Status 'ScreenshotInfrastructureFailure' -FailureKind 'ScreenshotInfrastructureFailure' -Message 'The interactive guest did not publish a bounded live capture before its capture deadline.' -LifecycleStage $LifecycleStage -ApplicationProcessId $ApplicationProcessId
                Remove-GuestLiveEvidenceArtifacts -Session $Session -CaptureId $captureId
                return $null
            }
            return $Context
        }
        if (-not [string]::Equals([string]$guestResult.CaptureId, $captureId, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$guestResult.RequestId, $RequestId, [StringComparison]::Ordinal) -or
            [int]$guestResult.ApplicationProcessId -ne $ApplicationProcessId) {
            throw 'The guest live evidence result does not match the broker-bound capture identity.'
        }

        $liveRoot = Initialize-HostLiveEvidencePublicationRoot -RequestStateRoot $RequestStateRoot -ClientSid ([string]$Config.ClientSid)
        $finalRoot = Join-Path $liveRoot $captureId
        if (Test-Path -LiteralPath $finalRoot) { throw 'A live evidence directory already exists for this capture ID; refusing to treat it as a fresh capture.' }
        $incomingRoot = Join-Path $layout.Processing ('.incoming-' + $captureId + '-' + [Guid]::NewGuid().ToString('N'))
        $publishedRoot = $null
        try {
            $inventory = @(Copy-GuestLiveEvidenceBounded -Session $Session -GuestResponseRoot $guestResponseRoot -HostStageRoot $incomingRoot -GuestResult $guestResult -RequestedGuestPaths @($command.GuestEvidencePaths))
            $copiedGuestResult = Get-Content -LiteralPath (Join-Path $incomingRoot 'live-evidence-result.json') -Raw | ConvertFrom-Json -ErrorAction Stop
            if (-not [string]::Equals([string]$copiedGuestResult.CaptureId, [string]$guestResult.CaptureId, [StringComparison]::Ordinal) -or
                -not [string]::Equals([string]$copiedGuestResult.RequestId, [string]$guestResult.RequestId, [StringComparison]::Ordinal) -or
                [bool]$copiedGuestResult.Success -ne [bool]$guestResult.Success -or
                -not [string]::Equals([string]$copiedGuestResult.Status, [string]$guestResult.Status, [StringComparison]::Ordinal)) {
                throw 'The broker-owned guest manifest snapshot changed after the live result was observed.'
            }
            if ([bool]$guestResult.Success) {
                if ((ConvertTo-LiveEvidenceUtcString -Value $copiedGuestResult.CapturedUtc) -ne (ConvertTo-LiveEvidenceUtcString -Value $guestResult.CapturedUtc) -or
                    -not [string]::Equals([string]$copiedGuestResult.Screenshot.Sha256, [string]$guestResult.Screenshot.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'The broker-owned guest manifest snapshot does not match the captured screenshot identity.'
                }
                $guestRecords = @($guestResult.GuestEvidenceFiles)
                $requestedPaths = @(Assert-LiveEvidenceRelativePaths -Paths @($command.GuestEvidencePaths))
                if ($guestRecords.Count -ne $requestedPaths.Count) { throw 'The guest evidence manifest does not contain exactly the requested allowlist.' }
                foreach ($relativePath in $requestedPaths) {
                    $record = @($guestRecords | Where-Object { [string]::Equals([string]$_.RelativePath, $relativePath, [StringComparison]::OrdinalIgnoreCase) })
                    if ($record.Count -ne 1) { throw "The guest evidence manifest is missing or duplicates '$relativePath'." }
                    $hostGuestFile = Join-Path (Join-Path $incomingRoot 'files') $relativePath
                    if (-not (Test-Path -LiteralPath $hostGuestFile -PathType Leaf)) { throw "The bounded transfer omitted guest evidence '$relativePath'." }
                    $hostGuestItem = Get-Item -LiteralPath $hostGuestFile -Force
                    $hostGuestHash = (Get-FileHash -LiteralPath $hostGuestFile -Algorithm SHA256).Hash
                    if ([long]$hostGuestItem.Length -ne [long]$record[0].Length -or -not [string]::Equals($hostGuestHash, [string]$record[0].Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Guest evidence integrity verification failed: $relativePath"
                    }
                }
            }
            $currentState = Read-LiveEvidenceJsonSafe -Path (Join-Path $RequestStateRoot 'request-state.json')
            $currentLifecycle = if ($currentState) { [string]$currentState.Status } else { $LifecycleStage }
            $binding = Get-LiveEvidencePoolBinding -BrokerRoot $BrokerRoot -Config $Config -RequestId $RequestId -ExpectedWorkerId $command.ExpectedWorkerId -ExpectedOperationId ([string]$command.ExpectedOperationId)
            $guestProcessStillRunning = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                param($ProcessId)
                $null -ne (Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
            } -ArgumentList $ApplicationProcessId
            $remainedActive = [bool]$guestResult.ApplicationRunningAfterCapture -and [bool]$guestProcessStillRunning -and [bool]$binding.Valid -and
                -not (Test-Path -LiteralPath (Join-Path $RequestStateRoot 'broker-result.json') -PathType Leaf) -and
                (Get-LiveEvidenceLifecycleDisposition -LifecycleStage $currentLifecycle -ApplicationProcessId $ApplicationProcessId) -eq 'Supported'

            $screenshotRecord = $null
            if ([bool]$guestResult.Success) {
                $screenshotPath = Join-Path $incomingRoot 'live-screenshot.png'
                if (-not (Test-Path -LiteralPath $screenshotPath -PathType Leaf)) { throw 'The successful guest response omitted the fresh screenshot.' }
                $screenshotItem = Get-Item -LiteralPath $screenshotPath -Force
                $screenshotHash = (Get-FileHash -LiteralPath $screenshotPath -Algorithm SHA256).Hash
                if ([long]$screenshotItem.Length -ne [long]$guestResult.Screenshot.Length -or $screenshotHash -ne [string]$guestResult.Screenshot.Sha256) { throw 'The host screenshot does not match the guest capture manifest.' }
                if ([int]$guestResult.Screenshot.Width -le 0 -or [int]$guestResult.Screenshot.Height -le 0) { throw 'The guest screenshot dimensions are invalid.' }
                $requestedUtc = [DateTime]::MinValue
                $capturedUtc = [DateTime]::MinValue
                if (-not [DateTime]::TryParse([string]$command.RequestedUtc, [ref]$requestedUtc) -or -not [DateTime]::TryParse([string]$guestResult.CapturedUtc, [ref]$capturedUtc) -or $capturedUtc.ToUniversalTime() -lt $requestedUtc.ToUniversalTime().AddSeconds(-5)) {
                    throw 'The guest screenshot freshness timestamps do not prove this capture attempt is current.'
                }
                $screenshotRecord = [ordered]@{
                    Path = Join-Path $finalRoot 'live-screenshot.png'
                    Length = [long]$screenshotItem.Length
                    Width = [int]$guestResult.Screenshot.Width
                    Height = [int]$guestResult.Screenshot.Height
                    Sha256 = $screenshotHash
                }
            }

            $hostManifest = [ordered]@{
                FormatVersion = 1
                CaptureId = $captureId
                RequestId = $RequestId
                Success = [bool]$guestResult.Success
                Status = [string]$guestResult.Status
                FailureKind = [string]$guestResult.FailureKind
                RequestedUtc = [string]$command.RequestedUtc
                CaptureStartedUtc = [string]$guestResult.CaptureStartedUtc
                CapturedUtc = [string]$guestResult.CapturedUtc
                HostPublishedUtc = [DateTime]::UtcNow.ToString('o')
                WorkerId = if ($null -ne $command.ExpectedWorkerId) { [int]$command.ExpectedWorkerId } else { $null }
                WorkerOperationId = [string]$command.ExpectedOperationId
                LifecycleStage = [string]$command.BoundLifecycleStage
                LifecycleStageAfterCapture = $currentLifecycle
                ApplicationProcessId = $ApplicationProcessId
                ApplicationRunningBeforeCapture = [bool]$guestResult.ApplicationRunningBeforeCapture
                ApplicationRunningAfterCapture = [bool]$guestResult.ApplicationRunningAfterCapture
                RequestRemainedActiveAfterCapture = [bool]$remainedActive
                Screenshot = $screenshotRecord
                GuestEvidenceFiles = @($guestResult.GuestEvidenceFiles | ForEach-Object {
                    [ordered]@{
                        RelativePath = [string]$_.RelativePath
                        Path = Join-Path (Join-Path $finalRoot 'files') ([string]$_.RelativePath)
                        Length = [long]$_.Length
                        Sha256 = [string]$_.Sha256
                        SourceLastWriteUtc = [string]$_.SourceLastWriteUtc
                    }
                })
                BoundedTransferFileCount = $inventory.Count
                BoundedTransferBytes = Get-HostLiveEvidenceInventoryTotalBytes -Inventory $inventory
            }
            Write-JsonAtomic -Path (Join-Path $incomingRoot 'capture.json') -Value $hostManifest
            Set-HostLiveEvidencePublishedAcl -Path $incomingRoot -ClientSid ([string]$Config.ClientSid)
            Publish-HostLiveEvidenceDirectoryAtomic -IncomingPath $incomingRoot -FinalPath $finalRoot
            $publishedRoot = $finalRoot

            if ([bool]$guestResult.Success) {
                $outcome = New-LiveEvidenceOutcome -CaptureId $captureId -RequestId $RequestId -Status 'Captured' -Message 'Fresh broker-mediated live evidence was published atomically.' -Success $true -WorkerId $command.ExpectedWorkerId -LifecycleStage ([string]$command.BoundLifecycleStage) -ApplicationProcessId $ApplicationProcessId -EvidencePath $finalRoot -Details $hostManifest
                $outcome['CapturedUtc'] = [string]$guestResult.CapturedUtc
                $outcome['Screenshot'] = $screenshotRecord
                $outcome['GuestEvidenceFiles'] = @($hostManifest.GuestEvidenceFiles)
                $outcome['RequestRemainedActiveAfterCapture'] = [bool]$remainedActive
                Write-LiveEvidenceOutcome -BrokerRoot $BrokerRoot -CaptureId $captureId -Outcome $outcome | Out-Null
            }
            else {
                Complete-HostLiveEvidenceFailure -Context $Context -Status ([string]$guestResult.Status) -FailureKind ([string]$guestResult.FailureKind) -Message ([string]$guestResult.Message) -LifecycleStage $LifecycleStage -ApplicationProcessId $ApplicationProcessId -EvidencePath $finalRoot -Details $hostManifest
            }
        }
        catch {
            if ($publishedRoot -and (Test-Path -LiteralPath $publishedRoot -PathType Container)) {
                Remove-Item -LiteralPath $publishedRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            throw
        }
        finally {
            Remove-Item -LiteralPath $incomingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-GuestLiveEvidenceArtifacts -Session $Session -CaptureId $captureId
        Remove-HostLiveEvidenceCommand -CaptureId $captureId -CommandPath ([string]$Context.CommandPath)
        return $null
    }
    catch {
        Complete-HostLiveEvidenceFailure -Context $Context -Status 'ScreenshotInfrastructureFailure' -FailureKind 'ScreenshotInfrastructureFailure' -Message $_.Exception.Message -LifecycleStage $LifecycleStage -ApplicationProcessId $ApplicationProcessId
        try { Remove-GuestLiveEvidenceArtifacts -Session $Session -CaptureId $captureId } catch { }
        return $null
    }
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
    $hostInputShareCleanupPerformed = $false
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
    $expectGuestPowerOff = $false
    $guestPowerOffRecoveryTimeoutSeconds = 180
    $expectedGuestPowerOffSubmissionStartedUtc = $null
    $guestApplicationEraRunningObservedUtc = $null
    $guestPowerOffObservedUtc = $null
    $guestPowerOffBeforeCleanup = $null
    $powerOffRecoveryDeadlineUtc = $null
    $guestPowerOffEvidenceRecoveryBootedUtc = $null
    $guestPowerOffEvidenceRecoveryGuestBootTimeUtc = $null
    $guestPowerOffEvidenceRecoveryCompletedUtc = $null
    $guestPowerOffEvidenceRecoveryTimedOut = $false
    $applicationRelaunchedByHarnessAfterGuestPowerOff = $null
    $expectedGuestPowerOffContractSatisfied = $null
    $brokerCleanupStartedUtc = $null
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
    $liveEvidenceContext = $null
    $executionTimeoutSeconds = Get-BoundedTimeout -Value $Request.ExecutionTimeoutSeconds -Default 900 -Minimum 10 -Maximum 7200
    $executionDeadlineUtc = $ClaimedUtc.AddSeconds($executionTimeoutSeconds)
    $originalExecutionDeadlineUtc = $executionDeadlineUtc
    $createdUtc = [DateTime]::Parse([string]$Request.CreatedUtc).ToUniversalTime()

    [CodexHostSession]::PreventSleep()
    try {
        $null = Recover-OrphanedHostInputResources -BrokerRoot $BrokerRoot
        # Recovery is owner/identity-aware. Do not exclude the current
        # RequestId: a crashed attempt can leave a stale lease with the same
        # RequestId, and retries must reclaim it before reserving a new one.
        $null = Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
            Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot
        }
        $failureStage = 'ValidatingRequest'
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
        $expectPropertyLookup = $Request.PSObject.Properties['ExpectGuestPowerOff']
        $expectProperty = @($Request.PSObject.Properties | Where-Object { $_.Name -ceq 'ExpectGuestPowerOff' }) | Select-Object -First 1
        if ($expectPropertyLookup -and -not $expectProperty) {
            throw 'The top-level expected-power-off property name must use exact case: ExpectGuestPowerOff.'
        }
        if ($expectProperty) {
            if ($Request.ExpectGuestPowerOff -isnot [bool]) {
                throw 'ExpectGuestPowerOff must be an exact JSON Boolean.'
            }
            $expectGuestPowerOff = [bool]$Request.ExpectGuestPowerOff
            if (-not $expectGuestPowerOff) {
                throw 'ExpectGuestPowerOff must be omitted for legacy requests or set to exact Boolean true.'
            }
        }
        $jobExpectPropertyLookup = if ($Request.Job) { $Request.Job.PSObject.Properties['expectGuestPowerOff'] } else { $null }
        $jobExpectProperty = if ($Request.Job) { @($Request.Job.PSObject.Properties | Where-Object { $_.Name -ceq 'expectGuestPowerOff' }) | Select-Object -First 1 } else { $null }
        if ($jobExpectPropertyLookup -and -not $jobExpectProperty) {
            throw 'The guest expected-power-off property name must use exact case: expectGuestPowerOff.'
        }
        if ($jobExpectProperty -and
            ($Request.Job.expectGuestPowerOff -isnot [bool] -or -not [bool]$Request.Job.expectGuestPowerOff -or -not $expectGuestPowerOff)) {
            throw 'The guest job expectGuestPowerOff property is accepted only as exact Boolean true with top-level ExpectGuestPowerOff=true.'
        }
        $recoveryTimeoutPropertyLookup = $Request.PSObject.Properties['GuestPowerOffRecoveryTimeoutSeconds']
        $recoveryTimeoutProperty = @($Request.PSObject.Properties | Where-Object { $_.Name -ceq 'GuestPowerOffRecoveryTimeoutSeconds' }) | Select-Object -First 1
        if ($recoveryTimeoutPropertyLookup -and -not $recoveryTimeoutProperty) {
            throw 'The recovery-timeout property name must use exact case: GuestPowerOffRecoveryTimeoutSeconds.'
        }
        if ($recoveryTimeoutProperty -and -not $expectGuestPowerOff) {
            throw 'GuestPowerOffRecoveryTimeoutSeconds is accepted only when ExpectGuestPowerOff is true.'
        }
        if ($expectGuestPowerOff) {
            if ($Request.ResetToBaseline -isnot [bool] -or -not [bool]$Request.ResetToBaseline -or
                $Request.StopAfter -isnot [bool] -or -not [bool]$Request.StopAfter) {
                throw 'ExpectGuestPowerOff requires exact Boolean ResetToBaseline=true and StopAfter=true.'
            }
            if (-not $recoveryTimeoutProperty) {
                throw 'ExpectGuestPowerOff requires GuestPowerOffRecoveryTimeoutSeconds.'
            }
            $recoveryTimeoutValue = $Request.GuestPowerOffRecoveryTimeoutSeconds
            $recoveryTimeoutType = if ($null -ne $recoveryTimeoutValue) { $recoveryTimeoutValue.GetType() } else { $null }
            $integralTimeoutTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
            if (-not $recoveryTimeoutType -or $recoveryTimeoutType -notin $integralTimeoutTypes) {
                throw 'GuestPowerOffRecoveryTimeoutSeconds must be an integer between 30 and 600.'
            }
            try { $guestPowerOffRecoveryTimeoutSeconds = [int]$recoveryTimeoutValue }
            catch { throw 'GuestPowerOffRecoveryTimeoutSeconds must be an integer between 30 and 600.' }
            if ($guestPowerOffRecoveryTimeoutSeconds -lt 30 -or $guestPowerOffRecoveryTimeoutSeconds -gt 600) {
                throw 'GuestPowerOffRecoveryTimeoutSeconds must be between 30 and 600.'
            }
            if (-not $jobExpectProperty -or $Request.Job.expectGuestPowerOff -isnot [bool] -or -not [bool]$Request.Job.expectGuestPowerOff) {
                throw 'ExpectGuestPowerOff requires the guest job expectGuestPowerOff property to be exact Boolean true.'
            }
            if (-not ($Request.Job.PSObject.Properties.Name -contains 'assertResultFile') -or [string]::IsNullOrWhiteSpace([string]$Request.Job.assertResultFile)) {
                throw 'ExpectGuestPowerOff requires a guest job assertResultFile marker.'
            }
        }
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
            $requestNetworkRuntime = Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
                New-RequestNetworkRuntime -BrokerRoot $BrokerRoot -Definition $requestNetworkDefinition -RequestId $requestId -VmName $vmName -WorkerId $requestNetworkWorkerId
            }
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
            $requestNetworkAttachment = Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
                Prepare-RequestVmNetwork -Runtime $requestNetworkRuntime -VmName $vmName -BrokerRoot $BrokerRoot
            }
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
            $requestNetworkConnection = Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
                Connect-RequestVmNetwork -Runtime $requestNetworkRuntime -VmName $vmName -BrokerRoot $BrokerRoot
            }
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
            if ($actionType -eq 'send_keys') {
                $null = Get-ValidatedKeyChord -Action $action -Context "Action $($actionIndex + 1)"
            }
            foreach ($property in @($action.PSObject.Properties)) {
                if ($property.Value -isnot [string]) {
                    continue
                }
                $tokensAllowedHere = if ($property.Name -eq 'type' -or ($actionType -eq 'screenshot' -and $property.Name -eq 'name') -or ($actionType -eq 'send_keys' -and $property.Name -eq 'keys')) {
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
            if ($expectGuestPowerOff) {
                $assertResultPath = [IO.Path]::GetFullPath([string]$job.assertResultFile)
                foreach ($reservedGuestProtocolFile in @('result.json', 'agent-error.json', 'lease.json')) {
                    if ([string]::Equals($assertResultPath, [IO.Path]::GetFullPath((Join-Path $guestOutbox $reservedGuestProtocolFile)), [StringComparison]::OrdinalIgnoreCase)) {
                        throw "ExpectGuestPowerOff assertResultFile must not collide with reserved guest protocol file '$reservedGuestProtocolFile'."
                    }
                }
            }
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
        # PowerShell Direct exposes the destination filename before Copy-Item
        # has necessarily finished writing it. Copy into an unwatched directory
        # first, then rename on the guest so the inbox only sees complete JSON.
        $guestTransferRoot = 'C:\CodexGuest\Transfer'
        $guestTransferFile = Join-Path $guestTransferRoot ($requestId + '.json')
        $guestInboxFile = Join-Path 'C:\CodexGuest\Inbox' ($requestId + '.json')
        $guestProcessingFile = Join-Path 'C:\CodexGuest\Processing' ($requestId + '.json')
        $guestCompletedFile = Join-Path 'C:\CodexGuest\Completed' ($requestId + '.json')
        if ($expectGuestPowerOff) {
            # After the no-replay marker, the broker must never block inside an
            # in-process PowerShell Direct call. Close the setup session first;
            # delivery and monitoring use disposable watchdog children below.
            if ($session) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                $session = $null
            }
            # From this atomic publication onward, delivery is ambiguous after
            # a host crash. Recovery must fail terminally rather than risk a
            # second launch, even if no guest lease was observed yet.
            $existingSubmissionState = $null
            $existingSubmissionStatePath = Join-Path $RequestStateRoot 'request-state.json'
            if (Test-Path -LiteralPath $existingSubmissionStatePath -PathType Leaf) {
                $existingSubmissionState = Read-BrokerJsonWithRetry -Path $existingSubmissionStatePath
            }
            $existingSubmissionProperty = if ($existingSubmissionState) { $existingSubmissionState.PSObject.Properties['ExpectedGuestPowerOffSubmissionStartedUtc'] } else { $null }
            $existingMayLaunchProperty = if ($existingSubmissionState) { $existingSubmissionState.PSObject.Properties['GuestJobMayHaveLaunched'] } else { $null }
            $existingSubmissionIsAmbiguous = $existingSubmissionProperty -and -not [string]::IsNullOrWhiteSpace([string]$existingSubmissionProperty.Value) -and
                $existingMayLaunchProperty -and $existingMayLaunchProperty.Value -is [bool] -and [bool]$existingMayLaunchProperty.Value
            $expectedGuestPowerOffSubmissionStartedUtc = if ($existingSubmissionIsAmbiguous) { [string]$existingSubmissionProperty.Value } else { [DateTime]::UtcNow.ToString('o') }
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'LaunchingApplication' -Message 'Expected-power-off job delivery is starting; automatic replay is now prohibited.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $originalExecutionDeadlineUtc -WorkerId $workerId -ExpectGuestPowerOff $true -ExpectedGuestPowerOffSubmissionStartedUtc $expectedGuestPowerOffSubmissionStartedUtc -GuestJobMayHaveLaunched $true
        }
        else {
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'LaunchingApplication' -Message 'Submitting the guest job; the application has not yet been confirmed started.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
        }
        Write-BrokerState -Status 'LaunchingApplication' -RequestId $requestId -Message 'Submitting the guest job and waiting for Start-Process confirmation.'
        $jobSubmitted = $false
        if ($expectGuestPowerOff) {
            $jobSubmissionAttempts = 1
            try {
                $null = Invoke-ExpectedPowerOffJobSubmissionBounded -VmName $vmName -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc -JobPath $guestJobPath -GuestTransferRoot $guestTransferRoot -GuestTransferFile $guestTransferFile -GuestInboxFile $guestInboxFile -GuestProcessingFile $guestProcessingFile -GuestCompletedFile $guestCompletedFile -GuestOutbox $guestOutbox
            }
            catch {
                $failureKind = 'ExpectedGuestPowerOffSubmissionInterrupted'
                throw
            }
            $jobSubmitted = $true
            $jobSubmittedUtc = [DateTime]::UtcNow
        }
        else {
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
            if ($expectGuestPowerOff) {
                $observedVmState = [string](Get-VM -Name $vmName -ErrorAction Stop).State
                $powerObservation = Get-ExpectedGuestPowerOffObservation `
                    -Enabled $true `
                    -VmState $observedVmState `
                    -ApplicationConfirmed $applicationRunningPublished `
                    -ApplicationEraRunningObservedUtc $guestApplicationEraRunningObservedUtc `
                    -BrokerCleanupStartedUtc $brokerCleanupStartedUtc
                if ([string]$powerObservation.Action -eq 'Fail') {
                    $failureKind = [string]$powerObservation.FailureKind
                    throw [InvalidOperationException]::new([string]$powerObservation.Message)
                }
                if ([string]$powerObservation.Action -eq 'RecordApplicationEraRunning') {
                    $guestApplicationEraRunningObservedUtc = [DateTime]::UtcNow.ToString('o')
                }
                elseif ([string]$powerObservation.Action -eq 'RecordGuestPowerOff') {
                    $powerOffObservedTimestamp = [DateTime]::UtcNow
                    if ($powerOffObservedTimestamp -ge $originalExecutionDeadlineUtc) {
                        $failureKind = 'ExpectedGuestPowerOffNotObserved'
                        throw [TimeoutException]::new('The VM did not reach the expected Off state before the original application execution deadline.')
                    }
                    $guestPowerOffObservedUtc = $powerOffObservedTimestamp.ToString('o')
                    $guestPowerOffBeforeCleanup = $true
                    $powerOffRecoveryDeadlineUtc = $powerOffObservedTimestamp.AddSeconds($guestPowerOffRecoveryTimeoutSeconds)
                    $executionDeadlineUtc = $powerOffRecoveryDeadlineUtc
                    # Persist the causal observation before any advisory live-
                    # evidence/session work. Pool recovery uses this atomic
                    # state to fail closed instead of replaying the AUT if the
                    # request worker exits in the following recovery window.
                    Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'GuestPowerOffObserved' -Message 'Confirmed guest power-off observed; preparing isolated evidence recovery.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $originalExecutionDeadlineUtc -WorkerId $workerId -ExpectGuestPowerOff $true -GuestApplicationEraRunningObservedUtc $guestApplicationEraRunningObservedUtc -GuestPowerOffObservedUtc $guestPowerOffObservedUtc -GuestPowerOffBeforeCleanup $true -PowerOffRecoveryDeadlineUtc $powerOffRecoveryDeadlineUtc.ToString('o')
                    if ($liveEvidenceContext) {
                        try {
                            Complete-HostLiveEvidenceFailure -Context $liveEvidenceContext -Status 'GuestPoweredOff' -FailureKind 'GuestPoweredOff' -Message 'The expected guest power-off ended the live application stage before any pending host capture could complete.' -LifecycleStage 'GuestPowerOffObserved' -ApplicationProcessId ([int]$liveEvidenceContext.Command.ExpectedApplicationProcessId)
                        }
                        catch {
                        }
                        $liveEvidenceContext = $null
                    }
                    if ($session) {
                        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                        $session = $null
                    }
                    Write-BrokerState -Status 'GuestPowerOffObserved' -RequestId $requestId -Message 'The broker observed the confirmed application-era VM transition from Running to Off before cleanup.'
                    break
                }
            }
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
                if ($expectGuestPowerOff) {
                    $completionState = Get-ExpectedPowerOffJobObservation -VmName $vmName -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc -InboxFile $guestInboxFile -ProcessingFile $guestProcessingFile -CompletedFile $guestCompletedFile -Outbox $guestOutbox
                }
                else {
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
            $firstApplicationConfirmation = -not $applicationRunningPublished -and [bool]$guestLifecycle.ApplicationConfirmed
            if ($firstApplicationConfirmation -and $expectGuestPowerOff) {
                # Re-sample only after the guest lease proves Start-Process.
                # Persist that application-era Running proof immediately: an
                # AUT may execute shutdown /s /t 0 before any advisory
                # lifecycle/live-evidence work completes.
                $confirmationVmState = [string](Get-VM -Name $vmName -ErrorAction Stop).State
                $confirmationObservation = Get-ExpectedGuestPowerOffObservation -Enabled $true -VmState $confirmationVmState -ApplicationConfirmed $true -ApplicationEraRunningObservedUtc $guestApplicationEraRunningObservedUtc -BrokerCleanupStartedUtc $brokerCleanupStartedUtc
                if ([string]$confirmationObservation.Action -eq 'Fail') {
                    $failureKind = [string]$confirmationObservation.FailureKind
                    throw [InvalidOperationException]::new([string]$confirmationObservation.Message)
                }
                if ([string]$confirmationObservation.Action -ne 'RecordApplicationEraRunning') {
                    $failureKind = 'ExpectedGuestPowerOffUnproven'
                    throw [InvalidOperationException]::new("The VM was '$confirmationVmState' when the application launch was confirmed; an application-era Running observation is required.")
                }
                $applicationRunningPublished = $true
                $guestApplicationEraRunningObservedUtc = [DateTime]::UtcNow.ToString('o')
                Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'ApplicationRunning' -Message 'Guest Start-Process confirmation and application-era VM Running state were both observed.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $originalExecutionDeadlineUtc -WorkerId $workerId -ApplicationProcessId ([int]$guestLifecycle.ApplicationProcessId) -ApplicationStartedUtc ([string]$guestLifecycle.ApplicationStartedUtc) -ExpectGuestPowerOff $true -GuestApplicationEraRunningObservedUtc $guestApplicationEraRunningObservedUtc
                # Leave the confirmation visible for at least one runner poll
                # before publishing guest-action progress.
                Start-Sleep -Milliseconds 750
                continue
            }
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

            $liveApplicationProcessId = if ($null -ne $guestLifecycle.ApplicationProcessId) {
                [int]$guestLifecycle.ApplicationProcessId
            }
            elseif ($completionState.ApplicationLease -and $null -ne $completionState.ApplicationLease.ProcessId) {
                [int]$completionState.ApplicationLease.ProcessId
            }
            else { 0 }
            if ($expectGuestPowerOff -and $liveApplicationProcessId -gt 0 -and [string]$guestLifecycle.Status -in @('ApplicationRunning', 'GuestAction')) {
                # Exact expected-power-off monitoring deliberately owns no
                # in-process guest session. Resolve pending capture commands
                # host-side instead of risking a blocking remoting transaction.
                $unavailableLiveEvidence = Get-HostLiveEvidenceContext -RequestId $requestId -Config $Config -ApplicationProcessId $liveApplicationProcessId
                if ($unavailableLiveEvidence) {
                    Complete-HostLiveEvidenceFailure -Context $unavailableLiveEvidence -Status 'CaptureUnavailableForExpectedPowerOff' -FailureKind 'CaptureUnavailableForExpectedPowerOff' -Message 'Live capture is unavailable while an exact expected-power-off run is monitored through watchdog-isolated guest probes.' -LifecycleStage ([string]$guestLifecycle.Status) -ApplicationProcessId $liveApplicationProcessId
                }
            }
            elseif ($session -and $liveApplicationProcessId -gt 0 -and [string]$guestLifecycle.Status -in @('ApplicationRunning', 'GuestAction')) {
                try {
                    $liveEvidenceContext = Invoke-HostLiveEvidenceService `
                        -Context $liveEvidenceContext `
                        -Session $session `
                        -RequestId $requestId `
                        -Config $Config `
                        -RequestStateRoot $RequestStateRoot `
                        -LifecycleStage ([string]$guestLifecycle.Status) `
                        -ApplicationProcessId $liveApplicationProcessId `
                        -ExecutionDeadlineUtc $executionDeadlineUtc
                }
                catch {
                    if ($liveEvidenceContext) {
                        try {
                            Complete-HostLiveEvidenceFailure -Context $liveEvidenceContext -Status 'ScreenshotInfrastructureFailure' -FailureKind 'ScreenshotInfrastructureFailure' -Message $_.Exception.Message -LifecycleStage ([string]$guestLifecycle.Status) -ApplicationProcessId $liveApplicationProcessId
                        }
                        catch {
                        }
                    }
                    $liveEvidenceContext = $null
                }
            }

            if ($firstApplicationConfirmation) {
                $applicationRunningPublished = $true
                # Leave the confirmation visible for at least one runner poll
                # before publishing guest-action progress.
                Start-Sleep -Milliseconds 750
                continue
            }

            if ($completionState.Result -or $completionState.AgentError) {
                if ($expectGuestPowerOff) {
                    if ($completionState.AgentError) {
                        $failureKind = 'ExpectedGuestPowerOffGuestFailure'
                        throw 'The guest agent failed before the expected guest power-off was observed.'
                    }
                    Write-BrokerState -Status 'AwaitingExpectedGuestPowerOff' -RequestId $requestId -Message 'Guest result exists; waiting for the causally observed application-era VM power-off.'
                    Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'AwaitingExpectedGuestPowerOff' -Message 'Guest result exists; waiting for a broker-observed VM Off state before cleanup.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $originalExecutionDeadlineUtc -WorkerId $workerId -ExpectGuestPowerOff $true -GuestApplicationEraRunningObservedUtc $guestApplicationEraRunningObservedUtc
                    Start-Sleep -Milliseconds 500
                    continue
                }
                if ($liveEvidenceContext) {
                    Complete-HostLiveEvidenceFailure -Context $liveEvidenceContext -Status 'RequestAlreadyTerminal' -FailureKind 'RequestAlreadyTerminal' -Message 'The guest request reached terminal evidence before the live capture completed.' -LifecycleStage 'CollectingEvidence' -ApplicationProcessId $(if ($liveApplicationProcessId -gt 0) { $liveApplicationProcessId } else { $null })
                    $liveEvidenceContext = $null
                }
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

        if ($expectGuestPowerOff) {
            if ([string]::IsNullOrWhiteSpace($guestPowerOffObservedUtc) -or -not [bool]$guestPowerOffBeforeCleanup) {
                $failureKind = 'ExpectedGuestPowerOffUnproven'
                throw 'Expected guest power-off recovery was reached without a causal Running-to-Off observation before cleanup.'
            }

            $failureStage = 'RevokingNetworkBeforePowerOffRecovery'
            if ($requestNetworkRuntime -and -not $requestNetworkCleanupPerformed) {
                $requestNetworkCleanup = Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
                    Remove-RequestNetworkRuntime -Runtime $requestNetworkRuntime -BrokerRoot $BrokerRoot -SuppressErrors
                }
                if (-not $requestNetworkCleanup.Success) {
                    $cleanupFailureObserved = $true
                    $failureKind = 'GuestPowerOffEvidenceRecoveryNetworkCleanup'
                    throw ('Request-network cleanup failed before expected-power-off evidence recovery: ' + (@($requestNetworkCleanup.Errors) -join ' | '))
                }
                $requestNetworkCleanupPerformed = $true
            }
            if ($hostInputShareRuntime -and -not $hostInputCleanup.Attempted) {
                $hostInputCleanup.Attempted = $true
                $shareCleanup = Remove-HostInputShareRuntime -Runtime $hostInputShareRuntime -BrokerRoot $BrokerRoot -SuppressErrors
                $hostInputCleanup = [pscustomobject][ordered]@{
                    Attempted = $true
                    Success = [bool]$shareCleanup.Success
                    Errors = @($shareCleanup.Errors)
                    StateDeleted = [bool]$shareCleanup.StateDeleted
                }
                if (-not $shareCleanup.Success) {
                    $cleanupFailureObserved = $true
                    $failureKind = 'GuestPowerOffEvidenceRecoveryHostInputCleanup'
                    throw ('Read-only host-input cleanup failed before expected-power-off evidence recovery: ' + (@($shareCleanup.Errors) -join ' | '))
                }
                $hostInputShareCleanupPerformed = $true
            }
            $connectedRecoveryAdapters = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) })
            if ($connectedRecoveryAdapters.Count -ne 0) {
                $failureKind = 'GuestPowerOffEvidenceRecoveryNetwork'
                throw 'The broker refused to boot expected-power-off evidence recovery while a VM network adapter remained connected.'
            }

            $failureStage = 'RecoveringGuestPowerOffEvidence'
            Write-BrokerState -Status 'RecoveringPowerOffEvidence' -RequestId $requestId -Message 'Network is revoked; booting the same disposable guest once to finalize persisted marker evidence without relaunching the application.'
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'RecoveringPowerOffEvidence' -Message 'Network is revoked; performing one controlled evidence-recovery boot without resubmitting the job.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $originalExecutionDeadlineUtc -WorkerId $workerId -ExpectGuestPowerOff $true -GuestApplicationEraRunningObservedUtc $guestApplicationEraRunningObservedUtc -GuestPowerOffObservedUtc $guestPowerOffObservedUtc -GuestPowerOffBeforeCleanup $true -PowerOffRecoveryDeadlineUtc $powerOffRecoveryDeadlineUtc.ToString('o')
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $powerOffRecoveryDeadlineUtc
            Start-VM -Name $vmName -ErrorAction Stop | Out-Null
            $guestPowerOffEvidenceRecoveryBootedUtc = [DateTime]::UtcNow
            $guestState = Wait-GuestSession -VmName $vmName -Credential $credential -NotBeforeUtc $guestPowerOffEvidenceRecoveryBootedUtc -RequestId $requestId -ExecutionDeadlineUtc $powerOffRecoveryDeadlineUtc -RequireCurrentGuestBootTime
            $recoveryStateBootProperty = @($guestState.PSObject.Properties | Where-Object { $_.Name -ceq 'GuestBootTimeUtc' }) | Select-Object -First 1
            if (-not $recoveryStateBootProperty -or [string]::IsNullOrWhiteSpace([string]$recoveryStateBootProperty.Value)) {
                $failureKind = 'GuestPowerOffEvidenceRecoveryBootUnproven'
                throw 'The fresh recovery guest agent state did not publish its current guest boot epoch.'
            }
            $guestPowerOffEvidenceRecoveryGuestBootTimeUtc = [string]$recoveryStateBootProperty.Value
            while ($true) {
                Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $powerOffRecoveryDeadlineUtc
                try {
                    # Every PowerShell Direct attempt lives in a disposable
                    # child process. The parent can therefore enforce the
                    # request cancellation and recovery deadline even if the
                    # remoting provider wedges during connection or invocation.
                    $recoveryPresence = Get-ExpectedPowerOffRecoveryPresence -VmName $vmName -RequestId $requestId -ExecutionDeadlineUtc $powerOffRecoveryDeadlineUtc -InboxFile $guestInboxFile -ProcessingFile $guestProcessingFile -CompletedFile $guestCompletedFile -Outbox $guestOutbox
                    $guestSessionReconnects++
                }
                catch [OperationCanceledException] {
                    throw
                }
                catch [TimeoutException] {
                    throw
                }
                catch {
                    Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $powerOffRecoveryDeadlineUtc
                    $recoveryVmState = [string](Get-VM -Name $vmName -ErrorAction Stop).State
                    if ([string]::Equals($recoveryVmState, 'Off', [StringComparison]::OrdinalIgnoreCase)) {
                        $failureKind = 'GuestPowerOffApplicationRelaunchRisk'
                        throw 'The recovery guest powered off again while its session was reconnecting; application relaunch cannot be excluded.'
                    }
                    Write-BrokerState -Status 'RecoveringPowerOffEvidence' -RequestId $requestId -Message 'The post-reboot guest session was interrupted; reconnecting without resubmitting the application job.'
                    Start-Sleep -Milliseconds 250
                    continue
                }
                if ($recoveryPresence.Inbox) {
                    $failureKind = 'GuestPowerOffApplicationRelaunchRisk'
                    throw 'Expected-power-off recovery found the job runnable in Inbox; the broker refuses to risk relaunching the application.'
                }
                if ($recoveryPresence.AgentError) {
                    $failureKind = 'GuestPowerOffEvidenceRecoveryFailure'
                    throw 'Expected-power-off recovery produced a guest agent error instead of valid evidence.'
                }
                if ($recoveryPresence.Completed -and $recoveryPresence.Result -and -not $recoveryPresence.Processing) {
                    break
                }
                $recoveryVmState = [string](Get-VM -Name $vmName -ErrorAction Stop).State
                if ([string]::Equals($recoveryVmState, 'Off', [StringComparison]::OrdinalIgnoreCase)) {
                    $failureKind = 'GuestPowerOffApplicationRelaunchRisk'
                    throw 'The recovery guest powered off again before evidence became terminal; application relaunch cannot be excluded.'
                }
                Write-BrokerState -Status 'RecoveringPowerOffEvidence' -RequestId $requestId -Message 'Waiting for the post-reboot guest agent to make persisted marker evidence terminal.'
                Start-Sleep -Milliseconds 250
            }
        }

        if ($requestNetworkRuntime -and -not $requestNetworkCleanupPerformed) {
            $failureStage = 'VerifyingNetwork'
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc

            # Guest-job completion is the network-use boundary. Revoke the
            # request adapter before taking a potentially long evidence
            # snapshot or publishing any best-effort status update.
            $requestNetworkCleanup = Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
                Remove-RequestNetworkRuntime -Runtime $requestNetworkRuntime -BrokerRoot $BrokerRoot -SuppressErrors
            }
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
        if ($expectGuestPowerOff) {
            $failureStage = 'CopyingRecoveredGuestEvidence'
            Write-BrokerState -Status 'RecoveringPowerOffEvidence' -RequestId $requestId -Message 'Copying and staging recovered guest evidence through a deadline-bounded child process.'
            Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'RecoveringPowerOffEvidence' -Message 'Copying recovered evidence within the configured recovery deadline.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $originalExecutionDeadlineUtc -WorkerId $workerId -ExpectGuestPowerOff $true -GuestApplicationEraRunningObservedUtc $guestApplicationEraRunningObservedUtc -GuestPowerOffObservedUtc $guestPowerOffObservedUtc -GuestPowerOffBeforeCleanup $true -PowerOffRecoveryDeadlineUtc $powerOffRecoveryDeadlineUtc.ToString('o')
            for ($evidenceAttempt = 1; $evidenceAttempt -le 3; $evidenceAttempt++) {
                $evidenceSnapshotAttempts = $evidenceAttempt
                $evidenceTransferAttempts = $evidenceAttempt
                $boundedHostStageRoot = $null
                $promotionStarted = $false
                try {
                    $boundedTransfer = Invoke-ExpectedPowerOffEvidenceTransferBounded -VmName $vmName -RequestId $requestId -ExecutionDeadlineUtc $powerOffRecoveryDeadlineUtc -GuestOutbox $guestOutbox -HostResultRoot $ResultRoot
                    $evidenceManifest = $boundedTransfer.Manifest
                    $boundedHostStageRoot = [string]$boundedTransfer.HostStageRoot
                    if (-not $evidenceManifest -or [string]::IsNullOrWhiteSpace($boundedHostStageRoot)) { throw 'The bounded evidence transfer returned no manifest or host stage.' }
                    $guestOutboxRoot = [IO.Path]::GetFullPath($guestOutbox).TrimEnd('\') + '\'
                    $guestAssertionPath = [IO.Path]::GetFullPath([string]$job.assertResultFile)
                    if (-not $guestAssertionPath.StartsWith($guestOutboxRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'The expected-power-off assertion marker escaped the guest output root.'
                    }
                    $assertionRelativePath = $guestAssertionPath.Substring($guestOutboxRoot.Length)
                    $stagedResultPath = Join-Path $boundedHostStageRoot 'result.json'
                    $resultCopiedMatch = @($evidenceManifest.CopiedFiles | Where-Object { [string]::Equals([string]$_.RelativePath, 'result.json', [StringComparison]::OrdinalIgnoreCase) })
                    $resultSkippedMatch = @($evidenceManifest.SkippedFiles | Where-Object { [string]::Equals([string]$_.RelativePath, 'result.json', [StringComparison]::OrdinalIgnoreCase) })
                    if ($resultCopiedMatch.Count -ne 1 -or $resultSkippedMatch.Count -ne 0 -or -not (Test-Path -LiteralPath $stagedResultPath -PathType Leaf)) {
                        throw "The current bounded transfer did not contain required recovered evidence 'result.json'."
                    }
                    $stagedGuestResult = Read-BrokerJsonWithRetry -Path $stagedResultPath
                    $resultFileEvidenceProperty = $stagedGuestResult.PSObject.Properties['ResultFileEvidence']
                    $markerExistsProperty = if ($resultFileEvidenceProperty) { $resultFileEvidenceProperty.Value.PSObject.Properties['Exists'] } else { $null }
                    $markerPredatesRecoveryProperty = if ($resultFileEvidenceProperty) { $resultFileEvidenceProperty.Value.PSObject.Properties['PredatesRecoveryBoot'] } else { $null }
                    if (-not $markerExistsProperty -or $markerExistsProperty.Value -isnot [bool]) {
                        throw 'Recovered result.json did not contain exact Boolean ResultFileEvidence.Exists.'
                    }
                    if (-not $markerPredatesRecoveryProperty -or $markerPredatesRecoveryProperty.Value -isnot [bool] -or
                        ([bool]$markerExistsProperty.Value -and -not [bool]$markerPredatesRecoveryProperty.Value) -or
                        (-not [bool]$markerExistsProperty.Value -and [bool]$markerPredatesRecoveryProperty.Value)) {
                        throw 'Recovered result.json did not prove a present marker predates the controlled recovery boot.'
                    }
                    $markerCopiedMatch = @($evidenceManifest.CopiedFiles | Where-Object { [string]::Equals([string]$_.RelativePath, $assertionRelativePath, [StringComparison]::OrdinalIgnoreCase) })
                    $markerSkippedMatch = @($evidenceManifest.SkippedFiles | Where-Object { [string]::Equals([string]$_.RelativePath, $assertionRelativePath, [StringComparison]::OrdinalIgnoreCase) })
                    $stagedMarkerPath = Join-Path $boundedHostStageRoot $assertionRelativePath
                    if ([bool]$markerExistsProperty.Value) {
                        if ($markerCopiedMatch.Count -ne 1 -or $markerSkippedMatch.Count -ne 0 -or -not (Test-Path -LiteralPath $stagedMarkerPath -PathType Leaf)) {
                            throw "The current bounded transfer did not contain the recovered assertion marker '$assertionRelativePath'."
                        }
                        $stagedMarkerItem = Get-Item -LiteralPath $stagedMarkerPath -Force -ErrorAction Stop
                        $stagedMarkerHash = (Get-FileHash -LiteralPath $stagedMarkerPath -Algorithm SHA256 -ErrorAction Stop).Hash
                        if ([int64]$stagedMarkerItem.Length -ne [int64]$resultFileEvidenceProperty.Value.Length -or
                            -not [string]::Equals($stagedMarkerHash, [string]$resultFileEvidenceProperty.Value.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                            throw 'The recovered assertion marker did not match ResultFileEvidence length/hash attestation.'
                        }
                    }
                    elseif ($markerCopiedMatch.Count -ne 0 -or (Test-Path -LiteralPath $stagedMarkerPath)) {
                        throw 'Recovered result.json attested a missing marker, but the current bounded transfer contained one.'
                    }
                    $promotionStarted = $true
                    foreach ($stagedItem in @(Get-ChildItem -LiteralPath $boundedHostStageRoot -Force -ErrorAction Stop)) {
                        $destinationPath = Join-Path $ResultRoot $stagedItem.Name
                        if (Test-Path -LiteralPath $destinationPath) {
                            throw "Recovered evidence promotion refused to overwrite an existing host artifact: $destinationPath"
                        }
                        Move-Item -LiteralPath $stagedItem.FullName -Destination $destinationPath -ErrorAction Stop
                    }
                    Remove-Item -LiteralPath $boundedHostStageRoot -Force -ErrorAction SilentlyContinue
                    $evidenceSnapshotSucceeded = $true
                    $evidenceTransferSucceeded = $true
                    break
                }
                catch {
                    $evidenceError = $_
                    if (-not [string]::IsNullOrWhiteSpace($boundedHostStageRoot)) {
                        Remove-Item -LiteralPath $boundedHostStageRoot -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $powerOffRecoveryDeadlineUtc
                    if ($promotionStarted -or $evidenceAttempt -ge 3) { throw $evidenceError }
                    Write-BrokerState -Status 'RecoveringPowerOffEvidence' -RequestId $requestId -Message 'Bounded recovered-evidence transfer was interrupted; retrying without resubmitting the application.'
                    Start-Sleep -Milliseconds 250
                }
            }
            if (-not $evidenceSnapshotSucceeded -or -not $evidenceTransferSucceeded) {
                throw 'Recovered guest evidence could not be copied within the configured recovery deadline.'
            }
            foreach ($skippedFile in @($evidenceManifest.SkippedFiles)) {
                $evidenceWarnings.Add("Skipped optional guest evidence '$([string]$skippedFile.RelativePath)' after $([int]$skippedFile.Attempts) attempts: $([string]$skippedFile.Error)")
            }
            foreach ($enumerationError in @($evidenceManifest.EnumerationErrors)) {
                $evidenceWarnings.Add("Guest evidence enumeration warning: $([string]$enumerationError)")
            }
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $powerOffRecoveryDeadlineUtc
        }
        else {
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
                $evidenceManifest = New-GuestEvidenceSnapshot -Session $session -GuestOutbox $guestOutbox -RequestId $requestId -SnapshotId ([Guid]::NewGuid().ToString('N'))
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
        }
        $failureStage = 'ValidatingGuestEvidence'
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
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
        if ($expectGuestPowerOff) {
            $guestExpectProperty = $guestResult.PSObject.Properties['ExpectGuestPowerOff']
            $guestRelaunchProperty = $guestResult.PSObject.Properties['ApplicationRelaunchedByHarnessAfterGuestPowerOff']
            if (-not $guestExpectProperty -or $guestResult.ExpectGuestPowerOff -isnot [bool] -or -not [bool]$guestResult.ExpectGuestPowerOff) {
                $failureKind = 'GuestPowerOffEvidenceRecoveryProtocol'
                throw 'Recovered guest evidence did not attest exact Boolean ExpectGuestPowerOff=true.'
            }
            if (-not [string]::Equals([string]$guestResult.GuestPowerOffEvidenceRecoveryMode, 'ControlledReboot', [StringComparison]::Ordinal)) {
                $failureKind = 'GuestPowerOffEvidenceRecoveryProtocol'
                throw 'Recovered guest evidence did not attest the ControlledReboot recovery mode.'
            }
            $guestRecoveryBootProperty = @($guestResult.PSObject.Properties | Where-Object { $_.Name -ceq 'GuestBootTimeUtc' }) | Select-Object -First 1
            if (-not $guestRecoveryBootProperty -or [string]::IsNullOrWhiteSpace([string]$guestRecoveryBootProperty.Value)) {
                $failureKind = 'GuestPowerOffEvidenceRecoveryBootUnproven'
                throw 'Recovered guest evidence did not include the exact recovery GuestBootTimeUtc.'
            }
            $guestRecoveryCompletedProperty = @($guestResult.PSObject.Properties | Where-Object { $_.Name -ceq 'RecoveryCompletedUtc' }) | Select-Object -First 1
            $guestRecoveryCompletedTimestamp = $null
            $guestRecoveryBootTimestamp = $null
            if (-not $guestRecoveryCompletedProperty -or [string]::IsNullOrWhiteSpace([string]$guestRecoveryCompletedProperty.Value)) {
                $failureKind = 'GuestPowerOffEvidenceRecoveryProtocol'
                throw 'Recovered guest evidence did not include RecoveryCompletedUtc.'
            }
            try {
                $guestRecoveryBootTimestamp = [DateTimeOffset]::Parse([string]$guestRecoveryBootProperty.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
                $agentStateBootTimestamp = [DateTimeOffset]::Parse([string]$guestPowerOffEvidenceRecoveryGuestBootTimeUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
                $guestRecoveryCompletedTimestamp = [DateTimeOffset]::Parse([string]$guestRecoveryCompletedProperty.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
            }
            catch {
                $failureKind = 'GuestPowerOffEvidenceRecoveryProtocol'
                throw 'Recovered guest evidence included an invalid guest boot or recovery-completion timestamp.'
            }
            if ($guestRecoveryBootTimestamp -ne $agentStateBootTimestamp) {
                $failureKind = 'GuestPowerOffEvidenceRecoveryBootUnproven'
                throw 'Recovered guest evidence does not belong to the current guest OS recovery boot.'
            }
            if ($guestRecoveryCompletedTimestamp -lt $guestRecoveryBootTimestamp) {
                $failureKind = 'GuestPowerOffEvidenceRecoveryBootUnproven'
                throw 'Recovered guest evidence completion predates its current guest OS recovery boot.'
            }
            if (-not $guestRelaunchProperty -or $guestResult.ApplicationRelaunchedByHarnessAfterGuestPowerOff -isnot [bool] -or [bool]$guestResult.ApplicationRelaunchedByHarnessAfterGuestPowerOff) {
                $failureKind = 'GuestPowerOffApplicationRelaunchRisk'
                throw 'Recovered guest evidence did not prove that the application was not relaunched.'
            }
            if ([string]::IsNullOrWhiteSpace($guestApplicationEraRunningObservedUtc) -or
                [string]::IsNullOrWhiteSpace($guestPowerOffObservedUtc) -or
                -not [bool]$guestPowerOffBeforeCleanup) {
                $failureKind = 'ExpectedGuestPowerOffUnproven'
                throw 'Recovered marker evidence exists, but broker-observed guest shutdown causality is incomplete.'
            }
            $applicationRelaunchedByHarnessAfterGuestPowerOff = $false
            $expectedGuestPowerOffContractSatisfied = $true
            Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $powerOffRecoveryDeadlineUtc
            $guestPowerOffEvidenceRecoveryCompletedUtc = [DateTime]::UtcNow
        }
        Assert-RequestActive -RequestId $requestId -ExecutionDeadlineUtc $executionDeadlineUtc
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
        $executionTimedOut = $typedException -is [TimeoutException] -and
            $typedException.Data.Contains('CodexBrokerDeadlineExpired') -and
            $typedException.Data['CodexBrokerDeadlineExpired'] -is [bool] -and
            [bool]$typedException.Data['CodexBrokerDeadlineExpired']
        if ($executionTimedOut -and $expectGuestPowerOff -and -not [string]::IsNullOrWhiteSpace($guestPowerOffObservedUtc)) {
            $executionTimedOut = $false
            $guestPowerOffEvidenceRecoveryTimedOut = $true
            $failureKind = 'GuestPowerOffEvidenceRecoveryTimeout'
        }
        elseif ($executionTimedOut -and $expectGuestPowerOff -and $applicationRunningPublished) {
            $failureKind = 'ExpectedGuestPowerOffNotObserved'
        }
        if ([string]::IsNullOrWhiteSpace($failureKind)) {
            $failureKind = if ($cancelled) { 'Cancelled' } elseif ($executionTimedOut) { 'ExecutionTimeout' } else { 'Harness' }
        }
        $lockEvidenceAfter = Get-HostLockEvidence
    }
    finally {
        $brokerCleanupStartedUtc = [DateTime]::UtcNow.ToString('o')
        if ($liveEvidenceContext) {
            try {
                Complete-HostLiveEvidenceFailure -Context $liveEvidenceContext -Status 'RequestAlreadyTerminal' -FailureKind 'RequestAlreadyTerminal' -Message 'The request left its live application stage before capture publication completed.' -LifecycleStage 'StoppingVm' -ApplicationProcessId ([int]$liveEvidenceContext.Command.ExpectedApplicationProcessId)
            }
            catch {
            }
            $liveEvidenceContext = $null
        }
        if ($requestNetworkRuntime -and -not $requestNetworkCleanupPerformed) {
            $failureStageBeforeCleanup = $failureStage
            $requestNetworkCleanup.Attempted = $true
            try {
                # Revoke first. Status publication is deliberately best effort
                # and must never run ahead of a still-connected adapter.
                $cleanup = Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation {
                    Remove-RequestNetworkRuntime -Runtime $requestNetworkRuntime -BrokerRoot $BrokerRoot -SuppressErrors
                }
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
                Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status 'StoppingVm' -Message 'Stopping the isolated guest; the pool worker will recycle asynchronously.' -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId -ExpectGuestPowerOff $(if ($expectGuestPowerOff) { $true } else { $null }) -GuestApplicationEraRunningObservedUtc $guestApplicationEraRunningObservedUtc -GuestPowerOffObservedUtc $guestPowerOffObservedUtc -GuestPowerOffBeforeCleanup $guestPowerOffBeforeCleanup -PowerOffRecoveryDeadlineUtc $(if ($powerOffRecoveryDeadlineUtc) { $powerOffRecoveryDeadlineUtc.ToString('o') } else { $null }) -BrokerCleanupStartedUtc $brokerCleanupStartedUtc
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

        if ($hostInputShareRuntime -and -not $hostInputShareCleanupPerformed) {
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
                $hostInputShareCleanupPerformed = [bool]$shareCleanup.Success
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
            elseif ($executionTimedOut -and [string]::IsNullOrWhiteSpace($failureKind)) {
                $failureKind = 'ExecutionTimeout'
            }
            elseif ($cleanupFailureObserved -and [string]::IsNullOrWhiteSpace($failureKind)) {
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
        $brokerResultValue = [ordered]@{
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
            ExecutionDeadlineUtc = $originalExecutionDeadlineUtc.ToString('o')
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
        }
        if ($expectGuestPowerOff) {
            $brokerResultValue['ExpectGuestPowerOff'] = $true
            $brokerResultValue['GuestPowerOffRecoveryTimeoutSeconds'] = $guestPowerOffRecoveryTimeoutSeconds
            $brokerResultValue['GuestApplicationEraRunningObservedUtc'] = $guestApplicationEraRunningObservedUtc
            $brokerResultValue['GuestPowerOffObservedUtc'] = $guestPowerOffObservedUtc
            $brokerResultValue['GuestPowerOffBeforeCleanup'] = if ($null -ne $guestPowerOffBeforeCleanup) { [bool]$guestPowerOffBeforeCleanup } else { $null }
            $brokerResultValue['BrokerCleanupStartedUtc'] = $brokerCleanupStartedUtc
            $brokerResultValue['PowerOffRecoveryDeadlineUtc'] = if ($powerOffRecoveryDeadlineUtc) { $powerOffRecoveryDeadlineUtc.ToString('o') } else { $null }
            $brokerResultValue['GuestPowerOffEvidenceRecoveryMode'] = if ($expectedGuestPowerOffContractSatisfied) { 'ControlledReboot' } else { $null }
            $brokerResultValue['GuestPowerOffEvidenceRecoveryBootedUtc'] = if ($guestPowerOffEvidenceRecoveryBootedUtc) { $guestPowerOffEvidenceRecoveryBootedUtc.ToString('o') } else { $null }
            $brokerResultValue['GuestPowerOffEvidenceRecoveryGuestBootTimeUtc'] = $guestPowerOffEvidenceRecoveryGuestBootTimeUtc
            $brokerResultValue['GuestPowerOffEvidenceRecoveryCompletedUtc'] = if ($guestPowerOffEvidenceRecoveryCompletedUtc) { $guestPowerOffEvidenceRecoveryCompletedUtc.ToString('o') } else { $null }
            $brokerResultValue['GuestPowerOffEvidenceRecoveryTimedOut'] = [bool]$guestPowerOffEvidenceRecoveryTimedOut
            $brokerResultValue['ApplicationRelaunchedByHarnessAfterGuestPowerOff'] = $applicationRelaunchedByHarnessAfterGuestPowerOff
            $brokerResultValue['ExpectedGuestPowerOffContractSatisfied'] = [bool]$success -and [bool]$expectedGuestPowerOffContractSatisfied
        }
        $brokerResultPath = Join-Path $ResultRoot 'broker-result.json'
        if ($poolMode) {
            # This attempt root is private to one pool worker. HostWorker later
            # publishes shared state/result under the request mutex.
            Write-TerminalJsonAtomic -Path $brokerResultPath -Value $brokerResultValue | Out-Null
        }
        else {
            Invoke-WithTerminalResultPublicationMutex -RequestId $requestId -ScopeRoot $ResultRoot -Operation {
                if (-not (Test-Path -LiteralPath $brokerResultPath -PathType Leaf)) {
                    Write-RequestState -ResultRoot $RequestStateRoot -RequestId $requestId -Status $finalStatus -Message $finalMessage -CreatedUtc $createdUtc -ClaimedUtc $ClaimedUtc -ExecutionDeadlineUtc $executionDeadlineUtc -WorkerId $workerId
                    Write-TerminalJsonAtomic -Path $brokerResultPath -Value $brokerResultValue | Out-Null
                }
            }
        }
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
    Recover-OrphanedPayloadChildren -VmName ([string]$config.VmName) -ClientSid ([string]$config.ClientSid)
    Recover-InterruptedRequests -Config $config
    $nextCleanupUtc = [DateTime]::MinValue

    while ($true) {
        Write-BrokerState
        try {
            Route-LiveEvidenceRequests -BrokerRoot $BrokerRoot -Config $config
            Reconcile-LiveEvidenceCommands -BrokerRoot $BrokerRoot -Config $config
        }
        catch {
            # Observation commands are auxiliary; malformed or contended
            # requests must not stop the canonical execution queue.
        }
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
        $activeRequestIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($processingRequestFile in @(Get-ChildItem -LiteralPath $processingPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $null = $activeRequestIds.Add([IO.Path]::GetFileNameWithoutExtension($processingRequestFile.Name))
        }
        foreach ($terminalQueuedFile in @($requestFiles)) {
            $terminalQueuedId = [IO.Path]::GetFileNameWithoutExtension($terminalQueuedFile.Name)
            if (Move-QueuedRequestWithTerminalResult -QueuedFile $terminalQueuedFile -RequestId $terminalQueuedId -Reason 'queued-after-terminal') {
                $requestFiles = @($requestFiles | Where-Object { -not [string]::Equals($_.FullName, $terminalQueuedFile.FullName, [StringComparison]::OrdinalIgnoreCase) })
            }
            elseif ($activeRequestIds.Contains($terminalQueuedId)) {
                $duplicateArchive = Join-Path $archivePath ($terminalQueuedId + '-duplicate-active-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N') + '.json')
                Move-Item -LiteralPath $terminalQueuedFile.FullName -Destination $duplicateArchive -ErrorAction Stop
                $requestFiles = @($requestFiles | Where-Object { -not [string]::Equals($_.FullName, $terminalQueuedFile.FullName, [StringComparison]::OrdinalIgnoreCase) })
            }
        }
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
                if (Move-QueuedRequestWithTerminalResult -QueuedFile ([IO.FileInfo]$processingFile) -RequestId $requestId -Reason 'claimed-after-terminal') {
                    continue
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
                    $terminalResult = [ordered]@{
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
                    }
                    $status = if ($queueTimedOut) { 'QueueTimedOut' } else { 'Cancelled' }
                    Invoke-WithTerminalResultPublicationMutex -RequestId $requestId -ScopeRoot $resultRoot -Operation {
                        if (-not (Test-Path -LiteralPath (Join-Path $resultRoot 'broker-result.json') -PathType Leaf)) {
                            Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status $status -Message $errorMessage -CreatedUtc $createdUtc -ClaimedUtc $claimedUtc
                            Write-TerminalJsonAtomic -Path (Join-Path $resultRoot 'broker-result.json') -Value $terminalResult | Out-Null
                        }
                    }
                    continue
                }

                $executionTimeoutSeconds = Get-BoundedTimeout -Value $request.ExecutionTimeoutSeconds -Default 900 -Minimum 10 -Maximum 7200
                Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'Claimed' -Message 'The broker claimed this request.' -CreatedUtc $createdUtc -ClaimedUtc $claimedUtc -ExecutionDeadlineUtc $claimedUtc.AddSeconds($executionTimeoutSeconds)
                Invoke-GuestRequest -Request $request -ResultRoot $resultRoot -Config $config -ClaimedUtc $claimedUtc
            }
            catch {
                $brokerResultFile = Join-Path $resultRoot 'broker-result.json'
                $terminalError = $_.Exception.Message
                Invoke-WithTerminalResultPublicationMutex -RequestId $requestId -ScopeRoot $resultRoot -Operation {
                    if (-not (Test-Path -LiteralPath $brokerResultFile -PathType Leaf)) {
                        Write-RequestState -ResultRoot $resultRoot -RequestId $requestId -Status 'Failed' -Message $terminalError -CreatedUtc $createdUtc -ClaimedUtc $claimedUtc
                        Write-TerminalJsonAtomic -Path $brokerResultFile -Value ([ordered]@{
                            RequestId = $requestId
                            Success = $false
                            Error = $terminalError
                            CreatedUtc = if ($request) { $request.CreatedUtc } else { $null }
                            ClaimedUtc = if ($claimedUtc) { $claimedUtc.ToString('o') } else { $null }
                            Cancelled = $false
                            QueueTimedOut = $false
                            ExecutionTimedOut = $false
                            CompletedUtc = [DateTime]::UtcNow.ToString('o')
                            BrokerIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                            BrokerSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
                        }) | Out-Null
                    }
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
