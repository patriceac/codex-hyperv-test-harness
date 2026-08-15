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
$approvedPreflightPosition = $prompt.IndexOf('Only after that approval', [StringComparison]::Ordinal)
if ($reviewPosition -lt 0 -or $explainPosition -le $reviewPosition -or $questionsPosition -le $explainPosition -or $proposalPosition -le $questionsPosition -or $approvedPreflightPosition -le $proposalPosition -or $prompt -notmatch 'Before cloning') {
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

if ($prompt -notmatch 'Treat my answers as preferences, not authorization' -or $prompt -notmatch 'Stop and wait for my explicit approval' -or $prompt -notmatch 'second explicit approval') {
    throw 'The public prompt does not enforce two distinct approval gates.'
}
$scenarios.Add('public-prompt-has-two-approval-gates')

$consentPosition = $skill.IndexOf('## Begin with informed consent', [StringComparison]::Ordinal)
$preflightPosition = $skill.IndexOf('## Run the read-only preflight after approval', [StringComparison]::Ordinal)
if ($consentPosition -lt 0 -or $preflightPosition -le $consentPosition -or $skill -notmatch 'Do not assume a drive' -or $skill -notmatch 'Stop and obtain a second explicit approval') {
    throw 'The setup skill does not place informed consent before preflight and mutation.'
}
$scenarios.Add('setup-skill-enforces-consent-before-preflight')

if ($agents -notmatch '## Informed-consent gate' -or $agents -notmatch 'Configuration answers are not approval' -or $agents -notmatch 'never use an unparameterized command' -or $agents -notmatch 'separate destructive approval') {
    throw 'Root agent instructions do not preserve informed consent or destructive separation.'
}
$scenarios.Add('root-agent-instructions-enforce-consent')

if ($checklist -notmatch 'Do not assume a drive' -or $checklist -notmatch 'obtain a second approval before mutation' -or $checklist -notmatch 'stable .NET channel' -or $disasterRecovery -notmatch 'No drive or resource profile is assumed' -or $disasterRecovery -notmatch '<chosen-install-root>') {
    throw 'Recovery references do not carry the user-selected configuration through execution.'
}
$scenarios.Add('recovery-references-use-the-chosen-configuration')

if ($skillUi -notmatch '\$setup-hyperv-harness' -or $skillUi -notmatch 'explain' -or $skillUi -notmatch 'approval') {
    throw 'Skill UI metadata still suggests immediate unattended installation.'
}
$scenarios.Add('skill-ui-prompts-for-explanation-and-approval')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
