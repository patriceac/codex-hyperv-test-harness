[CmdletBinding()]
param(
    [string] $SourceRoot,
    [string] $BrokerRoot,
    [string] $StatusPath,
    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = [string]$layout.HarnessSourceRoot }
if ([string]::IsNullOrWhiteSpace($BrokerRoot)) { $BrokerRoot = [string]$layout.BrokerRoot }
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-deploy-status.json' }
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Pool deployment must run from an elevated administrator process.'
    }
    & (Join-Path $SourceRoot 'Initialize-HyperVTestPool.ps1') -BrokerRoot $BrokerRoot -DefinitionPath (Join-Path $SourceRoot 'pool-definition.json') -StatusPath (Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-provision-status.json') -ConfigPath $layout.ConfigPath
    & (Join-Path $SourceRoot 'Install-PoolHostBroker.ps1') -SourceRoot $SourceRoot -BrokerRoot $BrokerRoot -PoolDefinitionPath (Join-Path $SourceRoot 'pool-definition.json') -StatusPath (Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-broker-install-status.json') -ConfigPath $layout.ConfigPath
    [ordered]@{
        Success = $true
        Message = 'The Hyper-V pool and SYSTEM broker were deployed.'
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}
catch {
    [ordered]@{
        Success = $false
        Message = $_.Exception.Message
        ScriptStackTrace = $_.ScriptStackTrace
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
    throw
}
