[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'GuestRestart.ps1')
$checks = New-Object Collections.Generic.List[string]
function Check($Name, [bool] $Value) { if (-not $Value) { throw $Name }; $checks.Add($Name) }
function Reject($Name, [scriptblock] $Action) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Check $Name $failed }
$manifest = [pscustomobject]@{ Files = @([pscustomobject]@{ RelativePath = 'lab.exe'; Sha256 = ('A' * 64) }) }
$planJson = @'
{"FormatVersion":1,"Boots":[{"ExpectedSignIn":"Automatic","BootTimeoutSeconds":30,"SignedOutObservationSeconds":0,"BeforeRestart":{"ResultFile":"{OUTDIR}\\ready.json","JsonPointer":"/Ready","EqualsJson":"true"},"Continuation":{"ExecutableRelativePath":"lab.exe","ExecutableSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","Arguments":"--observe {OUTDIR}","Actions":[]}}]}
'@
$plan = $planJson | ConvertFrom-Json
Check 'bounded-plan-valid' ($null -ne (Resolve-GuestRestartPlan $plan $manifest))
$bad = $planJson | ConvertFrom-Json; $bad.Boots[0].Continuation.ExecutableSha256 = 'B' * 64
Reject 'continuation-hash-mismatch' { Resolve-GuestRestartPlan $bad $manifest }
$bad = $planJson | ConvertFrom-Json; $bad.Boots[0].ExpectedSignIn = 'manual'
Reject 'exact-sign-in-enum' { Resolve-GuestRestartPlan $bad $manifest }
$bad = $planJson | ConvertFrom-Json; $bad.Boots[0].BeforeRestart.ResultFile = '{OUTDIR}\..\credential.json'
Reject 'marker-cannot-escape-outbox' { Resolve-GuestRestartPlan $bad $manifest }
$bad = $planJson | ConvertFrom-Json; $bad.Boots[0].Continuation.Arguments = '{GUEST_CREDENTIAL_FILE}'
Reject 'credential-token-requires-opt-in' { Resolve-GuestRestartPlan $bad $manifest }
Check 'credential-opt-in-permitted' ($null -ne (Resolve-GuestRestartPlan $bad $manifest $true))

& {
    Set-StrictMode -Version Latest
    . (Join-Path $root '..\Skill\scripts\GuestPowerTestContract.ps1')
    $request = [pscustomobject]@{ Operation = 'RunGuestJobPowerTestV1'; ResetToBaseline = $true; StopAfter = $true; Job = [pscustomobject]@{ executable = 'lab.exe' }; Network = [pscustomobject]@{ Profile = 'None' }; GuestRestartPlan = $plan }
    Check 'strict-runner-allows-omitted-optional-controls' ($null -ne (Resolve-GuestPowerTestPolicy $request $manifest))
    $request.PSObject.Properties.Remove('GuestRestartPlan')
    $request | Add-Member -NotePropertyName GuestCredentialFixture -NotePropertyValue $true
    Check 'strict-fixture-only-request-allows-omitted-controls' ((Resolve-GuestPowerTestPolicy $request $manifest).CredentialFixture)
    $request | Add-Member -NotePropertyName ExpectGuestPowerOff -NotePropertyValue $true
    Reject 'strict-runner-still-rejects-conflicting-power-control' { Resolve-GuestPowerTestPolicy $request $manifest }
}

# Exercise the actual coordinator with synthetic independent guest observations.
# Host/VM side effects are replaced here, never on a real worker.
function Write-JsonAtomic { param($Path, $Value) }
function Copy-GuestJobForExecution { param($Job) $Job | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
function Expand-GuestJobTokens { param($Value, $GuestPayloadRoot, $GuestOutputRoot, $GuestCredentialFile, $AllowedTokens, $Context) $Value.Replace('{OUTDIR}', $GuestOutputRoot) }
function Assert-RequestActive { param($RequestId, $ExecutionDeadlineUtc) if ($script:cancel -and $script:deliveries.Count -gt 0) { throw [OperationCanceledException]::new('test cancellation') } }
function Invoke-ExpectedPowerOffJobSubmissionBounded { param($VmName, $RequestId, $ExecutionDeadlineUtc, $JobPath, $GuestTransferRoot, $GuestTransferFile, $GuestInboxFile, $GuestProcessingFile, $GuestCompletedFile, $GuestOutbox) $script:deliveries.Add($JobPath) }
function Test-GuestSessionBootIdentity { param($GuestState, $CurrentGuestBootTimeUtc, $Required) $true }
function Get-GuestRestartObservation {
    param($VmName, $RequestId, $PhaseId, $Outbox, $ExecutionDeadlineUtc)
    $initial = $script:deliveries.Count -eq 0
    $final = $script:deliveries.Count -eq 2
    [pscustomobject]@{
        CurrentGuestUtc = if ($initial) { '2026-01-01T00:01:00Z' } else { '2026-01-01T00:03:10Z' }
        CurrentGuestBootTimeUtc = if ($initial) { '2026-01-01T00:00:00Z' } else { '2026-01-01T00:03:00Z' }
        PowerTest = [pscustomobject]@{ SignedIn = $true; ConsoleUser = 'CodexTest'; Markers = @([pscustomobject]@{ Passed = $true; WrittenUtc = '2026-01-01T00:02:00Z' }) }
        ApplicationLease = [pscustomobject]@{ JobId = $PhaseId; ProcessId = 111; GuestBootTimeUtc = if ($final) { '2026-01-01T00:03:00Z' } else { '2026-01-01T00:00:00Z' } }
        Presence = [pscustomobject]@{ Result = $final; AgentError = $false; Completed = $false }
        State = [pscustomobject]@{}
    }
}
$job = [pscustomobject]@{ id = 'test'; executable = 'X:\lab.exe'; arguments = ''; actions = @(); assertResultFile = 'C:\CodexGuest\Outbox\test\final.json'; assertResultJsonPointer = '/Ready'; assertResultEqualsJson = 'true' }
$credential = New-Object Management.Automation.PSCredential('CodexTest', (ConvertTo-SecureString 'fixture-only-not-a-real-password' -AsPlainText -Force))
$parameters = @{ Job = $job; Policy = [pscustomobject]@{ Plan = $plan }; VmName = 'synthetic'; RequestId = 'test'; PayloadRoot = 'X:\'; Outbox = 'C:\CodexGuest\Outbox\test'; ResultRoot = 'C:\synthetic'; CredentialFile = ''; ExecutionDeadlineUtc = [DateTime]::UtcNow.AddMinutes(1); Credential = $credential }
$script:deliveries = New-Object Collections.Generic.List[string]; $script:cancel = $false
$proof = Invoke-GuestRestartPlan @parameters
Check 'one-original-one-continuation-same-output' ($proof.ContractProven -and $deliveries.Count -eq 2 -and $proof.OriginalApplicationLaunchCount -eq 1 -and -not $proof.ApplicationActionReplayed)
$script:deliveries.Clear(); $script:cancel = $true
Reject 'cancel-after-delivery-is-terminal' { Invoke-GuestRestartPlan @parameters }
Check 'cancel-never-resubmits-or-continues' ($deliveries.Count -eq 1)
$script:deliveries.Clear(); $script:cancel = $false
$parameters.Policy.Plan = $planJson | ConvertFrom-Json
$parameters.Policy.Plan.Boots[0].ExpectedSignIn = 'Manual'
$parameters.Policy.Plan.Boots[0].SignedOutObservationSeconds = 10
Reject 'manual-boot-cannot-pass-automatic-sign-in' { Invoke-GuestRestartPlan @parameters }
Check 'failed-sign-in-never-delivers-continuation' ($deliveries.Count -eq 1)

$script:watchdogStarted = $false; $script:watchdogStopped = $false
$probePath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $root))) 'work\power-watchdog-unit'
$credentialPath = 'unused-fixture-credential-path'
function ConvertTo-PowerShellSingleQuotedLiteral { param($Value) "'" + $Value.Replace("'", "''") + "'" }
function Assert-RequestActive { param($RequestId, $ExecutionDeadlineUtc) if ($script:watchdogStarted) { throw [OperationCanceledException]::new('watchdog cancellation') } }
function Start-Process { param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru) $script:watchdogStarted = $true; [pscustomobject]@{ Id = 123; StartTime = [DateTime]::UtcNow; HasExited = $false } }
function Stop-GuestProbeProcess { param($Process, $LeasePath) $script:watchdogStopped = $true }
Reject 'fixture-watchdog-honors-cancellation' { Invoke-GuestPowerWatchdog -Mode Fixture -VmName 'synthetic' -RequestId 'test' -ExecutionDeadlineUtc ([DateTime]::UtcNow.AddMinutes(1)) }
Check 'cancellation-stops-owned-watchdog' $script:watchdogStopped
[pscustomobject]@{ Success = $true; ScenarioCount = $checks.Count; Checks = $checks.ToArray() } | ConvertTo-Json -Depth 5
