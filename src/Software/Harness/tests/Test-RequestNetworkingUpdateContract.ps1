[CmdletBinding()]
param([string] $RepositoryRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$scriptPath = Join-Path $RepositoryRoot 'setup\Update-RequestNetworking.ps1'
$infrastructurePath = Join-Path $RepositoryRoot 'setup\Prepare-RequestNetworkInfrastructure.ps1'
$setupSkillPath = Join-Path $RepositoryRoot '.agents\skills\setup-hyperv-harness\SKILL.md'
$recoveryVerifierPath = Join-Path $RepositoryRoot 'src\Software\Recovery\Test-CodexHyperVRecovery.ps1'
$text = Get-Content -Raw -LiteralPath $scriptPath
$infrastructureText = Get-Content -Raw -LiteralPath $infrastructurePath
$setupSkillText = Get-Content -Raw -LiteralPath $setupSkillPath
$recoveryVerifierText = Get-Content -Raw -LiteralPath $recoveryVerifierPath
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Update-RequestNetworking.ps1 has a parse error: $($errors[0].Message)" }
$infraTokens = $null
$infraErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($infrastructurePath, [ref]$infraTokens, [ref]$infraErrors)
if ($infraErrors.Count -gt 0) { throw "Prepare-RequestNetworkInfrastructure.ps1 has a parse error: $($infraErrors[0].Message)" }
$scenarios = New-Object Collections.Generic.List[string]

$planBranch = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] }, $true) | Where-Object {
    $_.Extent.Text -like 'if ($PlanOnly)*'
} | Select-Object -First 1)
Assert-True ($planBranch.Count -eq 1) 'The request-network updater has no explicit PlanOnly terminal branch.'
$planText = $planBranch[0].Extent.Text
Assert-True ($planText.Contains('ConvertTo-Json') -and $planText.Contains('return')) 'PlanOnly does not return immediately after emitting the plan.'
Assert-True ($text.IndexOf('if ($PlanOnly)', [StringComparison]::Ordinal) -lt $text.IndexOf('Start-RequestNetworkingElevatedSelf', $text.IndexOf('if ($PlanOnly)', [StringComparison]::Ordinal), [StringComparison]::Ordinal)) 'PlanOnly is not ordered before elevation.'
Assert-True ($text.Contains('NoMutationPerformed = [bool]$PlanOnly') -and $text.Contains('InfrastructureProvisioningIncluded = $false')) 'Plan output does not explicitly report its non-mutating boundary.'
$scenarios.Add('plan-only-returns-before-elevation-or-mutation')

foreach ($mutatingInfrastructureCommand in @('New-VMSwitch', 'Remove-VMSwitch', 'New-NetNat', 'Remove-NetNat', 'Set-VMNetworkAdapterVlan', 'New-NetFirewallRule')) {
    Assert-True (-not $text.Contains($mutatingInfrastructureCommand)) "Policy deployment unexpectedly contains infrastructure mutation command $mutatingInfrastructureCommand."
}
Assert-True ($text.Contains('Get-VMSwitch') -and $text.Contains('Get-NetNat') -and $text.Contains('Get-NetRoute') -and $text.Contains('Get-NetAdapter')) 'Read-only infrastructure inspection is incomplete.'
Assert-True ($text.Contains('DeferredLiveWork') -and $text.Contains('separately approved exact infrastructure plan')) 'The updater does not separate host infrastructure provisioning from broker-policy deployment.'
$scenarios.Add('policy-deployment-does-not-create-network-infrastructure')

Assert-True (
    $text.Contains('ApprovedPlanFingerprint') -and
    $text.Contains('CurrentConfigSha256') -and
    $text.Contains('PolicySha256') -and
    $text.Contains('SourceSha256') -and
    $text.Contains('DefaultRoutes') -and
    $text.Contains('no longer matches current source, configuration, queue, routes, or host infrastructure')
) 'The exact plan fingerprint does not bind source, policy, configuration, queue, routes, and host identities.'
Assert-True ($text.Contains('must remain outside the public repository')) 'Private host policy is not rejected from the public checkout.'
$scenarios.Add('approved-fingerprint-binds-private-policy-and-host-state')

Assert-True (
    $text.Contains('RequestNetworkUpdateBackup-') -and
    $text.Contains('Invoke-RequestNetworkingMirror') -and
    $text.Contains('Install-PoolHostBroker.ps1') -and
    $text.Contains('Request-network update failed:') -and
    $text.Contains('Rollback material remains at')
) 'The broker-policy update lacks an explicit source/config/skill rollback transaction.'
Assert-True (
    $text.IndexOf('$installedSourceMutated = $true', [StringComparison]::Ordinal) -lt $text.IndexOf("Copy-Item -Path (Join-Path `$checkoutHarnessRoot '*')", [StringComparison]::Ordinal) -and
    $text.Contains('Always reinstall the restored source/config')
) 'Rollback is not armed before the first source overlay or does not restore a partially changed broker.'
Assert-True (
    $text.Contains('Audit-HyperVTestPool.ps1') -and
    $text.Contains('RollbackMaterialPath = $backupRoot') -and
    -not $text.Contains('Remove-Item -LiteralPath $backupRoot -Recurse -Force') -and
    $text.Contains('RecoveryRefreshRequired = $true') -and
    $text.Contains('LiveProfileCanariesRequired = $true')
) 'Deployment does not preserve rollback material through post-install audit, live proof, and recovery refresh.'
$scenarios.Add('deployment-is-transactional-and-stops-before-claiming-live-proof')

Assert-True (
    $text.Contains("'Canaries\NetworkBoundaryCanary.cs'") -and
    $text.Contains("'Canaries\NetworkBoundaryCanary.exe'") -and
    $text.Contains("'Recovery\Test-CodexHyperVRecovery.ps1'") -and
    $text.Contains("Join-Path `$backupRoot 'Canaries'") -and
    $text.Contains("Join-Path `$backupRoot 'Recovery'") -and
    $text.Contains("Join-Path `$checkoutCanariesRoot 'NetworkBoundaryCanary.exe'") -and
    $text.Contains("Join-Path `$checkoutRecoveryRoot 'Test-CodexHyperVRecovery.ps1'")
) 'The live update does not source-bind, stage, and preserve rollback for its network canary and recovery verifier.'
$scenarios.Add('live-update-carries-network-canary-and-recovery-contract')

Assert-True ($setupSkillText.Contains('Update-RequestNetworking.ps1') -and $setupSkillText.Contains('approved fingerprint') -and $setupSkillText.Contains('separate approval')) 'The setup skill does not preserve the two-gate request-network workflow.'
Assert-True ($recoveryVerifierText.Contains("'Software\Setup\Update-RequestNetworking.ps1'")) 'Recovery verification does not require the request-network updater.'
$scenarios.Add('setup-and-recovery-contracts-carry-the-updater')

foreach ($requiredInfrastructureContract in @(
    'Get-RequestNetworkInfrastructurePlan',
    'ApprovedPlanFingerprint',
    'NoMutationPerformed',
    'New-VMSwitch @createInternet',
    'New-VMSwitch @createTrusted',
    'Set-VMNetworkAdapterVlan -VMNetworkAdapter $management[0] -Promiscuous',
    'New-NetNat -Name $InternetNatName',
    'Preserve all unrelated switches, NATs, VMs, adapters, routes, and firewall rules.',
    'PreparedForBrokerPolicyPlan',
    'RolledBack'
)) {
    Assert-True ($infrastructureText.Contains($requiredInfrastructureContract)) "Infrastructure preparation contract is missing: $requiredInfrastructureContract"
}
$infraPlanIndex = $infrastructureText.IndexOf('if ($PlanOnly)', [StringComparison]::Ordinal)
$infraMutationIndex = $infrastructureText.IndexOf('New-VMSwitch @createInternet', [StringComparison]::Ordinal)
Assert-True ($infraPlanIndex -ge 0 -and $infraMutationIndex -gt $infraPlanIndex) 'Infrastructure PlanOnly does not precede its first host mutation.'
Assert-True (-not $infrastructureText.Contains('Get-VMSwitch | Remove-VMSwitch') -and -not $infrastructureText.Contains('Get-NetNat | Remove-NetNat')) 'Infrastructure rollback contains an unscoped destructive pipeline.'
Assert-True ($text.Contains('Prepare-RequestNetworkInfrastructure.ps1')) 'The broker updater does not stage or bind the infrastructure preparation source.'
Assert-True ($recoveryVerifierText.Contains("'Software\Setup\Prepare-RequestNetworkInfrastructure.ps1'")) 'Recovery verification does not require the infrastructure preparation script.'
$scenarios.Add('fingerprinted-infrastructure-preparation-is-scoped-and-recoverable')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
