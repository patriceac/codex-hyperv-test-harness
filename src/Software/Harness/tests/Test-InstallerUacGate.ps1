$ErrorActionPreference='Stop'
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
[pscustomobject]@{Success=$true;Scenarios=$count}
