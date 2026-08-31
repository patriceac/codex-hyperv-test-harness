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

function ConvertTo-ExpectedLiteral {
    param([AllowEmptyString()] [string] $Value)

    "'" + $Value.Replace("'", "''") + "'"
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

$brokerAst = Get-ScriptAst -Path $HostBrokerPath
foreach ($functionName in @('ConvertTo-PowerShellSingleQuotedLiteral', 'Start-GuestSessionProbe')) {
    Import-AstFunction -Ast $brokerAst -Name $functionName
}

$script:credentialPath = 'C:\CodexHarness\private\guest-credential.json'
$scenarios = New-Object Collections.Generic.List[string]

$emptyLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value ''
Assert-True ($emptyLiteral -eq "''") 'The PowerShell literal helper rejected or changed an empty string.'
$scenarios.Add('empty-literal-is-valid')

$quotedLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value "C:\O'Brien\fixture"
Assert-True ($quotedLiteral -eq "'C:\O''Brien\fixture'") 'The PowerShell literal helper no longer escapes embedded apostrophes.'
$scenarios.Add('apostrophe-remains-escaped')

$nonEmptyPaths = [ordered]@{
    InboxFile = 'C:\CodexGuest\Inbox\request.json'
    ProcessingFile = 'C:\CodexGuest\Processing\request.json'
    CompletedFile = 'C:\CodexGuest\Completed\request.json'
    Outbox = 'C:\CodexGuest\Outbox\request'
}
$cases = @(
    [pscustomobject]@{ Name = 'all-optional-paths-omitted'; EmptyPath = $null },
    [pscustomobject]@{ Name = 'empty-inbox-file'; EmptyPath = 'InboxFile' },
    [pscustomobject]@{ Name = 'empty-processing-file'; EmptyPath = 'ProcessingFile' },
    [pscustomobject]@{ Name = 'empty-completed-file'; EmptyPath = 'CompletedFile' },
    [pscustomobject]@{ Name = 'empty-outbox'; EmptyPath = 'Outbox' }
)

foreach ($case in $cases) {
    $parameters = @{
        VmName = 'Codex-Harness-01'
        OutputPath = "C:\CodexHarness\probe-$($case.Name).json"
    }
    $expectedPaths = [ordered]@{}
    foreach ($pathName in @('InboxFile', 'ProcessingFile', 'CompletedFile', 'Outbox')) {
        if ($null -eq $case.EmptyPath) {
            $expectedPaths[$pathName] = ''
        }
        elseif ([string]$case.EmptyPath -eq $pathName) {
            $parameters[$pathName] = ''
            $expectedPaths[$pathName] = ''
        }
        else {
            $parameters[$pathName] = [string]$nonEmptyPaths[$pathName]
            $expectedPaths[$pathName] = [string]$nonEmptyPaths[$pathName]
        }
    }

    $script:startInvocation = $null
    $script:leaseWrite = $null
    $probe = Start-GuestSessionProbe @parameters
    Assert-True ($null -ne $probe -and $null -ne $script:startInvocation) "Probe case '$($case.Name)' did not start its disposable child process."
    Assert-True ($null -ne $script:leaseWrite -and [string]$probe.LeasePath -eq [string]$script:leaseWrite.Path) "Probe case '$($case.Name)' did not persist its process lease."

    $encodedIndex = [Array]::IndexOf([object[]]$script:startInvocation.ArgumentList, '-EncodedCommand')
    Assert-True ($encodedIndex -ge 0 -and $encodedIndex + 1 -lt $script:startInvocation.ArgumentList.Count) "Probe case '$($case.Name)' omitted its encoded command."
    $generatedCommand = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String([string]$script:startInvocation.ArgumentList[$encodedIndex + 1]))
    foreach ($placeholder in @('__INBOX_FILE__', '__PROCESSING_FILE__', '__COMPLETED_FILE__', '__OUTBOX__')) {
        Assert-True (-not $generatedCommand.Contains($placeholder)) "Probe case '$($case.Name)' left placeholder $placeholder unresolved."
    }

    $expectedArgumentList = '} -ArgumentList ' + (@(
        ConvertTo-ExpectedLiteral -Value ([string]$expectedPaths.InboxFile)
        ConvertTo-ExpectedLiteral -Value ([string]$expectedPaths.ProcessingFile)
        ConvertTo-ExpectedLiteral -Value ([string]$expectedPaths.CompletedFile)
        ConvertTo-ExpectedLiteral -Value ([string]$expectedPaths.Outbox)
    ) -join ', ') + ' | Select-Object -Last 1'
    Assert-True ($generatedCommand.Contains($expectedArgumentList)) "Probe case '$($case.Name)' generated an incorrect optional-path argument list."

    $generatedTokens = $null
    $generatedErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($generatedCommand, [ref]$generatedTokens, [ref]$generatedErrors)
    $generatedParseMessage = if ($generatedErrors.Count -gt 0) { [string]$generatedErrors[0].Message } else { 'none' }
    Assert-True ($generatedErrors.Count -eq 0) "Probe case '$($case.Name)' generated invalid Windows PowerShell: $generatedParseMessage"
    $scenarios.Add([string]$case.Name)
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
