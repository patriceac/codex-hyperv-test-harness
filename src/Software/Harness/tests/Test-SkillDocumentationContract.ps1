[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill'
$skillPath = Join-Path $skillRoot 'SKILL.md'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $skillPath -PathType Leaf) 'The runtime SKILL.md is missing.'
$skillText = Get-Content -Raw -LiteralPath $skillPath
$descriptionMatch = [regex]::Match($skillText, '(?m)^description:\s*(.+)$')

Assert-True $descriptionMatch.Success 'The runtime skill description is missing.'
Assert-True ($descriptionMatch.Groups[1].Value.Length -le 360) 'The runtime skill discovery description exceeded its 360-character budget.'
Assert-True ($skillText.Length -le 7000) 'The always-loaded runtime skill exceeded its 7,000-character budget; move mode-specific detail to references.'

foreach ($retiredPath in @('scripts\Invoke-HostExecutableTest.ps1', 'scripts\HostControlNative.cs', 'references\host-control.md')) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $skillRoot $retiredPath))) "Retired desktop-control component must not ship: $retiredPath"
}

$requiredReferences = [ordered]@{
    'artifact-and-actions.md' = @('wait_result_file', 'AssertResultJsonPointer', 'send_keys')
    'network-and-host-inputs.md' = @('InternetOnly', 'AllowNetworkWithHostInputs', 'SelectedTransport')
    'expected-guest-power-off.md' = @('ExpectGuestPowerOff', 'ResultFileNotPrePowerOff', 'ApplicationRelaunchedByHarnessAfterGuestPowerOff=false')
    'queue-observation-and-cancellation.md' = @('Capture-HyperVExecutableTestLiveEvidence.ps1', 'Cancel-HyperVExecutableTest.ps1', 'QueueTimedOut')
    'broker-pool-and-cache.md' = @('immutable VHDX generations', 'PayloadFilesHashed', 'ProcessCleanup')
    'verification-and-reporting.md' = @('HarnessSucceeded', 'TestEvaluated', 'TestPassed')
}

foreach ($referenceName in $requiredReferences.Keys) {
    $referencePath = Join-Path (Join-Path $skillRoot 'references') $referenceName
    Assert-True (Test-Path -LiteralPath $referencePath -PathType Leaf) "Required runtime skill reference is missing: $referenceName"
    Assert-True ($skillText.Contains("references/$referenceName")) "SKILL.md does not route to required reference: $referenceName"
    $referenceText = Get-Content -Raw -LiteralPath $referencePath
    foreach ($contractText in $requiredReferences[$referenceName]) {
        Assert-True ($referenceText.Contains($contractText)) "Reference '$referenceName' is missing contract text '$contractText'."
    }
}

$linkedReferences = [regex]::Matches($skillText, '\]\((references/[^\)#]+\.md)\)')
Assert-True ($linkedReferences.Count -ge $requiredReferences.Count) 'The runtime skill does not expose all conditional reference routes.'
foreach ($match in $linkedReferences) {
    $relativePath = $match.Groups[1].Value.Replace('/', [IO.Path]::DirectorySeparatorChar)
    Assert-True (Test-Path -LiteralPath (Join-Path $skillRoot $relativePath) -PathType Leaf) "SKILL.md links a missing reference: $relativePath"
}

[pscustomobject][ordered]@{
    Success = $true
    SkillCharacters = $skillText.Length
    DescriptionCharacters = $descriptionMatch.Groups[1].Value.Length
    RoutedReferences = $requiredReferences.Count
} | ConvertTo-Json -Depth 4
