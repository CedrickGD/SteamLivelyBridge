# Scene projects need an actual renderer. Use the installed Wallpaper Engine plus
# the MIT-licensed wp2video capture backend, pinned to a reviewed upstream commit.
function Get-SteamLibraries {
    $steam = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return }
    $libraries = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($line in Get-Content -LiteralPath $vdf) {
            if ($line -match '"path"\s+"([^"]+)"') { $libraries += ($Matches[1] -replace '\\\\', '\') }
        }
    }
    $libraries | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique
}

function Find-InstalledWorkshopItem {
    param([string]$Id)
    $id = Get-WorkshopId $Id
    foreach ($library in Get-SteamLibraries) {
        $path = Join-Path $library "steamapps\workshop\content\431960\$id"
        if (Test-Path -LiteralPath (Join-Path $path 'project.json') -PathType Leaf) { return $path }
    }
}

function Install-SceneDependencies {
    $engine = @(Get-SteamLibraries | ForEach-Object { Join-Path $_ 'steamapps\common\wallpaper_engine\wallpaper64.exe' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($engine.Count -eq 0) { throw 'Scene-to-video conversion requires Wallpaper Engine installed through Steam. Its renderer is needed to preserve animation and effects.' }
    $python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) { throw 'Scene capture requires Python 3.9 or newer. Install Python, then retry.' }
    $version = & $python.Source --version 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]$version -notmatch 'Python 3\.(\d+)\.' -or [int]$Matches[1] -lt 9) {
        throw 'Scene capture requires Python 3.9 or newer on PATH.'
    }
    $directory = Join-Path $script:AppDir 'wp2video'
    Assert-NoReparsePath $directory
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    $revision = 'b6f3194c96cc1f6e60ee1382367e13c3c86a2ad0'
    foreach ($name in @('wp2video.py', 'LICENSE')) {
        $target = Join-Path $directory $name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/unio207/wp2video/$revision/$name" -OutFile $target -TimeoutSec 60 -ErrorAction Stop
        }
    }
    $ffmpeg = Join-Path $directory 'ffmpeg.exe'
    if (-not (Test-Path -LiteralPath $ffmpeg -PathType Leaf)) {
        Write-Host 'Installing FFmpeg for scene capture (about 110 MB, first use only)...' -ForegroundColor Cyan
        $zip = Join-Path $directory ('ffmpeg-' + [guid]::NewGuid().ToString('N') + '.zip')
        $previousProgress = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
            $checksum = (Invoke-WebRequest -UseBasicParsing -Uri ($url + '.sha256') -TimeoutSec 30 -ErrorAction Stop).Content
            if ($checksum -notmatch '\b([a-fA-F0-9]{64})\b') { throw 'Could not read the FFmpeg archive checksum.' }
            $expected = $Matches[1]
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip -TimeoutSec 240 -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) { throw 'FFmpeg download checksum did not match. Retry the download.' }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
                    $entry = @($archive.Entries | Where-Object { $_.FullName -match ('/bin/' + [regex]::Escape($name) + '$') })
                    if ($entry.Count -ne 1) { throw "FFmpeg archive is missing $name." }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry[0], (Join-Path $directory $name), $false)
                }
                $license = $archive.Entries | Where-Object { $_.FullName -match '/LICENSE$' } | Select-Object -First 1
                if ($license) { [IO.Compression.ZipFileExtensions]::ExtractToFile($license, (Join-Path $directory 'LICENSE-FFmpeg.txt'), $true) }
            } finally { $archive.Dispose() }
        } finally {
            $ProgressPreference = $previousProgress
            if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        }
    }
    return [pscustomobject]@{ Python = $python.Source; Backend = (Join-Path $directory 'wp2video.py'); FFmpeg = $ffmpeg }
}

function Test-WorkshopNeedsLogin {
    param([string[]]$Items, [string]$Action)
    if ($Action -eq 'ConvertOnly') { return $false }
    if ($Action -eq 'DownloadOnly') { return $true }
    foreach ($item in $Items) {
        if (-not (Find-InstalledWorkshopItem (Get-WorkshopId $item))) { return $true }
    }
    return $false
}

function Convert-SceneWallpaper {
    param([string]$ItemPath, [string]$WorkshopId, [string]$OutputDir, [string]$Title, [switch]$NoArchive)
    $dependencies = Install-SceneDependencies
    $sourceProject = Get-Content -LiteralPath (Join-Path $ItemPath 'project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $Title -or $Title -eq $WorkshopId) { $Title = $sourceProject.title }
    $destination = Get-FullPath $OutputDir
    Assert-NoReparsePath $destination
    New-Item -ItemType Directory -Path $destination -Force -ErrorAction Stop | Out-Null
    $stage = Join-Path $destination ('.slb-' + [guid]::NewGuid().ToString('N') + '.tmp')
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
    try {
        Write-Host "Rendering scene to $script:SceneResolution, $script:SceneFPS fps, $script:SceneSeconds seconds. Please leave Wallpaper Engine running." -ForegroundColor Cyan
        $runner = Join-Path $script:Root 'CaptureScene.py'
        $captureArguments = @('-u', $runner, $dependencies.Backend, $ItemPath, $script:SceneResolution, [string]$script:SceneFPS, [string]$script:SceneSeconds, 'mp4', $stage, '--seamless')
        if ($script:WallpaperProperties) { $captureArguments += @('--properties', (Get-FullPath $script:WallpaperProperties)) }
        if ($script:WallpaperLocation) { $captureArguments += @('--location', $script:WallpaperLocation) }
        if ($script:WallpaperProfile) { $captureArguments += @('--profile', $script:WallpaperProfile) }
        & $dependencies.Python @captureArguments | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw 'Scene recording failed. Check the renderer/capture error above. Original wallpaper files were preserved.' }
        $videos = @(Get-ChildItem -LiteralPath $stage -File -Filter '*.mp4')
        if ($videos.Count -ne 1 -or $videos[0].Length -eq 0) { throw 'Scene capture did not produce a video.' }
        Write-JsonFile -Path (Join-Path $stage 'project.json') -Value @{ type = 'video'; file = $videos[0].Name; title = $Title }
        $preview = Join-Path $ItemPath 'preview.jpg'
        if (Test-Path -LiteralPath $preview -PathType Leaf) { Copy-Item -LiteralPath $preview -Destination (Join-Path $stage 'preview.jpg') }
        return Process-WallpaperFiles -ItemPath $stage -WorkshopId $WorkshopId -OutputDir $destination -Title $Title -NoArchive:$NoArchive
    } finally { if (Test-Path -LiteralPath $stage) { Remove-StagingFolder -Root $destination -Path $stage } }
}
