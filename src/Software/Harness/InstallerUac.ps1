$installerContractPath=Join-Path $PSScriptRoot 'InstallerUacContract.ps1'
if(-not(Test-Path -LiteralPath $installerContractPath)){$installerContractPath=Join-Path $PSScriptRoot '..\Skill\scripts\InstallerUacContract.ps1'}
. $installerContractPath

function Invoke-InstallerGuestStatus {
    param([string]$VmName,[string]$RequestId,[string]$GuestRoot,[DateTime]$ExecutionDeadlineUtc)
    $base=Join-Path $probePath ($RequestId+'-installer-'+[Guid]::NewGuid().ToString('N'))
    $inputPath=$base+'.input.json';$outputPath=$base+'.json';$leasePath=$base+'.process.json';$process=$null
    try {
        Write-JsonAtomic -Path $inputPath -Value @{VmName=$VmName;GuestRoot=$GuestRoot;CredentialPath=$credentialPath}
        $command=@'
$ErrorActionPreference='Stop'
try {
    $data=Get-Content -Raw -LiteralPath __INPUT__ | ConvertFrom-Json
    $saved=Get-Content -Raw -LiteralPath $data.CredentialPath | ConvertFrom-Json
    $credential=[Management.Automation.PSCredential]::new($saved.UserName,(ConvertTo-SecureString $saved.Password -AsPlainText -Force))
    $value=Invoke-Command -VMName $data.VmName -Credential $credential -ScriptBlock {
        param($Root)
        $path=Join-Path $Root 'complete.json'
        if(Test-Path -LiteralPath $path){Get-Content -Raw -LiteralPath $path | ConvertFrom-Json}else{$null}
    } -ArgumentList $data.GuestRoot
    @{Success=$true;Value=$value} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath __OUTPUT__ -Encoding UTF8
} catch { @{Success=$false} | ConvertTo-Json | Set-Content -LiteralPath __OUTPUT__ -Encoding UTF8 }
'@
        $command=$command.Replace('__INPUT__',(ConvertTo-PowerShellSingleQuotedLiteral $inputPath)).Replace('__OUTPUT__',(ConvertTo-PowerShellSingleQuotedLiteral $outputPath))
        $process=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))) -WindowStyle Hidden -PassThru
        Write-JsonAtomic -Path $leasePath -Value @{ProcessId=$process.Id;ProcessStartUtc=$process.StartTime.ToUniversalTime().ToString('o');CreatedUtc=[DateTime]::UtcNow.ToString('o')}
        $limit=[DateTime]::UtcNow.AddSeconds(15)
        while(-not $process.HasExited){Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc;if([DateTime]::UtcNow -ge $limit){return $null};Start-Sleep -Milliseconds 200;$process.Refresh()}
        if(Test-Path -LiteralPath $outputPath){$result=Read-BrokerJsonWithRetry -Path $outputPath;if($result.Success){return $result.Value}}
        return $null
    } finally {
        if($process){Stop-GuestProbeProcess -Process $process -LeasePath $leasePath}
        foreach($path in @($inputPath,$outputPath)){Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue}
    }
}

function Start-InstallerUacV2 {
    param($Session,$Policy,$Job,[string]$RequestId,[string]$PayloadRoot,[string]$Outbox,[string]$ResultRoot,[DateTime]$ExecutionDeadlineUtc)
    $root='C:\ProgramData\CodexHarness\InstallerUac\'+$RequestId
    Invoke-Command -Session $Session -ScriptBlock {
        param($Root,$Outbox)
        if(Test-Path -LiteralPath $Root){throw 'Installer workflow refuses to reuse a request directory.'}
        $null=New-Item -ItemType Directory -Path $Root -Force
        $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
        foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit, ObjectInherit','None','Allow'))}
        [IO.Directory]::SetAccessControl($Root,$acl)
        $null=New-Item -ItemType Directory -Path $Outbox -Force
    } -ArgumentList $root,$Outbox
    foreach($name in @('GuestInstallerUac.ps1','InstallerUacNative.ps1','InstallerUacObservations.ps1','InstallerUacGate.ps1')){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination ($root+'\'+$name) -ToSession $Session
    }
    $context=@{RequestId=$RequestId;Phase='Prepare';Policy=$Policy;Job=$Job;PayloadRoot=$PayloadRoot;Outbox=$Outbox;DeadlineUtc=$ExecutionDeadlineUtc.ToUniversalTime().ToString('o')}
    Invoke-Command -Session $Session -ScriptBlock {
        param($Root,$Context)
        [IO.File]::WriteAllText((Join-Path $Root 'context.json'),$Context,[Text.UTF8Encoding]::new($false))
        $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Root+'\GuestInstallerUac.ps1" -RequestRoot "'+$Root+'"')
        $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromHours(2)) -MultipleInstances IgnoreNew
        $name='CodexInstaller-'+(Split-Path $Root -Leaf)
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName $name
    } -ArgumentList $root,($context | ConvertTo-Json -Depth 25)
    $root
}
