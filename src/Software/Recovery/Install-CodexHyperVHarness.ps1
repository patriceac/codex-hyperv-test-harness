[CmdletBinding()]
param(
    [string] $BundleRoot,
    [string] $TargetUserProfile,
    [string] $TargetUserSid,
    [string] $AttemptId,
    [switch] $Resume,
    [switch] $NoRestart,
    [switch] $SkipSmokeTest,
    [switch] $ProfileArtifactsPrepared,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')] [string] $PreparedSkillFingerprint,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')] [string] $PreparedPolicyFingerprint,
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BundleRoot)) { $BundleRoot = $PSScriptRoot }

function Assert-RecoveryNoAlternateDataStream {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "Recovery path has no filesystem root: $Path" }
    if ($full.Substring($root.Length) -match ':') { throw "Recovery paths cannot contain alternate data streams: $Path" }
    if (-not (Test-Path -LiteralPath $full)) { return }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    # PowerShell's FileSystem stream provider is not reliable for directory
    # handles (notably profile junction roots). File ADS are still checked
    # individually by the source-tree walk and file fingerprint helpers.
    if ($item.PSIsContainer) { return }
    try {
        $streams = @(Get-Item -LiteralPath $full -Stream * -ErrorAction Stop)
        foreach ($stream in $streams) {
            if ([string]$stream.Stream -notin @('', '::$DATA', ':$DATA', '$DATA')) {
                throw "Recovery paths cannot contain alternate data streams: ${full}:$($stream.Stream)"
            }
        }
    }
    catch [System.Management.Automation.ParameterBindingException] { }
    catch [System.NotSupportedException] { }
}

function Assert-RecoveryNoReparseChain {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [switch] $RequireExisting
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A recovery path cannot be empty.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "Recovery path has no filesystem root: $Path" }
    if ($full.Substring($root.Length) -match ':') { throw "Recovery paths cannot contain alternate data streams: $Path" }
    $existing = New-Object Collections.Generic.List[object]
    $probe = New-Object IO.DirectoryInfo($full)
    while ($null -ne $probe) {
        if (Test-Path -LiteralPath $probe.FullName) {
            [void]$existing.Add((Get-Item -LiteralPath $probe.FullName -Force -ErrorAction Stop))
        }
        $probe = $probe.Parent
    }
    if ($RequireExisting -and -not (Test-Path -LiteralPath $full)) { throw "Recovery path is missing: $full" }
    foreach ($item in $existing) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Recovery path crosses a reparse point: $($item.FullName)"
        }
        Assert-RecoveryNoAlternateDataStream -Path $item.FullName
    }
    $full
}

function Resolve-RecoveryManifestPath {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $RelativePath,
        [Parameter(Mandatory = $true)] [string] $FieldName,
        [switch] $RequireLeaf
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw "Recovery manifest field '$FieldName' must be a non-empty relative path." }
    $relative = $RelativePath.Replace('/', '\')
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '^(?:[\/]{1,2}|[A-Za-z]:|\\[?.])') {
        throw "Recovery manifest field '$FieldName' must not be rooted: $RelativePath"
    }
    if ($relative -match '(^|\\)(?:\.\.?)(?:\\|$)' -or $relative -match ':') {
        throw "Recovery manifest field '$FieldName' contains traversal or an alternate data stream: $RelativePath"
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $relative)).TrimEnd('\')
    if ([string]::Equals($candidate, $rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not (($candidate + '\').StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw "Recovery manifest field '$FieldName' escapes BundleRoot: $RelativePath"
    }

    $current = $rootFull
    $parts = @($candidate.Substring($rootFull.Length).TrimStart('\') -split '\\')
    for ($index = 0; $index -lt $parts.Count; $index++) {
        $current = Join-Path $current $parts[$index]
        if (-not (Test-Path -LiteralPath $current)) {
            if ($RequireLeaf) { throw "Recovery manifest field '$FieldName' points to a missing path: $RelativePath" }
            continue
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Recovery manifest field '$FieldName' crosses a reparse point: $RelativePath"
        }
        Assert-RecoveryNoAlternateDataStream -Path $current
        if ($index -lt ($parts.Count - 1) -and -not $item.PSIsContainer) {
            throw "Recovery manifest field '$FieldName' crosses a file boundary: $RelativePath"
        }
    }
    if ($RequireLeaf -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Recovery manifest field '$FieldName' is not a file: $RelativePath"
    }
    $candidate
}

function Assert-RecoveryBundleRoot {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $full = Assert-RecoveryNoReparseChain -Path $Path -RequireExisting
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw "Recovery BundleRoot is not a directory: $full" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Recovery BundleRoot cannot be a reparse point: $full" }
    $full
}

function Read-RecoveryManifestSafely {
    param([Parameter(Mandatory = $true)] [string] $Root)

    $manifestPath = Resolve-RecoveryManifestPath -Root $Root -RelativePath 'manifest.json' -FieldName 'manifest.json' -RequireLeaf
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([int]$manifest.FormatVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$manifest.BundleId)) {
        throw 'The recovery manifest format is unsupported or incomplete.'
    }
    foreach ($entry in @($manifest.Files)) {
        [void](Resolve-RecoveryManifestPath -Root $Root -RelativePath ([string]$entry.RelativePath) -FieldName 'Files[].RelativePath' -RequireLeaf)
    }
    [void](Resolve-RecoveryManifestPath -Root $Root -RelativePath ([string]$manifest.ConfigRelativePath) -FieldName 'ConfigRelativePath' -RequireLeaf)
    [void](Resolve-RecoveryManifestPath -Root $Root -RelativePath ([string]$manifest.ExportedVmConfiguration) -FieldName 'ExportedVmConfiguration' -RequireLeaf)
    $manifest
}

function Assert-RecoveryBootstrapManifestEntry {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] $Manifest
    )

    $constantRelativePath = 'RecoveryCommon.ps1'
    $commonPath = Resolve-RecoveryManifestPath -Root $Root -RelativePath $constantRelativePath -FieldName $constantRelativePath -RequireLeaf
    $entries = @($Manifest.Files | Where-Object {
            $entryPath = ([string]$_.RelativePath).Replace('/', '\').TrimStart('\')
            [string]::Equals($entryPath, $constantRelativePath, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($entries.Count -eq 0) { throw "Recovery manifest is missing its exact '$constantRelativePath' file entry." }
    if ($entries.Count -ne 1) { throw "Recovery manifest contains duplicate '$constantRelativePath' file entries." }
    $entry = $entries[0]
    if (-not ($entry.PSObject.Properties.Name -contains 'Length') -or -not ($entry.PSObject.Properties.Name -contains 'Sha256')) {
        throw "Recovery manifest entry '$constantRelativePath' is missing its size or SHA-256 digest."
    }
    try { $expectedLength = [long]$entry.Length } catch { throw "Recovery manifest entry '$constantRelativePath' has an invalid size." }
    if ($expectedLength -lt 0) { throw "Recovery manifest entry '$constantRelativePath' has an invalid size." }
    $expectedHash = [string]$entry.Sha256
    if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw "Recovery manifest entry '$constantRelativePath' has an invalid SHA-256 digest." }
    $item = Get-Item -LiteralPath $commonPath -Force -ErrorAction Stop
    if ([long]$item.Length -ne $expectedLength) {
        throw "Recovery manifest size mismatch for '$constantRelativePath'."
    }
    $actualHash = (Get-FileHash -LiteralPath $commonPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actualHash, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovery manifest SHA-256 mismatch for '$constantRelativePath'."
    }
    $commonPath
}

$BundleRoot = Assert-RecoveryBundleRoot -Path $BundleRoot
$validatedManifest = Read-RecoveryManifestSafely -Root $BundleRoot
$recoveryCommonPath = Assert-RecoveryBootstrapManifestEntry -Root $BundleRoot -Manifest $validatedManifest
. $recoveryCommonPath

if ([string]::IsNullOrWhiteSpace($TargetUserProfile)) { $TargetUserProfile = $env:USERPROFILE }
$TargetUserProfile = [IO.Path]::GetFullPath($TargetUserProfile).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($TargetUserProfile) -or [IO.Path]::GetPathRoot($TargetUserProfile) -eq $TargetUserProfile) {
    throw 'TargetUserProfile must be a specific non-root directory.'
}
if ([string]::IsNullOrWhiteSpace($TargetUserSid)) { $TargetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
if ([string]::IsNullOrWhiteSpace($AttemptId)) { $AttemptId = [Guid]::NewGuid().ToString('N') }

function Register-RecoveryResultRunOnceForCurrentUser {
    $resultLauncher = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'SHOW-RECOVERY-RESULT.cmd' -FieldName 'SHOW-RECOVERY-RESULT.cmd' -RequireLeaf
    if (-not (Test-Path -LiteralPath $resultLauncher -PathType Leaf)) {
        throw "The post-restart result launcher is missing: $resultLauncher"
    }
    $command = 'cmd.exe /d /c ""' + $resultLauncher + '" ' + $AttemptId + '"'
    if ($command.Length -gt 260) {
        throw "The post-restart RunOnce command exceeds Windows' 260-character limit."
    }
    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $script:resultRunOnceRegistered = $true
    New-Item -Path $runOncePath -Force | Out-Null
    New-ItemProperty -Path $runOncePath -Name 'CodexHyperVRecoveryResult' -PropertyType String -Value $command -Force | Out-Null
}

function Unregister-RecoveryResultRunOnceForCurrentUser {
    if (-not $script:resultRunOnceRegistered) { return }
    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (Test-Path -LiteralPath $runOncePath) {
        Remove-ItemProperty -LiteralPath $runOncePath -Name 'CodexHyperVRecoveryResult' -ErrorAction SilentlyContinue
    }
    $script:resultRunOnceRegistered = $false
}

if (-not (Test-CodexAdministrator)) {
    if ($NoElevation) { throw 'The one-click recovery installer requires administrator rights.' }

    $userIntegrationScript = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'Software\UserIntegration\Install-CodexUserIntegration.ps1' -FieldName 'user-integration script' -RequireLeaf
    $policySource = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'Codex\AGENTS.md' -FieldName 'Codex policy' -RequireLeaf
    if (-not (Test-Path -LiteralPath $userIntegrationScript -PathType Leaf)) {
        throw "The user-integration helper is missing: $userIntegrationScript"
    }
    if (-not (Test-Path -LiteralPath $policySource -PathType Leaf)) {
        throw "The user-integration policy source is missing: $policySource"
    }
    $skillSourceRoot = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'Software\Skill' -FieldName 'skill source'
    $profileArtifacts = & $userIntegrationScript -SkillSourceRoot $skillSourceRoot -PolicyBlockPath $policySource -TargetUserProfile $TargetUserProfile -TargetUserSid $TargetUserSid
    if (-not [bool]$profileArtifacts.Success) { throw 'User-profile integration did not complete.' }
    $ProfileArtifactsPrepared = $true
    $PreparedSkillFingerprint = [string]$profileArtifacts.SkillFingerprint
    $PreparedPolicyFingerprint = [string]$profileArtifacts.PolicyFingerprint
    Register-RecoveryResultRunOnceForCurrentUser

    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $PSCommandPath + '"'),
        '-BundleRoot', ('"' + $BundleRoot + '"'),
        '-TargetUserProfile', ('"' + $TargetUserProfile + '"'),
        '-TargetUserSid', $TargetUserSid,
        '-AttemptId', $AttemptId,
        '-ProfileArtifactsPrepared',
        '-PreparedSkillFingerprint', $PreparedSkillFingerprint,
        '-PreparedPolicyFingerprint', $PreparedPolicyFingerprint,
        '-NoElevation'
    )
    if ($Resume) { $arguments += '-Resume' }
    if ($NoRestart) { $arguments += '-NoRestart' }
    if ($SkipSmokeTest) { $arguments += '-SkipSmokeTest' }
    $elevatedExitCode = $null
    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        $elevatedExitCode = $process.ExitCode
    }
    finally {
        # If this process survives until the elevated controller returns, no
        # automatic restart consumed RunOnce. Keep it only for a deferred
        # restart explicitly reported with Windows exit code 3010.
        if ($null -eq $elevatedExitCode -or [int]$elevatedExitCode -ne 3010) {
            Unregister-RecoveryResultRunOnceForCurrentUser
        }
    }
    exit $elevatedExitCode
}

try { [void][Security.Principal.SecurityIdentifier]::new($TargetUserSid) } catch { throw "Invalid target-user SID: $TargetUserSid" }
try { [void][Guid]::ParseExact($AttemptId, 'N') } catch { throw "Invalid recovery-attempt ID: $AttemptId" }
if (-not (Test-Path -LiteralPath $TargetUserProfile -PathType Container)) { throw "Target user profile is missing: $TargetUserProfile" }
if (-not $ProfileArtifactsPrepared -or [string]::IsNullOrWhiteSpace($PreparedSkillFingerprint) -or [string]::IsNullOrWhiteSpace($PreparedPolicyFingerprint)) {
    throw 'Launch recovery from the target user''s unelevated process so profile artifacts are prepared before elevation.'
}

$manifest = Get-CodexBundleManifest -BundleRoot $BundleRoot
foreach ($entry in @($manifest.Files)) {
    [void](Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath ([string]$entry.RelativePath) -FieldName 'Files[].RelativePath' -RequireLeaf)
}
$bundleConfigPath = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath ([string]$manifest.ConfigRelativePath) -FieldName 'ConfigRelativePath' -RequireLeaf
$exportedVmConfigurationPath = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath ([string]$manifest.ExportedVmConfiguration) -FieldName 'ExportedVmConfiguration' -RequireLeaf
$bundleHarnessRoot = Split-Path -Parent $bundleConfigPath
$bundleHarnessRelativeDirectory = Split-Path -Parent ([string]$manifest.ConfigRelativePath)
$bundleHarnessPathsPath = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath (Join-Path $bundleHarnessRelativeDirectory 'Harness\HarnessPaths.ps1') -FieldName 'HarnessPaths.ps1' -RequireLeaf
. $bundleHarnessPathsPath
$layout = Get-CodexHarnessConfig -ConfigPath $bundleConfigPath
$installRoot = [IO.Path]::GetFullPath([string]$layout.InstallRoot)
$liveRoot = [IO.Path]::GetFullPath([string]$layout.LiveRoot)
$brokerRoot = [IO.Path]::GetFullPath([string]$layout.BrokerRoot)
$baselineRoot = [IO.Path]::GetFullPath([string]$layout.BaselineRoot)
$softwareRoot = [IO.Path]::GetFullPath([string]$layout.SoftwareRoot)
$null = Assert-RecoveryNoReparseChain -Path $installRoot
if (Test-Path -LiteralPath $installRoot) { Assert-RecoveryNoAlternateDataStream -Path $installRoot }
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
$resumeTaskRegistered = $false
$resumeHandoffCommitted = $false
$resultRunOnceRegistered = $false
$profileReceipt = if ($ProfileArtifactsPrepared) {
    [ordered]@{
        FormatVersion = 1
        TargetUserProfile = $TargetUserProfile
        TargetUserSid = $TargetUserSid
        SkillFingerprint = $PreparedSkillFingerprint
        PolicyFingerprint = $PreparedPolicyFingerprint
        PreparedByTargetUser = $true
    }
}
else { $null }

function Write-InstallState {
    param([string] $Phase, [string] $Message, $Details = $null)
    $stateDetails = [ordered]@{}
    if ($null -ne $Details) {
        if ($Details -is [Collections.IDictionary]) {
            foreach ($key in $Details.Keys) { $stateDetails[[string]$key] = $Details[$key] }
        }
        else {
            foreach ($property in $Details.PSObject.Properties) { $stateDetails[$property.Name] = $property.Value }
        }
    }
    $stateDetails.ProfileReceipt = $profileReceipt
    Write-CodexJsonAtomic -Path $statePath -Value ([ordered]@{
        FormatVersion = 1
        BundleId = [string]$manifest.BundleId
        AttemptId = $AttemptId
        Phase = $Phase
        Message = $Message
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        TargetUserProfile = $TargetUserProfile
        TargetUserSid = $TargetUserSid
        Details = $stateDetails
    })
}

function Write-InstallResult {
    param([bool] $Success, [string] $Message, $Details = $null)
    $resultDetails = [ordered]@{}
    if ($null -ne $Details) {
        if ($Details -is [Collections.IDictionary]) {
            foreach ($key in $Details.Keys) { $resultDetails[[string]$key] = $Details[$key] }
        }
        else {
            foreach ($property in $Details.PSObject.Properties) { $resultDetails[$property.Name] = $property.Value }
        }
    }
    $resultDetails.ProfileReceipt = $profileReceipt
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
        Details = $resultDetails
    })
}

function Register-RecoveryResumeTask {
    $script = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'Install-CodexHyperVHarness.ps1' -FieldName 'recovery installer' -RequireLeaf
    if (-not $ProfileArtifactsPrepared -or [string]::IsNullOrWhiteSpace($PreparedSkillFingerprint) -or [string]::IsNullOrWhiteSpace($PreparedPolicyFingerprint)) {
        throw 'Cannot register the recovery resume task without the unelevated profile-artifact receipt.'
    }
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$script`" -BundleRoot `"$BundleRoot`" -TargetUserProfile `"$TargetUserProfile`" -TargetUserSid $TargetUserSid -AttemptId $AttemptId -Resume -ProfileArtifactsPrepared -PreparedSkillFingerprint $PreparedSkillFingerprint -PreparedPolicyFingerprint $PreparedPolicyFingerprint -NoElevation"
    if ($SkipSmokeTest) { $arguments += ' -SkipSmokeTest' }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4) -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $script:resumeTaskRegistered = $true
    Register-ScheduledTask -TaskName $resumeTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Resumes the unattended Codex Hyper-V harness recovery after Windows enables Hyper-V.' -Force | Out-Null
}

function Unregister-RecoveryResumeTaskIfOwned {
    if (-not $script:resumeTaskRegistered -and -not $Resume) { return }
    Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $script:resumeTaskRegistered = $false
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

function Assert-RecoveryTreeNoReparse {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $root.PSIsContainer) { throw "Recovery source tree is not a directory: $Path" }
    Assert-RecoveryNoAlternateDataStream -Path $root.FullName
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Recovery source tree is a reparse point: $Path" }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    [void]$pending.Push($root.FullName)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Recovery source tree contains a reparse point: $($child.FullName)"
            }
            Assert-RecoveryNoAlternateDataStream -Path $child.FullName
            if ($child.PSIsContainer) { [void]$pending.Push($child.FullName) }
        }
    }
}

function Get-RecoveryFileFingerprint {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $full = Assert-RecoveryNoReparseChain -Path $Path -RequireExisting
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "Recovery file fingerprint requires a file: $full" }
    Assert-RecoveryNoAlternateDataStream -Path $full
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    "$([long]$item.Length)|$hash"
}

function Get-RecoveryTreeFingerprint {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $full = Assert-RecoveryNoReparseChain -Path $Path -RequireExisting
    Assert-RecoveryTreeNoReparse -Path $full
    $root = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $root.PSIsContainer) { throw "Recovery tree fingerprint requires a directory: $full" }
    $records = New-Object Collections.Generic.List[string]
    [void]$records.Add('D|.')
    foreach ($item in @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($full.Length).TrimStart('\').Replace('\', '/')
        if ($item.PSIsContainer) {
            [void]$records.Add("D|$relative")
        }
        else {
            $fileFingerprint = Get-RecoveryFileFingerprint -Path $item.FullName
            [void]$records.Add("F|$relative|$fileFingerprint")
        }
    }
    $payload = [Text.Encoding]::UTF8.GetBytes(($records -join "`n"))
    $digest = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($digest.ComputeHash($payload))).Replace('-', '') }
    finally { $digest.Dispose() }
}

function Copy-RecoverySourceTree {
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination
    )

    Assert-RecoveryTreeNoReparse -Path $Source
    if (Test-Path -LiteralPath $Destination) { throw "Recovery staging destination already exists: $Destination" }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($child in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $child.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
    }
}

function Remove-RecoverySourceTree {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Parent
    )

    $resolved = Assert-CodexPathWithin -Path $Path -Parent $Parent
    if (-not (Test-Path -LiteralPath $resolved)) { return }
    Assert-RecoveryTreeNoReparse -Path $resolved
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $resolved) { throw "Recovery source transaction cleanup did not remove: $resolved" }
}

function Protect-RecoverySourceTree {
    param([Parameter(Mandatory = $true)] [string] $Path)

    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to protect the staged recovery source: $Path" }
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
        $exportConfig = $exportedVmConfigurationPath
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

    $manifestHash = (Get-FileHash -LiteralPath (Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'manifest.json' -FieldName 'manifest.json' -RequireLeaf) -Algorithm SHA256).Hash
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
        Write-InstallState -Phase 'RebootPending' -Message 'Hyper-V was enabled and Windows must restart.' -Details ([ordered]@{ ManifestSha256 = $manifestHash; RestartNeeded = [bool]$enableResult.RestartNeeded })
        if ($NoRestart) {
            $script:resumeHandoffCommitted = $true
            exit 3010
        }
        try {
            Restart-Computer -Force -ErrorAction Stop
            $script:resumeHandoffCommitted = $true
        }
        catch {
            $script:resumeHandoffCommitted = $false
            throw
        }
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
    $softwareParent = Split-Path -Parent $softwareRoot
    $softwareStage = Join-Path $softwareParent ('.CodexHarnessSoftwareStage-' + [Guid]::NewGuid().ToString('N'))
    $softwareBackup = Join-Path $softwareParent ('.CodexHarnessSoftwareBackup-' + [Guid]::NewGuid().ToString('N'))
    [void](Assert-CodexPathWithin -Path $softwareStage -Parent $softwareParent)
    [void](Assert-CodexPathWithin -Path $softwareBackup -Parent $softwareParent)
    $softwarePreviousMoved = $false
    $softwareStagePromoted = $false
    $softwareSourceCommitted = $false
    try {
        $bundleSoftwareRoot = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'Software' -FieldName 'Software source root'
        $softwareSourceFingerprintBefore = Get-RecoveryTreeFingerprint -Path $bundleSoftwareRoot
        $bundlePolicyPath = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'Codex\AGENTS.md' -FieldName 'Codex policy' -RequireLeaf
        $policySourceFingerprintBefore = Get-RecoveryFileFingerprint -Path $bundlePolicyPath
        Copy-RecoverySourceTree -Source $bundleSoftwareRoot -Destination $softwareStage
        $softwareSourceFingerprintAfter = Get-RecoveryTreeFingerprint -Path $bundleSoftwareRoot
        if (-not [string]::Equals($softwareSourceFingerprintBefore, $softwareSourceFingerprintAfter, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The recovery Software source changed while it was being staged.'
        }
        $softwareStageFingerprint = Get-RecoveryTreeFingerprint -Path $softwareStage
        if (-not [string]::Equals($softwareSourceFingerprintAfter, $softwareStageFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The staged recovery Software tree does not exactly match its source.'
        }
        $protectedPolicyPath = Join-Path $softwareStage 'Recovery\Protected-Codex-AGENTS.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $protectedPolicyPath) | Out-Null
        Copy-Item -LiteralPath $bundlePolicyPath -Destination $protectedPolicyPath -Force -ErrorAction Stop
        $policySourceFingerprintAfter = Get-RecoveryFileFingerprint -Path $bundlePolicyPath
        if (-not [string]::Equals($policySourceFingerprintBefore, $policySourceFingerprintAfter, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The recovery Codex policy source changed while it was being staged.'
        }
        $policyStageFingerprint = Get-RecoveryFileFingerprint -Path $protectedPolicyPath
        if (-not [string]::Equals($policySourceFingerprintAfter, $policyStageFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The staged recovery Codex policy does not exactly match its source.'
        }
        $softwareSourceFingerprintFinal = Get-RecoveryTreeFingerprint -Path $bundleSoftwareRoot
        if (-not [string]::Equals($softwareSourceFingerprintAfter, $softwareSourceFingerprintFinal, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The recovery Software source changed before staged-source protection.'
        }
        Protect-RecoverySourceTree -Path $softwareStage
        if (Test-Path -LiteralPath $softwareRoot) {
            Assert-RecoveryTreeNoReparse -Path $softwareRoot
            [IO.Directory]::Move($softwareRoot, $softwareBackup)
            $softwarePreviousMoved = $true
        }
        [IO.Directory]::Move($softwareStage, $softwareRoot)
        $softwareStagePromoted = $true
        $protectedPolicyPath = Join-Path $softwareRoot 'Recovery\Protected-Codex-AGENTS.md'
        $credentialPath = Join-Path $softwareRoot 'Harness\private\guest-credential.json'
        Set-CodexPrivateFileAcl -Path $credentialPath
        $installedUserIntegrationScript = Join-Path $softwareRoot 'UserIntegration\Install-CodexUserIntegration.ps1'
        $preparedSource = & $installedUserIntegrationScript -SkillSourceRoot (Join-Path $softwareRoot 'Skill') -PolicyBlockPath $protectedPolicyPath -TargetUserProfile $TargetUserProfile -TargetUserSid $TargetUserSid -FingerprintOnly
        if (-not [string]::Equals([string]$preparedSource.SkillFingerprint, $PreparedSkillFingerprint, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$preparedSource.PolicyFingerprint, $PreparedPolicyFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Prepared user-profile artifacts do not match the protected recovery sources staged for elevation.'
        }
        $softwareSourceCommitted = $true
        if ($softwarePreviousMoved) {
            Remove-RecoverySourceTree -Path $softwareBackup -Parent $softwareParent
            $softwarePreviousMoved = $false
        }
    }
    catch {
        $original = $_
        $rollbackErrors = New-Object 'Collections.Generic.List[string]'
        if (-not $softwareSourceCommitted -and $softwareStagePromoted -and (Test-Path -LiteralPath $softwareRoot)) {
            try { Remove-RecoverySourceTree -Path $softwareRoot -Parent $softwareParent } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        }
        if (-not $softwareSourceCommitted -and $softwarePreviousMoved -and -not (Test-Path -LiteralPath $softwareRoot) -and (Test-Path -LiteralPath $softwareBackup)) {
            try { [IO.Directory]::Move($softwareBackup, $softwareRoot); $softwarePreviousMoved = $false } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        }
        if (Test-Path -LiteralPath $softwareStage) {
            try { Remove-RecoverySourceTree -Path $softwareStage -Parent $softwareParent } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "Recovery source installation failed and rollback remains incomplete. Original: $($original.Exception.Message) Rollback: $($rollbackErrors -join '; ')"
        }
        throw $original
    }
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
        $runner = Join-Path $softwareRoot 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
        $canary = Join-Path $softwareRoot 'Canaries\PoolCanary.exe'
        $actions = Join-Path $softwareRoot 'Canaries\smoke-actions.json'
        $smokeJson = & $runner -ArtifactPath $canary -ActionsPath $actions -BrokerRoot $brokerRoot -QueueTimeoutSeconds 900 -ExecutionTimeoutSeconds 300
        $smoke = $smokeJson | ConvertFrom-Json
        if (-not [bool]$smoke.Success -or -not [bool]$smoke.PayloadChildDeleted -or [string]$smoke.VmFinalState -ne 'Off') {
            throw "The restored harness smoke test failed: $($smoke.Error)"
        }
    }

    Unregister-RecoveryResumeTaskIfOwned
    $script:resumeHandoffCommitted = $true
    Write-InstallState -Phase 'Ready' -Message 'The Codex Hyper-V harness is ready.' -Details ([ordered]@{ ManifestSha256 = $manifestHash; AuditPath = $auditPath; SmokeResultPath = if ($smoke) { [string]$smoke.ResultPath } else { $null } })
    Write-InstallResult -Success $true -Message 'READY - the one-click Codex Hyper-V harness installation completed successfully.' -Details ([ordered]@{
        BaselineVmId = [string]$baseline.Id
        AuditPath = $auditPath
        Smoke = $smoke
    })
}
catch {
    try {
        if (-not $resumeHandoffCommitted) {
            Unregister-RecoveryResultRunOnceForCurrentUser
            Unregister-RecoveryResumeTaskIfOwned
        }
        Write-InstallState -Phase 'Failed' -Message $_.Exception.Message -Details ([ordered]@{ ScriptStackTrace = $_.ScriptStackTrace })
        Write-InstallResult -Success $false -Message $_.Exception.Message -Details ([ordered]@{ ScriptStackTrace = $_.ScriptStackTrace })
    }
    catch { }
    throw
}
finally {
    if (-not $resumeHandoffCommitted) {
        Unregister-RecoveryResultRunOnceForCurrentUser
        Unregister-RecoveryResumeTaskIfOwned
    }
    Stop-CodexRecoveryAwake
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    if ($mutexTaken) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
