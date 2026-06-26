@echo off
title SteamLivelyBridge Launcher
echo Starting SteamLivelyBridge...

:: Launch the PowerShell script and bypass execution policy restrictions for other users
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SteamLivelyBridge.ps1"

:: If the script closes unexpectedly, pause so the user can see errors
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo The script exited with an error.
    pause
)
