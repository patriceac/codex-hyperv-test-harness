[CmdletBinding()]
param(
    [string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness',
    [string] $GuestUpdateSwitchName = 'Default Switch',
    [ValidatePattern('^\d+\.\d+$')] [string] $DotNetChannel = '10.0',
    [string] $ExpectedDotNetSdkVersion,
    [string] $ExpectedDotNet8SdkVersion,
    [string] $ExpectedDotNet9SdkVersion,
    [string] $TargetUserProfile,
    [string] $TargetUserSid,
    [ValidateSet('Automatic', 'Manual')] [string] $GuestRestartMode = 'Automatic',
    [switch] $AdoptCurrentBaseline,
    [ValidatePattern('^\d{8}T\d{9}Z$')] [string] $ResumeUpdateId,
    [switch] $PreserveRecoveryPrevious,
    [switch] $SkipSmokeTest,
    [switch] $PlanOnly,
    [switch] $NoElevation,
    [ValidateRange(0, [int]::MaxValue)] [int] $ElevationLauncherProcessId = 0,
    [ValidateRange(0, [long]::MaxValue)] [long] $ElevationLauncherStartTimeUtcTicks = 0
)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($InstallRoot) -or [IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) {
    throw 'InstallRoot must be a specific non-root directory.'
}
if ([string]::IsNullOrWhiteSpace($TargetUserProfile)) { $TargetUserProfile = $env:USERPROFILE }
if ([string]::IsNullOrWhiteSpace($TargetUserSid)) { $TargetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
try { [void][Security.Principal.SecurityIdentifier]::new($TargetUserSid) } catch { throw "Invalid target-user SID: $TargetUserSid" }
if ([string]::IsNullOrWhiteSpace($ExpectedDotNetSdkVersion)) {
    throw 'Pass the exact latest stable SDK version approved during preflight with -ExpectedDotNetSdkVersion.'
}
if ($AdoptCurrentBaseline -and $GuestRestartMode -ne 'Manual') {
    throw '-AdoptCurrentBaseline requires -GuestRestartMode Manual so the preserved guest is never restarted automatically.'
}
if (-not [string]::IsNullOrWhiteSpace($ResumeUpdateId) -and $AdoptCurrentBaseline) {
    throw '-ResumeUpdateId cannot be combined with -AdoptCurrentBaseline.'
}
if (-not [string]::IsNullOrWhiteSpace($ResumeUpdateId) -and $GuestRestartMode -ne 'Manual') {
    throw '-ResumeUpdateId requires -GuestRestartMode Manual so the baseline guest is never restarted during recovery.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$checkoutSoftware = Join-Path $repositoryRoot 'src\Software'
$installedSoftware = Join-Path $InstallRoot 'Software'
$installedSetup = Join-Path $installedSoftware 'Setup'
$configPath = Join-Path $installedSoftware 'harness-config.json'
$logPath = Join-Path $InstallRoot 'Live\Setup\image-update.log'
$cancellationPath = Join-Path $InstallRoot 'Live\Setup\image-update-cancel.requested.json'
$expectedInstalledChannels = @{}
if (-not [string]::IsNullOrWhiteSpace($ExpectedDotNet8SdkVersion)) { $expectedInstalledChannels['8.0'] = $ExpectedDotNet8SdkVersion }
if (-not [string]::IsNullOrWhiteSpace($ExpectedDotNet9SdkVersion)) { $expectedInstalledChannels['9.0'] = $ExpectedDotNet9SdkVersion }

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination,
        [string[]] $ExcludeFiles = @(),
        [string[]] $ExcludeDirectories = @()
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $arguments = @($Source, $Destination, '/MIR', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($ExcludeFiles.Count -gt 0) { $arguments += '/XF'; $arguments += $ExcludeFiles }
    if ($ExcludeDirectories.Count -gt 0) { $arguments += '/XD'; $arguments += $ExcludeDirectories }
    & robocopy.exe @arguments | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Robocopy failed with exit code $LASTEXITCODE while staging '$Source'." }
}

function Get-ElevationArguments {
    $launcher = Get-Process -Id $PID -ErrorAction Stop
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
        '-InstallRoot', ('"' + $InstallRoot + '"'),
        '-GuestUpdateSwitchName', ('"' + $GuestUpdateSwitchName + '"'),
        '-DotNetChannel', $DotNetChannel,
        '-ExpectedDotNetSdkVersion', $ExpectedDotNetSdkVersion,
        '-TargetUserProfile', ('"' + $TargetUserProfile + '"'),
        '-TargetUserSid', $TargetUserSid,
        '-GuestRestartMode', $GuestRestartMode,
        '-ElevationLauncherProcessId', $PID,
        '-ElevationLauncherStartTimeUtcTicks', $launcher.StartTime.ToUniversalTime().Ticks,
        '-NoElevation'
    )
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDotNet8SdkVersion)) { $arguments += @('-ExpectedDotNet8SdkVersion', $ExpectedDotNet8SdkVersion) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDotNet9SdkVersion)) { $arguments += @('-ExpectedDotNet9SdkVersion', $ExpectedDotNet9SdkVersion) }
    if ($AdoptCurrentBaseline) { $arguments += '-AdoptCurrentBaseline' }
    if (-not [string]::IsNullOrWhiteSpace($ResumeUpdateId)) { $arguments += @('-ResumeUpdateId', $ResumeUpdateId) }
    if ($PreserveRecoveryPrevious) { $arguments += '-PreserveRecoveryPrevious' }
    if ($SkipSmokeTest) { $arguments += '-SkipSmokeTest' }
    $arguments
}

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Harness configuration is missing: $configPath" }
. (Join-Path $installedSoftware 'Harness\HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $configPath
$definitionPath = Join-Path ([string]$layout.HarnessSourceRoot) 'pool-definition.json'
if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) { throw "Pool definition is missing: $definitionPath" }
$definition = Get-Content -Raw -LiteralPath $definitionPath | ConvertFrom-Json

if ($PlanOnly) {
    $resumeRetainedGeneration = -not [string]::IsNullOrWhiteSpace($ResumeUpdateId)
    $brokerRoot = [string]$layout.BrokerRoot
    $brokerStatePath = Join-Path $brokerRoot 'State\broker-state.json'
    $poolStatePath = Join-Path $brokerRoot 'State\pool-state.json'
    $brokerState = if (Test-Path -LiteralPath $brokerStatePath -PathType Leaf) { Get-Content -Raw -LiteralPath $brokerStatePath | ConvertFrom-Json } else { $null }
    $poolState = if (Test-Path -LiteralPath $poolStatePath -PathType Leaf) { Get-Content -Raw -LiteralPath $poolStatePath | ConvertFrom-Json } else { $null }
    $queueCount = @(Get-ChildItem -LiteralPath (Join-Path $brokerRoot 'Requests') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $processingCount = @(Get-ChildItem -LiteralPath (Join-Path $brokerRoot 'Processing') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $driveName = [IO.Path]::GetPathRoot($InstallRoot).TrimEnd('\').TrimEnd(':')
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    $currentRecoveryManifest = Join-Path ([string]$layout.RecoveryRoot) 'Current\manifest.json'
    $previousRecoveryManifest = Join-Path ([string]$layout.RecoveryRoot) 'Previous\manifest.json'
    $repositoryCommit = $null
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        $repositoryCommit = (& git.exe -C $repositoryRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    }
    $resolvedSdkMetadata = New-Object Collections.Generic.List[object]
    $resolvedSdkMetadata.Add((& (Join-Path $checkoutSoftware 'Harness\Resolve-DotNetSdkInstaller.ps1') -Channel $DotNetChannel -ExpectedVersion $ExpectedDotNetSdkVersion))
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDotNet8SdkVersion)) { $resolvedSdkMetadata.Add((& (Join-Path $checkoutSoftware 'Harness\Resolve-DotNetSdkInstaller.ps1') -Channel '8.0' -ExpectedVersion $ExpectedDotNet8SdkVersion)) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDotNet9SdkVersion)) { $resolvedSdkMetadata.Add((& (Join-Path $checkoutSoftware 'Harness\Resolve-DotNetSdkInstaller.ps1') -Channel '9.0' -ExpectedVersion $ExpectedDotNet9SdkVersion)) }
    [pscustomobject][ordered]@{
        PlanOnly = $true
        NoMutationPerformed = $true
        RepositoryRoot = $repositoryRoot
        RepositoryCommit = $repositoryCommit
        InstallRoot = [string]$layout.InstallRoot
        TargetUserProfile = $TargetUserProfile
        TargetUserSid = $TargetUserSid
        CurrentConfiguration = [ordered]@{
            BaselineVm = [string]$layout.BaselineVmName
            BaselineCheckpoint = [string]$layout.BaselineCheckpointName
            PoolSize = [int]$layout.PoolSize
            WorkerVms = @($definition.Workers | Sort-Object WorkerId | ForEach-Object { [string]$_.VmName })
            VmMemoryGiB = [math]::Round(([long]$layout.VmMemoryBytes / 1GB), 2)
            VmProcessorCount = [int]$layout.VmProcessorCount
            Display = "$($layout.GuestDisplayWidth)x$($layout.GuestDisplayHeight)"
            IdleTimeoutSeconds = [int]$layout.PoolIdleTimeoutSeconds
            NetworkPolicy = [string]$layout.NetworkPolicy
        }
        CurrentState = [ordered]@{
            QueueCount = $queueCount
            ProcessingCount = $processingCount
            BrokerStatus = if ($brokerState) { [string]$brokerState.Status } else { 'Missing' }
            BrokerHeartbeatUtc = if ($brokerState) { [string]$brokerState.HeartbeatUtc } else { $null }
            PoolWorkers = if ($poolState) { @($poolState.Workers | ForEach-Object { [ordered]@{
                VmName = [string]$_.VmName
                Status = [string]$_.Status
                OsClean = [bool]$_.OsClean
                ActiveRequestId = if ($_.PSObject.Properties['ActiveRequestId']) { [string]$_.ActiveRequestId } else { $null }
            } }) } else { @() }
            FreeBytes = [long]$drive.Free
            CurrentRecoveryPresent = Test-Path -LiteralPath $currentRecoveryManifest -PathType Leaf
            PreviousRecoveryPresent = Test-Path -LiteralPath $previousRecoveryManifest -PathType Leaf
        }
        ApprovedServicing = [ordered]@{
            WindowsUpdate = if ($resumeRetainedGeneration) { "Skipped; retained update $ResumeUpdateId already has a successful ReadyToSeal servicing record" } else { 'Applicable non-preview Microsoft software, security, quality, and Defender updates for the installed feature version; no drivers or feature-version upgrade' }
            TemporaryNetworkSwitch = $GuestUpdateSwitchName
            NetworkScope = if ($resumeRetainedGeneration) { 'No temporary update networking; the baseline remains off and disconnected; workers remain disconnected' } else { 'Baseline VM only during servicing; disconnected before sealing; workers remain disconnected' }
            DotNetPrimary = [ordered]@{ Channel = $DotNetChannel; Version = $ExpectedDotNetSdkVersion; Architecture = 'win-x64'; Stability = 'stable' }
            ExistingSupportedChannels = [ordered]@{ '8.0' = $ExpectedDotNet8SdkVersion; '9.0' = $ExpectedDotNet9SdkVersion }
            Integrity = 'Official Microsoft HTTPS metadata, SHA-512 match, and valid Microsoft Authenticode signature'
            ResolvedMetadata = $resolvedSdkMetadata.ToArray()
            GuestRestartMode = $GuestRestartMode
            AdoptCurrentBaseline = [bool]$AdoptCurrentBaseline
            ResumeUpdateId = $ResumeUpdateId
            RestartBehavior = if ($resumeRetainedGeneration) { 'No baseline guest boot or restart; retained workers are booted and shut down sequentially for verification' } elseif ($GuestRestartMode -eq 'Manual') { 'Report ManualRebootPending, restore transient host state, and wait for a user-controlled guest restart before resume' } else { 'Restart only when Windows Update, CBS, or a verified installer result explicitly requires it' }
            CancellationBehavior = 'Finish the current synchronous operation, then stop before any reboot or next mutation and restore transient host state'
        }
        Sequence = @(
            'Drain the empty queue and enter maintenance',
            $(if ($resumeRetainedGeneration) { "Validate retained update ${ResumeUpdateId}: failed checkpoint, ReadyToSeal servicing record, privileged audit, immutable base, and four disconnected differencing disks; do not run Windows Update or boot the baseline" } elseif ($AdoptCurrentBaseline) { 'Preserve and service the current baseline state without restoring the canonical checkpoint; retain that checkpoint as rollback' } elseif ($GuestRestartMode -eq 'Manual') { 'Restore and service the canonical baseline; stop in ManualRebootPending whenever an explicit restart is required, then resume with AdoptCurrentBaseline' } else { 'Restore and service the canonical baseline; restart only on an explicit Windows or installer requirement until updates converge' }),
            $(if ($resumeRetainedGeneration) { 'Reuse the retained checkpoint and pool base without modifying the baseline guest disk before promotion' } else { 'Verify SDK build smoke, pending-reboot state, shutdown, and network disconnection' }),
            $(if ($resumeRetainedGeneration) { 'Re-register the retained updated worker disks one at a time' } else { 'Create a candidate checkpoint and versioned immutable pool base while retaining the current generation' }),
            'Rename, replace, boot-verify, and shut down worker 01, then 02, 03, and 04 with at most one worker running',
            $(if ($resumeRetainedGeneration) { 'Promote and restore the retained checkpoint only after all four workers verify; write the retained pool definition; reinstall or repair the SYSTEM broker' } else { 'Promote the candidate checkpoint and pool definition atomically; reinstall or repair the SYSTEM broker' }),
            'Run the privileged pool audit and isolated visual canary',
            'Retire backup VM registrations only after verification while retaining prior pool disks and definition locally',
            'Archive the older Previous recovery generation, export the updated baseline, deep-hash verify, and rotate Current to Previous',
            'Run the public audit again, commit the source-only recovery changes, and push to the public GitHub repository after live success'
        )
        Rollback = [ordered]@{
            Baseline = 'The canonical checkpoint remains unchanged until the candidate baseline and all workers verify'
            Workers = 'Each old worker is retained under a temporary backup name until its replacement verifies; the whole pool is restored on failure'
            Recovery = 'Recovery Current is untouched until a fully verified staged export is promoted; the existing Previous generation is archived when requested'
            PreviousPoolFilesRetained = $true
            RetainedGeneration = if ($resumeRetainedGeneration) { "Existing audited generation $ResumeUpdateId remains available through rollback" } else { $null }
        }
        PersistentChanges = @(
            'Updated canonical baseline checkpoint',
            $(if ($resumeRetainedGeneration) { "Adopted existing audited pool generation $ResumeUpdateId with its immutable base and four differencing worker disks" } else { 'New versioned immutable pool base and four differencing worker disks' }),
            'Recreated canonical worker VM registrations, one at a time',
            'Reinstalled or repaired ACL-restricted SYSTEM broker task',
            'New Recovery Current plus retained pre-update recovery generations',
            'Source-only repository changes prepared for an audited public GitHub push'
        )
        ExplicitlyExcluded = @('Host reboot','Windows activation or product key','Microsoft account sign-in','Unrelated Hyper-V VMs','Preview updates','Optional drivers','Windows feature-version upgrade','.NET preview SDKs','VM images or credentials in Git')
        RequiresSecondApproval = $true
    }
    return
}

if (-not (Test-Administrator)) {
    if ($NoElevation) { throw 'Administrator rights are required for guest image maintenance.' }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-ElevationArguments) -Verb RunAs -WindowStyle Hidden -PassThru
    try {
        while (-not $process.WaitForExit(1000)) { }
        $elevatedExitCode = $process.ExitCode
    }
    finally {
        if ($process -and -not $process.HasExited) {
            Write-Warning "The visible maintenance launcher stopped while elevated controller PID $($process.Id) was finishing its current synchronous operation. Cooperative cancellation has been requested."
        }
    }
    exit $elevatedExitCode
}

$mutex = $null
$mutexTaken = $false
$transcriptStarted = $false
$launcherWatchdog = $null
if ($ElevationLauncherProcessId -gt 0 -and $ElevationLauncherStartTimeUtcTicks -gt 0) {
    $watcherPath = Join-Path $PSScriptRoot 'Watch-ImageUpdateLauncher.ps1'
    if (-not (Test-Path -LiteralPath $watcherPath -PathType Leaf)) { throw "Image-maintenance launcher watcher is missing: $watcherPath" }
    Remove-Item -LiteralPath $cancellationPath -Force -ErrorAction SilentlyContinue
    $watcherArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $watcherPath + '"'),
        '-LauncherProcessId', $ElevationLauncherProcessId,
        '-LauncherStartTimeUtcTicks', $ElevationLauncherStartTimeUtcTicks,
        '-CancellationPath', ('"' + $cancellationPath + '"')
    )
    $launcherWatchdog = Start-Process -FilePath 'powershell.exe' -ArgumentList $watcherArguments -WindowStyle Hidden -PassThru
}
try {
    $audit = & (Join-Path $PSScriptRoot 'Test-PublicRepository.ps1') -RepositoryRoot $repositoryRoot
    if (-not [bool]$audit.Success) { throw 'The public repository audit failed; refusing to stage maintenance source.' }
    $mutex = New-Object Threading.Mutex($false, 'Global\CodexHyperVImageMaintenance')
    try { $mutexTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) } catch [Threading.AbandonedMutexException] { $mutexTaken = $true }
    if (-not $mutexTaken) { throw 'Another harness image-maintenance run is already active.' }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null
    Start-Transcript -LiteralPath $logPath -Append | Out-Null
    $transcriptStarted = $true

    Invoke-Robocopy -Source $checkoutSoftware -Destination $installedSoftware -ExcludeFiles @('*.exe','harness-config.json','pool-definition.json','pool-provision-status.json','pool-broker-install-status.json','guest-credential.json') -ExcludeDirectories @('private','seed-build')
    Invoke-Robocopy -Source $PSScriptRoot -Destination $installedSetup -ExcludeDirectories @('artifacts')
    $canaries = @(& (Join-Path $installedSetup 'Build-Canaries.ps1') -CanaryRoot (Join-Path $installedSoftware 'Canaries'))

    $updateParameters = @{
        ConfigPath = $configPath
        NetworkSwitchName = $GuestUpdateSwitchName
        DotNetChannel = $DotNetChannel
        ExpectedDotNetSdkVersion = $ExpectedDotNetSdkVersion
        ExpectedInstalledChannelVersions = $expectedInstalledChannels
        TargetUserSid = $TargetUserSid
            GuestRestartMode = $GuestRestartMode
            CancellationPath = $cancellationPath
            AdoptCurrentBaseline = [bool]$AdoptCurrentBaseline
            ResumeUpdateId = $ResumeUpdateId
            PreserveRecoveryPrevious = [bool]$PreserveRecoveryPrevious
        SkipSmokeTest = [bool]$SkipSmokeTest
    }
    $result = & (Join-Path $installedSoftware 'Harness\Update-HyperVTestImages.ps1') @updateParameters
    $resultCancelled = ($null -ne $result.PSObject.Properties['Cancelled']) -and [bool]$result.Cancelled
    $resultResumeRequired = ($null -ne $result.PSObject.Properties['ResumeRequired']) -and [bool]$result.ResumeRequired
    if ($resultCancelled -or $resultResumeRequired) {
        [pscustomobject][ordered]@{
            Success = $false
            Completed = $false
            Cancelled = $resultCancelled
            ResumeRequired = $resultResumeRequired
            InstallRoot = $InstallRoot
            LogPath = $logPath
            Result = $result
        }
        return
    }
    if (-not [bool]$result.Success) { throw 'The sequential image update did not complete successfully.' }
    [pscustomobject][ordered]@{
        Success = $true
        InstallRoot = $InstallRoot
        LogPath = $logPath
        Canaries = $canaries
        Result = $result
        GitHubPublicationPending = $true
    }
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    if ($mutexTaken) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
    if ($launcherWatchdog -and -not $launcherWatchdog.HasExited) { Stop-Process -Id $launcherWatchdog.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $cancellationPath -Force -ErrorAction SilentlyContinue
}
