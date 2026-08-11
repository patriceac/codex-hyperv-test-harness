[CmdletBinding()]
param(
    [string] $BundleRoot = $PSScriptRoot,
    [string] $TargetUserProfile,
    [string] $TargetUserSid,
    [string] $AttemptId,
    [switch] $Resume,
    [switch] $NoRestart,
    [switch] $SkipSmokeTest,
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
$BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
. (Join-Path $BundleRoot 'RecoveryCommon.ps1')

if ([string]::IsNullOrWhiteSpace($TargetUserProfile)) { $TargetUserProfile = $env:USERPROFILE }
if ([string]::IsNullOrWhiteSpace($TargetUserSid)) { $TargetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
if ([string]::IsNullOrWhiteSpace($AttemptId)) { $AttemptId = [Guid]::NewGuid().ToString('N') }

if (-not (Test-CodexAdministrator)) {
    if ($NoElevation) { throw 'The one-click recovery installer requires administrator rights.' }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $PSCommandPath + '"'),
        '-BundleRoot', ('"' + $BundleRoot + '"'),
        '-TargetUserProfile', ('"' + $TargetUserProfile + '"'),
        '-TargetUserSid', $TargetUserSid,
        '-AttemptId', $AttemptId,
        '-NoElevation'
    )
    if ($Resume) { $arguments += '-Resume' }
    if ($NoRestart) { $arguments += '-NoRestart' }
    if ($SkipSmokeTest) { $arguments += '-SkipSmokeTest' }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    exit $process.ExitCode
}

try { [void][Security.Principal.SecurityIdentifier]::new($TargetUserSid) } catch { throw "Invalid target-user SID: $TargetUserSid" }
try { [void][Guid]::ParseExact($AttemptId, 'N') } catch { throw "Invalid recovery-attempt ID: $AttemptId" }
if (-not (Test-Path -LiteralPath $TargetUserProfile -PathType Container)) { throw "Target user profile is missing: $TargetUserProfile" }

$manifest = Get-CodexBundleManifest -BundleRoot $BundleRoot
$bundleConfigPath = Join-Path $BundleRoot ([string]$manifest.ConfigRelativePath).Replace('/', '\')
$bundleHarnessRoot = Split-Path -Parent $bundleConfigPath
. (Join-Path $bundleHarnessRoot 'Harness\HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $bundleConfigPath
$installRoot = [IO.Path]::GetFullPath([string]$layout.InstallRoot)
$liveRoot = [IO.Path]::GetFullPath([string]$layout.LiveRoot)
$brokerRoot = [IO.Path]::GetFullPath([string]$layout.BrokerRoot)
$baselineRoot = [IO.Path]::GetFullPath([string]$layout.BaselineRoot)
$softwareRoot = [IO.Path]::GetFullPath([string]$layout.SoftwareRoot)
$recoveryStateRoot = Assert-CodexPathWithin -Path (Join-Path $liveRoot 'RecoveryInstall') -Parent $installRoot -ExpectedLeaf 'RecoveryInstall'
$statePath = Join-Path $recoveryStateRoot 'state.json'
$statusPath = Join-Path $recoveryStateRoot 'install-status.json'
$logPath = Join-Path $recoveryStateRoot 'install.log'
$taskName = [string]$layout.BrokerTaskName
$resumeTaskName = [string]$layout.RecoveryResumeTaskName
$startedUtc = [DateTime]::UtcNow
$mutex = New-Object Threading.Mutex($false, 'Global\CodexHyperVRecoveryInstall')
$mutexTaken = $false
$transcriptStarted = $false

function Write-InstallState {
    param([string] $Phase, [string] $Message, $Details = $null)
    Write-CodexJsonAtomic -Path $statePath -Value ([ordered]@{
        FormatVersion = 1
        BundleId = [string]$manifest.BundleId
        AttemptId = $AttemptId
        Phase = $Phase
        Message = $Message
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        TargetUserProfile = $TargetUserProfile
        TargetUserSid = $TargetUserSid
        Details = $Details
    })
}

function Write-InstallResult {
    param([bool] $Success, [string] $Message, $Details = $null)
    Write-CodexJsonAtomic -Path $statusPath -Value ([ordered]@{
        Success = $Success
        Message = $Message
        BundleId = [string]$manifest.BundleId
        AttemptId = $AttemptId
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        InstallRoot = $installRoot
        BrokerRoot = $brokerRoot
        TargetUserProfile = $TargetUserProfile
        Details = $Details
    })
}

function Register-RecoveryResumeTask {
    $script = Join-Path $BundleRoot 'Install-CodexHyperVHarness.ps1'
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$script`" -BundleRoot `"$BundleRoot`" -TargetUserProfile `"$TargetUserProfile`" -TargetUserSid $TargetUserSid -AttemptId $AttemptId -Resume -NoElevation"
    if ($SkipSmokeTest) { $arguments += ' -SkipSmokeTest' }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4) -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $resumeTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Resumes the unattended Codex Hyper-V harness recovery after Windows enables Hyper-V.' -Force | Out-Null
}

function Register-RecoveryResultRunOnce {
    $resultLauncher = Join-Path $BundleRoot 'SHOW-RECOVERY-RESULT.cmd'
    if (-not (Test-Path -LiteralPath $resultLauncher -PathType Leaf)) {
        throw "The post-restart result launcher is missing: $resultLauncher"
    }
    $command = 'cmd.exe /d /c ""' + $resultLauncher + '" ' + $AttemptId + '"'
    if ($command.Length -gt 260) {
        throw "The post-restart RunOnce command exceeds Windows' 260-character limit."
    }
    $userHive = "Registry::HKEY_USERS\$TargetUserSid"
    $temporaryHiveName = $null

    if (-not (Test-Path -LiteralPath $userHive)) {
        $profileHive = Join-Path $TargetUserProfile 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $profileHive -PathType Leaf)) {
            throw "The target user's registry hive is missing: $profileHive"
        }
        $temporaryHiveName = 'CodexRecovery_' + [Guid]::NewGuid().ToString('N')
        & reg.exe load "HKU\$temporaryHiveName" "$profileHive" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to load the target user's registry hive." }
        $userHive = "Registry::HKEY_USERS\$temporaryHiveName"
    }

    try {
        $runOncePath = Join-Path $userHive 'Software\Microsoft\Windows\CurrentVersion\RunOnce'
        New-Item -Path $runOncePath -Force | Out-Null
        New-ItemProperty -Path $runOncePath -Name 'CodexHyperVRecoveryResult' -PropertyType String -Value $command -Force | Out-Null
    }
    finally {
        if ($temporaryHiveName) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            & reg.exe unload "HKU\$temporaryHiveName" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to unload the target user's registry hive." }
        }
    }
}

function Install-LocationPointer {
    $pointerPath = [string]$layout.BrokerLocationPointer
    $pointerRoot = Split-Path -Parent $pointerPath
    New-Item -ItemType Directory -Force -Path $pointerRoot | Out-Null
    Write-CodexJsonAtomic -Path $pointerPath -Value ([ordered]@{
        FormatVersion = 1
        InstallRoot = $installRoot
        BrokerRoot = $brokerRoot
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    })
    $clientPrincipal = '*' + $TargetUserSid
    & icacls.exe $pointerRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' "$clientPrincipal`:(OI)(CI)(RX)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to secure the broker location pointer.' }
}

function Install-CodexUserIntegration {
    $skillSource = Join-Path $softwareRoot 'Skill'
    $skillDestination = Join-Path $TargetUserProfile '.agents\skills\hyperv-test-executables'
    [void](Invoke-CodexRobocopy -Source $skillSource -Destination $skillDestination -Mirror)

    $agentsSource = Join-Path $BundleRoot 'Codex\AGENTS.md'
    $agentsDestination = Join-Path $TargetUserProfile '.codex\AGENTS.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $agentsDestination) | Out-Null
    $block = (Get-Content -LiteralPath $agentsSource -Raw).Trim()
    $existing = if (Test-Path -LiteralPath $agentsDestination -PathType Leaf) { Get-Content -LiteralPath $agentsDestination -Raw } else { '' }
    $startMarker = '<!-- BEGIN CODEX HYPERV TEST HARNESS -->'
    $endMarker = '<!-- END CODEX HYPERV TEST HARNESS -->'
    $pattern = [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
    if ([regex]::IsMatch($existing, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) {
        $updated = [regex]::Replace($existing, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $block }, [Text.RegularExpressions.RegexOptions]::Singleline)
    }
    else {
        $separator = if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { "`r`n`r`n" }
        $updated = $existing.TrimEnd() + $separator + $block + "`r`n"
    }
    [IO.File]::WriteAllText($agentsDestination, $updated, (New-Object Text.UTF8Encoding($false)))
}

function Ensure-BaselineVm {
    $vmName = [string]$layout.BaselineVmName
    $checkpointName = [string]$layout.BaselineCheckpointName
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        $liveConfigs = if (Test-Path -LiteralPath $baselineRoot -PathType Container) {
            @(Get-ChildItem -LiteralPath $baselineRoot -Recurse -File -Filter '*.vmcx' -ErrorAction SilentlyContinue)
        }
        else { @() }
        if ($liveConfigs.Count -eq 1) {
            try { $vm = Import-VM -Path $liveConfigs[0].FullName -Register -ErrorAction Stop } catch { $vm = $null }
        }
    }
    if (-not $vm) {
        if ((Test-Path -LiteralPath $baselineRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $baselineRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            [void](Assert-CodexPathWithin -Path $baselineRoot -Parent $installRoot -ExpectedLeaf 'Baseline')
            $archiveRoot = Join-Path $installRoot 'Archive'
            New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
            $archivePath = Join-Path $archiveRoot ('Baseline-unusable-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
            Move-Item -LiteralPath $baselineRoot -Destination $archivePath
        }
        New-Item -ItemType Directory -Force -Path $baselineRoot | Out-Null
        $exportConfig = Join-Path $BundleRoot ([string]$manifest.ExportedVmConfiguration).Replace('/', '\')
        if (-not (Test-Path -LiteralPath $exportConfig -PathType Leaf)) { throw "Exported baseline configuration is missing: $exportConfig" }
        $vmPath = Join-Path $baselineRoot 'Virtual Machines'
        $snapshotPath = Join-Path $baselineRoot 'Snapshots'
        $pagingPath = Join-Path $baselineRoot 'Smart Paging'
        $vhdPath = Join-Path $baselineRoot 'Virtual Hard Disks'
        New-Item -ItemType Directory -Force -Path $vmPath, $snapshotPath, $pagingPath, $vhdPath | Out-Null
        $vm = Import-VM -Path $exportConfig -Copy -GenerateNewId -VirtualMachinePath $vmPath -SnapshotFilePath $snapshotPath -SmartPagingFilePath $pagingPath -VhdDestinationPath $vhdPath -ErrorAction Stop
    }
    $vm = Get-VM -Name $vmName -ErrorAction Stop
    if ($vm.State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force -ErrorAction Stop | Out-Null }
    $configurationLocation = [IO.Path]::GetFullPath([string]$vm.ConfigurationLocation)
    if (-not ($configurationLocation + '\').StartsWith($baselineRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Move-VMStorage -Name $vmName -DestinationStoragePath $baselineRoot -ErrorAction Stop
        $vm = Get-VM -Name $vmName -ErrorAction Stop
    }
    Set-VMProcessor -VMName $vmName -Count ([int]$layout.VmProcessorCount) -ErrorAction Stop
    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -StartupBytes ([long]$layout.VmMemoryBytes) -ErrorAction Stop
    Set-VMVideo -VMName $vmName -HorizontalResolution ([int]$layout.GuestDisplayWidth) -VerticalResolution ([int]$layout.GuestDisplayHeight) -ResolutionType Single -ErrorAction Stop
    Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue | Disconnect-VMNetworkAdapter -ErrorAction SilentlyContinue
    [void](Get-VMSnapshot -VMName $vmName -Name $checkpointName -ErrorAction Stop)
    $vm
}

try {
    Start-CodexRecoveryAwake
    try { $mutexTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) } catch [Threading.AbandonedMutexException] { $mutexTaken = $true }
    if (-not $mutexTaken) { throw 'Another recovery installation is already running.' }
    New-Item -ItemType Directory -Force -Path $recoveryStateRoot | Out-Null
    if (-not $Resume) { Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue }
    Start-Transcript -LiteralPath $logPath -Append | Out-Null
    $transcriptStarted = $true

    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $BundleRoot 'manifest.json') -Algorithm SHA256).Hash
    $previousState = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try { $previousState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $previousState = $null }
    }
    $alreadyVerified = $Resume -and $previousState -and [string]$previousState.BundleId -eq [string]$manifest.BundleId -and [string]$previousState.Details.ManifestSha256 -eq $manifestHash
    Write-InstallState -Phase 'VerifyingBundle' -Message 'Verifying the recovery bundle before changing the host.' -Details ([ordered]@{ ManifestSha256 = $manifestHash })
    $verification = Test-CodexRecoveryBundleIntegrity -BundleRoot $BundleRoot -SkipContentHashes:$alreadyVerified
    if (-not $verification.Success) { throw ('Recovery bundle verification failed: ' + ($verification.Failures -join '; ')) }

    $edition = Get-WindowsEdition -Online -ErrorAction Stop
    if ([string]$edition.Edition -notin @('Professional','ProfessionalN','Enterprise','EnterpriseN','Education','EducationN')) {
        throw "A Windows Pro, Enterprise, or Education host is required; detected edition '$($edition.Edition)'."
    }
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetPathRoot($installRoot)) -PathType Container)) {
        throw "The target drive is unavailable: $([IO.Path]::GetPathRoot($installRoot))"
    }

    $hyperV = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
    if ($hyperV.State -ne 'Enabled') {
        Write-InstallState -Phase 'EnablingHyperV' -Message 'Enabling Hyper-V; installation will resume automatically after restart.' -Details ([ordered]@{ ManifestSha256 = $manifestHash })
        $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart -ErrorAction Stop
        Register-RecoveryResumeTask
        Register-RecoveryResultRunOnce
        Write-InstallState -Phase 'RebootPending' -Message 'Hyper-V was enabled and Windows must restart.' -Details ([ordered]@{ ManifestSha256 = $manifestHash; RestartNeeded = [bool]$enableResult.RestartNeeded })
        if ($NoRestart) { exit 3010 }
        Restart-Computer -Force
        exit 0
    }

    Import-Module Hyper-V -ErrorAction Stop
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask -and $existingTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 1
    }

    Write-InstallState -Phase 'InstallingSoftware' -Message 'Installing the portable harness and Codex integration.' -Details ([ordered]@{ ManifestSha256 = $manifestHash })
    New-Item -ItemType Directory -Force -Path $installRoot, $liveRoot, $brokerRoot | Out-Null
    [void](Invoke-CodexRobocopy -Source (Join-Path $BundleRoot 'Software') -Destination $softwareRoot -Mirror)
    $credentialPath = Join-Path $softwareRoot 'Harness\private\guest-credential.json'
    Set-CodexPrivateFileAcl -Path $credentialPath
    Install-CodexUserIntegration
    Install-LocationPointer

    Write-InstallState -Phase 'RestoringBaseline' -Message 'Registering or importing the clean baseline VM.' -Details ([ordered]@{ ManifestSha256 = $manifestHash })
    $baseline = Ensure-BaselineVm

    $harnessSource = Join-Path $softwareRoot 'Harness'
    $definitionPath = Join-Path $harnessSource 'pool-definition.json'
    $forcePool = $false
    if (Test-Path -LiteralPath $definitionPath -PathType Leaf) {
        try {
            $definition = Get-Content -LiteralPath $definitionPath -Raw | ConvertFrom-Json
            $expectedPoolRoot = [IO.Path]::GetFullPath((Join-Path $brokerRoot 'Pool'))
            $forcePool = -not [string]::Equals([IO.Path]::GetFullPath([string]$definition.PoolRoot), $expectedPoolRoot, [StringComparison]::OrdinalIgnoreCase)
        }
        catch { $forcePool = $true }
    }

    Write-InstallState -Phase 'BuildingPool' -Message 'Creating or repairing the disposable four-VM pool.' -Details ([ordered]@{ ManifestSha256 = $manifestHash; ForceRecreate = $forcePool })
    $initializeArguments = @{
        SourceVmName = [string]$layout.BaselineVmName
        BaselineName = [string]$layout.BaselineCheckpointName
        PoolSize = [int]$layout.PoolSize
        PoolVmPrefix = [string]$layout.PoolVmPrefix
        BrokerRoot = $brokerRoot
        DefinitionPath = $definitionPath
        StatusPath = Join-Path $brokerRoot 'State\Management\pool-provision-status.json'
        ConfigPath = Join-Path $softwareRoot 'harness-config.json'
    }
    if ($forcePool) { $initializeArguments.ForceRecreate = $true }
    & (Join-Path $harnessSource 'Initialize-HyperVTestPool.ps1') @initializeArguments

    Write-InstallState -Phase 'InstallingBroker' -Message 'Installing and starting the SYSTEM broker.' -Details ([ordered]@{ ManifestSha256 = $manifestHash })
    & (Join-Path $harnessSource 'Install-PoolHostBroker.ps1') `
        -SourceRoot $harnessSource `
        -BrokerRoot $brokerRoot `
        -PoolDefinitionPath $definitionPath `
        -StatusPath (Join-Path $brokerRoot 'State\Management\pool-broker-install-status.json') `
        -ConfigPath (Join-Path $softwareRoot 'harness-config.json') `
        -ClientSid $TargetUserSid

    $auditPath = Join-Path $brokerRoot 'State\Management\pool-audit-status.json'
    & (Join-Path $harnessSource 'Audit-HyperVTestPool.ps1') `
        -DefinitionPath $definitionPath `
        -BrokerRoot $brokerRoot `
        -StatusPath $auditPath `
        -ExpectedIdleTimeoutSeconds ([int]$layout.PoolIdleTimeoutSeconds) `
        -ConfigPath (Join-Path $softwareRoot 'harness-config.json') `
        -ClientSid $TargetUserSid
    $audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
    if (-not [bool]$audit.Success) { throw 'The restored Hyper-V pool failed its elevated audit.' }

    $smoke = $null
    if (-not $SkipSmokeTest) {
        Write-InstallState -Phase 'SmokeTesting' -Message 'Running the isolated visual executable smoke test.' -Details ([ordered]@{ ManifestSha256 = $manifestHash })
        $runner = Join-Path $TargetUserProfile '.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1'
        $canary = Join-Path $softwareRoot 'Canaries\PoolCanary.exe'
        $actions = Join-Path $softwareRoot 'Canaries\smoke-actions.json'
        $smokeJson = & $runner -ArtifactPath $canary -ActionsPath $actions -BrokerRoot $brokerRoot -QueueTimeoutSeconds 900 -ExecutionTimeoutSeconds 300
        $smoke = $smokeJson | ConvertFrom-Json
        if (-not [bool]$smoke.Success -or -not [bool]$smoke.PayloadChildDeleted -or [string]$smoke.VmFinalState -ne 'Off') {
            throw "The restored harness smoke test failed: $($smoke.Error)"
        }
    }

    Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-InstallState -Phase 'Ready' -Message 'The Codex Hyper-V harness is ready.' -Details ([ordered]@{ ManifestSha256 = $manifestHash; AuditPath = $auditPath; SmokeResultPath = if ($smoke) { [string]$smoke.ResultPath } else { $null } })
    Write-InstallResult -Success $true -Message 'READY - the one-click Codex Hyper-V harness installation completed successfully.' -Details ([ordered]@{
        BaselineVmId = [string]$baseline.Id
        AuditPath = $auditPath
        Smoke = $smoke
    })
}
catch {
    try {
        Write-InstallState -Phase 'Failed' -Message $_.Exception.Message -Details ([ordered]@{ ScriptStackTrace = $_.ScriptStackTrace })
        Write-InstallResult -Success $false -Message $_.Exception.Message -Details ([ordered]@{ ScriptStackTrace = $_.ScriptStackTrace })
    }
    catch { }
    throw
}
finally {
    Stop-CodexRecoveryAwake
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    if ($mutexTaken) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
