param([Parameter(Mandatory=$true)][string] $RequestRoot, [switch] $SecureUi)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'InstallerUacNative.ps1')
. (Join-Path $PSScriptRoot 'InstallerUacObservations.ps1')
. (Join-Path $PSScriptRoot 'InstallerUacGate.ps1')
Initialize-InstallerNative
Initialize-InstallerPathObservation
[CodexInstallerNative]::RequireSystem()
Add-Type -AssemblyName System.Security
$context = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $RequestRoot 'context.json') | ConvertFrom-Json
$policy = $context.Policy
$secretPath = Join-Path $RequestRoot 'administrator.bin'
function Write-InstallerJson($Value, [string]$Path) {
    $temporary=$Path+'.tmp'
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Test-SameInstallerProcess($Expected) {
    $live=[CodexInstallerNative]::Observe($Expected.ProcessId)
    foreach($field in @('CreationFileTime','SessionId','UserSid','ImagePath','Elevated')) {
        if($live.$field -ne $Expected.$field){throw 'Process identity changed before UAC input.'}
    }
    $live
}
function Assert-InstallerSecurePrompt($Gate,[switch]$WaitForReady) {
    $readyUntil=[DateTime]::UtcNow.AddSeconds(5)
    do {
        $requester=Test-SameInstallerProcess $Gate.Requester
        $consent=Test-SameInstallerProcess $Gate.Consent
        Assert-InstallerPromptAttribution $Gate.Event $requester $consent $Gate.Root $context.Job.executable $policy.ExecutableSha256 $policy.ExecutableSha256 ([DateTime]::UtcNow)
        $foreground=[CodexInstallerNative]::SecureForeground()
        if($foreground -eq $consent.ProcessId){break}
        if(-not $WaitForReady -or [DateTime]::UtcNow -ge $readyUntil){
            $detail='unobservable'
            try{$detail=[CodexInstallerNative]::Observe($foreground).ImagePath+'; class '+[CodexInstallerNative]::ForegroundClass()}catch{}
            throw "The attributed UAC prompt is not the secure foreground (expected PID $($consent.ProcessId), observed $foreground; $detail)."
        }
        Start-Sleep -Milliseconds 100
    }while($true)
    $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,[int]$consent.ProcessId)
    $windows=@([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$condition) | Where-Object {$_.Current.ClassName -ceq 'Credential Dialog Xaml Host' -and $_.Current.ControlType -eq [Windows.Automation.ControlType]::Window})
    if($windows.Count -ne 1 -or -not $windows[0].Current.IsEnabled -or $windows[0].Current.IsOffscreen){throw 'UAC window is unknown or ambiguous.'}
    $windows[0]
}
function Get-InstallerControl($Window,[string]$Id) {
    $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,$Id)
    $matches=$Window.FindAll([Windows.Automation.TreeScope]::Descendants,$condition)
    if($matches.Count -ne 1 -or -not $matches[0].Current.IsEnabled -or $matches[0].Current.IsOffscreen){throw 'UAC control is missing, disabled or ambiguous.'}
    $matches[0]
}
function Test-InstallerControlDescendant($Node,$Ancestor) {
    $cursor=$Node
    while($cursor){if([Windows.Automation.Automation]::Compare($cursor,$Ancestor)){return $true};$cursor=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($cursor)}
    return $false
}
if($SecureUi) {
    $secret=$null;$imageLease=$null
    $receipt=[ordered]@{Success=$false;InputStarted=$false;Decision=$policy.Decision;CredentialEntered=$false;Error=$null}
    try {
        Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
        $gate=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $RequestRoot 'gate.json') | ConvertFrom-Json
        $imageLease=[CodexInstallerPathObservation]::OpenBoundFile($context.Job.executable,$policy.ExecutableSha256,2147483648)
        $window=Assert-InstallerSecurePrompt $gate -WaitForReady
        $passwordCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::IsPasswordProperty,$true)
        $passwordNodes=$window.FindAll([Windows.Automation.TreeScope]::Descendants,$passwordCondition)
        $buttonId=if($policy.Decision -ceq 'Decline'){'CancelButton'}else{'OkButton'}
        $button=Get-InstallerControl $window $buttonId
        if($button.Current.ControlType -ne [Windows.Automation.ControlType]::Button){throw 'UAC decision control is not a button.'}
        # Resolve every required pattern before the first input. Never read a UI value.
        $invoke=$button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
        if($policy.Decision -ceq 'Accept' -and $policy.InitiatingUser -ceq 'StandardUser') {
            $username=Get-InstallerControl $window 'EditField_1'
            $password=Get-InstallerControl $window 'PasswordField_2'
            if($username.Current.IsPassword -or $username.Current.ControlType -ne [Windows.Automation.ControlType]::Edit -or $username.Current.ClassName -cne 'TextBox' -or
                -not $password.Current.IsPassword -or $password.Current.ControlType -ne [Windows.Automation.ControlType]::Edit -or $password.Current.ClassName -cne 'PasswordBox' -or $passwordNodes.Count -lt 1){throw 'Credential controls are not positively identified.'}
            # Unnamed masked children must belong to the identified password field.
            foreach($node in $passwordNodes){
                if(-not(Test-InstallerControlDescendant $node $password)){throw 'An unrelated password field is present.'}
            }
            $valuePattern=$username.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
            $secret=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($secretPath),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
            if($secret.Length -ne 64){throw 'Invalid disposable credential.'}
            $null=Assert-InstallerSecurePrompt $gate
            $receipt.InputStarted=$true
            $valuePattern.SetValue($context.Identity.ElevationAccount.QualifiedName)
            $password.SetFocus()
            for($index=0;$index -lt $secret.Length;$index+=2){
                $null=Assert-InstallerSecurePrompt $gate
                $focused=[Windows.Automation.AutomationElement]::FocusedElement
                if(-not $focused -or -not $focused.Current.IsPassword -or -not(Test-InstallerControlDescendant $focused $password)){throw 'Password focus changed; further input refused.'}
                [CodexInstallerNative]::TypeSecureCharacter([BitConverter]::ToUInt16($secret,$index),$gate.Consent.ProcessId)
            }
            $receipt.CredentialEntered=$true
        } elseif($policy.Decision -ceq 'Accept' -and $passwordNodes.Count -gt 0) {throw 'Managed-administrator acceptance requires a consent-only prompt.'}
        $null=Assert-InstallerSecurePrompt $gate
        $receipt.InputStarted=$true
        $invoke.Invoke()
        $receipt.Success=$true
    } catch {
        $receipt.Error=$_.Exception.Message
        if(-not $receipt.InputStarted){
            try {
                $foreground=[CodexInstallerNative]::SecureForeground()
                $receipt['Foreground']=[CodexInstallerNative]::Observe($foreground)
                $condition=[Windows.Automation.OrCondition]::new([Windows.Automation.Condition[]]@(
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,[int]$gate.Consent.ProcessId),
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,[int]$foreground)))
                $receipt['UiMetadata']=@([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Descendants,$condition) | Select-Object -First 96 | ForEach-Object {
                    $c=$_.Current;$parent=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($_)
                    # Never read control names or values; collect only pre-input ownership and control metadata.
                    [pscustomobject]@{ProcessId=$c.ProcessId;ParentProcessId=$(if($parent){$parent.Current.ProcessId}else{0});Class=$c.ClassName;AutomationId=$c.AutomationId;Type=$c.ControlType.ProgrammaticName;Password=$c.IsPassword;Focused=$c.HasKeyboardFocus;Enabled=$c.IsEnabled;Offscreen=$c.IsOffscreen;Handle=$c.NativeWindowHandle;OwnerProcessId=[CodexInstallerNative]::WindowOwnerProcess($c.NativeWindowHandle);RootOwnerProcessId=[CodexInstallerNative]::WindowRootOwnerProcess($c.NativeWindowHandle)}
                })
            }catch{$receipt['UiMetadataError']='Unavailable'}
        }
    }
    finally {
        if($secret){[Array]::Clear($secret,0,$secret.Length)}
        if($imageLease){$imageLease.Dispose()}
        if(Test-Path -LiteralPath $secretPath){Remove-Item -LiteralPath $secretPath}
        Write-InstallerJson $receipt (Join-Path $RequestRoot 'decision.json')
    }
    exit
}

function Set-InstallerDirectoryAcl([string]$Path,[string]$Sid,[string]$Rights='ReadAndExecute') {
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
    foreach($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@($Sid,$Rights))){
        if($entry[0]){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($entry[0]),$entry[1],'ContainerInherit, ObjectInherit','None','Allow'))}
    }
    [IO.Directory]::SetAccessControl($Path,$acl)
}
function New-InstallerAccount([string]$Name,[bool]$Administrator) {
    $random=New-Object byte[] 32
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create();$rng.GetBytes($random);$rng.Dispose()
    $alphabet='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#%+-'
    $secret=[Security.SecureString]::new();$bytes=New-Object byte[] 64
    try {
        for($i=0;$i -lt 32;$i++){$character=if($i -lt 4){'Aa9!'[$i]}else{$alphabet[[int]$random[$i]%$alphabet.Length]};$secret.AppendChar($character);$bytes[$i*2]=[byte][char]$character}
        $user=New-LocalUser -Name $Name -Password $secret -AccountNeverExpires -PasswordNeverExpires
        $group=if($Administrator){'S-1-5-32-544'}else{'S-1-5-32-545'}
        Add-LocalGroupMember -SID $group -Member $user
        if($Administrator){[IO.File]::WriteAllBytes($secretPath,[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine))}
        else {
            # Disposable preparation only. Cleared before either verifier or installer is launched.
            $winlogon='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Set-ItemProperty $winlogon DefaultUserName $Name
            Set-ItemProperty $winlogon DefaultDomainName $env:COMPUTERNAME
            Set-ItemProperty $winlogon DefaultPassword ([Text.Encoding]::Unicode.GetString($bytes))
            Set-ItemProperty $winlogon AutoAdminLogon '1'
        }
        [pscustomobject]@{Name=$Name;QualifiedName=($env:COMPUTERNAME+'\'+$Name);Sid=$user.SID.Value;ProfilePath=[CodexInstallerNative]::NewProfile($user.SID.Value,$Name)}
    } finally {[Array]::Clear($random,0,$random.Length);[Array]::Clear($bytes,0,$bytes.Length);$secret.Dispose()}
}
function Assert-InstallerDeadline {
    if([DateTime]::UtcNow -ge [DateTimeOffset]::Parse($context.DeadlineUtc).UtcDateTime){throw 'Installer workflow exceeded the request deadline.'}
}
function Read-InstallerBoundJson([string]$Path) {
    $lease=[CodexInstallerPathObservation]::OpenBoundFile($Path,[NullString]::Value,1048576)
    try {$reader=[IO.StreamReader]::new($lease.Stream,[Text.Encoding]::UTF8,$true);try{$reader.ReadToEnd() | ConvertFrom-Json}finally{$reader.Dispose()}}finally{$lease.Dispose()}
}
function Invoke-InstallerVerifier([string]$Phase) {
    Assert-InstallerDeadline
    foreach($account in @($identity.Initiator,$identity.ElevationAccount)){
        $registered=(Get-ItemProperty ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$account.Sid)).ProfileImagePath
        if([Environment]::ExpandEnvironmentVariables($registered) -ine $account.ProfilePath -or (Get-LocalUser -Name $account.Name).SID.Value -cne $account.Sid){throw 'Account SID and real Windows profile binding changed.'}
    }
    $out=Join-Path $sharedRoot $Phase
    $null=New-Item -ItemType Directory -Path $out
    Set-InstallerDirectoryAcl $out $identity.Initiator.Sid 'Modify'
    $observations=@(Get-InstallerPrivilegedObservations $policy $identity)
    $identityFile=Join-Path $sharedRoot ($Phase+'-identity.json')
    Write-InstallerJson @{RequestId=$context.RequestId;Phase=$Phase;Identity=$identity;PrivilegedObservations=$observations} $identityFile
    $arguments=@($policy.Verifier.Arguments | ForEach-Object {
        [CodexInstallerNative]::Quote($_.Replace('{PAYLOAD}',$context.PayloadRoot).Replace('{PHASE}',$Phase).Replace('{IDENTITY_FILE}',$identityFile).Replace('{VERIFIER_OUTDIR}',$out))
    }) -join ' '
    $process=[CodexInstallerNative]::StartAsConsoleUser((Join-Path $context.PayloadRoot $policy.Verifier.ExecutableRelativePath),$arguments,$identity.Initiator.Sid)
    $tracked.Add($process.Identity)
    try {
        if($process.Identity.Elevated -or $process.Identity.IntegrityRid -ne 8192 -or ($policy.InitiatingUser -ceq 'StandardUser' -and $process.Identity.AdministratorGroup) -or
            ($policy.InitiatingUser -ceq 'ManagedAdministrator' -and (-not $process.Identity.AdministratorGroup -or -not $process.Identity.AdministratorDenyOnly))){throw 'Verifier did not start as the required initiating user.'}
        $limit=[DateTime]::UtcNow.AddSeconds($policy.Verifier.TimeoutSeconds)
        while(-not $process.Exited){Assert-InstallerDeadline;if([DateTime]::UtcNow -gt $limit){throw 'Verifier timed out.'};Start-Sleep -Milliseconds 100}
        if($process.ExitCode -ne 0){throw "The $Phase verifier failed to produce its observation (exit $($process.ExitCode))."}
        $json=Read-InstallerBoundJson (Join-Path $out $policy.Verifier.ResultFile)
        $value=$json
        if($policy.Verifier.JsonPointer -ne ''){foreach($segment in $policy.Verifier.JsonPointer.Substring(1).Split('/')){$key=$segment.Replace('~1','/').Replace('~0','~');if($value -is [Array]){if($key -notmatch '^(0|[1-9][0-9]*)$' -or [long]$key -ge $value.Count){throw 'Verifier JSON pointer does not exist.'};$value=$value[[int]$key]}else{if(-not $value.PSObject.Properties[$key]){throw 'Verifier JSON pointer does not exist.'};$value=$value.$key}}}
        $passed=($value | ConvertTo-Json -Depth 25 -Compress) -ceq ($policy.Verifier.EqualsJson | ConvertTo-Json -Depth 25 -Compress)
        $record=[pscustomobject]@{Phase=$Phase;CompletedUtc=[DateTime]::UtcNow.ToString('o');Process=$process.Identity;Passed=$passed;Observations=$observations;Result=$json}
        Write-InstallerJson $record (Join-Path $RequestRoot ($Phase+'.json'))
        $record
    } finally {$process.Dispose()}
}
function Update-InstallerProcessTree {
    $snapshot=@(Get-CimInstance Win32_Process)
    for($pass=0;$pass -lt 4;$pass++){
        foreach($item in $snapshot){
            if(@($tracked | Where-Object {$_.ProcessId -eq $item.ProcessId}).Count){continue}
            $parents=@($installerTree | Where-Object {$_.ProcessId -eq $item.ParentProcessId})
            if($parents.Count -ne 1){continue}
            try {
                $parent=Test-SameInstallerProcess $parents[0]
                $child=[CodexInstallerNative]::Observe($item.ProcessId)
                if($child.CreationFileTime -ge $parent.CreationFileTime -and $child.SessionId -eq $parent.SessionId){$tracked.Add($child);$installerTree.Add($child)}
            } catch { }
        }
    }
}

$result=[ordered]@{JobId=$context.RequestId;StartedUtc=[DateTime]::UtcNow.ToString('o');CompletedUtc=$null;Success=$false;HarnessSucceeded=$false;OverallSucceeded=$false;TestEvaluated=$false;TestPassed=$false;TestFailureKind=$null;TestFailureMessage=$null;FailureKind='InstallerUacFailed';Error=$null;InstallerUac=$null;Screenshots=@();Actions=@();ProcessCleanup=$null}
$evidence=[ordered]@{FormatVersion=2;RequestId=$context.RequestId;Decision=$policy.Decision;InitiatingUser=$policy.InitiatingUser;ExecutableSha256=$policy.ExecutableSha256;VerifierSha256=$policy.Verifier.ExecutableSha256;Identity=$null;Before=$null;After=$null;Prompt=$null;Input=$null;ElevatedProcess=$null;ExitCode=$null;CleanupStartedUtc=$null;CleanupSucceeded=$false;ContractProven=$false}
$tracked=[Collections.Generic.List[object]]::new()
$installerTree=[Collections.Generic.List[object]]::new()
$imageLease=$null;$verifierLease=$null;$application=$null;$ui=$null;$trace=$null;$restarting=$false
try {
    if($context.Phase -ceq 'Prepare' -and $policy.InitiatingUser -ceq 'StandardUser'){
        $suffix=([Guid]::NewGuid().ToString('N')).Substring(0,10)
        $admin=New-InstallerAccount ('CIa'+$suffix) $true
        $standard=New-InstallerAccount ('CIs'+$suffix) $false
        New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' DisableAutomaticRestartSignOn -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' EnableFirstLogonAnimation -Value 0 -PropertyType DWord -Force | Out-Null
        $oobe='HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
        $null=New-Item $oobe -Force;New-ItemProperty $oobe DisablePrivacyExperience -Value 1 -PropertyType DWord -Force | Out-Null
        $context | Add-Member -NotePropertyName Identity -NotePropertyValue ([pscustomobject]@{Initiator=$standard;ElevationAccount=$admin})
        $context.Phase='Run'
        Write-InstallerJson $context (Join-Path $RequestRoot 'context.json')
        $restarting=$true
        Restart-Computer -Force
        exit
    }
    $marker=Join-Path $RequestRoot 'launch-once'
    $once=[IO.File]::Open($marker,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$once.Dispose()
    $limit=[DateTime]::UtcNow.AddSeconds(120)
    do {
        Assert-InstallerDeadline
        $consoleFlags=-1
        try{$consoleSid=[CodexInstallerNative]::ConsoleSid();$consoleFlags=[CodexInstallerNative]::ConsoleSessionFlags()}catch{$consoleSid=$null}
        $desktopReady=$false
        foreach($explorer in @(Get-Process explorer -ErrorAction SilentlyContinue)){try{$explorerToken=[CodexInstallerNative]::Observe($explorer.Id);if($explorerToken.UserSid -ceq $consoleSid -and $explorerToken.SessionId -eq [int][CodexInstallerNative]::WTSGetActiveConsoleSessionId()){$desktopReady=$true}}catch{}}
        if($desktopReady -and $consoleFlags -eq 1 -and $consoleSid -and ($policy.InitiatingUser -cne 'StandardUser' -or $consoleSid -ceq $context.Identity.Initiator.Sid)){break}
        Start-Sleep -Milliseconds 500
    }while([DateTime]::UtcNow -lt $limit)
    if(-not $consoleSid -or -not $desktopReady -or $consoleFlags -ne 1){throw "No unlocked interactive console desktop became available (session flags $consoleFlags)."}
    if($policy.InitiatingUser -ceq 'StandardUser'){
        if($consoleSid -cne $context.Identity.Initiator.Sid){throw 'The disposable standard account is not the console user.'}
        $identity=$context.Identity
        $winlogon='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $winlogon AutoAdminLogon '0'
        Remove-ItemProperty $winlogon DefaultPassword -ErrorAction SilentlyContinue
    }else{
        $user=Get-LocalUser -SID $consoleSid
        $profile=(Get-ItemProperty ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$consoleSid)).ProfileImagePath
        $account=[pscustomobject]@{Name=$user.Name;QualifiedName=($env:COMPUTERNAME+'\'+$user.Name);Sid=$consoleSid;ProfilePath=$profile}
        $identity=[pscustomobject]@{Initiator=$account;ElevationAccount=$account}
        $context | Add-Member -NotePropertyName Identity -NotePropertyValue $identity
        Write-InstallerJson $context (Join-Path $RequestRoot 'context.json')
    }
    $evidence.Identity=$identity
    $evidence['InitialSessionFlags']=$consoleFlags
    $systemPolicy='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-ItemProperty $systemPolicy PromptOnSecureDesktop 1
    Set-ItemProperty $systemPolicy ConsentPromptBehaviorAdmin 2
    Set-ItemProperty $systemPolicy ConsentPromptBehaviorUser 1
    $credUi='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\CredUI'
    $null=New-Item $credUi -Force;New-ItemProperty $credUi EnumerateAdministrators -Value 0 -PropertyType DWord -Force | Out-Null
    $reveal='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredUI'
    $null=New-Item $reveal -Force;New-ItemProperty $reveal DisablePasswordReveal -Value 1 -PropertyType DWord -Force | Out-Null
    $sharedRoot=Join-Path $context.Outbox 'verifier'
    $null=New-Item -ItemType Directory -Path $sharedRoot -Force
    Set-InstallerDirectoryAcl $context.Outbox $identity.Initiator.Sid
    Set-InstallerDirectoryAcl $sharedRoot $identity.Initiator.Sid
    $imageLease=[CodexInstallerPathObservation]::OpenBoundFile($context.Job.executable,$policy.ExecutableSha256,2147483648)
    $verifierLease=[CodexInstallerPathObservation]::OpenBoundFile((Join-Path $context.PayloadRoot $policy.Verifier.ExecutableRelativePath),$policy.Verifier.ExecutableSha256,2147483648)
    $evidence.Before=Invoke-InstallerVerifier 'Before'
    $trace='CodexInstaller-'+$context.RequestId
    $etl=Join-Path $RequestRoot 'uac.etl'
    & "$env:SystemRoot\System32\logman.exe" start $trace -p '{d37e7910-79c8-57c4-da77-52bb646364cd}' 0xFFFFFFFFFFFFFFFF 5 -o $etl -ets | Out-Null
    if($LASTEXITCODE -ne 0){throw 'UAC attribution trace could not start.'}
    $application=[CodexInstallerNative]::StartAsConsoleUser($context.Job.executable,$context.Job.arguments,$identity.Initiator.Sid)
    $root=$application.Identity;$tracked.Add($root);$installerTree.Add($root)
    if($root.Elevated -or $root.IntegrityRid -ne 8192 -or ($policy.InitiatingUser -ceq 'StandardUser' -and $root.AdministratorGroup) -or
        ($policy.InitiatingUser -ceq 'ManagedAdministrator' -and (-not $root.AdministratorGroup -or -not $root.AdministratorDenyOnly))){throw 'Installer initiating token does not satisfy the requested account mode.'}
    $limit=[DateTime]::UtcNow.AddSeconds($policy.PromptTimeoutSeconds)
    $prompts=@()
    do {
        Assert-InstallerDeadline;Update-InstallerProcessTree
        $prompts=@(Get-Process consent -ErrorAction SilentlyContinue | Where-Object {$_.SessionId -eq $root.SessionId})
        if($prompts.Count -gt 0){break}
        if($application.Exited){throw 'Installer exited without the declared UAC prompt.'}
        Start-Sleep -Milliseconds 100
    }while([DateTime]::UtcNow -lt $limit)
    if($prompts.Count -ne 1){throw 'No unique UAC prompt appeared.'}
    Start-Sleep -Milliseconds 500
    Update-InstallerProcessTree
    & "$env:SystemRoot\System32\logman.exe" stop $trace -ets | Out-Null
    if($LASTEXITCODE -ne 0){throw 'UAC attribution trace could not be finalized.'};$trace=$null
    $events=@(Get-WinEvent -Path $etl -Oldest | Where-Object {$_.ProviderName -ceq 'Microsoft-Antimalware-UacScan' -and $_.Id -eq 1201} | ForEach-Object {
        [xml]$xml=$_.ToXml();$fields=@{};foreach($item in $xml.Event.EventData.Data){$fields[$item.Name]=[string]$item.InnerText}
        [pscustomobject]@{Provider=$_.ProviderName;Id=$_.Id;TimeUtc=$_.TimeCreated.ToUniversalTime().ToString('o');RequestorProcessId=[int]$fields.requestorProcessId;EmitterProcessId=[int]$xml.Event.System.Execution.ProcessID;ApplicationName=$fields.exeApplicationName;RequestType=[int]$fields.uacRequestType;AutoElevate=$fields.autoElevateRequest}
    })
    if($events.Count -ne 1){throw 'UAC attribution is missing or ambiguous.'}
    $event=$events[0]
    $requesters=@($installerTree | Where-Object {$_.ProcessId -eq $event.RequestorProcessId})
    if($requesters.Count -ne 1){throw 'The UAC requester is not an observed descendant of the original installer.'}
    $requester=Test-SameInstallerProcess $requesters[0]
    $consent=[CodexInstallerNative]::Observe($prompts[0].Id)
    $signature=Get-AuthenticodeSignature -LiteralPath $consent.ImagePath
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft'){throw 'Consent executable signature is unverified.'}
    Assert-InstallerPromptAttribution $event $requester $consent $root $context.Job.executable $policy.ExecutableSha256 $policy.ExecutableSha256 ([DateTime]::UtcNow)
    $gate=[pscustomobject]@{Event=$event;Requester=$requester;Consent=$consent;Root=$root}
    $evidence.Prompt=$gate
    Write-InstallerJson $gate (Join-Path $RequestRoot 'gate.json')
    $ui=[CodexInstallerNative]::StartOnSecureDesktop($PSCommandPath,$RequestRoot)
    $uiLimit=[DateTime]::UtcNow.AddSeconds(25)
    while(-not $ui.Exited){Assert-InstallerDeadline;if([DateTime]::UtcNow -gt $uiLimit){throw 'Secure UAC handler timed out.'};Start-Sleep -Milliseconds 100}
    $decision=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $RequestRoot 'decision.json') | ConvertFrom-Json
    $evidence.Input=$decision
    if(-not $decision.Success){throw "Secure UAC handler refused: $($decision.Error)"}
    if(Test-Path -LiteralPath $secretPath){Remove-Item -LiteralPath $secretPath}
    $high=[Collections.Generic.Dictionary[int,object]]::new()
    do {
        Assert-InstallerDeadline;Update-InstallerProcessTree
        foreach($candidate in @(Get-CimInstance Win32_Process -Filter ("Name='"+[IO.Path]::GetFileName($context.Job.executable).Replace("'","''")+"'"))){
            try{$observed=[CodexInstallerNative]::Observe($candidate.ProcessId)}catch{continue}
            if($observed.ImagePath -ieq $context.Job.executable -and $observed.SessionId -eq $root.SessionId -and $observed.CreationFileTime -gt $root.CreationFileTime -and $observed.Elevated){
                if($observed.UserSid -cne $identity.ElevationAccount.Sid -or $observed.IntegrityRid -lt 12288){throw 'Elevated installer has the wrong administrator identity.'}
                if(-not $high.ContainsKey($observed.ProcessId)){$high.Add($observed.ProcessId,$observed);$tracked.Add($observed);$installerTree.Add($observed)}
            }
        }
        if($high.Count -gt 1 -or ($policy.Decision -ceq 'Decline' -and $high.Count -gt 0)){throw 'Unexpected elevated installer instance.'}
        $highRunning=$false
        foreach($entry in $high.Values){if([CodexInstallerNative]::IsAlive($entry)){$highRunning=$true}}
        if($application.Exited -and -not $highRunning){break}
        Start-Sleep -Milliseconds 100
    }while($true)
    if($policy.Decision -ceq 'Accept' -and $high.Count -ne 1){throw 'No attributed elevated child was observed.'}
    $evidence.ElevatedProcess=@($high.Values)
    $evidence.ExitCode=$application.ExitCode
    $evidence.After=Invoke-InstallerVerifier 'After'
    $result.TestPassed=$evidence.Before.Passed -and $evidence.After.Passed -and $evidence.ExitCode -eq $policy.ExpectedExitCode
    $result.TestEvaluated=$true
    $result.Success=$true;$result.FailureKind=$null
} catch {$result.Error=$_.Exception.Message}
finally {
    if(-not $restarting){
        $clean=$true
        if($trace){& "$env:SystemRoot\System32\logman.exe" stop $trace -ets 2>$null | Out-Null}
        if($ui){try{if(-not $ui.Exited){[CodexInstallerNative]::StopExact($ui.Identity)}}catch{$clean=$false};$ui.Dispose()}
        if(Test-Path -LiteralPath $secretPath){Remove-Item -LiteralPath $secretPath}
        $evidence.CleanupStartedUtc=[DateTime]::UtcNow.ToString('o')
        for($i=$tracked.Count-1;$i -ge 0;$i--){try{[CodexInstallerNative]::StopExact($tracked[$i])}catch{$clean=$false}}
        if($application){$application.Dispose()}
        if($verifierLease){$verifierLease.Dispose()};if($imageLease){$imageLease.Dispose()}
        $evidence.CleanupSucceeded=$clean
        if(-not $clean){$result.FailureKind='InstallerCleanupFailed';$result.Error='Privileged process cleanup was incomplete.'}
        $evidence.ContractProven=$result.Success -and $clean -and $null -ne $evidence.After
        $result.Success=$evidence.ContractProven
        $result.HarnessSucceeded=$result.Success
        $result.OverallSucceeded=$result.Success -and (-not $result.TestEvaluated -or $result.TestPassed)
        $result.CompletedUtc=[DateTime]::UtcNow.ToString('o')
        if($result.TestEvaluated -and -not $result.TestPassed){$result.TestFailureKind='InstallerVerification';$result.TestFailureMessage='Before/After observation or declared installer exit code did not match.'}
        $result.InstallerUac=$evidence
        $result.ProcessCleanup=@{Success=$clean;VerificationSucceeded=$clean;Attempted=$true;Privileged=$true;RootProcessId=$(if($application){$application.Identity.ProcessId}else{$null});ObservedProcessIds=@($tracked | ForEach-Object {$_.ProcessId})}
        # Export only selected non-secret records; private ETL, credentials and context never enter evidence.
        $null=New-Item -ItemType Directory -Path $context.Outbox -Force
        Write-InstallerJson $result (Join-Path $context.Outbox 'result.json')
        Write-InstallerJson $result (Join-Path $RequestRoot 'result.json')
        Write-InstallerJson @{Complete=$true;Success=$result.Success} (Join-Path $RequestRoot 'complete.json')
    }
}
