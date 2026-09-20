[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = Split-Path -Parent $PSScriptRoot
$runnerPath = Join-Path (Split-Path -Parent $sourceRoot) 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
. (Join-Path $sourceRoot 'RequestNetwork.ps1')
. (Join-Path $sourceRoot 'GuestSetup.ps1')
. (Join-Path $sourceRoot 'SystemPrompts.ps1')
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

function New-SetupRequest {
    param(
        [string] $Profile = 'None',
        [switch] $WithSystemPrompts
    )
    $request = [pscustomobject]@{
        RequestId = 'executable-test-setup-contract'
        Operation = if ($WithSystemPrompts) { 'RunGuestJobSetupSystemPromptsV1' } else { 'RunGuestJobSetupV1' }
        ResetToBaseline = $true
        StopAfter = $true
        GuestSetup = [pscustomobject]@{
            FormatVersion = 1
            ExecutableRelativePath = 'setup\Bootstrap.exe'
            ExecutableSha256 = ('A' * 64)
            Arguments = @('configure', '--test-mode')
            TimeoutSeconds = 120
        }
        HostInputs = @()
        Job = [pscustomobject]@{ executable = '{PAYLOAD}\app.exe' }
        Network = [pscustomobject]@{
            Profile = $Profile
            Cohort = if ($Profile -eq 'IsolatedTestNet') { 'generic-setup-contract' } else { $null }
            AllowHostInputs = $false
        }
    }
    if ($WithSystemPrompts) {
        $request | Add-Member -NotePropertyName SystemPrompts -NotePropertyValue ([pscustomobject][ordered]@{
            FormatVersion = 1
            AcceptUac = $false
            AcceptWindowsFirewall = $true
            PromptTimeoutSeconds = 120
            ExecutableRelativePath = 'app.exe'
            ExecutableSha256 = ('B' * 64)
            FirewallProfiles = @('Private')
        })
    }
    $request
}

$manifest = [pscustomobject]@{ Files = @(
    [pscustomobject]@{ RelativePath = 'setup/Bootstrap.exe'; Sha256 = ('A' * 64) },
    [pscustomobject]@{ RelativePath = 'app.exe'; Sha256 = ('B' * 64) }
) }
$config = [pscustomobject]@{ RequestNetworkPolicy = Get-RequestNetworkDefaultPolicy }
$request = New-SetupRequest
$resolved = Resolve-GuestSetupPolicyV1 -Request $request -PayloadManifest $manifest
if ($resolved.ExecutableRelativePath -cne 'setup\Bootstrap.exe' -or
    $resolved.ExecutableSha256 -cne ('A' * 64) -or
    @($resolved.Arguments).Count -ne 2 -or $resolved.TimeoutSeconds -ne 120) {
    throw 'The valid guest-setup request did not preserve its exact identity and execution bounds.'
}
$checks.Add('valid-policy-resolves')

$argumentSets = New-Object Collections.Generic.List[object]
$argumentSets.Add([object[]]::new(0))
$argumentSets.Add([object[]]('configure'))
foreach ($argumentSet in $argumentSets) {
    $request = New-SetupRequest
    $request.GuestSetup.Arguments = $argumentSet
    $resolved = Resolve-GuestSetupPolicyV1 -Request $request -PayloadManifest $manifest
    if ($resolved.Arguments -isnot [Array] -or @($resolved.Arguments).Count -ne $argumentSet.Count) {
        throw 'Guest setup did not preserve an empty or one-element argument array.'
    }
}
$checks.Add('argument-array-shape-preserved')

foreach ($profile in @('None', 'IsolatedTestNet')) {
    $network = Resolve-RequestNetworkProfile -Request (New-SetupRequest -Profile $profile) -Config $config
    if ($network.EffectiveProfile -ne $profile) { throw "Guest setup did not preserve $profile." }
    $checks.Add("network-$profile")

    $combined = New-SetupRequest -Profile $profile -WithSystemPrompts
    $combinedNetwork = Resolve-RequestNetworkProfile -Request $combined -Config $config
    $combinedSetup = Resolve-GuestSetupPolicyV1 -Request $combined -PayloadManifest $manifest
    $combinedPrompts = Resolve-SystemPromptPolicyV1 -Request $combined -PayloadManifest $manifest
    if ($combinedNetwork.EffectiveProfile -ne $profile -or
        $combinedSetup.ExecutableSha256 -cne ('A' * 64) -or
        $combinedPrompts.ExecutableSha256 -cne ('B' * 64) -or
        (@($combinedPrompts.Sequence) -join ',') -cne 'WindowsFirewall') {
        throw "Combined guest setup and prompt policy did not preserve $profile and both exact identities."
    }
    $checks.Add("combined-system-prompts-$profile")
}

$request = New-SetupRequest
$request.Operation = 'RunGuestJobSetupSystemPromptsV1'
Assert-Rejected 'combined-requires-system-prompts' { Resolve-GuestSetupPolicyV1 -Request $request -PayloadManifest $manifest } 'requires SystemPrompts'
$request = New-SetupRequest -WithSystemPrompts
$request.PSObject.Properties.Remove('GuestSetup')
Assert-Rejected 'combined-requires-guest-setup' { Resolve-SystemPromptPolicyV1 -Request $request -PayloadManifest $manifest } 'requires GuestSetup'
$request = New-SetupRequest -WithSystemPrompts
$request.Operation = 'RunGuestJobSetupV1'
Assert-Rejected 'setup-only-operation-rejects-prompts' { Resolve-GuestSetupPolicyV1 -Request $request -PayloadManifest $manifest } 'require RunGuestJobSetupSystemPromptsV1'
$request = New-SetupRequest -WithSystemPrompts
$request.Operation = 'RunGuestJobSystemPromptsV1'
Assert-Rejected 'prompt-only-operation-rejects-setup' { Resolve-SystemPromptPolicyV1 -Request $request -PayloadManifest $manifest } 'require RunGuestJobSetupSystemPromptsV1'

$request = New-SetupRequest
$request.Operation = 'RunGuestJob'
Assert-Rejected 'versioned-operation-required' { Resolve-RequestNetworkProfile -Request $request -Config $config } 'versioned'
$request = New-SetupRequest
$request.PSObject.Properties.Remove('GuestSetup')
Assert-Rejected 'profile-required' { Resolve-RequestNetworkProfile -Request $request -Config $config } 'requires GuestSetup'
foreach ($profile in @('InternetOnly', 'TrustedLan')) {
    $request = New-SetupRequest -Profile $profile
    $request.Network.Cohort = $null
    Assert-Rejected "external-network-$profile" { Resolve-RequestNetworkProfile -Request $request -Config $config } 'only None or IsolatedTestNet'
}
$request = New-SetupRequest
$request.HostInputs = @([pscustomobject]@{ Name = 'data' })
Assert-Rejected 'host-inputs-denied' { Resolve-RequestNetworkProfile -Request $request -Config $config } 'host inputs'
$request = New-SetupRequest
$request | Add-Member -NotePropertyName ExpectGuestPowerOff -NotePropertyValue $true
Assert-Rejected 'expected-poweroff-denied' { Resolve-RequestNetworkProfile -Request $request -Config $config } 'expected power-off'
foreach ($flag in @('ResetToBaseline', 'StopAfter')) {
    $request = New-SetupRequest
    $request.$flag = $false
    Assert-Rejected "disposable-lifetime-$flag" { Resolve-RequestNetworkProfile -Request $request -Config $config } 'exact Boolean'
}

$request = New-SetupRequest
$request.GuestSetup.ExecutableSha256 = ('B' * 64)
Assert-Rejected 'manifest-hash-bound' { Resolve-GuestSetupPolicyV1 -Request $request -PayloadManifest $manifest } 'payload-manifest'
$request = New-SetupRequest
$request.GuestSetup | Add-Member -NotePropertyName Product -NotePropertyValue 'specific'
Assert-Rejected 'extra-profile-property-denied' { Resolve-GuestSetupPolicyV1 -Request $request -PayloadManifest $manifest } 'unsupported properties'
$request = New-SetupRequest
$request.GuestSetup.Arguments = 'configure'
Assert-Rejected 'arguments-must-be-array' { Resolve-GuestSetupPolicyV1 -Request $request -PayloadManifest $manifest } 'JSON array'
$request = New-SetupRequest
$request.GuestSetup.Arguments = [object[]](1)
Assert-Rejected 'arguments-must-be-strings' { Resolve-GuestSetupPolicyV1 -Request $request -PayloadManifest $manifest } 'must be a string'
foreach ($path in @('..\Bootstrap.exe', 'setup\\Bootstrap.exe', 'setup\Bootstrap.exe:stream', 'C:\Bootstrap.exe', '\\host\Bootstrap.exe', 'setup\Bootstrap.dll')) {
    $request = New-SetupRequest
    $request.GuestSetup.ExecutableRelativePath = $path
    Assert-Rejected "invalid-path-$($checks.Count)" { Resolve-GuestSetupPolicyV1 -Request $request -PayloadManifest $manifest } 'GuestSetup ExecutableRelativePath'
}

# Import only the runner's pure local identity resolver. The fixture is inert and never executed.
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw $parseErrors[0].Message }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-GuestSetupClientExecutable' }, $true)
if (-not $definition) { throw 'Missing generic guest-setup client identity resolver.' }
. ([scriptblock]::Create($definition.Extent.Text))
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempBase ('codex-guest-setup-contract-' + [Guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $testRoot 'setup')
    $fixturePath = Join-Path $testRoot 'setup\Bootstrap.exe'
    [IO.File]::WriteAllText($fixturePath, 'Inert contract fixture. This file is never executed.')
    $hash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
    $artifact = Get-Item -LiteralPath $testRoot
    $client = Resolve-GuestSetupClientExecutable -Artifact $artifact -RelativePath 'setup/Bootstrap.exe' -ExpectedSha256 $hash.ToLowerInvariant() -Arguments @('configure') -TimeoutSeconds 60
    if ($client.ExecutableSha256 -cne $hash -or $client.ExecutableRelativePath -cne 'setup\Bootstrap.exe' -or
        $client.Arguments -isnot [Array] -or @($client.Arguments).Count -ne 1) {
        throw 'The client identity resolver changed the setup contract.'
    }
    $checks.Add('client-exact-identity-normalized')
    Assert-Rejected 'client-hash-drift-denied' { Resolve-GuestSetupClientExecutable -Artifact $artifact -RelativePath 'setup\Bootstrap.exe' -ExpectedSha256 ('0' * 64) } 'differs'
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedRoot) -notlike 'codex-guest-setup-contract-*') { throw 'Unsafe test cleanup target.' }
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}

$sourceText = Get-Content -LiteralPath (Join-Path $sourceRoot 'GuestSetup.ps1') -Raw
if ($sourceText -notmatch 'StagedExecutableSha256' -or $sourceText -notmatch 'IsAdministrator') {
    throw 'The guest-setup implementation lacks exact staged identity/elevation evidence.'
}
$checks.Add('generic-identity-and-elevation-evidence')

[pscustomobject]@{ Success = $true; ScenarioCount = $checks.Count; Scenarios = @($checks) } | ConvertTo-Json -Depth 4
