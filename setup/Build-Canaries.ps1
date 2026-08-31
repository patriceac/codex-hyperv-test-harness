[CmdletBinding()]
param(
    [string] $CanaryRoot
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($CanaryRoot)) {
    # Resolve the script-relative default after parameter binding.  Windows
    # PowerShell 5.1 evaluates default expressions before $PSScriptRoot is
    # available for this script invocation.
    $CanaryRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Software\Canaries'
}
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
    @{ Source = 'HostInputCanary.cs'; Output = 'HostInputCanary.exe' },
    @{ Source = 'NetworkBoundaryCanary.cs'; Output = 'NetworkBoundaryCanary.exe' },
    @{ Source = 'LiveEvidenceCanary.cs'; Output = 'LiveEvidenceCanary.exe' },
    @{ Source = 'ShutdownProbe.cs'; Output = 'ShutdownProbe.exe' }
)

$lock = $null
try {
    # The canary outputs are canonical files consumed by the installer and
    # source tests.  Serialize writers across PowerShell 5.1/7 processes so
    # parallel source-suite runs cannot make csc.exe race on the same .exe.
    $lockRoot = Join-Path ([IO.Path]::GetTempPath()) 'CodexHyperVHarness'
    New-Item -ItemType Directory -Force -Path $lockRoot | Out-Null
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $lockKey = -join ($hashAlgorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($CanaryRoot.ToUpperInvariant())) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $hashAlgorithm.Dispose()
    }
    $lockPath = Join-Path $lockRoot ('Build-Canaries-' + $lockKey + '.lock')
    $waitedMilliseconds = 0
    while ($null -eq $lock) {
        try {
            $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ($waitedMilliseconds -ge 120000) { throw "Timed out waiting for the canary build lock: $lockPath" }
            Start-Sleep -Milliseconds 100
            $waitedMilliseconds += 100
        }
    }

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
}
finally {
    if ($null -ne $lock) { $lock.Dispose() }
}

$built
