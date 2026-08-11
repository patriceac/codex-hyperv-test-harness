[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SourceDirectory,
    [Parameter(Mandatory = $true)] [string] $DestinationIso,
    [ValidatePattern('^[A-Z0-9_]{1,32}$')] [string] $VolumeName = 'CODEXSEED'
)

$ErrorActionPreference = 'Stop'
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
$DestinationIso = [IO.Path]::GetFullPath($DestinationIso)
if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) { throw "ISO source directory is missing: $SourceDirectory" }
if ([IO.Path]::GetPathRoot($DestinationIso) -eq $DestinationIso) { throw 'DestinationIso must be a file path, not a filesystem root.' }

$parent = Split-Path -Parent $DestinationIso
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$temporaryIso = $DestinationIso + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
if (-not ('CodexImapiStreamWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class CodexImapiStreamWriter
{
    public static void Write(object source, string destination)
    {
        IntPtr unknown = Marshal.GetIUnknownForObject(source);
        try
        {
            IStream input = (IStream)Marshal.GetTypedObjectForIUnknown(unknown, typeof(IStream));
            byte[] buffer = new byte[1024 * 1024];
            IntPtr readPointer = Marshal.AllocHGlobal(sizeof(int));
            try
            {
                using (FileStream output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    while (true)
                    {
                        Marshal.WriteInt32(readPointer, 0);
                        input.Read(buffer, buffer.Length, readPointer);
                        int count = Marshal.ReadInt32(readPointer);
                        if (count <= 0) break;
                        output.Write(buffer, 0, count);
                    }
                    output.Flush(true);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(readPointer);
            }
        }
        finally
        {
            Marshal.Release(unknown);
        }
    }
}
'@
}

try {
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3 # ISO 9660 and Joliet; both are readable by Windows Setup.
    $image.VolumeName = $VolumeName
    $image.Root.AddTree($SourceDirectory, $false)
    $result = $image.CreateResultImage()
    [CodexImapiStreamWriter]::Write($result.ImageStream, $temporaryIso)
    Move-Item -LiteralPath $temporaryIso -Destination $DestinationIso -Force
    Get-Item -LiteralPath $DestinationIso
}
finally {
    Remove-Item -LiteralPath $temporaryIso -Force -ErrorAction SilentlyContinue
}
