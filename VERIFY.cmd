@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Verify.ps1" %*
set "CODEX_EXIT=%ERRORLEVEL%"
echo.
echo The verification result path is shown in the command output.
if not "%CODEX_EXIT%"=="0" echo Verification exit code: %CODEX_EXIT%
echo.
pause
exit /b %CODEX_EXIT%
