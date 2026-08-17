[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-ExpectedFailure {
    param(
        [scriptblock] $Action,
        [string] $MessagePattern,
        [string] $Scenario
    )

    try {
        & $Action
        throw "Expected failure was not raised: $Scenario"
    }
    catch {
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "Unexpected failure for ${Scenario}: $($_.Exception.Message)"
        }
    }
}

$harnessRoot = Split-Path -Parent $PSScriptRoot
$softwareRoot = Split-Path -Parent $harnessRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $softwareRoot)
$setupRoot = Join-Path $repositoryRoot 'setup'
$wrapperPath = Join-Path $setupRoot 'Update-Images.ps1'
$wrapper = Get-Content -Raw -LiteralPath $wrapperPath
$scenarios = New-Object Collections.Generic.List[string]

$tokens = $null
$parseErrors = $null
$wrapperAst = [Management.Automation.Language.Parser]::ParseInput($wrapper, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Update-Images.ps1 did not parse: $($parseErrors[0].Message)" }

$requiredFunctions = @(
    'Assert-NoReparsePointChain',
    'Assert-NoAlternateDataStreams',
    'Assert-SourceTreeSafeForPrivilegedCopy',
    'Get-SourceTreeFingerprint',
    'Get-PreparedSourceFingerprint'
)
$functionAsts = @($wrapperAst.FindAll({
        param($candidate)
        $candidate -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true))
$functionText = New-Object Collections.Generic.List[string]
foreach ($functionName in $requiredFunctions) {
    $functionAst = $functionAsts | Where-Object { $_.Name -eq $functionName } | Select-Object -First 1
    if ($null -eq $functionAst) { throw "Update-Images.ps1 is missing source-protection function: $functionName" }
    [void]$functionText.Add($functionAst.Extent.Text)
}

foreach ($contract in @(
    'PreparedSourceFingerprint',
    "'-PreparedSourceFingerprint', `$PreparedSourceFingerprint",
    'Assert-NoReparsePointChain -Path $InstallRoot',
    'Assert-NoAlternateDataStreams -Path $InstallRoot',
    'Assert-SourceTreeSafeForPrivilegedCopy -Path $checkoutSoftware',
    'Assert-SourceTreeSafeForPrivilegedCopy -Path $PSScriptRoot',
    'Invoke-Robocopy -Source $checkoutSoftware',
    "Invoke-Robocopy -Source `$PSScriptRoot -Destination `$installedSetup",
    "Get-PreparedSourceFingerprint -SoftwareRoot `$installedSoftware -SetupRoot `$installedSetup",
    'The staged Software/Setup source changed between unelevated preparation and elevation.',
    'Protect-StagedSourceTree -Path $installedSoftware',
    'Protect-StagedSourceTree -Path $installedSetup',
    "Join-Path `$installedSetup 'Watch-ImageUpdateLauncher.ps1'",
    'SYSTEM+Administrators-only ACL',
    'Prepared runtime skill does not match the sanitized source staged for elevated image maintenance.'
)) {
    Assert-True ($wrapper.IndexOf($contract, [StringComparison]::Ordinal) -ge 0) "Wrapper is missing source-protection contract: $contract"
}
$scenarios.Add('wrapper-source-protection-contract-is-present')

$aclClientRx = '"$client`:(OI)(CI)(RX)"'
$aclClientFull = '"$client`:(OI)(CI)(F)"'
Assert-True $wrapper.Contains($aclClientRx) 'TargetUserSid is not granted recursive read/execute on staged source.'
Assert-True (-not $wrapper.Contains($aclClientFull)) 'TargetUserSid is granted full control on staged source.'
Assert-True ($wrapper.Contains("'*S-1-5-18:(OI)(CI)(F)'") -and $wrapper.Contains("'*S-1-5-32-544:(OI)(CI)(F)'") ) 'SYSTEM and Administrators are not granted full control on staged source.'
$scenarios.Add('staged-source-acl-gives-client-read-execute-only')

$planPosition = $wrapper.IndexOf('if ($PlanOnly)', [StringComparison]::Ordinal)
$elevationPosition = $wrapper.IndexOf('if (-not (Test-Administrator))', $planPosition + 1, [StringComparison]::Ordinal)
$receiptGuardPosition = $wrapper.IndexOf('if (-not $ProfileArtifactsPrepared', $elevationPosition + 1, [StringComparison]::Ordinal)
$sourceInventoryPosition = $wrapper.IndexOf('[void](Assert-SourceTreeSafeForPrivilegedCopy -Path $checkoutSoftware)', [StringComparison]::Ordinal)
$publicAuditPosition = $wrapper.IndexOf('$publicAudit = & (Join-Path $PSScriptRoot ''Test-PublicRepository.ps1'')', [StringComparison]::Ordinal)
$elevationProcessPosition = $wrapper.IndexOf("Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-ElevationArguments)", [StringComparison]::Ordinal)
Assert-True ($planPosition -ge 0 -and $elevationPosition -gt $planPosition) 'PlanOnly does not remain before elevation.'
Assert-True ($sourceInventoryPosition -ge 0 -and $publicAuditPosition -gt $sourceInventoryPosition -and $publicAuditPosition -gt $elevationPosition -and $elevationProcessPosition -gt $publicAuditPosition) 'Checkout source is not inventoried before the unelevated audit/elevation boundary.'
Assert-True ($receiptGuardPosition -gt $elevationProcessPosition) 'Elevated phase does not require the unelevated profile/source receipt.'
$scenarios.Add('plan-and-unelevated-receipt-order-is-preserved')

$stageSoftwarePosition = $wrapper.IndexOf('Invoke-Robocopy -Source $checkoutSoftware', $receiptGuardPosition, [StringComparison]::Ordinal)
$stageSetupPosition = $wrapper.IndexOf("Invoke-Robocopy -Source `$PSScriptRoot -Destination `$installedSetup", $stageSoftwarePosition, [StringComparison]::Ordinal)
$stagedFingerprintPosition = $wrapper.IndexOf('$stagedSourceFingerprint = Get-PreparedSourceFingerprint', $stageSetupPosition, [StringComparison]::Ordinal)
$protectSoftwarePosition = $wrapper.IndexOf('Protect-StagedSourceTree -Path $installedSoftware', $stagedFingerprintPosition, [StringComparison]::Ordinal)
$protectSetupPosition = $wrapper.IndexOf('Protect-StagedSourceTree -Path $installedSetup', $protectSoftwarePosition, [StringComparison]::Ordinal)
$watcherPathPosition = $wrapper.IndexOf("$watcherPath = Join-Path `$installedSetup 'Watch-ImageUpdateLauncher.ps1'", $protectSetupPosition, [StringComparison]::Ordinal)
$watcherStartPosition = $wrapper.IndexOf('$launcherWatchdog = Start-Process', $watcherPathPosition, [StringComparison]::Ordinal)
$childScriptPosition = $wrapper.IndexOf("$canaries = @(& (Join-Path `$installedSetup 'Build-Canaries.ps1')", $watcherStartPosition, [StringComparison]::Ordinal)
$updatePosition = $wrapper.IndexOf('$result = & (Join-Path $installedSoftware', $childScriptPosition, [StringComparison]::Ordinal)
Assert-True ($stageSoftwarePosition -gt $receiptGuardPosition -and
    $stageSetupPosition -gt $stageSoftwarePosition -and
    $stagedFingerprintPosition -gt $stageSetupPosition -and
    $protectSoftwarePosition -gt $stagedFingerprintPosition -and
    $protectSetupPosition -gt $protectSoftwarePosition -and
    $watcherPathPosition -gt $protectSetupPosition -and
    $watcherStartPosition -gt $watcherPathPosition -and
    $childScriptPosition -gt $watcherStartPosition -and
    $updatePosition -gt $childScriptPosition) 'A newly staged child script or watcher can run before exact fingerprint verification and ACL protection.'
Assert-True (-not $wrapper.Contains("Join-Path `$PSScriptRoot 'Watch-ImageUpdateLauncher.ps1'")) 'The elevated watchdog still runs from mutable checkout setup.'
$auditInvocationCount = @([regex]::Matches($wrapper, 'Test-PublicRepository\.ps1')).Count
Assert-True ($auditInvocationCount -eq 1 -and $wrapper.IndexOf('Test-PublicRepository.ps1', $elevationProcessPosition, [StringComparison]::Ordinal) -lt 0) 'Test-PublicRepository.ps1 is invoked from the mutable checkout after elevation.'
$scenarios.Add('staging-fingerprint-acl-watchdog-and-child-order-is-protected')

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-update-wrapper-source-' + [Guid]::NewGuid().ToString('N'))
try {
    $sourceSoftware = Join-Path $temporaryRoot 'source\Software'
    $sourceSetup = Join-Path $temporaryRoot 'source\setup'
    $stagedSoftware = Join-Path $temporaryRoot 'staged\Software'
    $stagedSetup = Join-Path $temporaryRoot 'staged\Setup'
    foreach ($path in @(
        (Join-Path $sourceSoftware 'Harness'),
        (Join-Path $sourceSoftware 'generated'),
        (Join-Path $sourceSoftware 'private'),
        (Join-Path $sourceSoftware 'seed-build'),
        (Join-Path $sourceSoftware 'Setup'),
        (Join-Path $sourceSetup 'artifacts'),
        $stagedSoftware,
        $stagedSetup
    )) { New-Item -ItemType Directory -Force -Path $path | Out-Null }

    Set-Content -LiteralPath (Join-Path $sourceSoftware 'Harness\Included.ps1') -Value 'included-v1' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sourceSoftware 'generated\ignored.txt') -Value 'source-generated' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sourceSoftware 'private\ignored.txt') -Value 'source-private' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sourceSoftware 'seed-build\ignored.txt') -Value 'source-seed-build' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sourceSoftware 'Setup\ignored.txt') -Value 'source-nested-setup' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sourceSetup 'Watch-ImageUpdateLauncher.ps1') -Value 'setup-v1' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sourceSetup 'artifacts\ignored.txt') -Value 'source-artifact' -Encoding UTF8

    function Copy-TreeContents {
        param([string] $Source, [string] $Destination)
        foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force
        }
    }
    Copy-TreeContents -Source (Join-Path $temporaryRoot 'source\Software') -Destination $stagedSoftware
    Copy-TreeContents -Source (Join-Path $temporaryRoot 'source\setup') -Destination $stagedSetup
    Set-Content -LiteralPath (Join-Path $stagedSoftware 'generated\ignored.txt') -Value 'staged-generated' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $stagedSoftware 'private\ignored.txt') -Value 'staged-private' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $stagedSoftware 'seed-build\ignored.txt') -Value 'staged-seed-build' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $stagedSoftware 'Setup\ignored.txt') -Value 'staged-nested-setup' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $stagedSetup 'artifacts\ignored.txt') -Value 'staged-artifact' -Encoding UTF8

    Invoke-Expression ($functionText -join "`n")
    $sourceFingerprint = Get-PreparedSourceFingerprint -SoftwareRoot $sourceSoftware -SetupRoot $sourceSetup
    $stagedFingerprint = Get-PreparedSourceFingerprint -SoftwareRoot $stagedSoftware -SetupRoot $stagedSetup
    Assert-True ([string]::Equals($sourceFingerprint, $stagedFingerprint, [StringComparison]::OrdinalIgnoreCase)) 'Equivalent staged source shapes produced different prepared fingerprints.'
    $scenarios.Add('prepared-source-fingerprint-equals-across-sanitized-staging-shapes')

    Set-Content -LiteralPath (Join-Path $stagedSoftware 'Harness\Included.ps1') -Value 'included-v2' -Encoding UTF8
    $changedFingerprint = Get-PreparedSourceFingerprint -SoftwareRoot $stagedSoftware -SetupRoot $stagedSetup
    Assert-True (-not [string]::Equals($sourceFingerprint, $changedFingerprint, [StringComparison]::OrdinalIgnoreCase)) 'A changed included source file did not change the prepared fingerprint.'
    $scenarios.Add('prepared-source-fingerprint-rejects-included-mismatch')

    $junctionPath = Join-Path $sourceSoftware 'Harness\reparse'
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target (Join-Path $temporaryRoot 'source') -ErrorAction Stop | Out-Null
        $junctionCreated = $true
        Assert-ExpectedFailure -Scenario 'source reparse point' -MessagePattern 'reparse point' -Action { Assert-SourceTreeSafeForPrivilegedCopy -Path $sourceSoftware | Out-Null }
        $scenarios.Add('source-reparse-point-is-rejected')
    }
    catch [System.Management.Automation.ItemNotFoundException] { }
    catch [System.UnauthorizedAccessException] { }
    finally {
        if ($junctionCreated) {
            try {
                $junctionItem = Get-Item -LiteralPath $junctionPath -Force -ErrorAction Stop
                if (($junctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $junctionItem.Delete($false) }
            }
            catch { }
        }
    }

    $setContentCommand = Get-Command Set-Content -ErrorAction Stop
    if ($setContentCommand.Parameters.ContainsKey('Stream')) {
        $adsPath = Join-Path $sourceSoftware 'Harness\Included.ps1'
        Set-Content -LiteralPath $adsPath -Stream 'codex-test' -Value 'ads' -Encoding UTF8
        try {
            Assert-ExpectedFailure -Scenario 'source alternate data stream' -MessagePattern 'alternate data stream' -Action { Assert-SourceTreeSafeForPrivilegedCopy -Path $sourceSoftware | Out-Null }
            $scenarios.Add('source-alternate-data-stream-is-rejected')
        }
        finally {
            Remove-Item -LiteralPath $adsPath -Stream 'codex-test' -ErrorAction SilentlyContinue
        }
    }
    else {
        $scenarios.Add('source-alternate-data-stream-guard-is-source-asserted')
    }
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
