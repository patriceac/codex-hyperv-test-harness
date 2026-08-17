[CmdletBinding()]
param([string] $RepositoryRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([string] $Scenario, [string] $ExpectedMessage, [scriptblock] $Operation) {
    $message = $null
    try { & $Operation } catch { $message = $_.Exception.Message }
    if ([string]::IsNullOrWhiteSpace($message)) { throw "Scenario '$Scenario' unexpectedly succeeded." }
    if ($message -notlike "*$ExpectedMessage*") { throw "Scenario '$Scenario' returned the wrong error: $message" }
}
function Remove-TestJunction([string] $Path) { if ($Path) { try { [IO.Directory]::Delete($Path) } catch { } } }

$helperPath = Join-Path $RepositoryRoot 'src\Software\UserIntegration\Install-CodexUserIntegration.ps1'
$installPath = Join-Path $RepositoryRoot 'setup\Install.ps1'
$updatePath = Join-Path $RepositoryRoot 'setup\Update-Images.ps1'
$helperText = Get-Content -Raw -LiteralPath $helperPath
$installText = Get-Content -Raw -LiteralPath $installPath
$updateText = Get-Content -Raw -LiteralPath $updatePath
$tokens = $null
$parseErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseInput($helperText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "User-integration helper did not parse: $($parseErrors[0].Message)" }
foreach ($name in @(
    'Get-ExistingFileSystemItem', 'Test-IsReparsePoint', 'Get-PathChain', 'Assert-NoReparsePointChain',
    'Ensure-SafeDirectoryChain', 'Get-ContentTreeInventory', 'Get-ContentTreeFingerprint', 'Get-FileFingerprint',
    'Invoke-RobocopyMirror', 'Remove-SafeTree', 'Install-RuntimeSkillForCurrentUser', 'Install-ManagedPolicyForCurrentUser'
)) {
    $definition = @($helperAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)) | Select-Object -First 1
    if ($null -eq $definition) { throw "User-integration helper is missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$scenarios = New-Object 'Collections.Generic.List[string]'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-user-integration-' + [Guid]::NewGuid().ToString('N'))
$junctions = New-Object 'Collections.Generic.List[string]'
try {
    $source = Join-Path $testRoot 'source'
    $destination = Join-Path $testRoot 'profile\.agents\skills\hyperv-test-executables'
    New-Item -ItemType Directory -Force -Path (Join-Path $source 'scripts'), (Join-Path $source 'empty'), $destination | Out-Null
    Set-Content -LiteralPath (Join-Path $source 'SKILL.md') -Value '# new runtime skill' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $source 'scripts\run.ps1') -Value 'Write-Output runtime' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $destination 'old.txt') -Value 'old' -Encoding UTF8
    $sourceFingerprint = Get-ContentTreeFingerprint -Root $source
    $installed = Install-RuntimeSkillForCurrentUser -Source $source -Destination $destination
    $destinationFingerprint = Get-ContentTreeFingerprint -Root $destination
    Assert-True ([bool]$installed.HashVerified -and [string]$installed.Fingerprint -ceq [string]$sourceFingerprint.Fingerprint) 'The transaction did not return the stable source fingerprint.'
    Assert-True ([string]$destinationFingerprint.Fingerprint -ceq [string]$sourceFingerprint.Fingerprint -and -not (Test-Path -LiteralPath (Join-Path $destination 'old.txt'))) 'The installed tree differs from source or retained stale content.'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $destination) -Force | Where-Object Name -like 'RuntimeSkill*').Count -eq 0) 'The successful transaction left residue.'
    Assert-True ($sourceFingerprint.Inventory -contains ("D`t" + 'empty')) 'The fingerprint omits empty directories.'
    $scenarios.Add('current-user-transaction-replaces-and-fingerprints-complete-tree')

    $fingerprintOnly = & $helperPath -SkillSourceRoot $source -TargetUserProfile (Join-Path $testRoot 'unused-profile') -TargetUserSid 'S-1-5-21-1-2-3-1001' -SkipGlobalPolicy -FingerprintOnly
    Assert-True ([string]$fingerprintOnly.SkillFingerprint -ceq [string]$sourceFingerprint.Fingerprint) 'FingerprintOnly accessed the profile or returned a different fingerprint.'
    $scenarios.Add('elevated-phase-verifies-protected-source-without-profile-access')

    $policySource = Join-Path $testRoot 'AGENTS.block.md'
    $policyDestination = Join-Path $testRoot 'policy-profile\.codex\AGENTS.md'
    $policyBlock = "<!-- BEGIN CODEX HYPERV TEST HARNESS -->`r`nnetwork policy`r`n<!-- END CODEX HYPERV TEST HARNESS -->"
    Set-Content -LiteralPath $policySource -Value $policyBlock -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $policyDestination) | Out-Null
    Set-Content -LiteralPath $policyDestination -Value 'preserve user content' -Encoding UTF8
    $policyFingerprint = Get-FileFingerprint -Path $policySource
    $policyResult = Install-ManagedPolicyForCurrentUser -BlockPath $policySource -Destination $policyDestination -ExpectedFingerprint $policyFingerprint
    $installedPolicy = Get-Content -Raw -LiteralPath $policyDestination
    Assert-True ([string]$policyResult.BlockFingerprint -ceq $policyFingerprint -and $installedPolicy.Contains('preserve user content') -and $installedPolicy.Contains('network policy')) 'The stable managed policy was not installed without preserving user content.'
    Set-Content -LiteralPath $policySource -Value ($policyBlock -replace 'network policy', 'changed policy') -Encoding UTF8
    Assert-Rejected 'changed managed policy source' 'changed before installation' {
        Install-ManagedPolicyForCurrentUser -BlockPath $policySource -Destination $policyDestination -ExpectedFingerprint $policyFingerprint | Out-Null
    }
    Assert-True ((Get-Content -Raw -LiteralPath $policyDestination).Contains('network policy')) 'A changed policy source modified the installed destination before rejection.'
    Set-Content -LiteralPath $policySource -Stream 'unexpected' -Value 'alternate' -Encoding UTF8
    Assert-Rejected 'policy alternate data stream' 'alternate data stream' { Get-FileFingerprint -Path $policySource | Out-Null }
    Remove-Item -LiteralPath $policySource -Stream 'unexpected' -ErrorAction Stop
    $scenarios.Add('managed-policy-source-is-stable-and-ads-free')

    Set-Content -LiteralPath (Join-Path $source 'SKILL.md') -Stream 'unexpected' -Value 'alternate' -Encoding UTF8
    Assert-Rejected 'alternate data stream' 'alternate data stream' { Get-ContentTreeFingerprint -Root $source | Out-Null }
    Remove-Item -LiteralPath (Join-Path $source 'SKILL.md') -Stream 'unexpected' -ErrorAction Stop
    $scenarios.Add('fingerprint-rejects-alternate-data-streams')

    $sourceTarget = Join-Path $testRoot 'source-target'
    $sourceLink = Join-Path $testRoot 'source-link'
    New-Item -ItemType Directory -Force -Path $sourceTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $sourceTarget 'SKILL.md') -Value '# linked source' -Encoding UTF8
    New-Item -ItemType Junction -Path $sourceLink -Target $sourceTarget | Out-Null
    [void]$junctions.Add($sourceLink)
    Assert-Rejected 'source junction' 'reparse point' { Install-RuntimeSkillForCurrentUser -Source $sourceLink -Destination (Join-Path $testRoot 'link-profile\.agents\skills\hyperv-test-executables') | Out-Null }
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $sourceTarget 'SKILL.md')).Trim() -eq '# linked source') 'Source-junction rejection modified its target.'
    $scenarios.Add('source-root-reparse-is-rejected')
    Remove-TestJunction $sourceLink
    [void]$junctions.Remove($sourceLink)

    $ancestorProfile = Join-Path $testRoot 'profile-ancestor'
    $ancestorTarget = Join-Path $testRoot 'ancestor-target'
    New-Item -ItemType Directory -Force -Path $ancestorProfile, $ancestorTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $ancestorTarget 'marker.txt') -Value 'keep' -Encoding UTF8
    $ancestorLink = Join-Path $ancestorProfile '.agents'
    New-Item -ItemType Junction -Path $ancestorLink -Target $ancestorTarget | Out-Null
    [void]$junctions.Add($ancestorLink)
    Assert-Rejected 'destination ancestor junction' 'reparse point' { Install-RuntimeSkillForCurrentUser -Source $source -Destination (Join-Path $ancestorProfile '.agents\skills\hyperv-test-executables') | Out-Null }
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $ancestorTarget 'marker.txt')).Trim() -eq 'keep') 'Ancestor-junction rejection modified its target.'
    $scenarios.Add('destination-ancestor-reparse-is-rejected')
    Remove-TestJunction $ancestorLink
    [void]$junctions.Remove($ancestorLink)

    $nestedDestination = Join-Path $testRoot 'profile-nested\.agents\skills\hyperv-test-executables'
    $nestedTarget = Join-Path $testRoot 'nested-target'
    New-Item -ItemType Directory -Force -Path $nestedDestination, $nestedTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $nestedTarget 'marker.txt') -Value 'keep' -Encoding UTF8
    $nestedLink = Join-Path $nestedDestination 'redirect'
    New-Item -ItemType Junction -Path $nestedLink -Target $nestedTarget | Out-Null
    [void]$junctions.Add($nestedLink)
    Assert-Rejected 'nested destination junction' 'reparse point' { Install-RuntimeSkillForCurrentUser -Source $source -Destination $nestedDestination | Out-Null }
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $nestedTarget 'marker.txt')).Trim() -eq 'keep') 'Nested-junction rejection modified its target.'
    $scenarios.Add('nested-destination-reparse-is-rejected')
    Remove-TestJunction $nestedLink
    [void]$junctions.Remove($nestedLink)

    $mutationSource = Join-Path $testRoot 'mutation-source'
    $mutationDestination = Join-Path $testRoot 'mutation-profile\.agents\skills\hyperv-test-executables'
    New-Item -ItemType Directory -Force -Path $mutationSource | Out-Null
    Set-Content -LiteralPath (Join-Path $mutationSource 'SKILL.md') -Value '# before' -Encoding UTF8
    $copyImplementation = ${function:Invoke-RobocopyMirror}
    $mutationMessage = & {
        param($Source, $Destination, $CopyImplementation)
        function Invoke-RobocopyMirror([string] $Source, [string] $Destination) {
            & $CopyImplementation -Source $Source -Destination $Destination
            Set-Content -LiteralPath (Join-Path $Source 'SKILL.md') -Value '# changed-during-copy' -Encoding UTF8
        }
        try { Install-RuntimeSkillForCurrentUser -Source $Source -Destination $Destination | Out-Null; $null } catch { $_.Exception.Message }
    } $mutationSource $mutationDestination $copyImplementation
    Assert-True ([string]$mutationMessage -like '*source changed while it was staged*' -and -not (Test-Path -LiteralPath $mutationDestination)) 'A changing source was installed or left a destination.'
    $scenarios.Add('source-mutation-is-detected-and-cleaned')

    $rollbackSource = Join-Path $testRoot 'rollback-source'
    $rollbackDestination = Join-Path $testRoot 'rollback-profile\.agents\skills\hyperv-test-executables'
    New-Item -ItemType Directory -Force -Path $rollbackSource, $rollbackDestination | Out-Null
    Set-Content -LiteralPath (Join-Path $rollbackSource 'SKILL.md') -Value '# replacement' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $rollbackDestination 'old.txt') -Value 'restore-me' -Encoding UTF8
    $fingerprintImplementation = ${function:Get-ContentTreeFingerprint}
    $rollbackMessage = & {
        param($Source, $Destination, $FingerprintImplementation)
        $injected = $false
        function Get-ContentTreeFingerprint([string] $Root) {
            if (-not $injected -and [string]::Equals([IO.Path]::GetFullPath($Root), [IO.Path]::GetFullPath($Destination), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath (Join-Path $Root 'SKILL.md') -PathType Leaf)) {
                $injected = $true
                throw 'injected final inventory failure'
            }
            & $FingerprintImplementation -Root $Root
        }
        try { Install-RuntimeSkillForCurrentUser -Source $Source -Destination $Destination | Out-Null; $null } catch { $_.Exception.Message }
    } $rollbackSource $rollbackDestination $fingerprintImplementation
    Assert-True ([string]$rollbackMessage -like '*injected final inventory failure*' -and (Test-Path -LiteralPath (Join-Path $rollbackDestination 'old.txt')) -and -not (Test-Path -LiteralPath (Join-Path $rollbackDestination 'SKILL.md'))) 'A final verification failure did not restore the old destination.'
    $scenarios.Add('final-verification-precedes-backup-retirement-and-rolls-back')

    Assert-True ($helperText.Contains('if (Test-Administrator)') -and $helperText.Contains('TargetUserSid must match the current unelevated user') -and $helperText.Contains('TargetUserProfile must match the current unelevated user profile')) 'The helper is not bound to the current unelevated user.'
    Assert-True ($installText.Contains('$profileArtifacts = & $userIntegrationScript') -and $installText.Contains('-ProfileArtifactsPrepared') -and $installText.Contains('-FingerprintOnly') -and $installText.Contains('Join-Path ([string]$layout.SkillSourceRoot)')) 'Install.ps1 does not use the prepared receipt and protected smoke runner.'
    Assert-True (-not $installText.Contains('function Install-RuntimeSkill') -and -not $installText.Contains('function Install-ManagedPolicyBlock')) 'Install.ps1 retains elevated profile deployment.'
    Assert-True ($updateText.Contains('$profileArtifacts = & $userIntegrationScript') -and $updateText.Contains('-ProfileArtifactsPrepared') -and $updateText.Contains('-FingerprintOnly') -and -not $updateText.Contains('function Install-RuntimeSkillTransactional')) 'Update-Images.ps1 does not use the current-user receipt boundary.'
    $scenarios.Add('elevated-install-and-update-skip-profile-deployment')
}
finally {
    foreach ($junction in @($junctions.ToArray())) { Remove-TestJunction $junction }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{ Success = $true; ScenarioCount = $scenarios.Count; Scenarios = $scenarios.ToArray() } | ConvertTo-Json -Depth 8
