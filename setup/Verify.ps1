[CmdletBinding()]
param(
    [string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness',
    [switch] $SkipSmokeTest,
    [switch] $DeepRecoveryVerification,
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$configPath = Join-Path $InstallRoot 'Software\harness-config.json'
$statusPath = Join-Path $InstallRoot 'Live\Setup\verification-result.json'

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Write-Result($Value) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statusPath) | Out-Null
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

if (-not (Test-Administrator)) {
    if ($NoElevation) { throw 'Verification requires administrator rights.' }
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'),'-InstallRoot',('"' + $InstallRoot + '"'),'-NoElevation')
    if ($SkipSmokeTest) { $arguments += '-SkipSmokeTest' }
    if ($DeepRecoveryVerification) { $arguments += '-DeepRecoveryVerification' }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -PassThru -Wait
    exit $process.ExitCode
}

$startedUtc = [DateTime]::UtcNow
try {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Harness configuration is missing: $configPath" }
    . (Join-Path $InstallRoot 'Software\Harness\HarnessPaths.ps1')
    $layout = Get-CodexHarnessConfig -ConfigPath $configPath
    $pointer = Get-Content -LiteralPath ([string]$layout.BrokerLocationPointer) -Raw | ConvertFrom-Json
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$pointer.BrokerRoot), [IO.Path]::GetFullPath([string]$layout.BrokerRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The broker location pointer does not match the installed configuration.'
    }
    $task = Get-ScheduledTask -TaskName ([string]$layout.BrokerTaskName) -ErrorAction Stop
    if ($task.State -eq 'Disabled') { throw 'The SYSTEM broker task is disabled.' }
    $auditPath = Join-Path ([string]$layout.BrokerRoot) 'State\Management\public-verification-audit.json'
    & (Join-Path ([string]$layout.HarnessSourceRoot) 'Audit-HyperVTestPool.ps1') -DefinitionPath (Join-Path ([string]$layout.HarnessSourceRoot) 'pool-definition.json') -BrokerRoot ([string]$layout.BrokerRoot) -StatusPath $auditPath -ExpectedIdleTimeoutSeconds ([int]$layout.PoolIdleTimeoutSeconds) -ConfigPath $configPath
    $audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
    if (-not [bool]$audit.Success) { throw 'The Hyper-V pool audit failed.' }

    $skill = @(
        (Join-Path $env:USERPROFILE '.agents\skills\hyperv-test-executables'),
        (Join-Path $env:USERPROFILE '.codex\skills\hyperv-test-executables')
    ) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'SKILL.md') -PathType Leaf } | Select-Object -First 1
    if (-not $skill) { throw 'The runtime Codex skill is missing from both .agents\skills and .codex\skills.' }
    $smoke = $null
    if (-not $SkipSmokeTest) {
        $smokeJson = & (Join-Path $skill 'scripts\Invoke-HyperVExecutableTest.ps1') -ArtifactPath (Join-Path ([string]$layout.SoftwareRoot) 'Canaries\PoolCanary.exe') -ActionsPath (Join-Path ([string]$layout.SoftwareRoot) 'Canaries\smoke-actions.json') -BrokerRoot ([string]$layout.BrokerRoot) -QueueTimeoutSeconds 900 -ExecutionTimeoutSeconds 300
        $smoke = $smokeJson | ConvertFrom-Json
        if (-not [bool]$smoke.Success -or -not [bool]$smoke.PayloadChildDeleted) { throw "The isolated canary failed: $($smoke.Error)" }
        if (-not (Test-Path -LiteralPath (Join-Path ([string]$smoke.ResultPath) 'recovery-smoke.png') -PathType Leaf)) { throw 'The isolated canary did not return its requested screenshot.' }
    }

    $recovery = $null
    $bundleRoot = Join-Path ([string]$layout.RecoveryRoot) 'Current'
    if (Test-Path -LiteralPath (Join-Path $bundleRoot 'manifest.json') -PathType Leaf) {
        $arguments = @{ BundleRoot = $bundleRoot; NoElevation = $true }
        if (-not $DeepRecoveryVerification) { $arguments.SkipContentHashes = $true }
        $recovery = & (Join-Path ([string]$layout.SoftwareRoot) 'Recovery\Test-CodexHyperVRecovery.ps1') @arguments
    }
    $result = [ordered]@{
        Success = $true; Message = 'The installed Hyper-V executable-test backend passed verification.'
        StartedUtc = $startedUtc.ToString('o'); CompletedUtc = [DateTime]::UtcNow.ToString('o')
        InstallRoot = $InstallRoot; Audit = $audit; Smoke = $smoke; Recovery = $recovery
    }
    Write-Result $result
    [pscustomobject]$result
}
catch {
    Write-Result ([ordered]@{
        Success = $false; Message = $_.Exception.Message; StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o'); InstallRoot = $InstallRoot; ScriptStackTrace = $_.ScriptStackTrace
    })
    throw
}
