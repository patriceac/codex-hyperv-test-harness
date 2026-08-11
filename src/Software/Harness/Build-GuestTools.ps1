[CmdletBinding()]
param([string] $GuestSourceRoot = (Join-Path $PSScriptRoot 'seed\guest'))

$ErrorActionPreference = 'Stop'
$GuestSourceRoot = [IO.Path]::GetFullPath($GuestSourceRoot)
$source = Join-Path $GuestSourceRoot 'InputProbe.cs'
$output = Join-Path $GuestSourceRoot 'InputProbe.exe'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Guest input-probe source is missing: $source" }
$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) { throw 'The Windows .NET Framework C# compiler was not found.' }
& $compiler /nologo /target:winexe /optimize+ "/out:$output" /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll $source
if ($LASTEXITCODE -ne 0) { throw "InputProbe compilation failed with exit code $LASTEXITCODE" }
[pscustomobject][ordered]@{
    Source = $source; Output = $output; Length = [long](Get-Item -LiteralPath $output).Length
    Sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
}
