function Assert-InstallerPromptAttribution {
    param($Event, $Requester, $Consent, $Root, [string] $ImagePath, [string] $ImageSha256, [string] $ExpectedSha256, [DateTime] $NowUtc)
    if ($ImageSha256 -cne $ExpectedSha256 -or $Event.Provider -cne 'Microsoft-Antimalware-UacScan' -or $Event.Id -ne 1201 -or
        $Event.RequestorProcessId -ne $Requester.ProcessId -or $Event.EmitterProcessId -ne $Consent.ProcessId -or
        $Event.ApplicationName -ine $ImagePath -or $Event.RequestType -ne 0 -or $Event.AutoElevate -ne 'false') { throw 'UAC event does not identify the bound executable and prompt.' }
    $time = [DateTimeOffset]::Parse($Event.TimeUtc).UtcDateTime
    if ($time -lt [DateTime]::FromFileTimeUtc($Root.CreationFileTime) -or $time -lt [DateTime]::FromFileTimeUtc($Requester.CreationFileTime) -or
        $time -lt [DateTime]::FromFileTimeUtc($Consent.CreationFileTime) -or $time -gt $NowUtc -or ($NowUtc-$time).TotalSeconds -gt 30) { throw 'UAC event is stale or predates its processes.' }
    if ($Requester.SessionId -ne $Root.SessionId -or $Requester.UserSid -cne $Root.UserSid -or $Requester.Elevated -or
        $Root.Elevated -or $Root.IntegrityRid -ne 8192 -or $Consent.SessionId -ne $Root.SessionId -or $Consent.UserSid -cne 'S-1-5-18' -or
        $Consent.ImagePath -ine ($env:SystemRoot+'\System32\consent.exe')) { throw 'UAC process tokens or session are inconsistent.' }
}
function Resolve-InstallerConsentActivationWindow($Windows,[int]$ConsentProcessId) {
    $matches=@($Windows | Where-Object {$_.ProcessId -eq $ConsentProcessId -and $_.Desktop -ceq 'Default' -and $_.Class -ceq '$$$Secure UAP Dummy Window Class For Interim Dialog' -and $_.Visible -is [bool] -and $_.Visible -and $_.Handle -gt 0})
    if($matches.Count -ne 1){throw 'Deferred UAC activation window is missing or ambiguous.'}
    $matches[0]
}
function Get-InstallerPromptDeadline([DateTime]$EstablishedUtc,[int]$TimeoutSeconds,[DateTime]$RequestDeadlineUtc,[DateTime]$NowUtc) {
    if($TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 600 -or $EstablishedUtc -gt $NowUtc){throw 'Invalid UAC prompt lifetime.'}
    $deadline=$EstablishedUtc.AddSeconds($TimeoutSeconds)
    if($RequestDeadlineUtc -lt $deadline){$deadline=$RequestDeadlineUtc}
    if($NowUtc -ge $deadline){throw 'Bound UAC prompt deadline expired.'}
    $deadline
}
function ConvertTo-InstallerSecureProgress($Value) {
    $phases=@('Initializing','InspectingPrompt','BindingImage','Activating','CheckingControls','EnteringCredentials','InvokingDecision','DecisionReturned','FailureDiagnostics')
    $rows=@($Value);$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if($rows.Count -gt $phases.Count){throw 'Too many secure UI checkpoints.'}
    foreach($row in $rows){
        if($row.Phase -cnotin $phases -or -not $seen.Add([string]$row.Phase)){throw 'Invalid secure UI checkpoint phase.'}
        [pscustomobject]@{Phase=[string]$row.Phase;AtUtc=[DateTimeOffset]::Parse($row.AtUtc).UtcDateTime.ToString('o')}
    }
}
function ConvertTo-InstallerControllerStatus($Value) {
    if($null -eq $Value){return $null}
    $phases=@('Initializing','PreparingAccounts','Rebooting','WaitingForDesktop','BindingFiles','WaitingForInputDesktop','VerifyingBefore','WaitingForPrompt','BindingPrompt','HandlingPrompt','WaitingForInstallerExit','VerifyingAfter','CleaningUp','Completed')
    if($Value.Phase -cnotin $phases -or $Value.ProcessId -lt 1){throw 'Invalid installer controller status.'}
    $result=[ordered]@{Phase=[string]$Value.Phase;AtUtc=[DateTimeOffset]::Parse($Value.AtUtc).UtcDateTime.ToString('o');DeadlineUtc=[DateTimeOffset]::Parse($Value.DeadlineUtc).UtcDateTime.ToString('o');ProcessId=[int]$Value.ProcessId;ProcessStartUtc=[DateTimeOffset]::Parse($Value.ProcessStartUtc).UtcDateTime.ToString('o')}
    foreach($name in @('BeforePassed','AfterPassed')){
        $valueProperty=$Value.PSObject.Properties[$name]
        $field=if($valueProperty){$valueProperty.Value}else{$null}
        if($null -ne $field -and $field -isnot [bool]){throw 'Invalid installer observation status.'}
        $result[$name]=$field
    }
    foreach($name in @('ElevatedProcessId','ElevatedCreationFileTime','ExitCode')){
        $valueProperty=$Value.PSObject.Properties[$name]
        $result[$name]=if($valueProperty -and $null -ne $valueProperty.Value){[long]$valueProperty.Value}else{$null}
    }
    [pscustomobject]$result
}
function ConvertTo-InstallerStatusSnapshot($Value) {
    if($Value.Complete -isnot [bool] -or $Value.TaskRan -isnot [bool] -or $Value.TaskState -cnotin @('Unknown','Disabled','Queued','Ready','Running') -or
        ($null -ne $Value.ControllerAlive -and $Value.ControllerAlive -isnot [bool])){throw 'Invalid installer supervision snapshot.'}
    $inputReceipt=$null
    if($null -ne $Value.Input){
        if($Value.Input.Decision -cnotin @('Accept','Decline')){throw 'Invalid installer decision receipt.'}
        $inputReceipt=[ordered]@{Decision=[string]$Value.Input.Decision}
        foreach($name in @('Success','InputStarted','CredentialEntered')){
            if($Value.Input.$name -isnot [bool]){throw 'Invalid installer decision outcome.'}
            $inputReceipt[$name]=$Value.Input.$name
        }
    }
    [pscustomobject]@{Complete=$Value.Complete;Controller=ConvertTo-InstallerControllerStatus $Value.Controller;ControllerAlive=$Value.ControllerAlive;TaskRan=$Value.TaskRan;TaskState=[string]$Value.TaskState;TaskResult=[long]$Value.TaskResult;SecureUiProgress=@(if($null -ne $Value.SecureUiProgress){ConvertTo-InstallerSecureProgress $Value.SecureUiProgress});Input=$inputReceipt}
}
function Get-InstallerSupervisionFailure($Status,$Previous,[DateTime]$NowUtc,[DateTime]$RequestDeadlineUtc) {
    if($Status.Complete){return $null}
    if($Status.Controller){
        $current=$Status.Controller
        $deadline=[DateTimeOffset]::Parse($current.DeadlineUtc).UtcDateTime
        if($Previous -and $Previous.Controller){
            $prior=$Previous.Controller
            if($current.ProcessId -eq $prior.ProcessId -and $current.ProcessStartUtc -ceq $prior.ProcessStartUtc -and $current.Phase -ceq $prior.Phase -and
                ($current.DeadlineUtc -cne $prior.DeadlineUtc -or $current.AtUtc -cne $prior.AtUtc)){return 'InstallerControllerDeadlineChanged'}
        }
        if($deadline -gt $RequestDeadlineUtc){$deadline=$RequestDeadlineUtc}
        if($NowUtc -ge $deadline){return 'InstallerControllerPhaseTimeout'}
        if($Status.ControllerAlive -eq $false -and $current.Phase -cne 'Rebooting'){return 'InstallerControllerExited'}
    } elseif($Status.TaskRan -and $Status.TaskState -ceq 'Ready'){return 'InstallerControllerExited'}
    $null
}
function Read-InstallerStatusJson([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    for($ancestor=$Path;$ancestor;$ancestor=Split-Path -Parent $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Installer status traverses a reparse point.'}}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $bytes=New-Object byte[] 1048577;$count=0
        while($count -lt $bytes.Length){$read=$stream.Read($bytes,$count,$bytes.Length-$count);if($read -eq 0){break};$count+=$read}
        if($count -gt 1048576){throw 'Installer status exceeds its size bound.'}
        [Text.Encoding]::UTF8.GetString($bytes,0,$count) | ConvertFrom-Json
    }finally{$stream.Dispose()}
}
function Get-InstallerStatusSnapshot([string]$Root,[string]$Outbox) {
    $task=Get-ScheduledTask -TaskName ('CodexInstaller-'+(Split-Path $Root -Leaf)) -ErrorAction Stop
    $taskInfo=$task | Get-ScheduledTaskInfo -ErrorAction Stop
    $controller=ConvertTo-InstallerControllerStatus (Read-InstallerStatusJson (Join-Path $Outbox 'installer-progress.json'))
    $alive=$null
    if($controller){
        $process=Get-Process -Id $controller.ProcessId -ErrorAction SilentlyContinue
        $alive=[bool]($process -and $process.StartTime.ToUniversalTime().ToString('o') -ceq $controller.ProcessStartUtc -and -not $process.HasExited)
        if(-not $alive){
            # Preparation may publish Rebooting and exit between the first read and this probe.
            $controller=ConvertTo-InstallerControllerStatus (Read-InstallerStatusJson (Join-Path $Outbox 'installer-progress.json'))
            if($controller){$process=Get-Process -Id $controller.ProcessId -ErrorAction SilentlyContinue;$alive=[bool]($process -and $process.StartTime.ToUniversalTime().ToString('o') -ceq $controller.ProcessStartUtc -and -not $process.HasExited)}
        }
    }
    $progress=Read-InstallerStatusJson (Join-Path $Outbox 'installer-secure-progress.json')
    $decision=Read-InstallerStatusJson (Join-Path $Outbox 'installer-decision.json')
    # Read completion last: an exited task may have published it during this probe.
    $complete=Read-InstallerStatusJson (Join-Path $Root 'complete.json')
    if($complete -and $complete.Complete -isnot [bool]){throw 'Invalid installer completion marker.'}
    ConvertTo-InstallerStatusSnapshot ([pscustomobject]@{Complete=[bool]($complete -and $complete.Complete);Controller=$controller;ControllerAlive=$alive;TaskRan=($taskInfo.LastRunTime.Year -gt 2000);TaskState=[string]$task.State;TaskResult=[long]$taskInfo.LastTaskResult;SecureUiProgress=$progress;Input=$decision})
}
