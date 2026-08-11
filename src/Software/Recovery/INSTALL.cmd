@echo off
setlocal
echo Codex Hyper-V harness recovery
echo If Windows restarts, sign in normally. A one-time result window will wait for completion.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-CodexHyperVHarness.ps1" -BundleRoot "%~dp0"
set "CODEX_HV_EXIT=%ERRORLEVEL%"
echo.
if "%CODEX_HV_EXIT%"=="0" (
    echo READY - Codex Hyper-V harness installation completed successfully.
) else (
    echo FAILED - Codex Hyper-V harness installation exited with code %CODEX_HV_EXIT%.
)
echo The status path is shown in the installer output.
echo.
echo Press any key to close this window.
pause >nul
exit /b %CODEX_HV_EXIT%
