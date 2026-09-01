[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
    [Parameter(Mandatory = $true)] [string] $InstallRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'Plan')] [switch] $PlanOnly,
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')] [switch] $Apply,
    [Parameter(Mandatory = $true, ParameterSetName = 'Resume')] [ValidatePattern('^deploy-[a-f0-9]{16}$')] [string] $ResumeDeploymentId,
    [Parameter(Mandatory = $true, ParameterSetName = 'Preflight')] [switch] $InvocationPreflightOnly,
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Resume')]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')] [string] $ExpectedPlanSha256,
    [ValidatePattern('^[A-Fa-f0-9]{40}$')] [string] $CandidateCommit,
    [ValidatePattern('^deploy-[a-f0-9]{16}$')] [string] $SupersedesDeploymentId,
    [string] $GuestUpdateSwitchName = 'Default Switch',
    [ValidatePattern('^\d+\.\d+$')] [string] $DotNetChannel = '10.0',
    [string] $ExpectedDotNetSdkVersion,
    [string] $TargetUserProfile,
    [string] $TargetUserSid,
    [switch] $AllowLowResources,
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) { throw 'InstallRoot must be a specific non-root directory.' }
if ([string]::IsNullOrWhiteSpace($TargetUserProfile)) { $TargetUserProfile = $env:USERPROFILE }
if ([string]::IsNullOrWhiteSpace($TargetUserSid)) { $TargetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
try { [void][Security.Principal.SecurityIdentifier]::new($TargetUserSid) } catch { throw "Invalid target-user SID: $TargetUserSid" }

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$configPath = Join-Path $InstallRoot 'Software\harness-config.json'
$baselineProvenancePath = Join-Path $InstallRoot 'Live\Setup\guest-baseline-provenance.json'

function Get-StringSha256 {
    param([Parameter(Mandatory = $true)] [string] $Value)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        -join ($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') })
    }
    finally { $algorithm.Dispose() }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Get-GitCommand {
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command git -ErrorAction SilentlyContinue }
    if (-not $command) { throw 'Git is required to bind a release to an exact public source commit.' }
    $command.Source
}

function Get-ReleaseRepositoryState {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [string] $RequestedCommit
    )

    $git = Get-GitCommand
    $resolvedRoot = (& $git -C $Root rev-parse --show-toplevel 2>$null | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolvedRoot)) { throw 'The release source is not a Git checkout.' }
    $resolvedRoot = [IO.Path]::GetFullPath([string]$resolvedRoot).TrimEnd('\')
    if (-not [string]::Equals($resolvedRoot, $Root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The deployment script must run from the repository root checkout: $resolvedRoot"
    }
    $head = [string](& $git -C $Root rev-parse HEAD 2>$null | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[a-fA-F0-9]{40}$') { throw 'Git HEAD could not be resolved to a commit.' }
    $head = $head.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($RequestedCommit)) { $RequestedCommit = $head }
    $resolvedCandidate = [string](& $git -C $Root rev-parse ($RequestedCommit + '^{commit}') 2>$null | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or $resolvedCandidate -notmatch '^[a-fA-F0-9]{40}$') { throw 'CandidateCommit does not resolve to a commit.' }
    $resolvedCandidate = $resolvedCandidate.ToLowerInvariant()
    if (-not [string]::Equals($resolvedCandidate, $head, [StringComparison]::Ordinal)) {
        throw 'CandidateCommit must exactly match HEAD so the reviewed checkout and deployed source cannot diverge.'
    }
    $trackedChanges = @(& $git -C $Root status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Git status failed while checking the release source.' }
    if ($trackedChanges.Count -gt 0) { throw 'Tracked or non-ignored untracked source changes are present. Commit or remove them before planning or applying a release.' }
    [pscustomobject][ordered]@{
        RepositoryRoot = $resolvedRoot
        CandidateCommit = $resolvedCandidate
        TrackedWorktreeClean = $true
        WorktreeClean = $true
    }
}

function Get-InstalledReleaseConfiguration {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Harness configuration is missing: $Path" }
    $configuration = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($field in @('InstallRoot','PoolSize','PoolIdleTimeoutSeconds','VmMemoryBytes','VmProcessorCount','GuestDisplayWidth','GuestDisplayHeight','BrokerRoot','HarnessSourceRoot')) {
        if (-not $configuration.PSObject.Properties[$field]) { throw "Installed harness configuration is missing $field." }
    }
    $configuredRoot = [IO.Path]::GetFullPath([string]$configuration.InstallRoot).TrimEnd('\')
    if (-not [string]::Equals($configuredRoot, $InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Installed harness configuration identity does not match InstallRoot.'
    }
    if ([long]$configuration.VmMemoryBytes % 1GB -ne 0) { throw 'Installed VM memory is not an exact GiB value.' }
    [pscustomobject][ordered]@{
        Document = $configuration
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        VmMemoryGiB = [int]([long]$configuration.VmMemoryBytes / 1GB)
    }
}

function Get-GuestReleaseInventory {
    param(
        [Parameter(Mandatory = $true)] [string] $CandidateSoftwareRoot,
        [Parameter(Mandatory = $true)] [string] $InstalledSoftwareRoot,
        [string] $ProvenancePath
    )

    $provenanceByPath = $null
    if (-not [string]::IsNullOrWhiteSpace($ProvenancePath) -and (Test-Path -LiteralPath $ProvenancePath -PathType Leaf)) {
        try { $provenance = Get-Content -LiteralPath $ProvenancePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Guest-baseline provenance is malformed: $($_.Exception.Message)" }
        if ([int]$provenance.FormatVersion -ne 1 -or -not $provenance.PSObject.Properties['GuestSourceInventory']) {
            throw 'Guest-baseline provenance has an unsupported schema.'
        }
        $provenanceByPath = @{}
        foreach ($entry in @($provenance.GuestSourceInventory)) {
            $relative = [string]$entry.RelativePath
            $sha256 = [string]$entry.Sha256
            if ([string]::IsNullOrWhiteSpace($relative) -or $sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $provenanceByPath.ContainsKey($relative)) {
                throw 'Guest-baseline provenance contains an invalid or duplicate source entry.'
            }
            $provenanceByPath[$relative] = $sha256.ToLowerInvariant()
        }
    }

    @(
        foreach ($relativePath in @(
            'Harness\seed\guest\GuestAgent.ps1',
            'Harness\seed\guest\GuestAgentSupervisor.ps1',
            'Harness\seed\guest\GuestLiveEvidence.ps1'
        )) {
            $candidatePath = Join-Path $CandidateSoftwareRoot $relativePath
            $installedPath = Join-Path $InstalledSoftwareRoot $relativePath
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { throw "Candidate guest source is missing: $candidatePath" }
            $candidateHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $normalizedRelativePath = $relativePath.Replace('\','/')
            $installedHash = if ($null -ne $provenanceByPath) {
                if (-not $provenanceByPath.ContainsKey($normalizedRelativePath)) {
                    throw "Guest-baseline provenance is missing $normalizedRelativePath."
                }
                [string]$provenanceByPath[$normalizedRelativePath]
            }
            elseif (Test-Path -LiteralPath $installedPath -PathType Leaf) {
                (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            else { $null }
            [pscustomobject][ordered]@{
                RelativePath = $normalizedRelativePath
                CandidateSha256 = $candidateHash
                InstalledSha256 = $installedHash
                ComparisonBasis = if ($null -ne $provenanceByPath) { 'GuestBaselineProvenance' } else { 'InstalledSourceFallback' }
                Changed = -not [string]::Equals($candidateHash, $installedHash, [StringComparison]::OrdinalIgnoreCase)
            }
        }
    )
}

function New-ReleaseInstallInvocationParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Plan,
        [Parameter(Mandatory = $true)] $Configuration,
        [switch] $ForPlanOnly
    )

    $parameters = @{
        InstallRoot = [string]$Plan.InstallRoot
        Language = 'Auto'
        PoolSize = [int]$Configuration.Document.PoolSize
        VmMemoryGiB = [int]$Configuration.VmMemoryGiB
        VmProcessorCount = [int]$Configuration.Document.VmProcessorCount
        IdleTimeoutSeconds = [int]$Configuration.Document.PoolIdleTimeoutSeconds
        DisplayWidth = [int]$Configuration.Document.GuestDisplayWidth
        DisplayHeight = [int]$Configuration.Document.GuestDisplayHeight
        GuestUpdateSwitchName = [string]$Plan.GuestUpdateSwitchName
        DotNetChannel = [string]$Plan.DotNetChannel
        ExpectedDotNetSdkVersion = [string]$Plan.ExpectedDotNetSdkVersion
        TargetUserProfile = [string]$Plan.TargetUserProfile
        TargetUserSid = [string]$Plan.TargetUserSid
        AttemptId = ([string]$Plan.PlanSha256).Substring(0, 32)
        ExpectedExistingConfigurationSha256 = [string]$Plan.InstalledConfigurationSha256
        NoRestart = $true
        SkipSmokeTest = $true
        SkipLocalRecoveryBundle = $true
    }
    if ([bool]$Plan.AllowLowResources) { $parameters.AllowLowResources = $true }
    if ([bool]$Plan.GuestBaselineUpdateRequired) { $parameters.DeferPoolRebuildForGuestBaselineUpdate = $true }
    if ($ForPlanOnly) { $parameters.PlanOnly = $true }
    else { $parameters.NoElevation = $true }
    $parameters
}

function New-GuestBaselineInvocationParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Plan,
        [Parameter(Mandatory = $true)] $Configuration,
        [Parameter(Mandatory = $true)] [string] $SourceRoot,
        [Parameter(Mandatory = $true)] [string] $StatusPath,
        [switch] $ForPlanOnly
    )

    $parameters = @{
        VmName = [string]$Configuration.Document.BaselineVmName
        BaselineName = [string]$Configuration.Document.BaselineCheckpointName
        SourceRoot = $SourceRoot
        PoolDefinitionPath = Join-Path ([string]$Configuration.Document.HarnessSourceRoot) 'pool-definition.json'
        BrokerRoot = [string]$Configuration.Document.BrokerRoot
        StatusPath = $StatusPath
        ConfigPath = $configPath
        ClientSid = [string]$Plan.TargetUserSid
    }
    if ($ForPlanOnly) { $parameters.PlanOnly = $true }
    $parameters
}

function New-ReleasePlan {
    param(
        [Parameter(Mandatory = $true)] $RepositoryState,
        [Parameter(Mandatory = $true)] $Configuration,
        [Parameter(Mandatory = $true)] [object[]] $GuestInventory
    )

    $guestUpdateRequired = @($GuestInventory | Where-Object { [bool]$_.Changed }).Count -gt 0
    $operations = New-Object Collections.Generic.List[string]
    $operations.Add('Qualify the exact committed source with the complete deterministic suite and public-payload audit.')
    $operations.Add('Stage and publish source through Install.ps1 without creating recovery or running duplicate smoke acceptance.')
    if ($guestUpdateRequired) { $operations.Add('Replace the guest harness in the canonical baseline and rebuild the disposable pool exactly once.') }
    else { $operations.Add('Refresh the disposable pool exactly once from the unchanged canonical baseline.') }
    $operations.Add('Run legacy launch, bounded keyboard, and expected-guest-power-off acceptance in isolated workers.')
    $operations.Add('Create and deep-verify local recovery exactly once after acceptance.')
    $operations.Add('Revalidate the exact commit and public payload, then publish a terminal release receipt.')

    $core = [ordered]@{
        FormatVersion = 1
        RepositoryRoot = [string]$RepositoryState.RepositoryRoot
        CandidateCommit = [string]$RepositoryState.CandidateCommit
        InstallRoot = $InstallRoot
        InstalledConfigurationSha256 = [string]$Configuration.Sha256
        TargetUserProfile = [IO.Path]::GetFullPath($TargetUserProfile).TrimEnd('\')
        TargetUserSid = $TargetUserSid
        GuestUpdateSwitchName = $GuestUpdateSwitchName
        DotNetChannel = $DotNetChannel
        ExpectedDotNetSdkVersion = $ExpectedDotNetSdkVersion
        AllowLowResources = [bool]$AllowLowResources
        GuestBaselineUpdateRequired = [bool]$guestUpdateRequired
        GuestSourceInventory = @($GuestInventory)
        SupersedesDeploymentId = if ([string]::IsNullOrWhiteSpace($SupersedesDeploymentId)) { $null } else { $SupersedesDeploymentId }
        Operations = $operations.ToArray()
        PrePromotionQualification = 'Exact source parse, build, deterministic tests, invocation contracts, and public-payload audit. No live shadow pool is claimed.'
        LiveShadowPoolAvailable = $false
        Acceptance = @('LegacyLaunch','Utf8ActionName','KeyboardInput','ExpectedGuestPowerOff')
        RecoveryRefreshCount = 1
        AutomaticRollback = $false
        FailurePolicy = 'Stop at the failed checkpoint, preserve valid completed phases, and resume or supersede with a reviewed fix-forward candidate.'
    }
    $planJson = $core | ConvertTo-Json -Depth 30 -Compress
    $planSha256 = Get-StringSha256 -Value $planJson
    $core['PlanSha256'] = $planSha256
    $core['DeploymentId'] = 'deploy-' + $planSha256.Substring(0, 16)
    [pscustomobject]$core
}

function Get-ReleasePlanIdentitySha256 {
    param([Parameter(Mandatory = $true)] $Plan)

    $planCore = [ordered]@{}
    foreach ($property in @($Plan.PSObject.Properties)) {
        if ($property.Name -notin @('PlanSha256','DeploymentId')) { $planCore[$property.Name] = $property.Value }
    }
    Get-StringSha256 -Value ($planCore | ConvertTo-Json -Depth 30 -Compress)
}

function Get-CurrentReleasePlan {
    if ([string]::IsNullOrWhiteSpace($ExpectedDotNetSdkVersion)) {
        throw 'ExpectedDotNetSdkVersion is required so the reviewed plan cannot drift to a different SDK release.'
    }
    $repositoryState = Get-ReleaseRepositoryState -Root $repositoryRoot -RequestedCommit $CandidateCommit
    $configuration = Get-InstalledReleaseConfiguration -Path $configPath
    $guestInventory = @(Get-GuestReleaseInventory -CandidateSoftwareRoot (Join-Path $repositoryRoot 'src\Software') -InstalledSoftwareRoot (Join-Path $InstallRoot 'Software') -ProvenancePath $baselineProvenancePath)
    [pscustomobject][ordered]@{
        Plan = New-ReleasePlan -RepositoryState $repositoryState -Configuration $configuration -GuestInventory $guestInventory
        Configuration = $configuration
    }
}

function Get-ResumableReleasePlan {
    if ([string]::IsNullOrWhiteSpace($ExpectedDotNetSdkVersion)) {
        throw 'ExpectedDotNetSdkVersion is required so resume remains bound to the reviewed SDK release.'
    }
    $resumeRoot = Join-Path $InstallRoot ('Live\Setup\Deployments\' + $ResumeDeploymentId)
    $resumeStatePath = Join-Path $resumeRoot 'state.json'
    if (-not (Test-Path -LiteralPath $resumeStatePath -PathType Leaf)) { throw "Deployment state is missing: $resumeStatePath" }
    $persistedState = Get-Content -LiteralPath $resumeStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::Equals([string]$persistedState.DeploymentId, $ResumeDeploymentId, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$persistedState.PlanSha256, $ExpectedPlanSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The persisted deployment identity does not match the requested resume plan.'
    }
    $persistedPlan = $persistedState.Plan
    if (-not $persistedPlan) { throw 'The persisted deployment plan is missing.' }
    $recomputedPlanSha256 = Get-ReleasePlanIdentitySha256 -Plan $persistedPlan
    if (-not [string]::Equals($recomputedPlanSha256, $ExpectedPlanSha256, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$persistedPlan.PlanSha256, $ExpectedPlanSha256, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$persistedPlan.DeploymentId, $ResumeDeploymentId, [StringComparison]::Ordinal)) {
        throw 'The persisted deployment plan does not match its immutable SHA-256 identity.'
    }

    $repositoryState = Get-ReleaseRepositoryState -Root $repositoryRoot -RequestedCommit ([string]$persistedPlan.CandidateCommit)
    $configuration = Get-InstalledReleaseConfiguration -Path $configPath
    if (-not [string]::Equals([string]$configuration.Sha256, [string]$persistedPlan.InstalledConfigurationSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installed harness configuration changed after the deployment plan was approved.'
    }
    $currentGuestInventory = @(Get-GuestReleaseInventory -CandidateSoftwareRoot (Join-Path $repositoryRoot 'src\Software') -InstalledSoftwareRoot (Join-Path $InstallRoot 'Software') -ProvenancePath $baselineProvenancePath)
    foreach ($approvedEntry in @($persistedPlan.GuestSourceInventory)) {
        $currentEntry = @($currentGuestInventory | Where-Object { [string]$_.RelativePath -eq [string]$approvedEntry.RelativePath })
        if ($currentEntry.Count -ne 1 -or
            -not [string]::Equals([string]$currentEntry[0].CandidateSha256, [string]$approvedEntry.CandidateSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Candidate guest source changed after approval: $($approvedEntry.RelativePath)"
        }
    }
    $expectedSupersedes = if ([string]::IsNullOrWhiteSpace($SupersedesDeploymentId)) { $null } else { $SupersedesDeploymentId }
    foreach ($binding in @(
        [pscustomobject]@{ Name = 'GuestUpdateSwitchName'; Current = $GuestUpdateSwitchName; Approved = [string]$persistedPlan.GuestUpdateSwitchName },
        [pscustomobject]@{ Name = 'DotNetChannel'; Current = $DotNetChannel; Approved = [string]$persistedPlan.DotNetChannel },
        [pscustomobject]@{ Name = 'ExpectedDotNetSdkVersion'; Current = $ExpectedDotNetSdkVersion; Approved = [string]$persistedPlan.ExpectedDotNetSdkVersion },
        [pscustomobject]@{ Name = 'TargetUserProfile'; Current = [IO.Path]::GetFullPath($TargetUserProfile).TrimEnd('\'); Approved = [string]$persistedPlan.TargetUserProfile },
        [pscustomobject]@{ Name = 'TargetUserSid'; Current = $TargetUserSid; Approved = [string]$persistedPlan.TargetUserSid },
        [pscustomobject]@{ Name = 'SupersedesDeploymentId'; Current = $expectedSupersedes; Approved = [string]$persistedPlan.SupersedesDeploymentId }
    )) {
        if (-not [string]::Equals([string]$binding.Current, [string]$binding.Approved, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Resume parameter $($binding.Name) differs from the approved deployment plan."
        }
    }
    if ([bool]$AllowLowResources -ne [bool]$persistedPlan.AllowLowResources) {
        throw 'Resume parameter AllowLowResources differs from the approved deployment plan.'
    }
    [pscustomobject][ordered]@{ Plan = $persistedPlan; Configuration = $configuration }
}

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enable-ReleaseAwake {
    if (-not ('CodexHyperVReleasePower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexHyperVReleasePower
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SetThreadExecutionState(uint flags);
    public static bool PreventSystemSleep() { return SetThreadExecutionState(0x80000001) != 0; }
    public static void RestoreDefault() { SetThreadExecutionState(0x80000000); }
}
'@
    }
    if (-not [CodexHyperVReleasePower]::PreventSystemSleep()) { throw 'Windows rejected release sleep inhibition.' }
    $script:releaseAwake = $true
}

function Disable-ReleaseAwake {
    if ($script:releaseAwake -and ('CodexHyperVReleasePower' -as [type])) {
        [CodexHyperVReleasePower]::RestoreDefault()
        $script:releaseAwake = $false
    }
}

function Get-ElevationArguments {
    param([Parameter(Mandatory = $true)] $Plan)

    $arguments = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'),
        '-InstallRoot',('"' + $InstallRoot + '"'),
        '-CandidateCommit',[string]$Plan.CandidateCommit,
        '-GuestUpdateSwitchName',('"' + $GuestUpdateSwitchName + '"'),
        '-DotNetChannel',$DotNetChannel,
        '-ExpectedDotNetSdkVersion',$ExpectedDotNetSdkVersion,
        '-TargetUserProfile',('"' + $TargetUserProfile + '"'),
        '-TargetUserSid',$TargetUserSid,
        '-ExpectedPlanSha256',$ExpectedPlanSha256,
        '-NoElevation'
    )
    if (-not [string]::IsNullOrWhiteSpace($ResumeDeploymentId)) { $arguments += @('-ResumeDeploymentId',$ResumeDeploymentId) }
    else { $arguments += '-Apply' }
    if (-not [string]::IsNullOrWhiteSpace($SupersedesDeploymentId)) { $arguments += @('-SupersedesDeploymentId',$SupersedesDeploymentId) }
    if ($AllowLowResources) { $arguments += '-AllowLowResources' }
    $arguments
}

if ($InvocationPreflightOnly) {
    $fakePlan = [pscustomobject][ordered]@{
        InstallRoot = $InstallRoot; PlanSha256 = ('a' * 64); InstalledConfigurationSha256 = ('b' * 64)
        GuestUpdateSwitchName = 'Test switch'; DotNetChannel = '10.0'; ExpectedDotNetSdkVersion = '10.0.100'
        TargetUserProfile = 'C:\Users\<TARGET_USER>'; TargetUserSid = 'S-1-5-18'; AllowLowResources = $false
        GuestBaselineUpdateRequired = $true
    }
    $fakeConfiguration = [pscustomobject][ordered]@{
        VmMemoryGiB = 8
        Document = [pscustomobject][ordered]@{
            PoolSize = 4; VmProcessorCount = 4; PoolIdleTimeoutSeconds = 600
            GuestDisplayWidth = 1920; GuestDisplayHeight = 1080
            BaselineVmName = 'Codex-Harness-Baseline'; BaselineCheckpointName = 'Clean-Windows11-Harness'
            HarnessSourceRoot = Join-Path $InstallRoot 'Software\Harness'; BrokerRoot = Join-Path $InstallRoot 'Live\Broker'
        }
    }
    $installInvocation = New-ReleaseInstallInvocationParameters -Plan $fakePlan -Configuration $fakeConfiguration
    $guestInvocation = New-GuestBaselineInvocationParameters -Plan $fakePlan -Configuration $fakeConfiguration -SourceRoot (Join-Path $InstallRoot 'Software\Harness') -StatusPath (Join-Path $InstallRoot 'Live\Setup\guest-update.json')
    $roundTripPlan = New-ReleasePlan `
        -RepositoryState ([pscustomobject]@{ RepositoryRoot = 'C:\ReleaseSource'; CandidateCommit = ('c' * 40) }) `
        -Configuration ([pscustomobject]@{ Sha256 = ('b' * 64) }) `
        -GuestInventory @([pscustomobject][ordered]@{ RelativePath = 'Harness/seed/guest/GuestAgent.ps1'; CandidateSha256 = ('d' * 64); InstalledSha256 = ('e' * 64); Changed = $true })
    $roundTripEnvelope = [pscustomobject]@{ Plan = $roundTripPlan } | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $roundTripVerified = [string]::Equals(
        [string]$roundTripEnvelope.Plan.PlanSha256,
        (Get-ReleasePlanIdentitySha256 -Plan $roundTripEnvelope.Plan),
        [StringComparison]::OrdinalIgnoreCase
    )
    [pscustomobject][ordered]@{
        Success = $installInvocation.ContainsKey('DeferPoolRebuildForGuestBaselineUpdate') -and $installInvocation.ContainsKey('SkipLocalRecoveryBundle') -and $guestInvocation.Count -gt 0 -and $roundTripVerified
        NoMutationPerformed = $true
        PlanRoundTripVerified = $roundTripVerified
        InstallInvocation = $installInvocation
        GuestBaselineInvocation = $guestInvocation
    }
    return
}

$release = if ($PSCmdlet.ParameterSetName -eq 'Resume') { Get-ResumableReleasePlan } else { Get-CurrentReleasePlan }
$plan = $release.Plan
$configuration = $release.Configuration

if ($PlanOnly) {
    $publicAuditJson = & (Join-Path $repositoryRoot 'setup\Test-PublicRepository.ps1') -RepositoryRoot $repositoryRoot -AsJson
    $publicAudit = $publicAuditJson | ConvertFrom-Json
    if (-not [bool]$publicAudit.Success) { throw 'The public repository audit failed during release planning.' }
    $installParameters = New-ReleaseInstallInvocationParameters -Plan $plan -Configuration $configuration -ForPlanOnly
    $installOutput = @(& (Join-Path $repositoryRoot 'setup\Install.ps1') @installParameters)
    $installPlan = $installOutput | Select-Object -Last 1
    if (-not $installPlan -or -not [bool]$installPlan.PlanOnly -or -not [bool]$installPlan.Configuration.NoMutationPerformed) {
        throw 'The exact Install.ps1 plan did not complete without mutation.'
    }
    $guestPlan = $null
    if ([bool]$plan.GuestBaselineUpdateRequired) {
        $guestParameters = New-GuestBaselineInvocationParameters -Plan $plan -Configuration $configuration -SourceRoot (Join-Path $repositoryRoot 'src\Software\Harness') -StatusPath (Join-Path $InstallRoot 'Live\Setup\guest-release-plan.json') -ForPlanOnly
        $guestPlanJson = & (Join-Path $repositoryRoot 'src\Software\Harness\Update-GuestHarnessBaseline.ps1') @guestParameters
        $guestPlan = if ($guestPlanJson -is [string]) { $guestPlanJson | ConvertFrom-Json } else { $guestPlanJson }
        if (-not [bool]$guestPlan.NoMutationPerformed) { throw 'The guest-baseline component plan did not remain read-only.' }
    }
    $acceptancePlan = & (Join-Path $repositoryRoot 'setup\Invoke-HarnessReleaseAcceptance.ps1') -InstallRoot $InstallRoot -InvocationPreflightOnly
    [pscustomobject][ordered]@{
        FormatVersion = 1
        PlanOnly = $true
        NoMutationPerformed = $true
        ApprovalReady = [bool]$publicAudit.Success -and [bool]$installPlan.Preflight.Success -and ($null -eq $guestPlan -or [bool]$guestPlan.ApprovalReady) -and [bool]$acceptancePlan.Success
        DeploymentId = [string]$plan.DeploymentId
        PlanSha256 = [string]$plan.PlanSha256
        Plan = $plan
        CurrentReadiness = [ordered]@{
            PublicAudit = [ordered]@{ Success = [bool]$publicAudit.Success; FileCount = [int]$publicAudit.FileCount }
            Install = $installPlan
            GuestBaseline = $guestPlan
            AcceptanceInvocation = $acceptancePlan
        }
        ApprovalBoundary = 'Apply performs one elevation and the listed live mutations. ForceRebuild, image servicing, networking changes, host restart, and automatic rollback are not authorized by this plan.'
        ApplyParameters = [ordered]@{
            InstallRoot = $InstallRoot
            Apply = $true
            CandidateCommit = [string]$plan.CandidateCommit
            ExpectedPlanSha256 = [string]$plan.PlanSha256
            GuestUpdateSwitchName = $GuestUpdateSwitchName
            DotNetChannel = $DotNetChannel
            ExpectedDotNetSdkVersion = $ExpectedDotNetSdkVersion
            TargetUserProfile = $TargetUserProfile
            TargetUserSid = $TargetUserSid
            AllowLowResources = [bool]$AllowLowResources
            SupersedesDeploymentId = $plan.SupersedesDeploymentId
        }
    }
    return
}

if (-not [string]::Equals([string]$plan.PlanSha256, $ExpectedPlanSha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The release plan changed after review. Expected $ExpectedPlanSha256 but found $($plan.PlanSha256)."
}
if ($PSCmdlet.ParameterSetName -eq 'Resume' -and -not [string]::Equals([string]$plan.DeploymentId, $ResumeDeploymentId, [StringComparison]::Ordinal)) {
    throw "ResumeDeploymentId does not match the current immutable plan: $($plan.DeploymentId)"
}

if (-not (Test-Administrator) -or [string]$PSVersionTable.PSEdition -ne 'Desktop') {
    if ($NoElevation) {
        if ([string]$PSVersionTable.PSEdition -ne 'Desktop') { throw 'Release apply and resume require Windows PowerShell 5.1.' }
        throw 'Administrator rights are required to apply or resume a harness release.'
    }
    $startParameters = @{
        FilePath = 'powershell.exe'
        ArgumentList = Get-ElevationArguments -Plan $plan
        PassThru = $true
        Wait = $true
        WindowStyle = 'Hidden'
    }
    if (-not (Test-Administrator)) { $startParameters.Verb = 'RunAs' }
    $process = Start-Process @startParameters
    exit $process.ExitCode
}

$deploymentRoot = Join-Path $InstallRoot ('Live\Setup\Deployments\' + [string]$plan.DeploymentId)
$statePath = Join-Path $deploymentRoot 'state.json'
$resultPath = Join-Path $deploymentRoot 'result.json'
$logPath = Join-Path $deploymentRoot 'deployment.log'
$startedUtc = [DateTime]::UtcNow
$mutex = $null
$mutexTaken = $false
$transcriptStarted = $false
$releaseAwake = $false

function Save-DeploymentState {
    Write-JsonAtomic -Path $statePath -Value $script:deploymentState
}

function Set-PhaseRecord {
    param([Parameter(Mandatory = $true)] [string] $Name, [Parameter(Mandatory = $true)] $Record)

    $property = $script:deploymentState.Phases.PSObject.Properties[$Name]
    if ($property) { $property.Value = $Record }
    else { $script:deploymentState.Phases | Add-Member -NotePropertyName $Name -NotePropertyValue $Record }
}

function Invoke-DeploymentPhase {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [scriptblock] $Body
    )

    $inputSha256 = Get-StringSha256 -Value (([string]$plan.PlanSha256) + ':' + $Name)
    $existing = $script:deploymentState.Phases.PSObject.Properties[$Name]
    if ($existing -and [string]$existing.Value.Status -eq 'Succeeded') {
        if (-not [string]::Equals([string]$existing.Value.InputSha256, $inputSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Completed phase $Name has a different input fingerprint."
        }
        Write-Host "[$Name] Reusing the completed checkpoint."
        return $existing.Value.Output
    }

    $phaseStartedUtc = [DateTime]::UtcNow
    Set-PhaseRecord -Name $Name -Record ([pscustomobject][ordered]@{
        Status = 'Running'; InputSha256 = $inputSha256; StartedUtc = $phaseStartedUtc.ToString('o')
        CompletedUtc = $null; Output = $null; Error = $null
    })
    $script:deploymentState.Status = 'Running'
    $script:deploymentState.CurrentPhase = $Name
    $script:deploymentState.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Save-DeploymentState
    Write-Host "[$Name] Starting."
    try {
        $output = & $Body
        Set-PhaseRecord -Name $Name -Record ([pscustomobject][ordered]@{
            Status = 'Succeeded'; InputSha256 = $inputSha256; StartedUtc = $phaseStartedUtc.ToString('o')
            CompletedUtc = [DateTime]::UtcNow.ToString('o'); Output = $output; Error = $null
        })
        $script:deploymentState.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Save-DeploymentState
        Write-Host "[$Name] Succeeded."
        $output
    }
    catch {
        Set-PhaseRecord -Name $Name -Record ([pscustomobject][ordered]@{
            Status = 'Failed'; InputSha256 = $inputSha256; StartedUtc = $phaseStartedUtc.ToString('o')
            CompletedUtc = [DateTime]::UtcNow.ToString('o'); Output = $null
            Error = [ordered]@{ Message = $_.Exception.Message; ScriptStackTrace = $_.ScriptStackTrace }
        })
        $script:deploymentState.Status = 'NeedsFixForward'
        $script:deploymentState.CurrentPhase = $Name
        $script:deploymentState.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Save-DeploymentState
        Write-JsonAtomic -Path $resultPath -Value ([ordered]@{
            Success = $false; Status = 'NeedsFixForward'; DeploymentId = [string]$plan.DeploymentId
            PlanSha256 = [string]$plan.PlanSha256; FailedPhase = $Name; Message = $_.Exception.Message
            AutomaticRollbackAttempted = $false; StatePath = $statePath; CompletedUtc = [DateTime]::UtcNow.ToString('o')
        })
        throw
    }
}

try {
    $mutex = New-Object Threading.Mutex($false, 'Global\CodexHyperVReleaseDeployment')
    try { $mutexTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) } catch [Threading.AbandonedMutexException] { $mutexTaken = $true }
    if (-not $mutexTaken) { throw 'Another harness release deployment is already running.' }
    New-Item -ItemType Directory -Force -Path $deploymentRoot | Out-Null
    Start-Transcript -LiteralPath $logPath -Append | Out-Null
    $transcriptStarted = $true
    Enable-ReleaseAwake

    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $deploymentState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not [string]::Equals([string]$deploymentState.PlanSha256, [string]$plan.PlanSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The persisted deployment state belongs to a different release plan.'
        }
        if ([string]$deploymentState.Status -eq 'Ready') {
            throw 'This release deployment is already complete.'
        }
        if ($PSCmdlet.ParameterSetName -ne 'Resume') {
            throw "This release already has resumable state. Use -ResumeDeploymentId $($plan.DeploymentId) with the same plan hash."
        }
    }
    else {
        if ($PSCmdlet.ParameterSetName -eq 'Resume') { throw "Deployment state is missing: $statePath" }
        $deploymentState = [pscustomobject][ordered]@{
            FormatVersion = 1; DeploymentId = [string]$plan.DeploymentId; PlanSha256 = [string]$plan.PlanSha256
            Status = 'Running'; CurrentPhase = $null; StartedUtc = $startedUtc.ToString('o'); UpdatedUtc = $startedUtc.ToString('o')
            InstallRoot = $InstallRoot; CandidateCommit = [string]$plan.CandidateCommit; Plan = $plan
            Phases = [pscustomobject]@{}
        }
        Save-DeploymentState
    }

    Invoke-DeploymentPhase -Name 'CandidateQualification' -Body {
        $sourceOutput = @(& (Join-Path $repositoryRoot 'setup\Test-Source.ps1'))
        $sourceJson = $sourceOutput | Select-Object -Last 1
        $sourceResult = if ($sourceJson -is [string]) { $sourceJson | ConvertFrom-Json } else { $sourceJson }
        if (-not [bool]$sourceResult.Success) { throw 'The complete deterministic source suite failed.' }
        $auditJson = & (Join-Path $repositoryRoot 'setup\Test-PublicRepository.ps1') -RepositoryRoot $repositoryRoot -AsJson
        $publicAudit = $auditJson | ConvertFrom-Json
        if (-not [bool]$publicAudit.Success) { throw 'The public repository audit failed.' }
        [pscustomobject][ordered]@{
            SourceSuite = [ordered]@{
                ParsedPowerShellFiles = [int]$sourceResult.ParsedPowerShellFiles
                BuiltCanaries = @($sourceResult.BuiltCanaries).Count
                DeterministicTestFiles = [int]$sourceResult.DeterministicTestFiles
                DeterministicScenarios = [int]$sourceResult.DeterministicScenarios
            }
            PublicAudit = [ordered]@{ FileCount = [int]$publicAudit.FileCount; Success = [bool]$publicAudit.Success }
        }
    } | Out-Null

    Invoke-DeploymentPhase -Name 'LiveReadiness' -Body {
        if (-not [bool]$plan.GuestBaselineUpdateRequired) {
            return [pscustomobject][ordered]@{ GuestBaselineUpdateRequired = $false; ApprovalReady = $true }
        }
        $guestPlanParameters = New-GuestBaselineInvocationParameters -Plan $plan -Configuration $configuration -SourceRoot (Join-Path $repositoryRoot 'src\Software\Harness') -StatusPath (Join-Path $deploymentRoot 'guest-plan.json') -ForPlanOnly
        $guestPlanJson = & (Join-Path $repositoryRoot 'src\Software\Harness\Update-GuestHarnessBaseline.ps1') @guestPlanParameters
        $guestPlan = if ($guestPlanJson -is [string]) { $guestPlanJson | ConvertFrom-Json } else { $guestPlanJson }
        if (-not [bool]$guestPlan.NoMutationPerformed -or -not [bool]$guestPlan.ApprovalReady) {
            throw 'Guest-baseline readiness failed because the broker is not drained or the exact component plan is invalid.'
        }
        $guestPlan
    } | Out-Null

    Invoke-DeploymentPhase -Name 'SourcePromotion' -Body {
        $installParameters = New-ReleaseInstallInvocationParameters -Plan $plan -Configuration $configuration
        $installOutput = @(& (Join-Path $repositoryRoot 'setup\Install.ps1') @installParameters)
        $installResult = $installOutput | Select-Object -Last 1
        if (-not $installResult -or -not [bool]$installResult.Success) { throw 'Install.ps1 did not report a successful source promotion.' }
        if ([bool]$plan.GuestBaselineUpdateRequired -and -not [bool]$installResult.Details.PoolRefreshDeferredForGuestBaselineUpdate) {
            throw 'Source promotion did not preserve the single-rebuild guest-baseline path.'
        }
        $installResult
    } | Out-Null

    if ([bool]$plan.GuestBaselineUpdateRequired) {
        Invoke-DeploymentPhase -Name 'GuestBaselinePromotion' -Body {
            $installedHarnessRoot = Join-Path $InstallRoot 'Software\Harness'
            $guestStatusPath = Join-Path $deploymentRoot 'guest-update.json'
            $guestParameters = New-GuestBaselineInvocationParameters -Plan $plan -Configuration $configuration -SourceRoot $installedHarnessRoot -StatusPath $guestStatusPath
            & (Join-Path $installedHarnessRoot 'Update-GuestHarnessBaseline.ps1') @guestParameters
            if (-not (Test-Path -LiteralPath $guestStatusPath -PathType Leaf)) { throw 'Guest-baseline promotion did not publish its status file.' }
            $guestResult = Get-Content -LiteralPath $guestStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [bool]$guestResult.Success) { throw 'The guest-baseline promotion did not report success.' }
            Write-JsonAtomic -Path $baselineProvenancePath -Value ([ordered]@{
                FormatVersion = 1
                CandidateCommit = [string]$plan.CandidateCommit
                GuestSourceInventory = @($plan.GuestSourceInventory | ForEach-Object {
                    [ordered]@{ RelativePath = [string]$_.RelativePath; Sha256 = [string]$_.CandidateSha256 }
                })
                GuestUpdateStatusPath = $guestStatusPath
                GuestUpdateStatusSha256 = (Get-FileHash -LiteralPath $guestStatusPath -Algorithm SHA256).Hash
                UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            })
            [pscustomobject][ordered]@{ Update = $guestResult; BaselineProvenancePath = $baselineProvenancePath }
        } | Out-Null
    }

    Invoke-DeploymentPhase -Name 'IsolatedAcceptance' -Body {
        $acceptance = & (Join-Path $InstallRoot 'Software\Setup\Invoke-HarnessReleaseAcceptance.ps1') `
            -InstallRoot $InstallRoot `
            -EvidenceRoot (Join-Path $deploymentRoot 'Acceptance') `
            -ClientSid $TargetUserSid
        if (-not [bool]$acceptance.Success -or @($acceptance.Tests).Count -ne 4) { throw 'Release acceptance did not pass all four isolated checks.' }
        $acceptance
    } | Out-Null

    Invoke-DeploymentPhase -Name 'RecoveryRefresh' -Body {
        $recoveryOutput = @(& (Join-Path $InstallRoot 'Software\Setup\Refresh-LocalRecovery.ps1') -InstallRoot $InstallRoot -TargetUserProfile $TargetUserProfile -NoElevation)
        $manifestPath = Join-Path $InstallRoot 'Recovery\Current\manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The final recovery refresh did not publish Recovery\Current\manifest.json.' }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        [pscustomobject][ordered]@{
            ManifestPath = $manifestPath
            ManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
            RecoveryOutputCount = $recoveryOutput.Count
            Manifest = $manifest
        }
    } | Out-Null

    Invoke-DeploymentPhase -Name 'Finalization' -Body {
        $repositoryState = Get-ReleaseRepositoryState -Root $repositoryRoot -RequestedCommit ([string]$plan.CandidateCommit)
        $auditJson = & (Join-Path $repositoryRoot 'setup\Test-PublicRepository.ps1') -RepositoryRoot $repositoryRoot -AsJson
        $publicAudit = $auditJson | ConvertFrom-Json
        if (-not [bool]$publicAudit.Success) { throw 'The final public repository audit failed.' }
        [pscustomobject][ordered]@{
            CandidateCommit = [string]$repositoryState.CandidateCommit
            TrackedWorktreeClean = [bool]$repositoryState.TrackedWorktreeClean
            PublicAuditFileCount = [int]$publicAudit.FileCount
            ReadyToPush = $true
        }
    } | Out-Null

    $deploymentState.Status = 'Ready'
    $deploymentState.CurrentPhase = 'Ready'
    $deploymentState.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Save-DeploymentState
    $terminalResult = [ordered]@{
        Success = $true; Status = 'Ready'; DeploymentId = [string]$plan.DeploymentId; PlanSha256 = [string]$plan.PlanSha256
        CandidateCommit = [string]$plan.CandidateCommit; StatePath = $statePath; RecoveryRefreshCount = 1
        AcceptanceTests = @('LegacyLaunch','Utf8ActionName','KeyboardInput','ExpectedGuestPowerOff')
        AutomaticRollbackAttempted = $false; ReadyToPush = $true; CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic -Path $resultPath -Value $terminalResult
    [pscustomobject]$terminalResult
}
catch {
    if ($null -ne $deploymentState -and [string]$deploymentState.Status -notin @('NeedsFixForward','Ready')) {
        try {
            $deploymentState.Status = 'NeedsFixForward'
            $deploymentState.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            Save-DeploymentState
        }
        catch { }
    }
    throw
}
finally {
    Disable-ReleaseAwake
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    if ($mutexTaken) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
