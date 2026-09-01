[CmdletBinding()]
param(
    [string] $RunnerPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RunnerPath)) {
    # Resolve this after parameter binding. Windows PowerShell 5.1 does not
    # reliably populate $PSScriptRoot while evaluating a default parameter.
    $RunnerPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $Operation,
        [Parameter(Mandatory = $true)] [string] $ExpectedMessage,
        [Parameter(Mandatory = $true)] [string] $Scenario
    )
    $message = $null
    try { & $Operation }
    catch { $message = $_.Exception.Message }
    if ($message -notlike ('*' + $ExpectedMessage + '*')) {
        throw "$Scenario was not rejected as expected. Actual error: $message"
    }
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [Parameter(Mandatory = $true)] [string] $Scenario
    )
    if ($Actual -ne $Expected) {
        throw "$Scenario failed. Expected '$Expected'; actual '$Actual'."
    }
}

function Import-RunnerFunction {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "$Path has a parse error: $($parseErrors[0].Message)" }
    $definition = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
}

function Get-QueuedRequest {
    param(
        [Parameter(Mandatory = $true)] [hashtable] $InvocationParameters,
        [Parameter(Mandatory = $true)] [string] $Scenario
    )

    $runnerJob = Start-Job -ScriptBlock {
        param($ScriptPath, $Parameters)
        & $ScriptPath @Parameters
    } -ArgumentList $RunnerPath, $InvocationParameters
    $queuedFile = $null
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline) {
            $queuedFile = Get-ChildItem -LiteralPath (Join-Path $root 'Requests') -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($queuedFile) { break }
            if ($runnerJob.State -in @('Completed', 'Failed', 'Stopped')) {
                $jobOutput = @(Receive-Job -Job $runnerJob -Keep -ErrorAction SilentlyContinue) -join [Environment]::NewLine
                $jobErrors = @($runnerJob.ChildJobs[0].Error | ForEach-Object { $_.ToString() }) -join ' | '
                $jobReason = if ($runnerJob.ChildJobs[0].JobStateInfo.Reason) { $runnerJob.ChildJobs[0].JobStateInfo.Reason.ToString() } else { $null }
                throw "$Scenario did not reach the broker queue. Runner job state: $($runnerJob.State). Reason: $jobReason Errors: $jobErrors Output: $jobOutput"
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $queuedFile) {
            throw "$Scenario did not reach the broker queue within 30 seconds."
        }
        Get-Content -Raw -LiteralPath $queuedFile.FullName -Encoding UTF8 | ConvertFrom-Json
    }
    finally {
        if ($runnerJob.State -notin @('Completed', 'Failed', 'Stopped')) {
            Stop-Job -Job $runnerJob -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $runnerJob -ErrorAction SilentlyContinue
        if ($queuedFile) {
            $queuedRequestId = [IO.Path]::GetFileNameWithoutExtension($queuedFile.Name)
            Remove-Item -LiteralPath $queuedFile.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path (Join-Path $root 'Results') $queuedRequestId) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-runner-contract-' + [Guid]::NewGuid().ToString('N'))
foreach ($relative in @('Requests', 'Processing', 'Results', 'PayloadManifests', 'PayloadCache', 'Cancellations', 'Cancelled')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $relative) | Out-Null
}
$artifact = Join-Path $root 'never-run.exe'
[IO.File]::WriteAllBytes($artifact, [byte[]](0, 1, 2, 3))
$hostInput = Join-Path $root 'host-input'
New-Item -ItemType Directory -Force -Path $hostInput | Out-Null
[IO.File]::WriteAllText((Join-Path $hostInput 'fixture.txt'), 'fixture')
$scenarios = New-Object Collections.Generic.List[string]
try {
    Import-RunnerFunction -Path $RunnerPath -Name 'ConvertTo-UtcRequestStateTimestamp'
    $typedDeadline = [DateTime]::Parse(
        '2026-08-31T15:13:49.6772745Z',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    $typedShutdown = [DateTime]::Parse(
        '2026-08-31T15:10:49.6772745Z',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    $parsedDeadline = ConvertTo-UtcRequestStateTimestamp -Value $typedDeadline -PropertyName 'PowerOffRecoveryDeadlineUtc'
    $parsedShutdown = ConvertTo-UtcRequestStateTimestamp -Value $typedShutdown -PropertyName 'GuestPowerOffObservedUtc'
    $justAfterPowerOff = [DateTime]::Parse(
        '2026-08-31T15:10:50.6001326Z',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    if ($parsedDeadline.Kind -ne [DateTimeKind]::Utc -or
        $parsedShutdown.Kind -ne [DateTimeKind]::Utc -or
        $parsedDeadline.Ticks -ne $typedDeadline.Ticks -or
        $justAfterPowerOff -ge $parsedDeadline) {
        throw 'A UTC DateTime deserialized from request state was reinterpreted through the local timezone.'
    }
    $scenarios.Add('typed-request-state-deadline-preserves-utc')

    Assert-Rejected -Scenario 'paired assertion arguments' -ExpectedMessage 'must be specified together' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -AssertResultFile '{OUTDIR}\result.json' -AssertResultJsonPointer '/passed'
    }
    $scenarios.Add('paired-assertion-arguments')

    Assert-Rejected -Scenario 'typed expected JSON' -ExpectedMessage 'valid JSON value' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -AssertResultFile '{OUTDIR}\result.json' -AssertResultJsonPointer '/passed' -AssertResultEqualsJson 'not-json'
    }
    $scenarios.Add('typed-expected-json')

    Assert-Rejected -Scenario 'expected power-off marker requirement' -ExpectedMessage 'AssertResultFile is required when ExpectGuestPowerOff is specified' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ExpectGuestPowerOff
    }
    $scenarios.Add('expected-power-off-requires-result-marker')

    foreach ($reservedMarker in @('result.json', 'agent-error.json', 'lease.json')) {
        Assert-Rejected -Scenario "reserved expected power-off marker $reservedMarker" -ExpectedMessage 'must not use reserved guest protocol filename' -Operation {
            & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ExpectGuestPowerOff -AssertResultFile ("{OUTDIR}\$reservedMarker")
        }
    }
    $scenarios.Add('expected-power-off-marker-does-not-collide-with-protocol')

    Assert-Rejected -Scenario 'power-off recovery timeout requires opt-in' -ExpectedMessage 'may be specified only with ExpectGuestPowerOff' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -GuestPowerOffRecoveryTimeoutSeconds 60
    }
    $scenarios.Add('power-off-recovery-timeout-requires-opt-in')

    Assert-Rejected -Scenario 'power-off recovery timeout lower bound' -ExpectedMessage 'minimum allowed range of 30' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ExpectGuestPowerOff -AssertResultFile '{OUTDIR}\result.json' -GuestPowerOffRecoveryTimeoutSeconds 29
    }
    Assert-Rejected -Scenario 'power-off recovery timeout upper bound' -ExpectedMessage 'maximum allowed range of 600' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ExpectGuestPowerOff -AssertResultFile '{OUTDIR}\result.json' -GuestPowerOffRecoveryTimeoutSeconds 601
    }
    $scenarios.Add('power-off-recovery-timeout-bounded')

    Assert-Rejected -Scenario 'wait result token scope' -ExpectedMessage 'Allowed tokens: {OUTDIR}' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ActionsJson '[{"type":"wait_result_file","path":"{PAYLOAD}\\result.json","timeoutMs":1000}]'
    }
    $scenarios.Add('wait-result-file-outdir-only')

    Assert-Rejected -Scenario 'wait result path traversal' -ExpectedMessage 'escapes the request output directory' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ActionsJson '[{"type":"wait_result_file","path":"{OUTDIR}\\..\\escape.json","timeoutMs":1000}]'
    }
    $scenarios.Add('wait-result-file-no-traversal')

    Assert-Rejected -Scenario 'process wait bound' -ExpectedMessage 'timeoutMs must be between 100 and 7200000' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ActionsJson '[{"type":"wait_process_exit","timeoutMs":7200001}]'
    }
    $scenarios.Add('process-wait-bounded')

    Assert-Rejected -Scenario 'key chord uppercase vocabulary' -ExpectedMessage "uppercase '+'-separated" -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ActionsJson '[{"type":"send_keys","keys":"Win+Left"}]'
    }
    $scenarios.Add('key-chord-uppercase-vocabulary')

    Assert-Rejected -Scenario 'key chord narrow shape' -ExpectedMessage 'unsupported properties: command' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ActionsJson '[{"type":"send_keys","keys":"WIN+LEFT","command":"ignored"}]'
    }
    $scenarios.Add('key-chord-narrow-shape')

    Assert-Rejected -Scenario 'key chord semantic shape' -ExpectedMessage 'one or more modifiers followed by exactly one non-modifier' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ActionsJson '[{"type":"send_keys","keys":"A+B"}]'
    }
    $scenarios.Add('key-chord-semantic-shape')

    Assert-Rejected -Scenario 'key chord hold bound' -ExpectedMessage 'holdMs must be between 10 and 2000' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ActionsJson '[{"type":"send_keys","keys":"ENTER","holdMs":2001}]'
    }
    $scenarios.Add('key-chord-hold-bounded')

    Assert-Rejected -Scenario 'undeclared host input token' -ExpectedMessage 'unresolved reserved token' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -Arguments '--input "{HOSTINPUT:media}"'
    }
    $scenarios.Add('host-input-token-must-be-declared')

    Assert-Rejected -Scenario 'unknown host input alias' -ExpectedMessage 'unresolved reserved token' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ReadOnlyHostInput @{ Name = 'media'; Path = $hostInput } -Arguments '--input "{HOSTINPUT:other}"'
    }
    $scenarios.Add('host-input-token-alias-must-match')

    Assert-Rejected -Scenario 'host input token prefix case' -ExpectedMessage 'unresolved reserved token' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ReadOnlyHostInput @{ Name = 'media'; Path = $hostInput } -Arguments '--input "{hostinput:media}"'
    }
    $scenarios.Add('host-input-prefix-is-reserved-uppercase')

    Assert-Rejected -Scenario 'relative host input path' -ExpectedMessage 'absolute local host path' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ReadOnlyHostInput @{ Name = 'media'; Path = '.\relative' }
    }
    $scenarios.Add('host-input-path-must-be-absolute')

    Assert-Rejected -Scenario 'duplicate host input names' -ExpectedMessage 'Duplicate ReadOnlyHostInput Name' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -ReadOnlyHostInput @(@{ Name = 'media'; Path = $hostInput }, @{ Name = 'MEDIA'; Path = $hostInput })
    }
    $scenarios.Add('host-input-names-case-insensitive-unique')

    Assert-Rejected -Scenario 'None rejects cohort' -ExpectedMessage 'NetworkProfile None does not accept NetworkCohort' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkCohort 'cohort-a'
    }
    $scenarios.Add('network-none-rejects-cohort')

    Assert-Rejected -Scenario 'caller cannot select any network switch' -ExpectedMessage 'parameter cannot be found' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkSwitchName 'switch-a'
    }
    $scenarios.Add('network-switch-selector-not-exposed')

    Assert-Rejected -Scenario 'None rejects host-input acknowledgement' -ExpectedMessage 'NetworkProfile None does not accept AllowNetworkWithHostInputs' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -AllowNetworkWithHostInputs
    }
    $scenarios.Add('network-none-rejects-host-input-acknowledgement')

    Assert-Rejected -Scenario 'isolated network requires cohort' -ExpectedMessage 'NetworkProfile IsolatedTestNet requires NetworkCohort' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile IsolatedTestNet
    }
    $scenarios.Add('isolated-network-requires-cohort')

    Assert-Rejected -Scenario 'InternetOnly rejects cohort' -ExpectedMessage 'NetworkProfile InternetOnly does not accept NetworkCohort' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile InternetOnly -NetworkCohort 'cohort-a'
    }
    $scenarios.Add('internet-only-rejects-cohort')

    Assert-Rejected -Scenario 'TrustedLan rejects cohort' -ExpectedMessage 'NetworkProfile TrustedLan does not accept NetworkCohort' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile TrustedLan -NetworkCohort 'cohort-a'
    }
    $scenarios.Add('trusted-lan-rejects-cohort')

    Assert-Rejected -Scenario 'blank cohort' -ExpectedMessage 'NetworkCohort must be nonblank' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile IsolatedTestNet -NetworkCohort '   '
    }
    $scenarios.Add('network-cohort-nonblank')

    Assert-Rejected -Scenario 'unsafe cohort' -ExpectedMessage 'at most 64 letters' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile IsolatedTestNet -NetworkCohort 'cohort/a'
    }
    $scenarios.Add('network-cohort-safe-characters')

    Assert-Rejected -Scenario 'long cohort' -ExpectedMessage 'at most 64 letters' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile IsolatedTestNet -NetworkCohort ('a' * 65)
    }
    $scenarios.Add('network-cohort-bounded')

    Assert-Rejected -Scenario 'networked host input without acknowledgement' -ExpectedMessage 'AllowNetworkWithHostInputs is required' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile InternetOnly -ReadOnlyHostInput @{ Name = 'media'; Path = $hostInput }
    }
    $scenarios.Add('network-host-input-requires-acknowledgement')

    Assert-Rejected -Scenario 'networked explicit share' -ExpectedMessage 'explicitly requests Share' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile InternetOnly -AllowNetworkWithHostInputs -ReadOnlyHostInput @{ Name = 'media'; Path = $hostInput; Mode = 'Share' }
    }
    $scenarios.Add('network-host-input-rejects-share')

    $baseInvocation = @{
        ArtifactPath = $artifact
        BrokerRoot = $root
        ActionsJson = '[{"type":"wait","ms":0}]'
        QueueTimeoutSeconds = 300
    }

    $legacyDefaultInvocation = @{
        ArtifactPath = $artifact
        BrokerRoot = $root
        QueueTimeoutSeconds = 300
    }
    $legacyDefaultRequest = Get-QueuedRequest -Scenario 'legacy default request shape' -InvocationParameters $legacyDefaultInvocation
    if ($legacyDefaultRequest.PSObject.Properties.Name -contains 'ExpectGuestPowerOff' -or
        $legacyDefaultRequest.PSObject.Properties.Name -contains 'GuestPowerOffRecoveryTimeoutSeconds' -or
        $legacyDefaultRequest.Job.PSObject.Properties.Name -contains 'expectGuestPowerOff') {
        throw 'The legacy default request serialized expected-power-off properties without opt-in.'
    }
    $legacyDefaultActionsJson = @($legacyDefaultRequest.Job.actions) | ConvertTo-Json -Compress
    $expectedLegacyDefaultActionsJson = '[{"type":"wait_window","timeoutMs":30000},{"type":"screenshot","name":"launched.png"},{"type":"wait","ms":2000},{"type":"screenshot","name":"after-wait.png"}]'
    Assert-Equal -Scenario 'legacy default action compatibility' -Actual $legacyDefaultActionsJson -Expected $expectedLegacyDefaultActionsJson
    $scenarios.Add('legacy-default-shape-omits-power-off-contract')

    $powerOffInvocation = @{
        ArtifactPath = $artifact
        BrokerRoot = $root
        AssertResultFile = '{OUTDIR}\shutdown-marker.json'
        AssertResultJsonPointer = '/passed'
        AssertResultEqualsJson = 'true'
        ExpectGuestPowerOff = $true
        GuestPowerOffRecoveryTimeoutSeconds = 240
        ExecutionTimeoutSeconds = 45
        QueueTimeoutSeconds = 300
    }
    $powerOffRequest = Get-QueuedRequest -Scenario 'expected guest power-off contract' -InvocationParameters $powerOffInvocation
    if ($powerOffRequest.ExpectGuestPowerOff -isnot [bool] -or -not $powerOffRequest.ExpectGuestPowerOff -or
        $powerOffRequest.Job.expectGuestPowerOff -isnot [bool] -or -not $powerOffRequest.Job.expectGuestPowerOff) {
        throw 'Expected guest power-off flags were not serialized as exact Boolean true values.'
    }
    Assert-Equal -Scenario 'power-off recovery timeout serialization' -Actual ([int]$powerOffRequest.GuestPowerOffRecoveryTimeoutSeconds) -Expected 240
    Assert-Equal -Scenario 'power-off marker default action count' -Actual (@($powerOffRequest.Job.actions).Count) -Expected 1
    Assert-Equal -Scenario 'power-off marker default action type' -Actual ([string]$powerOffRequest.Job.actions[0].type) -Expected 'wait_result_file'
    Assert-Equal -Scenario 'power-off marker default action path' -Actual ([string]$powerOffRequest.Job.actions[0].path) -Expected '{OUTDIR}\shutdown-marker.json'
    Assert-Equal -Scenario 'power-off marker default action timeout' -Actual ([int64]$powerOffRequest.Job.actions[0].timeoutMs) -Expected 45000
    $scenarios.Add('expected-power-off-shape-and-marker-default')

    $runnerText = Get-Content -Raw -LiteralPath $RunnerPath
    if (-not $runnerText.Contains('Broker result ExpectGuestPowerOff is not exact Boolean true.') -or
        -not $runnerText.Contains('Broker result GuestPowerOffRecoveryTimeoutSeconds does not exactly match the requested recovery timeout.') -or
        -not $runnerText.Contains('ResultFileEvidence does not prove that a present assertion marker predates the controlled recovery boot.') -or
        -not $runnerText.Contains("ConvertTo-UtcRequestStateTimestamp -Value `$publishedRecoveryDeadline -PropertyName 'PowerOffRecoveryDeadlineUtc'") -or
        -not $runnerText.Contains('if ($baseHarnessSucceeded -and $ExpectGuestPowerOff -and -not $expectedGuestPowerOffContractProven)')) {
        throw 'The runner can claim or misclassify the expected-power-off contract when opt-in metadata or pre-recovery marker proof is invalid.'
    }
    $scenarios.Add('expected-power-off-final-proof-binds-request-metadata')

    $powerOffExplicitActionsInvocation = $powerOffInvocation.Clone()
    $powerOffExplicitActionsInvocation.ActionsJson = '[{"type":"screenshot","name":"mandatory.png"}]'
    $powerOffExplicitActionsRequest = Get-QueuedRequest -Scenario 'expected power-off explicit screenshot' -InvocationParameters $powerOffExplicitActionsInvocation
    Assert-Equal -Scenario 'explicit screenshot remains mandatory' -Actual ([string]$powerOffExplicitActionsRequest.Job.actions[0].type) -Expected 'screenshot'
    Assert-Equal -Scenario 'explicit screenshot name remains unchanged' -Actual ([string]$powerOffExplicitActionsRequest.Job.actions[0].name) -Expected 'mandatory.png'
    $scenarios.Add('expected-power-off-keeps-explicit-actions')

    $defaultRequest = Get-QueuedRequest -Scenario 'default network contract' -InvocationParameters $baseInvocation
    Assert-Equal -Scenario 'default operation compatibility' -Actual ([string]$defaultRequest.Operation) -Expected 'RunGuestJob'
    Assert-Equal -Scenario 'default network profile' -Actual ([string]$defaultRequest.Network.Profile) -Expected 'None'
    if ($null -ne $defaultRequest.Network.Cohort -or [bool]$defaultRequest.Network.AllowHostInputs -or $defaultRequest.Network.PSObject.Properties.Name -contains 'SwitchName') {
        throw 'The default network contract must serialize null Cohort and AllowHostInputs=false without a switch selector.'
    }
    $scenarios.Add('network-default-serialized-none')

    $keyboardInvocation = $baseInvocation.Clone()
    $keyboardInvocation.ActionsJson = '[{"type":"send_keys","keys":"WIN+LEFT","holdMs":75}]'
    $keyboardRequest = Get-QueuedRequest -Scenario 'keyboard action contract' -InvocationParameters $keyboardInvocation
    Assert-Equal -Scenario 'keyboard action type' -Actual ([string]$keyboardRequest.Job.actions[0].type) -Expected 'send_keys'
    Assert-Equal -Scenario 'keyboard action chord' -Actual ([string]$keyboardRequest.Job.actions[0].keys) -Expected 'WIN+LEFT'
    Assert-Equal -Scenario 'keyboard action hold' -Actual ([int]$keyboardRequest.Job.actions[0].holdMs) -Expected 75
    $scenarios.Add('key-chord-valid-shape-serialized')

    $isolatedInvocation = $baseInvocation.Clone()
    $isolatedInvocation.NetworkProfile = 'IsolatedTestNet'
    $isolatedInvocation.NetworkCohort = '  suite.alpha_1  '
    $isolatedRequest = Get-QueuedRequest -Scenario 'isolated network contract' -InvocationParameters $isolatedInvocation
    Assert-Equal -Scenario 'network operation versioning' -Actual ([string]$isolatedRequest.Operation) -Expected 'RunGuestJobNetworkV1'
    Assert-Equal -Scenario 'isolated profile serialization' -Actual ([string]$isolatedRequest.Network.Profile) -Expected 'IsolatedTestNet'
    Assert-Equal -Scenario 'isolated cohort normalization' -Actual ([string]$isolatedRequest.Network.Cohort) -Expected 'suite.alpha_1'
    if ([bool]$isolatedRequest.Network.AllowHostInputs -or $isolatedRequest.Network.PSObject.Properties.Name -contains 'SwitchName') {
        throw 'The isolated network contract serialized a switch selector or unexpected host-input acknowledgement.'
    }
    $scenarios.Add('isolated-network-valid-shape')

    $internetInvocation = $baseInvocation.Clone()
    $internetInvocation.NetworkProfile = 'InternetOnly'
    $internetRequest = Get-QueuedRequest -Scenario 'InternetOnly network contract' -InvocationParameters $internetInvocation
    Assert-Equal -Scenario 'InternetOnly profile serialization' -Actual ([string]$internetRequest.Network.Profile) -Expected 'InternetOnly'
    if ($null -ne $internetRequest.Network.Cohort -or [bool]$internetRequest.Network.AllowHostInputs -or $internetRequest.Network.PSObject.Properties.Name -contains 'SwitchName') {
        throw 'The InternetOnly network contract serialized unexpected optional fields.'
    }
    $scenarios.Add('internet-only-valid-shape')

    $trustedInvocation = $baseInvocation.Clone()
    $trustedInvocation.NetworkProfile = 'TrustedLan'
    $trustedRequest = Get-QueuedRequest -Scenario 'TrustedLan network contract' -InvocationParameters $trustedInvocation
    Assert-Equal -Scenario 'TrustedLan profile serialization' -Actual ([string]$trustedRequest.Network.Profile) -Expected 'TrustedLan'
    if ($null -ne $trustedRequest.Network.Cohort -or [bool]$trustedRequest.Network.AllowHostInputs -or $trustedRequest.Network.PSObject.Properties.Name -contains 'SwitchName') {
        throw 'The TrustedLan network contract serialized a caller-controlled selector or unexpected optional field.'
    }
    $scenarios.Add('trusted-lan-valid-shape')

    $networkedInputInvocation = $baseInvocation.Clone()
    $networkedInputInvocation.NetworkProfile = 'InternetOnly'
    $networkedInputInvocation.AllowNetworkWithHostInputs = $true
    $networkedInputInvocation.ReadOnlyHostInput = @(@{ Name = 'media'; Path = $hostInput; Mode = 'Auto' })
    $networkedInputRequest = Get-QueuedRequest -Scenario 'networked Auto host input' -InvocationParameters $networkedInputInvocation
    Assert-Equal -Scenario 'host-input acknowledgement serialization' -Actual ([bool]$networkedInputRequest.Network.AllowHostInputs) -Expected $true
    Assert-Equal -Scenario 'networked Auto requested mode retention' -Actual ([string]$networkedInputRequest.HostInputs[0].RequestedMode) -Expected 'Auto'
    Assert-Equal -Scenario 'networked Auto forced transport' -Actual ([string]$networkedInputRequest.HostInputs[0].SelectedTransport) -Expected 'Vhdx'
    if ([string]$networkedInputRequest.HostInputs[0].SelectionReason -notlike '*forced to immutable VHDX*') {
        throw 'Networked Auto host input did not explain the forced immutable VHDX transport.'
    }
    $scenarios.Add('network-host-input-auto-forced-vhdx')

    if (@(Get-ChildItem -LiteralPath (Join-Path $root 'Requests') -File).Count -ne 0) {
        throw 'Rejected contracts unexpectedly reached the broker queue.'
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
