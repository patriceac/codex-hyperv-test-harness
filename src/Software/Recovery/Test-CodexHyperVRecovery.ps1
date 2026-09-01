[CmdletBinding()]
param(
    [string] $BundleRoot,
    [switch] $SkipContentHashes,
    [string] $StatusPath,
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BundleRoot)) {
    $softwareRoot = Split-Path -Parent $PSScriptRoot
    $configPath = Join-Path $softwareRoot 'harness-config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Pass -BundleRoot when verifying outside an installed harness.' }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $BundleRoot = Join-Path ([string]$config.RecoveryRoot) 'Current'
}
. (Join-Path $PSScriptRoot 'RecoveryCommon.ps1')
$BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
if (-not (Test-CodexAdministrator)) {
    if ($NoElevation) { throw 'Recovery verification requires administrator rights to read the protected portable credential.' }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $PSCommandPath + '"'),
        '-BundleRoot', ('"' + $BundleRoot + '"'),
        '-NoElevation'
    )
    if ($SkipContentHashes) { $arguments += '-SkipContentHashes' }
    if (-not [string]::IsNullOrWhiteSpace($StatusPath)) { $arguments += '-StatusPath'; $arguments += ('"' + $StatusPath + '"') }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    exit $process.ExitCode
}
$startedUtc = [DateTime]::UtcNow
if ([string]::IsNullOrWhiteSpace($StatusPath)) {
    $StatusPath = Join-Path (Split-Path -Parent $BundleRoot) 'last-verification.json'
}

try {
    $integrity = Test-CodexRecoveryBundleIntegrity -BundleRoot $BundleRoot -SkipContentHashes:$SkipContentHashes
    if (-not $integrity.Success) { throw ($integrity.Failures -join '; ') }
    $manifest = $integrity.Manifest
    $required = @(
        'INSTALL.cmd',
        'Install-CodexHyperVHarness.ps1',
        'RecoveryCommon.ps1',
        'SHOW-RECOVERY-RESULT.cmd',
        'Show-CodexHyperVRecoveryResult.ps1',
        'checksums.sha256',
        'manifest.json',
        'Codex\AGENTS.md',
        'Software\harness-config.json',
        'Software\Common\CodexManagedPolicy.ps1',
        'Software\Setup\AGENTS.block.md',
        'Software\Setup\Update-RequestNetworking.ps1',
        'Software\Setup\Prepare-RequestNetworkInfrastructure.ps1',
        'Software\Harness\HostBroker.ps1',
        'Software\Harness\HostInputShare.ps1',
        'Software\Harness\RequestNetwork.ps1',
        'Software\Harness\LiveEvidence.ps1',
        'Software\Harness\seed\guest\GuestLiveEvidence.ps1',
        'Software\Harness\Initialize-HyperVTestPool.ps1',
        'Software\Harness\Install-PoolHostBroker.ps1',
        'Software\Harness\private\guest-credential.json',
        'Software\Skill\SKILL.md',
        'Software\Skill\references\host-control.md',
        'Software\Skill\scripts\HostControlNative.cs',
        'Software\Skill\scripts\Invoke-HostExecutableTest.ps1',
        'Software\Skill\scripts\Invoke-HyperVExecutableTest.ps1',
        'Software\Skill\scripts\Capture-HyperVExecutableTestLiveEvidence.ps1',
        'Software\Canaries\PoolCanary.exe',
        'Software\Canaries\DetachedLockCanary.exe',
        'Software\Canaries\detached-lock-actions.json',
        'Software\Canaries\HostInputCanary.cs',
        'Software\Canaries\HostInputCanary.exe',
        'Software\Canaries\host-input-actions.json',
        'Software\Canaries\NetworkBoundaryCanary.cs',
        'Software\Canaries\NetworkBoundaryCanary.exe',
        'Software\Canaries\LiveEvidenceCanary.exe',
        'Software\Canaries\live-evidence-actions.json',
        'Software\Canaries\HarnessContractCanary.cs',
        'Software\Canaries\HarnessContractCanary.exe',
        'Software\Canaries\release-utf8-actions.json',
        'Software\Harness\tests\Test-AtomicJsonContention.ps1',
        'Software\Harness\tests\Test-EvidenceSnapshotResilience.ps1',
        'Software\Harness\tests\Test-LiveEvidenceProtocol.ps1',
        'Software\Harness\tests\Test-PoolFaultRecovery.ps1',
        'Software\Harness\tests\Test-HostInputTransportSelection.ps1',
        'Software\Harness\tests\Test-HostInputTokenExpansion.ps1',
        'Software\Harness\tests\Test-HostInputShareSafety.ps1',
        'Software\Harness\tests\Test-HostInputHostIntegration.ps1',
        'Software\Harness\tests\Test-ConfigurationPolicyPreservation.ps1',
        'Software\Harness\tests\Test-RequestNetworkingUpdateContract.ps1',
        'Software\Harness\tests\Test-RequestNetworkPropagation.ps1',
        'Software\Harness\tests\Test-RequestNetworkSafety.ps1',
        'Software\Harness\tests\Test-RunnerContractValidation.ps1',
        'Software\Harness\tests\Test-Utf8ActionTransport.ps1'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $BundleRoot $_) -PathType Leaf) })
    if ($missing.Count -gt 0) { throw ('Required recovery files are missing: ' + ($missing -join ', ')) }
    $recoveryPolicy = [IO.File]::ReadAllBytes((Join-Path $BundleRoot 'Codex\AGENTS.md'))
    $canonicalPolicy = [IO.File]::ReadAllBytes((Join-Path $BundleRoot 'Software\Setup\AGENTS.block.md'))
    if ([Convert]::ToBase64String($recoveryPolicy) -cne [Convert]::ToBase64String($canonicalPolicy)) {
        throw 'The recovery Codex policy is not an exact copy of the canonical managed policy block.'
    }
    $exportedConfig = Join-Path $BundleRoot ([string]$manifest.ExportedVmConfiguration).Replace('/', '\')
    if (-not (Test-Path -LiteralPath $exportedConfig -PathType Leaf)) { throw 'The exported baseline VM configuration is missing.' }

    $parseFailures = New-Object Collections.Generic.List[object]
    foreach ($script in @(Get-ChildItem -LiteralPath (Join-Path $BundleRoot 'Software') -Recurse -File -Filter '*.ps1')) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
        foreach ($error in @($errors)) {
            $parseFailures.Add([pscustomobject]@{ Path = $script.FullName; Line = $error.Extent.StartLineNumber; Message = $error.Message })
        }
    }
    foreach ($scriptName in @('Install-CodexHyperVHarness.ps1', 'RecoveryCommon.ps1', 'Show-CodexHyperVRecoveryResult.ps1')) {
        $script = Join-Path $BundleRoot $scriptName
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        foreach ($error in @($errors)) {
            $parseFailures.Add([pscustomobject]@{ Path = $script; Line = $error.Extent.StartLineNumber; Message = $error.Message })
        }
    }
    if ($parseFailures.Count -gt 0) { throw "Recovery scripts contain $($parseFailures.Count) PowerShell parse error(s)." }

    $credential = Get-Content -LiteralPath (Join-Path $BundleRoot 'Software\Harness\private\guest-credential.json') -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$credential.UserName) -or [string]::IsNullOrWhiteSpace([string]$credential.Password)) {
        throw 'The portable guest credential is incomplete.'
    }

    $result = [ordered]@{
        Success = $true
        Message = 'The one-click recovery bundle passed integrity and structural verification.'
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        BundleId = [string]$manifest.BundleId
        VerifiedFiles = [int]$integrity.VerifiedFiles
        VerifiedBytes = [long]$integrity.VerifiedBytes
        ContentHashesSkipped = [bool]$SkipContentHashes
        ExportedVmConfiguration = [string]$manifest.ExportedVmConfiguration
        ParsedPowerShellFiles = @(Get-ChildItem -LiteralPath (Join-Path $BundleRoot 'Software') -Recurse -File -Filter '*.ps1').Count + 3
    }
    Write-CodexJsonAtomic -Path $StatusPath -Value $result
    [pscustomobject]$result
}
catch {
    $result = [ordered]@{
        Success = $false
        Message = $_.Exception.Message
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        BundleRoot = $BundleRoot
        ScriptStackTrace = $_.ScriptStackTrace
    }
    Write-CodexJsonAtomic -Path $StatusPath -Value $result
    throw
}
