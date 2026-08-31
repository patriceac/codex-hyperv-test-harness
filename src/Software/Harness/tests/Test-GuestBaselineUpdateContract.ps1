[CmdletBinding()]
param([string] $HarnessRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($HarnessRoot)) { $HarnessRoot = Split-Path -Parent $PSScriptRoot }
$updateText = Get-Content -Raw -LiteralPath (Join-Path $HarnessRoot 'Update-GuestHarnessBaseline.ps1')
$initializeCallIndex = $updateText.LastIndexOf("Initialize-HyperVTestPool.ps1", [StringComparison]::Ordinal)
$installBrokerCallIndex = $updateText.LastIndexOf("Install-PoolHostBroker.ps1", [StringComparison]::Ordinal)
if ($initializeCallIndex -lt 0 -or $installBrokerCallIndex -le $initializeCallIndex) {
    throw 'The guest baseline update omits its pool or broker deployment call.'
}
$initializeCall = $updateText.Substring($initializeCallIndex, $installBrokerCallIndex - $initializeCallIndex)
$installBrokerCall = $updateText.Substring($installBrokerCallIndex)
if ($initializeCall -notlike '*-ConfigPath $ConfigPath*') {
    throw 'The guest baseline update does not pass the explicit configuration to pool initialization.'
}
if ($installBrokerCall -notlike '*-ConfigPath $ConfigPath*') {
    throw 'The guest baseline update does not pass the explicit configuration to broker installation.'
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = 2
    Scenarios = @('pool-config-path-propagated', 'broker-config-path-propagated')
} | ConvertTo-Json -Depth 4
