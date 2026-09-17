[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$setupPath = Join-Path $repositoryRoot 'setup\Install-RemoteDebuggerAcceptancePool.ps1'
. $setupPath -LibraryOnly
$checks = New-Object Collections.Generic.List[string]

$first = [ordered]@{ FormatVersion = 1; Name = 'fixed'; Nested = [ordered]@{ A = 1; B = @('x', 'y') } }
$same = [ordered]@{ FormatVersion = 1; Name = 'fixed'; Nested = [ordered]@{ A = 1; B = @('x', 'y') } }
$changed = [ordered]@{ FormatVersion = 1; Name = 'fixed'; Nested = [ordered]@{ A = 2; B = @('x', 'y') } }
$firstHash = Get-RemoteDebuggerAcceptancePlanSha256 -Plan $first
$sameHash = Get-RemoteDebuggerAcceptancePlanSha256 -Plan $same
$changedHash = Get-RemoteDebuggerAcceptancePlanSha256 -Plan $changed
if ($firstHash -cnotmatch '^[A-F0-9]{64}$' -or $firstHash -cne $sameHash -or $firstHash -ceq $changedHash) {
    throw 'Dedicated setup plan hashing is not deterministic or does not bind content changes.'
}
$checks.Add('deterministic-plan-hash-binds-content')

$expectedRoot = 'D:\Disk\VMs\RemoteDebugger-Acceptance'
$resolvedRoot = Assert-RemoteDebuggerAcceptanceExactPath -Actual $expectedRoot -Expected $expectedRoot -Name 'test root'
if ($resolvedRoot -cne $expectedRoot) { throw 'Exact dedicated root normalization changed the reviewed path.' }
$checks.Add('exact-dedicated-root-accepted')
$rejected = $false
try { $null = Assert-RemoteDebuggerAcceptanceExactPath -Actual 'D:\Disk\VMs\Codex-Harness' -Expected $expectedRoot -Name 'test root' }
catch { $rejected = $_.Exception.Message -like '*reviewed dedicated path*' }
if (-not $rejected) { throw 'Dedicated setup accepted a shared or alternate install root.' }
$checks.Add('shared-root-rejected')

$policy = New-RemoteDebuggerAcceptanceNetworkPolicy
if ($policy.DefaultProfile -cne 'None' -or -not $policy.IsolatedTestNet.Enabled -or $policy.InternetOnly.Enabled -or $policy.TrustedLan.Enabled) {
    throw 'Dedicated setup network policy is not fail closed outside the isolated request network.'
}
$checks.Add('network-policy-none-or-isolated-only')

$configuration = New-RemoteDebuggerAcceptanceConfiguration -Root $expectedRoot -PublisherThumbprint ('A' * 64) -ApprovedHashes @(('B' * 64), ('C' * 64))
if ($configuration.PoolSize -ne 2 -or $configuration.VmMemoryBytes -ne 8GB -or $configuration.VmProcessorCount -ne 4 -or
    $configuration.BrokerTaskName -cne 'RemoteDebugger Acceptance Hyper-V Broker' -or
    $configuration.BrokerInstanceId -cne 'RemoteDebuggerAcceptance' -or
    $configuration.RemoteDebuggerProvisionV1.ApprovedExecutableSha256.Count -ne 2) {
    throw 'Dedicated configuration does not retain the fixed approved resource and broker identity.'
}
$checks.Add('fixed-two-worker-dedicated-configuration')

$source = Get-Content -LiteralPath $setupPath -Raw
foreach ($required in @(
    'Import-VM', '-Copy', '-GenerateNewId',
    'RemoteDebugger Acceptance Hyper-V Broker',
    'RemoteDebugger-Acceptance-Baseline',
    'RemoteDebugger-Acceptance-01',
    'RemoteDebugger-Acceptance-02',
    'Test-CodexRecoveryBundleIntegrity',
    'Assert-RemoteDebuggerAcceptancePointerUnchanged',
    'RemoteDebuggerObservation.ps1'
)) {
    if ($source -notmatch [regex]::Escape($required)) { throw "Dedicated setup is missing required fixed contract text: $required" }
}
if ($source -match 'Install-CodexHyperVHarness\.ps1.*&' -or $source -match 'Install-LocationPointer') {
    throw 'Dedicated setup delegates to broad recovery or global-pointer installation.'
}
$checks.Add('copy-import-and-shared-preservation-contract')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $checks.Count
    Scenarios = $checks.ToArray()
} | ConvertTo-Json -Depth 4
