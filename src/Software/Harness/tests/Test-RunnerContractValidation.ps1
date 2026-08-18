[CmdletBinding()]
param(
    [string] $RunnerPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill\scripts\Invoke-HyperVExecutableTest.ps1')
)

$ErrorActionPreference = 'Stop'

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
