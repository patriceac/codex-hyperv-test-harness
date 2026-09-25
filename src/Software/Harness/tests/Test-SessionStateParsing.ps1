$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\InstallerUacNative.ps1')
Initialize-InstallerNative
$broker=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\HostBroker.ps1'),[ref]$null,[ref]$null)
$definition=$broker.Find({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class CodexHostSession')},$true).Value
Add-Type -TypeDefinition $definition
$info=[CodexInstallerNative].GetNestedType('WtsInfoEx',[Reflection.BindingFlags]::NonPublic)
$level=[CodexInstallerNative].GetNestedType('WtsLevel1',[Reflection.BindingFlags]::NonPublic)
$flagsOffset=[Runtime.InteropServices.Marshal]::OffsetOf($info,'Data').ToInt32()+[Runtime.InteropServices.Marshal]::OffsetOf($level,'SessionFlags').ToInt32()
if($flagsOffset -ne 16){throw 'Windows session lock field does not match the SDK structure layout.'}
$count=1
$buffer=[Runtime.InteropServices.Marshal]::AllocHGlobal(32)
try {
    [Runtime.InteropServices.Marshal]::WriteInt32($buffer,0,1)
    [Runtime.InteropServices.Marshal]::WriteInt32($buffer,8,1)
    foreach($flags in @(0,1)){
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer,12,(1-$flags))
        [Runtime.InteropServices.Marshal]::WriteInt32($buffer,16,$flags)
        if([CodexHostSession]::ReadSessionFlags($buffer,32) -ne $flags){throw 'Connection state was confused with the lock flag.'}
        $count++
    }
    if([CodexHostSession]::ReadSessionFlags($buffer,16) -ne -1){throw 'A truncated session buffer was accepted.'}
    $count++
    [Runtime.InteropServices.Marshal]::WriteInt32($buffer,0,2)
    if([CodexHostSession]::ReadSessionFlags($buffer,32) -ne -1){throw 'An unknown session information level was accepted.'}
    $count++
} finally {[Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)}
[pscustomobject]@{Success=$true;ScenarioCount=$count}
