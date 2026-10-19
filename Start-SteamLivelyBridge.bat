@echo off
setlocal
title SteamLivelyBridge Launcher
echo Starting SteamLivelyBridge...

:: Launch the PowerShell script and bypass execution policy restrictions for other users
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SteamLivelyBridge.ps1" %*
set "bridge_exit=%ERRORLEVEL%"

:: If the script closes unexpectedly, pause so the user can see errors
if %bridge_exit% NEQ 0 (
    echo.
    echo The script exited with an error.
    pause
)
exit /b %bridge_exit%
