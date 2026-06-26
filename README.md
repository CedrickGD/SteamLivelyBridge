# SteamLivelyBridge

A lightweight, portable PowerShell CLI tool that seamlessly bridges Steam Wallpaper Engine and Lively Wallpaper.

**SteamLivelyBridge** allows you to securely download any Video or Web wallpaper directly from the Steam Workshop without needing to own Wallpaper Engine, and automatically structures it into a format that Lively Wallpaper natively understands.

## Features
* **Automated Downloading:** Automatically fetches and installs its own dependencies (SteamCMD) in an isolated `bin` folder on first run.
* **Smart Detection:** Instantly scans Workshop links against the Steam API to warn you if a wallpaper is a proprietary "Scene" (which cannot be converted to video).
* **Lively Ready:** Automatically scrapes the real wallpaper title, downloads the raw `.mp4` or Web files, and generates a `LivelyInfo.json` file. You can simply drag and drop the output folder straight into Lively!
* **Multiple Accounts:** Securely caches and manages multiple Steam accounts (supports Steam Guard 2FA).
* **Interactive UI:** Smooth, flicker-free terminal UI built natively in PowerShell.

## Quick Start
1. Clone or download this repository.
2. Double-click `Start-SteamLivelyBridge.bat`.
3. Use the menu to log in to your Steam account (required to download paid Workshop items).
4. Select `Download / Convert Wallpaper` and paste a Steam Workshop URL.
5. Find your ready-to-use wallpaper in the `lively_wallpapers` folder!

## Note on "Scene" Wallpapers
Wallpaper Engine `.pkg` Scene files are not video files. They are 3D real-time rendering environments. This script will download them for you if you wish, but Lively Wallpaper **cannot natively play them**. To ensure compatibility, make sure to use the "Video" or "Web" filter when searching the Steam Workshop!
