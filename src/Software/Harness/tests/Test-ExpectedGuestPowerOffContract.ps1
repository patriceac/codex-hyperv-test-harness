[CmdletBinding()]
param([string] $HostBrokerPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($HostBrokerPath)) {
    $HostBrokerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'HostBroker.ps1'
}

function Get-ScriptAst {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has a parse error: $($errors[0].Message)" }
    $ast
}

function Import-AstFunction {
    param(
        [Parameter(Mandatory = $true)] $Ast,
        [Parameter(Mandatory = $true)] [string] $Name
    )
    $definition = @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
}

function Assert-True {
    param([bool] $Condition, [Parameter(Mandatory = $true)] [string] $Message)
    if (-not $Condition) { throw $Message }
}

$brokerAst = Get-ScriptAst -Path $HostBrokerPath
foreach ($name in @('Write-JsonAtomic', 'Write-TerminalJsonAtomic', 'Invoke-WithTerminalResultPublicationMutex', 'Read-BrokerJsonWithRetry', 'ConvertTo-BrokerTimestampText', 'Write-RequestState', 'Get-ExpectedGuestPowerOffObservation', 'Get-InterruptedExpectedGuestPowerOffRecoveryClassification', 'Get-InterruptedExpectedGuestPowerOffNoReplayState', 'Move-QueuedRequestWithTerminalResult', 'Test-GuestSessionBootIdentity')) {
    Import-AstFunction -Ast $brokerAst -Name $name
}

$scenarios = New-Object Collections.Generic.List[string]

$disabled = Get-ExpectedGuestPowerOffObservation -Enabled $false -VmState Off -ApplicationConfirmed $false -ApplicationEraRunningObservedUtc $null -BrokerCleanupStartedUtc $null
Assert-True ([string]$disabled.Action -eq 'None') 'The legacy path unexpectedly interpreted VM Off as an expected-power-off transition.'
$scenarios.Add('legacy-observation-is-disabled')

$premature = Get-ExpectedGuestPowerOffObservation -Enabled $true -VmState Off -ApplicationConfirmed $false -ApplicationEraRunningObservedUtc $null -BrokerCleanupStartedUtc $null
Assert-True ([string]$premature.Action -eq 'Fail' -and [string]$premature.FailureKind -eq 'ExpectedGuestPowerOffPremature') 'Power-off before application confirmation was not rejected.'
$scenarios.Add('power-off-before-application-is-rejected')

$unproven = Get-ExpectedGuestPowerOffObservation -Enabled $true -VmState Off -ApplicationConfirmed $true -ApplicationEraRunningObservedUtc $null -BrokerCleanupStartedUtc $null
Assert-True ([string]$unproven.Action -eq 'Fail' -and [string]$unproven.FailureKind -eq 'ExpectedGuestPowerOffUnproven') 'Final-Off-only evidence was accepted without an application-era Running observation.'
$scenarios.Add('final-off-only-is-not-causal-proof')

$running = Get-ExpectedGuestPowerOffObservation -Enabled $true -VmState Running -ApplicationConfirmed $true -ApplicationEraRunningObservedUtc $null -BrokerCleanupStartedUtc $null
Assert-True ([string]$running.Action -eq 'RecordApplicationEraRunning') 'The application-era Running observation was not recognized.'
$scenarios.Add('application-era-running-is-recorded')

$poweredOff = Get-ExpectedGuestPowerOffObservation -Enabled $true -VmState Off -ApplicationConfirmed $true -ApplicationEraRunningObservedUtc '2026-08-31T00:00:01Z' -BrokerCleanupStartedUtc $null
Assert-True ([string]$poweredOff.Action -eq 'RecordGuestPowerOff') 'A valid Running-to-Off transition before cleanup was not recognized.'
$scenarios.Add('running-to-off-before-cleanup-is-accepted')

$afterCleanup = Get-ExpectedGuestPowerOffObservation -Enabled $true -VmState Off -ApplicationConfirmed $true -ApplicationEraRunningObservedUtc '2026-08-31T00:00:01Z' -BrokerCleanupStartedUtc '2026-08-31T00:00:02Z'
Assert-True ([string]$afterCleanup.Action -eq 'Fail' -and [string]$afterCleanup.FailureKind -eq 'ExpectedGuestPowerOffAfterCleanup') 'Broker cleanup Off was accepted as guest shutdown causality.'
$scenarios.Add('cleanup-off-is-not-causal-proof')

$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-poweroff-state-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    Write-RequestState -ResultRoot $stateRoot -RequestId 'poweroff-state' -Status ApplicationRunning -ExpectGuestPowerOff $true -ExpectedGuestPowerOffSubmissionStartedUtc '2026-08-31T00:00:00Z' -GuestJobMayHaveLaunched $true -GuestApplicationEraRunningObservedUtc '2026-08-31T00:00:01Z'
    Write-RequestState -ResultRoot $stateRoot -RequestId 'poweroff-state' -Status RecoveringPowerOffEvidence -GuestPowerOffObservedUtc '2026-08-31T00:00:02Z' -GuestPowerOffBeforeCleanup $true -PowerOffRecoveryDeadlineUtc '2026-08-31T00:03:02Z'
    Write-RequestState -ResultRoot $stateRoot -RequestId 'poweroff-state' -Status RecoveringPowerOffEvidence -ExpectGuestPowerOff $false -ExpectedGuestPowerOffSubmissionStartedUtc '2026-08-31T00:00:30Z' -GuestJobMayHaveLaunched $false -GuestApplicationEraRunningObservedUtc '2026-08-31T00:00:31Z' -GuestPowerOffObservedUtc '2026-08-31T00:00:32Z' -GuestPowerOffBeforeCleanup $false
    $state = Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'request-state.json') | ConvertFrom-Json
    $persistedSubmissionUtc = [DateTimeOffset]::Parse([string]$state.ExpectedGuestPowerOffSubmissionStartedUtc).UtcDateTime
    $expectedSubmissionUtc = [DateTimeOffset]::Parse('2026-08-31T00:00:00Z').UtcDateTime
    Assert-True (
        $state.ExpectGuestPowerOff -is [bool] -and [bool]$state.ExpectGuestPowerOff -and
        $state.GuestJobMayHaveLaunched -is [bool] -and [bool]$state.GuestJobMayHaveLaunched -and
        $persistedSubmissionUtc.Ticks -eq $expectedSubmissionUtc.Ticks -and
        [string]$state.GuestApplicationEraRunningObservedUtc -eq '2026-08-31T00:00:01Z' -and
        [string]$state.GuestPowerOffObservedUtc -eq '2026-08-31T00:00:02Z' -and
        $state.GuestPowerOffBeforeCleanup -is [bool] -and [bool]$state.GuestPowerOffBeforeCleanup -and
        [string]$state.PowerOffRecoveryDeadlineUtc -eq '2026-08-31T00:03:02Z'
    ) 'Expected-power-off request-state evidence was not preserved monotonically across lifecycle revisions.'
    $scenarios.Add('causal-request-state-is-monotonic')

    $requestStatePath = Join-Path $stateRoot 'request-state.json'
    $stateHashBeforeTerminal = (Get-FileHash -LiteralPath $requestStatePath -Algorithm SHA256).Hash
    $terminalPath = Join-Path $stateRoot 'broker-result.json'
    Assert-True (Write-TerminalJsonAtomic -Path $terminalPath -Value ([ordered]@{ RequestId = 'poweroff-state'; Winner = 'first' })) 'The first terminal publisher unexpectedly lost.'
    Write-RequestState -ResultRoot $stateRoot -RequestId 'poweroff-state' -Status Failed -Message 'late state writer'
    Assert-True ((Get-FileHash -LiteralPath $requestStatePath -Algorithm SHA256).Hash -eq $stateHashBeforeTerminal) 'A state writer mutated lifecycle evidence after terminal publication.'
    Assert-True (-not (Write-TerminalJsonAtomic -Path $terminalPath -Value ([ordered]@{ RequestId = 'poweroff-state'; Winner = 'loser' }))) 'A competing terminal writer replaced the first result.'
    $terminal = Get-Content -Raw -LiteralPath $terminalPath | ConvertFrom-Json
    Assert-True ([string]$terminal.Winner -eq 'first') 'The losing terminal publisher changed the visible terminal result.'
    $scenarios.Add('terminal-winner-closes-state-and-result')
}
finally {
    Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$invalidStateRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-poweroff-invalid-state-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $invalidStateRoot | Out-Null
    [ordered]@{ RequestId = 'invalid-state'; Status = 'Queued'; ExpectGuestPowerOff = 'true'; Revision = 1; History = @() } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $invalidStateRoot 'request-state.json') -Encoding UTF8
    $invalidBooleanRejected = $false
    try { Write-RequestState -ResultRoot $invalidStateRoot -RequestId 'invalid-state' -Status Claimed }
    catch { $invalidBooleanRejected = $_.Exception.Message -like '*must be an exact JSON Boolean or null*' }
    Assert-True $invalidBooleanRejected 'A persisted string expected-power-off flag was coerced instead of rejected.'
    $scenarios.Add('persisted-poweroff-booleans-are-exact')
}
finally {
    Remove-Item -LiteralPath $invalidStateRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$duplicateRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-poweroff-terminal-duplicate-' + [Guid]::NewGuid().ToString('N'))
try {
    $script:resultsPath = Join-Path $duplicateRoot 'Results'
    $script:archivePath = Join-Path $duplicateRoot 'Archive'
    $queuePath = Join-Path $duplicateRoot 'Requests'
    foreach ($path in @($script:resultsPath, $script:archivePath, $queuePath)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    $duplicateRequestId = 'same-id-terminal'
    $duplicateResultRoot = Join-Path $script:resultsPath $duplicateRequestId
    New-Item -ItemType Directory -Force -Path $duplicateResultRoot | Out-Null
    $duplicateTerminalPath = Join-Path $duplicateResultRoot 'broker-result.json'
    [ordered]@{ RequestId = $duplicateRequestId; Winner = 'original' } | ConvertTo-Json | Set-Content -LiteralPath $duplicateTerminalPath -Encoding UTF8
    $duplicateTerminalHash = (Get-FileHash -LiteralPath $duplicateTerminalPath -Algorithm SHA256).Hash
    $queuedDuplicatePath = Join-Path $queuePath ($duplicateRequestId + '.json')
    [ordered]@{ RequestId = $duplicateRequestId; CreatedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $queuedDuplicatePath -Encoding UTF8
    Assert-True (Move-QueuedRequestWithTerminalResult -QueuedFile (Get-Item -LiteralPath $queuedDuplicatePath) -RequestId $duplicateRequestId -Reason 'test-terminal-duplicate') 'A same-ID queued duplicate was not recognized after terminal publication.'
    Assert-True (
        -not (Test-Path -LiteralPath $queuedDuplicatePath) -and
        @(Get-ChildItem -LiteralPath $script:archivePath -Filter ($duplicateRequestId + '-test-terminal-duplicate-*.json') -File).Count -eq 1 -and
        (Get-FileHash -LiteralPath $duplicateTerminalPath -Algorithm SHA256).Hash -eq $duplicateTerminalHash
    ) 'A same-ID queued duplicate was not quarantined without changing its terminal result.'
    $scenarios.Add('same-id-queued-duplicate-is-quarantined')
}
finally {
    Remove-Item -LiteralPath $duplicateRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$noReplayRequest = [pscustomobject]@{ ExpectGuestPowerOff = $true }
$applicationRunningState = [pscustomobject]@{
    ExpectGuestPowerOff = $true
    ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'
    GuestJobMayHaveLaunched = $true
    GuestApplicationEraRunningObservedUtc = '2026-08-31T00:00:01Z'
}
Assert-True ($null -ne (Get-InterruptedExpectedGuestPowerOffNoReplayState -Request $noReplayRequest -RequestState $applicationRunningState)) 'An interrupted expected-power-off application could be replayed after its durable Running confirmation.'
Assert-True ($null -eq (Get-InterruptedExpectedGuestPowerOffNoReplayState -Request ([pscustomobject]@{ expectGuestPowerOff = $true }) -RequestState $applicationRunningState)) 'A case-variant top-level flag enabled broker-restart no-replay semantics.'
Assert-True ($null -eq (Get-InterruptedExpectedGuestPowerOffNoReplayState -Request $noReplayRequest -RequestState ([pscustomobject]@{ ExpectGuestPowerOff = $true }))) 'A request without durable application-era Running evidence entered the post-launch no-replay path.'
Assert-True ($null -ne (Get-InterruptedExpectedGuestPowerOffNoReplayState -Request $noReplayRequest -RequestState ([pscustomobject]@{ ExpectGuestPowerOff = $true; ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'; GuestJobMayHaveLaunched = $true }))) 'An interrupted delivery with a durable may-have-launched marker remained replayable.'
Assert-True ($null -eq (Get-InterruptedExpectedGuestPowerOffNoReplayState -Request $noReplayRequest -RequestState ([pscustomobject]@{ ExpectGuestPowerOff = $true; ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'; GuestJobMayHaveLaunched = 'true' }))) 'A string may-have-launched marker enabled no-replay semantics.'
$scenarios.Add('broker-restart-never-replays-confirmed-poweroff-application')

$safePreDelivery = Get-InterruptedExpectedGuestPowerOffRecoveryClassification -Request $noReplayRequest -RequestState ([pscustomobject]@{ Status = 'Claimed' })
$invalidAmbiguity = Get-InterruptedExpectedGuestPowerOffRecoveryClassification -Request $noReplayRequest -RequestState ([pscustomobject]@{ ExpectGuestPowerOff = $true; ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'; GuestJobMayHaveLaunched = 'true' })
$invalidCaseVariant = Get-InterruptedExpectedGuestPowerOffRecoveryClassification -Request $noReplayRequest -RequestState ([pscustomobject]@{ ExpectGuestPowerOff = $true; ExpectedGuestPowerOffSubmissionStartedUtc = '2026-08-31T00:00:00Z'; guestJobMayHaveLaunched = $true })
$invalidOptInOnly = Get-InterruptedExpectedGuestPowerOffRecoveryClassification -Request $noReplayRequest -RequestState ([pscustomobject]@{ ExpectGuestPowerOff = $true })
Assert-True ([string]$safePreDelivery.Disposition -eq 'SafePreDelivery') 'A marker-free exact expected-power-off request was not classified as safely pre-delivery.'
Assert-True ([string]$invalidAmbiguity.Disposition -eq 'Invalid' -and [string]$invalidAmbiguity.Reason -like '*exact JSON Boolean*') 'Malformed durable ambiguity state was not classified fail-closed.'
Assert-True ([string]$invalidCaseVariant.Disposition -eq 'Invalid' -and [string]$invalidCaseVariant.Reason -like '*incorrect casing*') 'A case-variant ambiguity marker was treated as safe pre-delivery state.'
Assert-True ([string]$invalidOptInOnly.Disposition -eq 'Invalid' -and [string]$invalidOptInOnly.Reason -like '*incomplete*') 'An incomplete opt-in-only persisted state was treated as safe pre-delivery state.'
$scenarios.Add('broker-restart-classifies-malformed-poweroff-state-fail-closed')

$freshBootState = [pscustomobject]@{ GuestBootTimeUtc = '2026-08-31T00:05:00.0000000Z' }
Assert-True (Test-GuestSessionBootIdentity -GuestState $freshBootState -CurrentGuestBootTimeUtc '2026-08-31T00:05:00Z' -Required $true) 'Matching agent-state and current guest OS boot epochs were not accepted.'
Assert-True (-not (Test-GuestSessionBootIdentity -GuestState ([pscustomobject]@{ GuestBootTimeUtc = '2026-08-31T00:00:00Z' }) -CurrentGuestBootTimeUtc '2026-08-31T00:05:00Z' -Required $true)) 'A stale pre-shutdown agent-state boot epoch was accepted after recovery boot.'
Assert-True (-not (Test-GuestSessionBootIdentity -GuestState ([pscustomobject]@{ guestBootTimeUtc = '2026-08-31T00:05:00Z' }) -CurrentGuestBootTimeUtc '2026-08-31T00:05:00Z' -Required $true)) 'A case-variant guest boot identity field was accepted.'
$scenarios.Add('agent-state-must-match-current-guest-boot-epoch')

$brokerText = Get-Content -Raw -LiteralPath $HostBrokerPath
$recoveryStart = $brokerText.IndexOf("`$failureStage = 'RevokingNetworkBeforePowerOffRecovery'", [StringComparison]::Ordinal)
$recoveryEnd = $brokerText.IndexOf("`$failureStage = 'StagingGuestEvidence'", $recoveryStart + 1, [StringComparison]::Ordinal)
Assert-True ($recoveryStart -ge 0 -and $recoveryEnd -gt $recoveryStart) 'The bounded expected-power-off recovery region was not found.'
$recoveryText = $brokerText.Substring($recoveryStart, $recoveryEnd - $recoveryStart)
Assert-True (
    $recoveryText.IndexOf('Remove-RequestNetworkRuntime', [StringComparison]::Ordinal) -ge 0 -and
    $recoveryText.IndexOf('Remove-HostInputShareRuntime', [StringComparison]::Ordinal) -ge 0 -and
    $recoveryText.IndexOf('Get-VMNetworkAdapter', [StringComparison]::Ordinal) -ge 0 -and
    $recoveryText.IndexOf('Start-VM -Name $vmName', [StringComparison]::Ordinal) -gt $recoveryText.IndexOf('Get-VMNetworkAdapter', [StringComparison]::Ordinal)
) 'The recovery boot is not ordered after request-network, share, and final adapter revocation checks.'
Assert-True (
    -not $recoveryText.Contains('Copy-Item -LiteralPath $guestJobPath') -and
    -not $recoveryText.Contains('Move-Item -LiteralPath $guestTransferFile')
) 'The recovery path can resubmit the guest job and relaunch the application.'
$scenarios.Add('controlled-reboot-is-networkless-and-never-resubmits')

Assert-True (
    $recoveryText.Contains('-RequireCurrentGuestBootTime') -and
    $brokerText.Contains('CurrentGuestBootTimeUtc = $bootTime.ToUniversalTime().ToString') -and
    $recoveryText.Contains("while (`$true)") -and
    $recoveryText.Contains("if (`$recoveryPresence.Completed -and `$recoveryPresence.Result -and -not `$recoveryPresence.Processing)") -and
    -not $recoveryText.Contains("if (`$recoveryPresence.Inbox -or `$recoveryPresence.Processing)")
) 'Recovery can accept a stale pre-shutdown agent heartbeat or fail on transient post-boot Processing state.'
$scenarios.Add('recovery-requires-fresh-boot-and-polls-terminal-evidence')

Assert-True (
    $brokerText.Contains('ExpectGuestPowerOff must be omitted for legacy requests or set to exact Boolean true.') -and
    $brokerText.Contains('The guest job expectGuestPowerOff property is accepted only as exact Boolean true with top-level ExpectGuestPowerOff=true.') -and
    $brokerText.Contains('The guest expected-power-off property name must use exact case: expectGuestPowerOff.') -and
    $brokerText.Contains('$recoveryTimeoutType -notin $integralTimeoutTypes')
) 'Malformed or ambiguous expected-power-off protocol fields are not rejected at the broker boundary.'
$scenarios.Add('broker-rejects-ambiguous-or-nonintegral-opt-in-fields')

$observedOffStateIndex = $brokerText.IndexOf("-Status 'GuestPowerOffObserved'", [StringComparison]::Ordinal)
$liveEvidenceAfterOffIndex = $brokerText.IndexOf('Complete-HostLiveEvidenceFailure', $observedOffStateIndex, [StringComparison]::Ordinal)
Assert-True ($observedOffStateIndex -ge 0 -and $liveEvidenceAfterOffIndex -gt $observedOffStateIndex) 'Causal expected-power-off state is not persisted before advisory live-evidence work.'
Assert-True (
    $brokerText.Contains("FailureKind = if (`$causalPowerOffPersisted) { 'GuestPowerOffEvidenceRecoveryInterrupted' } elseif (`$applicationRunningPersisted) { 'ExpectedGuestPowerOffBrokerInterrupted' } else { 'ExpectedGuestPowerOffSubmissionInterrupted' }") -and
    $brokerText.Contains("FailureKind = 'ExpectedGuestPowerOffStateMissing'") -and
    $brokerText.Contains("FailureKind = 'ExpectedGuestPowerOffStateInvalid'") -and
    $brokerText.Contains('$interruptedTerminal.ContainsKey($requestId)') -and
    $brokerText.Contains('Publish-InterruptedRequestTerminalResult')
) 'Broker restart recovery can still requeue an ambiguous or confirmed expected-power-off application.'
$scenarios.Add('interrupted-broker-fails-poweroff-request-terminally')

Assert-True (
    $brokerText.Contains('$activeRequestIds.Contains($terminalQueuedId)') -and
    $brokerText.Contains("'-duplicate-active-'") -and
    $brokerText.Contains('Move-QueuedRequestWithTerminalResult')
) 'The single-VM queue can leave a same-ID active or terminal duplicate available to rewrite durable no-replay state.'
$scenarios.Add('single-broker-quarantines-same-id-duplicates')

foreach ($field in @(
    'GuestApplicationEraRunningObservedUtc',
    'GuestPowerOffObservedUtc',
    'GuestPowerOffBeforeCleanup',
    'BrokerCleanupStartedUtc',
    'GuestPowerOffEvidenceRecoveryMode',
    'GuestPowerOffEvidenceRecoveryBootedUtc',
    'ApplicationRelaunchedByHarnessAfterGuestPowerOff',
    'ExpectedGuestPowerOffContractSatisfied'
)) {
    Assert-True ($brokerText.Contains("`$brokerResultValue['$field']")) "Broker result does not serialize expected-power-off field '$field'."
}
Assert-True (
    $brokerText.Contains('assertResultFile must not collide with reserved guest protocol file') -and
    $brokerText.Contains('Recovered result.json did not prove a present marker predates the controlled recovery boot.') -and
    $brokerText.Contains("if (`$expectedGuestPowerOffContractSatisfied) { 'ControlledReboot' } else { `$null }")
) 'The broker does not fail closed on protocol-file collisions or pre-recovery-boot guest evidence.'
$scenarios.Add('broker-result-exposes-causal-and-recovery-proof')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
