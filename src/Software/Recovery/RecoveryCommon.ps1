Set-StrictMode -Version Latest

function Test-CodexAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-CodexPathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Parent,
        [string] $ExpectedLeaf
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $resolvedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if (-not ($resolvedPath + '\').StartsWith($resolvedParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside the intended root: $resolvedPath"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedLeaf) -and
        -not [string]::Equals([IO.Path]::GetFileName($resolvedPath), $ExpectedLeaf, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected path leaf '$([IO.Path]::GetFileName($resolvedPath))'; expected '$ExpectedLeaf'."
    }
    $resolvedPath
}

function Write-CodexJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value,
        [int] $Depth = 30
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $temporary + '.bak'
    try {
        $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $temporary -Encoding UTF8
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                    [IO.File]::Replace($temporary, $Path, $backup, $true)
                }
                else { [IO.File]::Move($temporary, $Path) }
                return
            }
            catch [IO.IOException] { if ($attempt -ge 20) { throw } }
            catch [UnauthorizedAccessException] { if ($attempt -ge 20) { throw } }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CodexRobocopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination,
        [switch] $Mirror,
        [string[]] $ExcludeDirectories = @(),
        [string[]] $ExcludeFiles = @()
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $arguments = @($Source, $Destination, $(if ($Mirror) { '/MIR' } else { '/E' }), '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($ExcludeDirectories.Count -gt 0) { $arguments += '/XD'; $arguments += $ExcludeDirectories }
    if ($ExcludeFiles.Count -gt 0) { $arguments += '/XF'; $arguments += $ExcludeFiles }
    & robocopy.exe @arguments | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) {
        throw "Robocopy failed with exit code $exitCode while copying '$Source' to '$Destination'."
    }
    $exitCode
}

function Get-CodexRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $BasePath,
        [Parameter(Mandatory = $true)] [string] $Path
    )

    $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    $baseUri = New-Object Uri($baseFull)
    $pathUri = New-Object Uri($pathFull)
    [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString())
}

function Get-CodexBundleManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $BundleRoot)

    $manifestPath = Join-Path $BundleRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Recovery manifest is missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([int]$manifest.FormatVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$manifest.BundleId)) {
        throw 'The recovery manifest format is unsupported or incomplete.'
    }
    $manifest
}

function Test-CodexRecoveryBundleIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $BundleRoot,
        [switch] $SkipContentHashes
    )

    $bundle = [IO.Path]::GetFullPath($BundleRoot)
    $manifest = Get-CodexBundleManifest -BundleRoot $bundle
    $failures = New-Object Collections.Generic.List[string]
    $verifiedBytes = [long]0
    $verifiedFiles = 0
    foreach ($entry in @($manifest.Files)) {
        $relative = [string]$entry.RelativePath
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/|\\)\.\.($|/|\\)') {
            $failures.Add("Unsafe manifest path: $relative")
            continue
        }
        $path = [IO.Path]::GetFullPath((Join-Path $bundle $relative))
        try { [void](Assert-CodexPathWithin -Path $path -Parent $bundle) } catch { $failures.Add($_.Exception.Message); continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $failures.Add("Missing file: $relative")
            continue
        }
        $item = Get-Item -LiteralPath $path
        if ([long]$item.Length -ne [long]$entry.Length) {
            $failures.Add("Length mismatch: $relative")
            continue
        }
        if (-not $SkipContentHashes) {
            $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if (-not [string]::Equals($actualHash, [string]$entry.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                $failures.Add("SHA-256 mismatch: $relative")
                continue
            }
        }
        $verifiedFiles++
        $verifiedBytes += [long]$item.Length
    }
    $checksumPath = Join-Path $bundle 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        $failures.Add('checksums.sha256 is missing.')
    }
    elseif (-not $SkipContentHashes) {
        $checksumHash = (Get-FileHash -LiteralPath $checksumPath -Algorithm SHA256).Hash
        if (-not [string]::Equals($checksumHash, [string]$manifest.ChecksumsSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $failures.Add('checksums.sha256 does not match the manifest.')
        }
    }
    [pscustomobject][ordered]@{
        Success = $failures.Count -eq 0
        BundleId = [string]$manifest.BundleId
        VerifiedFiles = $verifiedFiles
        VerifiedBytes = $verifiedBytes
        ContentHashesSkipped = [bool]$SkipContentHashes
        Failures = $failures.ToArray()
        Manifest = $manifest
    }
}

function Get-CodexExportedVmConfigurationPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $ExportRoot)

    $configs = @(Get-ChildItem -LiteralPath $ExportRoot -Recurse -File -Filter '*.vmcx' -ErrorAction SilentlyContinue)
    $activeConfigs = @($configs | Where-Object { [string]::Equals($_.Directory.Name, 'Virtual Machines', [StringComparison]::OrdinalIgnoreCase) })
    if ($activeConfigs.Count -ne 1) {
        throw "Expected exactly one active exported VM configuration under '$ExportRoot'; found $($activeConfigs.Count) active and $($configs.Count) total."
    }
    $activeConfigs[0].FullName
}

function Set-CodexPrivateFileAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Path)

    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to protect private file ACL: $Path" }
}

function Start-CodexRecoveryAwake {
    if (-not ('CodexHyperVRecoveryPower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexHyperVRecoveryPower
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SetThreadExecutionState(uint flags);
    public static bool PreventSystemSleep() { return SetThreadExecutionState(0x80000001) != 0; }
    public static void RestoreDefault() { SetThreadExecutionState(0x80000000); }
}
'@
    }
    if (-not [CodexHyperVRecoveryPower]::PreventSystemSleep()) {
        throw 'Windows rejected the temporary recovery sleep-inhibition request.'
    }
}

function Stop-CodexRecoveryAwake {
    if ('CodexHyperVRecoveryPower' -as [type]) { [CodexHyperVRecoveryPower]::RestoreDefault() }
}
