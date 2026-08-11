@echo off
setlocal
set "CODEX_ROOT=%~1"
if "%CODEX_ROOT%"=="" set "CODEX_ROOT=D:\Disk\VMs\Codex-Harness"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Show-Result.ps1" -InstallRoot "%CODEX_ROOT%" -WaitSeconds 21600
set "CODEX_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %CODEX_EXIT%
