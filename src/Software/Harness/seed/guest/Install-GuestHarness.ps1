$ErrorActionPreference = 'Stop'

$agentRoot = 'C:\CodexGuest'
$seedVolume = Get-Volume -FileSystemLabel 'CODEXSEED' -ErrorAction Stop | Select-Object -First 1
$seedRoot = $seedVolume.DriveLetter + ':\guest'

New-Item -ItemType Directory -Force -Path $agentRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $seedRoot 'GuestAgent.ps1') -Destination $agentRoot -Force
Copy-Item -LiteralPath (Join-Path $seedRoot 'GuestAgentSupervisor.ps1') -Destination $agentRoot -Force
Copy-Item -LiteralPath (Join-Path $seedRoot 'GuestLiveEvidence.ps1') -Destination $agentRoot -Force
Copy-Item -LiteralPath (Join-Path $seedRoot 'InputProbe.exe') -Destination $agentRoot -Force

foreach ($directoryName in @('Inbox', 'Processing', 'Completed', 'Outbox')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $agentRoot $directoryName) | Out-Null
}

Get-ChildItem -LiteralPath $agentRoot -File | Unblock-File -ErrorAction SilentlyContinue

# Keep the disposable guest's interactive desktop available even when nobody is
# attached through VMConnect. The physical host may be locked, but must not sleep.
powercfg.exe /hibernate off | Out-Null
powercfg.exe /change monitor-timeout-ac 0 | Out-Null
powercfg.exe /change monitor-timeout-dc 0 | Out-Null
powercfg.exe /change standby-timeout-ac 0 | Out-Null
powercfg.exe /change standby-timeout-dc 0 | Out-Null
powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 | Out-Null
powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 | Out-Null
powercfg.exe /setactive SCHEME_CURRENT | Out-Null

$desktopPolicy = 'HKCU:\Control Panel\Desktop'
Set-ItemProperty -LiteralPath $desktopPolicy -Name ScreenSaveActive -Value '0'
Set-ItemProperty -LiteralPath $desktopPolicy -Name ScreenSaverIsSecure -Value '0'
Set-ItemProperty -LiteralPath $desktopPolicy -Name ScreenSaveTimeOut -Value '0'

$systemPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-ItemProperty -LiteralPath $systemPolicy -Name InactivityTimeoutSecs -PropertyType DWord -Value 0 -Force | Out-Null

$werUser = 'HKCU:\Software\Microsoft\Windows\Windows Error Reporting'
New-Item -Path $werUser -Force | Out-Null
New-ItemProperty -LiteralPath $werUser -Name DontShowUI -PropertyType DWord -Value 1 -Force | Out-Null

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$agentCommand = 'powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\CodexGuest\GuestAgentSupervisor.ps1"'
New-ItemProperty -LiteralPath $runKey -Name CodexGuestAgent -PropertyType String -Value $agentCommand -Force | Out-Null

$ready = [ordered]@{
    Ready = $true
    InstalledUtc = [DateTime]::UtcNow.ToString('o')
    ComputerName = $env:COMPUTERNAME
    UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    SessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    UserInteractive = [Environment]::UserInteractive
    SeedDrive = $seedVolume.DriveLetter + ':'
}
$ready | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $agentRoot 'ready.json') -Encoding UTF8

Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoLogo',
    '-NoProfile',
    '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $agentRoot 'GuestAgentSupervisor.ps1')
) -WindowStyle Hidden
