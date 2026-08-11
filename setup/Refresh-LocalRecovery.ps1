[CmdletBinding()]
param(
    [string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness',
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$configPath = Join-Path $InstallRoot 'Software\harness-config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Harness configuration is missing: $configPath" }
. (Join-Path $InstallRoot 'Software\Harness\HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $configPath
& (Join-Path ([string]$layout.SoftwareRoot) 'Recovery\New-CodexHyperVRecovery.ps1') -ConfigPath $configPath -ActiveBrokerRoot ([string]$layout.BrokerRoot) -TargetUserProfile $env:USERPROFILE -NoElevation:$NoElevation
