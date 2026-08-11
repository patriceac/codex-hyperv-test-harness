[CmdletBinding()]
param([string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness')

$config = Get-Content -LiteralPath (Join-Path $InstallRoot 'Software\harness-config.json') -Raw | ConvertFrom-Json
$skillRoot = @(
    (Join-Path $env:USERPROFILE '.agents\skills\hyperv-test-executables'),
    (Join-Path $env:USERPROFILE '.codex\skills\hyperv-test-executables')
) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'SKILL.md') -PathType Leaf } | Select-Object -First 1
if (-not $skillRoot) { throw 'The hyperv-test-executables skill is not installed.' }
$runner = Join-Path $skillRoot 'scripts\Invoke-HyperVExecutableTest.ps1'
& $runner `
    -ArtifactPath (Join-Path ([string]$config.SoftwareRoot) 'Canaries\PoolCanary.exe') `
    -ActionsPath (Join-Path ([string]$config.SoftwareRoot) 'Canaries\smoke-actions.json') `
    -BrokerRoot ([string]$config.BrokerRoot) `
    -QueueTimeoutSeconds 900 `
    -ExecutionTimeoutSeconds 300
