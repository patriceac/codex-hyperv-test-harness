[CmdletBinding()]
param([string] $HarnessRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($HarnessRoot)) { $HarnessRoot = Split-Path -Parent $PSScriptRoot }

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Copy-JsonObject {
    param($Value)
    $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function Assert-Rejected {
    param([scriptblock] $Operation, [string] $ExpectedMessage, [string] $Scenario)
    $actual = $null
    try { & $Operation | Out-Null }
    catch { $actual = $_.Exception.Message }
    if ($actual -notlike ('*' + $ExpectedMessage + '*')) {
        throw "$Scenario was not rejected as expected. Actual error: $actual"
    }
}

$modulePath = Join-Path $HarnessRoot 'SystemPrompts.ps1'
$brokerPath = Join-Path $HarnessRoot 'HostBroker.ps1'
$workerPath = Join-Path $HarnessRoot 'HostWorker.ps1'
$networkPath = Join-Path $HarnessRoot 'RequestNetwork.ps1'
$installerPath = Join-Path $HarnessRoot 'Install-PoolHostBroker.ps1'
$runnerPath = Join-Path (Split-Path -Parent $HarnessRoot) 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
. $modulePath

$hash = 'A' * 64
$manifest = [pscustomobject]@{
    Files = @([pscustomobject]@{ RelativePath = 'bin/app.exe'; Sha256 = $hash })
}
$request = [pscustomobject][ordered]@{
    RequestId = 'system-prompt-test'
    Operation = 'RunGuestJobSystemPromptsV1'
    Job = [pscustomobject]@{ executable = '{PAYLOAD}\bin\app.exe' }
    SystemPrompts = [pscustomobject][ordered]@{
        FormatVersion = 1
        AcceptUac = $true
        AcceptWindowsFirewall = $true
        PromptTimeoutSeconds = 120
        ExecutableRelativePath = 'bin\app.exe'
        ExecutableSha256 = $hash
        FirewallProfiles = @('Private')
    }
}

$scenarios = New-Object Collections.Generic.List[string]
$policy = Resolve-SystemPromptPolicyV1 -Request $request -PayloadManifest $manifest
Assert-True ($policy.FormatVersion -eq 1 -and $policy.AcceptUac -and $policy.AcceptWindowsFirewall) 'Valid system-prompt policy did not retain its exact flags.'
Assert-True ((@($policy.Sequence) -join ',') -ceq 'Uac,WindowsFirewall') 'System-prompt policy did not retain the strict UAC-before-firewall sequence.'
Assert-True ([string]$policy.ExecutableSha256 -ceq $hash -and (@($policy.FirewallProfiles) -join ',') -ceq 'Private') 'System-prompt policy did not retain exact executable and firewall identity.'
$scenarios.Add('valid-versioned-policy')

$combinedRequest = Copy-JsonObject $request
$combinedRequest.Operation = 'RunGuestJobSetupSystemPromptsV1'
$combinedRequest | Add-Member -NotePropertyName GuestSetup -NotePropertyValue ([pscustomobject]@{ FormatVersion = 1 })
$combinedPolicy = Resolve-SystemPromptPolicyV1 -Request $combinedRequest -PayloadManifest $manifest
Assert-True ($combinedPolicy.ExecutableSha256 -ceq $hash -and (@($combinedPolicy.Sequence) -join ',') -ceq 'Uac,WindowsFirewall') 'Combined guest-setup/system-prompt policy changed the exact application prompt identity.'
$scenarios.Add('combined-operation-preserves-application-prompt-identity')

$runtime = [pscustomobject][ordered]@{
    Policy = $policy
    Complete = $false
    FirewallProfileReadiness = @([pscustomobject]@{ Name = 'Private'; NotifyOnListen = 'True' })
    Acceptances = (New-Object Collections.Generic.List[object])
}
$emptyEvidence = Get-SystemPromptEvidenceV1 -Runtime $runtime
Assert-True ($emptyEvidence.Acceptances -is [Array] -and @($emptyEvidence.Acceptances).Count -eq 0 -and @($emptyEvidence.FirewallProfileReadiness).Count -eq 1 -and -not [bool]$emptyEvidence.ContractSatisfied) 'Empty prompt evidence did not retain safe arrays and firewall readiness under Windows PowerShell 5.1.'
$runtime.Acceptances.Add([pscustomobject]@{ Kind = 'Uac'; Success = $true })
$runtime.Acceptances.Add([pscustomobject]@{ Kind = 'WindowsFirewall'; Success = $true })
$runtime.Complete = $true
$completeEvidence = Get-SystemPromptEvidenceV1 -Runtime $runtime
Assert-True ($completeEvidence.Acceptances -is [Array] -and @($completeEvidence.Acceptances).Count -eq 2 -and [bool]$completeEvidence.ContractSatisfied) 'Completed prompt evidence did not serialize the generic acceptance list safely.'
$scenarios.Add('prompt-evidence-generic-list-is-windows-powershell-safe')

$legacy = Copy-JsonObject $request
$legacy.Operation = 'RunGuestJob'
$legacy.PSObject.Properties.Remove('SystemPrompts')
Assert-True ($null -eq (Resolve-SystemPromptPolicyV1 -Request $legacy -PayloadManifest $manifest)) 'Legacy requests no longer remain prompt-free.'
$scenarios.Add('legacy-request-unchanged')

foreach ($case in @(
    @{ Name = 'wrong-operation'; Message = 'requires the versioned'; Mutate = { param($v) $v.Operation = 'RunGuestJob' } },
    @{ Name = 'missing-contract'; Message = 'requires SystemPrompts'; Mutate = { param($v) $v.PSObject.Properties.Remove('SystemPrompts') } },
    @{ Name = 'combined-missing-setup'; Message = 'requires GuestSetup'; Mutate = { param($v) $v.Operation = 'RunGuestJobSetupSystemPromptsV1' } },
    @{ Name = 'old-operation-rejects-setup'; Message = 'require RunGuestJobSetupSystemPromptsV1'; Mutate = { param($v) $v | Add-Member -NotePropertyName GuestSetup -NotePropertyValue ([pscustomobject]@{ FormatVersion = 1 }) } },
    @{ Name = 'unknown-property'; Message = 'unsupported properties'; Mutate = { param($v) $v.SystemPrompts | Add-Member script 'bad' } },
    @{ Name = 'false-flags'; Message = 'at least one'; Mutate = { param($v) $v.SystemPrompts.AcceptUac = $false; $v.SystemPrompts.AcceptWindowsFirewall = $false; $v.SystemPrompts.FirewallProfiles = @() } },
    @{ Name = 'short-timeout'; Message = 'between 5 and 600'; Mutate = { param($v) $v.SystemPrompts.PromptTimeoutSeconds = 4 } },
    @{ Name = 'relative-path-mismatch'; Message = 'guest job payload executable'; Mutate = { param($v) $v.SystemPrompts.ExecutableRelativePath = 'bin\other.exe' } },
    @{ Name = 'hash-mismatch'; Message = 'payload-manifest file'; Mutate = { param($v) $v.SystemPrompts.ExecutableSha256 = 'B' * 64 } },
    @{ Name = 'unsafe-path'; Message = 'safe payload-relative'; Mutate = { param($v) $v.SystemPrompts.ExecutableRelativePath = '..\app.exe'; $v.Job.executable = '{PAYLOAD}\..\app.exe' } },
    @{ Name = 'bad-profile'; Message = 'Private and Public only'; Mutate = { param($v) $v.SystemPrompts.FirewallProfiles = @('Domain') } },
    @{ Name = 'duplicate-profile'; Message = 'unique exact values'; Mutate = { param($v) $v.SystemPrompts.FirewallProfiles = @('Private', 'Private') } },
    @{ Name = 'power-off-conflict'; Message = 'cannot be combined'; Mutate = { param($v) $v | Add-Member ExpectGuestPowerOff $true } }
)) {
    $candidate = Copy-JsonObject $request
    & $case.Mutate $candidate
    Assert-Rejected -Scenario $case.Name -ExpectedMessage $case.Message -Operation { Resolve-SystemPromptPolicyV1 -Request $candidate -PayloadManifest $manifest }
}
$scenarios.Add('malformed-and-unbounded-contracts-rejected')

$moduleText = Get-Content -LiteralPath $modulePath -Raw
$brokerText = Get-Content -LiteralPath $brokerPath -Raw
$workerText = Get-Content -LiteralPath $workerPath -Raw
$networkText = Get-Content -LiteralPath $networkPath -Raw
$installerText = Get-Content -LiteralPath $installerPath -Raw
$runnerText = Get-Content -LiteralPath $runnerPath -Raw
foreach ($required in @(
    'Msvm_Keyboard',
    'GetVirtualSystemThumbnailImage',
    'FirewallUX\.dll',
    'PickerHost.exe',
    'FirewallNotificationDialogServer',
    'NotifyOnListen',
    'AllowInboundRules',
    'AllowLocalFirewallRules',
    'AllowUserApps',
    'AllowUserPorts',
    'DisabledInterfaceAliases',
    'New-NetFirewallRule',
    'ExactInboundFirewallRules',
    'UAC acceptance did not produce the exact hashed executable with an elevated token.'
)) {
    Assert-True ($moduleText.Contains($required)) "System-prompts module is missing runtime contract: $required"
}
Assert-True ($brokerText.Contains("'SystemPrompts.ps1'") -and $brokerText.Contains('Invoke-SystemPromptServiceV1') -and $brokerText.Contains("`$brokerResultValue['SystemPrompts']")) 'HostBroker does not own prompt validation, runtime service, and result evidence.'
Assert-True ($moduleText.Contains("`$arguments.TargetSystem = [string]`$settings.__PATH") -and $moduleText.Contains("`$service.PSBase.InvokeMethod('GetVirtualSystemThumbnailImage'")) 'Framebuffer capture does not pass the WMI virtual-system reference path required by Hyper-V.'
Assert-True ($moduleText.Contains('if ($bytes.Length -lt $pixelBytes)') -and $moduleText.Contains('Marshal]::Copy($bytes, 0, $data.Scan0, $pixelBytes)')) 'Framebuffer capture does not bound its RGB565 copy to the requested pixel payload.'
Assert-True (-not $moduleText.Contains("Caption -eq 'Virtual Machine'")) 'System-prompt VM lookup still depends on localized Hyper-V Caption text.'
Assert-True ($moduleText.Contains("[TimeSpan]::FromSeconds(2)") -and $moduleText.Contains('Start-Sleep -Milliseconds 250')) 'UAC input is not delayed until the consent UI can render and process focus changes.'
Assert-True ($moduleText.Contains('Waiting for the Windows Firewall prompt to finish rendering.')) 'Firewall authorization does not wait for its prompt UI to render.'
Assert-True ($workerText.Contains('ErrorFullyQualifiedId = $terminalErrorFullyQualifiedId') -and $workerText.Contains('ErrorScriptStackTrace = $terminalErrorScriptStackTrace')) 'Pool-worker fallback results do not preserve the original failure diagnostics.'
Assert-True ($networkText.Contains("'RunGuestJobSystemPromptsV1'") -and $networkText.Contains("'RunGuestJobSetupSystemPromptsV1'")) 'Request-network validation does not accept both versioned system-prompt operations.'
Assert-True ($installerText.Contains("'SystemPrompts.ps1'")) 'Broker installation does not copy and hash SystemPrompts.ps1.'
Assert-True ($runnerText.Contains('[switch] $AcceptUacPrompt') -and $runnerText.Contains('[switch] $AcceptWindowsFirewallPrompt') -and $runnerText.Contains("'RunGuestJobSystemPromptsV1'") -and $runnerText.Contains("'RunGuestJobSetupSystemPromptsV1'")) 'Runner does not expose and serialize both bounded prompt capabilities or their setup composition.'
$runtimeIndex = $brokerText.IndexOf('New-SystemPromptRuntimeV1')
$setupIndex = $brokerText.IndexOf('Invoke-GuestSetupV1')
$submitIndex = $brokerText.IndexOf("`$failureStage = 'SubmittingGuestJob'")
$serviceIndex = $brokerText.IndexOf('Invoke-SystemPromptServiceV1')
Assert-True ($runtimeIndex -ge 0 -and $setupIndex -gt $runtimeIndex -and $submitIndex -gt $setupIndex -and $serviceIndex -gt $submitIndex) 'The broker no longer prepares prompt policy, completes guest setup, submits the application, and services prompts in that order.'
$scenarios.Add('host-secure-desktop-firewall-and-propagation-contract')

$nativeSource = [regex]::Match($moduleText, "Add-Type -TypeDefinition @'\r?\n(?<source>[\s\S]*?)\r?\n'@")
Assert-True $nativeSource.Success 'Token-elevation helper source could not be extracted.'
if (-not ('CodexSystemPromptToken' -as [type])) { Add-Type -TypeDefinition $nativeSource.Groups['source'].Value -ErrorAction Stop }
Assert-True ($null -ne ('CodexSystemPromptToken' -as [type]).GetMethod('IsElevated')) 'Token-elevation helper did not compile with IsElevated.'
$scenarios.Add('token-elevation-helper-compiles')

foreach ($path in @($modulePath, $brokerPath, $workerPath, $networkPath, $installerPath, $runnerPath, $PSCommandPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) "PowerShell parse failure in $path"
}
$scenarios.Add('owned-powershell-parses')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
