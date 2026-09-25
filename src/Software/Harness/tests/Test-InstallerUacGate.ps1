$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\InstallerUacGate.ps1')
$now=[DateTime]::UtcNow
$root=[pscustomobject]@{ProcessId=100;SessionId=1;UserSid='S-1-5-21-1-2-3-1001';Elevated=$false;IntegrityRid=8192;CreationFileTime=$now.AddSeconds(-3).ToFileTimeUtc()}
$requester=$root
$consent=[pscustomobject]@{ProcessId=200;SessionId=1;UserSid='S-1-5-18';ImagePath=($env:SystemRoot+'\System32\consent.exe');CreationFileTime=$now.AddSeconds(-2).ToFileTimeUtc()}
$template=@{Provider='Microsoft-Antimalware-UacScan';Id=1201;RequestorProcessId=100;EmitterProcessId=200;ApplicationName='D:\Payload\setup.exe';RequestType=0;AutoElevate='false';TimeUtc=$now.AddSeconds(-1).ToString('o')}
Assert-InstallerPromptAttribution ([pscustomobject]$template) $requester $consent $root 'D:\Payload\setup.exe' ('A'*64) ('A'*64) $now
$count=1
foreach($change in @(@('RequestorProcessId',101),@('EmitterProcessId',201),@('ApplicationName','D:\unrelated.exe'),@('Provider','Untrusted'),@('AutoElevate','true'),@('TimeUtc',$now.AddSeconds(-60).ToString('o')),@('TimeUtc',$now.AddSeconds(1).ToString('o')),@('TimeUtc',$now.AddSeconds(-4).ToString('o')))){
    $event=$template | ConvertTo-Json | ConvertFrom-Json;$event.($change[0])=$change[1]
    $rejected=$false
    try{Assert-InstallerPromptAttribution $event $requester $consent $root 'D:\Payload\setup.exe' ('A'*64) ('A'*64) $now}catch{$rejected=$true}
    if(-not $rejected){throw "Prompt gate accepted a changed $($change[0])."};$count++
}
$rejected=$false
try{Assert-InstallerPromptAttribution ([pscustomobject]$template) $requester $consent $root 'D:\Payload\setup.exe' ('B'*64) ('A'*64) $now}catch{$rejected=$true}
if(-not $rejected){throw 'Prompt gate accepted a wrong image hash.'};$count++
foreach($case in @(
    @{Established=0;Now=45;Outer=300;Expected=120},
    @{Established=0;Now=59.999;Outer=60;Expected=60},
    @{Established=0;Now=60;Outer=60;Expected=$null},
    @{Established=0;Now=120;Outer=300;Expected=$null},
    @{Established=1;Now=0;Outer=300;Expected=$null}
)){
    $deadline=$null;$rejected=$false
    try{$deadline=Get-InstallerPromptDeadline $now.AddSeconds($case.Established) 120 $now.AddSeconds($case.Outer) $now.AddSeconds($case.Now)}catch{$rejected=$true}
    if($null -eq $case.Expected){if(-not $rejected){throw 'An expired or future prompt lifetime was accepted.'}}
    elseif($rejected -or $deadline -ne $now.AddSeconds($case.Expected)){throw 'The prompt lifetime was renewed or exceeded its request deadline.'}
    $count++
}
$interim=[pscustomobject]@{Handle=66210;ProcessId=200;Desktop='Default';Class='$$$Secure UAP Dummy Window Class For Interim Dialog';Visible=$true}
$ime=[pscustomobject]@{Handle=66214;ProcessId=200;Desktop='Default';Class='IME';Visible=$false}
if((Resolve-InstallerConsentActivationWindow @($interim,$ime) 200).Handle -ne 66210){throw 'The attributed interim window was not selected.'};$count++
foreach($change in @(@('ProcessId',201),@('Desktop','Winlogon'),@('Class','Unrelated'),@('Visible',$false))){
    $window=$interim | ConvertTo-Json | ConvertFrom-Json;$window.($change[0])=$change[1];$rejected=$false
    try{Resolve-InstallerConsentActivationWindow @($window,$ime) 200}catch{$rejected=$true}
    if(-not $rejected){throw "Prompt activation accepted a changed $($change[0])."};$count++
}
$rejected=$false
try{Resolve-InstallerConsentActivationWindow @($interim,$interim) 200}catch{$rejected=$true}
if(-not $rejected){throw 'Prompt activation accepted ambiguous windows.'};$count++
$controller=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\GuestInstallerUac.ps1'),[ref]$null,[ref]$null)
[void](Add-Type -TypeDefinition 'public static class InstallerIdentityTest { public static object Value; public static object Observe(int pid) { return Value; } }')
$identityFunction=$controller.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-SameInstallerProcess'},$true)
& {
    . ([scriptblock]::Create($identityFunction.Extent.Text.Replace('[CodexInstallerNative]','[InstallerIdentityTest]')))
    $expected=[pscustomobject]@{ProcessId=200;CreationFileTime=123;SessionId=1;UserSid='S-1-5-18';ImagePath='C:\Windows\System32\consent.exe';Elevated=$true}
    [InstallerIdentityTest]::Value=$expected
    $null=Test-SameInstallerProcess $expected
    foreach($change in @(@('CreationFileTime',124),@('SessionId',2),@('UserSid','S-1-5-19'),@('ImagePath','C:\unrelated.exe'))){
        $live=$expected | ConvertTo-Json | ConvertFrom-Json;$live.($change[0])=$change[1]
        [InstallerIdentityTest]::Value=$live;$rejected=$false
        try{$null=Test-SameInstallerProcess $expected}catch{$rejected=$true}
        if(-not $rejected){throw 'A changed live process identity was accepted.'}
    }
}
$count++
$parser=$controller.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'ForEach-Object' -and $node.Extent.Text.Contains('$xml.Event.EventData.Data')},$true).CommandElements[-1].ScriptBlock.GetScriptBlock()
$nativeEvent=[pscustomobject]@{ProviderName='Microsoft-Antimalware-UacScan';Id=1201;TimeCreated=$now}
$nativeEvent | Add-Member ScriptMethod ToXml {'<Event><System><Execution ProcessID="200" /></System><EventData><Data Name="requestorProcessId">100</Data><Data Name="exeApplicationName">D:\Payload\setup.exe</Data><Data Name="uacRequestType">0</Data><Data Name="autoElevateRequest">false</Data><Data Name="emptyField" /></EventData></Event>'}
$parsed=$nativeEvent | ForEach-Object $parser
Assert-InstallerPromptAttribution $parsed $requester $consent $root 'D:\Payload\setup.exe' ('A'*64) ('A'*64) $now
$count++
Add-Type -AssemblyName UIAutomationTypes
$windowFilter=$controller.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Where-Object' -and $node.Extent.Text.Contains('Credential Dialog Xaml Host')},$true).CommandElements[-1].ScriptBlock.GetScriptBlock()
$dialog=[pscustomobject]@{Current=[pscustomobject]@{ClassName='Credential Dialog Xaml Host';ControlType=[Windows.Automation.ControlType]::Window}}
$background=[pscustomobject]@{Current=[pscustomobject]@{ClassName='$$$Secure UAP Background Window Class';ControlType=[Windows.Automation.ControlType]::Pane}}
$selected=@(@($dialog,$background) | Where-Object $windowFilter)
if($selected.Count -ne 1 -or -not [object]::ReferenceEquals($selected[0],$dialog)){throw 'The consent background pane was confused with its credential dialog.'}
$count++
[void](Add-Type -TypeDefinition 'public static class InstallerForegroundTest { public static System.Collections.Generic.Queue<int> Values = new System.Collections.Generic.Queue<int>(); public static int SecureForeground() { int value=Values.Dequeue(); if(value<0)throw new System.InvalidOperationException("Secure input desktop is not active."); return value; } }')
$promptFunction=$controller.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-InstallerSecurePrompt'},$true)
$waitLoop=$promptFunction.Find({param($node) $node -is [Management.Automation.Language.DoWhileStatementAst]},$true)
$wait=[scriptblock]::Create($waitLoop.Extent.Text.Replace('[CodexInstallerNative]','[InstallerForegroundTest]'))
function Test-SameInstallerProcess($Expected){$script:liveChecks++;$Expected}
$liveFunction=$controller.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-InstallerLivePrompt'},$true)
. ([scriptblock]::Create($liveFunction.Extent.Text))
$gate=[pscustomobject]@{Event=[pscustomobject]$template;Requester=$requester;Consent=$consent;Root=$root;EstablishedUtc=$now.ToString('o');DeadlineUtc=$now.AddSeconds(120).ToString('o')}
$context=[pscustomobject]@{Job=[pscustomobject]@{executable='D:\Payload\setup.exe'};DeadlineUtc=$now.AddSeconds(300).ToString('o')}
$policy=[pscustomobject]@{ExecutableSha256=('A'*64);PromptTimeoutSeconds=120}
& {
    $past=$now.AddSeconds(-40)
    $oldGate=$gate | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $oldGate.EstablishedUtc=$past.ToString('o');$oldGate.DeadlineUtc=$past.AddSeconds(120).ToString('o')
    $oldGate.Root.CreationFileTime=$past.AddSeconds(-3).ToFileTimeUtc()
    $oldGate.Requester.CreationFileTime=$oldGate.Root.CreationFileTime
    $oldGate.Consent.CreationFileTime=$past.AddSeconds(-2).ToFileTimeUtc()
    $oldGate.Event.TimeUtc=$past.AddSeconds(-1).ToString('o');$script:liveChecks=0
    $null=Assert-InstallerLivePrompt $oldGate
    if($script:liveChecks -ne 2){throw 'Continuing a fresh-established prompt skipped live process checks.'}
    $oldGate.DeadlineUtc=$now.AddSeconds(120).ToString('o');$rejected=$false
    try{$null=Assert-InstallerLivePrompt $oldGate}catch{$rejected=$true}
    if(-not $rejected){throw 'A prompt binding could renew its deadline.'}
}
$count++
foreach($case in @(
    @{Wait=$true;Expired=$false;Values=@(0,200);Rejected=$false;Checks=4},
    @{Wait=$true;Expired=$false;Values=@(-1,200);Rejected=$false;Checks=4},
    @{Wait=$false;Expired=$false;Values=@(-1,200);Rejected=$true;Checks=2},
    @{Wait=$false;Expired=$false;Values=@(0,200);Rejected=$true;Checks=2},
    @{Wait=$true;Expired=$true;Values=@(0);Rejected=$true;Checks=2}
)){
    [InstallerForegroundTest]::Values.Clear()
    foreach($value in $case.Values){[InstallerForegroundTest]::Values.Enqueue($value)}
    $WaitForReady=$case.Wait
    $readyUntil=[DateTime]::UtcNow.AddSeconds($(if($case.Expired){-1}else{1}))
    $script:liveChecks=0;$message=$null
    try{& $wait}catch{$message=$_.Exception.Message}
    if($case.Rejected){if($message -notlike 'The attributed UAC prompt is not the secure foreground*' -and $message -notlike '*Secure input desktop is not active.*'){throw 'The foreground gate did not reject the missing prompt.'}}
    elseif($message){throw $message}
    if($script:liveChecks -ne $case.Checks){throw 'The readiness wait did not revalidate process identities or immediate input checks waited.'}
    $count++
}
$controlFunction=$controller.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InstallerControl'},$true)
$controlGuards=@($controlFunction.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst]},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"
$checkControls=[scriptblock]::Create($controlGuards.Replace('[Windows.Automation.Automation]::Compare','[object]::ReferenceEquals'))
$ExpectedControl=[pscustomobject]@{Current=[pscustomobject]@{IsEnabled=$true;IsOffscreen=$false}}
foreach($case in @('Same','Replaced','Duplicate','Disabled','Offscreen')){
    $ExpectedControl.Current.IsEnabled=$true;$ExpectedControl.Current.IsOffscreen=$false
    $matches=@($ExpectedControl)
    if($case -eq 'Replaced'){$matches=@([pscustomobject]@{Current=[pscustomobject]@{IsEnabled=$true;IsOffscreen=$false}})}
    if($case -eq 'Duplicate'){$matches=@($ExpectedControl,$ExpectedControl)}
    if($case -eq 'Disabled'){$ExpectedControl.Current.IsEnabled=$false}
    if($case -eq 'Offscreen'){$ExpectedControl.Current.IsOffscreen=$true}
    $inputReached=$false
    try{& $checkControls;$inputReached=$true}catch{}
    if($inputReached -ne ($case -eq 'Same')){throw 'Changed or unavailable controls did not stop input.'}
}
$count++
$readEvidence=$controller.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-InstallerSecureUiEvidence'},$true)
& {
    . ([scriptblock]::Create($readEvidence.Extent.Text))
    $RequestRoot='D:\synthetic-installer-request';$files=@{}
    function Test-Path([string]$LiteralPath){$files.ContainsKey($LiteralPath)}
    function Read-InstallerBoundJson([string]$Path){$files[$Path]}
    foreach($phase in @('Initializing','EnteringCredentials','DecisionReturned')){
        $files[(Join-Path $RequestRoot 'secure-progress.json')]=[pscustomobject]@{Phase=$phase;AtUtc=$now.ToString('o');Secret='synthetic-do-not-export';InputStarted=$false}
        $evidence=[ordered]@{Input=$null;SecureUiProgress=$null;ContractProven=$false}
        Read-InstallerSecureUiEvidence
        if($null -ne $evidence.Input -or $evidence.ContractProven){throw 'A checkpoint invented a decision or input outcome.'}
        if(($evidence.SecureUiProgress[0].PSObject.Properties.Name -join ',') -cne 'Phase,AtUtc'){throw 'Secure UI progress exported an unapproved field.'}
    }
    $files[(Join-Path $RequestRoot 'decision.json')]=[pscustomobject]@{Success=$true;InputStarted=$true;CredentialEntered=$true}
    Read-InstallerSecureUiEvidence
    if(-not $evidence.Input.CredentialEntered -or $evidence.ContractProven){throw 'A final decision was lost or was sufficient to prove the whole contract.'}
}
$count++
$rejected=$false
try{ConvertTo-InstallerSecureProgress ([pscustomobject]@{Phase='unapproved';AtUtc=$now.ToString('o')})}catch{$rejected=$true}
if(-not $rejected){throw 'An arbitrary checkpoint phase was exported.'};$count++
$consoleGuard=$controller.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text.Contains('$desktopReady -and $consoleFlags')},$true)
$ready=[scriptblock]::Create($consoleGuard.Clauses[0].Item1.Extent.Text)
$desktopReady=$true;$consoleSid='S-1-5-21-1-2-3-1003'
$policy=[pscustomobject]@{InitiatingUser='StandardUser'}
$context=[pscustomobject]@{Identity=[pscustomobject]@{Initiator=[pscustomobject]@{Sid=$consoleSid}}}
foreach($consoleFlags in @(-1,0,1)){
    if((& $ready) -ne ($consoleFlags -eq 1)){throw 'An unknown or locked console passed installer readiness, or an unlocked console was rejected.'}
    $count++
}
[void](Add-Type -TypeDefinition 'public static class InstallerDesktopTest { public static int Flags; public static int ConsoleSessionFlags() { return Flags; } }')
$desktopGuard=$controller.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text.Contains('$desktop.InputDesktop')},$true)
$ready=[scriptblock]::Create($desktopGuard.Clauses[0].Item1.Extent.Text.Replace('[CodexInstallerNative]','[InstallerDesktopTest]'))
foreach($case in @(@{Desktop='Winlogon';Flags=1;Ready=$false},@{Desktop='Default';Flags=0;Ready=$false},@{Desktop='Default';Flags=1;Ready=$true})){
    $desktop=[pscustomobject]@{InputDesktop=$case.Desktop};[InstallerDesktopTest]::Flags=$case.Flags
    if((& $ready) -ne $case.Ready){throw 'Installer readiness accepted the sign-in desktop or a locked session.'}
    $count++
}
[pscustomobject]@{Success=$true;ScenarioCount=$count}
