[CmdletBinding()]
param(
    [string] $CanaryRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Software\Canaries')
)

$ErrorActionPreference = 'Stop'
$CanaryRoot = [IO.Path]::GetFullPath($CanaryRoot)
if (-not (Test-Path -LiteralPath $CanaryRoot -PathType Container)) { throw "Canary source directory is missing: $CanaryRoot" }

$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) { throw 'The Windows .NET Framework C# compiler was not found.' }

$targets = @(
    @{ Source = 'PoolCanary.cs'; Output = 'PoolCanary.exe' },
    @{ Source = 'DetachedLockCanary.cs'; Output = 'DetachedLockCanary.exe' },
    @{ Source = 'HarnessContractCanary.cs'; Output = 'HarnessContractCanary.exe' },
    @{ Source = 'HostInputCanary.cs'; Output = 'HostInputCanary.exe' }
)

$built = foreach ($target in $targets) {
    $source = Join-Path $CanaryRoot $target.Source
    $output = Join-Path $CanaryRoot $target.Output
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Canary source is missing: $source" }
    & $compiler /nologo /target:winexe /optimize+ "/out:$output" /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll $source
    if ($LASTEXITCODE -ne 0) { throw "Canary compilation failed for $($target.Source) with exit code $LASTEXITCODE." }
    $file = Get-Item -LiteralPath $output
    [pscustomobject][ordered]@{
        Source = $source
        Output = $output
        Length = [long]$file.Length
        Sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
    }
}

$built
