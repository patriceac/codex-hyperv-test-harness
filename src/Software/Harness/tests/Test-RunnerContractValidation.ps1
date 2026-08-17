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
                throw "$Scenario did not reach the broker queue. Runner job state: $($runnerJob.State). Output: $jobOutput"
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $queuedFile) {
            throw "$Scenario did not reach the broker queue within 30 seconds."
        }
        Get-Content -Raw -LiteralPath $queuedFile.FullName | ConvertFrom-Json
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
    Assert-Rejected -Scenario 'paired assertion arguments' -ExpectedMessage 'must be specified together' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -AssertResultFile '{OUTDIR}\result.json' -AssertResultJsonPointer '/passed'
    }
    $scenarios.Add('paired-assertion-arguments')

    Assert-Rejected -Scenario 'typed expected JSON' -ExpectedMessage 'valid JSON value' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -AssertResultFile '{OUTDIR}\result.json' -AssertResultJsonPointer '/passed' -AssertResultEqualsJson 'not-json'
    }
    $scenarios.Add('typed-expected-json')

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

    Assert-Rejected -Scenario 'None rejects switch' -ExpectedMessage 'NetworkProfile None does not accept NetworkSwitchName' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkSwitchName 'switch-a'
    }
    $scenarios.Add('network-none-rejects-switch')

    Assert-Rejected -Scenario 'None rejects host-input acknowledgement' -ExpectedMessage 'NetworkProfile None does not accept AllowNetworkWithHostInputs' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -AllowNetworkWithHostInputs
    }
    $scenarios.Add('network-none-rejects-host-input-acknowledgement')

    Assert-Rejected -Scenario 'isolated network requires cohort' -ExpectedMessage 'NetworkProfile IsolatedTestNet requires NetworkCohort' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile IsolatedTestNet
    }
    $scenarios.Add('isolated-network-requires-cohort')

    Assert-Rejected -Scenario 'isolated network rejects switch' -ExpectedMessage 'NetworkProfile IsolatedTestNet does not accept NetworkSwitchName' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile IsolatedTestNet -NetworkCohort 'cohort-a' -NetworkSwitchName 'switch-a'
    }
    $scenarios.Add('isolated-network-rejects-switch')

    Assert-Rejected -Scenario 'InternetOnly rejects cohort' -ExpectedMessage 'NetworkProfile InternetOnly does not accept NetworkCohort' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile InternetOnly -NetworkCohort 'cohort-a'
    }
    $scenarios.Add('internet-only-rejects-cohort')

    Assert-Rejected -Scenario 'InternetOnly rejects switch' -ExpectedMessage 'broker policy selects pinned infrastructure' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile InternetOnly -NetworkSwitchName 'switch-a'
    }
    $scenarios.Add('internet-only-rejects-switch')

    Assert-Rejected -Scenario 'TrustedLan requires switch' -ExpectedMessage 'NetworkProfile TrustedLan requires NetworkSwitchName' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile TrustedLan
    }
    $scenarios.Add('trusted-lan-requires-switch')

    Assert-Rejected -Scenario 'TrustedLan rejects cohort' -ExpectedMessage 'NetworkProfile TrustedLan does not accept NetworkCohort' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile TrustedLan -NetworkSwitchName 'switch-a' -NetworkCohort 'cohort-a'
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

    Assert-Rejected -Scenario 'blank switch name' -ExpectedMessage 'NetworkSwitchName must be nonblank' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile TrustedLan -NetworkSwitchName '   '
    }
    $scenarios.Add('network-switch-nonblank')

    Assert-Rejected -Scenario 'control character in switch name' -ExpectedMessage 'no control characters' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile TrustedLan -NetworkSwitchName ("switch`nname")
    }
    $scenarios.Add('network-switch-no-control-characters')

    Assert-Rejected -Scenario 'long switch name' -ExpectedMessage 'at most 128 characters' -Operation {
        & $RunnerPath -ArtifactPath $artifact -BrokerRoot $root -NetworkProfile TrustedLan -NetworkSwitchName ('a' * 129)
    }
    $scenarios.Add('network-switch-bounded')

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

    $defaultRequest = Get-QueuedRequest -Scenario 'default network contract' -InvocationParameters $baseInvocation
    Assert-Equal -Scenario 'default operation compatibility' -Actual ([string]$defaultRequest.Operation) -Expected 'RunGuestJob'
    Assert-Equal -Scenario 'default network profile' -Actual ([string]$defaultRequest.Network.Profile) -Expected 'None'
    if ($null -ne $defaultRequest.Network.Cohort -or $null -ne $defaultRequest.Network.SwitchName -or [bool]$defaultRequest.Network.AllowHostInputs) {
        throw 'The default network contract must serialize null Cohort, null SwitchName, and AllowHostInputs=false.'
    }
    $scenarios.Add('network-default-serialized-none')

    $isolatedInvocation = $baseInvocation.Clone()
    $isolatedInvocation.NetworkProfile = 'IsolatedTestNet'
    $isolatedInvocation.NetworkCohort = '  suite.alpha_1  '
    $isolatedRequest = Get-QueuedRequest -Scenario 'isolated network contract' -InvocationParameters $isolatedInvocation
    Assert-Equal -Scenario 'network operation versioning' -Actual ([string]$isolatedRequest.Operation) -Expected 'RunGuestJobNetworkV1'
    Assert-Equal -Scenario 'isolated profile serialization' -Actual ([string]$isolatedRequest.Network.Profile) -Expected 'IsolatedTestNet'
    Assert-Equal -Scenario 'isolated cohort normalization' -Actual ([string]$isolatedRequest.Network.Cohort) -Expected 'suite.alpha_1'
    if ($null -ne $isolatedRequest.Network.SwitchName -or [bool]$isolatedRequest.Network.AllowHostInputs) {
        throw 'The isolated network contract serialized unexpected switch or host-input acknowledgement fields.'
    }
    $scenarios.Add('isolated-network-valid-shape')

    $internetInvocation = $baseInvocation.Clone()
    $internetInvocation.NetworkProfile = 'InternetOnly'
    $internetRequest = Get-QueuedRequest -Scenario 'InternetOnly network contract' -InvocationParameters $internetInvocation
    Assert-Equal -Scenario 'InternetOnly profile serialization' -Actual ([string]$internetRequest.Network.Profile) -Expected 'InternetOnly'
    if ($null -ne $internetRequest.Network.Cohort -or $null -ne $internetRequest.Network.SwitchName -or [bool]$internetRequest.Network.AllowHostInputs) {
        throw 'The InternetOnly network contract serialized unexpected optional fields.'
    }
    $scenarios.Add('internet-only-valid-shape')

    $trustedInvocation = $baseInvocation.Clone()
    $trustedInvocation.NetworkProfile = 'TrustedLan'
    $trustedInvocation.NetworkSwitchName = '  Approved External Switch  '
    $trustedRequest = Get-QueuedRequest -Scenario 'TrustedLan network contract' -InvocationParameters $trustedInvocation
    Assert-Equal -Scenario 'TrustedLan profile serialization' -Actual ([string]$trustedRequest.Network.Profile) -Expected 'TrustedLan'
    Assert-Equal -Scenario 'TrustedLan switch normalization' -Actual ([string]$trustedRequest.Network.SwitchName) -Expected 'Approved External Switch'
    if ($null -ne $trustedRequest.Network.Cohort -or [bool]$trustedRequest.Network.AllowHostInputs) {
        throw 'The TrustedLan network contract serialized unexpected cohort or host-input acknowledgement fields.'
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
