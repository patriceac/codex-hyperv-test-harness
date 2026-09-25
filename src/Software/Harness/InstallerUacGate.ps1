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
