[CmdletBinding()]
param([string] $HostBrokerPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($HostBrokerPath)) {
    $HostBrokerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'HostBroker.ps1'
}

function Get-ScriptAst {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "$Path has a parse error: $($errors[0].Message)"
    }
    $ast
}

function Import-AstFunction {
    param(
        [Parameter(Mandatory = $true)] $Ast,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $definition = @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
}

function Assert-True {
    param(
        [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )

    if (-not $Condition) { throw $Message }
}

$newPSSessionCommand = Get-Command -Name 'New-PSSession' -CommandType Cmdlet -ErrorAction Stop
$hyperVDirectParameterSets = @($newPSSessionCommand.ParameterSets | Where-Object {
    $names = @($_.Parameters | ForEach-Object Name)
    $names -contains 'VMName' -or $names -contains 'VMId'
})
Assert-True ($hyperVDirectParameterSets.Count -gt 0) 'Windows PowerShell exposed no Hyper-V Direct New-PSSession parameter set.'
foreach ($parameterSet in $hyperVDirectParameterSets) {
    $names = @($parameterSet.Parameters | ForEach-Object Name)
    Assert-True (-not ($names -contains 'SessionOption')) "Hyper-V Direct parameter set '$($parameterSet.Name)' unexpectedly accepted SessionOption; review this regression."
}

$brokerAst = Get-ScriptAst -Path $HostBrokerPath
$brokerText = Get-Content -Raw -LiteralPath $HostBrokerPath
$incompatiblePattern = '(?im)New-PSSession[^\r\n]*(?:-VMName|-VMId)[^\r\n]*-SessionOption|New-PSSession[^\r\n]*-SessionOption[^\r\n]*(?:-VMName|-VMId)'
Assert-True (-not [regex]::IsMatch($brokerText, $incompatiblePattern)) 'HostBroker contains a New-PSSession call that combines Hyper-V Direct with SessionOption.'
Assert-True ([regex]::Matches($brokerText, '(?im)New-PSSession[^\r\n]*(?:-VMName|-VMId)').Count -ge 3) 'The expected Hyper-V Direct session call sites were not all found.'

$sourceCommands = @($brokerAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-PSSession'
}, $true))
$sourceHyperVCommands = @($sourceCommands | Where-Object {
    $names = @($_.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
    $names -contains 'VMName' -or $names -contains 'VMId'
})
Assert-True ($sourceHyperVCommands.Count -gt 0) 'No executable Hyper-V Direct New-PSSession call was found in HostBroker.'
foreach ($command in $sourceHyperVCommands) {
    $names = @($command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
    Assert-True (-not ($names -contains 'SessionOption')) 'An executable Hyper-V Direct New-PSSession call binds SessionOption.'
}

$script:startInvocation = $null
$script:leaseWrite = $null
function Start-Process {
    param(
        [string] $FilePath,
        [object[]] $ArgumentList,
        [string] $WindowStyle,
        [switch] $PassThru
    )

    $script:startInvocation = [pscustomobject]@{
        FilePath = $FilePath
        ArgumentList = @($ArgumentList)
        WindowStyle = $WindowStyle
        PassThru = [bool]$PassThru
    }
    [pscustomobject]@{
        Id = 4242
        StartTime = [DateTime]::Parse('2026-08-31T12:00:00Z').ToLocalTime()
    }
}

function Write-JsonAtomic {
    param(
        [string] $Path,
        $Value
    )

    $script:leaseWrite = [pscustomobject]@{ Path = $Path; Value = $Value }
}

foreach ($functionName in @('ConvertTo-PowerShellSingleQuotedLiteral', 'Start-ExpectedPowerOffJobSubmission')) {
    Import-AstFunction -Ast $brokerAst -Name $functionName
}

$script:credentialPath = 'C:\CodexHarness\private\guest-credential.json'
$submission = Start-ExpectedPowerOffJobSubmission `
    -VmName 'Codex-Harness-01' `
    -RequestId 'parameter-set-regression' `
    -JobPath 'C:\CodexHarness\Jobs\request.json' `
    -GuestTransferRoot 'C:\CodexGuest\Transfer\request' `
    -GuestTransferFile 'C:\CodexGuest\Transfer\request\request.json' `
    -GuestInboxFile 'C:\CodexGuest\Inbox\request.json' `
    -GuestProcessingFile 'C:\CodexGuest\Processing\request.json' `
    -GuestCompletedFile 'C:\CodexGuest\Completed\request.json' `
    -GuestOutbox 'C:\CodexGuest\Outbox\request' `
    -OutputPath 'C:\CodexHarness\Probes\parameter-set-regression.json'
Assert-True ($null -ne $submission -and $null -ne $script:startInvocation) 'The expected-power-off child command was not generated.'
Assert-True ($null -ne $script:leaseWrite) 'The expected-power-off child process lease was not recorded.'

$encodedIndex = [Array]::IndexOf([object[]]$script:startInvocation.ArgumentList, '-EncodedCommand')
Assert-True ($encodedIndex -ge 0 -and $encodedIndex + 1 -lt $script:startInvocation.ArgumentList.Count) 'The expected-power-off child omitted its encoded command.'
$generatedCommand = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String([string]$script:startInvocation.ArgumentList[$encodedIndex + 1]))
$generatedTokens = $null
$generatedErrors = $null
$generatedAst = [Management.Automation.Language.Parser]::ParseInput($generatedCommand, [ref]$generatedTokens, [ref]$generatedErrors)
$generatedParseMessage = if ($generatedErrors.Count -gt 0) { [string]$generatedErrors[0].Message } else { 'none' }
Assert-True ($generatedErrors.Count -eq 0) "The expected-power-off child generated invalid Windows PowerShell: $generatedParseMessage"
$generatedSessionCommands = @($generatedAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-PSSession'
}, $true))
Assert-True ($generatedSessionCommands.Count -eq 1) 'The expected-power-off child did not generate exactly one New-PSSession call.'
$generatedParameterNames = @($generatedSessionCommands[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
Assert-True ($generatedParameterNames -contains 'VMName') 'The expected-power-off child stopped using Hyper-V Direct.'
Assert-True (-not ($generatedParameterNames -contains 'SessionOption')) 'The expected-power-off child binds SessionOption with Hyper-V Direct.'

$script:newPSSessionBoundParameters = $null
function Assert-RequestActive {
    param([string] $RequestId, [DateTime] $ExecutionDeadlineUtc)
}

function Write-BrokerState {
    param([string] $Status, [string] $RequestId, [string] $Message)
}

function New-PSSession {
    [CmdletBinding()]
    param(
        [string] $VMName,
        [Management.Automation.PSCredential] $Credential
    )

    $script:newPSSessionBoundParameters = @{} + $PSBoundParameters
    [pscustomobject]@{ Marker = 'compatible-hyper-v-direct-session' }
}

Import-AstFunction -Ast $brokerAst -Name 'Open-GuestSessionReliable'
$securePassword = ConvertTo-SecureString 'test-password' -AsPlainText -Force
$credential = New-Object Management.Automation.PSCredential('test-user', $securePassword)
$session = Open-GuestSessionReliable -VmName 'Codex-Harness-01' -Credential $credential -RequestId 'parameter-set-regression' -ExecutionDeadlineUtc ([DateTime]::UtcNow.AddMinutes(1)) -Attempts 1
Assert-True ([string]$session.Marker -eq 'compatible-hyper-v-direct-session') 'The reliable Hyper-V Direct connection did not return the session.'
Assert-True ($null -ne $script:newPSSessionBoundParameters) 'The reliable Hyper-V Direct connection did not call New-PSSession.'
Assert-True ($script:newPSSessionBoundParameters.ContainsKey('VMName')) 'The reliable connection omitted VMName.'
Assert-True ($script:newPSSessionBoundParameters.ContainsKey('Credential')) 'The reliable connection omitted Credential.'
Assert-True ($script:newPSSessionBoundParameters.ContainsKey('ErrorAction')) 'The reliable connection omitted fail-fast ErrorAction handling.'
Assert-True (-not $script:newPSSessionBoundParameters.ContainsKey('SessionOption')) 'The reliable connection still binds SessionOption with Hyper-V Direct.'

$scenarios = @(
    'windows-powershell-metadata-excludes-session-option'
    'host-broker-source-excludes-invalid-parameter-combination'
    'expected-poweroff-child-uses-compatible-parameter-set'
    'reliable-session-runtime-binds-compatible-parameters'
)
[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios
} | ConvertTo-Json -Depth 8
