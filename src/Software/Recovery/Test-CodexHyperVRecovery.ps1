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

function Assert-RecoveryVerifierNoAlternateDataStream {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "Recovery path has no filesystem root: $Path" }
    if ($full.Substring($root.Length) -match ':') { throw "Recovery paths cannot contain alternate data streams: $Path" }
    if (-not (Test-Path -LiteralPath $full)) { return }
    try {
        foreach ($stream in @(Get-Item -LiteralPath $full -Stream * -ErrorAction Stop)) {
            if ([string]$stream.Stream -notin @('', '::$DATA', ':$DATA', '$DATA')) {
                throw "Recovery paths cannot contain alternate data streams: ${full}:$($stream.Stream)"
            }
        }
    }
    catch [ParameterBindingException] { }
    catch [NotSupportedException] { }
}

function Assert-RecoveryVerifierNoReparseChain {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [switch] $RequireExisting
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "Recovery path has no filesystem root: $Path" }
    if ($full.Substring($root.Length) -match ':') { throw "Recovery paths cannot contain alternate data streams: $Path" }
    $existing = New-Object Collections.Generic.List[object]
    $probe = New-Object IO.DirectoryInfo($full)
    while ($null -ne $probe) {
        if (Test-Path -LiteralPath $probe.FullName) { [void]$existing.Add((Get-Item -LiteralPath $probe.FullName -Force -ErrorAction Stop)) }
        $probe = $probe.Parent
    }
    if ($RequireExisting -and -not (Test-Path -LiteralPath $full)) { throw "Recovery path is missing: $full" }
    foreach ($item in $existing) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Recovery path crosses a reparse point: $($item.FullName)" }
        Assert-RecoveryVerifierNoAlternateDataStream -Path $item.FullName
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
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '^(?:[\/]{1,2}|[A-Za-z]:|\\[?.])' -or $relative -match '(^|\\)(?:\.\.?)(?:\\|$)' -or $relative -match ':') {
        throw "Recovery manifest field '$FieldName' is not a safe relative path: $RelativePath"
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $relative)).TrimEnd('\')
    if ([string]::Equals($candidate, $rootFull, [StringComparison]::OrdinalIgnoreCase) -or -not (($candidate + '\').StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase))) {
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
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Recovery manifest field '$FieldName' crosses a reparse point: $RelativePath" }
        Assert-RecoveryVerifierNoAlternateDataStream -Path $current
        if ($index -lt ($parts.Count - 1) -and -not $item.PSIsContainer) { throw "Recovery manifest field '$FieldName' crosses a file boundary: $RelativePath" }
    }
    if ($RequireLeaf -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Recovery manifest field '$FieldName' is not a file: $RelativePath" }
    $candidate
}

function Read-RecoveryManifestSafely {
    param([Parameter(Mandatory = $true)] [string] $Root)
    $manifestPath = Resolve-RecoveryManifestPath -Root $Root -RelativePath 'manifest.json' -FieldName 'manifest.json' -RequireLeaf
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([int]$manifest.FormatVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$manifest.BundleId)) { throw 'The recovery manifest format is unsupported or incomplete.' }
    foreach ($entry in @($manifest.Files)) { [void](Resolve-RecoveryManifestPath -Root $Root -RelativePath ([string]$entry.RelativePath) -FieldName 'Files[].RelativePath' -RequireLeaf) }
    [void](Resolve-RecoveryManifestPath -Root $Root -RelativePath ([string]$manifest.ConfigRelativePath) -FieldName 'ConfigRelativePath' -RequireLeaf)
    [void](Resolve-RecoveryManifestPath -Root $Root -RelativePath ([string]$manifest.ExportedVmConfiguration) -FieldName 'ExportedVmConfiguration' -RequireLeaf)
    $manifest
}

$BundleRoot = Assert-RecoveryVerifierNoReparseChain -Path $BundleRoot -RequireExisting
$bundleRootItem = Get-Item -LiteralPath $BundleRoot -Force -ErrorAction Stop
if (-not $bundleRootItem.PSIsContainer -or ($bundleRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Recovery BundleRoot must be a non-reparse directory: $BundleRoot" }
$validatedManifest = Read-RecoveryManifestSafely -Root $BundleRoot
. (Join-Path $PSScriptRoot 'RecoveryCommon.ps1')
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
    foreach ($entry in @($manifest.Files)) {
        [void](Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath ([string]$entry.RelativePath) -FieldName 'Files[].RelativePath' -RequireLeaf)
    }
    [void](Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath ([string]$manifest.ConfigRelativePath) -FieldName 'ConfigRelativePath' -RequireLeaf)
    [void](Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath ([string]$manifest.ExportedVmConfiguration) -FieldName 'ExportedVmConfiguration' -RequireLeaf)
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
        'Software\Harness\HostBroker.ps1',
        'Software\Harness\HostInputShare.ps1',
        'Software\Harness\RequestNetwork.ps1',
        'Software\Harness\Initialize-HyperVTestPool.ps1',
        'Software\Harness\Install-PoolHostBroker.ps1',
        'Software\Harness\private\guest-credential.json',
        'Software\Skill\SKILL.md',
        'Software\UserIntegration\Install-CodexUserIntegration.ps1',
        'Software\Skill\scripts\Invoke-HyperVExecutableTest.ps1',
        'Software\Canaries\PoolCanary.exe',
        'Software\Canaries\DetachedLockCanary.exe',
        'Software\Canaries\detached-lock-actions.json',
        'Software\Canaries\HostInputCanary.cs',
        'Software\Canaries\HostInputCanary.exe',
        'Software\Canaries\host-input-actions.json',
        'Software\Harness\tests\Test-AtomicJsonContention.ps1',
        'Software\Harness\tests\Test-EvidenceSnapshotResilience.ps1',
        'Software\Harness\tests\Test-PoolFaultRecovery.ps1',
        'Software\Harness\tests\Test-HostInputTransportSelection.ps1',
        'Software\Harness\tests\Test-HostInputTokenExpansion.ps1',
        'Software\Harness\tests\Test-HostInputShareSafety.ps1',
        'Software\Harness\tests\Test-HostInputHostIntegration.ps1',
        'Software\Harness\tests\Test-RequestNetworkPropagation.ps1',
        'Software\Harness\tests\Test-RequestNetworkSafety.ps1',
        'Software\Harness\tests\Test-InstallRuntimeSkillTransaction.ps1',
        'Software\Harness\tests\Test-RunnerContractValidation.ps1',
        'Software\Recovery\Test-RecoveryInstallContract.ps1'
    )
    $missing = @($required | Where-Object {
            try { [void](Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath $_ -FieldName "required:$($_)" -RequireLeaf); $false }
            catch { $true }
        })
    if ($missing.Count -gt 0) { throw ('Required recovery files are missing: ' + ($missing -join ', ')) }
    $exportedConfig = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath ([string]$manifest.ExportedVmConfiguration) -FieldName 'ExportedVmConfiguration' -RequireLeaf
    $softwareBundleRoot = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'Software' -FieldName 'Software source root'

    $parseFailures = New-Object Collections.Generic.List[object]
    foreach ($script in @(Get-ChildItem -LiteralPath $softwareBundleRoot -Recurse -File -Filter '*.ps1')) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
        foreach ($error in @($errors)) {
            $parseFailures.Add([pscustomobject]@{ Path = $script.FullName; Line = $error.Extent.StartLineNumber; Message = $error.Message })
        }
    }
    foreach ($scriptName in @('Install-CodexHyperVHarness.ps1', 'RecoveryCommon.ps1', 'Show-CodexHyperVRecoveryResult.ps1')) {
        $script = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath $scriptName -FieldName "recovery-script:$scriptName" -RequireLeaf
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        foreach ($error in @($errors)) {
            $parseFailures.Add([pscustomobject]@{ Path = $script; Line = $error.Extent.StartLineNumber; Message = $error.Message })
        }
    }
    if ($parseFailures.Count -gt 0) { throw "Recovery scripts contain $($parseFailures.Count) PowerShell parse error(s)." }

    $credentialPath = Resolve-RecoveryManifestPath -Root $BundleRoot -RelativePath 'Software\Harness\private\guest-credential.json' -FieldName 'guest credential' -RequireLeaf
    $credential = Get-Content -LiteralPath $credentialPath -Raw | ConvertFrom-Json
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
        ParsedPowerShellFiles = @(Get-ChildItem -LiteralPath $softwareBundleRoot -Recurse -File -Filter '*.ps1').Count + 3
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
