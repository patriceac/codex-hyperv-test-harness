[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$readme = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'README.md')
$agents = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'AGENTS.md')
$skill = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.agents\skills\setup-hyperv-harness\SKILL.md')
$skillUi = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.agents\skills\setup-hyperv-harness\agents\openai.yaml')
$checklist = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.agents\skills\setup-hyperv-harness\references\rebuild-checklist.md')
$disasterRecovery = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'docs\disaster-recovery.md')
$scenarios = New-Object Collections.Generic.List[string]

$promptStart = $readme.IndexOf('> I want to evaluate and possibly rebuild', [StringComparison]::Ordinal)
$manualStart = $readme.IndexOf('Or perform the same review manually', [StringComparison]::Ordinal)
if ($promptStart -lt 0 -or $manualStart -le $promptStart) { throw 'The copyable guided-recovery prompt could not be isolated.' }
$prompt = $readme.Substring($promptStart, $manualStart - $promptStart)

$reviewPosition = $prompt.IndexOf('Begin in review-only mode', [StringComparison]::Ordinal)
$explainPosition = $prompt.IndexOf('First explain in detailed, plain language', [StringComparison]::Ordinal)
$questionsPosition = $prompt.IndexOf('Then ask me', [StringComparison]::Ordinal)
$proposalPosition = $prompt.IndexOf('After I answer', [StringComparison]::Ordinal)
$preflightPosition = $prompt.IndexOf("Run the repository's public-safety audit", [StringComparison]::Ordinal)
if ($reviewPosition -lt 0 -or $explainPosition -le $reviewPosition -or $questionsPosition -le $explainPosition -or $proposalPosition -le $questionsPosition -or $preflightPosition -le $proposalPosition -or $prompt -notmatch 'Before cloning') {
    throw 'The public prompt does not require explanation before local action.'
}
$scenarios.Add('public-prompt-starts-read-only-and-explains-first')

if ($prompt -match 'Use `D:\\' -or $prompt -notmatch 'Do not assume that `D:` or any other drive exists' -or $prompt -notmatch 'exact non-root installation directory') {
    throw 'The public prompt still assumes storage instead of asking the user.'
}
$scenarios.Add('public-prompt-does-not-assume-a-drive')

foreach ($requiredChoice in @('Pool size', 'Memory', 'Virtual processors', 'Display', 'Idle shutdown', 'Guest language', 'Target Windows account', 'Restart behavior', 'Local recovery bundle', 'Preservation', 'Temporary guest-update switch', '.NET SDK', 'Windows Update')) {
    if ($prompt.IndexOf($requiredChoice, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "The public prompt does not collect required choice: $requiredChoice" }
}
$scenarios.Add('public-prompt-collects-basic-configuration')

foreach ($referenceAnswer in @('"use the reference profile"', 'suggested: 4 workers', 'suggested: 8 GiB per VM', 'suggested: 4 per VM', 'suggested: 1920 by 1080', 'suggested: 600 seconds', 'suggested: `Auto`', 'suggested: the current account', 'NoRestart = false', 'SkipLocalRecoveryBundle = false', 'ForceRebuild = false', 'suggested: `Default Switch`', 'suggested: stable LTS channel `10.0`', 'suggested: applicable non-preview Microsoft', 'read-only fixed-drive and free-space inventory')) {
    if (-not $prompt.Contains($referenceAnswer)) { throw "The public prompt does not provide reference answer: $referenceAnswer" }
}
if ($skill -notmatch 'Use these reference answers' -or $skill -notmatch 'use the reference profile' -or $skill -notmatch 'temporary guest-update switch' -or $skill -notmatch 'stable .NET channel' -or $agents -notmatch 'suggested/reference answer and its tradeoff') {
    throw 'The skill or root instructions do not require suggested answers for every configuration question.'
}
$scenarios.Add('configuration-questions-include-reference-answers')

if ($prompt -notmatch 'authorized by default' -or $prompt -notmatch 'do not pause for confirmation' -or $prompt -notmatch 'continue immediately') {
    throw 'The public prompt does not establish standing authorization through Apply.'
}
$scenarios.Add('public-prompt-has-standing-authorization')

$planningPosition = $skill.IndexOf('## Plan before mutation', [StringComparison]::Ordinal)
$skillPreflightPosition = $skill.IndexOf('## Run the read-only preflight', [StringComparison]::Ordinal)
if ($planningPosition -lt 0 -or $skillPreflightPosition -le $planningPosition -or $skill -notmatch 'Do not assume a drive' -or $skill -notmatch 'standing authorization applies') {
    throw 'The setup skill does not place exact planning and standing authorization before mutation.'
}
$scenarios.Add('setup-skill-enforces-planning-before-automatic-apply')

if ($agents -notmatch '## Planning and standing authorization' -or $agents -notmatch 'All in-scope harness operations are standing-authorized' -or $agents -notmatch 'never use an unparameterized command' -or $agents -notmatch 'without asking for approval') {
    throw 'Root agent instructions do not preserve exact planning and standing authorization.'
}
$scenarios.Add('root-agent-instructions-enforce-standing-authorization')

if ($checklist -notmatch 'Do not assume a drive' -or $checklist -notmatch 'continue automatically when it succeeds' -or $checklist -notmatch 'stable .NET channel' -or $disasterRecovery -notmatch 'No drive or resource profile is assumed' -or $disasterRecovery -notmatch '<chosen-install-root>' -or $disasterRecovery -notmatch 'standing-authorized') {
    throw 'Recovery references do not carry the user-selected configuration through execution.'
}
$scenarios.Add('recovery-references-use-the-chosen-configuration')

if ($skillUi -notmatch '\$setup-hyperv-harness' -or $skillUi -notmatch 'exact plan' -or $skillUi -notmatch 'without asking for confirmation') {
    throw 'Skill UI metadata does not preserve planning with standing authorization.'
}
$scenarios.Add('skill-ui-prompts-for-planning-and-automatic-apply')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
