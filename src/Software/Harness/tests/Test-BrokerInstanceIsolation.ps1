[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $Action,
        [Parameter(Mandatory = $true)] [string] $Message
    )

    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}

function Get-FunctionScript {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "$Path has a PowerShell parse error."
    $functions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true))
    Assert-True ($functions.Count -eq 1) "$Path must contain exactly one $Name function."
    [scriptblock]::Create($functions[0].Extent.Text)
}

function Write-TestConfig {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [AllowNull()] [object] $BrokerInstanceId
    )

    $privateRoot = Join-Path $BrokerRoot 'Private'
    New-Item -ItemType Directory -Force -Path $privateRoot | Out-Null
    $config = [ordered]@{ FormatVersion = 1 }
    if ($PSBoundParameters.ContainsKey('BrokerInstanceId')) { $config.BrokerInstanceId = $BrokerInstanceId }
    $config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $privateRoot 'config.json') -Encoding UTF8
}

$harnessRoot = Split-Path -Parent $PSScriptRoot
$hostBrokerPath = Join-Path $harnessRoot 'HostBroker.ps1'
$poolCommonPath = Join-Path $harnessRoot 'PoolCommon.ps1'
$installerPath = Join-Path $harnessRoot 'Install-PoolHostBroker.ps1'
$hostBrokerText = Get-Content -Raw -LiteralPath $hostBrokerPath
$poolCommonText = Get-Content -Raw -LiteralPath $poolCommonPath
$installerText = Get-Content -Raw -LiteralPath $installerPath
$scenarios = New-Object Collections.Generic.List[string]

. (Get-FunctionScript -Path $hostBrokerPath -Name 'Get-ValidatedBrokerInstanceId')
. (Get-FunctionScript -Path $hostBrokerPath -Name 'Get-BrokerMutexName')
. (Get-FunctionScript -Path $poolCommonPath -Name 'Get-PoolBrokerInstanceId')
. (Get-FunctionScript -Path $poolCommonPath -Name 'Get-PoolWorkerMutexName')
. (Get-FunctionScript -Path $installerPath -Name 'Get-OptionalBrokerInstanceId')

$emptyConfig = [pscustomobject]@{ FormatVersion = 1 }
Assert-True ((Get-BrokerMutexName -Config $emptyConfig) -ceq 'Global\CodexHyperVBroker') 'A config without BrokerInstanceId must retain the legacy broker mutex name.'
Assert-True ((Get-PoolWorkerMutexName -WorkerId 1) -ceq 'Global\CodexHyperVPoolWorker-01') 'A worker lock without BrokerRoot must retain the legacy mutex name.'
Assert-True ((Get-OptionalBrokerInstanceId -Layout $emptyConfig) -eq $null) 'A layout without BrokerInstanceId must remain optional.'
$scenarios.Add('legacy-mutex-names-remain-default')

$hostAlpha = [pscustomobject]@{ BrokerInstanceId = 'dedicated-alpha_01' }
$hostBeta = [pscustomobject]@{ BrokerInstanceId = 'dedicated-beta-02' }
$hostAlphaName = Get-BrokerMutexName -Config $hostAlpha
$hostBetaName = Get-BrokerMutexName -Config $hostBeta
Assert-True ($hostAlphaName -ceq 'Global\CodexHyperVBroker-dedicated-alpha_01') 'The broker mutex must include the validated instance ID.'
Assert-True ($hostAlphaName -cne $hostBetaName) 'Independent broker instance IDs must produce different broker mutexes.'
Assert-True ((Get-ValidatedBrokerInstanceId -Config $hostAlpha) -ceq 'dedicated-alpha_01') 'The broker validator returned the wrong instance ID.'
Assert-True ((Get-OptionalBrokerInstanceId -Layout $hostBeta) -ceq 'dedicated-beta-02') 'The installer must return the validated layout instance ID.'
$scenarios.Add('independent-broker-instance-names')

foreach ($invalid in @('', ' ', '-leading', 'with.dot', 'with space', 'with\slash', ('a' * 65), 42, $null)) {
    $invalidConfig = [pscustomobject]@{ BrokerInstanceId = $invalid }
    Assert-Throws { Get-BrokerMutexName -Config $invalidConfig } "Invalid BrokerInstanceId '$invalid' was accepted by the broker mutex validator."
    Assert-Throws { Get-OptionalBrokerInstanceId -Layout $invalidConfig } "Invalid BrokerInstanceId '$invalid' was accepted by the installer validator."
}
$scenarios.Add('invalid-instance-ids-fail-closed')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-broker-instance-' + [Guid]::NewGuid().ToString('N'))
try {
    $defaultRoot = Join-Path $testRoot 'default'
    $alphaRoot = Join-Path $testRoot 'alpha'
    $betaRoot = Join-Path $testRoot 'beta'
    Write-TestConfig -BrokerRoot $defaultRoot
    Write-TestConfig -BrokerRoot $alphaRoot -BrokerInstanceId 'dedicated-alpha'
    Write-TestConfig -BrokerRoot $betaRoot -BrokerInstanceId 'dedicated-beta'
    Assert-True ((Get-PoolWorkerMutexName -BrokerRoot $defaultRoot -WorkerId 2) -ceq 'Global\CodexHyperVPoolWorker-02') 'A protected config without BrokerInstanceId must retain the legacy worker mutex name.'
    $alphaWorkerName = Get-PoolWorkerMutexName -BrokerRoot $alphaRoot -WorkerId 2
    $betaWorkerName = Get-PoolWorkerMutexName -BrokerRoot $betaRoot -WorkerId 2
    Assert-True ($alphaWorkerName -ceq 'Global\CodexHyperVPoolWorker-02-dedicated-alpha') 'The worker state mutex must include its protected instance ID.'
    Assert-True ($alphaWorkerName -cne $betaWorkerName) 'Independent broker roots must not share scoped worker state mutexes.'
    $invalidRoot = Join-Path $testRoot 'invalid'
    Write-TestConfig -BrokerRoot $invalidRoot -BrokerInstanceId 'bad.instance'
    Assert-Throws { Get-PoolWorkerMutexName -BrokerRoot $invalidRoot -WorkerId 2 } 'The worker state lock accepted an invalid protected instance ID.'
    $malformedRoot = Join-Path $testRoot 'malformed'
    $malformedPrivateRoot = Join-Path $malformedRoot 'Private'
    New-Item -ItemType Directory -Force -Path $malformedPrivateRoot | Out-Null
    '{' | Set-Content -LiteralPath (Join-Path $malformedPrivateRoot 'config.json') -Encoding UTF8
    Assert-Throws { Get-PoolWorkerMutexName -BrokerRoot $malformedRoot -WorkerId 2 } 'A malformed protected config must fail before taking a legacy worker state lock.'
    $scenarios.Add('worker-state-locks-follow-broker-root-config')
    $scenarios.Add('malformed-protected-config-fails-closed')
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Assert-True ($installerText.Contains("Get-OptionalBrokerInstanceId -Layout `$layout")) 'The installer does not validate the optional layout BrokerInstanceId.'
Assert-True ($installerText.Contains("`$config['BrokerInstanceId'] = `$brokerInstanceId")) 'The installer does not propagate BrokerInstanceId into protected config before launch.'
Assert-True ($hostBrokerText.Contains('Get-Item -LiteralPath $configPath -Force -ErrorAction Stop')) 'HostBroker does not fail closed when the protected config cannot be accessed.'
Assert-True ($hostBrokerText.Contains('ConvertFrom-Json -ErrorAction Stop')) 'HostBroker does not fail closed when the protected config is malformed.'
Assert-True ($hostBrokerText.Contains("Get-BrokerMutexName -Config `$startupConfig")) 'HostBroker does not derive its mutex from protected startup config.'
Assert-True ($poolCommonText.Contains('Get-PoolWorkerMutexName -WorkerId $WorkerId -BrokerRoot $BrokerRoot')) 'Worker state updates do not bind their mutex to BrokerRoot.'
$scenarios.Add('installer-and-worker-propagation-contract')

foreach ($path in @($hostBrokerPath, $poolCommonPath, $installerPath, $PSCommandPath)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "PowerShell parse failure in $path"
}
$scenarios.Add('owned-powershell-parses')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
