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
$scenarios = New-Object Collections.Generic.List[string]

foreach ($path in @($deployPath, $acceptancePath, $installPath, $runnerPath, $poolBrokerPath, $recoveryWrapperPath, $publicAuditPath, $deploymentDocPath, $skillPath)) {
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
if ((@($acceptancePreview.TestNames) -join ',') -ne 'LegacyLaunch,Utf8ActionName,KeyboardInput,ExpectedGuestPowerOff') {
    throw 'Release acceptance does not contain the exact four required paths in order.'
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
    [int]$shutdownInvocation.GuestPowerOffRecoveryTimeoutSeconds -ne 180 -or
    [string]$shutdownInvocation.AssertResultFile -ne '{OUTDIR}\shutdown-marker.json' -or
    [string]$shutdownInvocation.Arguments -notmatch '--delay-ms 3000') {
    throw 'Expected-power-off acceptance is not bound to the canonical marker and recovery contract.'
}
$acceptanceSource = Get-Content -LiteralPath $acceptancePath -Raw
if ($acceptanceSource -match '\.Parameters\.ActionsPath' -or
    $acceptanceSource -notmatch "Parameters\.ContainsKey\('ActionsPath'\)" -or
    $acceptanceSource -notmatch "Parameters\['ActionsPath'\]") {
    throw "Release acceptance does not handle the expected-power-off test's absent optional ActionsPath safely."
}
$scenarios.Add('four-path-isolated-acceptance-is-exactly-bound')

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
if ($deploy -notmatch [regex]::Escape("Run legacy launch, accented-name UI Automation, bounded keyboard, and expected-guest-power-off acceptance in isolated workers.")) {
    throw 'The immutable release plan does not describe all four isolated acceptance paths.'
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
    $deploy -notmatch 'ApprovalReady = \[bool\]\$publicAudit\.Success') {
    throw 'PlanOnly does not include the public repository audit in its approval-ready boundary.'
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
foreach ($requiredText in @('LiveShadowPoolAvailable = false','no magic phrase','NeedsFixForward','one final local recovery')) {
    if ($deploymentDoc.IndexOf($requiredText, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "Deployment documentation is missing: $requiredText" }
}
if ($skill.IndexOf('Deploy-HarnessRelease.ps1', [StringComparison]::Ordinal) -lt 0 -or
    $skill.IndexOf('do not require a magic phrase', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'The setup skill does not route future ordinary releases through the canonical controller.'
}
$scenarios.Add('documentation-and-skill-make-the-controller-the-durable-default')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
