[CmdletBinding()]
param([string] $HostBrokerPath)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($HostBrokerPath)) {
    $HostBrokerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'HostBroker.ps1'
}
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($HostBrokerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Import-AstFunction {
    param([Parameter(Mandatory = $true)] $Ast, [Parameter(Mandatory = $true)] [string] $Name)
    $definition = @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name" }
    $body = $definition.Body.Extent.Text
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
}

Import-AstFunction -Ast $ast -Name 'Assert-ExpectedPowerOffEvidenceStageMatchesManifest'

$snapshotFunction = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-GuestEvidenceSnapshot'
}, $true)) | Select-Object -First 1
if (-not $snapshotFunction) { throw 'New-GuestEvidenceSnapshot was not found.' }

$snapshotScriptAst = @($snapshotFunction.FindAll({
    param($node)
    $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
        $node.Extent.Text -like '*evidence-copy-manifest.json*'
}, $true)) | Select-Object -First 1
if (-not $snapshotScriptAst) { throw 'The guest-side evidence snapshot script block was not found.' }
$snapshotBody = $snapshotScriptAst.ScriptBlock.Extent.Text
$snapshotBody = $snapshotBody.Substring(1, $snapshotBody.Length - 2)
$snapshotScript = [scriptblock]::Create($snapshotBody)

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-evidence-snapshot-' + [Guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $testRoot 'source'
$stageBaseRoot = Join-Path $testRoot 'stage'
New-Item -ItemType Directory -Force -Path $sourceRoot, $stageBaseRoot | Out-Null
$scenarios = New-Object Collections.Generic.List[string]
$lockStream = $null
try {
    [ordered]@{ Success = $true; TestPassed = $false } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sourceRoot 'result.json') -Encoding UTF8
    'diagnostic' | Set-Content -LiteralPath (Join-Path $sourceRoot 'screenshot.txt') -Encoding UTF8
    $lockedDirectory = Join-Path $sourceRoot 'nested-optional'
    New-Item -ItemType Directory -Force -Path $lockedDirectory | Out-Null
    $lockedPath = Join-Path $lockedDirectory 'optional-locked.log'
    'still open' | Set-Content -LiteralPath $lockedPath -Encoding UTF8
    $lockStream = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)

    $snapshotId = '0123456789abcdef0123456789abcdef'
    $manifest = & $snapshotScript $sourceRoot 'synthetic-request' $snapshotId $stageBaseRoot
    $stageRoot = [string]$manifest.StageRoot
    Assert-True ([string]$manifest.SnapshotId -ceq $snapshotId -and [string]$stageRoot -eq (Join-Path $stageBaseRoot $snapshotId)) 'The snapshot was not bound to its exact immutable operation id.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'result.json') -PathType Leaf) 'A locked optional file prevented the terminal result from being staged.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'screenshot.txt') -PathType Leaf) 'An unlocked evidence file was not staged.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'nested-optional\optional-locked.log') -PathType Leaf)) 'A partially copied locked file leaked into the stable snapshot.'
    Assert-True (@($manifest.CopiedFiles).Count -eq 2 -and @($manifest.SkippedFiles).Count -eq 1) 'The evidence manifest did not separate copied and skipped files.'
    foreach ($copiedFile in @($manifest.CopiedFiles)) {
        $copiedPath = Join-Path $stageRoot ([string]$copiedFile.RelativePath)
        Assert-True (
            [int64]$copiedFile.Length -eq [int64](Get-Item -LiteralPath $copiedPath).Length -and
            [string]::Equals([string]$copiedFile.Sha256, (Get-FileHash -LiteralPath $copiedPath -Algorithm SHA256).Hash, [StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::IsNullOrWhiteSpace([string]$copiedFile.SourceLastWriteUtc)
        ) "The copied evidence record for '$([string]$copiedFile.RelativePath)' lacks stable length, timestamp, or SHA-256 proof."
    }
    Assert-True ([string]$manifest.SkippedFiles[0].RelativePath -eq 'nested-optional\optional-locked.log' -and [int]$manifest.SkippedFiles[0].Attempts -eq 4) 'The locked-file retry record is incomplete.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'evidence-copy-manifest.json') -PathType Leaf) 'The stable snapshot manifest was not published.'
    $scenarios.Add('locked-optional-evidence-is-skipped')

    $hostStageRoot = Join-Path $testRoot 'host-stage'
    New-Item -ItemType Directory -Force -Path $hostStageRoot | Out-Null
    Copy-Item -Path (Join-Path $stageRoot '*') -Destination $hostStageRoot -Recurse -Force
    $hostManifest = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $hostManifest.StageRoot = 'C:\CodexGuest\EvidenceStage\' + $snapshotId
    $hostManifestPath = Join-Path $hostStageRoot 'evidence-copy-manifest.json'
    $hostManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $hostManifestPath -Encoding UTF8
    $hostManifestSha256 = (Get-FileHash -LiteralPath $hostManifestPath -Algorithm SHA256).Hash
    $remotedManifest = $hostManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $remotedManifest.SkippedFiles = $null
    $remotedManifest.EnumerationErrors = $null
    Assert-True (Assert-ExpectedPowerOffEvidenceStageMatchesManifest -HostStageRoot $hostStageRoot -Manifest $remotedManifest -ManifestSha256 $hostManifestSha256 -RequestId 'synthetic-request' -SnapshotId $snapshotId) 'A complete host evidence stage did not pass hash-bound manifest verification after remoting changed empty collection shapes.'
    $tamperedResultPath = Join-Path $hostStageRoot 'result.json'
    [IO.File]::AppendAllText($tamperedResultPath, 'tampered')
    $tamperedTransferRejected = $false
    try { $null = Assert-ExpectedPowerOffEvidenceStageMatchesManifest -HostStageRoot $hostStageRoot -Manifest $remotedManifest -ManifestSha256 $hostManifestSha256 -RequestId 'synthetic-request' -SnapshotId $snapshotId }
    catch { $tamperedTransferRejected = $_.Exception.Message -like '*length/SHA-256 verification*' }
    Assert-True $tamperedTransferRejected 'A host evidence file corrupted after PowerShell Direct transfer passed manifest verification.'
    Copy-Item -LiteralPath (Join-Path $stageRoot 'result.json') -Destination $tamperedResultPath -Force
    $injectedDirectory = Join-Path $hostStageRoot 'unmanifested-directory'
    New-Item -ItemType Directory -Force -Path $injectedDirectory | Out-Null
    'injected' | Set-Content -LiteralPath (Join-Path $injectedDirectory 'payload.txt') -Encoding UTF8
    $injectedDirectoryRejected = $false
    try { $null = Assert-ExpectedPowerOffEvidenceStageMatchesManifest -HostStageRoot $hostStageRoot -Manifest $remotedManifest -ManifestSha256 $hostManifestSha256 -RequestId 'synthetic-request' -SnapshotId $snapshotId }
    catch { $injectedDirectoryRejected = $_.Exception.Message -like '*unmanifested or unsafe directory*' }
    Assert-True $injectedDirectoryRejected 'An unmanifested host-stage directory could bypass inventory verification and reach promotion.'
    $scenarios.Add('host-transfer-is-rehashed-before-promotion')

    $secondSnapshotId = 'fedcba9876543210fedcba9876543210'
    $secondManifest = & $snapshotScript $sourceRoot 'synthetic-request' $secondSnapshotId $stageBaseRoot
    Assert-True (
        [string]$secondManifest.StageRoot -ne $stageRoot -and
        (Test-Path -LiteralPath $stageRoot -PathType Container) -and
        (Test-Path -LiteralPath ([string]$secondManifest.StageRoot) -PathType Container)
    ) 'A later snapshot attempt reused or removed an earlier immutable stage.'
    $invalidSnapshotRejected = $false
    try { $null = & $snapshotScript $sourceRoot 'synthetic-request' 'ABC' $stageBaseRoot }
    catch { $invalidSnapshotRejected = $_.Exception.Message -like '*Invalid evidence snapshot operation id*' }
    Assert-True $invalidSnapshotRejected 'A non-canonical snapshot id was accepted by the guest snapshot implementation.'
    $scenarios.Add('snapshot-attempts-use-validated-unique-stages')

    $failureManifest = & $snapshotScript $sourceRoot 'synthetic-request' ([Guid]::NewGuid().ToString('N')) $stageBaseRoot $true
    Assert-True (@($failureManifest.CopiedFiles).Count -eq 2 -and @($failureManifest.SkippedFiles).Count -eq 1 -and $failureManifest.SkippedFiles[0].Attempts -eq 1) 'Failure diagnostics did not retain available files with one bounded attempt for a locked file.'
    $failureRoot = Join-Path $testRoot 'failure-source'
    New-Item -ItemType Directory -Path $failureRoot | Out-Null
    foreach ($name in @('a.bin','b.bin','c.bin','d.bin','e.bin','oversized.bin')) {
        $stream = [IO.File]::Create((Join-Path $failureRoot $name))
        try { $stream.SetLength($(if ($name -eq 'oversized.bin') { 17MB } else { 16MB })) } finally { $stream.Dispose() }
    }
    $limited = & $snapshotScript $failureRoot 'synthetic-request' ([Guid]::NewGuid().ToString('N')) $stageBaseRoot $true
    Assert-True (@($limited.CopiedFiles).Count -eq 4 -and @($limited.SkippedFiles).Count -eq 2 -and ($limited.CopiedFiles | ForEach-Object { $_['Length'] } | Measure-Object -Sum).Sum -eq 64MB) 'Failure diagnostics did not enforce per-file and aggregate byte limits.'
    $scenarios.Add('failure-snapshot-retains-partial-bounded-files')

    $manyRoot = Join-Path $testRoot 'many-files'
    New-Item -ItemType Directory -Path $manyRoot | Out-Null
    for ($index = 0; $index -lt 514; $index++) { [IO.File]::WriteAllText((Join-Path $manyRoot ($index.ToString() + '.txt')), '') }
    $limited = & $snapshotScript $manyRoot 'synthetic-request' ([Guid]::NewGuid().ToString('N')) $stageBaseRoot $true
    Assert-True (@($limited.CopiedFiles).Count -eq 512 -and @($limited.EnumerationErrors).Count -eq 1) 'Failure diagnostics did not enforce the entry limit or report truncation.'
    $scenarios.Add('failure-snapshot-reports-entry-limit')

    $safeRoot = Join-Path $testRoot 'safe-output'
    New-Item -ItemType Directory -Path $safeRoot | Out-Null
    'authorized' | Set-Content -LiteralPath (Join-Path $safeRoot 'status.json')
    $junction = Join-Path $safeRoot 'outside'
    New-Item -ItemType Junction -Path $junction -Target $sourceRoot | Out-Null
    try {
        $safe = & $snapshotScript $safeRoot 'synthetic-request' ([Guid]::NewGuid().ToString('N')) $stageBaseRoot $true
        Assert-True (@($safe.CopiedFiles).Count -eq 1 -and $safe.CopiedFiles[0].RelativePath -eq 'status.json' -and @($safe.EnumerationErrors).Count -gt 0) 'Failure diagnostics followed a directory junction outside the authorized output.'
        $rejected = $false
        try { & $snapshotScript $junction 'synthetic-request' ([Guid]::NewGuid().ToString('N')) $stageBaseRoot $true | Out-Null } catch { $rejected = $_.Exception.Message -like '*reparse*' }
        Assert-True $rejected 'A reparse-backed failure output root was accepted.'
    }
    finally { [IO.Directory]::Delete($junction) }
    $scenarios.Add('failure-snapshot-rejects-reparse-boundary')

    $hostBrokerText = Get-Content -Raw -LiteralPath $HostBrokerPath
    Assert-True ($hostBrokerText -notlike '*Copy-Item -Path "$guestOutbox\*"*') 'The broker still recursively copies the live guest outbox.'
    Assert-True ($hostBrokerText -like '*Copy-Item -Path "$guestEvidenceStage\*"*') 'The broker does not transfer the stable evidence stage.'
    Assert-True ($hostBrokerText -like '*Copy-Item -LiteralPath $stagedItem.FullName -Destination $destinationPath -Recurse -Force*') 'Recovered evidence is moved from the private broker stage instead of inheriting the client-readable result ACL.'
    Assert-True ($hostBrokerText -like '*if (-not (Test-Path -LiteralPath $guestResultPath))*') 'Terminal result validation was removed.'
    Assert-True ($hostBrokerText -like '*EvidenceFilesSkipped*' -and $hostBrokerText -like '*EvidenceWarnings*') 'Evidence degradation is not exposed in the broker result.'
    $scenarios.Add('broker-copies-stage-and-retains-terminal-contract')
}
finally {
    if ($lockStream) { $lockStream.Dispose() }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
