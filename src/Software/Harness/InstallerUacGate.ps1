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
