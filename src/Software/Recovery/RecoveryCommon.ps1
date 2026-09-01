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

function Initialize-CodexRecoveryFileIdentityType {
    if ('CodexHyperVRecoveryFileIdentity' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class CodexHyperVRecoveryFileIdentity
{
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    public sealed class Identity
    {
        public string Value { get; set; }
        public uint LinkCount { get; set; }
        public long Length { get; set; }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLinkW(
        string newFileName,
        string existingFileName,
        IntPtr securityAttributes);

    private static string NormalizePath(string path)
    {
        string full = Path.GetFullPath(path);
        if (full.StartsWith(@"\\?\", StringComparison.Ordinal)) { return full; }
        if (full.StartsWith(@"\\", StringComparison.Ordinal)) { return @"\\?\UNC\" + full.Substring(2); }
        return @"\\?\" + full;
    }

    public static Identity GetIdentity(string path)
    {
        using (SafeFileHandle handle = CreateFileW(
            NormalizePath(path),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            IntPtr.Zero))
        {
            if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return new Identity {
                Value = information.VolumeSerialNumber.ToString("X8") + ":" +
                    information.FileIndexHigh.ToString("X8") + information.FileIndexLow.ToString("X8"),
                LinkCount = information.NumberOfLinks,
                Length = ((long)information.FileSizeHigh << 32) | information.FileSizeLow
            };
        }
    }

    public static void CreateHardLink(string newFileName, string existingFileName)
    {
        if (!CreateHardLinkW(NormalizePath(newFileName), NormalizePath(existingFileName), IntPtr.Zero)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
}

function Get-CodexFileIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "File identity input is missing: $resolved" }
    Initialize-CodexRecoveryFileIdentityType
    $identity = [CodexHyperVRecoveryFileIdentity]::GetIdentity($resolved)
    [pscustomobject][ordered]@{
        Path = $resolved
        Value = [string]$identity.Value
        LinkCount = [uint32]$identity.LinkCount
        Length = [long]$identity.Length
    }
}

function New-CodexRecoveryHardLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $DestinationPath
    )

    $source = [IO.Path]::GetFullPath($SourcePath)
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Hard-link source is missing: $source" }
    if (Test-Path -LiteralPath $destination) { throw "Hard-link destination already exists: $destination" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Initialize-CodexRecoveryFileIdentityType
    try {
        [CodexHyperVRecoveryFileIdentity]::CreateHardLink($destination, $source)
        $sourceIdentity = Get-CodexFileIdentity -Path $source
        $destinationIdentity = Get-CodexFileIdentity -Path $destination
        if (-not [string]::Equals($sourceIdentity.Value, $destinationIdentity.Value, [StringComparison]::Ordinal) -or
            [long]$sourceIdentity.Length -ne [long]$destinationIdentity.Length) {
            throw 'Windows created a destination that does not share the source file identity.'
        }
        [pscustomobject][ordered]@{
            SourcePath = $source
            DestinationPath = $destination
            FileIdentity = [string]$sourceIdentity.Value
            Length = [long]$sourceIdentity.Length
            LinkCount = [uint32]$destinationIdentity.LinkCount
        }
    }
    catch {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-CodexRecoveryManifestFileMap {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Manifest)

    $map = @{}
    foreach ($entry in @($Manifest.Files)) {
        $relative = ([string]$entry.RelativePath).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.($|/)') {
            throw "Unsafe recovery manifest path: $relative"
        }
        if ([long]$entry.Length -lt 0 -or [string]$entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Invalid recovery manifest length or SHA-256: $relative"
        }
        if ($map.ContainsKey($relative)) { throw "Duplicate recovery manifest path: $relative" }
        $map[$relative] = $entry
    }
    $map
}

function Copy-CodexRecoveryFileIncremental {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $DestinationBundleRoot,
        [Parameter(Mandatory = $true)] [string] $RelativePath,
        [string] $PriorBundleRoot,
        [hashtable] $PriorFileMap
    )

    $source = [IO.Path]::GetFullPath($SourcePath)
    $bundle = [IO.Path]::GetFullPath($DestinationBundleRoot).TrimEnd('\')
    $relative = $RelativePath.Replace('\', '/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.($|/)') {
        throw "Unsafe incremental recovery path: $relative"
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Incremental recovery source is missing: $source" }
    $destination = Assert-CodexPathWithin -Path (Join-Path $bundle $relative) -Parent $bundle
    if (Test-Path -LiteralPath $destination) { throw "Incremental recovery destination already exists: $destination" }

    $sourceItem = Get-Item -LiteralPath $source
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $reused = $false
    $reuseFailure = $null
    if (-not [string]::IsNullOrWhiteSpace($PriorBundleRoot) -and $null -ne $PriorFileMap -and $PriorFileMap.ContainsKey($relative)) {
        $priorEntry = $PriorFileMap[$relative]
        $priorRoot = [IO.Path]::GetFullPath($PriorBundleRoot).TrimEnd('\')
        $priorPath = Assert-CodexPathWithin -Path (Join-Path $priorRoot $relative) -Parent $priorRoot
        if ([long]$priorEntry.Length -eq [long]$sourceItem.Length -and
            [string]::Equals([string]$priorEntry.Sha256, $sourceHash, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $priorPath -PathType Leaf)) {
            $priorItem = Get-Item -LiteralPath $priorPath
            if ([long]$priorItem.Length -eq [long]$sourceItem.Length) {
                $priorHash = (Get-FileHash -LiteralPath $priorPath -Algorithm SHA256).Hash
                if ([string]::Equals($priorHash, $sourceHash, [StringComparison]::OrdinalIgnoreCase)) {
                    try {
                        [void](New-CodexRecoveryHardLink -SourcePath $priorPath -DestinationPath $destination)
                        $reused = $true
                    }
                    catch { $reuseFailure = $_.Exception.Message }
                }
            }
        }
    }

    if (-not $reused) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if (-not [string]::Equals($destinationHash, $sourceHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Incremental recovery copy changed content: $relative"
        }
    }

    [pscustomobject][ordered]@{
        RelativePath = $relative
        Length = [long]$sourceItem.Length
        Sha256 = $sourceHash
        ReusedByHardLink = $reused
        ReuseFailure = $reuseFailure
    }
}

function Copy-CodexRecoveryTreeIncremental {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $SourceRoot,
        [Parameter(Mandatory = $true)] [string] $DestinationBundleRoot,
        [Parameter(Mandatory = $true)] [string] $BundlePrefix,
        [string] $PriorBundleRoot,
        [hashtable] $PriorFileMap
    )

    $source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Incremental recovery tree source is missing: $source" }
    $items = @(Get-ChildItem -LiteralPath $source -Recurse -Force)
    $reparsePoints = @($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparsePoints.Count -gt 0) {
        throw "Incremental recovery refuses reparse points under '$source': $($reparsePoints[0].FullName)"
    }

    $prefix = $BundlePrefix.Replace('\', '/').Trim('/')
    $results = New-Object Collections.Generic.List[object]
    foreach ($directory in @($items | Where-Object PSIsContainer | Sort-Object FullName)) {
        $within = Get-CodexRelativePath -BasePath $source -Path $directory.FullName
        $relative = if ([string]::IsNullOrWhiteSpace($prefix)) { $within } else { $prefix + '/' + $within }
        $destination = Assert-CodexPathWithin -Path (Join-Path $DestinationBundleRoot $relative) -Parent $DestinationBundleRoot
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
    }
    foreach ($file in @($items | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)) {
        $within = Get-CodexRelativePath -BasePath $source -Path $file.FullName
        $relative = if ([string]::IsNullOrWhiteSpace($prefix)) { $within } else { $prefix + '/' + $within }
        $results.Add((Copy-CodexRecoveryFileIncremental -SourcePath $file.FullName -DestinationBundleRoot $DestinationBundleRoot -RelativePath $relative -PriorBundleRoot $PriorBundleRoot -PriorFileMap $PriorFileMap))
    }
    $results.ToArray()
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
        [switch] $SkipContentHashes,
        [string] $TrustedBundleRoot,
        [string[]] $TrustedRelativePaths = @()
    )

    $bundle = [IO.Path]::GetFullPath($BundleRoot)
    $manifest = Get-CodexBundleManifest -BundleRoot $bundle
    $failures = New-Object Collections.Generic.List[string]
    $verifiedBytes = [long]0
    $verifiedFiles = 0
    $hashedBytes = [long]0
    $hashedFiles = 0
    $trustedIdentityBytes = [long]0
    $trustedIdentityFiles = 0
    try { $manifestMap = Get-CodexRecoveryManifestFileMap -Manifest $manifest } catch { $failures.Add($_.Exception.Message); $manifestMap = @{} }
    $trustedRoot = $null
    $trustedMap = @{}
    $trustedSet = @{}
    if (-not [string]::IsNullOrWhiteSpace($TrustedBundleRoot)) {
        if ($SkipContentHashes) { throw 'Trusted hard-link verification cannot be combined with SkipContentHashes.' }
        $trustedRoot = [IO.Path]::GetFullPath($TrustedBundleRoot)
        $trustedManifest = Get-CodexBundleManifest -BundleRoot $trustedRoot
        $trustedMap = Get-CodexRecoveryManifestFileMap -Manifest $trustedManifest
        foreach ($trustedRelativePath in @($TrustedRelativePaths)) {
            $trustedRelative = ([string]$trustedRelativePath).Replace('\', '/')
            if (-not $trustedMap.ContainsKey($trustedRelative)) { throw "Trusted manifest path is missing: $trustedRelative" }
            if ($trustedSet.ContainsKey($trustedRelative)) { throw "Duplicate trusted manifest path: $trustedRelative" }
            $trustedSet[$trustedRelative] = $true
        }
    }
    elseif (@($TrustedRelativePaths).Count -gt 0) {
        throw 'TrustedRelativePaths requires TrustedBundleRoot.'
    }

    $manifestFileCount = @($manifest.Files).Count
    if ([int]$manifest.FileCount -ne $manifestFileCount) { $failures.Add('Manifest FileCount does not match Files.') }
    $manifestTotalBytes = [long](($manifest.Files | Measure-Object -Property Length -Sum).Sum)
    if ([long]$manifest.TotalBytes -ne $manifestTotalBytes) { $failures.Add('Manifest TotalBytes does not match Files.') }

    foreach ($entry in @($manifest.Files)) {
        $relative = ([string]$entry.RelativePath).Replace('\', '/')
        if (-not $manifestMap.ContainsKey($relative)) { continue }
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
        if ($null -ne $trustedRoot -and $trustedSet.ContainsKey($relative)) {
            $trustedEntry = $trustedMap[$relative]
            if ([long]$trustedEntry.Length -ne [long]$entry.Length -or
                -not [string]::Equals([string]$trustedEntry.Sha256, [string]$entry.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                $failures.Add("Trusted manifest mismatch: $relative")
                continue
            }
            $trustedPath = [IO.Path]::GetFullPath((Join-Path $trustedRoot $relative))
            try { [void](Assert-CodexPathWithin -Path $trustedPath -Parent $trustedRoot) } catch { $failures.Add($_.Exception.Message); continue }
            if (-not (Test-Path -LiteralPath $trustedPath -PathType Leaf)) {
                $failures.Add("Trusted file is missing: $relative")
                continue
            }
            try {
                $identity = Get-CodexFileIdentity -Path $path
                $trustedIdentity = Get-CodexFileIdentity -Path $trustedPath
                if (-not [string]::Equals($identity.Value, $trustedIdentity.Value, [StringComparison]::Ordinal) -or
                    [long]$trustedIdentity.Length -ne [long]$entry.Length) {
                    $failures.Add("Trusted hard-link identity mismatch: $relative")
                    continue
                }
            }
            catch {
                $failures.Add("Trusted hard-link identity failed for ${relative}: $($_.Exception.Message)")
                continue
            }
            $trustedIdentityFiles++
            $trustedIdentityBytes += [long]$item.Length
        }
        elseif (-not $SkipContentHashes) {
            $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if (-not [string]::Equals($actualHash, [string]$entry.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                $failures.Add("SHA-256 mismatch: $relative")
                continue
            }
            $hashedFiles++
            $hashedBytes += [long]$item.Length
        }
        $verifiedFiles++
        $verifiedBytes += [long]$item.Length
    }
    $checksumPath = Join-Path $bundle 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        $failures.Add('checksums.sha256 is missing.')
    }
    else {
        $checksumHash = (Get-FileHash -LiteralPath $checksumPath -Algorithm SHA256).Hash
        if (-not [string]::Equals($checksumHash, [string]$manifest.ChecksumsSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $failures.Add('checksums.sha256 does not match the manifest.')
        }
        $checksumLines = @(Get-Content -LiteralPath $checksumPath)
        $expectedChecksumLines = @($manifest.Files | ForEach-Object { "$([string]$_.Sha256) *$(([string]$_.RelativePath).Replace('\', '/'))" })
        if ($checksumLines.Count -ne $expectedChecksumLines.Count) {
            $failures.Add('checksums.sha256 does not contain exactly one line per manifest file.')
        }
        else {
            for ($index = 0; $index -lt $checksumLines.Count; $index++) {
                if (-not [string]::Equals([string]$checksumLines[$index], [string]$expectedChecksumLines[$index], [StringComparison]::OrdinalIgnoreCase)) {
                    $failures.Add("checksums.sha256 entry mismatch at line $($index + 1).")
                    break
                }
            }
        }
    }
    [pscustomobject][ordered]@{
        Success = $failures.Count -eq 0
        BundleId = [string]$manifest.BundleId
        VerifiedFiles = $verifiedFiles
        VerifiedBytes = $verifiedBytes
        ContentHashesSkipped = [bool]$SkipContentHashes
        HashedFiles = $hashedFiles
        HashedBytes = $hashedBytes
        TrustedIdentityFiles = $trustedIdentityFiles
        TrustedIdentityBytes = $trustedIdentityBytes
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
