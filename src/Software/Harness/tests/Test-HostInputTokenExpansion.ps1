[CmdletBinding()]
param(
    [string] $HostBrokerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'HostBroker.ps1')
)

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($HostBrokerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }
$definition = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Expand-GuestJobTokens'
}, $true)) | Select-Object -First 1
if (-not $definition) { throw 'Expand-GuestJobTokens was not found.' }
$body = $definition.Body.Extent.Text
$body = $body.Substring(1, $body.Length - 2)
Set-Item -LiteralPath 'Function:\script:Expand-GuestJobTokens' -Value ([scriptblock]::Create($body))

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$scenarios = New-Object Collections.Generic.List[string]
$roots = [ordered]@{ media = 'Z:'; fixture = 'Y:\project' }
$allowed = @('PAYLOAD', 'OUTDIR', 'HOSTINPUT:media', 'HOSTINPUT:fixture')

$arguments = Expand-GuestJobTokens -Value '--media "{HOSTINPUT:media}\movie.mkv" --project "{HOSTINPUT:fixture}" --out "{OUTDIR}"' -GuestPayloadRoot 'D:\Payload' -GuestOutputRoot 'C:\CodexGuest\Outbox\request' -Context 'Arguments' -AllowedTokens $allowed -GuestHostInputRoots $roots
Assert-True ($arguments -eq '--media "Z:\movie.mkv" --project "Y:\project" --out "C:\CodexGuest\Outbox\request"') 'Named host-input arguments did not expand to broker-assigned roots.'
$scenarios.Add('arguments-expand-named-host-inputs')

$typedText = Expand-GuestJobTokens -Value '{HOSTINPUT:MEDIA}\selection.txt' -GuestPayloadRoot 'D:\Payload' -GuestOutputRoot 'C:\Out' -Context 'Action type_text.text' -AllowedTokens $allowed -GuestHostInputRoots $roots
Assert-True ($typedText -eq 'Z:\selection.txt') 'String-valued action expansion did not resolve the named host input case-insensitively.'
$scenarios.Add('string-actions-expand-named-host-inputs')

$unknownMessage = $null
try {
    Expand-GuestJobTokens -Value '{HOSTINPUT:other}' -GuestPayloadRoot 'D:\Payload' -GuestOutputRoot 'C:\Out' -Context 'Arguments' -AllowedTokens $allowed -GuestHostInputRoots $roots | Out-Null
}
catch { $unknownMessage = $_.Exception.Message }
Assert-True ($unknownMessage -like '*unresolved reserved token*') 'An undeclared named host input reached the guest.'
$scenarios.Add('undeclared-host-input-rejected')

$missingMessage = $null
try {
    Expand-GuestJobTokens -Value '{HOSTINPUT:media}' -GuestPayloadRoot 'D:\Payload' -GuestOutputRoot 'C:\Out' -Context 'Arguments' -AllowedTokens $allowed -GuestHostInputRoots ([ordered]@{}) | Out-Null
}
catch { $missingMessage = $_.Exception.Message }
Assert-True ($missingMessage -like '*was not mounted*') 'A declared but unmounted host input was silently passed through.'
$scenarios.Add('unmounted-host-input-rejected')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
