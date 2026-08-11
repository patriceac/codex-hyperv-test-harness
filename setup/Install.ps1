[CmdletBinding()]
param(
    [string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness',
    [string] $Language = 'Auto',
    [ValidateRange(1, 4)] [int] $PoolSize = 4,
    [ValidateRange(2, 64)] [int] $VmMemoryGiB = 8,
    [ValidateRange(1, 64)] [int] $VmProcessorCount = 4,
    [ValidateRange(60, 86400)] [int] $IdleTimeoutSeconds = 600,
    [ValidateRange(1024, 7680)] [int] $DisplayWidth = 1920,
    [ValidateRange(768, 4320)] [int] $DisplayHeight = 1080,
    [string] $TargetUserProfile,
    [string] $TargetUserSid,
    [string] $AttemptId,
    [switch] $Resume,
    [switch] $NoRestart,
    [switch] $SkipSmokeTest,
    [switch] $SkipLocalRecoveryBundle,
    [switch] $AllowLowResources,
    [switch] $ForceRebuild,
    [switch] $PlanOnly,
    [switch] $SkipGlobalPolicy,
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) { throw 'InstallRoot must be a specific non-root directory.' }
if ([string]::IsNullOrWhiteSpace($TargetUserProfile)) { $TargetUserProfile = $env:USERPROFILE }
if ([string]::IsNullOrWhiteSpace($TargetUserSid)) { $TargetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
if ([string]::IsNullOrWhiteSpace($AttemptId)) { $AttemptId = [Guid]::NewGuid().ToString('N') }
try { [void][Security.Principal.SecurityIdentifier]::new($TargetUserSid) } catch { throw "Invalid target-user SID: $TargetUserSid" }
try { [void][Guid]::ParseExact($AttemptId, 'N') } catch { throw "Invalid attempt ID: $AttemptId" }

$checkoutSoftware = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\Software'))
$runningFromCheckout = Test-Path -LiteralPath (Join-Path $checkoutSoftware 'Harness\HarnessPaths.ps1') -PathType Leaf
$sourceSoftware = if ($runningFromCheckout) { $checkoutSoftware } else { Split-Path -Parent $PSScriptRoot }
$installedSoftware = Join-Path $InstallRoot 'Software'
$installedSetup = Join-Path $installedSoftware 'Setup'
$liveRoot = Join-Path $InstallRoot 'Live'
$setupStateRoot = Join-Path $liveRoot 'Setup'
$statePath = Join-Path $setupStateRoot 'setup-state.json'
$resultPath = Join-Path $setupStateRoot 'setup-result.json'
$logPath = Join-Path $setupStateRoot 'setup.log'
$configPath = Join-Path $installedSoftware 'harness-config.json'
$resumeTaskName = 'Codex Hyper-V Source Rebuild Resume'
$startedUtc = [DateTime]::UtcNow
$transcriptStarted = $false
$mutex = $null
$mutexTaken = $false
$installerAwake = $false

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enable-InstallerAwake {
    if (-not ('CodexHyperVSetupPower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexHyperVSetupPower
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SetThreadExecutionState(uint flags);
    public static bool PreventSystemSleep() { return SetThreadExecutionState(0x80000001) != 0; }
    public static void RestoreDefault() { SetThreadExecutionState(0x80000000); }
}
'@
    }
    if (-not [CodexHyperVSetupPower]::PreventSystemSleep()) {
        throw 'Windows rejected the temporary system-sleep inhibition request.'
    }
    $script:installerAwake = $true
}

function Disable-InstallerAwake {
    if ($script:installerAwake -and ('CodexHyperVSetupPower' -as [type])) {
        [CodexHyperVSetupPower]::RestoreDefault()
        $script:installerAwake = $false
    }
}

function Write-JsonAtomic {
    param([string] $Path, $Value)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Write-SetupState {
    param([string] $Phase, [string] $Message, $Details = $null)
    Write-JsonAtomic -Path $statePath -Value ([ordered]@{
        FormatVersion = 1; AttemptId = $AttemptId; Phase = $Phase; Message = $Message
        StartedUtc = $startedUtc.ToString('o'); UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        InstallRoot = $InstallRoot; TargetUserProfile = $TargetUserProfile; TargetUserSid = $TargetUserSid
        Details = $Details
    })
    Write-Host "[$Phase] $Message"
}

function Write-SetupResult {
    param([bool] $Success, [string] $Message, $Details = $null)
    Write-JsonAtomic -Path $resultPath -Value ([ordered]@{
        Success = $Success; Message = $Message; AttemptId = $AttemptId
        StartedUtc = $startedUtc.ToString('o'); CompletedUtc = [DateTime]::UtcNow.ToString('o')
        InstallRoot = $InstallRoot; Details = $Details
    })
}

function Invoke-Robocopy {
    param([string] $Source, [string] $Destination, [switch] $Mirror, [string[]] $ExcludeFiles = @(), [string[]] $ExcludeDirectories = @())
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $arguments = @($Source, $Destination, $(if ($Mirror) { '/MIR' } else { '/E' }), '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($ExcludeFiles.Count -gt 0) { $arguments += '/XF'; $arguments += $ExcludeFiles }
    if ($ExcludeDirectories.Count -gt 0) { $arguments += '/XD'; $arguments += $ExcludeDirectories }
    & robocopy.exe @arguments | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Robocopy failed with exit code $LASTEXITCODE while copying '$Source' to '$Destination'." }
}

function Get-ElevationArguments {
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
        '-InstallRoot', ('"' + $InstallRoot + '"'), '-Language', ('"' + $Language + '"'),
        '-PoolSize', [string]$PoolSize, '-VmMemoryGiB', [string]$VmMemoryGiB,
        '-VmProcessorCount', [string]$VmProcessorCount, '-IdleTimeoutSeconds', [string]$IdleTimeoutSeconds,
        '-DisplayWidth', [string]$DisplayWidth, '-DisplayHeight', [string]$DisplayHeight,
        '-TargetUserProfile', ('"' + $TargetUserProfile + '"'), '-TargetUserSid', $TargetUserSid,
        '-AttemptId', $AttemptId, '-NoElevation'
    )
    foreach ($switchName in @('Resume','NoRestart','SkipSmokeTest','SkipLocalRecoveryBundle','AllowLowResources','ForceRebuild','SkipGlobalPolicy')) {
        if ((Get-Variable -Name $switchName -ValueOnly)) { $arguments += '-' + $switchName }
    }
    $arguments
}

function Register-ResumeTask {
    $resumeScript = Join-Path $installedSetup 'Install.ps1'
    $arguments = Get-ElevationArguments
    $arguments[5] = '"' + $resumeScript + '"'
    if ($arguments -notcontains '-Resume') { $arguments += '-Resume' }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($arguments -join ' ')
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $resumeTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Resumes the source-only Codex Hyper-V harness rebuild after Hyper-V enablement.' -Force | Out-Null
}

function Register-ResultRunOnce {
    $launcher = Join-Path $installedSetup 'SHOW-RESULT.cmd'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Post-restart result launcher is missing: $launcher" }
    $command = 'cmd.exe /d /c ""' + $launcher + '" "' + $InstallRoot + '""'
    $userHive = "Registry::HKEY_USERS\$TargetUserSid"
    $temporaryHive = $null
    if (-not (Test-Path -LiteralPath $userHive)) {
        $profileHive = Join-Path $TargetUserProfile 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $profileHive -PathType Leaf)) { throw "Target-user registry hive is missing: $profileHive" }
        $temporaryHive = 'CodexHyperVSetup_' + [Guid]::NewGuid().ToString('N')
        & reg.exe load "HKU\$temporaryHive" "$profileHive" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to load the target-user registry hive.' }
        $userHive = "Registry::HKEY_USERS\$temporaryHive"
    }
    try {
        $runOnce = Join-Path $userHive 'Software\Microsoft\Windows\CurrentVersion\RunOnce'
        New-Item -Path $runOnce -Force | Out-Null
        New-ItemProperty -Path $runOnce -Name 'CodexHyperVSetupResult' -PropertyType String -Value $command -Force | Out-Null
    }
    finally {
        if ($temporaryHive) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            & reg.exe unload "HKU\$temporaryHive" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Failed to unload the target-user registry hive.' }
        }
    }
}

function Install-LocationPointer {
    param($Layout)
    $pointerPath = [string]$Layout.BrokerLocationPointer
    $pointerRoot = Split-Path -Parent $pointerPath
    New-Item -ItemType Directory -Force -Path $pointerRoot | Out-Null
    Write-JsonAtomic -Path $pointerPath -Value ([ordered]@{
        FormatVersion = 1; InstallRoot = $InstallRoot; BrokerRoot = [string]$Layout.BrokerRoot
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    })
    $client = '*' + $TargetUserSid
    & icacls.exe $pointerRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' "$client`:(OI)(CI)(RX)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to secure the broker location pointer.' }
}

function Set-PrivateFileAcl {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Private file is missing: $Path" }
    $client = '*' + $TargetUserSid
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' "$client`:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to secure private file: $Path" }
}

function Install-RuntimeSkill {
    param($Layout)
    $skillDestination = Join-Path $TargetUserProfile '.agents\skills\hyperv-test-executables'
    Invoke-Robocopy -Source ([string]$Layout.SkillSourceRoot) -Destination $skillDestination -Mirror
    $skillDestination
}

function Install-ManagedPolicyBlock {
    if ($SkipGlobalPolicy) { return $null }
    $blockPath = Join-Path $installedSetup 'AGENTS.block.md'
    $agentsPath = Join-Path $TargetUserProfile '.codex\AGENTS.md'
    $block = (Get-Content -LiteralPath $blockPath -Raw).Trim()
    $startMarker = '<!-- BEGIN CODEX HYPERV TEST HARNESS -->'
    $endMarker = '<!-- END CODEX HYPERV TEST HARNESS -->'
    $existing = if (Test-Path -LiteralPath $agentsPath -PathType Leaf) { Get-Content -LiteralPath $agentsPath -Raw } else { '' }
    $pattern = [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
    if ([regex]::IsMatch($existing, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) {
        $updated = [regex]::Replace($existing, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $block }, [Text.RegularExpressions.RegexOptions]::Singleline)
    }
    else {
        $updated = $existing.TrimEnd() + $(if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { "`r`n`r`n" }) + $block + "`r`n"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $agentsPath) | Out-Null
    [IO.File]::WriteAllText($agentsPath, $updated, (New-Object Text.UTF8Encoding($false)))
    $agentsPath
}

function Resolve-WindowsLocale {
    param([string] $MicrosoftLanguage)
    $map = @{
        'Arabic'='ar-SA'; 'Brazilian Portuguese'='pt-BR'; 'Bulgarian'='bg-BG'; 'Chinese (Simplified)'='zh-CN'
        'Chinese (Traditional)'='zh-TW'; 'Croatian'='hr-HR'; 'Czech'='cs-CZ'; 'Danish'='da-DK'; 'Dutch'='nl-NL'
        'English'='en-US'; 'English International'='en-GB'; 'Estonian'='et-EE'; 'Finnish'='fi-FI'; 'French'='fr-FR'
        'French Canadian'='fr-CA'; 'German'='de-DE'; 'Greek'='el-GR'; 'Hebrew'='he-IL'; 'Hungarian'='hu-HU'
        'Italian'='it-IT'; 'Japanese'='ja-JP'; 'Korean'='ko-KR'; 'Latvian'='lv-LV'; 'Lithuanian'='lt-LT'
        'Norwegian'='nb-NO'; 'Polish'='pl-PL'; 'Portuguese'='pt-PT'; 'Romanian'='ro-RO'; 'Russian'='ru-RU'
        'Serbian Latin'='sr-Latn-RS'; 'Slovak'='sk-SK'; 'Slovenian'='sl-SI'; 'Spanish'='es-ES'
        'Spanish (Mexico)'='es-MX'; 'Swedish'='sv-SE'; 'Thai'='th-TH'; 'Turkish'='tr-TR'; 'Ukrainian'='uk-UA'
    }
    if (-not $map.ContainsKey($MicrosoftLanguage)) { throw "No unattended locale mapping exists for Microsoft language '$MicrosoftLanguage'." }
    [string]$map[$MicrosoftLanguage]
}

function New-ValidatedMediaAndSeed {
    param($Layout, [string] $ConfigurationPath)
    $isoStatus = Join-Path $setupStateRoot 'iso-status.json'
    $iso = & (Join-Path $installedSetup 'Get-OfficialWindows11Iso.ps1') -DestinationDirectory (Join-Path ([string]$Layout.RecoveryRoot) 'Media') -Language $Language -StatusPath $isoStatus
    if (-not [bool]$iso.Success) { throw 'Official Windows 11 media acquisition failed.' }
    $uiLanguage = Resolve-WindowsLocale -MicrosoftLanguage ([string]$iso.Language)
    $seedJson = & (Join-Path ([string]$Layout.HarnessSourceRoot) 'Build-Seed.ps1') -InstallIso ([string]$iso.IsoPath) -ConfigPath $ConfigurationPath -UiLanguage $uiLanguage -InputLocale $uiLanguage -TimeZone ([string](Get-TimeZone).Id) -RotateCredential
    $seed = $seedJson | ConvertFrom-Json
    Set-PrivateFileAcl -Path (Join-Path ([string]$Layout.HarnessSourceRoot) 'private\guest-credential.json')
    Set-PrivateFileAcl -Path ([string]$seed.IsoPath)
    [pscustomobject][ordered]@{ Iso = $iso; Seed = $seed; UiLanguage = $uiLanguage }
}

function Remove-ExistingHarnessVms {
    param($Layout)
    $names = @([string]$Layout.BaselineVmName) + @(1..([int]$Layout.PoolSize) | ForEach-Object { '{0}-{1:D2}' -f ([string]$Layout.PoolVmPrefix), $_ })
    foreach ($name in $names) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { continue }
        if ($vm.State -ne 'Off') { Stop-VM -Name $name -TurnOff -Force -ErrorAction Stop | Out-Null }
        Remove-VM -Name $name -Force -ErrorAction Stop
    }
    $baselineRoot = [IO.Path]::GetFullPath([string]$Layout.BaselineRoot)
    if ((Test-Path -LiteralPath $baselineRoot) -and ($baselineRoot + '\').StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($baselineRoot) -eq 'Baseline') {
        Remove-Item -LiteralPath $baselineRoot -Recurse -Force
    }
}

if ($PlanOnly) {
    $preflightPath = if ($runningFromCheckout) { Join-Path $PSScriptRoot 'Test-Prerequisites.ps1' } else { Join-Path $installedSetup 'Test-Prerequisites.ps1' }
    $preflightJson = & $preflightPath -InstallRoot $InstallRoot -PoolSize $PoolSize -VmMemoryGiB $VmMemoryGiB -AllowLowResources:$AllowLowResources -AsJson -ReportOnly
    $workerNoun = if ($PoolSize -eq 1) { 'worker' } else { 'workers' }
    [pscustomobject][ordered]@{
        PlanOnly = $true; InstallRoot = $InstallRoot; SourceSoftware = $sourceSoftware
        TargetUserProfile = $TargetUserProfile; TargetUserSid = $TargetUserSid
        WindowsIso = 'Downloaded automatically from the official Microsoft Windows 11 page'
        GuestEdition = 'Windows 11 Pro selected dynamically by EditionId Professional'
        Pool = "$PoolSize $workerNoun, $VmMemoryGiB GiB each, ${DisplayWidth}x${DisplayHeight}, $IdleTimeoutSeconds second idle timeout"
        Licensing = 'Not configured; activation and licensing remain the user responsibility'
        Preflight = $preflightJson | ConvertFrom-Json
    }
    return
}

if (-not (Test-Administrator)) {
    if ($NoElevation) { throw 'Administrator rights are required to install Hyper-V and the SYSTEM broker.' }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-ElevationArguments) -Verb RunAs -PassThru -Wait
    exit $process.ExitCode
}

try {
    Enable-InstallerAwake
    $mutex = New-Object Threading.Mutex($false, 'Global\CodexHyperVSourceInstall')
    try { $mutexTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) } catch [Threading.AbandonedMutexException] { $mutexTaken = $true }
    if (-not $mutexTaken) { throw 'Another source rebuild is already running.' }
    New-Item -ItemType Directory -Force -Path $setupStateRoot | Out-Null
    Start-Transcript -LiteralPath $logPath -Append | Out-Null
    $transcriptStarted = $true

    Write-SetupState -Phase 'Preflight' -Message 'Checking Windows, virtualization, storage, memory, and official-media prerequisites.'
    $preflightPath = if ($runningFromCheckout) { Join-Path $PSScriptRoot 'Test-Prerequisites.ps1' } else { Join-Path $installedSetup 'Test-Prerequisites.ps1' }
    $preflightJson = & $preflightPath -InstallRoot $InstallRoot -PoolSize $PoolSize -VmMemoryGiB $VmMemoryGiB -AllowLowResources:$AllowLowResources -AsJson -ReportOnly
    $preflight = $preflightJson | ConvertFrom-Json
    if (-not [bool]$preflight.Success) {
        $failedChecks = @($preflight.Checks | Where-Object { $_.Required -and -not $_.Passed } | ForEach-Object { $_.Name }) -join ', '
        throw "Required prerequisite checks failed: $failedChecks"
    }

    Write-SetupState -Phase 'StagingSource' -Message 'Installing the sanitized harness source and resumable setup scripts.'
    New-Item -ItemType Directory -Force -Path $installedSoftware, $installedSetup | Out-Null
    if ($runningFromCheckout) {
        Invoke-Robocopy -Source $sourceSoftware -Destination $installedSoftware -Mirror -ExcludeFiles @('*.exe','pool-definition.json','pool-provision-status.json','pool-broker-install-status.json','guest-credential.json') -ExcludeDirectories @('private','seed-build')
        Invoke-Robocopy -Source $PSScriptRoot -Destination $installedSetup -Mirror -ExcludeDirectories @('artifacts')
    }
    $layout = & (Join-Path $installedSetup 'New-HarnessConfiguration.ps1') -InstallRoot $InstallRoot -PoolSize $PoolSize -VmMemoryGiB $VmMemoryGiB -VmProcessorCount $VmProcessorCount -IdleTimeoutSeconds $IdleTimeoutSeconds -DisplayWidth $DisplayWidth -DisplayHeight $DisplayHeight -OutputPath $configPath
    . (Join-Path ([string]$layout.HarnessSourceRoot) 'HarnessPaths.ps1')
    $layout = Get-CodexHarnessConfig -ConfigPath $configPath
    Install-LocationPointer -Layout $layout

    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
    if ($feature.State -ne 'Enabled') {
        Write-SetupState -Phase 'PreparingMediaBeforeRestart' -Message 'Downloading official Windows media before the Hyper-V restart so recovery can resume as SYSTEM.'
        $preRestartMedia = New-ValidatedMediaAndSeed -Layout $layout -ConfigurationPath $configPath
        $Language = [string]$preRestartMedia.Iso.Language
        Write-SetupState -Phase 'EnablingHyperV' -Message 'Enabling Hyper-V; setup will resume automatically after Windows restarts.'
        $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart -ErrorAction Stop
        Register-ResumeTask
        Register-ResultRunOnce
        Write-SetupState -Phase 'RebootPending' -Message 'Hyper-V is enabled and a restart is required.' -Details @{ RestartNeeded = [bool]$enableResult.RestartNeeded }
        if ($NoRestart) { exit 3010 }
        Restart-Computer -Force
        exit 0
    }

    Import-Module Hyper-V -ErrorAction Stop
    Write-SetupState -Phase 'BuildingCanaries' -Message 'Compiling all test canaries from the published C# sources.'
    $canaries = @(& (Join-Path $installedSetup 'Build-Canaries.ps1') -CanaryRoot (Join-Path ([string]$layout.SoftwareRoot) 'Canaries'))
    $guestTool = & (Join-Path ([string]$layout.HarnessSourceRoot) 'Build-GuestTools.ps1')

    $baseline = Get-VM -Name ([string]$layout.BaselineVmName) -ErrorAction SilentlyContinue
    $baselineCheckpoint = if ($baseline) { Get-VMSnapshot -VMName $baseline.Name -Name ([string]$layout.BaselineCheckpointName) -ErrorAction SilentlyContinue } else { $null }
    if ($ForceRebuild) {
        Write-SetupState -Phase 'RemovingExistingPool' -Message 'Removing the explicitly selected existing harness VMs before a clean rebuild.'
        Remove-ExistingHarnessVms -Layout $layout
        $baseline = $null
        $baselineCheckpoint = $null
    }
    elseif ($baseline -and -not $baselineCheckpoint) {
        throw "Baseline VM '$($layout.BaselineVmName)' exists without checkpoint '$($layout.BaselineCheckpointName)'. Rerun with -ForceRebuild only if it is safe to replace."
    }

    $isoResult = $null
    if (-not $baselineCheckpoint) {
        Write-SetupState -Phase 'PreparingWindowsMedia' -Message 'Downloading and validating Windows 11 Pro media, then generating the guest seed ISO.'
        $media = New-ValidatedMediaAndSeed -Layout $layout -ConfigurationPath $configPath
        $isoResult = $media.Iso
        $uiLanguage = [string]$media.UiLanguage
        $seed = $media.Seed

        Write-SetupState -Phase 'CreatingBaselineVm' -Message 'Creating the isolated generation-2 Windows 11 Pro baseline VM.'
        New-Item -ItemType Directory -Force -Path ([string]$layout.BaselineRoot) | Out-Null
        New-VM -Name ([string]$layout.BaselineVmName) -Generation 2 -NoVHD -MemoryStartupBytes ([long]$layout.VmMemoryBytes) -Path ([string]$layout.BaselineRoot) | Out-Null
        & (Join-Path ([string]$layout.HarnessSourceRoot) 'Provision-Windows11Vm.ps1') -VmName ([string]$layout.BaselineVmName) -InstallIso ([string]$isoResult.IsoPath) -SeedIso ([string]$seed.IsoPath) -CredentialPath (Join-Path ([string]$layout.HarnessSourceRoot) 'private\guest-credential.json') -StatusPath (Join-Path $setupStateRoot 'provision-status.json') -ConfigPath $configPath
        $baseline = Get-VM -Name ([string]$layout.BaselineVmName) -ErrorAction Stop
        $baselineCheckpoint = Get-VMSnapshot -VMName $baseline.Name -Name ([string]$layout.BaselineCheckpointName) -ErrorAction Stop
    }
    else {
        Write-SetupState -Phase 'ReusingBaseline' -Message 'Reusing the existing clean Windows 11 Pro baseline checkpoint.' -Details @{ VmId = [string]$baseline.Id; CheckpointId = [string]$baselineCheckpoint.Id }
    }

    Write-SetupState -Phase 'BuildingPool' -Message "Creating or refreshing the $($layout.PoolSize)-slot disposable worker pool."
    $definitionPath = Join-Path ([string]$layout.HarnessSourceRoot) 'pool-definition.json'
    $initialize = @{
        SourceVmName = [string]$layout.BaselineVmName; BaselineName = [string]$layout.BaselineCheckpointName
        PoolSize = [int]$layout.PoolSize; PoolVmPrefix = [string]$layout.PoolVmPrefix
        BrokerRoot = [string]$layout.BrokerRoot; DefinitionPath = $definitionPath
        StatusPath = Join-Path ([string]$layout.BrokerRoot) 'State\Management\pool-provision-status.json'; ConfigPath = $configPath
    }
    if ($ForceRebuild) { $initialize.ForceRecreate = $true }
    & (Join-Path ([string]$layout.HarnessSourceRoot) 'Initialize-HyperVTestPool.ps1') @initialize

    Write-SetupState -Phase 'InstallingBroker' -Message 'Installing and starting the ACL-restricted SYSTEM broker.'
    & (Join-Path ([string]$layout.HarnessSourceRoot) 'Install-PoolHostBroker.ps1') -SourceRoot ([string]$layout.HarnessSourceRoot) -BrokerRoot ([string]$layout.BrokerRoot) -PoolDefinitionPath $definitionPath -StatusPath (Join-Path ([string]$layout.BrokerRoot) 'State\Management\pool-broker-install-status.json') -ConfigPath $configPath -ClientSid $TargetUserSid
    $skillPath = Install-RuntimeSkill -Layout $layout
    $policyPath = Install-ManagedPolicyBlock

    Write-SetupState -Phase 'Verifying' -Message 'Auditing pool isolation, lifecycle policy, and broker configuration.'
    $auditPath = Join-Path ([string]$layout.BrokerRoot) 'State\Management\pool-audit-status.json'
    & (Join-Path ([string]$layout.HarnessSourceRoot) 'Audit-HyperVTestPool.ps1') -DefinitionPath $definitionPath -BrokerRoot ([string]$layout.BrokerRoot) -StatusPath $auditPath -ExpectedIdleTimeoutSeconds ([int]$layout.PoolIdleTimeoutSeconds) -ConfigPath $configPath -ClientSid $TargetUserSid
    $audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
    if (-not [bool]$audit.Success) { throw 'The rebuilt Hyper-V pool failed its elevated audit.' }

    $smoke = $null
    if (-not $SkipSmokeTest) {
        Write-SetupState -Phase 'SmokeTesting' -Message 'Running the compiled visual canary inside an isolated pool VM.'
        $runner = Join-Path $skillPath 'scripts\Invoke-HyperVExecutableTest.ps1'
        $smokeJson = & $runner -ArtifactPath (Join-Path ([string]$layout.SoftwareRoot) 'Canaries\PoolCanary.exe') -ActionsPath (Join-Path ([string]$layout.SoftwareRoot) 'Canaries\smoke-actions.json') -BrokerRoot ([string]$layout.BrokerRoot) -QueueTimeoutSeconds 900 -ExecutionTimeoutSeconds 300
        $smoke = $smokeJson | ConvertFrom-Json
        if (-not [bool]$smoke.Success -or -not [bool]$smoke.PayloadChildDeleted) { throw "The isolated smoke test failed: $($smoke.Error)" }
        if (-not (Test-Path -LiteralPath (Join-Path ([string]$smoke.ResultPath) 'recovery-smoke.png') -PathType Leaf)) { throw 'The isolated smoke test did not return its requested screenshot.' }
    }

    $recovery = $null
    if (-not $SkipLocalRecoveryBundle) {
        Write-SetupState -Phase 'CreatingLocalRecovery' -Message 'Creating and verifying the faster local image-based recovery bundle.'
        & (Join-Path ([string]$layout.SoftwareRoot) 'Recovery\New-CodexHyperVRecovery.ps1') -ConfigPath $configPath -ActiveBrokerRoot ([string]$layout.BrokerRoot) -TargetUserProfile $TargetUserProfile -NoElevation | Out-Null
        $recovery = Join-Path ([string]$layout.RecoveryRoot) 'Current\manifest.json'
    }

    Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $details = [ordered]@{
        ConfigPath = $configPath; BaselineVmId = [string]$baseline.Id; BaselineCheckpointId = [string]$baselineCheckpoint.Id
        SkillPath = $skillPath; PolicyPath = $policyPath; AuditPath = $auditPath; Smoke = $smoke
        LocalRecoveryManifest = $recovery; Canaries = $canaries; GuestTool = $guestTool; Iso = $isoResult
        Licensing = 'Windows activation and licensing were intentionally not configured.'
    }
    Write-SetupState -Phase 'Ready' -Message 'The source-rebuilt Codex Hyper-V executable-test backend is ready.' -Details $details
    Write-SetupResult -Success $true -Message 'READY - the Codex Hyper-V executable-test backend was rebuilt successfully.' -Details $details
    [pscustomobject]([ordered]@{ Success = $true; ResultPath = $resultPath; Details = $details })
}
catch {
    try {
        if ($Resume) { Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false -ErrorAction SilentlyContinue }
        Write-SetupState -Phase 'Failed' -Message $_.Exception.Message -Details @{ ScriptStackTrace = $_.ScriptStackTrace }
        Write-SetupResult -Success $false -Message $_.Exception.Message -Details @{ ScriptStackTrace = $_.ScriptStackTrace }
    }
    catch { }
    throw
}
finally {
    Disable-InstallerAwake
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    if ($mutexTaken) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
