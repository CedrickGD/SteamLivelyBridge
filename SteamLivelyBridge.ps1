#requires -Version 5.1
<#
.SYNOPSIS
Download Wallpaper Engine Workshop content and package video/web projects for Lively.
.EXAMPLE
.\SteamLivelyBridge.ps1 -Mode Convert -InputPath 'D:\Wallpapers\123'
.EXAMPLE
.\SteamLivelyBridge.ps1 -Mode Download -Workshop 123456789 -Username myaccount
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Login', 'Download', 'Convert')][string]$Mode = 'Menu',
    [string[]]$Workshop,
    [string]$InputPath,
    [string]$OutputDirectory,
    [string]$Username,
    [ValidateSet('Both', 'DownloadOnly', 'ConvertOnly')][string]$Action = 'Both',
    [ValidateRange(3, 600)][int]$SceneSeconds = 30,
    [ValidateSet('1080p', '1440p', '4K')][string]$SceneResolution = '4K',
    [ValidateSet(30, 60)][int]$SceneFPS = 30,
    [string]$WallpaperProperties,
    [string]$WallpaperLocation,
    [string]$WallpaperProfile,
    [switch]$NoArchive
)

$script:Root = $PSScriptRoot
$script:AppDir = Join-Path $script:Root 'bin'
$script:SteamCmdDir = Join-Path $script:AppDir 'steamcmd'
$script:SteamCmdExe = Join-Path $script:SteamCmdDir 'steamcmd.exe'
$script:ConfigPath = Join-Path $script:AppDir 'config.json'
$script:DefaultOutputDir = Join-Path $script:Root 'lively_wallpapers'
$script:VideoExtensions = @('.mp4', '.webm', '.avi', '.mov', '.mkv', '.wmv', '.m4v', '.mpg', '.mpeg')
$script:SceneSeconds = $SceneSeconds
$script:SceneResolution = $SceneResolution
$script:SceneFPS = $SceneFPS
$script:WallpaperProperties = $WallpaperProperties
$script:WallpaperLocation = $WallpaperLocation
$script:WallpaperProfile = $WallpaperProfile
. (Join-Path $script:Root 'SceneCapture.ps1')

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $script:Root $Path }
    return [IO.Path]::GetFullPath($Path)
}

function Test-ChildPath {
    param([string]$Parent, [string]$Child)
    $prefix = (Get-FullPath $Parent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return (Get-FullPath $Child).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePath {
    param([string]$Path)
    $current = Get-FullPath $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Symbolic links and junctions are not supported here: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Assert-Username {
    param([string]$Name)
    if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.@-]{0,127}$') {
        throw 'Enter a Steam account login name (letters, numbers, underscore, dot, @ or dash).'
    }
}

function Load-Config {
    $cfg = [pscustomobject]@{ Accounts = @(); OutputDir = $script:DefaultOutputDir; Action = 'Both'; CreateArchive = $true }
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return $cfg }
    try {
        $saved = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $saved -or $saved -isnot [pscustomobject]) { throw 'Expected a JSON object.' }
        $cfg.Accounts = @($saved.Accounts | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        foreach ($account in $cfg.Accounts) { Assert-Username $account }
        if (-not [string]::IsNullOrWhiteSpace($saved.OutputDir)) { $cfg.OutputDir = Get-FullPath $saved.OutputDir }
        if ($saved.Action -in @('Both', 'DownloadOnly', 'ConvertOnly')) { $cfg.Action = $saved.Action }
        if ($saved.CreateArchive -is [bool]) { $cfg.CreateArchive = $saved.CreateArchive }
        return $cfg
    } catch {
        throw "Cannot read config at '$script:ConfigPath'. Correct or rename the file; it has been preserved. $($_.Exception.Message)"
    }
}

function Save-Config {
    param($Config)
    Assert-NoReparsePath $script:AppDir
    New-Item -ItemType Directory -Path $script:AppDir -Force -ErrorAction Stop | Out-Null
    $temporary = Join-Path $script:AppDir ([guid]::NewGuid().ToString() + '.json.tmp')
    try {
        Write-JsonFile -Path $temporary -Value $Config
        if (Test-Path -LiteralPath $script:ConfigPath) { [IO.File]::Replace($temporary, $script:ConfigPath, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $script:ConfigPath) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-WorkshopId {
    param([Parameter(Mandatory)][string]$Value)
    $value = $Value.Trim()
    if ($value -match '^\d+$' -and $value -match '[1-9]') { return $value }
    $uri = $null
    if ([uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -and
        $uri.Scheme -in @('http', 'https') -and $uri.Host -eq 'steamcommunity.com' -and
        $uri.AbsolutePath -in @('/sharedfiles/filedetails/', '/sharedfiles/filedetails', '/workshop/filedetails/', '/workshop/filedetails') -and
        $uri.Query -match '(?:^\?|&)id=(\d+)(?:&|$)') {
        $id = $Matches[1]
        if ($id -match '[1-9]') { return $id }
    }
    throw "Invalid Workshop ID or Steam Community item URL: $Value"
}

function Get-WorkshopDetails {
    param([string]$Id)
    $fallback = [pscustomobject]@{ Title = $Id; Tags = @() }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri 'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/' `
                -Method Post -Body @{ itemcount = 1; 'publishedfileids[0]' = $Id } -TimeoutSec 20 -ErrorAction Stop
            $detail = @($response.response.publishedfiledetails)[0]
        } catch {
            if ($attempt -lt 3) { Start-Sleep -Seconds $attempt; continue }
            Write-Warning 'Workshop metadata is unavailable. Local project metadata will be used after download.'
            return $fallback
        }
        if ($detail.result -ne 1) { throw "Workshop item $Id is unavailable (Steam result $($detail.result)). It may be private, deleted, or inaccessible." }
        if ($detail.consumer_app_id -and $detail.consumer_app_id -ne 431960) { throw "Item $Id is not a Wallpaper Engine wallpaper." }
        return [pscustomobject]@{ Title = [Net.WebUtility]::HtmlDecode($detail.title); Tags = @($detail.tags | ForEach-Object { $_.tag }) }
    }
}

function Install-Dependencies {
    Assert-NoReparsePath $script:SteamCmdDir
    if (Test-Path -LiteralPath $script:SteamCmdExe -PathType Leaf) { return }
    New-Item -ItemType Directory -Path $script:SteamCmdDir -Force -ErrorAction Stop | Out-Null
    $zipPath = Join-Path $script:SteamCmdDir ('steamcmd-' + [guid]::NewGuid().ToString() + '.zip')
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Host 'Downloading SteamCMD from Valve...' -ForegroundColor Cyan
        Invoke-WebRequest -UseBasicParsing -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zipPath -TimeoutSec 120 -ErrorAction Stop
        Expand-Archive -LiteralPath $zipPath -DestinationPath $script:SteamCmdDir -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $script:SteamCmdExe -PathType Leaf)) { throw 'The SteamCMD archive did not contain steamcmd.exe.' }
    } catch {
        throw "SteamCMD setup failed. Check your connection and try again. $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    }
}

function Read-SteamConsoleLog {
    $path = Join-Path $script:SteamCmdDir 'logs\console_log.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    return [string](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
}

function Invoke-SteamProcess {
    param([string[]]$Arguments)
    foreach ($running in Get-Process -Name steamcmd -ErrorAction SilentlyContinue) {
        if ($running.Path -and $running.Path -eq $script:SteamCmdExe) {
            throw 'SteamCMD is already running from this tool. Close that SteamCMD session before starting another login or download.'
        }
    }
    $before = Read-SteamConsoleLog
    # Keep all console handles intact. Redirecting stdout can change SteamCMD's interactive
    # password/Steam Guard behavior. Start-Process also avoids accidental PowerShell pipeline capture.
    # -Wait waits for bootstrap child processes as well as the initial SteamCMD process.
    $process = Start-Process -FilePath $script:SteamCmdExe -ArgumentList $Arguments `
        -WorkingDirectory $script:SteamCmdDir -NoNewWindow -Wait -PassThru -ErrorAction Stop
    try { $exitCode = $process.ExitCode } finally { $process.Dispose() }
    $after = Read-SteamConsoleLog
    # Never count a success left over from an earlier session as evidence for this run.
    if ($after.StartsWith($before, [StringComparison]::Ordinal)) { $after = $after.Substring($before.Length) }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $after }
}

function Assert-SteamResult {
    param($Result, [string]$WorkshopId)
    if ($Result.ExitCode -ne 0) { throw "SteamCMD exited with code $($Result.ExitCode). Check the SteamCMD message above." }
    # console_log.txt records the prompt and its OK on separate timestamped lines,
    # even though the interactive console displays them together.
    $successPattern = '(?im)Waiting for user info[. \t]*(?:\r?\n[ \t]*(?:\[\d{4}-\d{2}-\d{2} [^\]\r\n]+\][ \t]*)?)?OK\b'
    if ($WorkshopId) {
        $successPattern = '(?im)Success\. Downloaded item\s+' + [regex]::Escape($WorkshopId) + '\b'
    }
    $successes = [regex]::Matches($Result.Output, $successPattern)
    $failures = [regex]::Matches($Result.Output, '(?im)(ERROR!|FAILED\s*\(|Invalid Password|InvalidPassword|Invalid Login Auth Code|Two-factor code mismatch|Account Logon Denied)')
    if ($failures.Count -gt 0 -and ($successes.Count -eq 0 -or $failures[$failures.Count - 1].Index -gt $successes[$successes.Count - 1].Index)) {
        if ($Result.Output -match '(?i)Invalid\s*Password') {
            throw 'Steam rejected the login credentials before Steam Guard completed. Use your Steam account login name (not display name) and enter the password directly in SteamCMD.'
        }
        throw 'SteamCMD reported an error. Check its message above. Login or download has not been confirmed.'
    }
    if ($successes.Count -eq 0) {
        if ($WorkshopId) { throw "SteamCMD did not confirm download of $WorkshopId. Old cached files will not be converted." }
        throw 'Login could not be confirmed from this SteamCMD session. Check its messages above; an attempted username/password login is not a completed login.'
    }
}

function Invoke-SteamCommand {
    param([string]$Account, [string]$WorkshopId)
    Assert-Username $Account
    Install-Dependencies
    $arguments = @('+login', $Account)
    if ($WorkshopId) { $arguments += @('+workshop_download_item', '431960', (Get-WorkshopId $WorkshopId), 'validate') }
    $arguments += '+quit'
    Write-Host 'Enter your password only when SteamCMD prompts you (typing may be invisible).' -ForegroundColor Cyan
    Write-Host 'Steam Guard: approve the sign-in in your mobile app, or enter its current code when requested.' -ForegroundColor Cyan
    Write-Host 'A saved account name is not proof of login. Wait for authentication to finish. Ctrl+C cancels.' -ForegroundColor DarkGray
    $result = Invoke-SteamProcess -Arguments $arguments
    Assert-SteamResult -Result $result -WorkshopId $WorkshopId
    if ($WorkshopId) {
        $path = Join-Path $script:SteamCmdDir "steamapps\workshop\content\431960\$WorkshopId"
        if (-not (Test-Path -LiteralPath $path -PathType Container) -or @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) {
            throw "SteamCMD reported success but no wallpaper files were found at '$path'."
        }
        return $path
    }
}

function Get-SafeFiles {
    param([string]$Root)
    Assert-NoReparsePath $Root
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked content is not supported: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $item }
        }
    }
}

function Resolve-ProjectFile {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':')) {
        throw 'The project entry file must be a relative path inside the wallpaper folder.'
    }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not (Test-ChildPath -Parent $Root -Child $full)) { throw 'The project entry file escapes the wallpaper folder.' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Project entry file is missing: $RelativePath" }
    return $full
}

function Get-WallpaperProject {
    param([string]$Root)
    $files = @(Get-SafeFiles $Root)
    if ($files.Count -eq 0) { throw 'The wallpaper folder is empty.' }
    $projectPath = Join-Path $Root 'project.json'
    $project = $null
    if (Test-Path -LiteralPath $projectPath -PathType Leaf) {
        try { $project = Get-Content -LiteralPath $projectPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Invalid Wallpaper Engine project.json: $($_.Exception.Message)" }
    }
    $type = [string]$project.type
    if ($type -eq 'scene') {
        return [pscustomobject]@{ Type = 'scene'; Title = $project.title; Files = $files }
    }
    if ($type -and $type -notin @('video', 'web')) {
        throw "Wallpaper Engine '$type' projects cannot be converted to Lively. Raw files have been left in their source folder."
    }
    if ($project.file) {
        $entry = Resolve-ProjectFile -Root $Root -RelativePath $project.file
        $extension = [IO.Path]::GetExtension($entry).ToLowerInvariant()
        if (-not $type) {
            if ($extension -in $script:VideoExtensions) { $type = 'video' }
            elseif ($extension -in @('.html', '.htm')) { $type = 'web' }
        }
        if (($type -eq 'video' -and $extension -notin $script:VideoExtensions) -or
            ($type -eq 'web' -and $extension -notin @('.html', '.htm')) -or -not $type) {
            throw 'The project entry file is not a supported video or HTML file.'
        }
    } else {
        # Scene projects may contain preview videos that are not the actual wallpaper.
        if (@($files | Where-Object { $_.Extension -eq '.pkg' }).Count -gt 0) { throw 'Scene/PKG content requires its original project.json so Wallpaper Engine can render it. Raw files have been preserved.' }
        $candidates = @($files | Where-Object {
            (($type -ne 'web' -and $_.Extension.ToLowerInvariant() -in $script:VideoExtensions) -or
             ($type -ne 'video' -and $_.Extension -in @('.html', '.htm'))) -and $_.BaseName -notmatch '^(preview|thumbnail|trailer)$'
        })
        if ($candidates.Count -ne 1) { throw "Found $($candidates.Count) possible entry files. Supply a project.json with type and file to select the actual wallpaper." }
        $entry = $candidates[0].FullName
        if ($candidates[0].Extension -in @('.html', '.htm')) { $type = 'web' } else { $type = 'video' }
    }
    $relative = $entry.Substring($Root.TrimEnd('\', '/').Length + 1)
    $preview = $null
    if ($project.preview) {
        $previewPath = Resolve-ProjectFile -Root $Root -RelativePath $project.preview
        if ([IO.Path]::GetExtension($previewPath) -in @('.jpg', '.jpeg', '.png', '.webp')) {
            $preview = $previewPath.Substring($Root.TrimEnd('\', '/').Length + 1)
        }
    } else {
        foreach ($name in @('preview.jpg', 'preview.png', 'thumbnail.jpg', 'thumbnail.png')) {
            if (Test-Path -LiteralPath (Join-Path $Root $name) -PathType Leaf) { $preview = $name; break }
        }
    }
    return [pscustomobject]@{ Type = $type; File = $relative; Title = $project.title; Preview = $preview; Files = $files }
}

function Get-SafeFolderName {
    param([string]$Title)
    $name = ($Title -replace '[\x00-\x1f<>:"/\\|?*]', '_').Trim().TrimEnd('.', ' ')
    if (-not $name -or $name -in @('.', '..')) { $name = 'Wallpaper' }
    if ($name -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { $name = '_' + $name }
    if ($name.Length -gt 80) { $name = $name.Substring(0, 80).TrimEnd('.', ' ') }
    return $name
}

function Remove-StagingFolder {
    param([string]$Root, [string]$Path)
    $full = Get-FullPath $Path
    if ([IO.Path]::GetDirectoryName($full) -ne (Get-FullPath $Root).TrimEnd('\', '/') -or
        [IO.Path]::GetFileName($full) -notmatch '^\.slb-[a-f0-9]{32}\.tmp$') { throw 'Refusing to remove a folder outside the conversion staging area.' }
    Assert-NoReparsePath $full
    if (Test-Path -LiteralPath $full) {
        $null = @(Get-SafeFiles $full)
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}

function Process-WallpaperFiles {
    param([Parameter(Mandatory)][string]$ItemPath, [string]$WorkshopId, [string]$OutputDir = $script:DefaultOutputDir, [string]$Title, [switch]$NoArchive)
    $source = Get-FullPath $ItemPath
    $destination = Get-FullPath $OutputDir
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Wallpaper folder does not exist: $source" }
    if ($source.TrimEnd('\', '/') -eq $destination.TrimEnd('\', '/') -or (Test-ChildPath $source $destination)) {
        throw 'Choose an output directory outside the source wallpaper folder.'
    }
    Assert-NoReparsePath $destination
    $project = Get-WallpaperProject $source
    if ($project.Type -eq 'scene') {
        return Convert-SceneWallpaper -ItemPath $source -WorkshopId $WorkshopId -OutputDir $destination -Title $Title -NoArchive:$NoArchive
    }
    if ([string]::IsNullOrWhiteSpace($Title) -or $Title -eq $WorkshopId) { $Title = $project.Title }
    if ([string]::IsNullOrWhiteSpace($Title)) { $Title = [IO.Path]::GetFileName($source.TrimEnd('\', '/')) }
    $folderName = Get-SafeFolderName $Title
    if ($WorkshopId) { $folderName = (Get-WorkshopId $WorkshopId) + ' - ' + $folderName }
    New-Item -ItemType Directory -Path $destination -Force -ErrorAction Stop | Out-Null
    $stage = Join-Path $destination ('.slb-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stageZip = $stage + '.zip'
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
    try {
        foreach ($file in $project.Files) {
            $relative = $file.FullName.Substring($source.TrimEnd('\', '/').Length + 1)
            $target = Join-Path $stage $relative
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force -ErrorAction Stop | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force -ErrorAction Stop
        }
        # Lively's enum uses web=1 and video=7; IsAbsolutePath is the model property.
        $typeNumber = 7
        if ($project.Type -eq 'web') { $typeNumber = 1 }
        $contact = $null
        if ($WorkshopId) { $contact = "https://steamcommunity.com/sharedfiles/filedetails/?id=$WorkshopId" }
        $info = [ordered]@{
            AppVersion = '2.0.0.0'; Title = $Title; Type = $typeNumber; FileName = $project.File
            IsAbsolutePath = $false; Thumbnail = $project.Preview; Preview = $null
            Desc = 'Imported from Wallpaper Engine by SteamLivelyBridge'; Author = $null; Contact = $contact
        }
        Write-JsonFile -Path (Join-Path $stage 'LivelyInfo.json') -Value $info
        if (-not $NoArchive) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::CreateFromDirectory($stage, $stageZip, [IO.Compression.CompressionLevel]::NoCompression, $false)
        }
        $final = Join-Path $destination $folderName
        $suffix = 2
        while ((Test-Path -LiteralPath $final) -or (Test-Path -LiteralPath ($final + '.zip'))) {
            $final = Join-Path $destination ($folderName + " ($suffix)"); $suffix++
        }
        # Move refuses overwrites, including concurrent conversions choosing the same name.
        [IO.Directory]::Move($stage, $final)
        $archive = $null
        if (-not $NoArchive) {
            $archive = $final + '.zip'
            try { [IO.File]::Move($stageZip, $archive) }
            catch { throw "Converted folder is ready at '$final', but publishing its ZIP failed: $($_.Exception.Message)" }
        }
        if ($project.Type -eq 'web') { Write-Warning 'Wallpaper Engine-specific web APIs and custom controls may need changes to work in Lively.' }
        return [pscustomobject]@{ Title = $Title; Type = $project.Type; Folder = $final; Archive = $archive }
    } finally {
        if (Test-Path -LiteralPath $stageZip) { Remove-Item -LiteralPath $stageZip -Force }
        if (Test-Path -LiteralPath $stage) { Remove-StagingFolder -Root $destination -Path $stage }
    }
}

function Set-ConsoleCursorPosition {
    param([int]$X, [int]$Y)
    try { [Console]::SetCursorPosition($X, $Y) } catch { }
}

function Write-MenuFrame {
    param([string]$Title)
    Clear-Host
    Write-Host '==============================================' -ForegroundColor DarkGray
    Write-Host "   $Title" -ForegroundColor White
    Write-Host '==============================================' -ForegroundColor DarkGray
    Write-Host ''
}

function Read-MenuKey {
    return $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Wait-MenuContinue {
    Write-Host "`nPress any key to continue..." -ForegroundColor DarkGray
    while ($Host.UI.RawUI.KeyAvailable) { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown,IncludeKeyUp') }
    $null = Read-MenuKey
}

function Read-MenuSelection {
    param([string]$Title, [string[]]$Options)
    if ($Options.Count -eq 0) { return -1 }
    $selected = 0
    Write-MenuFrame -Title $Title
    try { $top = [Console]::CursorTop } catch { $top = 0 }
    while ($true) {
        Set-ConsoleCursorPosition -X 0 -Y $top
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $selected) {
                Write-Host (" > $($Options[$i])".PadRight(60)) -ForegroundColor Cyan
            } else {
                Write-Host ("   $($Options[$i])".PadRight(60)) -ForegroundColor Gray
            }
        }
        Write-Host "`nUse Up/Down arrows to select, Enter to confirm. Esc to go back." -ForegroundColor DarkGray
        $key = Read-MenuKey
        switch ($key.VirtualKeyCode) {
            38 { $selected = ($selected - 1 + $Options.Count) % $Options.Count }
            40 { $selected = ($selected + 1) % $Options.Count }
            13 { return $selected }
            27 { return -1 }
        }
    }
}

function Select-Account {
    param($Config, [switch]$Login)
    $title = 'Select Account for Download'
    $prefix = 'Use'
    if ($Login) { $title = 'Select Account to Login'; $prefix = 'Login as' }
    $options = @($Config.Accounts | ForEach-Object { "$prefix $_" }) + @('Add New Account', 'Back')
    $selection = Read-MenuSelection -Title $title -Options $options
    if ($selection -lt 0 -or $selection -eq ($options.Count - 1)) { return $null }
    if ($selection -lt $Config.Accounts.Count) { return $Config.Accounts[$selection] }
    $account = Read-Host 'Steam account login name (blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($account)) { return $null }
    Assert-Username $account
    $Config.Accounts = @($Config.Accounts + $account | Select-Object -Unique)
    Save-Config $Config
    return $account
}

function Invoke-WallpaperDownload {
    param([string[]]$Items, [string]$Account, [string]$Action = 'Both', [string]$OutputDir, [switch]$NoArchive)
    # Validate the entire batch before network calls or SteamCMD execution.
    $ids = @($Items | ForEach-Object { Get-WorkshopId $_ } | Select-Object -Unique)
    if ($ids.Count -eq 0) { throw 'Supply at least one Workshop ID or URL.' }
    $failed = 0
    foreach ($id in $ids) {
        try {
            Write-Host "`nWorkshop item $id" -ForegroundColor Cyan
            $installed = Find-InstalledWorkshopItem $id
            if ($installed -and $Action -ne 'DownloadOnly') {
                Write-Host 'Using the wallpaper already installed by Steam.' -ForegroundColor Gray
                $path = $installed
                $title = $null
            } elseif ($Action -eq 'ConvertOnly') {
                $path = Join-Path $script:SteamCmdDir "steamapps\workshop\content\431960\$id"
                $title = $null
            } else {
                $details = Get-WorkshopDetails $id
                $title = $details.Title
                if ($Action -eq 'Both' -and $details.Tags -contains 'Application') {
                    throw 'Application wallpapers cannot be converted to Lively. Choose DownloadOnly to keep raw content.'
                }
                $path = Invoke-SteamCommand -Account $Account -WorkshopId $id
            }
            if ($Action -eq 'DownloadOnly') {
                [pscustomobject]@{ Title = $title; Type = 'raw'; Folder = $path; Archive = $null }
            } else { Process-WallpaperFiles -ItemPath $path -WorkshopId $id -OutputDir $OutputDir -Title $title -NoArchive:$NoArchive }
        } catch { $failed++; Write-Warning "Item $id failed: $($_.Exception.Message)" }
    }
    if ($failed) { throw "$failed of $($ids.Count) Workshop items failed. Successful items have been preserved." }
}

function Show-Result {
    param($Result)
    Write-Host "Ready: $($Result.Folder)" -ForegroundColor Green
    if ($Result.Archive) { Write-Host "Drag this ZIP into Lively: $($Result.Archive)" -ForegroundColor Cyan }
}

function Invoke-SettingsMenu {
    while ($true) {
        $cfg = Load-Config
        $selection = Read-MenuSelection -Title 'Settings' -Options @("Change Action [Current: $($cfg.Action)]", 'Change Output Directory', 'Open Output Directory', 'More Tools', 'Back')
        switch ($selection) {
            0 {
                if ($cfg.Action -eq 'Both') { $cfg.Action = 'DownloadOnly' }
                elseif ($cfg.Action -eq 'DownloadOnly') { $cfg.Action = 'ConvertOnly' }
                else { $cfg.Action = 'Both' }
            }
            1 {
                Clear-Host
                Write-Host "Current Directory: $($cfg.OutputDir)" -ForegroundColor Cyan
                $path = Read-Host 'New output directory (blank to cancel)'
                if (-not [string]::IsNullOrWhiteSpace($path)) { $cfg.OutputDir = Get-FullPath $path }
            }
            2 {
                Assert-NoReparsePath $cfg.OutputDir
                New-Item -ItemType Directory -Path $cfg.OutputDir -Force -ErrorAction Stop | Out-Null
                Invoke-Item -LiteralPath $cfg.OutputDir
            }
            3 {
                $tool = Read-MenuSelection 'More Tools' @('Convert a local wallpaper folder', "Create Lively ZIP: $($cfg.CreateArchive)", 'Remove a saved account', 'Back')
                switch ($tool) {
                    0 {
                        Write-MenuFrame 'Convert a Local Wallpaper Folder'
                        $path = Read-Host 'Local wallpaper folder (blank to cancel)'
                        if (-not [string]::IsNullOrWhiteSpace($path)) {
                            Process-WallpaperFiles -ItemPath $path.Trim('"') -OutputDir $cfg.OutputDir -NoArchive:(-not $cfg.CreateArchive) | ForEach-Object { Show-Result $_ }
                            Wait-MenuContinue
                        }
                    }
                    1 { $cfg.CreateArchive = -not $cfg.CreateArchive }
                    2 {
                        if ($cfg.Accounts.Count -eq 0) { Write-Host 'No saved accounts.'; Wait-MenuContinue; continue }
                        $choice = Read-MenuSelection 'Remove account name (Steam session remains cached)' (@($cfg.Accounts) + @('Back'))
                        if ($choice -ge 0 -and $choice -lt $cfg.Accounts.Count) {
                            $removed = $cfg.Accounts[$choice]
                            $cfg.Accounts = @($cfg.Accounts | Where-Object { $_ -ne $removed })
                        }
                    }
                }
            }
            default { return }
        }
        Save-Config $cfg
    }
}

function Invoke-SteamLivelyBridge {
    while ($true) {
        try {
            $selection = Read-MenuSelection 'SteamLivelyBridge Main Menu' @('Login to Steam', 'Download / Convert Wallpaper', 'Settings', 'Exit')
            if ($selection -lt 0 -or $selection -eq 3) { return }
            $cfg = Load-Config
            switch ($selection) {
                0 {
                    $account = Select-Account $cfg -Login
                    if (-not $account) { continue }
                    Write-MenuFrame 'Login to Steam'
                    Invoke-SteamCommand -Account $account
                    Write-Host 'Steam login confirmed.' -ForegroundColor Green
                }
                1 {
                    Write-MenuFrame 'Download / Convert Wallpaper'
                    $value = Read-Host 'Workshop IDs or URLs, separated by commas (blank to cancel)'
                    if ([string]::IsNullOrWhiteSpace($value)) { continue }
                    $items = @($value -split ',' | ForEach-Object { $_.Trim() })
                    $null = @($items | ForEach-Object { Get-WorkshopId $_ })
                    $account = $null
                    if (Test-WorkshopNeedsLogin -Items $items -Action $cfg.Action) {
                        if ($cfg.Accounts.Count -eq 1) { $account = $cfg.Accounts[0] }
                        else { $account = Select-Account $cfg }
                        if (-not $account) { continue }
                        Write-MenuFrame 'Download / Convert Wallpaper'
                    }
                    Invoke-WallpaperDownload -Items $items -Account $account -Action $cfg.Action -OutputDir $cfg.OutputDir -NoArchive:(-not $cfg.CreateArchive) | ForEach-Object { Show-Result $_ }
                }
                2 { Invoke-SettingsMenu }
            }
            if ($selection -in @(0, 1)) { Wait-MenuContinue }
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            Wait-MenuContinue
        }
    }
}

# Dot-sourcing exposes functions for tests without starting a menu or downloading anything.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        if ($Mode -eq 'Menu') { Invoke-SteamLivelyBridge }
        else {
            $cfg = Load-Config
            if (-not $OutputDirectory) { $OutputDirectory = $cfg.OutputDir }
            switch ($Mode) {
                'Login' {
                    Invoke-SteamCommand -Account $Username
                    Write-Host 'Steam login confirmed.' -ForegroundColor Green
                }
                'Convert' {
                    if (-not $InputPath) { throw 'Convert mode requires -InputPath.' }
                    Process-WallpaperFiles -ItemPath $InputPath -OutputDir $OutputDirectory -NoArchive:($NoArchive -or -not $cfg.CreateArchive) | ForEach-Object { Show-Result $_ }
                }
                'Download' {
                    if (-not $Workshop) { throw 'Download mode requires -Workshop.' }
                    if (Test-WorkshopNeedsLogin -Items $Workshop -Action $Action) { Assert-Username $Username }
                    Invoke-WallpaperDownload -Items $Workshop -Account $Username -Action $Action -OutputDir $OutputDirectory -NoArchive:($NoArchive -or -not $cfg.CreateArchive) | ForEach-Object { Show-Result $_ }
                }
            }
        }
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}
