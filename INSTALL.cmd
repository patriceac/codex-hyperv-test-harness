@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Install.ps1" %*
set "CODEX_EXIT=%ERRORLEVEL%"
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Show-Result.ps1"
echo.
if not "%CODEX_EXIT%"=="0" echo Installer exit code: %CODEX_EXIT%
pause
exit /b %CODEX_EXIT%
