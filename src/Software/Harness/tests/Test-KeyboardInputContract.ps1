[CmdletBinding()]
param(
    [string] $HarnessRoot,
    [string] $RunnerPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($HarnessRoot)) { $HarnessRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($RunnerPath)) { $RunnerPath = Join-Path (Split-Path -Parent $HarnessRoot) 'Skill\scripts\Invoke-HyperVExecutableTest.ps1' }

function Import-KeyChordValidator {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw $errors[0].Message }
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ValidatedKeyChord' }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Key-chord validator not found: $Path" }
    $body = $definition.Body.Extent.Text
    Set-Item -LiteralPath 'Function:\script:Get-ValidatedKeyChord' -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)] $Action,
        [Parameter(Mandatory = $true)] [string] $ExpectedMessage,
        [Parameter(Mandatory = $true)] [string] $Scenario
    )
    $message = $null
    try { $null = Get-ValidatedKeyChord -Action $Action -Context 'Action 1' }
    catch { $message = $_.Exception.Message }
    if ($message -notlike ('*' + $ExpectedMessage + '*')) {
        throw "$Scenario was not rejected as expected. Actual error: $message"
    }
}

$validatorPaths = @(
    $RunnerPath,
    (Join-Path $HarnessRoot 'HostBroker.ps1'),
    (Join-Path $HarnessRoot 'seed\guest\GuestAgent.ps1')
)
$scenarios = New-Object Collections.Generic.List[string]
foreach ($validatorPath in $validatorPaths) {
    Import-KeyChordValidator -Path $validatorPath
    $sourceName = [IO.Path]::GetFileName($validatorPath)

    $valid = Get-ValidatedKeyChord -Action ([pscustomobject]@{ type = 'send_keys'; keys = 'WIN+LEFT'; holdMs = 75 }) -Context 'Action 1'
    $validKeys = if ($valid.PSObject.Properties.Name -contains 'Keys') { @($valid.Keys) } else { @($valid) }
    if (($validKeys -join '+') -ne 'WIN+LEFT') { throw "$sourceName did not retain the validated Win+Left chord." }
    if ($valid.PSObject.Properties.Name -contains 'VirtualKeys' -and (($valid.VirtualKeys -join ',') -ne '91,37')) {
        throw "$sourceName did not map Win+Left to its exact allowlisted virtual keys."
    }
    $scenarios.Add("$sourceName-valid-win-left")

    Assert-Rejected -Scenario "$sourceName-lowercase" -ExpectedMessage "uppercase '+'-separated" -Action ([pscustomobject]@{ type = 'send_keys'; keys = 'Win+Left' })
    Assert-Rejected -Scenario "$sourceName-unsupported" -ExpectedMessage "key 'VOLUMEUP' is not supported" -Action ([pscustomobject]@{ type = 'send_keys'; keys = 'VOLUMEUP' })
    Assert-Rejected -Scenario "$sourceName-duplicate" -ExpectedMessage 'does not allow duplicate keys' -Action ([pscustomobject]@{ type = 'send_keys'; keys = 'CTRL+CTRL+A' })
    Assert-Rejected -Scenario "$sourceName-multiple-non-modifiers" -ExpectedMessage 'one or more modifiers followed by exactly one non-modifier' -Action ([pscustomobject]@{ type = 'send_keys'; keys = 'A+B' })
    Assert-Rejected -Scenario "$sourceName-modifier-order" -ExpectedMessage 'one or more modifiers followed by exactly one non-modifier' -Action ([pscustomobject]@{ type = 'send_keys'; keys = 'A+CTRL' })
    Assert-Rejected -Scenario "$sourceName-unknown-property" -ExpectedMessage 'unsupported properties: script' -Action ([pscustomobject]@{ type = 'send_keys'; keys = 'ENTER'; script = 'not allowed' })
    Assert-Rejected -Scenario "$sourceName-low-hold" -ExpectedMessage 'holdMs must be between 10 and 2000' -Action ([pscustomobject]@{ type = 'send_keys'; keys = 'ENTER'; holdMs = 9 })
    Assert-Rejected -Scenario "$sourceName-fractional-hold" -ExpectedMessage 'holdMs must be a whole number' -Action ([pscustomobject]@{ type = 'send_keys'; keys = 'ENTER'; holdMs = 10.5 })
    $scenarios.Add("$sourceName-invalid-contracts")
}

$guestAgentText = Get-Content -LiteralPath (Join-Path $HarnessRoot 'seed\guest\GuestAgent.ps1') -Raw
if (-not $guestAgentText.Contains('public static void SendKeyChord') -or
    -not $guestAgentText.Contains('KEYEVENTF_EXTENDEDKEY') -or
    -not $guestAgentText.Contains('[CodexGuestInput]::SendKeyChord') -or
    -not $guestAgentText.Contains('[uint16[]]$chord.VirtualKeys') -or
    $guestAgentText.Contains('[ushort[]]$chord.VirtualKeys') -or
    -not $guestAgentText.Contains('VirtualKeyCodes =')) {
    throw 'The guest action does not retain the bounded SendInput implementation and result evidence contract.'
}
$scenarios.Add('guest-sendinput-and-evidence-contract')

$nativeSourceMatch = [regex]::Match($guestAgentText, "Add-Type @'\r?\n(?<source>[\s\S]*?)\r?\n'@")
if (-not $nativeSourceMatch.Success) { throw 'The guest native input helper source could not be extracted.' }
Add-Type -TypeDefinition $nativeSourceMatch.Groups['source'].Value -ErrorAction Stop
if (-not ('CodexGuestInput' -as [type]).GetMethod('SendKeyChord')) {
    throw 'The compiled guest input helper does not expose SendKeyChord.'
}
$scenarios.Add('guest-native-input-helper-compiles')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
