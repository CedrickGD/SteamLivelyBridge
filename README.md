# SteamLivelyBridge

Current release: **2.0.1**. See [CHANGELOG.md](CHANGELOG.md) for the changes.

A portable Windows PowerShell tool that downloads Wallpaper Engine Workshop content with SteamCMD and prepares wallpapers for Lively Wallpaper. Video and web projects are packaged directly; **scene projects are rendered to video using your installed Wallpaper Engine**.

Double-click `Start-SteamLivelyBridge.bat` for the menu. No administrator access or PowerShell modules are required. Windows PowerShell 5.1 is included with Windows; PowerShell 7 can also run the script.

Use **Up/Down arrows** to move, **Enter** to select, and **Esc** to go back. Results remain visible until you press a key.

## What it does

- Downloads SteamCMD from Valve on the first login or download, rather than at startup.
- Leaves passwords and Steam Guard authentication with SteamCMD. The tool stores account names only.
- Verifies SteamCMD's output and exit code before reporting success or converting downloaded files.
- Accepts multiple Workshop IDs or links, skips duplicates, and continues after individual failures.
- Converts existing local wallpaper folders entirely offline, without SteamCMD or a Steam login.
- Finds Workshop items already installed in your Steam libraries and uses those files before trying a new download.
- Records scene wallpapers with the installed Wallpaper Engine renderer, preserving their visual effects in a looping video.
- Reads Wallpaper Engine's `project.json` to select the real entry file, including nested video/HTML paths.
- Produces a wallpaper folder and an importable ZIP with `LivelyInfo.json` at its root.
- Preserves existing output. Repeated conversions get numbered names instead of deleting earlier files.

## Quick start

1. Download or clone this repository and extract it to a writable folder.
2. Open `Start-SteamLivelyBridge.bat`.
3. Choose **Login to Steam**, select **Add account**, and enter your Steam **login name**, not your display name.
4. Enter your password when **SteamCMD** requests it. With Steam Guard enabled, follow its mobile approval, authenticator code, or email code prompt. Password typing may be invisible.
5. Wait for **Steam login confirmed**. A remembered account name or SteamCMD saying it is using username/password does **not** mean authentication succeeded.
6. Choose **Download / Convert Wallpaper** and paste an item URL or numeric ID. Separate multiple items with commas.
7. Drag the generated **ZIP** from `lively_wallpapers` into Lively's window.

You need a Steam account with access to the Workshop content. SteamCMD may require ownership of Wallpaper Engine and may refuse particular items. This tool does not bypass Steam ownership, subscriptions, or Workshop access restrictions.

**Scene conversion needs Wallpaper Engine installed and Python 3.9+ on PATH.** On first capture, the tool downloads the pinned [wp2video](https://github.com/unio207/wp2video) backend and a checksum-verified FFmpeg build (about 110 MB). Scene capture opens a dedicated renderer window, normally off-screen; it may move on-screen if off-screen capture fails. It records 30 seconds at 4K by default, targets 30 fps, and reduces frame rate if the renderer cannot keep up. The result has no audio or interactivity, and its end is crossfaded into its beginning for looping.

## Convert files you already have

Choose **Settings > More Tools > Convert a local wallpaper folder** and point it at an individual wallpaper's folder. This also works with content already downloaded by the Steam client. Select the folder containing `project.json`, rather than its parent containing many wallpapers.

If there is no project file, the tool accepts a single unambiguous video or HTML entry. Preview videos are excluded from this fallback. If multiple possible entries exist, add a `project.json` identifying the correct file:

```json
{
  "title": "My wallpaper",
  "type": "video",
  "file": "media/wallpaper.mp4",
  "preview": "preview.jpg"
}
```

For web content, use `"type": "web"` and the HTML file's relative path. The preview field is optional. All source files, including nested and hidden assets, are copied.

## Command line

Run from a PowerShell terminal in this folder:

```powershell
# Let SteamCMD handle password and Steam Guard input.
.\SteamLivelyBridge.ps1 -Mode Login -Username myaccount

# Download and package one wallpaper.
.\SteamLivelyBridge.ps1 -Mode Download -Username myaccount -Workshop 123456789

# Download a batch; successful items remain available if another fails.
.\SteamLivelyBridge.ps1 -Mode Download -Username myaccount -Workshop 123456789,987654321

# Convert a local folder without network access or a Steam login.
.\SteamLivelyBridge.ps1 -Mode Convert -InputPath 'D:\Wallpapers\123456789'

# Choose the output directory and skip ZIP creation to save disk space.
.\SteamLivelyBridge.ps1 -Mode Convert -InputPath 'D:\Wallpapers\123456789' -OutputDirectory 'D:\Lively' -NoArchive

# Download raw content, including unsupported scene projects.
.\SteamLivelyBridge.ps1 -Mode Download -Username myaccount -Workshop 123456789 -Action DownloadOnly

# Package a previously downloaded SteamCMD item without contacting Steam.
.\SteamLivelyBridge.ps1 -Mode Download -Workshop 123456789 -Action ConvertOnly

# Record an installed scene at a different length/resolution/frame rate.
.\SteamLivelyBridge.ps1 -Mode Convert -InputPath 'D:\SteamLibrary\steamapps\workshop\content\431960\3110614158' -SceneSeconds 30 -SceneResolution 4K -SceneFPS 30

# Apply a Wallpaper Engine Share JSON file on top of saved checkbox/slider values.
.\SteamLivelyBridge.ps1 -Mode Download -Workshop 3360376408 -Action ConvertOnly -WallpaperProperties 'D:\Wallpapers\my-settings.json'

# Choose a particular monitor/profile's saved values instead of the primary monitor.
.\SteamLivelyBridge.ps1 -Mode Download -Workshop 3360376408 -Action ConvertOnly -WallpaperLocation Monitor1 -WallpaperProfile myprofile
```

The launcher accepts the same flags for single-item operations. For batches, use PowerShell's array syntax as shown above. Relative filesystem paths resolve against this repository's folder. Command-line download action defaults to `Both`; the menu's action setting does not override it. Command-line failures return exit code 1.

## Compatibility

Scene capture reads Wallpaper Engine's saved per-wallpaper settings, including unchecked checkboxes (`false`), sliders set to zero, colors, and dropdown choices. It matches the Workshop ID across Steam libraries and prefers the primary monitor's values. The tool reports which saved monitor settings it found. `-WallpaperLocation` and `-WallpaperProfile` select another saved configuration.

Save/apply your choices in Wallpaper Engine before exporting. If there are no saved settings for the item, the tool says it is using the wallpaper's defaults. For unsaved choices or explicit overrides, use Wallpaper Engine's **Share JSON**, save it as a UTF-8 JSON file, and pass `-WallpaperProperties`. These values override the saved settings. Properties are applied only to the isolated recording window, leaving your desktop wallpaper settings alone.

The choices affect the recorded appearance and are baked into the video. A recorded clock repeats with the clip, and audio/mouse reactions are recorded rather than remaining interactive controls in Lively. This setting transfer currently applies to scene captures, not directly packaged HTML projects.

| Wallpaper type | Result |
| --- | --- |
| Video | Packaged for Lively; MP4, WebM, AVI, MOV, MKV, WMV, M4V, MPG, MPEG are recognized. Playback depends on Lively's player/codecs. |
| Web | HTML and assets are packaged. Wallpaper Engine-specific APIs, audio visualizers, properties, and custom controls may require manual adaptation. |
| Scene (`.pkg`) | Rendered by the installed Wallpaper Engine and captured to MP4, then packaged for Lively. Requires Python 3.9+; FFmpeg and the pinned capture backend are installed on first use. |
| Application | Cannot be converted. Raw download only. |

Video and web projects keep their original media. Scene projects use the original renderer and become recorded video; the tool does not translate Wallpaper Engine's scene/shader format or web APIs. Scene content needs its original `project.json`; a preview video is never substituted for the actual scene. Symbolic links, junctions, entry paths outside the source folder, and output directories inside the source are rejected. Large wallpapers require room for the copied folder **and** ZIP. ZIPs use no compression to avoid spending time recompressing video.

The generated metadata follows Lively's [model](https://github.com/lively-community/lively/blob/core-separation/src/Lively/Lively.Models/LivelyInfoModel.cs) and [wallpaper type enum](https://github.com/lively-community/lively/blob/core-separation/src/Lively/Lively.Models/Enums/WallpaperType.cs). Lively documents ZIP import in [Lively Wallpaper File](https://github.com/lively-community/lively/wiki/Lively-Wallpaper-File).

## Settings and local data

The main menu keeps its original four choices: **Login to Steam**, **Download / Convert Wallpaper**, **Settings**, and **Exit**. **Settings** offers the original action cycle, output location, and open-output commands. ZIP creation, local conversion, and saved-account removal are under **More Tools**. Existing `bin/config.json` files are supported. Config updates use a temporary file and atomic replacement; malformed config is preserved with an actionable error.

| Location | Purpose |
| --- | --- |
| `bin/config.json` | Account names, output location, action, and ZIP preference |
| `bin/steamcmd/` | Valve's SteamCMD installation, logs, and its own cached Steam sessions |
| `bin/steamcmd/steamapps/workshop/content/431960/<id>/` | Downloaded source files |
| `bin/wp2video/` | Pinned MIT-licensed capture backend, its license, FFmpeg/ffprobe and FFmpeg's license |
| `lively_wallpapers/` | Default output folders and ZIPs |

These directories are excluded from Git. SteamCMD manages its own cached authentication; treat `bin` as private. Removing an account name from the menu does not revoke SteamCMD's session. No password or 2FA code is collected by this script or written to its config.

Output names include the Workshop ID when available. The tool never overwrites an existing output folder or ZIP. A failed conversion cleans up its own temporary staging files; interrupted sessions may leave `.slb-*.tmp` files in the output directory, which you can remove once the tool is closed.

## Troubleshooting

- **Steam Guard / two-factor login:** keep the terminal open and respond to SteamCMD's prompt. Approve the request in Steam's mobile app or enter the current requested code. An account saved in the menu is only a name, not a login status. A failed or pending login is never reported as confirmed.
- **Interactive console:** SteamCMD runs in the same console without redirected input/output so it can handle password and Steam Guard prompts itself. Only new entries in its own `console_log.txt` are used to verify the outcome after it exits. If no fresh confirmation is available, the tool leaves the result unconfirmed.
- **SteamCMD already running:** close the earlier SteamCMD session using this installation before retrying. The tool will not terminate existing sessions.
- **No subscription / access denied:** confirm the account has access to the item and owns the required app. Private, deleted, or restricted items may be unavailable.
- **Old cached files after a failed download:** download mode refuses to convert them. Use `ConvertOnly` or local conversion explicitly if you intend to use cached content.
- **Metadata unavailable:** the tool retries the Steam API and then uses local project metadata. Conversion of a local folder always works offline.
- **Already installed in Steam:** download/convert and convert-only modes search your Steam libraries first. Steam handles updates to those copies. Download-only mode still requests a SteamCMD download.
- **Scene capture:** leave Wallpaper Engine running during recording. The recorded video preserves appearance, but does not react to audio, mouse movement, or wallpaper properties after export. First-use dependency installation needs internet; subsequent captures can use installed content offline.
- **Config cannot be read:** correct or rename the indicated `config.json`; your file is left intact.
- **PowerShell execution policy:** use the batch launcher, which sets the policy only for its PowerShell process. It does not modify your system policy.

## Tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
python .\tests\Test-CaptureEncoding.py
```

The dependency-free suite uses temporary fixtures and a fake native SteamCMD executable. It covers config migration, metadata and ZIP contents, source/output preservation, unsafe paths, scene routing, batch failures, and login/2FA success detection. No Steam credentials, actual downloads, or changes to your Steam sessions are needed. CI runs it on Windows PowerShell and PowerShell 7. Real scene recording and playback in Lively require the installed renderer and a manual check. The scene path was also exercised with Workshop item `3110614158` (4k Red Moon), producing a decoded and visually checked 3840x2160 H.264 MP4, 30 seconds at 24 fps, and an importable ZIP.
