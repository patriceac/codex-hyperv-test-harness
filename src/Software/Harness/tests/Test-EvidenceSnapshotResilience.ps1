[CmdletBinding()]
param(
    [string] $HostBrokerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'HostBroker.ps1')
)

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($HostBrokerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

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
    $lockedPath = Join-Path $sourceRoot 'optional-locked.log'
    'still open' | Set-Content -LiteralPath $lockedPath -Encoding UTF8
    $lockStream = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)

    $manifest = & $snapshotScript $sourceRoot 'synthetic-request' $stageBaseRoot
    $stageRoot = [string]$manifest.StageRoot
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'result.json') -PathType Leaf) 'A locked optional file prevented the terminal result from being staged.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'screenshot.txt') -PathType Leaf) 'An unlocked evidence file was not staged.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'optional-locked.log') -PathType Leaf)) 'A partially copied locked file leaked into the stable snapshot.'
    Assert-True (@($manifest.CopiedFiles).Count -eq 2 -and @($manifest.SkippedFiles).Count -eq 1) 'The evidence manifest did not separate copied and skipped files.'
    Assert-True ([string]$manifest.SkippedFiles[0].RelativePath -eq 'optional-locked.log' -and [int]$manifest.SkippedFiles[0].Attempts -eq 4) 'The locked-file retry record is incomplete.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stageRoot 'evidence-copy-manifest.json') -PathType Leaf) 'The stable snapshot manifest was not published.'
    $scenarios.Add('locked-optional-evidence-is-skipped')

    $hostBrokerText = Get-Content -Raw -LiteralPath $HostBrokerPath
    Assert-True ($hostBrokerText -notlike '*Copy-Item -Path "$guestOutbox\*"*') 'The broker still recursively copies the live guest outbox.'
    Assert-True ($hostBrokerText -like '*Copy-Item -Path "$guestEvidenceStage\*"*') 'The broker does not transfer the stable evidence stage.'
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
