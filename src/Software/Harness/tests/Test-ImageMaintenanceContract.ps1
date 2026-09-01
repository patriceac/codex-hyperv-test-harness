[CmdletBinding()]
param(
    [switch] $RunInertController,
    [string] $InertStatePath,
    [string] $InertCancellationPath,
    [ValidateRange(1, 30)] [int] $InertSynchronousOperationSeconds = 3
)

$ErrorActionPreference = 'Stop'

if ($RunInertController) {
    if ([string]::IsNullOrWhiteSpace($InertStatePath) -or [string]::IsNullOrWhiteSpace($InertCancellationPath)) {
        throw 'InertStatePath and InertCancellationPath are required in inert-controller mode.'
    }
    $inertState = [ordered]@{
        Phase = 'Starting'
        BrokerState = 'Running'
        NetworkState = 'Disconnected'
        MaintenanceMarkerPresent = $false
        SynchronousOperationStarted = $false
        SynchronousOperationCompleted = $false
        NextMutationStarted = $false
        Cancelled = $false
        CleanupCompleted = $false
    }
    function Write-InertState {
        $parent = Split-Path -Parent ([IO.Path]::GetFullPath($InertStatePath))
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $temporary = $InertStatePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        try {
            $inertState | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
            Move-Item -LiteralPath $temporary -Destination $InertStatePath -Force
        }
        finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    try {
        $inertState.Phase = 'SynchronousOperation'
        $inertState.BrokerState = 'StoppedForMaintenance'
        $inertState.NetworkState = 'TemporaryUpdateNetworkConnected'
        $inertState.MaintenanceMarkerPresent = $true
        $inertState.SynchronousOperationStarted = $true
        Write-InertState
        Start-Sleep -Seconds $InertSynchronousOperationSeconds
        $inertState.SynchronousOperationCompleted = $true
        if (Test-Path -LiteralPath $InertCancellationPath -PathType Leaf) {
            throw [OperationCanceledException]::new('Inert image maintenance was cancelled after its synchronous operation.')
        }
        $inertState.NextMutationStarted = $true
        $inertState.Phase = 'NextMutation'
        Write-InertState
    }
    catch [OperationCanceledException] {
        $inertState.Cancelled = $true
        $inertState.Phase = 'Cancelling'
    }
    finally {
        $inertState.NetworkState = 'Disconnected'
        $inertState.BrokerState = 'Running'
        $inertState.MaintenanceMarkerPresent = $false
        $inertState.CleanupCompleted = $true
        $inertState.Phase = if ($inertState.Cancelled) { 'CancelledAndCleaned' } else { 'CompletedAndCleaned' }
        Write-InertState
    }
    return
}

$harnessRoot = Split-Path -Parent $PSScriptRoot
$softwareRoot = Split-Path -Parent $harnessRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $softwareRoot)
$setupRoot = Join-Path $repositoryRoot 'setup'
$wrapper = Get-Content -Raw -LiteralPath (Join-Path $setupRoot 'Update-Images.ps1')
$watcherPath = Join-Path $setupRoot 'Watch-ImageUpdateLauncher.ps1'
$watcher = Get-Content -Raw -LiteralPath $watcherPath
$inertControllerPath = $PSCommandPath
$installer = Get-Content -Raw -LiteralPath (Join-Path $setupRoot 'Install.ps1')
$guestServicing = Get-Content -Raw -LiteralPath (Join-Path $harnessRoot 'Update-WindowsGuestImage.ps1')
$imageUpdatePath = Join-Path $harnessRoot 'Update-HyperVTestImages.ps1'
$imageUpdate = Get-Content -Raw -LiteralPath $imageUpdatePath
$resolverPath = Join-Path $harnessRoot 'Resolve-DotNetSdkInstaller.ps1'
$resolver = Get-Content -Raw -LiteralPath $resolverPath
$recovery = Get-Content -Raw -LiteralPath (Join-Path $softwareRoot 'Recovery\New-CodexHyperVRecovery.ps1')
$maintenanceDoc = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'docs\maintenance.md')
$setupSkill = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.agents\skills\setup-hyperv-harness\SKILL.md')
$scenarios = New-Object Collections.Generic.List[string]

function Get-ScriptAst {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has a parse error: $($errors[0].Message)" }
    $ast
}

function Import-AstFunction {
    param(
        [Parameter(Mandatory = $true)] $Ast,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $definition = @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
}

$wrapperAst = Get-ScriptAst -Path (Join-Path $setupRoot 'Update-Images.ps1')
Import-AstFunction -Ast $wrapperAst -Name 'New-ImageUpdateInvocationParameters'

$normalInvocation = New-ImageUpdateInvocationParameters `
    -ConfigPath 'C:\CodexHarness\missing-config.json' `
    -NetworkSwitchName 'Codex Test NAT' `
    -DotNetChannel '10.0' `
    -ExpectedDotNetSdkVersion '10.0.400' `
    -ExpectedInstalledChannelVersions @{} `
    -TargetUserSid 'S-1-5-18' `
    -CancellationPath 'C:\CodexHarness\image-update-cancel.json' `
    -GuestRestartMode Automatic `
    -ResumeUpdateId '' `
    -PreserveRecoveryPrevious
if ($normalInvocation.ContainsKey('ResumeUpdateId') -or
    $normalInvocation.ContainsKey('AdoptCurrentBaseline') -or
    $normalInvocation.ContainsKey('SkipSmokeTest') -or
    -not $normalInvocation.ContainsKey('PreserveRecoveryPrevious')) {
    throw 'The normal image-update invocation did not omit unset optional parameters exactly.'
}
$normalPreflight = & $imageUpdatePath @normalInvocation -InvocationPreflightOnly
if (-not [bool]$normalPreflight.Success -or
    -not [bool]$normalPreflight.NoMutationPerformed -or
    [bool]$normalPreflight.ResumeUpdateIdBound -or
    -not [bool]$normalPreflight.PreserveRecoveryPreviousBound) {
    throw 'The exact normal wrapper-to-inner invocation did not bind safely without a resume ID.'
}
$scenarios.Add('normal-wrapper-to-inner-binding-omits-empty-resume-id')

$resumeInvocation = New-ImageUpdateInvocationParameters `
    -ConfigPath 'C:\CodexHarness\missing-config.json' `
    -NetworkSwitchName 'Codex Test NAT' `
    -DotNetChannel '10.0' `
    -ExpectedDotNetSdkVersion '10.0.400' `
    -ExpectedInstalledChannelVersions @{} `
    -TargetUserSid 'S-1-5-18' `
    -CancellationPath 'C:\CodexHarness\image-update-cancel.json' `
    -GuestRestartMode Manual `
    -ResumeUpdateId '20260831T123456789Z' `
    -PreserveRecoveryPrevious
$resumePreflight = & $imageUpdatePath @resumeInvocation -InvocationPreflightOnly
if (-not [bool]$resumePreflight.Success -or
    -not [bool]$resumePreflight.ResumeUpdateIdBound -or
    [string]$resumePreflight.ResumeUpdateId -ne '20260831T123456789Z') {
    throw 'The retained-generation wrapper-to-inner invocation did not bind its exact resume ID.'
}
$scenarios.Add('resume-wrapper-to-inner-binding-preserves-valid-resume-id')

if ($guestServicing -match 'Stop-VM\s+-Name\s+\$VmName\s+-TurnOff' -or
    $guestServicing -match 'if\s*\(\s*-not\s+\$success\s*\)[\s\S]{0,500}Stop-VM') {
    throw 'Guest servicing still hard-powers the baseline off after an ordinary failure.'
}
$scenarios.Add('servicing-failure-never-hard-powers-off-baseline')

foreach ($optionalResultContract in @(
    @{ Text = $imageUpdate; Name = 'baseline servicing'; Cancelled = "`$servicing.PSObject.Properties['Cancelled']"; Resume = "`$servicing.PSObject.Properties['ResumeRequired']" },
    @{ Text = $wrapper; Name = 'top-level image update'; Cancelled = "`$result.PSObject.Properties['Cancelled']"; Resume = "`$result.PSObject.Properties['ResumeRequired']" }
)) {
    if ($optionalResultContract.Text.IndexOf($optionalResultContract.Cancelled, [StringComparison]::Ordinal) -lt 0 -or
        $optionalResultContract.Text.IndexOf($optionalResultContract.Resume, [StringComparison]::Ordinal) -lt 0) {
        throw "$($optionalResultContract.Name) reads optional cancellation fields without checking their presence."
    }
}
$scenarios.Add('successful-result-shapes-do-not-require-cancellation-fields')

$planPosition = $wrapper.IndexOf('if ($PlanOnly)', [StringComparison]::Ordinal)
$invocationPreflightPosition = $wrapper.IndexOf('$invocationPreflight = & $innerUpdatePath @updateParameters -InvocationPreflightOnly', [StringComparison]::Ordinal)
$elevationPosition = $wrapper.IndexOf('if (-not (Test-Administrator))', $planPosition + 1, [StringComparison]::Ordinal)
if ($invocationPreflightPosition -lt 0 -or $planPosition -le $invocationPreflightPosition -or $elevationPosition -le $planPosition -or
    $wrapper -notmatch 'NoMutationPerformed = \$true' -or $wrapper -notmatch 'ApprovalReady = \$true' -or $wrapper -notmatch 'RequiresSecondApproval = \$true') {
    throw 'Image maintenance does not expose a non-mutating plan before elevation and the second approval.'
}
$scenarios.Add('plan-only-precedes-elevation')

foreach ($requiredPlanText in @('Baseline VM only during servicing', 'at most one worker running', 'Recovery Current is untouched', 'push to the public GitHub repository after live success')) {
    if ($wrapper.IndexOf($requiredPlanText, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "Image-maintenance plan is missing: $requiredPlanText" }
}
if ($wrapper -notmatch 'ExpectedDotNetSdkVersion' -or $wrapper -notmatch 'PreserveRecoveryPrevious') {
    throw 'Image maintenance does not pin the SDK version or preserve the prior recovery generation.'
}
$scenarios.Add('plan-covers-live-local-and-github-recovery')

foreach ($networkContract in @('Connect-VMNetworkAdapter', 'Disconnect-VMNetworkAdapter', 'Enable-GuestTemporaryDhcp', 'Restore-GuestNetworkConfiguration', 'MatchesOriginal = $true', 'Wait-GuestUpdateConnectivity', 'Invoke-UpdateSearchWithRetry', '8024001E', "Type='Software'", 'BrowseOnly', 'FeatureUpgrade', 'FailedUpdates', 'Microsoft Corporation', 'SHA512', 'WU_E_DS_UNKNOWNSERVICE', 'ServerSelection 2')) {
    if ($guestServicing.IndexOf($networkContract, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "Guest servicing is missing contract: $networkContract" }
}
if ($guestServicing -notmatch 'finally\s*\{' -or $guestServicing -notmatch 'if \(\$networkConnected\)') {
    throw 'Guest servicing does not fail closed by disconnecting temporary networking in finally.'
}
$absoluteDotNetPathCount = ([regex]::Matches($guestServicing, 'Join-Path \$env:ProgramFiles ''dotnet\\dotnet\.exe''', [Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
if ($absoluteDotNetPathCount -lt 2 -or $guestServicing.IndexOf('& $dotnetPath --list-sdks', [StringComparison]::Ordinal) -lt 0) {
    throw 'Guest inventory and post-install verification do not tolerate a stale process PATH after SDK installation.'
}
if ($guestServicing.IndexOf('if ([string]$sdk.Version -in $installedVersions)', [StringComparison]::Ordinal) -lt 0 -or
    $guestServicing.IndexOf('AlreadyInstalled = $true', [StringComparison]::Ordinal) -lt 0) {
    throw 'Guest SDK servicing is not idempotent after a verified install followed by controller resume.'
}
if ($guestServicing.IndexOf('Invoke-DotNetSmokeCommand', [StringComparison]::Ordinal) -lt 0 -or
    $guestServicing.IndexOf('2>&1 | ForEach-Object', [StringComparison]::Ordinal) -lt 0 -or
    $guestServicing.IndexOf('DOTNET_SKIP_FIRST_TIME_EXPERIENCE', [StringComparison]::Ordinal) -lt 0) {
    throw 'The SDK smoke test can promote benign native stderr into an opaque PowerShell remoting failure.'
}
$scenarios.Add('guest-servicing-network-and-update-policy-fail-closed')

$passRecordPosition = $guestServicing.IndexOf('$windowsUpdatePasses.Add($record)', [StringComparison]::Ordinal)
$convergencePosition = $guestServicing.IndexOf('function Invoke-WindowsUpdateToConvergence', [StringComparison]::Ordinal)
$searchOperationPosition = $guestServicing.IndexOf('$search = Invoke-Command -Session $activeSession', $convergencePosition, [StringComparison]::Ordinal)
$searchIdlePosition = $guestServicing.IndexOf('Wait-GuestWindowsUpdateIdle -CurrentSession $activeSession', $searchOperationPosition, [StringComparison]::Ordinal)
$searchCancellationPosition = $guestServicing.IndexOf('Assert-ImageServicingNotCancelled', $searchIdlePosition, [StringComparison]::Ordinal)
$downloadOperationPosition = $guestServicing.IndexOf('$download = Invoke-Command -Session $activeSession', $searchCancellationPosition, [StringComparison]::Ordinal)
$downloadIdlePosition = $guestServicing.IndexOf('Wait-GuestWindowsUpdateIdle -CurrentSession $activeSession', $downloadOperationPosition, [StringComparison]::Ordinal)
$downloadCancellationPosition = $guestServicing.IndexOf('Assert-ImageServicingNotCancelled', $downloadIdlePosition, [StringComparison]::Ordinal)
$installOperationPosition = $guestServicing.IndexOf('$installation = Invoke-Command -Session $activeSession', $downloadCancellationPosition, [StringComparison]::Ordinal)
$installIdlePosition = $guestServicing.IndexOf('Wait-GuestWindowsUpdateIdle -CurrentSession $activeSession', $installOperationPosition, [StringComparison]::Ordinal)
$installCancellationPosition = $guestServicing.IndexOf('Assert-ImageServicingNotCancelled', $installIdlePosition, [StringComparison]::Ordinal)
$cancellationCheckPosition = $guestServicing.IndexOf('Assert-ImageServicingNotCancelled', $passRecordPosition, [StringComparison]::Ordinal)
$conditionalRebootPosition = $guestServicing.IndexOf('if ([bool]$result.RebootRequired)', $passRecordPosition, [StringComparison]::Ordinal)
$zeroSelectionReturnPosition = $guestServicing.IndexOf('if ([int]$result.SelectedCount -eq 0)', $conditionalRebootPosition, [StringComparison]::Ordinal)
if ($searchOperationPosition -lt 0 -or $searchIdlePosition -le $searchOperationPosition -or $searchCancellationPosition -le $searchIdlePosition -or
    $downloadOperationPosition -le $searchCancellationPosition -or $downloadIdlePosition -le $downloadOperationPosition -or $downloadCancellationPosition -le $downloadIdlePosition -or
    $installOperationPosition -le $downloadCancellationPosition -or $installIdlePosition -le $installOperationPosition -or $installCancellationPosition -le $installIdlePosition -or
    $passRecordPosition -le $installCancellationPosition -or
    $cancellationCheckPosition -le $passRecordPosition -or $conditionalRebootPosition -le $cancellationCheckPosition -or
    $zeroSelectionReturnPosition -le $conditionalRebootPosition -or $guestServicing.IndexOf('if ($sdkRequiresReboot)', [StringComparison]::Ordinal) -lt 0) {
    throw 'Guest servicing does not stop between search, download, install, idle confirmation, cancellation, and restart decisions.'
}
if ($guestServicing.IndexOf('PendingFileRenameAutomaticRestartAuthorized = $false', [StringComparison]::Ordinal) -lt 0 -or
    $guestServicing.IndexOf('Windows Update or CBS still explicitly requires a reboot', [StringComparison]::Ordinal) -lt 0) {
    throw 'Pending file-renames are not separated from explicit Windows Update and CBS reboot requirements.'
}
if ($wrapper.IndexOf('while (-not $process.WaitForExit(1000))', [StringComparison]::Ordinal) -lt 0 -or
    $wrapper.IndexOf('elevated controller PID', [StringComparison]::Ordinal) -lt 0 -or
    $wrapper.IndexOf('Watch-ImageUpdateLauncher.ps1', [StringComparison]::Ordinal) -lt 0 -or
    $watcher.IndexOf('CancellationPath', [StringComparison]::Ordinal) -lt 0 -or
    $watcher.IndexOf('Stop-Process', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
    $guestServicing.IndexOf('Assert-ImageServicingNotCancelled', [StringComparison]::Ordinal) -lt 0 -or
    $imageUpdate.IndexOf('Assert-ImageUpdateNotCancelled', [StringComparison]::Ordinal) -lt 0) {
    throw 'The visible image-maintenance launcher does not request cooperative cancellation and cleanup.'
}
if ($guestServicing.IndexOf("[ValidateSet('Automatic', 'Manual')]", [StringComparison]::Ordinal) -lt 0 -or
    $guestServicing.IndexOf('ManualRebootPending', [StringComparison]::Ordinal) -lt 0 -or
    $guestServicing.IndexOf('AutomaticRestartAuthorized = $false', [StringComparison]::Ordinal) -lt 0 -or
    $imageUpdate.IndexOf("-Phase 'ManualRebootPending'", [StringComparison]::Ordinal) -lt 0) {
    throw 'Guest servicing does not expose a user-controlled restart and resumable stop state.'
}
$scenarios.Add('guest-reboots-only-when-required-and-cancels-cooperatively')

foreach ($guardContract in @('NoAutoRebootWithLoggedOnUsers', 'AlwaysAutoRebootAtScheduledTime', 'baseline-manual-restart-guard.json', 'if ($restartGuardActive -and -not $manualRestartPending)', 'Guest servicing cleanup was incomplete')) {
    if ($guestServicing.IndexOf($guardContract, [StringComparison]::Ordinal) -lt 0) { throw "Manual guest restart guard is missing lifecycle contract: $guardContract" }
}
$scenarios.Add('manual-restart-guard-persists-only-while-awaiting-user')

if ($wrapper.IndexOf('AdoptCurrentBaseline', [StringComparison]::Ordinal) -lt 0 -or
    $wrapper.IndexOf("requires -GuestRestartMode Manual", [StringComparison]::Ordinal) -lt 0 -or
    $imageUpdate.IndexOf("elseif (-not `$AdoptCurrentBaseline -and `$GuestRestartMode -eq 'Automatic')", [StringComparison]::Ordinal) -lt 0 -or
    $imageUpdate.IndexOf('AllowApprovedConnectedStart:$AdoptCurrentBaseline', [StringComparison]::Ordinal) -lt 0 -or
    $imageUpdate.IndexOf('ManualBaselineStateRetained', [StringComparison]::Ordinal) -lt 0 -or
    $guestServicing.IndexOf('AllowApprovedConnectedStart', [StringComparison]::Ordinal) -lt 0) {
    throw 'Manual restart cannot resume from or adopt the preserved current baseline without restoring the old checkpoint.'
}
$scenarios.Add('manual-restart-resumes-from-preserved-current-baseline')

$watcherTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-image-watcher-test-' + [Guid]::NewGuid().ToString('N'))
$dummyLauncher = $null
$watcherProcess = $null
try {
    New-Item -ItemType Directory -Force -Path $watcherTestRoot | Out-Null
    $cancellationTestPath = Join-Path $watcherTestRoot 'cancel.json'
    $dummyLauncher = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
    $dummyStartTicks = $dummyLauncher.StartTime.ToUniversalTime().Ticks
    $watcherProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $watcherPath + '"'),
        '-LauncherProcessId',$dummyLauncher.Id,
        '-LauncherStartTimeUtcTicks',$dummyStartTicks,
        '-CancellationPath',('"' + $cancellationTestPath + '"'),
        '-PollMilliseconds',100
    ) -WindowStyle Hidden -PassThru
    Stop-Process -Id $dummyLauncher.Id -Force -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $cancellationTestPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $cancellationTestPath -PathType Leaf)) { throw 'Launcher watcher did not write a cooperative cancellation request.' }
    $request = Get-Content -Raw -LiteralPath $cancellationTestPath | ConvertFrom-Json
    if ([int]$request.LauncherProcessId -ne [int]$dummyLauncher.Id -or [string]$request.Reason -notmatch 'launcher exited') {
        throw 'Launcher watcher wrote an invalid cancellation request.'
    }
}
finally {
    if ($dummyLauncher -and -not $dummyLauncher.HasExited) { Stop-Process -Id $dummyLauncher.Id -Force -ErrorAction SilentlyContinue }
    if ($watcherProcess -and -not $watcherProcess.HasExited) { Stop-Process -Id $watcherProcess.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $watcherTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$scenarios.Add('launcher-loss-produces-tested-cooperative-cancellation-signal')

$cleanupTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-image-cleanup-test-' + [Guid]::NewGuid().ToString('N'))
$cleanupLauncher = $null
$cleanupWatcher = $null
$inertController = $null
try {
    New-Item -ItemType Directory -Force -Path $cleanupTestRoot | Out-Null
    $cleanupCancellationPath = Join-Path $cleanupTestRoot 'cancel.json'
    $cleanupStatePath = Join-Path $cleanupTestRoot 'state.json'
    $cleanupLauncher = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
    $cleanupLauncherTicks = $cleanupLauncher.StartTime.ToUniversalTime().Ticks
    $cleanupWatcher = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $watcherPath + '"'),
        '-LauncherProcessId',$cleanupLauncher.Id,
        '-LauncherStartTimeUtcTicks',$cleanupLauncherTicks,
        '-CancellationPath',('"' + $cleanupCancellationPath + '"'),
        '-PollMilliseconds',100
    ) -WindowStyle Hidden -PassThru
    $inertController = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $inertControllerPath + '"'),
        '-RunInertController',
        '-InertStatePath',('"' + $cleanupStatePath + '"'),
        '-InertCancellationPath',('"' + $cleanupCancellationPath + '"'),
        '-InertSynchronousOperationSeconds',3
    ) -WindowStyle Hidden -PassThru

    $startDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $startedState = if (Test-Path -LiteralPath $cleanupStatePath -PathType Leaf) { Get-Content -Raw -LiteralPath $cleanupStatePath | ConvertFrom-Json } else { $null }
        if ($startedState -and [bool]$startedState.SynchronousOperationStarted) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $startDeadline)
    if (-not $startedState -or -not [bool]$startedState.SynchronousOperationStarted) { throw 'The inert controller did not enter its bounded synchronous operation.' }

    Stop-Process -Id $cleanupLauncher.Id -Force -ErrorAction Stop
    if (-not $inertController.WaitForExit(15000)) { throw 'The inert controller did not exit after cooperative cancellation.' }
    if (-not $cleanupWatcher.WaitForExit(5000)) { throw 'The launcher watcher did not exit after writing cancellation.' }
    $cleanedState = Get-Content -Raw -LiteralPath $cleanupStatePath | ConvertFrom-Json
    if (-not [bool]$cleanedState.Cancelled -or
        -not [bool]$cleanedState.SynchronousOperationCompleted -or
        [bool]$cleanedState.NextMutationStarted -or
        [string]$cleanedState.NetworkState -ne 'Disconnected' -or
        [string]$cleanedState.BrokerState -ne 'Running' -or
        [bool]$cleanedState.MaintenanceMarkerPresent -or
        -not [bool]$cleanedState.CleanupCompleted) {
        throw ('Cooperative cancellation did not finish the synchronous operation and restore inert controller state: ' + ($cleanedState | ConvertTo-Json -Depth 6 -Compress))
    }
}
finally {
    foreach ($process in @($cleanupLauncher, $cleanupWatcher, $inertController)) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $cleanupTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$scenarios.Add('controller-cancellation-finishes-current-operation-and-restores-state')

foreach ($resolverContract in @('dotnetcli.blob.core.windows.net', 'builds.dotnet.microsoft.com', 'latest-sdk', 'win-x64', 'Get-AuthenticodeSignature', 'changed after approval')) {
    if ($resolver.IndexOf($resolverContract, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "SDK resolver is missing contract: $resolverContract" }
}
$scenarios.Add('sdk-resolver-pins-and-verifies-official-payload')

$deferPosition = $installer.IndexOf('-DeferBaselineCheckpoint', [StringComparison]::Ordinal)
$servicingPosition = $installer.IndexOf("'Update-WindowsGuestImage.ps1'", [StringComparison]::Ordinal)
$checkpointPosition = $installer.IndexOf('Checkpoint-VM -VMName', $servicingPosition, [StringComparison]::Ordinal)
if ($deferPosition -lt 0 -or $servicingPosition -le $deferPosition -or $checkpointPosition -le $servicingPosition) {
    throw 'Cold rebuild does not service the new guest before creating the clean checkpoint.'
}
if ($installer -notmatch 'GuestUpdateSwitchName' -or $installer -notmatch 'ExpectedDotNetSdkVersion' -or $installer -notmatch 'NetworkFinalState') {
    throw 'Cold-rebuild planning does not carry the approved guest update network and SDK pin.'
}
$scenarios.Add('cold-rebuild-services-before-sealing')

$candidatePosition = $imageUpdate.IndexOf('Checkpoint-VM -VMName $baselineVm.Name -SnapshotName $candidateCheckpointName', [StringComparison]::Ordinal)
$workerLoopPosition = $imageUpdate.IndexOf('foreach ($workerDefinition in @($oldDefinition.Workers | Sort-Object WorkerId))', $candidatePosition + 1, [StringComparison]::Ordinal)
$workerVerifyPosition = $imageUpdate.IndexOf('Test-WorkerImage -VmName $vmName', $workerLoopPosition, [StringComparison]::Ordinal)
$promotePosition = $imageUpdate.IndexOf('Rename-VMSnapshot -VMSnapshot $canonicalCheckpoint', [StringComparison]::Ordinal)
if ($candidatePosition -lt 0 -or $workerLoopPosition -le $candidatePosition -or $workerVerifyPosition -le $workerLoopPosition -or $promotePosition -le $workerVerifyPosition) {
    throw 'The candidate checkpoint is promoted before all sequential workers verify.'
}
if ($imageUpdate -notmatch 'preupdate-\$updateId' -or $imageUpdate -notmatch 'Restore-WorkerRegistration') {
    throw 'Sequential worker replacement does not retain and restore prior registrations.'
}
$scenarios.Add('candidate-and-workers-are-transactional')

foreach ($resumeContract in @(
    'ResumeUpdateId',
    'ResumingRetainedGeneration',
    'The retained updated checkpoint is not a direct child of the current rollback checkpoint',
    'ReadyToSeal',
    'ReusedRetainedBase',
    '-UseExistingOsChild:$resumeRetainedGeneration',
    'Restore-VMSnapshot -VMSnapshot $promotedCheckpoint',
    'RetainedGenerationPreserved'
)) {
    if ($imageUpdate.IndexOf($resumeContract, [StringComparison]::Ordinal) -lt 0) { throw "Retained-generation resume is missing contract: $resumeContract" }
}
if ($wrapper.IndexOf('ResumeUpdateId', [StringComparison]::Ordinal) -lt 0 -or
    $wrapper.IndexOf('do not run Windows Update or boot the baseline', [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
    $maintenanceDoc.IndexOf("ResumeUpdateId = '<YYYYMMDDTHHMMSSFFFZ>'", [StringComparison]::Ordinal) -lt 0 -or
    $setupSkill.IndexOf('-ResumeUpdateId <EXACT_FAILED_UPDATE_ID>', [StringComparison]::Ordinal) -lt 0) {
    throw 'The approval-gated wrapper and maintenance guidance do not expose retained-generation resume.'
}
$resumeValidationPosition = $imageUpdate.IndexOf("Write-UpdateStatus -Phase 'ResumingRetainedGeneration'", [StringComparison]::Ordinal)
$resumeWorkerReusePosition = $imageUpdate.IndexOf('-UseExistingOsChild:$resumeRetainedGeneration', $resumeValidationPosition, [StringComparison]::Ordinal)
$resumePromotionPosition = $imageUpdate.IndexOf('Restore-VMSnapshot -VMSnapshot $promotedCheckpoint', $resumeWorkerReusePosition, [StringComparison]::Ordinal)
if ($resumeValidationPosition -lt 0 -or $resumeWorkerReusePosition -le $resumeValidationPosition -or $resumePromotionPosition -le $resumeWorkerReusePosition) {
    throw 'Retained-generation resume can promote the baseline before reused workers are sequentially re-verified.'
}
$scenarios.Add('retained-generation-resume-skips-baseline-servicing-and-reverifies-workers')

if ($imageUpdate -notmatch "PSObject\.Properties\['ActiveRequestId'\]" -or
    $imageUpdate -notmatch 'UseExistingOsChild' -or
    $imageUpdate -notmatch 'RecreatedFromExistingDisk' -or
    $imageUpdate -notmatch 'VmName -in \$touchedWorkerNames') {
    throw 'Image maintenance is not restart-safe after legacy pool state or a partial worker-registration rollback.'
}
$scenarios.Add('legacy-state-and-partial-registration-rollback-are-restart-safe')

$auditPosition = $imageUpdate.IndexOf("'Audit-HyperVTestPool.ps1'", [StringComparison]::Ordinal)
$smokePosition = $imageUpdate.IndexOf('Invoke-HyperVExecutableTest.ps1', [StringComparison]::Ordinal)
$recoveryPosition = $imageUpdate.IndexOf("'Recovery\New-CodexHyperVRecovery.ps1'", [StringComparison]::Ordinal)
if ($auditPosition -lt 0 -or $smokePosition -le $auditPosition -or $recoveryPosition -le $smokePosition) {
    throw 'Local recovery is refreshed before the updated pool audit and isolated canary pass.'
}
if ($recovery -notmatch 'ImageServicing' -or $recovery -notmatch 'WindowsUpdatePassCount' -or $recovery -notmatch 'DotNetSdks') {
    throw 'The recovery manifest does not record sanitized image-servicing provenance.'
}
if ($recovery -notmatch "BaselineExportMode\s*=\s*'FullExport'" -or
    $imageUpdate -match "New-CodexHyperVRecovery\.ps1'[^\r\n]*ReuseCurrent") {
    throw 'Image maintenance can bypass the mandatory full baseline recovery export.'
}
$scenarios.Add('recovery-follows-live-verification-and-records-provenance')

if ($maintenanceDoc -notmatch 'Update-Images.ps1 @parameters -PlanOnly' -or $maintenanceDoc -notmatch 'deep-hash' -or $setupSkill -notmatch 'intentional Windows/.NET baseline refresh') {
    throw 'Maintenance documentation or the setup skill does not route image updates through the approval-gated workflow.'
}
$scenarios.Add('maintenance-documentation-routes-through-skill')

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-image-maintenance-test-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    $indexPath = Join-Path $temporaryRoot 'index.json'
    $releasesPath = Join-Path $temporaryRoot 'releases.json'
    [ordered]@{
        'releases-index' = @([ordered]@{
            'channel-version' = '10.0'
            'latest-sdk' = '10.0.400'
            'support-phase' = 'active'
            'release-type' = 'lts'
            'releases.json' = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
        })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $indexPath -Encoding UTF8
    [ordered]@{
        'latest-sdk' = '10.0.400'
        releases = @([ordered]@{
            'release-date' = '2026-08-11'
            sdk = [ordered]@{
                version = '10.0.400'
                'runtime-version' = '10.0.11'
                files = @([ordered]@{
                    name = 'dotnet-sdk-win-x64.exe'
                    rid = 'win-x64'
                    url = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.400/dotnet-sdk-10.0.400-win-x64.exe'
                    hash = ('A' * 128)
                })
            }
        })
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $releasesPath -Encoding UTF8

    $resolved = & $resolverPath -Channel '10.0' -ExpectedVersion '10.0.400' -ReleaseIndexPath $indexPath -ReleasesPath $releasesPath -AllowUnsignedLocalMetadata
    if ([string]$resolved.Version -ne '10.0.400' -or [string]$resolved.Sha512 -ne ('A' * 128) -or [bool]$resolved.Downloaded) {
        throw 'The deterministic SDK metadata resolution returned an unexpected result.'
    }
    $mismatchRejected = $false
    try {
        & $resolverPath -Channel '10.0' -ExpectedVersion '10.0.399' -ReleaseIndexPath $indexPath -ReleasesPath $releasesPath -AllowUnsignedLocalMetadata | Out-Null
    }
    catch {
        $mismatchRejected = $_.Exception.Message -match 'changed after approval'
    }
    if (-not $mismatchRejected) { throw 'The SDK resolver did not reject a version change after approval.' }
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$scenarios.Add('deterministic-sdk-resolution-and-version-drift-rejection')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
