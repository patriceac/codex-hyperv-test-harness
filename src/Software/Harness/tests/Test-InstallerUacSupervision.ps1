[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\InstallerUacGate.ps1')
$now=[DateTime]::Parse('2026-09-25T00:00:00Z').ToUniversalTime()
$count=0
function New-Snapshot {
    [pscustomobject]@{Complete=$false;Controller=[pscustomobject]@{Phase='HandlingPrompt';AtUtc=$now.ToString('o');DeadlineUtc=$now.AddSeconds(120).ToString('o');ProcessId=100;ProcessStartUtc=$now.AddSeconds(-10).ToString('o');BeforePassed=$true;AfterPassed=$null;ElevatedProcessId=$null;ElevatedCreationFileTime=$null;ExitCode=$null};ControllerAlive=$true;TaskRan=$true;TaskState='Running';TaskResult=267009;SecureUiProgress=@();Input=$null}
}
foreach($case in @('Complete','Exited','EarlyExit','Reboot','PhaseTimeout','RequestCap','Renewal','PhaseTimeDrift')){
    $previous=New-Snapshot;$status=New-Snapshot;$current=$now.AddSeconds(30);$outer=$now.AddSeconds(300);$expected=$null
    switch($case){
        Complete {$status.Complete=$true;$status.ControllerAlive=$false}
        Exited {$status.ControllerAlive=$false;$expected='InstallerControllerExited'}
        EarlyExit {$status.Controller=$null;$status.TaskState='Ready';$expected='InstallerControllerExited'}
        Reboot {$status.Controller.Phase='Rebooting';$status.ControllerAlive=$false}
        PhaseTimeout {$current=$now.AddSeconds(120);$expected='InstallerControllerPhaseTimeout'}
        RequestCap {$current=$now.AddSeconds(60);$outer=$current;$expected='InstallerControllerPhaseTimeout'}
        Renewal {$status.Controller.DeadlineUtc=$now.AddSeconds(121).ToString('o');$expected='InstallerControllerDeadlineChanged'}
        PhaseTimeDrift {$status.Controller.AtUtc=$now.AddSeconds(1).ToString('o');$expected='InstallerControllerDeadlineChanged'}
    }
    if((Get-InstallerSupervisionFailure $status $previous $current $outer) -cne $expected){throw "Incorrect supervision for $case."};$count++
}
$status=New-Snapshot
$status | Add-Member Secret 'NEVER_EXPORT_SECRET'
$status.Controller | Add-Member Secret 'NEVER_EXPORT_SECRET'
$status.SecureUiProgress=@([pscustomobject]@{Phase='EnteringCredentials';AtUtc=$now.ToString('o');Secret='NEVER_EXPORT_SECRET'})
$safe=ConvertTo-InstallerStatusSnapshot $status
if($null -ne $safe.Input -or $null -ne $safe.Controller.AfterPassed -or ($safe | ConvertTo-Json -Depth 10) -match 'NEVER_EXPORT_SECRET'){throw 'Unknown outcomes or the diagnostic allowlist changed.'};$count++
$status.Input=[pscustomobject]@{Success=$false;Decision='Accept';InputStarted=$true;CredentialEntered=$false;Secret='NEVER_EXPORT_SECRET'}
$safe=ConvertTo-InstallerStatusSnapshot $status
if(-not $safe.Input.InputStarted -or $safe.Input.Success -or $safe.Input.CredentialEntered -or ($safe | ConvertTo-Json -Depth 10) -match 'NEVER_EXPORT_SECRET'){throw 'A final partial-input receipt was lost or misrepresented.'};$count++
foreach($change in @('UnknownPhase','NonBooleanInput')){
    $bad=$status | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    if($change -eq 'UnknownPhase'){$bad.Controller.Phase='NEVER_EXPORT_SECRET'}else{$bad.Input.Success='false'}
    $rejected=$false;try{$null=ConvertTo-InstallerStatusSnapshot $bad}catch{$rejected=$true}
    if(-not $rejected){throw "Malformed diagnostics accepted: $change."};$count++
}
# Exercise the real host polling loop using only synthetic probes, a fake clock and no process APIs.
$hostAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\HostBroker.ps1'),[ref]$null,[ref]$null)
$loop=$hostAst.Find({param($node) $node -is [Management.Automation.Language.DoWhileStatementAst] -and $node.Extent.Text.Contains('Invoke-InstallerGuestStatus')},$true)
$poll=[scriptblock]::Create($loop.Extent.Text.Replace('[DateTime]::UtcNow','$script:fakeNow'))
foreach($case in @('Complete','Exited','UnavailableUntilDeadline')){
    & {
        $script:fakeNow=$now;$script:probeCount=0;$script:retained=$null
        $requestId='synthetic';$vmName='synthetic';$installerRoot='C:\synthetic';$guestOutbox='C:\synthetic-out';$ResultRoot='C:\synthetic-host';$RequestStateRoot=$ResultRoot
        $executionDeadlineUtc=$now.AddSeconds(300);$createdUtc=$now;$ClaimedUtc=$now;$workerId=1
        $installerLastStatus=$null;$installerLastPhase=$null;$installerObservedUtc=$null;$failureKind=$null
        function Assert-RequestActive {param($RequestId,$ExecutionDeadlineUtc) if($script:fakeNow -ge $ExecutionDeadlineUtc){throw 'Outer deadline expired.'}}
        function Invoke-InstallerGuestStatus {
            param($VmName,$RequestId,$GuestRoot,$GuestOutbox,$ExecutionDeadlineUtc)
            $script:probeCount++
            if($case -eq 'UnavailableUntilDeadline' -and $script:probeCount -gt 1){return [pscustomobject]@{Available=$false;Failure='ProbeTimeout';Snapshot=$null}}
            $value=New-Snapshot
            if($case -eq 'Complete'){$value.Complete=$true}
            if($case -eq 'Exited'){$value.ControllerAlive=$false}
            [pscustomobject]@{Available=$true;Failure=$null;Snapshot=$value}
        }
        function Write-JsonAtomic {param($Path,$Value) $script:retained=$Value}
        function Write-RequestState {param($ResultRoot,$RequestId,$Status,$Message,$CreatedUtc,$ClaimedUtc,$ExecutionDeadlineUtc,$WorkerId)}
        function Start-Sleep {param($Seconds) $script:fakeNow=$script:fakeNow.AddSeconds(60)}
        $caught=$null;try{. $poll}catch{$caught=$_.Exception.Message}
        if($case -eq 'Complete'){if($caught -or $script:probeCount -ne 1){throw 'A completed controller was polled again.'}}
        elseif($case -eq 'Exited'){if($failureKind -cne 'InstallerControllerExited' -or $script:probeCount -ne 1){throw 'Controller exit waited for the outer timeout.'}}
        else {
            if($failureKind -cne 'InstallerControllerPhaseTimeout' -or $script:probeCount -ne 3){throw 'Unavailable probes renewed the last known phase deadline.'}
            if($script:retained.LastObservedUtc -cne $now.ToString('o') -or $script:retained.ProbeAvailable -or $null -ne $script:retained.LastKnown.Input){throw 'Stale status became fresh or invented input evidence.'}
        }
    }
    $count++
}
# Simulate a preparation exit racing with its Rebooting marker, and final publication racing with process exit.
foreach($case in @('Reboot','Complete')){
    & {
        $Root='C:\synthetic-private';$Outbox='C:\synthetic-outbox';$script:record=(New-Snapshot).Controller;$script:record.Phase='PreparingAccounts';$script:completion=$null
        function Get-ScheduledTask {[CmdletBinding()]param($TaskName) [pscustomobject]@{State='Ready'}}
        function Get-ScheduledTaskInfo {[CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject) process{[pscustomobject]@{LastRunTime=$now;LastTaskResult=0}}}
        function Get-Process {[CmdletBinding()]param($Id) if($case -eq 'Reboot'){$script:record=$script:record.PSObject.Copy();$script:record.Phase='Rebooting'}else{$script:completion=[pscustomobject]@{Complete=$true}};$null}
        function Read-InstallerStatusJson {param($Path) if($Path.EndsWith('installer-progress.json')){$script:record.PSObject.Copy()}elseif($Path.EndsWith('complete.json')){$script:completion}else{$null}}
        $snapshot=Get-InstallerStatusSnapshot $Root $Outbox
        if(Get-InstallerSupervisionFailure $snapshot $null $now $now.AddSeconds(300)){throw 'An intentional reboot or completed controller was reported as an early exit.'}
        if($case -eq 'Complete' -and -not $snapshot.Complete){throw 'Final completion was not read after the exit observation.'}
    }
    $count++
}
$harvest=$hostAst.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text.Contains('$installerStarted') -and $node.Extent.Text.Contains('Save-GuestRestartFailureEvidence')},$true)
& {
    $installerStarted=$true;$guestRestartStarted=$false;$success=$false;$evidenceTransferSucceeded=$false
    $vmName='synthetic';$requestId='synthetic';$guestOutbox='C:\synthetic-outbox';$ResultRoot='C:\synthetic-result';$Config=[pscustomobject]@{ClientSid='synthetic'}
    function Save-GuestRestartFailureEvidence {param($VmName,$RequestId,$GuestOutbox,$ResultRoot,$ClientSid) [pscustomobject]@{Retained=$true}}
    . ([scriptblock]::Create($harvest.Extent.Text))
    if(-not $failureEvidence.Retained){throw 'An installer failure skipped bounded evidence collection.'}
}
$count++
# Execute the actual guest probe body with policy/task/file mocks; never change host policy.
$probeAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\InstallerUac.ps1'),[ref]$null,[ref]$null)
$childSource=$probeAst.Find({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('$value=Invoke-Command -VMName')},$true).Value
$childAst=[Management.Automation.Language.Parser]::ParseInput($childSource,[ref]$null,[ref]$null)
$remote=$childAst.Find({param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $node.Parent -is [Management.Automation.Language.CommandAst] -and $node.Parent.GetCommandName() -eq 'Invoke-Command'},$true)
$gatePath=Join-Path $PSScriptRoot '..\InstallerUacGate.ps1'
& {
    $script:probePolicyApplied=$false
    function Set-ExecutionPolicy {[CmdletBinding()]param($Scope,$ExecutionPolicy,[switch]$Force) if($Scope -cne 'Process' -or $ExecutionPolicy -cne 'Bypass' -or -not $Force){throw 'The probe attempted a persistent or unsupported execution-policy change.'};$script:probePolicyApplied=$true}
    function Join-Path {param($Path,$ChildPath) if($ChildPath -ceq 'InstallerUacGate.ps1'){if(-not $script:probePolicyApplied){throw 'The probe imported a script before configuring its own process.'};$gatePath}else{[IO.Path]::Combine($Path,$ChildPath)}}
    function Test-Path {param($LiteralPath,$PathType) $false}
    function Get-ScheduledTask {[CmdletBinding()]param($TaskName) [pscustomobject]@{State='Ready'}}
    function Get-ScheduledTaskInfo {[CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject) process{[pscustomobject]@{LastRunTime=$now;LastTaskResult=0}}}
    $snapshot=& $remote.ScriptBlock.GetScriptBlock() 'C:\synthetic-private' 'C:\synthetic-outbox'
    if(-not $script:probePolicyApplied -or -not $snapshot.TaskRan -or $snapshot.Complete){throw 'The scoped guest probe did not return its real projected snapshot.'}
}
$count++
@{Success=$true;ScenarioCount=$count} | ConvertTo-Json
