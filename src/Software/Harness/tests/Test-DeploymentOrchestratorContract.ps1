[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$harnessRoot = Split-Path -Parent $PSScriptRoot
$softwareRoot = Split-Path -Parent $harnessRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $softwareRoot)
$setupRoot = Join-Path $repositoryRoot 'setup'
$deployPath = Join-Path $setupRoot 'Deploy-HarnessRelease.ps1'
$acceptancePath = Join-Path $setupRoot 'Invoke-HarnessReleaseAcceptance.ps1'
$installPath = Join-Path $setupRoot 'Install.ps1'
$runnerPath = Join-Path $softwareRoot 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
$poolBrokerPath = Join-Path $harnessRoot 'PoolBroker.ps1'
$recoveryWrapperPath = Join-Path $setupRoot 'Refresh-LocalRecovery.ps1'
$publicAuditPath = Join-Path $setupRoot 'Test-PublicRepository.ps1'
$deploymentDocPath = Join-Path $repositoryRoot 'docs\deployment.md'
$skillPath = Join-Path $repositoryRoot '.agents\skills\setup-hyperv-harness\SKILL.md'
$agentsPath = Join-Path $repositoryRoot 'AGENTS.md'
$scenarios = New-Object Collections.Generic.List[string]

foreach ($path in @($deployPath, $acceptancePath, $installPath, $runnerPath, $poolBrokerPath, $recoveryWrapperPath, $publicAuditPath, $deploymentDocPath, $skillPath, $agentsPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release contract input is missing: $path" }
}

$probeRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexHarnessReleaseContract-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $probeRoot) { throw 'The no-mutation probe path already exists.' }
$deployPreview = & $deployPath -InstallRoot $probeRoot -InvocationPreflightOnly
if (-not [bool]$deployPreview.Success -or -not [bool]$deployPreview.NoMutationPerformed -or -not [bool]$deployPreview.PlanRoundTripVerified -or (Test-Path -LiteralPath $probeRoot)) {
    throw 'Deployment invocation preflight was not successful and mutation-free.'
}
$installInvocation = $deployPreview.InstallInvocation
$recoveryInvocation = $deployPreview.RecoveryRefreshInvocation
foreach ($requiredKey in @('NoElevation','NoRestart','SkipSmokeTest','SkipLocalRecoveryBundle','DeferPoolRebuildForGuestBaselineUpdate','ExpectedExistingConfigurationSha256')) {
    if (-not $installInvocation.ContainsKey($requiredKey)) { throw "Deployment install invocation is missing $requiredKey." }
}
foreach ($forbiddenKey in @('ForceRebuild','ResetRequestNetworkPolicy','PlanOnly')) {
    if ($installInvocation.ContainsKey($forbiddenKey)) { throw "Deployment install invocation unexpectedly binds $forbiddenKey." }
}
if ($deployPreview.GuestBaselineInvocation.ContainsKey('PlanOnly') -or
    [string]$deployPreview.GuestBaselineInvocation.ClientSid -ne 'S-1-5-18') {
    throw 'Apply preflight did not preserve the exact client SID or unexpectedly bound guest PlanOnly.'
}
if ([string]$recoveryInvocation.BaselineExportMode -ne 'ReuseCurrent' -or
    -not $recoveryInvocation.ContainsKey('NoElevation') -or
    [string]$recoveryInvocation.InstallRoot -ne $probeRoot) {
    throw 'Apply preflight did not preserve the reviewed recovery baseline-export mode.'
}
$scenarios.Add('exact-apply-invocations-defer-duplicate-work-without-expanding-scope')

$acceptancePreview = & $acceptancePath -InstallRoot $probeRoot -InvocationPreflightOnly
if (-not [bool]$acceptancePreview.Success -or
    -not [bool]$acceptancePreview.NoMutationPerformed -or
    -not [bool]$acceptancePreview.MaintenanceSnapshotShapeSafe -or
    (Test-Path -LiteralPath $probeRoot)) {
    throw 'Acceptance invocation preflight was not successful and mutation-free.'
}
if ((@($acceptancePreview.TestNames) -join ',') -ne 'LegacyLaunch,Utf8ActionName,KeyboardInput,ExpectedGuestPowerOff,SystemPrompts,GuestRestart,InstalledGuestPowerOff,GuestRestartFailure') {
    throw 'Release acceptance does not contain the exact eight required paths in order.'
}
$utf8Invocation = @($acceptancePreview.Invocations | Where-Object Name -eq 'Utf8ActionName')[0].Parameters
if ([string]$utf8Invocation.ActionsPath -notlike '*release-utf8-actions.json' -or
    [string]$utf8Invocation.AssertResultFile -ne '{OUTDIR}\utf8-action-result.json' -or
    [string]$utf8Invocation.AssertResultJsonPointer -ne '/passed' -or
    [string]$utf8Invocation.AssertResultEqualsJson -ne 'true' -or
    -not $utf8Invocation.ContainsKey('ThrowOnFailure')) {
    throw 'UTF-8 action acceptance is not bound to its exact named-control assertion and throwable failure.'
}
$keyboardInvocation = @($acceptancePreview.Invocations | Where-Object Name -eq 'KeyboardInput')[0].Parameters
if ([string]$keyboardInvocation.AssertResultJsonPointer -ne '/passed' -or
    [string]$keyboardInvocation.AssertResultEqualsJson -ne 'true' -or
    -not $keyboardInvocation.ContainsKey('ThrowOnFailure')) {
    throw 'Keyboard acceptance is not bound to an exact result assertion and throwable failure.'
}
$shutdownInvocation = @($acceptancePreview.Invocations | Where-Object Name -eq 'ExpectedGuestPowerOff')[0].Parameters
if (-not $shutdownInvocation.ContainsKey('ExpectGuestPowerOff') -or
    $shutdownInvocation.ContainsKey('ActionsPath') -or
    [int]$shutdownInvocation.GuestPowerOffRecoveryTimeoutSeconds -ne 300 -or
    [int]$shutdownInvocation.ExecutionTimeoutSeconds -ne 600 -or
    [string]$shutdownInvocation.AssertResultFile -ne '{OUTDIR}\shutdown-marker.json' -or
    [string]$shutdownInvocation.Arguments -notmatch '--delay-ms 3000') {
    throw 'Expected-power-off acceptance is not bound to the canonical marker and recovery contract.'
}
$systemPromptInvocation = @($acceptancePreview.Invocations | Where-Object Name -eq 'SystemPrompts')[0].Parameters
if (-not $systemPromptInvocation.ContainsKey('AcceptUacPrompt') -or
    -not $systemPromptInvocation.ContainsKey('AcceptWindowsFirewallPrompt') -or
    [int]$systemPromptInvocation.SystemPromptTimeoutSeconds -ne 120 -or
    (@($systemPromptInvocation.WindowsFirewallProfiles) -join ',') -cne 'Private' -or
    [string]$systemPromptInvocation.NetworkProfile -cne 'IsolatedTestNet' -or
    [string]$systemPromptInvocation.NetworkCohort -cne 'release-system-prompts' -or
    [string]$systemPromptInvocation.Arguments -notmatch '--settle-ms 30000' -or
    [string]$systemPromptInvocation.ActionsPath -notlike '*system-prompt-actions.json') {
    throw 'System-prompt acceptance is not bound to ordered UAC and exact isolated Private-profile firewall authorization.'
}
$acceptanceSource = Get-Content -LiteralPath $acceptancePath -Raw
if ($acceptanceSource -match '\.Parameters\.ActionsPath' -or
    $acceptanceSource -notmatch "Parameters\.ContainsKey\('ActionsPath'\)" -or
    $acceptanceSource -notmatch "Parameters\['ActionsPath'\]") {
    throw "Release acceptance does not handle the expected-power-off test's absent optional ActionsPath safely."
}
if ($acceptanceSource -notmatch 'ExactInboundFirewallRulesWithQueryUserReconciliation' -or
    $acceptanceSource -notmatch 'ExactApplicationInboundBlockRuleCount' -or
    $acceptanceSource -notmatch 'RemovedQueryUserBlockRules' -or
    $acceptanceSource -match 'RemovedQueryUserBlockRules\)\.Count\s*-lt\s*1') {
    throw 'Release acceptance does not prove post-dismissal Query User reconciliation and a final exact allow-only state.'
}
$restartInvocation = @($acceptancePreview.Invocations | Where-Object Name -eq 'GuestRestart')[0].Parameters
$installedShutdownInvocation = @($acceptancePreview.Invocations | Where-Object Name -eq 'InstalledGuestPowerOff')[0].Parameters
if (-not $restartInvocation.GuestCredentialFixture -or -not $restartInvocation.GuestRestartPlanPath -or
    -not $restartInvocation.GuestSetupExecutableSha256 -or $restartInvocation.NetworkProfile -ne 'IsolatedTestNet' -or
    -not $installedShutdownInvocation.ExpectGuestPowerOff -or -not $installedShutdownInvocation.GuestSetupExecutableSha256) { throw 'Power acceptance lost its fixture, setup, network, or restart binding.' }
$failedRestartInvocation = @($acceptancePreview.Invocations | Where-Object Name -eq 'GuestRestartFailure')[0].Parameters
if ($failedRestartInvocation.ContainsKey('ThrowOnFailure') -or -not $failedRestartInvocation.GuestRestartPlanPath -or
    $failedRestartInvocation.Arguments -cne 'fail-restart "{OUTDIR}"' -or
    $installedShutdownInvocation.GuestSetupArguments[2] -cne '{PAYLOAD}\PowerTestCanary.exe') { throw 'Failure-diagnostic or setup-token acceptance lost its exact reproduction.' }
$scenarios.Add('eight-path-isolated-acceptance-is-exactly-bound')
if ($acceptancePreview.RestartNetworkPeer.Profile -ne 'IsolatedTestNet' -or -not $acceptancePreview.RestartNetworkPeer.SameCohort -or
    -not $acceptancePreview.RestartNetworkPeer.DistinctWorkerRequired -or ($acceptancePreview.RestartNetworkPeer.BootChallenges -join ',') -cne 'auto,manual') { throw 'Restart acceptance requires a distinct same-cohort peer after both boots.' }
& {
    $definition = [Management.Automation.Language.Parser]::ParseInput($acceptanceSource, [ref]$null, [ref]$null).Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-RestartAcceptanceWithPeer' }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $EvidenceRoot = $repositoryRoot; $runner = 'synthetic'; $brokerRoot = 'synthetic'
    function Start-Job { [pscustomobject]@{ State = 'Completed' } }
    function Wait-Job { }
    function Remove-Job { }
    function Invoke-AcceptanceTest { [pscustomobject]@{ PoolWorkerId = 1; ResultPath = 'C:\synthetic\restart'; Network = @{ GuestAddress = '10.254.0.101' }; GuestRestart = @{ NetworkChecks = @(@{ Succeeded = $true; Evidence = @{ Before = $true; After = $true } }, @{ Succeeded = $true; Evidence = @{ Before = $true; After = $true } }) } } }
    function Receive-Job { @{ Success = $true; PayloadChildDeleted = $true; VmFinalState = 'Off'; PoolWorkerId = $peerWorker; Network = @{ GuestAddress = '10.254.0.102' }; ResultPath = 'C:\synthetic\peer'; RequestId = 'peer' } | ConvertTo-Json -Depth 8 }
    function Read-JsonIfPresent {
        param($Path)
        if ($Path.EndsWith('peer.json')) { return [pscustomobject]@{ passed = $true; token = 'challenge'; address = '10.254.0.101'; automatic = $true; manual = $true } }
        [pscustomobject]@{ passed = -not ($missingManual -and $Path.EndsWith('network-manual.json')); token = 'challenge'; phase = $(if ($Path.EndsWith('network-auto.json')) { 'auto' } else { 'manual' }); peerAddress = '10.254.0.102' }
    }
    $peerWorker = 2; $missingManual = $false
    $definition = @{ Parameters = @{ NetworkCohort = 'synthetic' } }
    $result = Invoke-RestartAcceptanceWithPeer -Definition $definition -Token 'challenge'
    if (-not $result.NetworkPeer.Success) { throw 'Two-guest boot acceptance did not retain the peer receipt.' }
    foreach ($fault in @('same-worker','missing-manual')) {
        $peerWorker = if ($fault -eq 'same-worker') { 1 } else { 2 }; $missingManual = $fault -eq 'missing-manual'
        $rejected = $false
        try { Invoke-RestartAcceptanceWithPeer -Definition $definition -Token 'challenge' | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Restart peer acceptance accepted $fault." }
    }
}
$scenarios.Add('restart-peer-must-prove-both-boots-on-distinct-workers')
$singleWorkerPreview = & $acceptancePath -InstallRoot $probeRoot -InvocationPreflightOnly -AvailableWorkerCount 1
if ($singleWorkerPreview.Success -or -not $singleWorkerPreview.NoMutationPerformed -or $singleWorkerPreview.RequiredWorkerCount -ne 2) { throw 'A single-worker pool must fail peer acceptance preflight before mutation.' }
$scenarios.Add('single-worker-peer-acceptance-fails-preflight')

$inventoryAst = [Management.Automation.Language.Parser]::ParseFile($deployPath, [ref]$null, [ref]$null).Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GuestReleaseInventory' }, $true)
. ([scriptblock]::Create($inventoryAst.Extent.Text))
$inventoryRoot = Join-Path $repositoryRoot ('work\release-inventory-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $inventoryRoot | Out-Null
$priorGuestFiles = @('GuestAgent.ps1', 'GuestAgentSupervisor.ps1', 'GuestLiveEvidence.ps1')
$priorReceipt = @{ FormatVersion = 1; GuestSourceInventory = @($priorGuestFiles | ForEach-Object {
    @{ RelativePath = 'Harness/seed/guest/' + $_; Sha256 = (Get-FileHash -LiteralPath (Join-Path $harnessRoot ('seed\guest\' + $_)) -Algorithm SHA256).Hash }
}) }
$priorReceipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $inventoryRoot 'prior.json') -Encoding UTF8
$inventory = @(Get-GuestReleaseInventory -CandidateSoftwareRoot $softwareRoot -InstalledSoftwareRoot $softwareRoot -ProvenancePath (Join-Path $inventoryRoot 'prior.json'))
if (@($inventory | Where-Object Changed).Count -ne 1 -or @($inventory | Where-Object Changed)[0].RelativePath -ne 'Harness/seed/guest/GuestPowerTest.ps1' -or
    @($inventory | Where-Object Changed)[0].InstalledSha256) { throw 'A new guest component was incorrectly treated as deployed from source alone.' }
$scenarios.Add('new-guest-component-requires-baseline-promotion')

if ($acceptanceSource -notmatch "Invoke-PoolAuditUnderMaintenance -Name 'pre-acceptance-audit'" -or
    $acceptanceSource -notmatch "Invoke-PoolAuditUnderMaintenance -Name 'post-acceptance-audit'" -or
    $acceptanceSource -notmatch 'MaintenanceCleanupCompleted' -or
    $acceptanceSource -notmatch 'Get-ReleaseCollectionCount -Value \$workerStates' -or
    $acceptanceSource -notmatch 'Get-ReleaseOptionalPropertyValue -InputObject \$poolState' -or
    $acceptanceSource -notmatch 'OwnerToken' -or
    $acceptanceSource -notmatch 'finally\s*\{' -or
    $acceptanceSource -notmatch 'Remove-Item -LiteralPath \$maintenancePath') {
    throw 'Strict release audits are not bracketed by an owned, cleanup-proven broker maintenance drain.'
}
. $poolBrokerPath
$cleanupNowUtc = [DateTime]::UtcNow
if (-not (Test-PoolPayloadCleanupDue -MaintenanceActive $true -MaintenanceCleanupCompleted $false -AllWorkerStatesOff $true -NowUtc $cleanupNowUtc -NextCleanupUtc $cleanupNowUtc.AddMinutes(5)) -or
    (Test-PoolPayloadCleanupDue -MaintenanceActive $true -MaintenanceCleanupCompleted $true -AllWorkerStatesOff $true -NowUtc $cleanupNowUtc -NextCleanupUtc $cleanupNowUtc.AddMinutes(5)) -or
    (Test-PoolPayloadCleanupDue -MaintenanceActive $true -MaintenanceCleanupCompleted $false -AllWorkerStatesOff $false -NowUtc $cleanupNowUtc -NextCleanupUtc $cleanupNowUtc.AddMinutes(5)) -or
    -not (Test-PoolPayloadCleanupDue -MaintenanceActive $false -MaintenanceCleanupCompleted $false -AllWorkerStatesOff $true -NowUtc $cleanupNowUtc -NextCleanupUtc $cleanupNowUtc.AddSeconds(-1))) {
    throw 'Pool payload cleanup scheduling does not distinguish a new drained maintenance cycle from normal periodic cleanup.'
}
$poolBrokerSource = Get-Content -LiteralPath $poolBrokerPath -Raw
if ($poolBrokerSource -notmatch '\$maintenanceGcState\.Status -eq ''Completed''' -or
    $poolBrokerSource -notmatch '\$maintenanceGcStartedUtc -ge \$nowUtc' -or
    $poolBrokerSource.IndexOf('Invoke-PayloadCacheGarbageCollection', [StringComparison]::Ordinal) -gt $poolBrokerSource.IndexOf('$maintenanceGcState = Get-Content', [StringComparison]::Ordinal)) {
    throw 'The broker does not record maintenance cleanup only after payload garbage collection restores transient ACLs.'
}
$scenarios.Add('strict-release-audits-use-maintenance-drain-and-immediate-acl-cleanup')

$maintenanceTiming = @{ MaintenanceActive = $true; MaintenanceCleanupCompleted = $true; AllWorkerStatesOff = $true; NowUtc = $cleanupNowUtc; NextCleanupUtc = $cleanupNowUtc.AddMinutes(5); MaintenanceRequestedUtc = $cleanupNowUtc }
if (-not (Test-PoolPayloadCleanupDue @maintenanceTiming -MaintenanceCleanupStartedUtc $cleanupNowUtc.AddSeconds(-1)) -or
    (Test-PoolPayloadCleanupDue @maintenanceTiming -MaintenanceCleanupStartedUtc $cleanupNowUtc.AddSeconds(1))) {
    throw 'A replacement maintenance marker must get fresh cleanup even when no loop observed the previous marker disappear.'
}
$scenarios.Add('replacement-maintenance-owner-requires-fresh-cleanup')

$parsedUtf8Actions = Get-Content -LiteralPath (Join-Path $softwareRoot 'Canaries\release-utf8-actions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$utf8Actions = @()
foreach ($parsedUtf8Action in $parsedUtf8Actions) { $utf8Actions += $parsedUtf8Action }
$utf8ClickActions = @($utf8Actions | Where-Object type -eq 'click_control')
$accentedControlName = 'Approuver le pilote et d' + [char]0x00E9 + 'bloquer la file'
if ($utf8ClickActions.Count -ne 1 -or
    [string]$utf8ClickActions[0].name -cne $accentedControlName -or
    $utf8ClickActions[0].PSObject.Properties.Name -contains 'automationId') {
    throw 'UTF-8 release actions do not request the exact accented UI Automation Name without AutomationId.'
}
if ($acceptanceSource -notmatch 'RequestedAutomationId' -or
    $acceptanceSource -notmatch 'MatchedName' -or
    $acceptanceSource -notmatch 'clickedControlName') {
    throw 'UTF-8 release acceptance does not bind selector evidence to the application click marker.'
}
$scenarios.Add('utf8-proof-clicks-exact-accented-name-without-automation-id')

$parsedKeyboardActions = Get-Content -LiteralPath (Join-Path $softwareRoot 'Canaries\release-keyboard-actions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$keyboardActions = @($parsedKeyboardActions)
if ((@($keyboardActions.type) -join ',') -ne 'wait_window,screenshot,send_keys,screenshot,wait_result_file') {
    throw 'Keyboard release actions do not preserve before/input/after/result ordering.'
}
$sendKeys = @($keyboardActions | Where-Object type -eq 'send_keys')
if ($sendKeys.Count -ne 1 -or [string]$sendKeys[0].keys -cne 'WIN+LEFT' -or [int]$sendKeys[0].holdMs -ne 75) {
    throw 'Keyboard release actions do not request the exact bounded WIN+LEFT chord.'
}
$scenarios.Add('keyboard-proof-captures-before-and-after-exact-chord')

$deploy = Get-Content -LiteralPath $deployPath -Raw
if ($deploy -notmatch 'verify the disposable account cannot expire') {
    throw 'The immutable release plan omits guest account expiry protection.'
}
if ($deploy -notmatch [regex]::Escape("Run legacy launch, accented-name UI Automation, bounded keyboard, expected-guest-power-off, verified system-prompt, automatic/manual restart with cross-guest traffic after both boots, installed-app shutdown, and restart-failure diagnostics acceptance in isolated workers.")) {
    throw 'The immutable release plan does not describe all eight isolated acceptance paths.'
}
$phaseNames = @('CandidateQualification','LiveReadiness','SourcePromotion','GuestBaselinePromotion','IsolatedAcceptance','RecoveryRefresh','Finalization')
$lastIndex = -1
foreach ($phaseName in $phaseNames) {
    $index = $deploy.IndexOf("-Name '$phaseName'", [StringComparison]::Ordinal)
    if ($index -lt 0 -or $index -le $lastIndex) { throw "Deployment phase is missing or out of order: $phaseName" }
    $lastIndex = $index
}
if ([regex]::Matches($deploy, "-Name 'RecoveryRefresh'").Count -ne 1 -or
    $deploy -notmatch "RecoveryRefreshCount\s*=\s*1" -or
    $deploy -notmatch 'RecoveryBaselineExportMode' -or
    $deploy -notmatch "'ReuseCurrent'" -or
    $deploy -notmatch 'NTFS hard links' -or
    $deploy -notmatch 'AutomaticRollback\s*=\s*\$false' -or
    $deploy -notmatch 'LiveShadowPoolAvailable\s*=\s*\$false' -or
    $deploy -notmatch "Status\s*=\s*'NeedsFixForward'" -or
    $deploy -notmatch 'ResumeDeploymentId') {
    throw 'The release state machine does not enforce single recovery, honest shadow status, resumability, and fix-forward failure state.'
}
if ($deploy -notmatch 'guest-baseline-provenance\.json' -or
    $deploy.IndexOf("'GuestBaselineProvenance'", [StringComparison]::Ordinal) -lt 0 -or
    $deploy.IndexOf('provenanceByPath', [StringComparison]::Ordinal) -lt 0 -or
    $deploy -notmatch 'Get-ResumableReleasePlan') {
    throw 'Guest-baseline detection and resume are not bound to durable provenance and the persisted plan.'
}
if ($deploy -notmatch '\$publicAuditJson\s*=\s*&\s*\(Join-Path \$repositoryRoot ''setup\\Test-PublicRepository\.ps1''\)' -or
    $deploy -notmatch 'ApplyReady = \$applyReady' -or
    $deploy -notmatch "DefaultAuthorization = 'ApplyWithoutAdditionalUserConfirmation'") {
    throw 'PlanOnly does not include the public repository audit in its default-authorized apply boundary.'
}
if ($deploy -notmatch 'status --porcelain=v1 --untracked-files=all') {
    throw 'The immutable commit check does not reject non-ignored untracked deployment source.'
}
$publicAuditSource = Get-Content -LiteralPath $publicAuditPath -Raw
if ($publicAuditSource -match "\.git'\) -PathType Container") {
    throw 'The public audit would ignore Git metadata in a linked worktree and scan generated ignored binaries instead.'
}
if ($deploy -notmatch "Status -notin @\('NeedsFixForward','Ready'\)") {
    throw 'A repeated apply could corrupt an already-ready deployment receipt.'
}
if ($deploy -notmatch 'Enable-ReleaseAwake' -or $deploy -notmatch 'Disable-ReleaseAwake') {
    throw 'The release controller does not keep the host awake across its bounded transaction.'
}
if ($deploy -match '\bRestore-VM\b|\bRemove-VM\b|\bRemove-VMSnapshot\b') {
    throw 'The release controller contains an automatic VM or checkpoint rollback primitive.'
}
if ($deploy -notmatch '\$PSVersionTable\.PSEdition\s+-ne\s+''Desktop''' -or
    $deploy -notmatch 'FilePath\s*=\s*''powershell\.exe''') {
    throw 'Apply and resume are not pinned to the supported Windows PowerShell 5.1 controller.'
}
$scenarios.Add('ordered-resumable-state-machine-refreshes-recovery-once-without-auto-rollback')

$install = Get-Content -LiteralPath $installPath -Raw
if ($install -notmatch 'DeferPoolRebuildForGuestBaselineUpdate requires SkipSmokeTest and SkipLocalRecoveryBundle' -or
    $install -notmatch "Phase 'PoolRefreshDeferred'" -or
    $install -notmatch "'ReadyForGuestBaselineUpdate'") {
    throw 'Install.ps1 does not fail closed around the orchestrator-only single-pool-rebuild handoff.'
}
$guestUpdater = Get-Content -LiteralPath (Join-Path $harnessRoot 'Update-GuestHarnessBaseline.ps1') -Raw
if ($guestUpdater -notmatch '-PoolSize\s+\(\[int\]\$layout\.PoolSize\)' -or
    $guestUpdater -notmatch '-PoolVmPrefix\s+\(\[string\]\$layout\.PoolVmPrefix\)' -or
    $guestUpdater -notmatch '-ClientSid\s+\$ClientSid') {
    throw 'Guest-baseline promotion does not preserve the installed pool shape and target client SID.'
}
if ($guestUpdater -notmatch 'ApplyReady\s*=\s*\$applyReady' -or
    $guestUpdater -notmatch "DefaultAuthorization\s*=\s*'ApplyWithoutAdditionalUserConfirmation'" -or
    $guestUpdater -notmatch 'DestructiveApprovalRequired\s*=\s*\$false' -or
    $guestUpdater -notmatch 'DestructiveOperationStandingAuthorized\s*=\s*\$true') {
    throw 'Guest-baseline promotion does not expose standing authorization for its destructive exact plan.'
}
$runner = Get-Content -LiteralPath $runnerPath -Raw
if ($runner -notmatch '\[switch\]\s*\$ThrowOnFailure' -or $runner -notmatch 'if \(\$ThrowOnFailure\)') {
    throw 'The runner cannot return acceptance failures to the orchestrator without terminating its state process.'
}
$recoveryWrapper = Get-Content -LiteralPath $recoveryWrapperPath -Raw
if ($recoveryWrapper -notmatch '\[string\]\s*\$TargetUserProfile' -or
    $recoveryWrapper -notmatch "ValidateSet\('FullExport','ReuseCurrent'\)" -or
    $recoveryWrapper -notmatch '-BaselineExportMode\s+\$BaselineExportMode' -or
    $deploy -notmatch 'New-RecoveryRefreshInvocationParameters\s+-Plan\s+\$plan') {
    throw 'The final recovery refresh does not preserve the reviewed target-user profile.'
}
$scenarios.Add('component-handoff-and-runner-failure-return-are-fail-closed')

$shutdownProbe = Get-Content -LiteralPath (Join-Path $softwareRoot 'Canaries\ShutdownProbe.cs') -Raw
if ($shutdownProbe -notmatch 'stream\.Flush\(true\)' -or
    $shutdownProbe -notmatch 'File\.Move\(temporaryPath, markerPath\)' -or
    $shutdownProbe -notmatch 'Thread\.Sleep\(delayMs\)' -or
    $shutdownProbe -notmatch 'shutdown\.exe' -or
    $shutdownProbe.IndexOf('File.Move(temporaryPath, markerPath)', [StringComparison]::Ordinal) -gt $shutdownProbe.IndexOf('Process.Start(shutdown)', [StringComparison]::Ordinal)) {
    throw 'ShutdownProbe does not durably publish its marker before requesting real guest shutdown.'
}
$scenarios.Add('shutdown-probe-flushes-and-atomically-promotes-marker-before-poweroff')

$deploymentDoc = Get-Content -LiteralPath $deploymentDocPath -Raw
$skill = Get-Content -LiteralPath $skillPath -Raw
$agents = Get-Content -LiteralPath $agentsPath -Raw
foreach ($requiredText in @('LiveShadowPoolAvailable = false','No additional user confirmation is required','NeedsFixForward','one final local recovery')) {
    if ($deploymentDoc.IndexOf($requiredText, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "Deployment documentation is missing: $requiredText" }
}
if ($skill.IndexOf('Deploy-HarnessRelease.ps1', [StringComparison]::Ordinal) -lt 0 -or
    $skill.IndexOf('Every in-scope harness operation is authorized by default', [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
    $agents.IndexOf('All in-scope harness operations are standing-authorized', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'The repository instructions and setup skill do not preserve standing authorization while routing ordinary releases through the canonical controller.'
}
$scenarios.Add('documentation-and-skill-make-the-controller-the-durable-default')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
