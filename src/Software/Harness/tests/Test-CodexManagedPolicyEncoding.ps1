[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$harnessRoot = Split-Path -Parent $PSScriptRoot
$softwareRoot = Split-Path -Parent $harnessRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $softwareRoot)
$helperPath = Join-Path $softwareRoot 'Common\CodexManagedPolicy.ps1'
$canonicalPolicyPath = Join-Path $repositoryRoot 'setup\AGENTS.block.md'
$obsoleteRecoveryPolicyPath = Join-Path $softwareRoot 'Recovery\CodexPolicy.md'
$installPath = Join-Path $repositoryRoot 'setup\Install.ps1'
$publicAuditPath = Join-Path $repositoryRoot 'setup\Test-PublicRepository.ps1'
$recoveryBuilderPath = Join-Path $softwareRoot 'Recovery\New-CodexHyperVRecovery.ps1'
$recoveryInstallPath = Join-Path $softwareRoot 'Recovery\Install-CodexHyperVHarness.ps1'
$recoveryVerifierPath = Join-Path $softwareRoot 'Recovery\Test-CodexHyperVRecovery.ps1'

foreach ($requiredPath in @($helperPath, $canonicalPolicyPath, $installPath, $publicAuditPath, $recoveryBuilderPath, $recoveryInstallPath, $recoveryVerifierPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Managed policy test input is missing: $requiredPath" }
}
if (Test-Path -LiteralPath $obsoleteRecoveryPolicyPath) { throw "The obsolete duplicate recovery policy still exists: $obsoleteRecoveryPolicyPath" }
. $helperPath

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-TestBytesEqual {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [byte[]] $Actual,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [byte[]] $Expected,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not (Test-CodexByteArrayEqual -Left $Actual -Right $Expected)) { throw $Message }
}

function Assert-TestByteSegment {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [byte[]] $Actual,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [byte[]] $Expected,
        [Parameter(Mandatory = $true)] [int] $Offset,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if ($Offset -lt 0 -or ($Offset + $Expected.Length) -gt $Actual.Length) { throw $Message }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Actual[$Offset + $index] -ne $Expected[$index]) { throw $Message }
    }
}

function ConvertTo-TestUtf8Bytes {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Text,
        [switch] $IncludeBom
    )
    [byte[]]$payload = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($Text)
    if (-not $IncludeBom) { return ,$payload }
    [byte[]]$withBom = New-Object byte[] ($payload.Length + 3)
    $withBom[0] = 0xEF
    $withBom[1] = 0xBB
    $withBom[2] = 0xBF
    if ($payload.Length -gt 0) { [Array]::Copy($payload, 0, $withBom, 3, $payload.Length) }
    ,$withBom
}

function Write-TestUtf8File {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Text,
        [switch] $IncludeBom
    )
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)))
    [byte[]]$bytes = ConvertTo-TestUtf8Bytes -Text $Text -IncludeBom:$IncludeBom
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-TestLiteralCount {
    param(
        [Parameter(Mandatory = $true)] [string] $Text,
        [Parameter(Mandatory = $true)] [string] $Literal
    )
    [regex]::Matches($Text, [regex]::Escape($Literal)).Count
}

function Assert-RejectedWithoutChange {
    param(
        [Parameter(Mandatory = $true)] [string] $Scenario,
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ExpectedMessage,
        [Parameter(Mandatory = $true)] [scriptblock] $Operation
    )

    [byte[]]$before = [IO.File]::ReadAllBytes($Path)
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
    [byte[]]$after = [IO.File]::ReadAllBytes($Path)
    Assert-TestBytesEqual -Actual $after -Expected $before -Message "Scenario '$Scenario' changed the target after rejecting it."
}

$startMarker = '<!-- BEGIN CODEX HYPERV TEST HARNESS -->'
$endMarker = '<!-- END CODEX HYPERV TEST HARNESS -->'
$iterations = 20
$scenarios = New-Object Collections.Generic.List[string]
$canonicalPolicy = Read-CodexStrictUtf8File -Path $canonicalPolicyPath
$canonicalBlock = $canonicalPolicy.Text.Trim()
Assert-True ($canonicalBlock.StartsWith($startMarker, [StringComparison]::Ordinal) -and
    $canonicalBlock.EndsWith($endMarker, [StringComparison]::Ordinal) -and
    (Get-TestLiteralCount -Text $canonicalBlock -Literal $startMarker) -eq 1 -and
    (Get-TestLiteralCount -Text $canonicalBlock -Literal $endMarker) -eq 1) 'The canonical public policy is not exactly one complete managed marker block.'
Assert-True ($canonicalBlock.IndexOf('prefer the guarded host controller provided by `hyperv-test-executables` over general computer-use tools', [StringComparison]::Ordinal) -ge 0) 'The canonical public policy does not resolve host-control routing before general computer use.'
foreach ($forbiddenPersonalText in @('## Working agreements', 'Always publish sites', 'Release computer use', 'C:\Users\')) {
    Assert-True ($canonicalBlock.IndexOf($forbiddenPersonalText, [StringComparison]::OrdinalIgnoreCase) -lt 0) "The canonical public policy contains personal/global content: $forbiddenPersonalText"
}
$scenarios.Add('one-public-harness-only-policy-fragment')
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempParent ('CodexManagedPolicy-' + [Guid]::NewGuid().ToString('N'))
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
if (-not ($resolvedTestRoot + '\').StartsWith($tempParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing managed policy test root outside the system temporary directory: $resolvedTestRoot"
}

try {
    $eAcute = [char]0x00E9
    $eGrave = [char]0x00E8
    $cCedilla = [char]0x00E7
    $emDash = [char]0x2014

    $normalProfile = Join-Path $testRoot 'normal-profile'
    $normalAgentsPath = Join-Path $normalProfile '.codex\AGENTS.md'
    $normalPrefix = 'Pr' + $eAcute + 'face checkpoints' + $emDash + 'especially, ' + $eAcute + 't' + $eAcute + '.' + "`r`n" +
        'No' + $eGrave + 'l, fa' + $cCedilla + 'ade, ' + $eGrave + 'l' + $eGrave + 've.'
    Write-TestUtf8File -Path $normalAgentsPath -Text $normalPrefix
    [byte[]]$normalPrefixBytes = ConvertTo-TestUtf8Bytes -Text $normalPrefix
    $expectedNormalBlock = [regex]::Replace((Read-CodexStrictUtf8File -Path $canonicalPolicyPath).Text.Trim(), "\r\n|\n|\r", "`r`n")
    $expectedNormalText = $normalPrefix + "`r`n`r`n" + $expectedNormalBlock + "`r`n"
    [byte[]]$stableNormalBytes = $null
    for ($iteration = 1; $iteration -le $iterations; $iteration++) {
        $result = Set-CodexManagedPolicyBlock -PolicyPath $canonicalPolicyPath -AgentsPath $normalAgentsPath
        if ($iteration -eq 1) {
            Assert-True ([bool]$result.Changed -and -not [bool]$result.ReplacedExistingBlock) 'Normal installation did not append its first managed policy block.'
        }
        else {
            Assert-True (-not [bool]$result.Changed) "Normal installation rewrote an already stable file on iteration $iteration."
        }
        $current = Read-CodexStrictUtf8File -Path $normalAgentsPath
        Assert-True ([string]$current.Text -ceq $expectedNormalText) "Normal installation changed Unicode content on iteration $iteration."
        Assert-True ((Get-TestLiteralCount -Text $current.Text -Literal $startMarker) -eq 1 -and
            (Get-TestLiteralCount -Text $current.Text -Literal $endMarker) -eq 1) "Normal installation did not retain exactly one marker pair on iteration $iteration."
        Assert-TestByteSegment -Actual $current.Bytes -Expected $normalPrefixBytes -Offset 0 -Message "Normal installation changed unrelated prefix bytes on iteration $iteration."
        if ($iteration -eq 1) {
            [byte[]]$stableNormalBytes = $current.Bytes
        }
        else {
            Assert-TestBytesEqual -Actual $current.Bytes -Expected $stableNormalBytes -Message "Normal installation bytes or size drifted on iteration $iteration."
        }
    }
    $scenarios.Add('normal-install-is-strict-utf8-byte-preserving-and-idempotent')

    $newProfile = Join-Path $testRoot 'new-profile'
    $newAgentsPath = Join-Path $newProfile '.codex\AGENTS.md'
    $newResult = Set-CodexManagedPolicyBlock -PolicyPath $canonicalPolicyPath -AgentsPath $newAgentsPath
    $newFile = Read-CodexStrictUtf8File -Path $newAgentsPath
    Assert-True ([bool]$newResult.Changed -and -not [bool]$newFile.HasUtf8Bom -and
        (Get-TestLiteralCount -Text $newFile.Text -Literal $startMarker) -eq 1 -and
        (Get-TestLiteralCount -Text $newFile.Text -Literal $endMarker) -eq 1) 'New installation did not atomically create one BOM-less managed policy block.'
    [byte[]]$newStableBytes = $newFile.Bytes
    $newRepeat = Set-CodexManagedPolicyBlock -PolicyPath $canonicalPolicyPath -AgentsPath $newAgentsPath
    Assert-True (-not [bool]$newRepeat.Changed) 'New installation rewrote its stable managed-only file.'
    Assert-TestBytesEqual -Actual ([IO.File]::ReadAllBytes($newAgentsPath)) -Expected $newStableBytes -Message 'New installation bytes changed on its first repeat.'
    $scenarios.Add('missing-target-is-created-atomically-and-stays-stable')

    $recoveryProfile = Join-Path $testRoot 'recovery-profile'
    $recoveryAgentsPath = Join-Path $recoveryProfile '.codex\AGENTS.md'
    $recoveryPrefix = 'R' + $eAcute + 'cup' + $eAcute + 'ration ' + $emDash + ' avant.' + "`n`n"
    $staleBlock = $startMarker + "`n## Stale managed text`n" + $endMarker
    $recoverySuffix = "`n`n" + 'Apr' + $eGrave + 's: ' + $eAcute + 'l' + $eGrave + 've et fa' + $cCedilla + 'ade.' + "`n"
    $recoverySeed = $recoveryPrefix + $staleBlock + $recoverySuffix
    Write-TestUtf8File -Path $recoveryAgentsPath -Text $recoverySeed -IncludeBom
    [byte[]]$recoveryPrefixBytes = ConvertTo-TestUtf8Bytes -Text $recoveryPrefix -IncludeBom
    [byte[]]$recoverySuffixBytes = ConvertTo-TestUtf8Bytes -Text $recoverySuffix
    $expectedRecoveryBlock = [regex]::Replace((Read-CodexStrictUtf8File -Path $canonicalPolicyPath).Text.Trim(), "\r\n|\n|\r", "`n")
    $expectedRecoveryText = $recoveryPrefix + $expectedRecoveryBlock + $recoverySuffix
    [byte[]]$stableRecoveryBytes = $null
    for ($iteration = 1; $iteration -le $iterations; $iteration++) {
        $result = Set-CodexManagedPolicyBlock -PolicyPath $canonicalPolicyPath -AgentsPath $recoveryAgentsPath
        if ($iteration -eq 1) {
            Assert-True ([bool]$result.Changed -and [bool]$result.ReplacedExistingBlock -and [bool]$result.PreservedUtf8Bom) 'Recovery installation did not replace the stale block while preserving its UTF-8 BOM.'
        }
        else {
            Assert-True (-not [bool]$result.Changed) "Recovery installation rewrote an already stable file on iteration $iteration."
        }
        $current = Read-CodexStrictUtf8File -Path $recoveryAgentsPath
        Assert-True ([bool]$current.HasUtf8Bom -and [string]$current.Text -ceq $expectedRecoveryText) "Recovery installation changed Unicode content or the UTF-8 BOM on iteration $iteration."
        Assert-True ((Get-TestLiteralCount -Text $current.Text -Literal $startMarker) -eq 1 -and
            (Get-TestLiteralCount -Text $current.Text -Literal $endMarker) -eq 1) "Recovery installation did not retain exactly one marker pair on iteration $iteration."
        Assert-TestByteSegment -Actual $current.Bytes -Expected $recoveryPrefixBytes -Offset 0 -Message "Recovery installation changed unrelated prefix bytes on iteration $iteration."
        Assert-TestByteSegment -Actual $current.Bytes -Expected $recoverySuffixBytes -Offset ($current.Bytes.Length - $recoverySuffixBytes.Length) -Message "Recovery installation changed unrelated suffix bytes on iteration $iteration."
        if ($iteration -eq 1) {
            [byte[]]$stableRecoveryBytes = $current.Bytes
        }
        else {
            Assert-TestBytesEqual -Actual $current.Bytes -Expected $stableRecoveryBytes -Message "Recovery installation bytes or size drifted on iteration $iteration."
        }
    }
    $scenarios.Add('recovery-install-is-strict-utf8-byte-preserving-and-idempotent')

    $invalidUtf8Path = Join-Path $testRoot 'invalid-utf8-profile\.codex\AGENTS.md'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($invalidUtf8Path))
    [byte[]]$invalidPrefix = ConvertTo-TestUtf8Bytes -Text 'legacy ANSI '
    [byte[]]$invalidSuffix = ConvertTo-TestUtf8Bytes -Text ' remains'
    [byte[]]$invalidUtf8Bytes = New-Object byte[] ($invalidPrefix.Length + 1 + $invalidSuffix.Length)
    [Array]::Copy($invalidPrefix, 0, $invalidUtf8Bytes, 0, $invalidPrefix.Length)
    $invalidUtf8Bytes[$invalidPrefix.Length] = 0xE9
    [Array]::Copy($invalidSuffix, 0, $invalidUtf8Bytes, $invalidPrefix.Length + 1, $invalidSuffix.Length)
    [IO.File]::WriteAllBytes($invalidUtf8Path, $invalidUtf8Bytes)
    Assert-RejectedWithoutChange -Scenario 'invalid UTF-8 target' -Path $invalidUtf8Path -ExpectedMessage 'not valid UTF-8' -Operation {
        Set-CodexManagedPolicyBlock -PolicyPath $canonicalPolicyPath -AgentsPath $invalidUtf8Path
    }
    $scenarios.Add('invalid-legacy-encoding-fails-without-rewrite')

    $orphanMarkerPath = Join-Path $testRoot 'orphan-marker-profile\.codex\AGENTS.md'
    Write-TestUtf8File -Path $orphanMarkerPath -Text ('before' + "`r`n" + $startMarker + "`r`nmissing end")
    Assert-RejectedWithoutChange -Scenario 'orphan marker target' -Path $orphanMarkerPath -ExpectedMessage 'invalid or ambiguous' -Operation {
        Set-CodexManagedPolicyBlock -PolicyPath $canonicalPolicyPath -AgentsPath $orphanMarkerPath
    }
    $scenarios.Add('orphan-marker-layout-fails-without-rewrite')

    $duplicateMarkerPath = Join-Path $testRoot 'duplicate-marker-profile\.codex\AGENTS.md'
    $duplicateText = $startMarker + "`nfirst`n" + $endMarker + "`n" + $startMarker + "`nsecond`n" + $endMarker
    Write-TestUtf8File -Path $duplicateMarkerPath -Text $duplicateText
    Assert-RejectedWithoutChange -Scenario 'duplicate marker target' -Path $duplicateMarkerPath -ExpectedMessage 'invalid or ambiguous' -Operation {
        Set-CodexManagedPolicyBlock -PolicyPath $canonicalPolicyPath -AgentsPath $duplicateMarkerPath
    }
    $scenarios.Add('duplicate-marker-layout-fails-without-rewrite')

    $ambiguousUtf16Path = Join-Path $testRoot 'ambiguous-utf16-profile\.codex\AGENTS.md'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ambiguousUtf16Path))
    [byte[]]$ambiguousBytes = (New-Object Text.UnicodeEncoding($false, $false, $true)).GetBytes('ambiguous UTF-16 without BOM')
    [IO.File]::WriteAllBytes($ambiguousUtf16Path, $ambiguousBytes)
    Assert-RejectedWithoutChange -Scenario 'ambiguous UTF-16 target' -Path $ambiguousUtf16Path -ExpectedMessage 'NUL characters' -Operation {
        Set-CodexManagedPolicyBlock -PolicyPath $canonicalPolicyPath -AgentsPath $ambiguousUtf16Path
    }
    $scenarios.Add('ambiguous-null-bearing-encoding-fails-without-rewrite')

    $auditFixtureRoot = Join-Path $testRoot 'public-audit-fixture'
    $auditFixturePolicyPath = Join-Path $auditFixtureRoot 'setup\AGENTS.block.md'
    Write-TestUtf8File -Path (Join-Path $auditFixtureRoot 'README.md') -Text '# Public audit fixture'
    Write-TestUtf8File -Path $auditFixturePolicyPath -Text $canonicalBlock
    $auditHost = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    $cleanAuditOutput = @(& $auditHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $publicAuditPath -RepositoryRoot $auditFixtureRoot -AsJson 2>&1)
    $cleanAuditExitCode = $LASTEXITCODE
    Assert-True ($cleanAuditExitCode -eq 0 -and (($cleanAuditOutput -join "`n") | ConvertFrom-Json).Success) 'The public audit rejected a bounded canonical-only policy fixture.'

    Write-TestUtf8File -Path $auditFixturePolicyPath -Text ("## Working agreements`n`nprivate preference`n`n" + $canonicalBlock)
    $personalAuditOutput = @(& $auditHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $publicAuditPath -RepositoryRoot $auditFixtureRoot -AsJson 2>&1)
    $personalAuditExitCode = $LASTEXITCODE
    $personalAudit = ($personalAuditOutput -join "`n") | ConvertFrom-Json
    Assert-True ($personalAuditExitCode -eq 1 -and -not [bool]$personalAudit.Success -and
        @($personalAudit.Violations | Where-Object Rule -in @('UnboundedManagedPolicy', 'PersonalGlobalPolicyContent')).Count -eq 2) 'The public audit did not reject unbounded personal/global policy content.'

    Write-TestUtf8File -Path $auditFixturePolicyPath -Text $canonicalBlock
    Write-TestUtf8File -Path (Join-Path $auditFixtureRoot 'src\Software\Recovery\CodexPolicy.md') -Text $canonicalBlock
    $duplicateAuditOutput = @(& $auditHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File $publicAuditPath -RepositoryRoot $auditFixtureRoot -AsJson 2>&1)
    $duplicateAuditExitCode = $LASTEXITCODE
    $duplicateAudit = ($duplicateAuditOutput -join "`n") | ConvertFrom-Json
    Assert-True ($duplicateAuditExitCode -eq 1 -and -not [bool]$duplicateAudit.Success -and
        @($duplicateAudit.Violations | Where-Object Rule -eq 'DuplicateManagedPolicySource').Count -eq 1) 'The public audit did not reject a second managed policy source.'
    $scenarios.Add('public-audit-rejects-personal-content-and-duplicate-policy-source')

    $installSource = (Read-CodexStrictUtf8File -Path $installPath).Text
    $recoveryBuilderSource = (Read-CodexStrictUtf8File -Path $recoveryBuilderPath).Text
    $recoveryInstallSource = (Read-CodexStrictUtf8File -Path $recoveryInstallPath).Text
    $recoveryVerifierSource = (Read-CodexStrictUtf8File -Path $recoveryVerifierPath).Text
    $helperSource = (Read-CodexStrictUtf8File -Path $helperPath).Text
    Assert-True ($installSource.IndexOf("Common\CodexManagedPolicy.ps1", [StringComparison]::Ordinal) -ge 0 -and
        $installSource.IndexOf('Set-CodexManagedPolicyBlock', [StringComparison]::Ordinal) -ge 0 -and
        $installSource.IndexOf('[IO.File]::WriteAllText($agentsPath', [StringComparison]::Ordinal) -lt 0) 'Normal installer is not exclusively wired through the shared safe policy helper.'
    Assert-True ($recoveryBuilderSource.IndexOf("'Setup\AGENTS.block.md'", [StringComparison]::Ordinal) -ge 0 -and
        $recoveryBuilderSource.IndexOf('CodexPolicy.md', [StringComparison]::Ordinal) -lt 0 -and
        $recoveryBuilderSource.IndexOf('Copy-CodexRecoveryFileIncremental', [StringComparison]::Ordinal) -ge 0 -and
        $recoveryBuilderSource.IndexOf("-RelativePath 'Codex/AGENTS.md'", [StringComparison]::Ordinal) -ge 0) 'Recovery generation does not snapshot the one canonical managed policy block.'
    Assert-True ($recoveryInstallSource.IndexOf("Common\CodexManagedPolicy.ps1", [StringComparison]::Ordinal) -ge 0 -and
        $recoveryInstallSource.IndexOf('Set-CodexManagedPolicyBlock', [StringComparison]::Ordinal) -ge 0 -and
        $recoveryInstallSource.IndexOf('[IO.File]::WriteAllText($agentsDestination', [StringComparison]::Ordinal) -lt 0) 'Recovery installer is not exclusively wired through the shared safe policy helper.'
    Assert-True ($recoveryVerifierSource.IndexOf('Software\Common\CodexManagedPolicy.ps1', [StringComparison]::Ordinal) -ge 0) 'Recovery verification does not require the self-contained managed policy helper.'
    $flushIndex = $helperSource.IndexOf('$stream.Flush($true)', [StringComparison]::Ordinal)
    $replaceIndex = $helperSource.IndexOf('[IO.File]::Replace(', [StringComparison]::Ordinal)
    Assert-True ($helperSource.IndexOf('Text.UTF8Encoding($false, $true)', [StringComparison]::Ordinal) -ge 0 -and
        $flushIndex -ge 0 -and $replaceIndex -gt $flushIndex -and
        $helperSource.IndexOf('[IO.File]::Move(', [StringComparison]::Ordinal) -gt $flushIndex) 'Shared policy helper does not enforce strict UTF-8 and durable atomic publication.'
    $leftovers = @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Force | Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '*.bak' })
    Assert-True ($leftovers.Count -eq 0) 'Managed policy tests left atomic staging or backup files behind.'
    $scenarios.Add('both-production-paths-use-one-canonical-policy-and-atomic-helper')

    [pscustomobject][ordered]@{
        Success = $true
        ScenarioCount = $scenarios.Count
        Scenarios = $scenarios.ToArray()
        Metrics = [ordered]@{
            Engine = [string]$PSVersionTable.PSEdition
            PowerShellVersion = [string]$PSVersionTable.PSVersion
            IterationsPerInstallPath = $iterations
            NormalStableBytes = [long]$stableNormalBytes.Length
            RecoveryStableBytes = [long]$stableRecoveryBytes.Length
        }
    } | ConvertTo-Json -Depth 8
}
finally {
    $cleanupPath = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    if (($cleanupPath + '\').StartsWith($tempParent + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $cleanupPath -PathType Container)) {
        Remove-Item -LiteralPath $cleanupPath -Recurse -Force
    }
}
