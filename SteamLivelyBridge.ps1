<#
SteamLivelyBridge
A CLI tool to download and convert Steam Wallpaper Engine Wallpapers for Lively Wallpaper.
#>

$ErrorActionPreference = "Stop"
$script:AppName = "SteamLivelyBridge"
$script:MenuNormalColor = [ConsoleColor]::Gray
$script:MenuHighlightColor = [ConsoleColor]::Cyan
$script:MenuPointerSymbol = ">"

try { $Host.UI.RawUI.WindowTitle = "SteamLivelyBridge" } catch {}

$script:AppDir = Join-Path $PSScriptRoot "bin"
$script:SteamCmdDir = Join-Path $script:AppDir "steamcmd"
$script:SteamCmdExe = Join-Path $script:SteamCmdDir "steamcmd.exe"
$script:RePkgExe = Join-Path $script:AppDir "repkg.exe"
$script:DownloadsDir = Join-Path $PSScriptRoot "downloads"
$script:DefaultOutputDir = Join-Path $PSScriptRoot "lively_wallpapers"

function Set-ConsoleCursorPosition {
    param([int]$X, [int]$Y)
    try { [Console]::SetCursorPosition($X, $Y) } catch {}
}

function Write-MenuFrame {
    param([string]$Title)
    Clear-Host
    Write-Host "==============================================" -ForegroundColor DarkGray
    Write-Host "   $Title" -ForegroundColor White
    Write-Host "==============================================" -ForegroundColor DarkGray
    Write-Host ""
}

function Flush-KeyBuffer {
    while ($Host.UI.RawUI.KeyAvailable) {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown,IncludeKeyUp")
    }
}

function Show-Message {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Message -ForegroundColor $Color
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    Flush-KeyBuffer
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Read-PasswordWithToggle {
    param([string]$Prompt)
    Write-Host "$Prompt (Press F2 to toggle visibility): " -NoNewline -ForegroundColor Cyan
    $password = ""
    $visible = $false
    
    while ($true) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown,IncludeKeyUp")
        if ($key.KeyDown -eq $false) { continue }
        
        if ($key.VirtualKeyCode -eq 13) { # Enter
            Write-Host ""
            break
        } elseif ($key.VirtualKeyCode -eq 8) { # Backspace
            if ($password.Length -gt 0) {
                $password = $password.Substring(0, $password.Length - 1)
                Write-Host "`b `b" -NoNewline
            }
        } elseif ($key.VirtualKeyCode -eq 113) { # F2
            $visible = -not $visible
            $len = $password.Length
            if ($len -gt 0) {
                Write-Host ("`b" * $len + " " * $len + "`b" * $len) -NoNewline
            }
            if ($visible) {
                Write-Host $password -NoNewline
            } else {
                Write-Host ("*" * $len) -NoNewline
            }
        } elseif ($key.Character -ne 0) {
            $password += $key.Character
            if ($visible) {
                Write-Host $key.Character -NoNewline
            } else {
                Write-Host "*" -NoNewline
            }
        }
    }
    return $password
}

function Load-Config {
    $configPath = Join-Path $script:AppDir "config.json"
    if (Test-Path $configPath) {
        $cfg = Get-Content -Path $configPath | ConvertFrom-Json
        if (-not $cfg.Accounts) { Add-Member -InputObject $cfg -MemberType NoteProperty -Name Accounts -Value @() }
        if (-not $cfg.OutputDir) { Add-Member -InputObject $cfg -MemberType NoteProperty -Name OutputDir -Value $script:DefaultOutputDir }
        if (-not $cfg.Action) { Add-Member -InputObject $cfg -MemberType NoteProperty -Name Action -Value "Both" }
        return $cfg
    }
    return @{ Accounts = @(); OutputDir = $script:DefaultOutputDir; Action = "Both" }
}

function Save-Config {
    param($Config)
    $configPath = Join-Path $script:AppDir "config.json"
    $Config | ConvertTo-Json | Set-Content -Path $configPath
}

function Install-Dependencies {
    if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir | Out-Null }
    if (-not (Test-Path $script:SteamCmdDir)) { New-Item -ItemType Directory -Path $script:SteamCmdDir | Out-Null }
    if (-not (Test-Path $script:DownloadsDir)) { New-Item -ItemType Directory -Path $script:DownloadsDir | Out-Null }

    if (-not (Test-Path $script:SteamCmdExe)) {
        Write-Host "Downloading SteamCMD..." -ForegroundColor Cyan
        $zipPath = Join-Path $script:SteamCmdDir "steamcmd.zip"
        Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $script:SteamCmdDir -Force
        Remove-Item $zipPath -Force
    }
}

function Read-MenuSelection {
    param(
        [string]$Title,
        [string[]]$Options
    )
    $selected = 0
    $optionsCount = $Options.Length

    Write-MenuFrame -Title $Title
    $top = [Console]::CursorTop

    while ($true) {
        Set-ConsoleCursorPosition -X 0 -Y $top
        
        for ($i = 0; $i -lt $optionsCount; $i++) {
            if ($i -eq $selected) {
                Write-Host " $script:MenuPointerSymbol $($Options[$i])".PadRight(50) -ForegroundColor $script:MenuHighlightColor
            } else {
                Write-Host "   $($Options[$i])".PadRight(50) -ForegroundColor $script:MenuNormalColor
            }
        }
        
        Write-Host "`nUse Up/Down arrows to select, Enter to confirm.".PadRight(60) -ForegroundColor DarkGray

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        if ($key.VirtualKeyCode -eq 38) { # Up
            $selected = ($selected - 1 + $optionsCount) % $optionsCount
        } elseif ($key.VirtualKeyCode -eq 40) { # Down
            $selected = ($selected + 1) % $optionsCount
        } elseif ($key.VirtualKeyCode -eq 13) { # Enter
            return $selected
        }
    }
}

function Invoke-SteamLogin {
    $cfg = Load-Config
    
    $opts = @()
    foreach ($acc in $cfg.Accounts) {
        $opts += "Login as $acc"
    }
    $opts += "Add New Account"
    $opts += "Back"
    
    $sel = Read-MenuSelection -Title "Select Account to Login" -Options $opts
    
    if ($sel -eq $opts.Length - 1) { return } # Back
    
    $username = ""
    if ($sel -eq $opts.Length - 2) {
        Clear-Host
        $username = Read-Host "Enter Steam Username"
        if ([string]::IsNullOrWhiteSpace($username)) { return }
        if ($cfg.Accounts -notcontains $username) {
            $cfg.Accounts += $username
            Save-Config -Config $cfg
        }
    } else {
        $username = $cfg.Accounts[$sel]
    }
    
    Clear-Host
    Write-Host "SteamCMD will now prompt you for login details." -ForegroundColor Cyan
    Write-Host "Note: If you have Steam Guard, you will need your code." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Logging in as $username..." -ForegroundColor Green
    
    $plainPass = Read-PasswordWithToggle -Prompt "Enter Steam Password (or leave blank if cached)"

    if ([string]::IsNullOrWhiteSpace($plainPass)) {
        $args = @("+login", $username, "+quit")
    } else {
        $args = @("+login", $username, $plainPass, "+quit")
    }
    
    try {
        $oldError = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & $script:SteamCmdExe $args
    } catch {
        Write-Host "An error occurred while launching SteamCMD." -ForegroundColor Red
    } finally {
        $ErrorActionPreference = $oldError
    }
    
    Show-Message "`nLogin process completed." -Color Green
}

function Get-WorkshopTitle {
    param([string]$Id)
    try {
        $url = "https://steamcommunity.com/sharedfiles/filedetails/?id=$Id"
        $page = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        if ($page.Content -match '<div class="workshopItemTitle">([^<]+)</div>') {
            $title = $matches[1].Trim()
            $title = $title -replace '[\\/:*?"<>|]', '_'
            return $title
        }
    } catch {}
    return $Id
}

function Get-WorkshopTags {
    param([string]$Id)
    try {
        $body = @{ itemcount = 1; "publishedfileids[0]" = $Id }
        $resp = Invoke-RestMethod -Uri "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" -Method Post -Body $body -ErrorAction Stop
        if ($resp.response.publishedfiledetails.Count -gt 0) {
            return $resp.response.publishedfiledetails[0].tags | Select-Object -ExpandProperty tag
        }
    } catch {}
    return @()
}

function Invoke-DownloadWallpaper {
    $cfg = Load-Config
    Write-MenuFrame -Title "Download / Convert Wallpaper"
    Write-Host "To find the ID, copy the URL of the Steam Workshop page." -ForegroundColor Gray
    Write-Host "Example: https://steamcommunity.com/sharedfiles/filedetails/?id=3648988375" -ForegroundColor Gray
    Write-Host ""
    $workshopInput = Read-Host "Enter Workshop ID or full URL"
    if ([string]::IsNullOrWhiteSpace($workshopInput)) { return }
    
    $workshopId = ""
    if ($workshopInput -match "id=(\d+)") {
        $workshopId = $matches[1]
    } elseif ($workshopInput -match "^\d+$") {
        $workshopId = $workshopInput
    } else {
        Show-Message "Invalid input. Could not find a numeric ID in your entry." -Color Red
        return
    }

    Write-Host "Analyzing Workshop Item..." -ForegroundColor DarkGray
    $tags = Get-WorkshopTags -Id $workshopId
    if ($tags -contains "Scene") {
        Write-Host "Warning: This is a Scene wallpaper. There is no real video file to convert." -ForegroundColor Yellow
        $continue = Read-Host "Do you still want to download the raw files anyway? (Y/N)"
        if ($continue -notmatch "^[Yy]") {
            Show-Message "Download cancelled." -Color Cyan
            return
        }
    }

    $downloadPath = Join-Path $script:SteamCmdDir "steamapps\workshop\content\431960\$workshopId"

    if ($cfg.Action -ne "ConvertOnly") {
        Write-Host "`nDownloading Workshop ID $workshopId ..." -ForegroundColor Cyan
        
        $username = ""
        if ($cfg.Accounts.Count -eq 0) {
            $username = Read-Host "Enter your Steam Username (needed for cached session)"
            if ([string]::IsNullOrWhiteSpace($username)) { return }
            $cfg.Accounts += $username
            Save-Config -Config $cfg
        } elseif ($cfg.Accounts.Count -eq 1) {
            $username = $cfg.Accounts[0]
            Write-Host "Using saved account: $username" -ForegroundColor Cyan
        } else {
            $opts = @()
            foreach ($acc in $cfg.Accounts) { $opts += "Use $acc" }
            $sel = Read-MenuSelection -Title "Select Account for Download" -Options $opts
            $username = $cfg.Accounts[$sel]
            Clear-Host
            Write-Host "`nDownloading Workshop ID $workshopId as $username ..." -ForegroundColor Cyan
        }

        $args = @("+login", $username, "+workshop_download_item", "431960", $workshopId, "+quit")
        
        try {
            $oldError = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            & $script:SteamCmdExe $args
        } catch {
            Write-Host "Error during download process." -ForegroundColor Red
        } finally {
            $ErrorActionPreference = $oldError
        }
    }
    
    if ($cfg.Action -ne "DownloadOnly") {
        if (-not (Test-Path $downloadPath)) {
            Show-Message "Conversion failed. Could not find downloaded files at $downloadPath" -Color Red
            return
        }

        Write-Host "Fetching wallpaper details..." -ForegroundColor Cyan
        $wpTitle = Get-WorkshopTitle -Id $workshopId
        Write-Host "Processing files for '$wpTitle'..." -ForegroundColor Green
        Process-WallpaperFiles -ItemPath $downloadPath -WorkshopId $workshopId -OutputDir $cfg.OutputDir -Title $wpTitle
    } else {
        Show-Message "Download only completed. Skipping conversion." -Color Green
    }
}

function Process-WallpaperFiles {
    param([string]$ItemPath, [string]$WorkshopId, [string]$OutputDir, [string]$Title)

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

    $outFolder = Join-Path $OutputDir $Title
    if (Test-Path $outFolder) { Remove-Item -Path $outFolder -Recurse -Force }
    New-Item -ItemType Directory -Path $outFolder | Out-Null

    # Copy all original files over directly
    Copy-Item -Path "$ItemPath\*" -Destination $outFolder -Recurse -Force

    $files = Get-ChildItem -Path $outFolder

    # Check for video files
    $videoFile = $files | Where-Object { $_.Extension -match "\.(mp4|webm|avi|mov)$" } | Select-Object -First 1
    if ($null -ne $videoFile) {
        Write-LivelyInfo -Folder $outFolder -Id $WorkshopId -Title $Title -File $videoFile.Name -Type "Video"
        Show-Message "Video successfully processed into '$Title'" -Color Green
        return
    }

    # Check for Web wallpaper
    $htmlFile = $files | Where-Object { $_.Name -eq "index.html" } | Select-Object -First 1
    if ($null -ne $htmlFile) {
        Write-LivelyInfo -Folder $outFolder -Id $WorkshopId -Title $Title -File "index.html" -Type "Web"
        Show-Message "Web wallpaper successfully processed into '$Title'" -Color Green
        return
    }

    # Check for Scene PKG wallpaper
    $pkgFile = $files | Where-Object { $_.Extension -eq ".pkg" } | Select-Object -First 1
    if ($null -ne $pkgFile) {
        Write-LivelyInfo -Folder $outFolder -Id $WorkshopId -Title $Title -File $pkgFile.Name -Type "Scene (PKG)"
        Write-Host "Note: Lively doesn't natively run .pkg scene files directly." -ForegroundColor Yellow
        Show-Message "Scene wallpaper downloaded into '$Title'." -Color Green
        return
    }

    Write-LivelyInfo -Folder $outFolder -Id $WorkshopId -Title $Title -File "" -Type "Unknown"
    Show-Message "Files copied to '$Title', but no supported lively format (video/html) found." -Color Yellow
}

function Write-LivelyInfo {
    param([string]$Folder, [string]$Id, [string]$Title, [string]$File, [string]$Type)
    $info = @{
        AppVersion = "1.0"
        Title = $Title
        Thumbnail = "preview.jpg"
        Preview = "preview.jpg"
        Desc = "$Type Wallpaper generated by SteamLivelyBridge"
        Author = "SteamLivelyBridge"
        IsAbsolute = $false
        FileName = $File
    }
    $json = $info | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $Folder "LivelyInfo.json") -Value $json
}

function Invoke-SettingsMenu {
    while ($true) {
        $cfg = Load-Config
        $opts = @(
            "Change Action [Current: $($cfg.Action)]",
            "Change Output Directory",
            "Open Output Directory",
            "Back"
        )
        $sel = Read-MenuSelection -Title "Settings" -Options $opts
        switch ($sel) {
            0 {
                if ($cfg.Action -eq "Both") { $cfg.Action = "DownloadOnly" }
                elseif ($cfg.Action -eq "DownloadOnly") { $cfg.Action = "ConvertOnly" }
                else { $cfg.Action = "Both" }
                Save-Config -Config $cfg
            }
            1 {
                Clear-Host
                Write-Host "Current Directory: $($cfg.OutputDir)" -ForegroundColor Cyan
                $newPath = Read-Host "Enter new output directory path (or leave blank to cancel)"
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $cfg.OutputDir = $newPath
                    Save-Config -Config $cfg
                }
            }
            2 {
                if (-not (Test-Path $cfg.OutputDir)) { New-Item -ItemType Directory -Path $cfg.OutputDir | Out-Null }
                Start-Process $cfg.OutputDir
            }
            3 { return }
        }
    }
}

function Invoke-SteamLivelyBridge {
    Install-Dependencies

    while ($true) {
        $options = @(
            "Login to Steam",
            "Download / Convert Wallpaper",
            "Settings",
            "Exit"
        )
        $sel = Read-MenuSelection -Title "SteamLivelyBridge Main Menu" -Options $options
        
        switch ($sel) {
            0 { Invoke-SteamLogin }
            1 { Invoke-DownloadWallpaper }
            2 { Invoke-SettingsMenu }
            3 { 
                Clear-Host
                Write-Host "Goodbye!"
                exit 0 
            }
        }
    }
}

Invoke-SteamLivelyBridge
