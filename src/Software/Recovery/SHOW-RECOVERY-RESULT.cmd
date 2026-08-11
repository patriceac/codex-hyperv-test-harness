@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Show-CodexHyperVRecoveryResult.ps1" -BundleRoot "%~dp0" -ExpectedAttemptId "%~1"
exit /b %ERRORLEVEL%
