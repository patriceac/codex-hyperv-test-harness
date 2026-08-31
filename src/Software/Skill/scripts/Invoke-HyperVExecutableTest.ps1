[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ArtifactPath,
    [string] $ExecutableRelativePath,
    [string] $Arguments = '',
    [string] $ActionsPath,
    [string] $ActionsJson,
    [string] $AssertResultFile,
    [string] $AssertResultJsonPointer,
    [string] $AssertResultEqualsJson,
    [switch] $ExpectGuestPowerOff,
    [Alias('HostInput')] [hashtable[]] $ReadOnlyHostInput = @(),
    [ValidateRange(1048576, 1099511627776)] [long] $HostInputColdShareThresholdBytes = 1073741824,
    [ValidateRange(1048576, 1099511627776)] [long] $HostInputIncrementalShareThresholdBytes = 268435456,
    [ValidateSet('None', 'IsolatedTestNet', 'InternetOnly', 'TrustedLan')] [string] $NetworkProfile = 'None',
    [string] $NetworkCohort,
    [switch] $AllowNetworkWithHostInputs,
    [switch] $RequireHostLocked,
    [ValidateRange(5, 86400)] [int] $QueueTimeoutSeconds = 1800,
    [Alias('TimeoutSeconds')] [ValidateRange(10, 7200)] [int] $ExecutionTimeoutSeconds = 900,
    [ValidateRange(30, 600)] [int] $GuestPowerOffRecoveryTimeoutSeconds = 180,
    [ValidateRange(30, 600)] [int] $CancellationGraceSeconds = 180,
    [string] $BrokerRoot,
    [switch] $ThrowOnFailure
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HyperVBrokerLocation.ps1')
$BrokerRoot = Resolve-HyperVBrokerRoot -BrokerRoot $BrokerRoot

if (-not [string]::IsNullOrWhiteSpace($ActionsPath) -and -not [string]::IsNullOrWhiteSpace($ActionsJson)) {
    throw 'Specify ActionsPath or ActionsJson, not both.'
}
if (-not $ExpectGuestPowerOff -and $PSBoundParameters.ContainsKey('GuestPowerOffRecoveryTimeoutSeconds')) {
    throw 'GuestPowerOffRecoveryTimeoutSeconds may be specified only with ExpectGuestPowerOff.'
}
if ($ExpectGuestPowerOff -and [string]::IsNullOrWhiteSpace($AssertResultFile)) {
    throw 'AssertResultFile is required when ExpectGuestPowerOff is specified.'
}

function Get-ValidatedKeyChord {
    param(
        [Parameter(Mandatory = $true)] $Action,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    $allowedProperties = @('type', 'keys', 'holdMs')
    $unexpectedProperties = @($Action.PSObject.Properties.Name | Where-Object { $_ -notin $allowedProperties })
    if ($unexpectedProperties.Count -gt 0) {
        throw "$Context send_keys contains unsupported properties: $($unexpectedProperties -join ', ')."
    }

    $keySpec = [string]$Action.keys
    if ([string]::IsNullOrWhiteSpace($keySpec)) {
        throw "$Context send_keys requires keys."
    }
    if ($keySpec.Length -gt 64 -or $keySpec -cnotmatch '^[A-Z0-9]+(?:\+[A-Z0-9]+)*$') {
        throw "$Context send_keys keys must be an uppercase '+'-separated chord of at most 64 characters."
    }

    $virtualKeys = @{
        CTRL = 0x11; ALT = 0x12; SHIFT = 0x10; WIN = 0x5B
        LEFT = 0x25; UP = 0x26; RIGHT = 0x27; DOWN = 0x28
        ENTER = 0x0D; ESCAPE = 0x1B; TAB = 0x09; SPACE = 0x20; BACKSPACE = 0x08
        DELETE = 0x2E; INSERT = 0x2D; HOME = 0x24; END = 0x23; PAGEUP = 0x21; PAGEDOWN = 0x22
        F1 = 0x70; F2 = 0x71; F3 = 0x72; F4 = 0x73; F5 = 0x74; F6 = 0x75
        F7 = 0x76; F8 = 0x77; F9 = 0x78; F10 = 0x79; F11 = 0x7A; F12 = 0x7B
        A = 0x41; B = 0x42; C = 0x43; D = 0x44; E = 0x45; F = 0x46; G = 0x47
        H = 0x48; I = 0x49; J = 0x4A; K = 0x4B; L = 0x4C; M = 0x4D; N = 0x4E
        O = 0x4F; P = 0x50; Q = 0x51; R = 0x52; S = 0x53; T = 0x54; U = 0x55
        V = 0x56; W = 0x57; X = 0x58; Y = 0x59; Z = 0x5A
        '0' = 0x30; '1' = 0x31; '2' = 0x32; '3' = 0x33; '4' = 0x34
        '5' = 0x35; '6' = 0x36; '7' = 0x37; '8' = 0x38; '9' = 0x39
    }
    $modifiers = @('CTRL', 'ALT', 'SHIFT', 'WIN')
    $keys = @($keySpec.Split([char]'+'))
    if ($keys.Count -gt 5) {
        throw "$Context send_keys may contain at most four modifiers and one non-modifier key."
    }
    if (@($keys | Select-Object -Unique).Count -ne $keys.Count) {
        throw "$Context send_keys does not allow duplicate keys."
    }
    foreach ($key in $keys) {
        if (-not $virtualKeys.ContainsKey($key)) {
            throw "$Context send_keys key '$key' is not supported."
        }
    }
    if ($keys.Count -gt 1) {
        if ($keys[-1] -in $modifiers -or @($keys[0..($keys.Count - 2)] | Where-Object { $_ -notin $modifiers }).Count -gt 0) {
            throw "$Context send_keys chords must list one or more modifiers followed by exactly one non-modifier key."
        }
    }

    $holdMilliseconds = 50
    if ($Action.PSObject.Properties.Name -contains 'holdMs') {
        try {
            $holdMilliseconds = [int]$Action.holdMs
            if ([double]$Action.holdMs -ne [double]$holdMilliseconds) { throw 'not an integer' }
        }
        catch {
            throw "$Context send_keys holdMs must be a whole number between 10 and 2000."
        }
        if ($holdMilliseconds -lt 10 -or $holdMilliseconds -gt 2000) {
            throw "$Context send_keys holdMs must be between 10 and 2000."
        }
    }

    [pscustomobject][ordered]@{
        KeySpec = $keySpec
        Keys = $keys
        VirtualKeys = @($keys | ForEach-Object { [int]$virtualKeys[$_] })
        HoldMilliseconds = $holdMilliseconds
    }
}

$networkCohortSpecified = $PSBoundParameters.ContainsKey('NetworkCohort')
$normalizedNetworkCohort = $null
if ($networkCohortSpecified) {
    if ([string]::IsNullOrWhiteSpace($NetworkCohort)) {
        throw 'NetworkCohort must be nonblank when specified.'
    }
    $normalizedNetworkCohort = $NetworkCohort.Trim()
    if ($normalizedNetworkCohort.Length -gt 64 -or $normalizedNetworkCohort -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'NetworkCohort must contain at most 64 letters, digits, dots, underscores, or hyphens.'
    }
}

switch ($NetworkProfile) {
    'None' {
        if ($networkCohortSpecified) { throw 'NetworkProfile None does not accept NetworkCohort.' }
        if ($AllowNetworkWithHostInputs) { throw 'NetworkProfile None does not accept AllowNetworkWithHostInputs.' }
    }
    'IsolatedTestNet' {
        if (-not $networkCohortSpecified) { throw 'NetworkProfile IsolatedTestNet requires NetworkCohort.' }
    }
    'InternetOnly' {
        if ($networkCohortSpecified) { throw 'NetworkProfile InternetOnly does not accept NetworkCohort.' }
    }
    'TrustedLan' {
        if ($networkCohortSpecified) { throw 'NetworkProfile TrustedLan does not accept NetworkCohort.' }
    }
}

$networkContract = [ordered]@{
    Profile = [string]$NetworkProfile
    Cohort = $normalizedNetworkCohort
    AllowHostInputs = [bool]$AllowNetworkWithHostInputs
}

$artifact = Get-Item -LiteralPath $ArtifactPath -ErrorAction Stop
$requestsRoot = Join-Path $BrokerRoot 'Requests'
$processingRoot = Join-Path $BrokerRoot 'Processing'
$resultsRoot = Join-Path $BrokerRoot 'Results'
$payloadManifestRoot = Join-Path $BrokerRoot 'PayloadManifests'
$payloadCacheRoot = Join-Path $BrokerRoot 'PayloadCache'
$cancellationsRoot = Join-Path $BrokerRoot 'Cancellations'
$cancelledRoot = Join-Path $BrokerRoot 'Cancelled'
foreach ($requiredRoot in @($requestsRoot, $processingRoot, $resultsRoot, $payloadManifestRoot, $payloadCacheRoot, $cancellationsRoot, $cancelledRoot)) {
    if (-not (Test-Path -LiteralPath $requiredRoot -PathType Container)) {
        throw "Broker directory not found: $requiredRoot"
    }
}

$requestId = 'executable-test-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$requestFile = Join-Path $requestsRoot ($requestId + '.json')
$processingFile = Join-Path $processingRoot ($requestId + '.json')
$cancellationFile = Join-Path $cancellationsRoot ($requestId + '.json')
$resultPath = Join-Path $resultsRoot $requestId
$brokerResultPath = Join-Path $resultPath 'broker-result.json'
$requestStatePath = Join-Path $resultPath 'request-state.json'
$clientStatePath = Join-Path $resultPath 'client-state.json'
$cancelledBeforeStart = $false
$executionDeadlineUtc = $null
$powerOffRecoveryDeadlineUtc = $null
$queueDeadlineUtc = $null
$lastDisplayState = $null
$lastAssignedWorkerId = $null
$lastLifecycleRevision = 0
$lastReadableRequestState = $null
$finalExitCode = 0
$payloadId = $null
$payloadContentKey = $null
$payloadManifestPath = $null
$preparedHostInputs = @()
$observedLifecycle = New-Object Collections.Generic.List[object]

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = $temporaryPath + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                    [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
                }
                else { [IO.File]::Move($temporaryPath, $Path) }
                return
            }
            catch [IO.IOException] { if ($attempt -ge 20) { throw } }
            catch [UnauthorizedAccessException] { if ($attempt -ge 20) { throw } }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-SupportedReservedTokens {
    param(
        [AllowNull()] [string] $Value,
        [Parameter(Mandatory = $true)] [string] $Context,
        [string[]] $AllowedTokens = @()
    )

    if ($null -eq $Value) {
        return
    }

    $reservedTokenPattern = '\{(?<Name>(?i:PAYLOAD|OUTDIR|HOSTINPUT:[A-Za-z][A-Za-z0-9_-]{0,31})|[A-Z][A-Z0-9_:.-]*)\}'
    foreach ($match in [regex]::Matches($Value, $reservedTokenPattern)) {
        $tokenName = [string]$match.Groups['Name'].Value
        $isHostInput = $tokenName.StartsWith('HOSTINPUT:', [StringComparison]::OrdinalIgnoreCase)
        $isAllowed = if ($isHostInput) {
            $tokenName.StartsWith('HOSTINPUT:', [StringComparison]::Ordinal) -and $AllowedTokens -contains $tokenName
        }
        else {
            $AllowedTokens -ccontains $tokenName
        }
        if (-not $isAllowed) {
            $allowedDescription = if ($AllowedTokens.Count -gt 0) {
                'Allowed tokens: ' + (($AllowedTokens | ForEach-Object { '{' + $_ + '}' }) -join ', ') + '.'
            }
            else {
                'Reserved tokens are not allowed in this field.'
            }
            throw "$Context contains unresolved reserved token $($match.Value). $allowedDescription"
        }
    }
}

function Get-ValidatedOutdirRelativePath {
    param(
        [Parameter(Mandatory = $true)] [string] $Value,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    Assert-SupportedReservedTokens -Value $Value -Context $Context -AllowedTokens @('OUTDIR')
    $normalized = $Value.Replace('/', '\')
    $outdirToken = '{OUTDIR}\'
    if (-not $normalized.StartsWith($outdirToken, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context must start with {OUTDIR}\ and remain inside the request output directory."
    }

    $relativePath = $normalized.Substring($outdirToken.Length)
    $validationRoot = 'C:\CodexValidationRoot'
    $validationPrefix = [IO.Path]::GetFullPath($validationRoot).TrimEnd('\') + '\'
    $validationPath = [IO.Path]::GetFullPath((Join-Path $validationRoot $relativePath))
    if ([string]::IsNullOrWhiteSpace($relativePath) -or -not $validationPath.StartsWith($validationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context escapes the request output directory."
    }
    $relativePath
}

function Assert-ValidJsonPointer {
    param(
        [AllowEmptyString()] [string] $Pointer,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    if ($Pointer.Length -gt 0 -and -not $Pointer.StartsWith('/', [StringComparison]::Ordinal)) {
        throw "$Context must be empty for the document root or start with '/'."
    }
    if ([regex]::IsMatch($Pointer, '~(?![01])')) {
        throw "$Context contains an invalid JSON Pointer escape. Only ~0 and ~1 are valid."
    }
}

function Assert-ValidJsonValue {
    param(
        [Parameter(Mandatory = $true)] [string] $Json,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    try {
        $null = ('{"value":' + $Json + '}') | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$Context must contain exactly one valid JSON value: $($_.Exception.Message)"
    }
}

$jsonPointerSpecified = $PSBoundParameters.ContainsKey('AssertResultJsonPointer')
$jsonExpectedSpecified = $PSBoundParameters.ContainsKey('AssertResultEqualsJson')
if ($jsonPointerSpecified -xor $jsonExpectedSpecified) {
    throw 'AssertResultJsonPointer and AssertResultEqualsJson must be specified together.'
}
if ($jsonPointerSpecified) {
    if ([string]::IsNullOrWhiteSpace($AssertResultFile)) {
        throw 'AssertResultFile is required when a JSON result assertion is specified.'
    }
    Assert-ValidJsonPointer -Pointer $AssertResultJsonPointer -Context 'AssertResultJsonPointer'
    Assert-ValidJsonValue -Json $AssertResultEqualsJson -Context 'AssertResultEqualsJson'
}

function Write-ClientState {
    param(
        [Parameter(Mandatory = $true)] [string] $Status,
        [string] $Message = $null,
        [Nullable[int]] $QueuePosition = $null,
        [Nullable[int]] $QueueDepth = $null
    )

    Write-JsonAtomic -Path $clientStatePath -Value ([ordered]@{
        RequestId = $requestId
        Status = $Status
        Message = $Message
        QueuePosition = if ($null -ne $QueuePosition) { [int]$QueuePosition } else { $null }
        QueueDepth = if ($null -ne $QueueDepth) { [int]$QueueDepth } else { $null }
        QueueDeadlineUtc = if ($queueDeadlineUtc) { $queueDeadlineUtc.ToString('o') } else { $null }
        ExecutionDeadlineUtc = if ($executionDeadlineUtc) { $executionDeadlineUtc.ToString('o') } else { $null }
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        ResultPath = $resultPath
    })
}

function Read-RequestStateSafe {
    param([Parameter(Mandatory = $true)] [string] $Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)) { return $null }
        Get-Content -Raw -LiteralPath $Path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { $null }
}

function Resolve-RequestStateWithLastReadable {
    param(
        $CurrentRequestState,
        $LastReadableRequestState
    )

    if ($CurrentRequestState) { return $CurrentRequestState }
    if ($LastReadableRequestState) { return $LastReadableRequestState }
    $null
}

function Get-OptionalRequestStateValue {
    param(
        $RequestState,
        [Parameter(Mandatory = $true)] [string] $PropertyName
    )

    if ($null -eq $RequestState) { return $null }
    $property = $RequestState.PSObject.Properties[$PropertyName]
    if ($null -eq $property) { return $null }
    $property.Value
}

function ConvertTo-UtcRequestStateTimestamp {
    [OutputType([DateTime])]
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)] [string] $PropertyName
    )

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).UtcDateTime
    }
    if ($Value -is [DateTime]) {
        $dateTimeValue = [DateTime]$Value
        if ($dateTimeValue.Kind -eq [DateTimeKind]::Unspecified) {
            throw "$PropertyName must include an explicit UTC offset."
        }
        return $dateTimeValue.ToUniversalTime()
    }
    try {
        return [DateTimeOffset]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).UtcDateTime
    }
    catch {
        throw "$PropertyName is not a valid round-trip timestamp: $($_.Exception.Message)"
    }
}

function Get-RequestLifecycleDisplay {
    param(
        $RequestState,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [bool] $ProcessingPresent = $false,
        [Nullable[int]] $FallbackWorkerId = $null
    )

    if (-not $RequestState) {
        if (-not $ProcessingPresent) { return $null }
        $fallbackWorkerText = if ($null -ne $FallbackWorkerId) { "worker $([int]$FallbackWorkerId)" } else { 'an isolated worker' }
        return [pscustomobject][ordered]@{
            Status = 'Assigned'
            Message = 'Per-request lifecycle state is not yet available.'
            WorkerId = if ($null -ne $FallbackWorkerId) { [int]$FallbackWorkerId } else { $null }
            Text = "Assigned to ${fallbackWorkerText}: $RequestId. Waiting for broker lifecycle details."
            Key = "Assigned|$FallbackWorkerId|state-unavailable"
        }
    }

    $sourceStatus = [string](Get-OptionalRequestStateValue -RequestState $RequestState -PropertyName 'Status')
    $requestMessage = Get-OptionalRequestStateValue -RequestState $RequestState -PropertyName 'Message'
    $requestWorkerId = Get-OptionalRequestStateValue -RequestState $RequestState -PropertyName 'WorkerId'
    $queuePosition = Get-OptionalRequestStateValue -RequestState $RequestState -PropertyName 'QueuePosition'
    $queueDepth = Get-OptionalRequestStateValue -RequestState $RequestState -PropertyName 'QueueDepth'
    $applicationProcessId = Get-OptionalRequestStateValue -RequestState $RequestState -PropertyName 'ApplicationProcessId'
    $guestActionIndex = Get-OptionalRequestStateValue -RequestState $RequestState -PropertyName 'GuestActionIndex'
    $guestActionType = Get-OptionalRequestStateValue -RequestState $RequestState -PropertyName 'GuestActionType'
    $message = if ([string]::IsNullOrWhiteSpace([string]$requestMessage)) { '' } else { ([string]$requestMessage).Trim() }
    $workerId = if ($null -ne $requestWorkerId) { [Nullable[int]]([int]$requestWorkerId) } else { $FallbackWorkerId }
    $workerText = if ($null -ne $workerId) { "worker $([int]$workerId)" } else { 'the assigned worker' }
    $status = $sourceStatus
    $text = switch ($sourceStatus) {
        'Submitted' { "Submitted $RequestId." }
        'Queued' {
            if ($null -ne $queuePosition -and $null -ne $queueDepth) {
                "Queued at position $([int]$queuePosition) of $([int]$queueDepth): $RequestId."
            }
            else { "Queued: $RequestId." }
        }
        'RetryQueued' { "Queued for one clean-worker retry: $RequestId. $message".Trim() }
        'Claimed' { "Assigned to ${workerText}: $RequestId. $message".Trim() }
        'Assigned' { "Assigned to ${workerText}: $RequestId. $message".Trim() }
        'StagingGuestPayload' { "Staging guest payload: $message".Trim() }
        'PreparingHostInputs' { "Preparing read-only host inputs: $message".Trim() }
        'PreparingNetwork' { "Preparing request network: $message".Trim() }
        'VerifyingNetwork' { "Verifying request network: $message".Trim() }
        'PreparingVm' { "Preparing VM: $message".Trim() }
        'StartingVm' { "Starting VM: $message".Trim() }
        'WaitingForGuestAgent' { "Waiting for guest agent: $message".Trim() }
        'LaunchingApplication' { "Launching application: $message".Trim() }
        'ApplicationRunning' {
            $pidText = if ($null -ne $applicationProcessId) { " PID $([int]$applicationProcessId)" } else { '' }
            "Application running on $workerText${pidText}: $RequestId. $message".Trim()
        }
        'GuestAction' {
            $actionText = if ($null -ne $guestActionIndex -and -not [string]::IsNullOrWhiteSpace([string]$guestActionType)) {
                "$([int]$guestActionIndex) ($([string]$guestActionType))"
            }
            else { 'in progress' }
            "Guest action ${actionText}: $message".Trim()
        }
        'AwaitingGuestCompletion' { "Waiting for guest completion: $message".Trim() }
        'AwaitingExpectedGuestPowerOff' { "Waiting for expected guest power-off: $message".Trim() }
        'GuestPowerOffObserved' { "Expected guest power-off observed: $message".Trim() }
        'RecoveringPowerOffEvidence' { "Recovering post-power-off evidence: $message".Trim() }
        'CollectingEvidence' { "Collecting evidence: $message".Trim() }
        'CleaningNetwork' { "Revoking request network: $message".Trim() }
        'StoppingVm' { "Stopping VM / recycling ${workerText}: $message".Trim() }
        'RetryPendingRecycle' { "Recycling failed capture worker before one retry: $message".Trim() }
        'GuestAgentRecovery' { "Waiting for guest-agent recovery: $message".Trim() }
        'WaitingForHostLock' { "Waiting for host lock: $message".Trim() }
        'RetryingGuestConnection' { "Retrying guest connection: $message".Trim() }
        'RunningGuestJob' {
            # Older brokers used this immediately after submission, before any
            # Start-Process confirmation. Never translate it into app-running.
            $status = 'AssignedLegacy'
            "Assigned to ${workerText}: $RequestId. Waiting for guest lifecycle confirmation from an older broker."
        }
        'Completed' { "Terminal result: Completed. $message".Trim() }
        'TestFailed' { "Terminal result: TestFailed. $message".Trim() }
        'Failed' { "Terminal result: Failed. $message".Trim() }
        'Cancelled' { "Terminal result: Cancelled. $message".Trim() }
        'QueueTimedOut' { "Terminal result: QueueTimedOut. $message".Trim() }
        'ExecutionTimedOut' { "Terminal result: ExecutionTimedOut. $message".Trim() }
        'Cancelling' { "Cancellation requested: $message".Trim() }
        default { "$sourceStatus`: $message".Trim() }
    }

    $keyParts = @(
        $status
        $message
        $(if ($null -ne $workerId) { [string][int]$workerId } else { '' })
        $(if ($null -ne $queuePosition) { [string][int]$queuePosition } else { '' })
        $(if ($null -ne $queueDepth) { [string][int]$queueDepth } else { '' })
        $(if ($null -ne $applicationProcessId) { [string][int]$applicationProcessId } else { '' })
        $(if ($null -ne $guestActionIndex) { [string][int]$guestActionIndex } else { '' })
        [string]$guestActionType
    )
    [pscustomobject][ordered]@{
        Status = $status
        Message = $message
        WorkerId = if ($null -ne $workerId) { [int]$workerId } else { $null }
        Text = $text
        Key = $keyParts -join '|'
    }
}

function Test-LifecycleProgressChanged {
    param([AllowNull()] [string] $LastKey, $Display)
    $Display -and -not [string]::Equals($LastKey, [string]$Display.Key, [StringComparison]::Ordinal)
}

function Show-RequestLifecycleProgress {
    param(
        $RequestState,
        [bool] $ProcessingPresent = $false,
        [Nullable[int]] $FallbackWorkerId = $null
    )

    $display = Get-RequestLifecycleDisplay -RequestState $RequestState -RequestId $requestId -ProcessingPresent:$ProcessingPresent -FallbackWorkerId $FallbackWorkerId
    if (-not (Test-LifecycleProgressChanged -LastKey $script:lastDisplayState -Display $display)) { return $false }
    Write-Host ([string]$display.Text)
    $script:lastDisplayState = [string]$display.Key
    $observedLifecycle.Add([pscustomobject][ordered]@{
        Status = [string]$display.Status
        Message = [string]$display.Message
        WorkerId = if ($null -ne $display.WorkerId) { [int]$display.WorkerId } else { $null }
        ObservedUtc = [DateTime]::UtcNow.ToString('o')
    })
    $true
}

function Show-BrokerRequestState {
    param(
        [Parameter(Mandatory = $true)] $RequestState,
        [bool] $ProcessingPresent = $false
    )

    $stateWorkerId = if ($null -ne $RequestState.WorkerId) { [Nullable[int]]([int]$RequestState.WorkerId) } else { $null }
    if ($null -ne $stateWorkerId -and $stateWorkerId -ne $script:lastAssignedWorkerId -and [string]$RequestState.Status -notin @('Queued', 'RetryQueued')) {
        if ([string]$RequestState.Status -ne 'Claimed') {
            [void](Show-RequestLifecycleProgress -RequestState ([pscustomobject][ordered]@{
                Status = 'Claimed'
                Message = "Broker assigned pool worker $([int]$stateWorkerId)."
                WorkerId = [int]$stateWorkerId
            }) -ProcessingPresent:$ProcessingPresent)
        }
        $script:lastAssignedWorkerId = [int]$stateWorkerId
    }
    [void](Show-RequestLifecycleProgress -RequestState $RequestState -ProcessingPresent:$ProcessingPresent)
}

function Show-NewBrokerRequestState {
    param(
        [Parameter(Mandatory = $true)] $RequestState,
        [bool] $ProcessingPresent = $false
    )

    $historyEvents = @($RequestState.History | Where-Object { $null -ne $_.Revision -and [int64]$_.Revision -gt $script:lastLifecycleRevision } | Sort-Object { [int64]$_.Revision })
    if ($historyEvents.Count -gt 0) {
        foreach ($historyEvent in $historyEvents) {
            Show-BrokerRequestState -RequestState $historyEvent -ProcessingPresent:$ProcessingPresent
            $script:lastLifecycleRevision = [Math]::Max([int64]$script:lastLifecycleRevision, [int64]$historyEvent.Revision)
        }
    }
    elseif (-not $RequestState.History) {
        Show-BrokerRequestState -RequestState $RequestState -ProcessingPresent:$ProcessingPresent
    }
}

function Get-QueuePosition {
    $queuedFiles = @(Get-ChildItem -LiteralPath $requestsRoot -Filter '*.json' -File | Sort-Object CreationTimeUtc, Name)
    for ($index = 0; $index -lt $queuedFiles.Count; $index++) {
        if ([IO.Path]::GetFileNameWithoutExtension($queuedFiles[$index].Name) -eq $requestId) {
            return [ordered]@{
                Position = $index + 1
                Depth = $queuedFiles.Count
            }
        }
    }
    $null
}

function Request-Cancellation {
    param([Parameter(Mandatory = $true)] [string] $Reason)

    if (Test-Path -LiteralPath $brokerResultPath -PathType Leaf) {
        return 'AlreadyCompleted'
    }

    if (Test-Path -LiteralPath $requestFile -PathType Leaf) {
        $cancelledFile = Join-Path $cancelledRoot ($requestId + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
        try {
            Move-Item -LiteralPath $requestFile -Destination $cancelledFile -Force -ErrorAction Stop
            return 'CancelledBeforeStart'
        }
        catch {
            # The broker may have claimed it between the existence check and move.
        }
    }

    Write-JsonAtomic -Path $cancellationFile -Value ([ordered]@{
        RequestId = $requestId
        Reason = $Reason
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
        RequestedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    })
    'CancellationRequested'
}

function Get-PayloadSourceInventory {
    param(
        [Parameter(Mandatory = $true)] [IO.FileSystemInfo] $Artifact,
        $PreviousIndex,
        [switch] $AllowReparsePoints
    )

    if (-not $AllowReparsePoints -and ($Artifact.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'ArtifactPath must not be a symbolic link or other reparse point.'
    }

    $enumerationWatch = [Diagnostics.Stopwatch]::StartNew()
    $allItems = @()
    if ($Artifact.PSIsContainer) {
        $allItems = @(Get-ChildItem -LiteralPath $Artifact.FullName -Force -Recurse)
    }
    $reparsePoints = @(
        if (($Artifact.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $Artifact }
        $allItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
    )
    if (-not $AllowReparsePoints -and $reparsePoints.Count -gt 0) {
        $reparsePoint = $reparsePoints | Select-Object -First 1
        if ($reparsePoint) {
            throw "Artifact contains a symbolic link or other reparse point: $($reparsePoint.FullName)"
        }
    }

    $artifactPrefix = if ($Artifact.PSIsContainer) {
        [IO.Path]::GetFullPath($Artifact.FullName).TrimEnd('\') + '\'
    }
    else {
        $null
    }
    $inventoryDirectories = foreach ($sourceDirectory in @($allItems | Where-Object { $_.PSIsContainer })) {
        $resolvedDirectory = [IO.Path]::GetFullPath($sourceDirectory.FullName)
        if (-not $resolvedDirectory.StartsWith($artifactPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Artifact directory escapes its root: $resolvedDirectory"
        }
        [pscustomobject][ordered]@{
            Item = $sourceDirectory
            RelativePath = $resolvedDirectory.Substring($artifactPrefix.Length).Replace('\', '/')
        }
    }
    $previousMap = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    if ($PreviousIndex) {
        foreach ($previousFile in @($PreviousIndex.Files)) {
            if ($previousFile.RelativePath) {
                $previousMap[[string]$previousFile.RelativePath] = $previousFile
            }
        }
    }
    $seenPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $candidateBytes = [long]0
    $candidateCount = 0
    $unchangedCount = 0
    $totalBytes = [long]0
    $inventoryFiles = foreach ($sourceFile in @($(if ($Artifact.PSIsContainer) { $allItems | Where-Object { -not $_.PSIsContainer } } else { $Artifact }))) {
        $relativePath = if ($Artifact.PSIsContainer) {
            $resolvedFile = [IO.Path]::GetFullPath($sourceFile.FullName)
            if (-not $resolvedFile.StartsWith($artifactPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Artifact file escapes its root: $resolvedFile"
            }
            $resolvedFile.Substring($artifactPrefix.Length).Replace('\', '/')
        }
        else {
            $Artifact.Name
        }
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            throw "Artifact contains an invalid relative file path: $($sourceFile.FullName)"
        }
        [void]$seenPaths.Add($relativePath)
        $lastWriteTicks = [long]$sourceFile.LastWriteTimeUtc.Ticks
        $previousFile = if ($previousMap.ContainsKey($relativePath)) { $previousMap[$relativePath] } else { $null }
        $unchanged = $previousFile -and
            [long]$previousFile.Length -eq [long]$sourceFile.Length -and
            [long]$previousFile.LastWriteTimeUtcTicks -eq $lastWriteTicks -and
            [string]$previousFile.Sha256 -match '^[A-Fa-f0-9]{64}$'
        if ($unchanged) { $unchangedCount++ }
        else {
            $candidateCount++
            $candidateBytes += [long]$sourceFile.Length
        }
        $totalBytes += [long]$sourceFile.Length
        [pscustomobject][ordered]@{
            Item = $sourceFile
            RelativePath = $relativePath
            LastWriteTimeUtcTicks = $lastWriteTicks
            Unchanged = [bool]$unchanged
            PreviousSha256 = if ($unchanged) { ([string]$previousFile.Sha256).ToUpperInvariant() } else { $null }
        }
    }
    $deletedCount = @($previousMap.Keys | Where-Object { -not $seenPaths.Contains([string]$_) }).Count
    $candidateCount += $deletedCount
    $enumerationWatch.Stop()

    [pscustomobject][ordered]@{
        Directories = @($inventoryDirectories)
        Files = @($inventoryFiles)
        TotalBytes = $totalBytes
        CandidateBytes = $candidateBytes
        CandidateCount = $candidateCount
        DeletedCount = $deletedCount
        UnchangedCount = $unchangedCount
        ReparsePointCount = $reparsePoints.Count
        FirstReparsePoint = if ($reparsePoints.Count -gt 0) { [string]$reparsePoints[0].FullName } else { $null }
        EnumerationMilliseconds = [Math]::Round($enumerationWatch.Elapsed.TotalMilliseconds, 3)
    }
}

function Get-PayloadManifest {
    param(
        [Parameter(Mandatory = $true)] [IO.FileSystemInfo] $Artifact,
        $PreviousIndex,
        $Inventory
    )

    if (-not $Inventory) {
        $Inventory = Get-PayloadSourceInventory -Artifact $Artifact -PreviousIndex $PreviousIndex
    }
    if ([int]$Inventory.ReparsePointCount -gt 0) {
        throw "Artifact contains a symbolic link or other reparse point: $($Inventory.FirstReparsePoint)"
    }
    if (@($Inventory.Files).Count -eq 0) {
        throw 'The application artifact contains no files.'
    }

    $manifestDirectories = @($Inventory.Directories | ForEach-Object { [string]$_.RelativePath })
    $hashWatch = New-Object Diagnostics.Stopwatch
    $filesHashed = 0
    $hashesReused = 0
    $indexFiles = New-Object Collections.Generic.List[object]
    $manifestFiles = foreach ($sourceEntry in @($Inventory.Files)) {
        $sourceFile = $sourceEntry.Item
        $relativePath = [string]$sourceEntry.RelativePath
        $lastWriteTicks = [long]$sourceEntry.LastWriteTimeUtcTicks
        $hash = if ([bool]$sourceEntry.Unchanged) { [string]$sourceEntry.PreviousSha256 } else { $null }
        if ($hash) { $hashesReused++ }
        if (-not $hash) {
            $hashWatch.Start()
            $hash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
            $hashWatch.Stop()
            $filesHashed++
        }
        $indexFiles.Add([pscustomobject][ordered]@{
            RelativePath = $relativePath
            Length = [long]$sourceFile.Length
            LastWriteTimeUtcTicks = $lastWriteTicks
            Sha256 = $hash
        })
        [pscustomobject][ordered]@{
            RelativePath = $relativePath
            Length = [long]$sourceFile.Length
            Sha256 = $hash
        }
    }

    [pscustomobject]@{
        Directories = @($manifestDirectories | Sort-Object { ([string]$_).ToUpperInvariant() }, { [string]$_ })
        Files = @($manifestFiles | Sort-Object @{ Expression = { ([string]$_.RelativePath).ToUpperInvariant() } }, @{ Expression = { [string]$_.RelativePath } })
        IndexFiles = @($indexFiles | Sort-Object @{ Expression = { ([string]$_.RelativePath).ToUpperInvariant() } }, @{ Expression = { [string]$_.RelativePath } })
        EnumerationMilliseconds = [double]$Inventory.EnumerationMilliseconds
        CandidateHashMilliseconds = [Math]::Round($hashWatch.Elapsed.TotalMilliseconds, 3)
        FilesHashed = $filesHashed
        HashesReused = $hashesReused
    }
}

function Get-PayloadContentKey {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Files,
        [string[]] $Directories = @()
    )

    $canonical = New-Object Text.StringBuilder
    foreach ($directory in $Directories) {
        [void]$canonical.Append('D:').Append($directory.Length).Append(':').Append($directory).Append("`n")
    }
    foreach ($file in $Files) {
        $relativePath = [string]$file.RelativePath
        [void]$canonical.Append('F:').Append($relativePath.Length).Append(':').Append($relativePath).Append(':').Append([long]$file.Length).Append(':').Append(([string]$file.Sha256).ToUpperInvariant()).Append("`n")
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical.ToString()))
        ([BitConverter]::ToString($digest)).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-PayloadId {
    param(
        [Parameter(Mandatory = $true)] [string] $CanonicalArtifactPath,
        [Parameter(Mandatory = $true)] [bool] $IsDirectory,
        [ValidateSet('Application', 'ReadOnlyHostInput')] [string] $CacheScope = 'Application'
    )

    # Preserve the established application cache identity exactly. Read-only
    # host inputs use a separate namespace so their NTFS policy can never alter
    # normal ArtifactPath behavior, even when both name the same source path.
    $identityPrefix = if ($CacheScope -eq 'ReadOnlyHostInput') {
        if ($IsDirectory) { 'readonly-host-input-directory|' } else { 'readonly-host-input-file|' }
    }
    elseif ($IsDirectory) { 'directory|' }
    else { 'file|' }
    $identityText = $identityPrefix + $CanonicalArtifactPath.ToUpperInvariant()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($identityText))
        ([BitConverter]::ToString($digest)).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-PreviousPayloadIndex {
    param(
        [Parameter(Mandatory = $true)] [string] $PayloadId,
        [Parameter(Mandatory = $true)] [string] $CanonicalPath,
        [Parameter(Mandatory = $true)] [bool] $IsDirectory
    )

    $indexPath = Join-Path (Join-Path $payloadManifestRoot $PayloadId) 'source-index.json'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return $null
    }
    try {
        $candidate = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json
        if ([int]$candidate.IndexVersion -eq 1 -and
            [string]$candidate.PayloadId -eq $PayloadId -and
            [string]::Equals([string]$candidate.ArtifactPath, $CanonicalPath, [StringComparison]::OrdinalIgnoreCase) -and
            [bool]$candidate.IsDirectory -eq $IsDirectory) {
            return $candidate
        }
    }
    catch { }
    $null
}

function Test-PayloadCacheWarm {
    param(
        [Parameter(Mandatory = $true)] [string] $PayloadId,
        [Parameter(Mandatory = $true)] [string] $CanonicalPath
    )

    $metadataPath = Join-Path (Join-Path $payloadCacheRoot $PayloadId) 'metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return $false }
    try {
        $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
        [string]::Equals([string]$metadata.ArtifactPath, $CanonicalPath, [StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::IsNullOrWhiteSpace([string]$metadata.CurrentVhdxPath) -and
            (Test-Path -LiteralPath ([string]$metadata.CurrentVhdxPath) -PathType Leaf)
    }
    catch { $false }
}

function Select-HostInputTransport {
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('Auto', 'Share', 'Vhdx')] [string] $RequestedMode,
        [Parameter(Mandatory = $true)] [bool] $WarmCache,
        [Parameter(Mandatory = $true)] $Inventory,
        [Parameter(Mandatory = $true)] [int] $FileCount,
        [Parameter(Mandatory = $true)] [long] $ColdShareThresholdBytes,
        [Parameter(Mandatory = $true)] [long] $IncrementalShareThresholdBytes
    )

    if ($RequestedMode -eq 'Share') {
        return [pscustomobject][ordered]@{ Transport = 'Share'; Reason = 'Share was explicitly requested.' }
    }
    if ($RequestedMode -eq 'Vhdx') {
        return [pscustomobject][ordered]@{ Transport = 'Vhdx'; Reason = 'VHDX cache transport was explicitly requested.' }
    }
    if ([int]$Inventory.ReparsePointCount -gt 0 -or $FileCount -eq 0) {
        $reason = if ($FileCount -eq 0) { 'The input is empty, so a live read-only share avoids creating an empty cache disk.' } else { 'The input contains a reparse point and is safer to expose without flattening it into a VHDX.' }
        return [pscustomobject][ordered]@{ Transport = 'Share'; Reason = $reason }
    }
    if ($WarmCache -and [int]$Inventory.CandidateCount -eq 0) {
        return [pscustomobject][ordered]@{ Transport = 'Vhdx'; Reason = 'An unchanged immutable VHDX generation is already warm.' }
    }
    if ($WarmCache -and [long]$Inventory.CandidateBytes -lt $IncrementalShareThresholdBytes -and [int]$Inventory.CandidateCount -lt 5000) {
        return [pscustomobject][ordered]@{ Transport = 'Vhdx'; Reason = 'The warm immutable cache needs only a small incremental update.' }
    }
    if (-not $WarmCache -and [long]$Inventory.TotalBytes -lt $ColdShareThresholdBytes -and $FileCount -lt 25000) {
        return [pscustomobject][ordered]@{ Transport = 'Vhdx'; Reason = 'The cold input is small enough to cache locally.' }
    }
    [pscustomobject][ordered]@{ Transport = 'Share'; Reason = 'A cold or substantially changed large input is cheaper to expose directly than to copy into a VHDX.' }
}

if ($artifact.PSIsContainer) {
    if ([string]::IsNullOrWhiteSpace($ExecutableRelativePath)) {
        throw 'ExecutableRelativePath is required when ArtifactPath is a directory.'
    }
    $relativeExecutable = $ExecutableRelativePath.Replace('/', '\')
    if ([IO.Path]::IsPathRooted($relativeExecutable)) {
        throw 'ExecutableRelativePath must be relative to ArtifactPath.'
    }
    $artifactRoot = [IO.Path]::GetFullPath($artifact.FullName).TrimEnd('\') + '\'
    $sourceExecutable = [IO.Path]::GetFullPath((Join-Path $artifact.FullName $relativeExecutable))
    if (-not $sourceExecutable.StartsWith($artifactRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ExecutableRelativePath escapes ArtifactPath.'
    }
    if (-not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf)) {
        throw "Executable not found inside artifact directory: $sourceExecutable"
    }
}
else {
    if (-not [string]::IsNullOrWhiteSpace($ExecutableRelativePath)) {
        throw 'Do not specify ExecutableRelativePath when ArtifactPath is a file.'
    }
    $relativeExecutable = $artifact.Name
}

$hostInputDeclarations = New-Object Collections.Generic.List[object]
$hostInputNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($declaration in @($ReadOnlyHostInput)) {
    if (-not $declaration) { throw 'ReadOnlyHostInput entries must be non-null hashtables.' }
    $name = [string]$declaration.Name
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$') {
        throw "ReadOnlyHostInput Name must start with a letter and contain at most 32 letters, digits, underscores, or hyphens: $name"
    }
    if (-not $hostInputNames.Add($name)) {
        throw "Duplicate ReadOnlyHostInput Name: $name"
    }
    $declaredPath = [string]$declaration.Path
    if ([string]::IsNullOrWhiteSpace($declaredPath) -or -not [IO.Path]::IsPathRooted($declaredPath) -or $declaredPath.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "ReadOnlyHostInput '$name' Path must be an absolute local host path."
    }
    $item = Get-Item -LiteralPath $declaredPath -Force -ErrorAction Stop
    $canonicalPath = [IO.Path]::GetFullPath($item.FullName)
    if ($item.PSIsContainer) { $canonicalPath = $canonicalPath.TrimEnd('\') }
    $requestedMode = if ([string]::IsNullOrWhiteSpace([string]$declaration.Mode)) { 'Auto' } else { [string]$declaration.Mode }
    $mode = switch -Regex ($requestedMode) {
        '^(?i:auto)$' { 'Auto'; break }
        '^(?i:share)$' { 'Share'; break }
        '^(?i:vhdx|cache|cached)$' { 'Vhdx'; break }
        default { throw "ReadOnlyHostInput '$name' Mode must be Auto, Share, or Vhdx." }
    }
    $hostInputDeclarations.Add([pscustomobject][ordered]@{
        Name = $name
        TokenName = 'HOSTINPUT:' + $name
        Token = '{HOSTINPUT:' + $name + '}'
        Path = $canonicalPath
        Item = $item
        IsDirectory = [bool]$item.PSIsContainer
        RequestedMode = $mode
    })
}
if ($hostInputDeclarations.Count -gt 8) {
    throw 'A request may expose at most eight read-only host inputs.'
}
$networkEnabled = $NetworkProfile -ne 'None'
if ($networkEnabled -and $hostInputDeclarations.Count -gt 0) {
    if (-not $AllowNetworkWithHostInputs) {
        throw 'AllowNetworkWithHostInputs is required when a non-None NetworkProfile is combined with ReadOnlyHostInput.'
    }
    $explicitShare = @($hostInputDeclarations | Where-Object { [string]$_.RequestedMode -eq 'Share' } | Select-Object -First 1)
    if ($explicitShare.Count -gt 0) {
        throw "ReadOnlyHostInput '$($explicitShare[0].Name)' explicitly requests Share, which cannot be combined with a non-None NetworkProfile. Use Auto or Vhdx."
    }
}
$hostInputTokenNames = @($hostInputDeclarations | ForEach-Object { [string]$_.TokenName })

if (-not [string]::IsNullOrWhiteSpace($ActionsPath)) {
    $parsedActions = Get-Content -Raw -LiteralPath $ActionsPath | ConvertFrom-Json
    $actions = @()
    foreach ($action in $parsedActions) {
        $actions += $action
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($ActionsJson)) {
    $parsedActions = $ActionsJson | ConvertFrom-Json
    $actions = @()
    foreach ($action in $parsedActions) {
        $actions += $action
    }
}
elseif ($ExpectGuestPowerOff) {
    $actions = @(
        [ordered]@{
            type = 'wait_result_file'
            path = $AssertResultFile
            timeoutMs = [int64]$ExecutionTimeoutSeconds * 1000
        }
    )
}
else {
    $actions = @(
        [ordered]@{ type = 'wait_window'; timeoutMs = 30000 },
        [ordered]@{ type = 'screenshot'; name = 'launched.png' },
        [ordered]@{ type = 'wait'; ms = 2000 },
        [ordered]@{ type = 'screenshot'; name = 'after-wait.png' }
    )
}

if ($actions.Count -eq 0) {
    throw 'At least one guest action is required.'
}

$expectedHarnessEvidence = @()
$expectedTestEvidence = @()
for ($actionIndex = 0; $actionIndex -lt $actions.Count; $actionIndex++) {
    $action = $actions[$actionIndex]
    $actionType = [string]$action.type
    if ([string]::IsNullOrWhiteSpace($actionType)) {
        throw "Action $($actionIndex + 1) has no type."
    }
    switch ($actionType) {
        'wait_window' {
            $timeout = if ($action.timeoutMs) { [int]$action.timeoutMs } else { 15000 }
            if ($timeout -lt 100 -or $timeout -gt 300000) {
                throw "Action $($actionIndex + 1) wait_window timeoutMs must be between 100 and 300000."
            }
        }
        'focus_window' {
        }
        'click_control' {
            if ([string]::IsNullOrWhiteSpace([string]$action.automationId) -and [string]::IsNullOrWhiteSpace([string]$action.name)) {
                throw "Action $($actionIndex + 1) click_control requires automationId or name."
            }
            $timeout = if ($action.timeoutMs) { [int]$action.timeoutMs } else { 10000 }
            if ($timeout -lt 100 -or $timeout -gt 300000) {
                throw "Action $($actionIndex + 1) click_control timeoutMs must be between 100 and 300000."
            }
        }
        'click_relative' {
            if ($null -eq $action.x -or $null -eq $action.y) {
                throw "Action $($actionIndex + 1) click_relative requires x and y."
            }
        }
        'type_text' {
            if ($null -eq $action.text) {
                throw "Action $($actionIndex + 1) type_text requires text."
            }
        }
        'send_keys' {
            $null = Get-ValidatedKeyChord -Action $action -Context "Action $($actionIndex + 1)"
        }
        'wait' {
            $milliseconds = [int]$action.ms
            if ($milliseconds -lt 0 -or $milliseconds -gt 300000) {
                throw "Action $($actionIndex + 1) wait ms must be between 0 and 300000."
            }
        }
        'wait_process_exit' {
            $timeout = if ($action.timeoutMs) { [int64]$action.timeoutMs } else { 300000 }
            if ($timeout -lt 100 -or $timeout -gt 7200000) {
                throw "Action $($actionIndex + 1) wait_process_exit timeoutMs must be between 100 and 7200000."
            }
            if ($null -ne $action.expectedExitCode) {
                try { $null = [int]$action.expectedExitCode }
                catch { throw "Action $($actionIndex + 1) wait_process_exit expectedExitCode must be a 32-bit integer." }
            }
        }
        'wait_result_file' {
            if ([string]::IsNullOrWhiteSpace([string]$action.path)) {
                throw "Action $($actionIndex + 1) wait_result_file requires path."
            }
            $timeout = if ($action.timeoutMs) { [int64]$action.timeoutMs } else { 300000 }
            if ($timeout -lt 100 -or $timeout -gt 7200000) {
                throw "Action $($actionIndex + 1) wait_result_file timeoutMs must be between 100 and 7200000."
            }
            $relativeResultPath = Get-ValidatedOutdirRelativePath -Value ([string]$action.path) -Context "Action $($actionIndex + 1) wait_result_file path"
            if ($expectedTestEvidence -notcontains $relativeResultPath) {
                $expectedTestEvidence += $relativeResultPath
            }
        }
        'screenshot' {
            $fileName = [string]$action.name
            if ([string]::IsNullOrWhiteSpace($fileName)) {
                $fileName = 'screenshot.png'
                $action | Add-Member -NotePropertyName name -NotePropertyValue $fileName -Force
            }
            if ([IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw "Action $($actionIndex + 1) screenshot name must be a valid leaf filename."
            }
            $captureTimeout = if ($action.timeoutMs) { [int]$action.timeoutMs } else { 30000 }
            if ($captureTimeout -lt 3000 -or $captureTimeout -gt 30000) {
                throw "Action $($actionIndex + 1) screenshot timeoutMs must be between 3000 and 30000."
            }
            $captureAttempts = if ($action.attempts) { [int]$action.attempts } else { 5 }
            if ($captureAttempts -lt 1 -or $captureAttempts -gt 5) {
                throw "Action $($actionIndex + 1) screenshot attempts must be between 1 and 5."
            }
            if ($expectedHarnessEvidence -contains $fileName) {
                throw "Duplicate screenshot evidence filename: $fileName"
            }
            $expectedHarnessEvidence += $fileName
        }
        default {
            throw "Unsupported action type at position $($actionIndex + 1): $actionType"
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($AssertResultFile)) {
    $assertionRelativePath = Get-ValidatedOutdirRelativePath -Value $AssertResultFile -Context 'AssertResultFile'
    if ($ExpectGuestPowerOff -and $assertionRelativePath -in @('result.json', 'agent-error.json', 'lease.json')) {
        throw "ExpectGuestPowerOff AssertResultFile must not use reserved guest protocol filename '$assertionRelativePath' at the OUTDIR root."
    }
    if ($expectedTestEvidence -notcontains $assertionRelativePath) {
        $expectedTestEvidence += $assertionRelativePath
    }
}

Assert-SupportedReservedTokens -Value $Arguments -Context 'Arguments' -AllowedTokens (@('PAYLOAD', 'OUTDIR') + $hostInputTokenNames)
for ($actionIndex = 0; $actionIndex -lt $actions.Count; $actionIndex++) {
    $action = $actions[$actionIndex]
    $actionType = [string]$action.type
    $stringFields = @()
    if ($action -is [Collections.IDictionary]) {
        foreach ($key in @($action.Keys)) {
            if ($action[$key] -is [string]) {
                $stringFields += [pscustomobject]@{ Name = [string]$key; Value = [string]$action[$key] }
            }
        }
    }
    else {
        foreach ($property in @($action.PSObject.Properties)) {
            if ($property.Value -is [string]) {
                $stringFields += [pscustomobject]@{ Name = [string]$property.Name; Value = [string]$property.Value }
            }
        }
    }

    foreach ($field in $stringFields) {
        $tokensAllowedHere = if ($field.Name -eq 'type' -or ($actionType -eq 'screenshot' -and $field.Name -eq 'name') -or ($actionType -eq 'send_keys' -and $field.Name -eq 'keys')) {
            @()
        }
        elseif ($actionType -eq 'wait_result_file' -and $field.Name -eq 'path') {
            @('OUTDIR')
        }
        else {
            @('PAYLOAD', 'OUTDIR') + $hostInputTokenNames
        }
        Assert-SupportedReservedTokens -Value $field.Value -Context "Action $($actionIndex + 1) '$($field.Name)'" -AllowedTokens $tokensAllowedHere
    }
}

try {
    New-Item -ItemType Directory -Force -Path $resultPath | Out-Null
    Write-ClientState -Status 'HashingPayload' -Message 'Scanning cheap payload fingerprints and hashing only likely changes.'
    $payloadDetectionWatch = [Diagnostics.Stopwatch]::StartNew()
    $canonicalArtifactPath = [IO.Path]::GetFullPath($artifact.FullName)
    if ($artifact.PSIsContainer) {
        $canonicalArtifactPath = $canonicalArtifactPath.TrimEnd('\')
    }
    $payloadId = Get-PayloadId -CanonicalArtifactPath $canonicalArtifactPath -IsDirectory ([bool]$artifact.PSIsContainer)
    $payloadManifestDirectory = Join-Path $payloadManifestRoot $payloadId
    New-Item -ItemType Directory -Force -Path $payloadManifestDirectory | Out-Null
    $payloadIndexPath = Join-Path $payloadManifestDirectory 'source-index.json'
    $previousIndex = Get-PreviousPayloadIndex -PayloadId $payloadId -CanonicalPath $canonicalArtifactPath -IsDirectory ([bool]$artifact.PSIsContainer)
    $payloadInventory = Get-PayloadSourceInventory -Artifact $artifact -PreviousIndex $previousIndex
    $payloadManifest = Get-PayloadManifest -Artifact $artifact -PreviousIndex $previousIndex -Inventory $payloadInventory
    $payloadFiles = @($payloadManifest.Files)
    $payloadDirectories = @($payloadManifest.Directories)
    $payloadContentKey = Get-PayloadContentKey -Files $payloadFiles -Directories $payloadDirectories
    $payloadManifestPath = Join-Path $payloadManifestDirectory ($payloadContentKey + '.json')
    $payloadBytes = [long](($payloadFiles | Measure-Object -Property Length -Sum).Sum)
    Write-JsonAtomic -Path $payloadManifestPath -Value ([ordered]@{
        ManifestVersion = 2
        PayloadId = $payloadId
        ContentKey = $payloadContentKey
        ArtifactPath = $canonicalArtifactPath
        IsDirectory = [bool]$artifact.PSIsContainer
        DirectoryCount = $payloadDirectories.Count
        FileCount = $payloadFiles.Count
        TotalBytes = $payloadBytes
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Directories = $payloadDirectories
        Files = $payloadFiles
    })
    Write-JsonAtomic -Path $payloadIndexPath -Value ([ordered]@{
        IndexVersion = 1
        PayloadId = $payloadId
        ArtifactPath = $canonicalArtifactPath
        IsDirectory = [bool]$artifact.PSIsContainer
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Directories = $payloadDirectories
        Files = @($payloadManifest.IndexFiles)
    })
    $payloadDetectionWatch.Stop()

    $preparedHostInputs = @()
    foreach ($hostInput in $hostInputDeclarations) {
        Write-ClientState -Status 'InspectingHostInput' -Message "Inspecting read-only host input '$($hostInput.Name)' with cheap file metadata."
        $inputDetectionWatch = [Diagnostics.Stopwatch]::StartNew()
        $inputItem = $hostInput.Item
        $inputPath = [string]$hostInput.Path
        $inputPayloadId = Get-PayloadId -CanonicalArtifactPath $inputPath -IsDirectory ([bool]$hostInput.IsDirectory) -CacheScope ReadOnlyHostInput
        $inputPreviousIndex = Get-PreviousPayloadIndex -PayloadId $inputPayloadId -CanonicalPath $inputPath -IsDirectory ([bool]$hostInput.IsDirectory)
        $inputInventory = Get-PayloadSourceInventory -Artifact $inputItem -PreviousIndex $inputPreviousIndex -AllowReparsePoints
        $inputFileCount = @($inputInventory.Files).Count
        $inputDirectoryCount = @($inputInventory.Directories).Count
        $warmCache = Test-PayloadCacheWarm -PayloadId $inputPayloadId -CanonicalPath $inputPath

        $selection = if ($networkEnabled -and [string]$hostInput.RequestedMode -eq 'Auto') {
            [pscustomobject][ordered]@{
                Transport = 'Vhdx'
                Reason = 'Auto was forced to immutable VHDX transport because the request enables general networking.'
            }
        }
        else {
            Select-HostInputTransport -RequestedMode ([string]$hostInput.RequestedMode) -WarmCache ([bool]$warmCache) -Inventory $inputInventory -FileCount $inputFileCount -ColdShareThresholdBytes $HostInputColdShareThresholdBytes -IncrementalShareThresholdBytes $HostInputIncrementalShareThresholdBytes
        }
        $selectedTransport = [string]$selection.Transport
        $selectionReason = [string]$selection.Reason

        $inputPayload = $null
        $inputManifest = $null
        $inputContentKey = $null
        $inputManifestPath = $null
        $filesHashed = 0
        $hashesReused = 0
        $candidateHashMilliseconds = 0.0
        if ($selectedTransport -eq 'Vhdx') {
            if ([int]$inputInventory.ReparsePointCount -gt 0) {
                throw "ReadOnlyHostInput '$($hostInput.Name)' cannot use VHDX mode because it contains a reparse point: $($inputInventory.FirstReparsePoint)"
            }
            $inputManifest = Get-PayloadManifest -Artifact $inputItem -PreviousIndex $inputPreviousIndex -Inventory $inputInventory
            $inputFiles = @($inputManifest.Files)
            $inputDirectories = @($inputManifest.Directories)
            $inputContentKey = Get-PayloadContentKey -Files $inputFiles -Directories $inputDirectories
            $inputManifestDirectory = Join-Path $payloadManifestRoot $inputPayloadId
            New-Item -ItemType Directory -Force -Path $inputManifestDirectory | Out-Null
            $inputManifestPath = Join-Path $inputManifestDirectory ($inputContentKey + '.json')
            Write-JsonAtomic -Path $inputManifestPath -Value ([ordered]@{
                ManifestVersion = 2
                CacheScope = 'ReadOnlyHostInput'
                PayloadId = $inputPayloadId
                ContentKey = $inputContentKey
                ArtifactPath = $inputPath
                IsDirectory = [bool]$hostInput.IsDirectory
                DirectoryCount = $inputDirectories.Count
                FileCount = $inputFiles.Count
                TotalBytes = [long]$inputInventory.TotalBytes
                CreatedUtc = [DateTime]::UtcNow.ToString('o')
                Directories = $inputDirectories
                Files = $inputFiles
            })
            Write-JsonAtomic -Path (Join-Path $inputManifestDirectory 'source-index.json') -Value ([ordered]@{
                IndexVersion = 1
                CacheScope = 'ReadOnlyHostInput'
                PayloadId = $inputPayloadId
                ArtifactPath = $inputPath
                IsDirectory = [bool]$hostInput.IsDirectory
                UpdatedUtc = [DateTime]::UtcNow.ToString('o')
                Directories = $inputDirectories
                Files = @($inputManifest.IndexFiles)
            })
            $filesHashed = [int]$inputManifest.FilesHashed
            $hashesReused = [int]$inputManifest.HashesReused
            $candidateHashMilliseconds = [double]$inputManifest.CandidateHashMilliseconds
            $inputPayload = [ordered]@{
                CacheScope = 'ReadOnlyHostInput'
                PayloadId = $inputPayloadId
                ContentKey = $inputContentKey
                ManifestPath = $inputManifestPath
                ArtifactPath = $inputPath
                IsDirectory = [bool]$hostInput.IsDirectory
                DirectoryCount = $inputDirectories.Count
                FileCount = $inputFiles.Count
                TotalBytes = [long]$inputInventory.TotalBytes
                FingerprintEnumerationMilliseconds = [double]$inputInventory.EnumerationMilliseconds
                CandidateHashMilliseconds = $candidateHashMilliseconds
                FilesHashed = $filesHashed
                HashesReused = $hashesReused
            }
        }
        $inputDetectionWatch.Stop()
        if ($inputPayload) {
            $inputPayload['DetectionTotalMilliseconds'] = [Math]::Round($inputDetectionWatch.Elapsed.TotalMilliseconds, 3)
        }
        $preparedHostInputs += [ordered]@{
            Name = [string]$hostInput.Name
            TokenName = [string]$hostInput.TokenName
            Token = [string]$hostInput.Token
            HostPath = $inputPath
            IsDirectory = [bool]$hostInput.IsDirectory
            LeafName = if ($hostInput.IsDirectory) { $null } else { [string]$inputItem.Name }
            RequestedMode = [string]$hostInput.RequestedMode
            SelectedTransport = $selectedTransport
            SelectionReason = $selectionReason
            WarmCacheAvailable = [bool]$warmCache
            FileCount = $inputFileCount
            DirectoryCount = $inputDirectoryCount
            TotalBytes = [long]$inputInventory.TotalBytes
            CandidateCount = [int]$inputInventory.CandidateCount
            CandidateBytes = [long]$inputInventory.CandidateBytes
            ReparsePointCount = [int]$inputInventory.ReparsePointCount
            FingerprintEnumerationMilliseconds = [double]$inputInventory.EnumerationMilliseconds
            CandidateHashMilliseconds = $candidateHashMilliseconds
            DetectionTotalMilliseconds = [Math]::Round($inputDetectionWatch.Elapsed.TotalMilliseconds, 3)
            FilesHashed = $filesHashed
            HashesReused = $hashesReused
            Payload = $inputPayload
        }
    }

    $job = [ordered]@{
        id = $requestId
        executable = '{PAYLOAD}\' + $relativeExecutable
        arguments = $Arguments
        actions = $actions
    }
    if (-not [string]::IsNullOrWhiteSpace($AssertResultFile)) {
        $job['assertResultFile'] = $AssertResultFile
    }
    if ($jsonPointerSpecified) {
        $job['assertResultJsonPointer'] = $AssertResultJsonPointer
        $job['assertResultEqualsJson'] = $AssertResultEqualsJson
    }
    if ($ExpectGuestPowerOff) {
        $job['expectGuestPowerOff'] = $true
    }

    $createdUtc = [DateTime]::UtcNow
    $queueDeadlineUtc = $createdUtc.AddSeconds($QueueTimeoutSeconds)
    $request = [ordered]@{
        RequestId = $requestId
        Operation = if ($networkEnabled) { 'RunGuestJobNetworkV1' } else { 'RunGuestJob' }
        CreatedUtc = $createdUtc.ToString('o')
        QueueTimeoutSeconds = $QueueTimeoutSeconds
        ExecutionTimeoutSeconds = $ExecutionTimeoutSeconds
        RequireHostLocked = [bool]$RequireHostLocked
        ResetToBaseline = $true
        StopAfter = $true
        Payload = [ordered]@{
            PayloadId = $payloadId
            ContentKey = $payloadContentKey
            ManifestPath = $payloadManifestPath
            ArtifactPath = $canonicalArtifactPath
            IsDirectory = [bool]$artifact.PSIsContainer
            DirectoryCount = $payloadDirectories.Count
            FileCount = $payloadFiles.Count
            TotalBytes = $payloadBytes
            FingerprintEnumerationMilliseconds = [double]$payloadManifest.EnumerationMilliseconds
            CandidateHashMilliseconds = [double]$payloadManifest.CandidateHashMilliseconds
            DetectionTotalMilliseconds = [Math]::Round($payloadDetectionWatch.Elapsed.TotalMilliseconds, 3)
            FilesHashed = [int]$payloadManifest.FilesHashed
            HashesReused = [int]$payloadManifest.HashesReused
        }
        HostInputs = $preparedHostInputs
        Network = $networkContract
        Job = $job
    }
    if ($ExpectGuestPowerOff) {
        $request['ExpectGuestPowerOff'] = $true
        $request['GuestPowerOffRecoveryTimeoutSeconds'] = [int]$GuestPowerOffRecoveryTimeoutSeconds
    }

    $temporaryRequest = Join-Path $requestsRoot ($requestId + '.json.tmp')
    $request | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryRequest -Encoding UTF8
    Move-Item -LiteralPath $temporaryRequest -Destination $requestFile

    [void](Show-RequestLifecycleProgress -RequestState ([pscustomobject][ordered]@{
        Status = 'Submitted'
        Message = 'Request was atomically added to the broker queue.'
        WorkerId = $null
    }))
    Write-Host "Evidence: $resultPath"
    Write-ClientState -Status 'Queued' -Message 'Waiting for an available Hyper-V pool worker.'

    $cancellationRequestedUtc = $null
    $cancellationDeadlineUtc = $null
    $clientCancellationReason = $null
    while (-not (Test-Path -LiteralPath $brokerResultPath -PathType Leaf)) {
        $now = [DateTime]::UtcNow
        $currentRequestState = Read-RequestStateSafe -Path $requestStatePath
        if ($currentRequestState) {
            $lastReadableRequestState = $currentRequestState
        }
        $requestState = Resolve-RequestStateWithLastReadable -CurrentRequestState $currentRequestState -LastReadableRequestState $lastReadableRequestState
        $processingPresent = Test-Path -LiteralPath $processingFile -PathType Leaf
        if ($requestState) {
            Show-NewBrokerRequestState -RequestState $requestState -ProcessingPresent:$processingPresent
        }

        if ($cancellationRequestedUtc) {
            [void](Show-RequestLifecycleProgress -RequestState ([pscustomobject][ordered]@{
                Status = 'Cancelling'
                Message = "$clientCancellationReason Waiting for isolated VM cleanup."
                WorkerId = if ($requestState -and $null -ne $requestState.WorkerId) { [int]$requestState.WorkerId } else { $null }
            }) -ProcessingPresent:$processingPresent)
            Write-ClientState -Status 'Cancelling' -Message $clientCancellationReason
            if ($now -ge $cancellationDeadlineUtc) {
                throw "Broker did not finish cancellation within $CancellationGraceSeconds seconds. The immutable payload cache and canonical ArtifactPath were left intact."
            }
        }
        elseif ($processingPresent) {
            if (-not $executionDeadlineUtc) {
                $executionDeadlineUtc = $now.AddSeconds($ExecutionTimeoutSeconds)
            }
            if ($ExpectGuestPowerOff -and $requestState) {
                $publishedRecoveryDeadline = Get-OptionalRequestStateValue -RequestState $requestState -PropertyName 'PowerOffRecoveryDeadlineUtc'
                if (-not [string]::IsNullOrWhiteSpace([string]$publishedRecoveryDeadline)) {
                    $publishedShutdownUtc = Get-OptionalRequestStateValue -RequestState $requestState -PropertyName 'GuestPowerOffObservedUtc'
                    if ([string]::IsNullOrWhiteSpace([string]$publishedShutdownUtc)) {
                        throw 'Broker request state published PowerOffRecoveryDeadlineUtc without GuestPowerOffObservedUtc.'
                    }
                    try {
                        $parsedRecoveryDeadlineUtc = ConvertTo-UtcRequestStateTimestamp -Value $publishedRecoveryDeadline -PropertyName 'PowerOffRecoveryDeadlineUtc'
                        $parsedShutdownUtc = ConvertTo-UtcRequestStateTimestamp -Value $publishedShutdownUtc -PropertyName 'GuestPowerOffObservedUtc'
                    }
                    catch {
                        throw "Broker request state published an invalid expected-power-off recovery timestamp: $($_.Exception.Message)"
                    }
                    $configuredRecoveryLimitUtc = $parsedShutdownUtc.AddSeconds($GuestPowerOffRecoveryTimeoutSeconds)
                    $powerOffRecoveryDeadlineUtc = if ($parsedRecoveryDeadlineUtc -le $configuredRecoveryLimitUtc) {
                        $parsedRecoveryDeadlineUtc
                    }
                    else {
                        $configuredRecoveryLimitUtc
                    }
                }
            }
            if (-not $requestState) {
                [void](Show-RequestLifecycleProgress -RequestState $null -ProcessingPresent:$true)
            }
            $clientExecutionStatus = if ($requestState -and -not [string]::IsNullOrWhiteSpace([string]$requestState.Status)) { [string]$requestState.Status } else { 'Assigned' }
            $clientExecutionMessage = if ($requestState -and -not [string]::IsNullOrWhiteSpace([string]$requestState.Message)) { [string]$requestState.Message } else { 'Assigned to an isolated worker; waiting for broker lifecycle details.' }
            Write-ClientState -Status $clientExecutionStatus -Message $clientExecutionMessage
            $activeExecutionDeadlineUtc = if ($powerOffRecoveryDeadlineUtc) { $powerOffRecoveryDeadlineUtc } else { $executionDeadlineUtc }
            if ($now -ge $activeExecutionDeadlineUtc) {
                $clientCancellationReason = if ($powerOffRecoveryDeadlineUtc) {
                    "Expected guest power-off evidence recovery timeout expired after $GuestPowerOffRecoveryTimeoutSeconds seconds."
                }
                else {
                    "Execution timeout expired after $ExecutionTimeoutSeconds seconds."
                }
                $cancelState = Request-Cancellation -Reason $clientCancellationReason
                if ($cancelState -eq 'AlreadyCompleted') {
                    continue
                }
                $cancellationRequestedUtc = $now
                $cancellationDeadlineUtc = $now.AddSeconds($CancellationGraceSeconds)
            }
        }
        elseif (Test-Path -LiteralPath $requestFile -PathType Leaf) {
            $queue = Get-QueuePosition
            if ($queue) {
                if (-not $requestState) {
                    [void](Show-RequestLifecycleProgress -RequestState ([pscustomobject][ordered]@{
                        Status = 'Queued'
                        Message = 'Waiting for an available Hyper-V pool worker.'
                        QueuePosition = $queue.Position
                        QueueDepth = $queue.Depth
                        WorkerId = $null
                    }))
                }
                Write-ClientState -Status 'Queued' -Message 'Waiting for an available Hyper-V pool worker.' -QueuePosition $queue.Position -QueueDepth $queue.Depth
            }
            if ($now -ge $queueDeadlineUtc) {
                $clientCancellationReason = "Queue timeout expired after $QueueTimeoutSeconds seconds."
                $cancelState = Request-Cancellation -Reason $clientCancellationReason
                if ($cancelState -eq 'CancelledBeforeStart') {
                    $cancelledBeforeStart = $true
                    Write-ClientState -Status 'QueueTimedOut' -Message $clientCancellationReason
                    break
                }
                if ($cancelState -ne 'AlreadyCompleted') {
                    $cancellationRequestedUtc = $now
                    $cancellationDeadlineUtc = $now.AddSeconds($CancellationGraceSeconds)
                }
            }
        }
        else {
            $cancelledRecord = Get-ChildItem -LiteralPath $cancelledRoot -Filter ($requestId + '-*.json') -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cancelledRecord) {
                $cancelledBeforeStart = $true
                $clientCancellationReason = 'The queued request was cancelled before execution.'
                Write-ClientState -Status 'Cancelled' -Message $clientCancellationReason
                break
            }
            if (-not $requestState) {
                [void](Show-RequestLifecycleProgress -RequestState $null -ProcessingPresent:$true)
            }
            Write-ClientState -Status 'Claiming' -Message 'The request is moving from the queue into execution.'
            if ($now -ge $queueDeadlineUtc) {
                $clientCancellationReason = "Queue timeout expired while the broker was claiming the request."
                $cancelState = Request-Cancellation -Reason $clientCancellationReason
                if ($cancelState -ne 'AlreadyCompleted') {
                    $cancellationRequestedUtc = $now
                    $cancellationDeadlineUtc = $now.AddSeconds($CancellationGraceSeconds)
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }

    if ($cancelledBeforeStart) {
        $queueTimedOutBeforeStart = $clientCancellationReason -like 'Queue timeout*'
        $terminalStatus = if ($queueTimedOutBeforeStart) { 'QueueTimedOut' } else { 'Cancelled' }
        [void](Show-RequestLifecycleProgress -RequestState ([pscustomobject][ordered]@{
            Status = $terminalStatus
            Message = $clientCancellationReason
            WorkerId = $null
        }))
        $summary = [ordered]@{
            Success = $false
            OverallSucceeded = $false
            HarnessSucceeded = $false
            BrokerSucceeded = $false
            GuestHarnessSucceeded = $false
            TestEvaluated = $false
            TestPassed = $null
            FailureKind = if ($queueTimedOutBeforeStart) { 'QueueTimeout' } else { 'Cancelled' }
            RequestId = $requestId
            ArtifactPath = $artifact.FullName
            PayloadId = $payloadId
            PayloadContentKey = $payloadContentKey
            PayloadFingerprintEnumerationMilliseconds = [double]$payloadManifest.EnumerationMilliseconds
            PayloadCandidateHashMilliseconds = [double]$payloadManifest.CandidateHashMilliseconds
            PayloadDetectionTotalMilliseconds = [Math]::Round($payloadDetectionWatch.Elapsed.TotalMilliseconds, 3)
            PayloadFilesHashed = [int]$payloadManifest.FilesHashed
            PayloadHashesReused = [int]$payloadManifest.HashesReused
            HostInputs = @($preparedHostInputs)
            Network = $networkContract
            ExecutableRelativePath = $relativeExecutable
            Status = $terminalStatus
            Cancelled = -not $queueTimedOutBeforeStart
            QueueTimedOut = $queueTimedOutBeforeStart
            ExecutionTimedOut = $false
            ResultPath = $resultPath
            VmFinalState = 'NotStarted'
            Error = $clientCancellationReason
            LifecycleSequence = @($observedLifecycle.ToArray())
        }
        if ($ExpectGuestPowerOff) {
            $summary['ExpectGuestPowerOff'] = $true
            $summary['GuestPowerOffRecoveryTimeoutSeconds'] = [int]$GuestPowerOffRecoveryTimeoutSeconds
            $summary['GuestApplicationEraRunningObservedUtc'] = $null
            $summary['GuestPowerOffObservedUtc'] = $null
            $summary['GuestPowerOffBeforeCleanup'] = $null
            $summary['BrokerCleanupStartedUtc'] = $null
            $summary['GuestPowerOffEvidenceRecoveryMode'] = $null
            $summary['GuestPowerOffEvidenceRecoveryBootedUtc'] = $null
            $summary['GuestPowerOffEvidenceRecoveryCompletedUtc'] = $null
            $summary['GuestPowerOffEvidenceRecoveryTimedOut'] = $null
            $summary['ApplicationRelaunchedByHarnessAfterGuestPowerOff'] = $null
            $summary['ExpectedGuestPowerOffContractSatisfied'] = $null
            $summary['ExpectedGuestPowerOffContractProven'] = $false
            $summary['PowerOffRecoveryDeadlineUtc'] = $null
        }
        $summary | ConvertTo-Json -Depth 8
        $finalExitCode = if ($queueTimedOutBeforeStart) { 124 } else { 130 }
    }
    else {
        $brokerResult = Get-Content -Raw -LiteralPath $brokerResultPath | ConvertFrom-Json
        $guestResultPath = Join-Path $resultPath 'result.json'
        $guestResult = if (Test-Path -LiteralPath $guestResultPath -PathType Leaf) {
            Get-Content -Raw -LiteralPath $guestResultPath | ConvertFrom-Json
        }
        else {
            $null
        }

        $missingHarnessEvidence = @()
        foreach ($relativeEvidencePath in $expectedHarnessEvidence) {
            $evidencePrefix = [IO.Path]::GetFullPath($resultPath).TrimEnd('\') + '\'
            $evidencePath = [IO.Path]::GetFullPath((Join-Path $resultPath $relativeEvidencePath))
            if (-not $evidencePath.StartsWith($evidencePrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $evidencePath -PathType Leaf) -or
                (Get-Item -LiteralPath $evidencePath -ErrorAction SilentlyContinue).Length -le 0) {
                $missingHarnessEvidence += $relativeEvidencePath
            }
        }

        $missingTestEvidence = @()
        foreach ($relativeEvidencePath in $expectedTestEvidence) {
            $evidencePrefix = [IO.Path]::GetFullPath($resultPath).TrimEnd('\') + '\'
            $evidencePath = [IO.Path]::GetFullPath((Join-Path $resultPath $relativeEvidencePath))
            if (-not $evidencePath.StartsWith($evidencePrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $evidencePath -PathType Leaf) -or
                (Get-Item -LiteralPath $evidencePath -ErrorAction SilentlyContinue).Length -le 0) {
                $missingTestEvidence += $relativeEvidencePath
            }
        }

        $guestApplicationEraRunningObservedUtc = Get-OptionalRequestStateValue -RequestState $brokerResult -PropertyName 'GuestApplicationEraRunningObservedUtc'
        $guestPowerOffObservedUtc = Get-OptionalRequestStateValue -RequestState $brokerResult -PropertyName 'GuestPowerOffObservedUtc'
        $brokerCleanupStartedUtc = Get-OptionalRequestStateValue -RequestState $brokerResult -PropertyName 'BrokerCleanupStartedUtc'
        $publishedPowerOffRecoveryDeadlineUtc = Get-OptionalRequestStateValue -RequestState $brokerResult -PropertyName 'PowerOffRecoveryDeadlineUtc'
        $guestPowerOffBeforeCleanupProperty = $brokerResult.PSObject.Properties['GuestPowerOffBeforeCleanup']
        $guestPowerOffRecoveryMode = Get-OptionalRequestStateValue -RequestState $brokerResult -PropertyName 'GuestPowerOffEvidenceRecoveryMode'
        $guestPowerOffRecoveryBootedUtc = Get-OptionalRequestStateValue -RequestState $brokerResult -PropertyName 'GuestPowerOffEvidenceRecoveryBootedUtc'
        $guestPowerOffRecoveryCompletedUtc = Get-OptionalRequestStateValue -RequestState $brokerResult -PropertyName 'GuestPowerOffEvidenceRecoveryCompletedUtc'
        $guestPowerOffRecoveryTimedOut = Get-OptionalRequestStateValue -RequestState $brokerResult -PropertyName 'GuestPowerOffEvidenceRecoveryTimedOut'
        $guestPowerOffRecoveryTimedOutProperty = $brokerResult.PSObject.Properties['GuestPowerOffEvidenceRecoveryTimedOut']
        $applicationRelaunchedProperty = $brokerResult.PSObject.Properties['ApplicationRelaunchedByHarnessAfterGuestPowerOff']
        $powerOffContractSatisfiedProperty = $brokerResult.PSObject.Properties['ExpectedGuestPowerOffContractSatisfied']
        $guestResultFileEvidenceProperty = if ($guestResult) { $guestResult.PSObject.Properties['ResultFileEvidence'] } else { $null }
        $guestMarkerExistsProperty = if ($guestResultFileEvidenceProperty) { $guestResultFileEvidenceProperty.Value.PSObject.Properties['Exists'] } else { $null }
        $guestMarkerPredatesRecoveryProperty = if ($guestResultFileEvidenceProperty) { $guestResultFileEvidenceProperty.Value.PSObject.Properties['PredatesRecoveryBoot'] } else { $null }
        $brokerExpectGuestPowerOffProperty = @($brokerResult.PSObject.Properties | Where-Object { $_.Name -ceq 'ExpectGuestPowerOff' }) | Select-Object -First 1
        $brokerRecoveryTimeoutProperty = @($brokerResult.PSObject.Properties | Where-Object { $_.Name -ceq 'GuestPowerOffRecoveryTimeoutSeconds' }) | Select-Object -First 1
        $powerOffContractEvidenceFailures = @()
        $expectedGuestPowerOffContractProven = -not [bool]$ExpectGuestPowerOff
        if ($ExpectGuestPowerOff) {
            if (-not $brokerExpectGuestPowerOffProperty -or $brokerExpectGuestPowerOffProperty.Value -isnot [bool] -or -not [bool]$brokerExpectGuestPowerOffProperty.Value) {
                $powerOffContractEvidenceFailures += 'Broker result ExpectGuestPowerOff is not exact Boolean true.'
            }
            $brokerTimeoutType = if ($brokerRecoveryTimeoutProperty -and $null -ne $brokerRecoveryTimeoutProperty.Value) { $brokerRecoveryTimeoutProperty.Value.GetType() } else { $null }
            $integralBrokerTimeoutTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
            if (-not $brokerRecoveryTimeoutProperty -or -not $brokerTimeoutType -or $brokerTimeoutType -notin $integralBrokerTimeoutTypes -or
                [int64]$brokerRecoveryTimeoutProperty.Value -ne [int64]$GuestPowerOffRecoveryTimeoutSeconds) {
                $powerOffContractEvidenceFailures += 'Broker result GuestPowerOffRecoveryTimeoutSeconds does not exactly match the requested recovery timeout.'
            }
            $runningObservedTimestamp = $null
            $shutdownObservedTimestamp = $null
            $recoveryDeadlineTimestamp = $null
            $recoveryBootedTimestamp = $null
            $recoveryCompletedTimestamp = $null
            $cleanupStartedTimestamp = $null
            $originalExecutionDeadlineTimestamp = $null
            if ([string]::IsNullOrWhiteSpace([string]$guestApplicationEraRunningObservedUtc)) {
                $powerOffContractEvidenceFailures += 'GuestApplicationEraRunningObservedUtc is missing.'
            }
            else {
                try {
                    $runningObservedTimestamp = [DateTimeOffset]::Parse(
                        [string]$guestApplicationEraRunningObservedUtc,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind
                    )
                }
                catch { $powerOffContractEvidenceFailures += 'GuestApplicationEraRunningObservedUtc is invalid.' }
            }
            if ([string]::IsNullOrWhiteSpace([string]$guestPowerOffObservedUtc)) {
                $powerOffContractEvidenceFailures += 'GuestPowerOffObservedUtc is missing.'
            }
            else {
                try {
                    $shutdownObservedTimestamp = [DateTimeOffset]::Parse(
                        [string]$guestPowerOffObservedUtc,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind
                    )
                }
                catch { $powerOffContractEvidenceFailures += 'GuestPowerOffObservedUtc is invalid.' }
            }
            if ($runningObservedTimestamp -and $shutdownObservedTimestamp -and $shutdownObservedTimestamp -le $runningObservedTimestamp) {
                $powerOffContractEvidenceFailures += 'GuestPowerOffObservedUtc does not follow GuestApplicationEraRunningObservedUtc.'
            }
            try {
                $originalExecutionDeadlineTimestamp = [DateTimeOffset]::Parse(
                    [string]$brokerResult.ExecutionDeadlineUtc,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
            }
            catch { $powerOffContractEvidenceFailures += 'ExecutionDeadlineUtc is invalid.' }
            if ($shutdownObservedTimestamp -and $originalExecutionDeadlineTimestamp -and $shutdownObservedTimestamp -ge $originalExecutionDeadlineTimestamp) {
                $powerOffContractEvidenceFailures += 'GuestPowerOffObservedUtc did not precede the original application execution deadline.'
            }
            foreach ($timestampContract in @(
                [pscustomobject]@{ Name = 'PowerOffRecoveryDeadlineUtc'; Value = $publishedPowerOffRecoveryDeadlineUtc; Target = 'recoveryDeadlineTimestamp' },
                [pscustomobject]@{ Name = 'GuestPowerOffEvidenceRecoveryBootedUtc'; Value = $guestPowerOffRecoveryBootedUtc; Target = 'recoveryBootedTimestamp' },
                [pscustomobject]@{ Name = 'GuestPowerOffEvidenceRecoveryCompletedUtc'; Value = $guestPowerOffRecoveryCompletedUtc; Target = 'recoveryCompletedTimestamp' },
                [pscustomobject]@{ Name = 'BrokerCleanupStartedUtc'; Value = $brokerCleanupStartedUtc; Target = 'cleanupStartedTimestamp' }
            )) {
                if ([string]::IsNullOrWhiteSpace([string]$timestampContract.Value)) {
                    $powerOffContractEvidenceFailures += "$($timestampContract.Name) is missing."
                    continue
                }
                try {
                    $parsedTimestamp = [DateTimeOffset]::Parse(
                        [string]$timestampContract.Value,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind
                    )
                    Set-Variable -Name ([string]$timestampContract.Target) -Value $parsedTimestamp
                }
                catch { $powerOffContractEvidenceFailures += "$($timestampContract.Name) is invalid." }
            }
            if ($shutdownObservedTimestamp -and $recoveryDeadlineTimestamp) {
                if ($recoveryDeadlineTimestamp -le $shutdownObservedTimestamp -or
                    $recoveryDeadlineTimestamp -gt $shutdownObservedTimestamp.AddSeconds($GuestPowerOffRecoveryTimeoutSeconds)) {
                    $powerOffContractEvidenceFailures += 'PowerOffRecoveryDeadlineUtc is outside the bounded recovery window.'
                }
            }
            if ($shutdownObservedTimestamp -and $recoveryBootedTimestamp -and $recoveryBootedTimestamp -le $shutdownObservedTimestamp) {
                $powerOffContractEvidenceFailures += 'GuestPowerOffEvidenceRecoveryBootedUtc does not follow GuestPowerOffObservedUtc.'
            }
            if ($recoveryBootedTimestamp -and $recoveryCompletedTimestamp -and $recoveryCompletedTimestamp -lt $recoveryBootedTimestamp) {
                $powerOffContractEvidenceFailures += 'GuestPowerOffEvidenceRecoveryCompletedUtc precedes the recovery boot.'
            }
            if ($recoveryCompletedTimestamp -and $recoveryDeadlineTimestamp -and $recoveryCompletedTimestamp -gt $recoveryDeadlineTimestamp) {
                $powerOffContractEvidenceFailures += 'GuestPowerOffEvidenceRecoveryCompletedUtc exceeds the bounded recovery deadline.'
            }
            if ($recoveryCompletedTimestamp -and $cleanupStartedTimestamp -and $cleanupStartedTimestamp -lt $recoveryCompletedTimestamp) {
                $powerOffContractEvidenceFailures += 'BrokerCleanupStartedUtc precedes completion of expected-power-off evidence recovery.'
            }
            if ($null -eq $guestPowerOffBeforeCleanupProperty -or $guestPowerOffBeforeCleanupProperty.Value -isnot [bool] -or -not [bool]$guestPowerOffBeforeCleanupProperty.Value) {
                $powerOffContractEvidenceFailures += 'GuestPowerOffBeforeCleanup is not exact Boolean true.'
            }
            if (-not [String]::Equals([string]$guestPowerOffRecoveryMode, 'ControlledReboot', [StringComparison]::Ordinal)) {
                $powerOffContractEvidenceFailures += 'GuestPowerOffEvidenceRecoveryMode is not ControlledReboot.'
            }
            if ($null -eq $applicationRelaunchedProperty -or $applicationRelaunchedProperty.Value -isnot [bool] -or [bool]$applicationRelaunchedProperty.Value) {
                $powerOffContractEvidenceFailures += 'ApplicationRelaunchedByHarnessAfterGuestPowerOff is not exact Boolean false.'
            }
            if ($null -eq $guestMarkerExistsProperty -or $guestMarkerExistsProperty.Value -isnot [bool] -or
                $null -eq $guestMarkerPredatesRecoveryProperty -or $guestMarkerPredatesRecoveryProperty.Value -isnot [bool] -or
                ([bool]$guestMarkerExistsProperty.Value -and -not [bool]$guestMarkerPredatesRecoveryProperty.Value) -or
                (-not [bool]$guestMarkerExistsProperty.Value -and [bool]$guestMarkerPredatesRecoveryProperty.Value)) {
                $powerOffContractEvidenceFailures += 'ResultFileEvidence does not prove that a present assertion marker predates the controlled recovery boot.'
            }
            if ($null -eq $guestPowerOffRecoveryTimedOutProperty -or $guestPowerOffRecoveryTimedOutProperty.Value -isnot [bool] -or [bool]$guestPowerOffRecoveryTimedOutProperty.Value) {
                $powerOffContractEvidenceFailures += 'GuestPowerOffEvidenceRecoveryTimedOut is not exact Boolean false.'
            }
            if ($null -eq $powerOffContractSatisfiedProperty -or $powerOffContractSatisfiedProperty.Value -isnot [bool] -or -not [bool]$powerOffContractSatisfiedProperty.Value) {
                $powerOffContractEvidenceFailures += 'ExpectedGuestPowerOffContractSatisfied is not exact Boolean true.'
            }
            $expectedGuestPowerOffContractProven = $powerOffContractEvidenceFailures.Count -eq 0
        }

        $baseHarnessSucceeded = [bool]$brokerResult.Success -and
            [string]$brokerResult.VmFinalState -eq 'Off' -and
            $guestResult -and [bool]$guestResult.Success -and
            $missingHarnessEvidence.Count -eq 0
        $harnessSucceeded = [bool]$baseHarnessSucceeded -and [bool]$expectedGuestPowerOffContractProven
        $testEvaluated = [bool]($guestResult -and $guestResult.TestEvaluated)
        $testPassed = if ($testEvaluated) { [bool]$guestResult.TestPassed } else { $null }
        if ($missingTestEvidence.Count -gt 0) {
            $testEvaluated = $true
            $testPassed = $false
        }
        $overallSucceeded = [bool]$harnessSucceeded -and (-not $testEvaluated -or [bool]$testPassed)

        $finalStatus = if ($overallSucceeded) { 'Completed' } elseif ($harnessSucceeded -and $testEvaluated -and -not $testPassed) { 'TestFailed' } elseif ($brokerResult.QueueTimedOut) { 'QueueTimedOut' } elseif ($brokerResult.ExecutionTimedOut) { 'ExecutionTimedOut' } elseif ($brokerResult.Cancelled) { 'Cancelled' } else { 'Failed' }
        Write-ClientState -Status $finalStatus -Message ([string]$brokerResult.Error)
        $terminalRequestState = Read-RequestStateSafe -Path $requestStatePath
        if ($terminalRequestState -and [string]$terminalRequestState.Status -in @('Completed', 'TestFailed', 'Failed', 'Cancelled', 'QueueTimedOut', 'ExecutionTimedOut')) {
            Show-NewBrokerRequestState -RequestState $terminalRequestState
        }
        else {
            [void](Show-RequestLifecycleProgress -RequestState ([pscustomobject][ordered]@{
                Status = $finalStatus
                Message = if ([string]::IsNullOrWhiteSpace([string]$brokerResult.Error)) { 'Terminal broker result received.' } else { [string]$brokerResult.Error }
                WorkerId = if ($null -ne $brokerResult.PoolWorkerId) { [int]$brokerResult.PoolWorkerId } else { $null }
            }))
        }
        $summary = [ordered]@{
            Success = [bool]$overallSucceeded
            OverallSucceeded = [bool]$overallSucceeded
            HarnessSucceeded = [bool]$harnessSucceeded
            BrokerSucceeded = [bool]$brokerResult.Success
            GuestHarnessSucceeded = [bool]($guestResult -and $guestResult.Success)
            TestEvaluated = [bool]$testEvaluated
            TestPassed = if ($testEvaluated) { [bool]$testPassed } else { $null }
            FailureKind = if (-not $harnessSucceeded) {
                if ($baseHarnessSucceeded -and $ExpectGuestPowerOff -and -not $expectedGuestPowerOffContractProven) {
                    'ExpectedGuestPowerOffContract'
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$brokerResult.FailureKind)) {
                    [string]$brokerResult.FailureKind
                }
                else { 'Harness' }
            }
            elseif ($testEvaluated -and -not $testPassed) {
                if ($guestResult -and -not [string]::IsNullOrWhiteSpace([string]$guestResult.TestFailureKind)) { [string]$guestResult.TestFailureKind } else { 'TestAssertion' }
            }
            else { $null }
            RequestId = $requestId
            ArtifactPath = $artifact.FullName
            PayloadId = $payloadId
            PayloadContentKey = $payloadContentKey
            PayloadFingerprintEnumerationMilliseconds = [double]$brokerResult.PayloadFingerprintEnumerationMilliseconds
            PayloadCandidateHashMilliseconds = [double]$brokerResult.PayloadCandidateHashMilliseconds
            PayloadDetectionTotalMilliseconds = [double]$brokerResult.PayloadDetectionTotalMilliseconds
            PayloadFilesHashed = [int]$brokerResult.PayloadFilesHashed
            PayloadHashesReused = [int]$brokerResult.PayloadHashesReused
            PayloadCacheOperationMilliseconds = [double]$brokerResult.PayloadCacheOperationMilliseconds
            PayloadVhdxSyncMilliseconds = [double]$brokerResult.PayloadVhdxSyncMilliseconds
            PayloadCacheHit = [bool]$brokerResult.PayloadCacheHit
            PayloadSyncMode = [string]$brokerResult.PayloadSyncMode
            PayloadFilesCopied = [int]$brokerResult.PayloadFilesCopied
            PayloadFilesDeleted = [int]$brokerResult.PayloadFilesDeleted
            PayloadParentVhdx = [string]$brokerResult.PayloadParentVhdx
            PayloadChildDeleted = [bool]$brokerResult.PayloadChildDeleted
            HostInputs = if ($brokerResult.HostInputs) { @($brokerResult.HostInputs) } else { @() }
            Network = if ($brokerResult.Network) { $brokerResult.Network } else { $networkContract }
            ExecutableRelativePath = $relativeExecutable
            Status = $finalStatus
            QueueTimeoutSeconds = $QueueTimeoutSeconds
            ExecutionTimeoutSeconds = $ExecutionTimeoutSeconds
            RequireHostLocked = [bool]$RequireHostLocked
            ResultPath = $resultPath
            BrokerResultPath = $brokerResultPath
            GuestResultPath = $guestResultPath
            VmFinalState = [string]$brokerResult.VmFinalState
            PoolWorkerId = if ($null -ne $brokerResult.PoolWorkerId) { [int]$brokerResult.PoolWorkerId } else { $null }
            PoolWorkerRecyclePending = [bool]$brokerResult.PoolWorkerRecyclePending
            InfrastructureRetryCount = if ($null -ne $brokerResult.InfrastructureRetryCount) { [int]$brokerResult.InfrastructureRetryCount } else { 0 }
            InfrastructureRetryHistory = if ($brokerResult.InfrastructureRetryHistory) { @($brokerResult.InfrastructureRetryHistory) } else { @() }
            Cancelled = [bool]$brokerResult.Cancelled
            QueueTimedOut = [bool]$brokerResult.QueueTimedOut
            ExecutionTimedOut = [bool]$brokerResult.ExecutionTimedOut
            ExpectedHarnessEvidence = @($expectedHarnessEvidence)
            MissingHarnessEvidence = @($missingHarnessEvidence)
            ExpectedTestEvidence = @($expectedTestEvidence)
            MissingTestEvidence = @($missingTestEvidence)
            ExpectedEvidence = @($expectedHarnessEvidence + $expectedTestEvidence)
            MissingEvidence = @($missingHarnessEvidence + $missingTestEvidence)
            LockedBefore = if ($brokerResult.HostLockEvidenceBefore) { [bool]$brokerResult.HostLockEvidenceBefore.IsLocked } else { $false }
            LockedAfter = if ($brokerResult.HostLockEvidenceAfter) { [bool]$brokerResult.HostLockEvidenceAfter.IsLocked } else { $false }
            Error = if (-not $brokerResult.Success) {
                [string]$brokerResult.Error
            }
            elseif (-not $guestResult) {
                'Guest result is missing.'
            }
            elseif (-not $guestResult.Success) {
                [string]$guestResult.Error
            }
            elseif ($missingHarnessEvidence.Count -gt 0) {
                'Required harness evidence is missing or empty: ' + ($missingHarnessEvidence -join ', ')
            }
            elseif ($ExpectGuestPowerOff -and -not $expectedGuestPowerOffContractProven) {
                'Expected guest power-off contract evidence was incomplete or invalid: ' + ($powerOffContractEvidenceFailures -join ' ')
            }
            elseif ($testEvaluated -and -not $testPassed) {
                if ($missingTestEvidence.Count -gt 0) {
                    'Required test evidence is missing or empty: ' + ($missingTestEvidence -join ', ')
                }
                elseif ($guestResult -and -not [string]::IsNullOrWhiteSpace([string]$guestResult.TestFailureMessage)) {
                    [string]$guestResult.TestFailureMessage
                }
                else {
                    'The application-under-test did not satisfy its declared assertion.'
                }
            }
            else {
                $null
            }
            LifecycleSequence = @($observedLifecycle.ToArray())
        }
        if ($ExpectGuestPowerOff) {
            $summary['ExpectGuestPowerOff'] = $true
            $summary['GuestPowerOffRecoveryTimeoutSeconds'] = [int]$GuestPowerOffRecoveryTimeoutSeconds
            $summary['GuestApplicationEraRunningObservedUtc'] = $guestApplicationEraRunningObservedUtc
            $summary['GuestPowerOffObservedUtc'] = $guestPowerOffObservedUtc
            $summary['GuestPowerOffBeforeCleanup'] = if ($null -ne $guestPowerOffBeforeCleanupProperty) { $guestPowerOffBeforeCleanupProperty.Value } else { $null }
            $summary['BrokerCleanupStartedUtc'] = $brokerCleanupStartedUtc
            $summary['GuestPowerOffEvidenceRecoveryMode'] = $guestPowerOffRecoveryMode
            $summary['GuestPowerOffEvidenceRecoveryBootedUtc'] = $guestPowerOffRecoveryBootedUtc
            $summary['GuestPowerOffEvidenceRecoveryCompletedUtc'] = $guestPowerOffRecoveryCompletedUtc
            $summary['GuestPowerOffEvidenceRecoveryTimedOut'] = $guestPowerOffRecoveryTimedOut
            $summary['ApplicationRelaunchedByHarnessAfterGuestPowerOff'] = if ($null -ne $applicationRelaunchedProperty) { $applicationRelaunchedProperty.Value } else { $null }
            $summary['ExpectedGuestPowerOffContractSatisfied'] = if ($null -ne $powerOffContractSatisfiedProperty) { $powerOffContractSatisfiedProperty.Value } else { $null }
            $summary['ExpectedGuestPowerOffContractProven'] = [bool]$expectedGuestPowerOffContractProven
            $summary['ExpectedGuestPowerOffContractEvidenceFailures'] = @($powerOffContractEvidenceFailures)
            $summary['PowerOffRecoveryDeadlineUtc'] = $publishedPowerOffRecoveryDeadlineUtc
        }
        $summary | ConvertTo-Json -Depth 8
        if (-not $overallSucceeded) {
            $finalExitCode = 1
        }
    }
}
finally {
    # Payload manifests are tiny, content-addressed cache metadata. The SYSTEM
    # broker garbage-collects stale manifests together with their VHDX cache.
}

if ($finalExitCode -ne 0) {
    if ($ThrowOnFailure) {
        throw "The isolated executable test failed with exit code $finalExitCode."
    }
    exit $finalExitCode
}
