[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)] [string] $Text,
        [Parameter(Mandatory = $true)] [string] $Needle,
        [Parameter(Mandatory = $true)] [string] $Message
    )

    Assert-Contract -Condition ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) -Message $Message
}

$recoveryRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$softwareRoot = Split-Path -Parent $recoveryRoot
$harnessRoot = Join-Path $softwareRoot 'Harness'
$installerPath = Join-Path $recoveryRoot 'Install-CodexHyperVHarness.ps1'
$verifierPath = Join-Path $recoveryRoot 'Test-CodexHyperVRecovery.ps1'
$commonPath = Join-Path $recoveryRoot 'RecoveryCommon.ps1'
$userIntegrationPath = Join-Path $softwareRoot 'UserIntegration\Install-CodexUserIntegration.ps1'
$installer = Get-Content -Raw -LiteralPath $installerPath
$verifier = Get-Content -Raw -LiteralPath $verifierPath
$userIntegration = Get-Content -Raw -LiteralPath $userIntegrationPath
$scenarios = New-Object Collections.Generic.List[string]

foreach ($path in @($installerPath, $verifierPath, $commonPath, $userIntegrationPath, $PSCommandPath)) {
    $tokens = $null
    $parseIssues = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseIssues)
    Assert-Contract -Condition ($parseIssues.Count -eq 0) -Message "PowerShell parse failure in $path"
}
$scenarios.Add('owned-recovery-sources-parse')

$installerTokens = $null
$installerParseIssues = $null
$installerAst = [Management.Automation.Language.Parser]::ParseInput($installer, [ref]$installerTokens, [ref]$installerParseIssues)
Assert-Contract -Condition ($installerParseIssues.Count -eq 0) -Message 'Recovery installer AST parsing failed.'
$manifestPathFunctions = @($installerAst.FindAll({
        param($candidate)
        $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $candidate.Name -in @('Assert-RecoveryNoAlternateDataStream', 'Resolve-RecoveryManifestPath')
    }, $true))
Assert-Contract -Condition ($manifestPathFunctions.Count -eq 2) -Message 'Recovery installer is missing its manifest path-validation functions.'
$manifestPathValidator = [ScriptBlock]::Create((@($manifestPathFunctions | ForEach-Object { $_.Extent.Text }) -join "`n") + "`nResolve-RecoveryManifestPath -Root `$args[0] -RelativePath `$args[1] -FieldName 'contract' -RequireLeaf")
$manifestTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-recovery-manifest-contract-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $manifestTestRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $manifestTestRoot 'safe.txt') -Value 'safe' -Encoding UTF8
    $maliciousManifestPaths = @('..\outside.txt', 'C:\outside.txt', '\\server\share\outside.txt', '/absolute.txt', 'safe.txt:evil', 'nested\..\safe.txt')
    foreach ($maliciousPath in $maliciousManifestPaths) {
        $rejected = $false
        try { & $manifestPathValidator $manifestTestRoot $maliciousPath | Out-Null } catch { $rejected = $true }
        Assert-Contract -Condition $rejected -Message "Manifest validator accepted malicious path '$maliciousPath'."
    }
    $safePath = & $manifestPathValidator $manifestTestRoot 'safe.txt'
    Assert-Contract -Condition ([string]::Equals([IO.Path]::GetFullPath($safePath), [IO.Path]::GetFullPath((Join-Path $manifestTestRoot 'safe.txt')), [StringComparison]::OrdinalIgnoreCase)) -Message 'Manifest validator rejected a safe child path.'
}
finally {
    Remove-Item -LiteralPath $manifestTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$scenarios.Add('malicious-manifest-relative-paths-are-rejected')

$bootstrapFunctionNames = @('Assert-RecoveryNoAlternateDataStream', 'Assert-RecoveryNoReparseChain', 'Resolve-RecoveryManifestPath', 'Assert-RecoveryBootstrapManifestEntry')
$bootstrapFunctions = @($installerAst.FindAll({
        param($candidate)
        $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -in $bootstrapFunctionNames
    }, $true))
Assert-Contract -Condition ($bootstrapFunctions.Count -eq $bootstrapFunctionNames.Count) -Message 'Recovery installer is missing bootstrap manifest-consistency functions.'
$bootstrapScript = [ScriptBlock]::Create((@($bootstrapFunctions | Sort-Object { $bootstrapFunctionNames.IndexOf($_.Name) } | ForEach-Object { $_.Extent.Text }) -join "`n") + "`nAssert-RecoveryBootstrapManifestEntry -Root `$args[0] -Manifest `$args[1]")
$bootstrapTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-recovery-bootstrap-contract-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $bootstrapTestRoot | Out-Null
    $bootstrapPath = Join-Path $bootstrapTestRoot 'RecoveryCommon.ps1'
    Set-Content -LiteralPath $bootstrapPath -Value 'function Test-RecoveryBootstrap { $true }' -Encoding UTF8
    $bootstrapItem = Get-Item -LiteralPath $bootstrapPath -Force
    $bootstrapEntry = [pscustomobject][ordered]@{
        RelativePath = 'RecoveryCommon.ps1'
        Length = [long]$bootstrapItem.Length
        Sha256 = (Get-FileHash -LiteralPath $bootstrapPath -Algorithm SHA256).Hash
    }
    $bootstrapManifest = [pscustomobject]@{ Files = @($bootstrapEntry) }
    [void](& $bootstrapScript $bootstrapTestRoot $bootstrapManifest)

    $duplicateManifest = [pscustomobject]@{ Files = @($bootstrapEntry, $bootstrapEntry) }
    $duplicateRejected = $false
    try { & $bootstrapScript $bootstrapTestRoot $duplicateManifest | Out-Null } catch { $duplicateRejected = $true }
    Assert-Contract -Condition $duplicateRejected -Message 'Bootstrap verifier accepted duplicate RecoveryCommon.ps1 entries.'

    $missingManifest = [pscustomobject]@{ Files = @() }
    $missingRejected = $false
    try { & $bootstrapScript $bootstrapTestRoot $missingManifest | Out-Null } catch { $missingRejected = $true }
    Assert-Contract -Condition $missingRejected -Message 'Bootstrap verifier accepted a manifest without RecoveryCommon.ps1.'

    Add-Content -LiteralPath $bootstrapPath -Value 'drift' -Encoding UTF8
    $driftRejected = $false
    try { & $bootstrapScript $bootstrapTestRoot $bootstrapManifest | Out-Null } catch { $driftRejected = $true }
    Assert-Contract -Condition $driftRejected -Message 'Bootstrap verifier accepted a changed RecoveryCommon.ps1 payload.'
}
finally {
    Remove-Item -LiteralPath $bootstrapTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$scenarios.Add('bootstrap-manifest-entry-size-hash-and-duplicate-proof-is-executable')

$treeFunctionNames = @('Assert-RecoveryNoAlternateDataStream', 'Assert-RecoveryNoReparseChain', 'Assert-RecoveryTreeNoReparse', 'Get-RecoveryFileFingerprint', 'Get-RecoveryTreeFingerprint')
$treeFunctions = @($installerAst.FindAll({
        param($candidate)
        $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -in $treeFunctionNames
    }, $true))
Assert-Contract -Condition ($treeFunctions.Count -eq $treeFunctionNames.Count) -Message 'Recovery installer is missing executable tree-fingerprint functions.'
$treeFingerprintScript = [ScriptBlock]::Create((@($treeFunctions | Sort-Object { $treeFunctionNames.IndexOf($_.Name) } | ForEach-Object { $_.Extent.Text }) -join "`n") + "`nif (`$args[1] -eq 'File') { Get-RecoveryFileFingerprint -Path `$args[0] } else { Get-RecoveryTreeFingerprint -Path `$args[0] }")
$treeTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-recovery-tree-contract-' + [Guid]::NewGuid().ToString('N'))
try {
    $sourceTree = Join-Path $treeTestRoot 'source'
    $destinationTree = Join-Path $treeTestRoot 'destination'
    $sourceNested = Join-Path $sourceTree 'nested'
    $destinationNested = Join-Path $destinationTree 'nested'
    New-Item -ItemType Directory -Force -Path $sourceNested, $destinationNested | Out-Null
    Set-Content -LiteralPath (Join-Path $sourceTree 'payload.txt') -Value 'payload' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sourceNested 'child.txt') -Value 'child' -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $sourceTree 'payload.txt') -Destination $destinationTree -Force
    Copy-Item -LiteralPath (Join-Path $sourceNested 'child.txt') -Destination $destinationNested -Force
    $sourceFingerprint = & $treeFingerprintScript $sourceTree 'Tree'
    $destinationFingerprint = & $treeFingerprintScript $destinationTree 'Tree'
    Assert-Contract -Condition ([string]::Equals([string]$sourceFingerprint, [string]$destinationFingerprint, [StringComparison]::OrdinalIgnoreCase)) -Message 'Recovery tree fingerprint rejected an identical temp-tree copy.'

    Add-Content -LiteralPath (Join-Path $destinationNested 'child.txt') -Value 'destination-drift' -Encoding UTF8
    $destinationMismatch = & $treeFingerprintScript $destinationTree 'Tree'
    Assert-Contract -Condition (-not [string]::Equals([string]$sourceFingerprint, [string]$destinationMismatch, [StringComparison]::OrdinalIgnoreCase)) -Message 'Recovery tree fingerprint missed destination content drift.'

    Set-Content -LiteralPath (Join-Path $destinationNested 'child.txt') -Value 'child' -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $sourceTree 'payload.txt') -Value 'source-drift' -Encoding UTF8
    $sourceDriftFingerprint = & $treeFingerprintScript $sourceTree 'Tree'
    Assert-Contract -Condition (-not [string]::Equals([string]$sourceFingerprint, [string]$sourceDriftFingerprint, [StringComparison]::OrdinalIgnoreCase)) -Message 'Recovery tree fingerprint missed source drift between staging checks.'

    $policySource = Join-Path $treeTestRoot 'policy-source.md'
    $policyDestination = Join-Path $treeTestRoot 'policy-destination.md'
    Set-Content -LiteralPath $policySource -Value 'policy' -Encoding UTF8
    Copy-Item -LiteralPath $policySource -Destination $policyDestination -Force
    $policySourceFingerprint = & $treeFingerprintScript $policySource 'File'
    $policyDestinationFingerprint = & $treeFingerprintScript $policyDestination 'File'
    Assert-Contract -Condition ([string]::Equals([string]$policySourceFingerprint, [string]$policyDestinationFingerprint, [StringComparison]::OrdinalIgnoreCase)) -Message 'Recovery policy fingerprint rejected an identical copied policy.'
    Add-Content -LiteralPath $policyDestination -Value 'policy-drift' -Encoding UTF8
    $policyMismatch = & $treeFingerprintScript $policyDestination 'File'
    Assert-Contract -Condition (-not [string]::Equals([string]$policySourceFingerprint, [string]$policyMismatch, [StringComparison]::OrdinalIgnoreCase)) -Message 'Recovery policy fingerprint missed destination drift.'
}
finally {
    Remove-Item -LiteralPath $treeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$scenarios.Add('recovery-tree-and-policy-fingerprint-equality-mismatch-source-drift-are-executable')

foreach ($required in @(
        'Assert-RecoveryNoReparseChain',
        'Resolve-RecoveryManifestPath',
        'Read-RecoveryManifestSafely',
        'Assert-RecoveryBootstrapManifestEntry',
        'Get-RecoveryTreeFingerprint',
        'Get-RecoveryFileFingerprint',
        '$softwareSourceFingerprintBefore',
        '$softwareSourceFingerprintAfter',
        '$softwareStageFingerprint',
        '$policySourceFingerprintBefore',
        '$policyStageFingerprint',
        'The recovery Software source changed while it was being staged.',
        'The staged recovery Software tree does not exactly match its source.',
        'The staged recovery Codex policy does not exactly match its source.',
        'Files[].RelativePath',
        'ConfigRelativePath',
        'ExportedVmConfiguration',
        'Unregister-RecoveryResumeTaskIfOwned',
        '$script:resumeHandoffCommitted = $true',
        'Register-RecoveryResumeTask'
    )) {
    Assert-Contains -Text $installer -Needle $required -Message "Recovery installer is missing hardening contract: $required"
}
$bootstrapPosition = $installer.IndexOf('$recoveryCommonPath = Assert-RecoveryBootstrapManifestEntry', [StringComparison]::Ordinal)
$commonDotSourcePosition = $installer.IndexOf('. $recoveryCommonPath', $bootstrapPosition, [StringComparison]::Ordinal)
Assert-Contract -Condition ($bootstrapPosition -ge 0 -and $commonDotSourcePosition -gt $bootstrapPosition) -Message 'RecoveryCommon.ps1 is dot-sourced before bootstrap manifest consistency verification.'
$scenarios.Add('manifest-containment-and-resume-cleanup-contract-is-present')

foreach ($forbidden in @('Invoke-CodexRobocopy', '/MIR', 'NTUSER.DAT', 'reg.exe load', 'reg.exe unload', '.agents\skills\hyperv-test-executables', '.codex\AGENTS.md')) {
    Assert-Contract -Condition ($installer.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -lt 0) -Message "Recovery installer still contains forbidden elevated/profile operation: $forbidden"
}
$scenarios.Add('elevated-installer-has-no-profile-mirror-or-hive-load')

foreach ($required in @(
        '[switch] $ProfileArtifactsPrepared',
        '[string] $PreparedSkillFingerprint',
        '[string] $PreparedPolicyFingerprint',
        '$profileArtifacts = & $userIntegrationScript',
        '-ProfileArtifactsPrepared',
        '-PreparedSkillFingerprint',
        '-PreparedPolicyFingerprint',
        '-FingerprintOnly',
        'Copy-RecoverySourceTree',
        'Protect-RecoverySourceTree',
        'Prepared user-profile artifacts do not match the protected recovery sources staged for elevation.'
    )) {
    Assert-Contains -Text $installer -Needle $required -Message "Recovery installer is missing receipt/source contract: $required"
}
$scenarios.Add('receipt-and-protected-source-contract-is-present')

foreach ($required in @(
        'Assert-RecoveryTreeNoReparse',
        '.CodexHarnessSoftwareStage-',
        '.CodexHarnessSoftwareBackup-',
        '[IO.Directory]::Move($softwareStage, $softwareRoot)',
        '$softwareSourceCommitted = $true',
        'Recovery source installation failed and rollback remains incomplete.'
    )) {
    Assert-Contains -Text $installer -Needle $required -Message "Recovery source replacement is not an exact staged/rollback transaction: $required"
}
$scenarios.Add('recovery-source-tree-is-staged-exactly-and-rollback-safe')

$adminPosition = $installer.IndexOf('if (-not (Test-CodexAdministrator))', [StringComparison]::Ordinal)
$profilePreparationPosition = $installer.IndexOf('$profileArtifacts = & $userIntegrationScript', [StringComparison]::Ordinal)
$runOncePosition = $installer.IndexOf('Register-RecoveryResultRunOnceForCurrentUser', $profilePreparationPosition, [StringComparison]::Ordinal)
$elevationPosition = $installer.IndexOf("Start-Process -FilePath 'powershell.exe'", $profilePreparationPosition, [StringComparison]::Ordinal)
$elevatedGuardPosition = $installer.IndexOf('if (-not $ProfileArtifactsPrepared', $elevationPosition, [StringComparison]::Ordinal)
$sourceStagePosition = $installer.IndexOf('Copy-RecoverySourceTree -Source', $elevatedGuardPosition, [StringComparison]::Ordinal)
$sourceFingerprintPosition = $installer.IndexOf('$preparedSource = & $installedUserIntegrationScript', $sourceStagePosition, [StringComparison]::Ordinal)
$smokePosition = $installer.IndexOf('$runner = Join-Path $softwareRoot ''Skill\scripts\Invoke-HyperVExecutableTest.ps1''', $sourceFingerprintPosition, [StringComparison]::Ordinal)
Assert-Contract -Condition ($adminPosition -ge 0 -and $profilePreparationPosition -gt $adminPosition -and $runOncePosition -gt $profilePreparationPosition -and $elevationPosition -gt $runOncePosition -and $elevatedGuardPosition -gt $elevationPosition -and $sourceStagePosition -gt $elevatedGuardPosition -and $sourceFingerprintPosition -gt $sourceStagePosition -and $smokePosition -gt $sourceFingerprintPosition) -Message 'Recovery installation does not order unelevated profile preparation, elevation/resume receipt validation, protected staging, fingerprint verification, and smoke correctly.'
$scenarios.Add('unelevated-preparation-precedes-elevated-work')

Assert-Contains -Text $installer -Needle "`$runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'" -Message 'Recovery result RunOnce is not registered only in the target user context.'
Assert-Contains -Text $installer -Needle 'Unregister-RecoveryResultRunOnceForCurrentUser' -Message 'Recovery does not retire an unused result RunOnce entry.'
Assert-Contains -Text $installer -Needle '[int]$elevatedExitCode -ne 3010' -Message 'Recovery does not retain RunOnce only for an explicitly deferred restart.'
$scenarios.Add('runonce-is-current-user-and-restart-scoped')

$resumePosition = $installer.IndexOf('function Register-RecoveryResumeTask', [StringComparison]::Ordinal)
$resumeArgumentsPosition = $installer.IndexOf('-PreparedPolicyFingerprint $PreparedPolicyFingerprint', $resumePosition, [StringComparison]::Ordinal)
Assert-Contract -Condition ($resumePosition -ge 0 -and $resumeArgumentsPosition -gt $resumePosition) -Message 'Recovery resume task does not carry the prepared profile receipt.'
$scenarios.Add('resume-forwards-receipt')

Assert-Contains -Text $installer -Needle '$runner = Join-Path $softwareRoot ''Skill\scripts\Invoke-HyperVExecutableTest.ps1''' -Message 'Recovery smoke does not run from the protected staged skill source.'
Assert-Contract -Condition ($installer.IndexOf('$runner = Join-Path $TargetUserProfile', [StringComparison]::Ordinal) -lt 0) -Message 'Recovery smoke still runs from the target-user profile.'
$scenarios.Add('smoke-runs-from-protected-source')

foreach ($requiredRecoveryPath in @(
        'Software\UserIntegration\Install-CodexUserIntegration.ps1',
        'Software\Skill\scripts\Invoke-HyperVExecutableTest.ps1',
        'Software\Harness\RequestNetwork.ps1',
        'Software\Harness\tests\Test-RequestNetworkPropagation.ps1',
        'Software\Harness\tests\Test-RequestNetworkSafety.ps1',
        'Software\Harness\tests\Test-InstallRuntimeSkillTransaction.ps1',
        'Software\Harness\tests\Test-RunnerContractValidation.ps1',
        'Software\Recovery\Test-RecoveryInstallContract.ps1'
    )) {
    Assert-Contains -Text $verifier -Needle ("'" + $requiredRecoveryPath + "'") -Message "Recovery verifier does not require $requiredRecoveryPath."
}
$scenarios.Add('recovery-bundle-requires-user-integration-and-network-sources')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
