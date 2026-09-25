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
foreach($change in @(@('RequestorProcessId',101),@('EmitterProcessId',201),@('ApplicationName','D:\unrelated.exe'),@('Provider','Untrusted'),@('AutoElevate','true'),@('TimeUtc',$now.AddSeconds(-60).ToString('o')))){
    $event=$template | ConvertTo-Json | ConvertFrom-Json;$event.($change[0])=$change[1]
    $rejected=$false
    try{Assert-InstallerPromptAttribution $event $requester $consent $root 'D:\Payload\setup.exe' ('A'*64) ('A'*64) $now}catch{$rejected=$true}
    if(-not $rejected){throw "Prompt gate accepted a changed $($change[0])."};$count++
}
$rejected=$false
try{Assert-InstallerPromptAttribution ([pscustomobject]$template) $requester $consent $root 'D:\Payload\setup.exe' ('B'*64) ('A'*64) $now}catch{$rejected=$true}
if(-not $rejected){throw 'Prompt gate accepted a wrong image hash.'};$count++
$controller=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\GuestInstallerUac.ps1'),[ref]$null,[ref]$null)
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
[void](Add-Type -TypeDefinition 'public static class InstallerForegroundTest { public static System.Collections.Generic.Queue<int> Values = new System.Collections.Generic.Queue<int>(); public static int SecureForeground() { return Values.Dequeue(); } }')
$promptFunction=$controller.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-InstallerSecurePrompt'},$true)
$waitLoop=$promptFunction.Find({param($node) $node -is [Management.Automation.Language.DoWhileStatementAst]},$true)
$wait=[scriptblock]::Create($waitLoop.Extent.Text.Replace('[CodexInstallerNative]','[InstallerForegroundTest]'))
function Test-SameInstallerProcess($Expected){$script:liveChecks++;$Expected}
$gate=[pscustomobject]@{Event=[pscustomobject]$template;Requester=$requester;Consent=$consent;Root=$root}
$context=[pscustomobject]@{Job=[pscustomobject]@{executable='D:\Payload\setup.exe'}}
$policy=[pscustomobject]@{ExecutableSha256=('A'*64)}
foreach($case in @(
    @{Wait=$true;Expired=$false;Values=@(0,200);Rejected=$false;Checks=4},
    @{Wait=$false;Expired=$false;Values=@(0,200);Rejected=$true;Checks=2},
    @{Wait=$true;Expired=$true;Values=@(0);Rejected=$true;Checks=2}
)){
    [InstallerForegroundTest]::Values.Clear()
    foreach($value in $case.Values){[InstallerForegroundTest]::Values.Enqueue($value)}
    $WaitForReady=$case.Wait
    $readyUntil=[DateTime]::UtcNow.AddSeconds($(if($case.Expired){-1}else{1}))
    $script:liveChecks=0;$message=$null
    try{& $wait}catch{$message=$_.Exception.Message}
    if($case.Rejected){if($message -notlike 'The attributed UAC prompt is not the secure foreground*'){throw 'The foreground gate did not reject the missing prompt.'}}
    elseif($message){throw $message}
    if($script:liveChecks -ne $case.Checks){throw 'The readiness wait did not revalidate process identities or immediate input checks waited.'}
    $count++
}
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
