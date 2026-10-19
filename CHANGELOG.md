# Changelog

## 2.0.1 - 2026-10-19

- Fix the GitHub Actions shell matrix so Windows PowerShell and PowerShell 7 tests run before publishing release packages.

## 2.0.0 - 2026-10-19

- Convert scene wallpapers into looping MP4s using the installed Wallpaper Engine renderer, then package them for Lively.
- Honor saved Wallpaper Engine checkbox, slider, color, and dropdown values. Support Share JSON overrides and monitor/profile selection.
- Find wallpapers already installed in Steam libraries, avoiding unnecessary downloads and account prompts.
- Keep SteamCMD authentication in the original console for passwords, Steam Guard codes, and mobile approval. Recognize successful login in timestamped multiline logs.
- Decode native capture diagnostics safely, including Unicode wallpaper titles and malformed bytes; drain both FFmpeg pipes and wait for the error reader.
- Select video/web entry files from project.json, support nested assets, and generate correct Lively metadata and importable ZIPs.
- Preserve source files and existing exports; reject unsafe paths and linked content.
- Add offline conversion, batch operations, command-line controls, config migration and atomic config writes.
- Preserve the original arrow-key main menu and settings flow, with additional tools under Settings.
- Add Windows PowerShell/PowerShell 7 CI and subprocess regression tests.

Scene capture requires installed Wallpaper Engine and Python 3.9+. The first capture installs the pinned wp2video backend and a checksum-verified FFmpeg build. Exported videos have no audio and do not retain interactive Wallpaper Engine controls; selected property values affect the recorded appearance. Their frame rate may be reduced to match renderer performance.
