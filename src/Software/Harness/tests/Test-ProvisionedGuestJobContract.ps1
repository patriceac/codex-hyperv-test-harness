[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = Split-Path -Parent $PSScriptRoot
$runnerPath = Join-Path (Split-Path -Parent $sourceRoot) 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
. (Join-Path $sourceRoot 'RequestNetwork.ps1')
. (Join-Path $sourceRoot 'RemoteDebuggerProvisioning.ps1')
$checks = New-Object Collections.Generic.List[string]
function Assert-Rejected {
    param([string] $Name, [scriptblock] $Action, [string] $Message)
    $errorMessage = $null
    try { $null = & $Action } catch { $errorMessage = $_.Exception.Message }
    if (-not $errorMessage -or ($Message -and $errorMessage -notlike ('*' + $Message + '*'))) {
        throw "$Name failed to reject as expected: $errorMessage"
    }
    $checks.Add($Name)
}
function New-ProvisionRequest {
    [pscustomobject]@{
        RequestId = 'executable-test-contract-01'
        Operation = 'RunGuestJobProvisionedV1'
        ResetToBaseline = $true
        StopAfter = $true
        RemoteDebuggerProvisionV1 = [pscustomobject]@{ FixtureRelativePath = 'release\RemoteDebugger.exe'; ExpectedSha256 = ('A' * 64) }
        HostInputs = @()
        Job = [pscustomobject]@{}
        Network = [pscustomobject]@{ Profile = 'None'; Cohort = $null; AllowHostInputs = $false }
    }
}
$config = [pscustomobject]@{
    BrokerInstanceId = 'RemoteDebugger-Acceptance'
    RequestNetworkPolicy = Get-RequestNetworkDefaultPolicy
    RemoteDebuggerProvisionV1 = [pscustomobject]@{
        FormatVersion = 1; Enabled = $true; PublisherThumbprint = ('B' * 64); ApprovedExecutableSha256 = @(('A' * 64))
    }
}
foreach ($profile in @('None', 'IsolatedTestNet')) {
    $request = New-ProvisionRequest
    $request.Network.Profile = $profile
    if ($profile -eq 'IsolatedTestNet') { $request.Network.Cohort = 'dedicated-contract' }
    $resolved = Resolve-RequestNetworkProfile -Request $request -Config $config
    if ($resolved.EffectiveProfile -ne $profile) { throw "Provisioned $profile did not resolve correctly." }
    $checks.Add("approved-profile-$profile")
}
foreach ($operation in @('RunGuestJob', 'RunGuestJobNetworkV1')) {
    $request = New-ProvisionRequest
    $request.Operation = $operation
    Assert-Rejected "legacy-operation-$operation-cannot-provision" { Resolve-RequestNetworkProfile -Request $request -Config $config } 'versioned'
}
$request = New-ProvisionRequest
$request.PSObject.Properties.Remove('RemoteDebuggerProvisionV1')
Assert-Rejected 'provision-operation-requires-profile' { Resolve-RequestNetworkProfile -Request $request -Config $config } 'requires RemoteDebugger'
$request = New-ProvisionRequest
Assert-Rejected 'shared-broker-default-disabled' { Resolve-RequestNetworkProfile -Request $request -Config ([pscustomobject]@{RequestNetworkPolicy = Get-RequestNetworkDefaultPolicy}) } 'disabled'
foreach ($profile in @('InternetOnly', 'TrustedLan')) {
    $request = New-ProvisionRequest
    $request.Network.Profile = $profile
    Assert-Rejected "external-network-$profile-denied" { Resolve-RequestNetworkProfile -Request $request -Config $config } 'only None or IsolatedTestNet'
}
$request = New-ProvisionRequest
$request.HostInputs = @([pscustomobject]@{ Name = 'data' })
Assert-Rejected 'host-inputs-denied' { Resolve-RequestNetworkProfile -Request $request -Config $config } 'host inputs'
$request = New-ProvisionRequest
$request.Job | Add-Member -NotePropertyName expectGuestPowerOff -NotePropertyValue $true
Assert-Rejected 'expected-poweroff-denied' { Resolve-RequestNetworkProfile -Request $request -Config $config } 'power-off'
$request = New-ProvisionRequest
$request.RemoteDebuggerProvisionV1.ExpectedSha256 = ('C' * 64)
Assert-Rejected 'hash-allowlist-enforced-before-allocation' { Resolve-RequestNetworkProfile -Request $request -Config $config } 'allowlist'
$request = New-ProvisionRequest
$request.RemoteDebuggerProvisionV1 | Add-Member -NotePropertyName Arguments -NotePropertyValue 'arbitrary'
Assert-Rejected 'no-arbitrary-provision-arguments' { Resolve-RequestNetworkProfile -Request $request -Config $config } 'invalid property set'
foreach ($flag in @('ResetToBaseline', 'StopAfter')) {
    $request = New-ProvisionRequest
    $request.$flag = $false
    Assert-Rejected "disposable-lifetime-required-$flag" { Resolve-RequestNetworkProfile -Request $request -Config $config } 'exact Boolean'
}

# Import only the runner's pure read-only fixture resolver, never run a broker or executable.
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw $parseErrors[0].Message }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-RemoteDebuggerClientFixture' }, $true)
if (-not $definition) { throw 'Missing client fixture validator.' }
. ([scriptblock]::Create($definition.Extent.Text))
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempBase ('codex-provision-contract-' + [Guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $testRoot 'release')
    $fixturePath = Join-Path $testRoot 'release\RemoteDebugger.exe'
    [IO.File]::WriteAllText($fixturePath, 'Inert contract fixture. This file is never executed.')
    $hash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
    $artifact = Get-Item -LiteralPath $testRoot
    $resolved = Resolve-RemoteDebuggerClientFixture -Artifact $artifact -RelativePath 'release/RemoteDebugger.exe' -ExpectedSha256 $hash.ToLowerInvariant()
    if ($resolved.ExpectedSha256 -cne $hash -or $resolved.FixtureRelativePath -cne 'release\RemoteDebugger.exe') { throw 'Client fixture normalization failed.' }
    $checks.Add('client-exact-file-hash-normalized')
    Assert-Rejected 'client-drifted-binary-denied' { Resolve-RemoteDebuggerClientFixture -Artifact $artifact -RelativePath 'release\RemoteDebugger.exe' -ExpectedSha256 ('0' * 64) } 'differs'
    foreach ($path in @('..\RemoteDebugger.exe', 'release\..\RemoteDebugger.exe', 'release\\RemoteDebugger.exe', 'release.\RemoteDebugger.exe', 'release \RemoteDebugger.exe', 'C:\RemoteDebugger.exe', '\\host\RemoteDebugger.exe', 'release\RemoteDebugger.exe:stream', 'release\other.exe', 'release\*\RemoteDebugger.exe')) {
        Assert-Rejected "client-invalid-path-$path" { Resolve-RemoteDebuggerClientFixture -Artifact $artifact -RelativePath $path -ExpectedSha256 $hash } 'traversal-free'
    }
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedRoot) -notlike 'codex-provision-contract-*') { throw 'Unsafe test cleanup target.' }
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
[pscustomobject]@{ Success = $true; ScenarioCount = $checks.Count; Scenarios = @($checks) } | ConvertTo-Json -Depth 4
