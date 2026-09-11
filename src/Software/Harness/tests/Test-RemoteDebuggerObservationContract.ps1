[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'RemoteDebuggerObservation.ps1')
$script:calls = New-Object Collections.Generic.List[string]
$script:invocation = $null
$script:stopFails = $false
function Invoke-Command {
    param($Session, [switch] $AsJob, $ErrorAction, $ArgumentList, [scriptblock] $ScriptBlock)
    $script:invocation = [pscustomobject]@{ Session = $Session; AsJob = [bool]$AsJob; Arguments = @($ArgumentList); Script = $ScriptBlock }
    [pscustomobject]@{ State = 'Running' }
}
function Stop-Job { param($Job, $ErrorAction) $script:calls.Add('stop'); if ($script:stopFails) { throw 'stop failed' } }
function Remove-Job { param($Job, [switch] $Force, $ErrorAction) $script:calls.Add('remove-job') }
function Remove-PSSession { param($Session, $ErrorAction) $script:calls.Add('remove-session') }
$deadline = [DateTime]::UtcNow.AddMinutes(10)
$job = Start-RemoteDebuggerObservationV1 -Session 'dedicated-direct-session' -RequestId 'executable-test-contract-01' -ExecutionDeadlineUtc $deadline
if (-not $invocation.AsJob -or $invocation.Arguments.Count -ne 2 -or $invocation.Arguments[0] -cne 'executable-test-contract-01' -or [DateTime]::Parse($invocation.Arguments[1]).ToUniversalTime() -ne $deadline) { throw 'Observer did not bind its request and deadline to the separate asynchronous session.' }
foreach ($requestId in @('..\escape', 'bad/id', 'bad:stream')) {
    $rejected = $false
    try { $null = Start-RemoteDebuggerObservationV1 -Session 'fake' -RequestId $requestId -ExecutionDeadlineUtc $deadline } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe observer request ID accepted.' }
}
$rejected = $false
try { $null = Start-RemoteDebuggerObservationV1 -Session 'fake' -RequestId 'safe-id' -ExecutionDeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1)) } catch { $rejected = $true }
if (-not $rejected) { throw 'Expired observer deadline accepted.' }
Stop-RemoteDebuggerObservationV1 -Job $job -Session 'fake'
if (($calls -join ',') -ne 'stop,remove-job,remove-session') { throw 'Observer cleanup did not close both the job and separate Direct session.' }
$calls.Clear()
$stopFails = $true
$rejected = $false
try { Stop-RemoteDebuggerObservationV1 -Job $job -Session 'fake' } catch { $rejected = $true }
if (-not $rejected -or ($calls -join ',') -ne 'stop,remove-job,remove-session') { throw 'Observer stop failure leaked the Direct session.' }
$calls.Clear()
Stop-RemoteDebuggerObservationV1 -Job ([pscustomobject]@{State = 'Completed'}) -Session 'fake'
if (($calls -join ',') -ne 'remove-job,remove-session') { throw 'Completed observer cleanup restarted or stopped completed work.' }
[pscustomobject]@{ Success = $true; ScenarioCount = 8; GuestCommandsExecuted = $false } | ConvertTo-Json
