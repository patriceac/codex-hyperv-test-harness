@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Refresh-LocalRecovery.ps1" %*
set "CODEX_EXIT=%ERRORLEVEL%"
echo.
echo The recovery status path is shown in the command output.
if not "%CODEX_EXIT%"=="0" echo Recovery refresh exit code: %CODEX_EXIT%
echo.
pause
exit /b %CODEX_EXIT%
