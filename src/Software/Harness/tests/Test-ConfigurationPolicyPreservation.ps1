[CmdletBinding()]
param(
    [string] $RepositoryRoot = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)] [string] $Scenario,
        [Parameter(Mandatory = $true)] [string] $ExpectedMessage,
        [Parameter(Mandatory = $true)] [scriptblock] $Operation
    )

    try {
        & $Operation | Out-Null
        throw "Scenario '$Scenario' unexpectedly succeeded."
    }
    catch {
        if ($_.Exception.Message -like "Scenario '$Scenario' unexpectedly succeeded.*") { throw }
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Scenario '$Scenario' returned the wrong error. Expected '*$ExpectedMessage*'; got '$($_.Exception.Message)'."
        }
    }
}

function Write-TestJson {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
}

function Get-TestSha256 {
    param([Parameter(Mandatory = $true)] [string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

$configurationPath = Join-Path $RepositoryRoot 'setup\New-HarnessConfiguration.ps1'
$installPath = Join-Path $RepositoryRoot 'setup\Install.ps1'
$requestNetworkPath = Join-Path $RepositoryRoot 'src\Software\Harness\RequestNetwork.ps1'
. $requestNetworkPath

$scenarios = New-Object Collections.Generic.List[string]
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-configuration-policy-' + [Guid]::NewGuid().ToString('N'))
try {
    $freshInstallRoot = Join-Path $testRoot 'fresh-install'
    $freshConfigPath = Join-Path $freshInstallRoot 'Software\harness-config.json'
    $freshPlan = & $configurationPath -InstallRoot $freshInstallRoot -OutputPath $freshConfigPath -PlanOnly
    Assert-True (-not (Test-Path -LiteralPath $freshConfigPath)) 'Fresh-install PlanOnly wrote a configuration file.'
    Assert-True (-not (Test-Path -LiteralPath $freshInstallRoot)) 'Fresh-install PlanOnly created the install root.'
    Assert-True (-not [bool]$freshPlan.ExistingConfigurationDetected -and [string]$freshPlan.RequestNetworkPolicyDisposition -eq 'CreatedFailClosed') 'Fresh-install PlanOnly did not report fail-closed creation.'
    Assert-True ([bool]$freshPlan.NoMutationPerformed -and [string]::IsNullOrWhiteSpace([string]$freshPlan.CommittedConfigurationSha256)) 'Fresh-install PlanOnly did not report its no-mutation state.'
    Assert-Rejected -Scenario 'fresh-install policy reset' -ExpectedMessage 'valid only for an existing' -Operation {
        & $configurationPath -InstallRoot $freshInstallRoot -OutputPath $freshConfigPath -ResetRequestNetworkPolicy -PlanOnly
    }
    $created = & $configurationPath -InstallRoot $freshInstallRoot -OutputPath $freshConfigPath
    Assert-True (Test-Path -LiteralPath $freshConfigPath -PathType Leaf) 'Fresh installation did not create its configuration.'
    $createdConfig = Get-Content -LiteralPath $freshConfigPath -Raw | ConvertFrom-Json
    Assert-True (-not [bool]$createdConfig.RequestNetworkPolicy.InternetOnly.Enabled -and -not [bool]$createdConfig.RequestNetworkPolicy.TrustedLan.Enabled) 'Fresh installation did not create fail-closed external network profiles.'
    Assert-True ([string]$created.RequestNetworkPolicyDisposition -eq 'CreatedFailClosed' -and [string]$created.CommittedConfigurationSha256 -eq (Get-TestSha256 -Path $freshConfigPath)) 'Fresh installation did not attest its committed configuration.'
    $scenarios.Add('fresh-install-is-plan-only-then-fail-closed')

    $orphanedInstallRoot = Join-Path $testRoot 'orphaned-install'
    $orphanedConfigPath = Join-Path $orphanedInstallRoot 'Software\harness-config.json'
    New-Item -ItemType Directory -Force -Path (Join-Path $orphanedInstallRoot 'Live\Broker') | Out-Null
    Assert-Rejected -Scenario 'existing state without configuration' -ExpectedMessage 'refusing to treat this as a first installation' -Operation {
        & $configurationPath -InstallRoot $orphanedInstallRoot -OutputPath $orphanedConfigPath -PlanOnly
    }
    Assert-True (-not (Test-Path -LiteralPath $orphanedConfigPath)) 'Existing state without a configuration was silently converted into a first installation.'
    $scenarios.Add('existing-state-without-configuration-is-not-a-first-install')

    $preserveInstallRoot = Join-Path $testRoot 'preserve-install'
    $preserveConfigPath = Join-Path $preserveInstallRoot 'Software\harness-config.json'
    $null = & $configurationPath -InstallRoot $preserveInstallRoot -OutputPath $preserveConfigPath
    $preserveConfig = Get-Content -LiteralPath $preserveConfigPath -Raw | ConvertFrom-Json
    $policy = Get-RequestNetworkDefaultPolicy
    $policy.InternetOnly.Enabled = $true
    $policy.InternetOnly.SwitchName = 'Codex Test NAT'
    $policy.InternetOnly.SwitchId = '11111111-1111-4111-8111-111111111111'
    $policy.InternetOnly.NatName = 'CodexHarnessNat'
    $policy.InternetOnly.NatPrefix = '10.253.0.0/24'
    $policy.InternetOnly.GatewayAddress = '10.253.0.1'
    $policy.InternetOnly.PrimaryVlanId = 100
    $policy.InternetOnly.SecondaryVlanId = 101
    $policy.InternetOnly.DnsServers = @('1.1.1.1')
    $policy.InternetOnly.DenyRemotePrefixes = @('10.0.0.0/8')
    $policy.TrustedLan.Enabled = $true
    $policy.TrustedLan.AllowedSwitches = @([pscustomobject][ordered]@{
        Name = 'Pinned Trusted LAN'
        Id = '22222222-2222-4222-8222-222222222222'
        NetAdapterInterfaceGuid = '33333333-3333-4333-8333-333333333333'
        NetAdapterInterfaceDescription = 'Pinned physical adapter'
        AllowManagementOS = $false
    })
    $null = Assert-RequestNetworkPolicySchema -Policy $policy
    $preserveConfig.RequestNetworkPolicy = $policy
    Write-TestJson -Path $preserveConfigPath -Value $preserveConfig
    $reviewedHash = Get-TestSha256 -Path $preserveConfigPath
    $reviewedPolicyJson = $policy | ConvertTo-Json -Depth 30 -Compress
    $plan = & $configurationPath -InstallRoot $preserveInstallRoot -OutputPath $preserveConfigPath -PoolSize 3 -PlanOnly
    Assert-True ([string]$plan.ExistingConfigurationSha256 -eq $reviewedHash -and [string]$plan.RequestNetworkPolicyDisposition -eq 'PreservedExisting') 'Refresh PlanOnly did not report the exact existing configuration fingerprint and preservation disposition.'
    Assert-True ((Get-TestSha256 -Path $preserveConfigPath) -eq $reviewedHash) 'Refresh PlanOnly changed the installed configuration.'
    Assert-Rejected -Scenario 'unfingerprinted refresh' -ExpectedMessage 'ExpectedExistingConfigurationSha256' -Operation {
        & $configurationPath -InstallRoot $preserveInstallRoot -OutputPath $preserveConfigPath -PoolSize 3
    }
    Assert-True ((Get-TestSha256 -Path $preserveConfigPath) -eq $reviewedHash) 'Rejected unfingerprinted refresh changed the installed configuration.'
    $refreshed = & $configurationPath -InstallRoot $preserveInstallRoot -OutputPath $preserveConfigPath -PoolSize 3 -ExpectedExistingConfigurationSha256 $reviewedHash
    $refreshedConfig = Get-Content -LiteralPath $preserveConfigPath -Raw | ConvertFrom-Json
    Assert-True ([int]$refreshedConfig.PoolSize -eq 3) 'Fingerprint-authorized refresh did not update ordinary configuration values.'
    Assert-True (($refreshedConfig.RequestNetworkPolicy | ConvertTo-Json -Depth 30 -Compress) -ceq $reviewedPolicyJson) 'Fingerprint-authorized refresh did not preserve the complete validated request-network policy.'
    Assert-True ([string]$refreshed.RequestNetworkPolicyDisposition -eq 'PreservedExisting' -and [string]$refreshed.RequestNetworkPolicySha256 -eq [string]$plan.RequestNetworkPolicySha256) 'Fingerprint-authorized refresh reported the wrong policy disposition or policy fingerprint.'
    $scenarios.Add('valid-enabled-policy-is-preserved-by-exact-fingerprint')

    $currentHash = Get-TestSha256 -Path $preserveConfigPath
    Assert-Rejected -Scenario 'stale fingerprint' -ExpectedMessage 'changed after review' -Operation {
        & $configurationPath -InstallRoot $preserveInstallRoot -OutputPath $preserveConfigPath -PoolSize 4 -ExpectedExistingConfigurationSha256 $reviewedHash
    }
    Assert-True ((Get-TestSha256 -Path $preserveConfigPath) -eq $currentHash) 'A stale-fingerprint rejection changed the installed configuration.'
    $scenarios.Add('stale-configuration-fingerprint-fails-closed')

    $malformedInstallRoot = Join-Path $testRoot 'malformed-policy-install'
    $malformedConfigPath = Join-Path $malformedInstallRoot 'Software\harness-config.json'
    $null = & $configurationPath -InstallRoot $malformedInstallRoot -OutputPath $malformedConfigPath
    $malformedConfig = Get-Content -LiteralPath $malformedConfigPath -Raw | ConvertFrom-Json
    $malformedConfig.RequestNetworkPolicy.FormatVersion = 2
    Write-TestJson -Path $malformedConfigPath -Value $malformedConfig
    $malformedHash = Get-TestSha256 -Path $malformedConfigPath
    Assert-Rejected -Scenario 'malformed policy preserve plan' -ExpectedMessage 'malformed or incompatible' -Operation {
        & $configurationPath -InstallRoot $malformedInstallRoot -OutputPath $malformedConfigPath -PlanOnly
    }
    Assert-True ((Get-TestSha256 -Path $malformedConfigPath) -eq $malformedHash) 'Malformed policy rejection changed the installed configuration.'
    $resetPlan = & $configurationPath -InstallRoot $malformedInstallRoot -OutputPath $malformedConfigPath -ResetRequestNetworkPolicy -PlanOnly
    Assert-True ([string]$resetPlan.RequestNetworkPolicyDisposition -eq 'ResetToFailClosed' -and [bool]$resetPlan.IntentionalPolicyReset -and [bool]$resetPlan.NoMutationPerformed) 'Explicit policy-reset PlanOnly did not clearly report the destructive policy disposition.'
    Assert-Rejected -Scenario 'unfingerprinted policy reset' -ExpectedMessage 'ExpectedExistingConfigurationSha256' -Operation {
        & $configurationPath -InstallRoot $malformedInstallRoot -OutputPath $malformedConfigPath -ResetRequestNetworkPolicy
    }
    $reset = & $configurationPath -InstallRoot $malformedInstallRoot -OutputPath $malformedConfigPath -ResetRequestNetworkPolicy -ExpectedExistingConfigurationSha256 $malformedHash
    $resetConfig = Get-Content -LiteralPath $malformedConfigPath -Raw | ConvertFrom-Json
    Assert-True ([string]$reset.RequestNetworkPolicyDisposition -eq 'ResetToFailClosed' -and -not [bool]$resetConfig.RequestNetworkPolicy.InternetOnly.Enabled -and -not [bool]$resetConfig.RequestNetworkPolicy.TrustedLan.Enabled) 'Explicit fingerprinted reset did not produce fail-closed policy defaults.'
    $scenarios.Add('malformed-policy-requires-explicit-fingerprinted-reset')

    $missingInstallRoot = Join-Path $testRoot 'missing-policy-install'
    $missingConfigPath = Join-Path $missingInstallRoot 'Software\harness-config.json'
    $null = & $configurationPath -InstallRoot $missingInstallRoot -OutputPath $missingConfigPath
    $missingConfig = Get-Content -LiteralPath $missingConfigPath -Raw | ConvertFrom-Json
    $missingConfig.PSObject.Properties.Remove('RequestNetworkPolicy')
    Write-TestJson -Path $missingConfigPath -Value $missingConfig
    $missingHash = Get-TestSha256 -Path $missingConfigPath
    Assert-Rejected -Scenario 'missing policy' -ExpectedMessage 'has no RequestNetworkPolicy' -Operation {
        & $configurationPath -InstallRoot $missingInstallRoot -OutputPath $missingConfigPath -PlanOnly
    }
    Assert-True ((Get-TestSha256 -Path $missingConfigPath) -eq $missingHash) 'Missing-policy rejection changed the installed configuration.'
    $missingResetPlan = & $configurationPath -InstallRoot $missingInstallRoot -OutputPath $missingConfigPath -ResetRequestNetworkPolicy -PlanOnly
    Assert-True ([string]$missingResetPlan.RequestNetworkPolicyDisposition -eq 'ResetToFailClosed') 'A missing policy could not be recovered through the explicit reset plan.'
    $scenarios.Add('missing-policy-fails-closed-with-explicit-reset-route')

    foreach ($identityCase in @(
        [pscustomobject]@{ Name = 'malformed JSON'; Content = '{'; Expected = 'Could not read' },
        [pscustomobject]@{ Name = 'unsupported configuration version'; Content = '{"FormatVersion":2,"InstallRoot":"' + ($freshInstallRoot -replace '\\','\\') + '"}'; Expected = 'FormatVersion' },
        [pscustomobject]@{ Name = 'different install root'; Content = '{"FormatVersion":1,"InstallRoot":"C:\\Different\\Harness"}'; Expected = 'different install root' }
    )) {
        $identityRoot = Join-Path $testRoot ('identity-' + [Guid]::NewGuid().ToString('N'))
        $identityPath = Join-Path $identityRoot 'Software\harness-config.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $identityPath) | Out-Null
        [IO.File]::WriteAllText($identityPath, [string]$identityCase.Content, (New-Object Text.UTF8Encoding($false)))
        $identityHash = Get-TestSha256 -Path $identityPath
        Assert-Rejected -Scenario ([string]$identityCase.Name) -ExpectedMessage ([string]$identityCase.Expected) -Operation {
            & $configurationPath -InstallRoot $identityRoot -OutputPath $identityPath -ResetRequestNetworkPolicy -PlanOnly
        }
        Assert-True ((Get-TestSha256 -Path $identityPath) -eq $identityHash) "Identity rejection '$($identityCase.Name)' changed the installed configuration."
    }
    $scenarios.Add('malformed-or-incompatible-configuration-cannot-be-hidden-by-reset')

    $tokens = $null
    $parseErrors = $null
    $configurationAst = [Management.Automation.Language.Parser]::ParseFile($configurationPath, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'New-HarnessConfiguration.ps1 has a parse error.'
    $ownedFunctions = @($configurationAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Get-HarnessFileSha256', 'Write-HarnessConfigurationAtomic')
    }, $true))
    Assert-True ($ownedFunctions.Count -eq 2) 'Atomic configuration writer functions are missing or ambiguous.'
    foreach ($ownedFunction in $ownedFunctions) { . ([scriptblock]::Create($ownedFunction.Extent.Text)) }

    $rollbackPath = Join-Path $testRoot 'atomic\existing.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rollbackPath) | Out-Null
    [IO.File]::WriteAllText($rollbackPath, 'original', (New-Object Text.UTF8Encoding($false)))
    $rollbackHash = Get-TestSha256 -Path $rollbackPath
    $script:configurationValidationCount = 0
    $failingValidator = {
        param([string] $Path)
        $script:configurationValidationCount++
        if ($script:configurationValidationCount -eq 2) { throw 'injected post-commit validation failure' }
    }
    Assert-Rejected -Scenario 'existing configuration rollback' -ExpectedMessage 'was rolled back' -Operation {
        Write-HarnessConfigurationAtomic -Path $rollbackPath -Json 'replacement' -ExpectedExisting $true -ExpectedCurrentSha256 $rollbackHash -ValidateCommittedPath $failingValidator
    }
    Assert-True ((Get-Content -LiteralPath $rollbackPath -Raw) -ceq 'original' -and (Get-TestSha256 -Path $rollbackPath) -eq $rollbackHash) 'Post-commit validation failure did not restore the exact existing configuration.'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $rollbackPath) -File | Where-Object { $_.Extension -in @('.tmp', '.bak') }).Count -eq 0) 'Successful rollback left transaction debris.'

    $newRollbackPath = Join-Path $testRoot 'atomic\new.json'
    $script:configurationValidationCount = 0
    Assert-Rejected -Scenario 'new configuration rollback' -ExpectedMessage 'was rolled back' -Operation {
        Write-HarnessConfigurationAtomic -Path $newRollbackPath -Json 'replacement' -ExpectedExisting $false -ExpectedCurrentSha256 '' -ValidateCommittedPath $failingValidator
    }
    Assert-True (-not (Test-Path -LiteralPath $newRollbackPath)) 'Post-commit validation failure left a new configuration behind.'
    $scenarios.Add('atomic-commit-validation-rolls-back-existing-and-new-files')

    $installText = Get-Content -LiteralPath $installPath -Raw
    $previewIndex = $installText.IndexOf('$configurationPreview = & $configurationScript @configurationParameters', [StringComparison]::Ordinal)
    $elevationIndex = $installText.IndexOf('if (-not (Test-Administrator))', [StringComparison]::Ordinal)
    $stagingIndex = $installText.IndexOf("Write-SetupState -Phase 'StagingSource'", [StringComparison]::Ordinal)
    $secondPreviewIndex = $installText.IndexOf('$configurationPreview = & $configurationScript @configurationParameters', $previewIndex + 1, [StringComparison]::Ordinal)
    Assert-True ($previewIndex -ge 0 -and $previewIndex -lt $elevationIndex) 'Installer does not validate configuration policy before elevation or live writes.'
    Assert-True ($secondPreviewIndex -gt $elevationIndex -and $secondPreviewIndex -lt $stagingIndex) 'Installer does not revalidate the reviewed configuration fingerprint immediately before source staging.'
    Assert-True ($installText.Contains("'harness-config.json'")) 'Source mirroring can delete the installed harness configuration.'
    Assert-True ($installText.Contains("@('-ExpectedExistingConfigurationSha256', `$ExpectedExistingConfigurationSha256)")) 'Elevation/resume does not carry the reviewed configuration fingerprint.'
    Assert-True ($installText.Contains("'ResetRequestNetworkPolicy'") -and $installText.Contains('PolicyResetApproval')) 'Installer does not propagate and visibly report intentional policy reset.'
    Assert-True ($installText.Contains("`$ExpectedExistingConfigurationSha256 = [string]`$layout.CommittedConfigurationSha256")) 'Restart resume does not advance to the newly committed configuration fingerprint.'
    $scenarios.Add('installer-validates-before-staging-and-propagates-policy-intent')

    $maintenanceText = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'docs\maintenance.md') -Raw
    $setupSkillText = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.agents\skills\setup-hyperv-harness\SKILL.md') -Raw
    Assert-True ($maintenanceText.Contains('RequestNetworkPolicyDisposition = PreservedExisting') -and $maintenanceText.Contains('ResetToFailClosed')) 'Maintenance documentation does not distinguish ordinary preservation from intentional policy reset.'
    Assert-True ($setupSkillText.Contains('ExpectedExistingConfigurationSha256') -and $setupSkillText.Contains('separate explicit approval')) 'Setup skill does not require a fingerprint and separate approval for policy reset.'
    $scenarios.Add('maintenance-contract-documents-preserve-and-reset-paths')

    foreach ($path in @($configurationPath, $installPath, $PSCommandPath)) {
        $parseTokens = $null
        $parseIssues = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$parseTokens, [ref]$parseIssues)
        Assert-True ($parseIssues.Count -eq 0) "PowerShell parse failure in $path"
    }
    $scenarios.Add('owned-powershell-parses')
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
