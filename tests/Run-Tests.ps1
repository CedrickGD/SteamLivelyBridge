#requires -Version 5.1
# Offline regression suite. All fixtures, config, and the fake SteamCMD stay in a unique temp folder.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\SteamLivelyBridge.ps1')
$script:Passed = 0
$script:Failed = 0
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('steamlively-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
$script:AppDir = Join-Path $script:TestRoot 'bin'
$script:SteamCmdDir = Join-Path $script:AppDir 'steamcmd'
$script:SteamCmdExe = Join-Path $script:SteamCmdDir 'steamcmd.exe'
$script:ConfigPath = Join-Path $script:AppDir 'config.json'
$script:DefaultOutputDir = Join-Path $script:TestRoot 'output'

function Assert {
    param([bool]$Condition, [string]$Message = 'Assertion failed')
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern = '.')
    try { & $Body | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
        return
    }
    throw 'Expected an error, but the operation succeeded.'
}
function Test {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function New-Fixture {
    param([string]$Name, [hashtable]$Files)
    $path = Join-Path $script:TestRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    foreach ($name in $Files.Keys) {
        $file = Join-Path $path $name
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($file)) -Force | Out-Null
        [IO.File]::WriteAllText($file, $Files[$name], (New-Object Text.UTF8Encoding($false)))
    }
    return $path
}

try {
    Test 'dot sourcing does not install dependencies' { Assert (-not (Test-Path -LiteralPath $script:AppDir)) }
    Test 'arrow menu selects with Enter, wraps at either end, and Escape goes back' {
        function Write-MenuFrame { }
        function Set-ConsoleCursorPosition { }
        function Read-MenuKey {
            if ($script:MenuKeys.Count -eq 0) { throw 'Menu requested an unexpected key.' }
            return [pscustomobject]@{ VirtualKeyCode = $script:MenuKeys.Dequeue() }
        }
        foreach ($case in @(
            @{ Keys = @(40, 40, 13); Expected = 2 },
            @{ Keys = @(38, 13); Expected = 2 },
            @{ Keys = @(40, 40, 40, 13); Expected = 0 },
            @{ Keys = @(65, 13); Expected = 0 },
            @{ Keys = @(27); Expected = -1 }
        )) {
            $script:MenuKeys = New-Object 'System.Collections.Generic.Queue[int]'
            foreach ($code in $case.Keys) { $script:MenuKeys.Enqueue($code) }
            $selected = Read-MenuSelection -Title 'Menu test' -Options @('First', 'Second', 'Third') 6>$null
            Assert ($selected -eq $case.Expected) 'Menu selected the wrong item.'
        }
    }
    Test 'main menu preserves the original four choices and order' {
        function Read-MenuSelection {
            param($Title, $Options)
            $script:SeenMainOptions = $Options
            return 3
        }
        Invoke-SteamLivelyBridge
        Assert (($script:SeenMainOptions -join '|') -eq 'Login to Steam|Download / Convert Wallpaper|Settings|Exit')
    }
    Test 'IDs and official URLs accepted; unrelated URLs and command input rejected' {
        Assert ((Get-WorkshopId ' 123456 ') -eq '123456')
        Assert ((Get-WorkshopId 'https://steamcommunity.com/sharedfiles/filedetails/?id=123456&x=y') -eq '123456')
        foreach ($bad in @('0', 'https://example.com/?id=123', 'https://steamcommunity.com.evil.test/sharedfiles/filedetails/?id=123', '123 +quit', '../123', 'https://steamcommunity.com/sharedfiles/filedetails/?id=123abc')) {
            Assert-Throws { Get-WorkshopId $bad }
        }
        Assert-Throws { Assert-Username '+quit' }
        Assert-Throws { Assert-Username 'user name' }
    }
    Test 'empty account arrays load and config updates atomically' {
        $config = Load-Config
        Assert ($config.Accounts.Count -eq 0)
        Save-Config $config
        $config = Load-Config
        Assert ($config.Accounts.Count -eq 0)
        $config.Accounts = @('account1')
        Save-Config $config
        Assert ((Load-Config).Accounts[0] -eq 'account1')
        Assert (@(Get-ChildItem -LiteralPath $script:AppDir -Filter '*.tmp').Count -eq 0)
    }
    Test 'legacy config defaults and malformed config preservation' {
        [IO.File]::WriteAllText($script:ConfigPath, '{"Accounts":[],"Action":"invalid","OutputDir":""}')
        $config = Load-Config
        Assert ($config.Action -eq 'Both' -and $config.CreateArchive -eq $true)
        [IO.File]::WriteAllText($script:ConfigPath, '{broken')
        Assert-Throws { Load-Config } 'preserved'
        Assert ([IO.File]::ReadAllText($script:ConfigPath) -eq '{broken')
        Remove-Item -LiteralPath $script:ConfigPath
    }
    $video = New-Fixture 'video [fixture]' @{
        'project.json' = '{"type":"video","file":"media/main.mp4","title":"Night: Sky","preview":"preview.png"}'
        'media/main.mp4' = 'main video'; 'preview.mp4' = 'not the entry'; 'preview.png' = 'image'; '.hidden' = 'asset'
    }
    $script:FirstResult = $null
    Test 'project entry wins over preview; Lively schema and ZIP root are correct' {
        $script:FirstResult = Process-WallpaperFiles -ItemPath $video -WorkshopId '111' -OutputDir $script:DefaultOutputDir
        $info = Get-Content -LiteralPath (Join-Path $script:FirstResult.Folder 'LivelyInfo.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($info.Type -eq 7 -and -not $info.IsAbsolutePath)
        Assert ($info.FileName -eq 'media\main.mp4' -and $info.Thumbnail -eq 'preview.png')
        Assert ($info.Contact -match 'id=111$')
        Assert (Test-Path -LiteralPath (Join-Path $script:FirstResult.Folder '.hidden'))
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($script:FirstResult.Archive)
        try {
            $names = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
            Assert ($names -contains 'LivelyInfo.json')
            Assert ($names -contains 'media/main.mp4')
            Assert ($names -contains '.hidden')
        } finally { $archive.Dispose() }
    }
    Test 'repeat conversion preserves existing output and source data' {
        $sentinel = Join-Path $script:FirstResult.Folder 'keep.txt'
        [IO.File]::WriteAllText($sentinel, 'keep me')
        $result = Process-WallpaperFiles -ItemPath $video -WorkshopId '111' -OutputDir $script:DefaultOutputDir -NoArchive
        Assert ($result.Folder -ne $script:FirstResult.Folder)
        Assert ([IO.File]::ReadAllText($sentinel) -eq 'keep me')
        Assert ([IO.File]::ReadAllText((Join-Path $video 'media/main.mp4')) -eq 'main video')
        Assert ($null -eq $result.Archive)
    }
    Test 'web projects support nested entry paths and retain assets' {
        $web = New-Fixture 'web' @{ 'project.json' = '{"type":"web","file":"site/start.htm","title":"Web"}'; 'site/start.htm' = '<html></html>'; 'site/style.css' = 'body{}' }
        $result = Process-WallpaperFiles -ItemPath $web -OutputDir $script:DefaultOutputDir -NoArchive -WarningAction SilentlyContinue
        $info = Get-Content -LiteralPath (Join-Path $result.Folder 'LivelyInfo.json') -Raw | ConvertFrom-Json
        Assert ($info.Type -eq 1 -and $info.FileName -eq 'site\start.htm')
        Assert ($null -eq $info.Thumbnail -and $null -eq $info.Preview)
        Assert (Test-Path -LiteralPath (Join-Path $result.Folder 'site/style.css'))
    }
    Test 'Unicode titles round trip in UTF-8 metadata' {
        $title = 'Night ' + [char]0x591c + [char]0x00e9
        $result = Process-WallpaperFiles -ItemPath $video -Title $title -OutputDir $script:DefaultOutputDir -NoArchive
        $info = Get-Content -LiteralPath (Join-Path $result.Folder 'LivelyInfo.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($info.Title -eq $title)
    }
    Test 'missing project falls back only when entry selection is unambiguous' {
        $single = New-Fixture 'single' @{ 'wallpaper.mkv' = 'video'; 'preview.mp4' = 'preview' }
        Assert ((Get-WallpaperProject $single).File -eq 'wallpaper.mkv')
        $ambiguous = New-Fixture 'ambiguous' @{ 'a.mp4' = 'a'; 'b.mp4' = 'b' }
        Assert-Throws { Get-WallpaperProject $ambiguous } 'possible entry files'
    }
    Test 'scene projects use real capture instead of their preview video' {
        $scene = New-Fixture 'scene' @{ 'project.json' = '{"type":"scene","file":"scene.pkg"}'; 'scene.pkg' = 'scene'; 'preview.mp4' = 'preview' }
        Assert ((Get-WallpaperProject $scene).Type -eq 'scene')
        function Convert-SceneWallpaper {
            param($ItemPath, $WorkshopId, $OutputDir, $Title, [switch]$NoArchive)
            Assert ($ItemPath -eq $scene)
            return [pscustomobject]@{ Type = 'video'; Folder = 'captured-scene'; Archive = $null }
        }
        Assert ((Process-WallpaperFiles -ItemPath $scene -OutputDir $script:DefaultOutputDir -NoArchive).Folder -eq 'captured-scene')
        Remove-Item -LiteralPath (Join-Path $scene 'project.json')
        Assert-Throws { Get-WallpaperProject $scene } 'PKG'
        Assert (Test-Path -LiteralPath (Join-Path $scene 'scene.pkg'))
    }
    Test 'path traversal, missing entry, and source/output overlap rejected before copying' {
        $bad = New-Fixture 'bad' @{ 'project.json' = '{"type":"video","file":"../outside.mp4"}'; 'asset' = 'data' }
        Assert-Throws { Get-WallpaperProject $bad } 'escapes'
        [IO.File]::WriteAllText((Join-Path $bad 'project.json'), '{"type":"video","file":"missing.mp4"}')
        Assert-Throws { Get-WallpaperProject $bad } 'missing'
        Assert-Throws { Process-WallpaperFiles -ItemPath $video -OutputDir (Join-Path $video 'output') } 'outside the source'
        Assert-Throws { Process-WallpaperFiles -ItemPath $video -OutputDir $video } 'outside the source'
        Assert (-not (Test-Path -LiteralPath (Join-Path $video 'output')))
    }
    Test 'unsafe folder names and staging cleanup boundaries' {
        Assert ((Get-SafeFolderName 'CON') -eq '_CON')
        Assert ((Get-SafeFolderName '../bad:*?') -notmatch '[/\\:*?]')
        Assert ((Get-SafeFolderName '..') -eq 'Wallpaper')
        Assert-Throws { Remove-StagingFolder -Root $script:DefaultOutputDir -Path $video } 'Refusing'
        Assert (Test-Path -LiteralPath $video)
    }
    Test 'source junctions are rejected without touching their targets' {
        $linked = New-Fixture 'linked-project' @{ 'video.mp4' = 'video' }
        $outside = New-Fixture 'junction-target' @{ 'keep.txt' = 'keep me' }
        $link = Join-Path $linked 'linked-assets'
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        try {
            Assert-Throws { Process-WallpaperFiles -ItemPath $linked -OutputDir $script:DefaultOutputDir } 'Linked content'
            Assert ([IO.File]::ReadAllText((Join-Path $outside 'keep.txt')) -eq 'keep me')
        } finally { [IO.Directory]::Delete($link) }
    }
    Test 'command line converts offline with spaces and brackets in paths' {
        $cliDir = Join-Path $script:TestRoot 'cli copy'
        New-Item -ItemType Directory -Path $cliDir | Out-Null
        $cliScript = Join-Path $cliDir 'SteamLivelyBridge.ps1'
        Copy-Item -LiteralPath (Join-Path $script:Root 'SteamLivelyBridge.ps1') -Destination $cliScript
        Copy-Item -LiteralPath (Join-Path $script:Root 'SceneCapture.ps1') -Destination (Join-Path $cliDir 'SceneCapture.ps1')
        $cliOutput = Join-Path $script:TestRoot 'cli output [test]'
        $terminal = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $null = & $terminal -NoProfile -ExecutionPolicy Bypass -File $cliScript -Mode Convert -InputPath $video -OutputDirectory $cliOutput -NoArchive
        Assert ($LASTEXITCODE -eq 0)
        Assert (@(Get-ChildItem -LiteralPath $cliOutput -Directory).Count -eq 1)
        Assert (-not (Test-Path -LiteralPath (Join-Path $cliDir 'bin')))
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $null = & $terminal -NoProfile -ExecutionPolicy Bypass -File $cliScript -Mode Convert -InputPath (Join-Path $cliDir 'missing') 2>$null
            $failureCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        Assert ($failureCode -eq 1)
    }
    Test 'authentication attempt and pending/failed 2FA never count as login' {
        foreach ($output in @('Logging in using username/password.', "Logging in user 'name'...OK`nWaiting for confirmation...", 'Two-factor code:', 'ERROR! Failed to log on (Invalid Password)', ("Waiting for user info...OK`nERROR! Two-factor code mismatch"))) {
            Assert-Throws { Assert-SteamResult ([pscustomobject]@{ ExitCode = 0; Output = $output }) }
        }
        Assert-Throws { Assert-SteamResult ([pscustomobject]@{ ExitCode = 5; Output = 'Waiting for user info...OK' }) } 'code 5'
        Assert-SteamResult ([pscustomobject]@{ ExitCode = 0; Output = "Logging in user...OK`nWaiting for user info...OK" })
        # SteamCMD may let a user recover from a mistyped password during the same session.
        Assert-SteamResult ([pscustomobject]@{ ExitCode = 0; Output = "Invalid Password`nWaiting for user info...OK" })
    }
    Test 'real SteamCMD timestamped multiline login completion is recognized' {
        $completed = "[2026-10-19 22:04:19] Waiting for client config...`r`n[2026-10-19 22:04:27] OK`r`n[2026-10-19 22:04:27] Waiting for user info...`r`n[2026-10-19 22:05:01] OK`r`n[2026-10-19 22:05:01] Unloading Steam API...`r`n[2026-10-19 22:05:01] OK"
        Assert-SteamResult ([pscustomobject]@{ ExitCode = 0; Output = $completed })
        Assert-SteamResult ([pscustomobject]@{ ExitCode = 0; Output = "Waiting for user info...`nOK" })
        # Earlier startup OKs, later unrelated OKs, and a pending prompt are not confirmation.
        foreach ($incomplete in @(
            "[2026-10-19 22:04:27] OK`r`n[2026-10-19 22:04:27] Waiting for user info...",
            "Waiting for user info...`nUnloading Steam API...`nOK",
            "Waiting for user info...`n[2026-10-19 22:05:01] ERROR (Timeout)`nOK"
        )) {
            Assert-Throws { Assert-SteamResult ([pscustomobject]@{ ExitCode = 0; Output = $incomplete }) }
        }
    }
    Test 'zero exit code and old cache do not prove download success' {
        Assert-Throws { Assert-SteamResult ([pscustomobject]@{ ExitCode = 0; Output = 'ERROR! Download item 111 failed (Failure).' }) '111' }
        Assert-Throws { Assert-SteamResult ([pscustomobject]@{ ExitCode = 0; Output = 'Success. Downloaded item 1111' }) '111' }
        Assert-SteamResult ([pscustomobject]@{ ExitCode = 0; Output = 'Success. Downloaded item 111 to path' }) '111'
    }
    Test 'native process shares the console and confirms only fresh session log output' {
        New-Item -ItemType Directory -Path $script:SteamCmdDir -Force | Out-Null
        $terminal = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $terminal -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Build-FakeSteamCmd.ps1') -OutputPath $script:SteamCmdExe
        Assert ($LASTEXITCODE -eq 0) 'Could not compile the fake SteamCMD executable.'
        $result = Invoke-SteamProcess @('+login', 'guard_ok', '+quit')
        Assert ($result.ExitCode -eq 0 -and $result.Output -match 'Waiting for user info')
        Invoke-SteamCommand -Account 'guard_ok'
        Assert-Throws { Invoke-SteamCommand -Account 'guard_fail' } 'reported an error'
        # A new process with no log output must not inherit the previous success marker.
        Invoke-SteamCommand -Account 'guard_ok'
        Assert-Throws { Invoke-SteamCommand -Account 'no_log' } 'could not be confirmed'
    }
    # Replace only the metadata request; the download path still executes the fake native process.
    function Invoke-RestMethod {
        param($Uri, $Method, $Body, $TimeoutSec, $ErrorAction)
        $id = $Body['publishedfileids[0]']
        $appId = 431960
        if ($id -eq '999') { $appId = 123 }
        return [pscustomobject]@{ response = @{ publishedfiledetails = @(@{ result = 1; consumer_app_id = $appId; title = 'Test &amp; Wallpaper'; tags = @() }) } }
    }
    Test 'metadata decodes titles and rejects other applications' {
        Assert ((Get-WorkshopDetails '111').Title -eq 'Test & Wallpaper')
        Assert-Throws { Get-WorkshopDetails '999' } 'not a Wallpaper Engine'
    }
    Test 'installed Steam scene uses local capture without another login or download' {
        $localScene = New-Fixture 'installed-scene' @{ 'project.json' = '{"type":"scene","file":"scene.json","title":"4k Red Moon"}'; 'scene.pkg' = 'scene' }
        function Find-InstalledWorkshopItem {
            param($Id)
            Assert ($Id -eq '3110614158')
            return $localScene
        }
        function Get-WorkshopDetails { throw 'Metadata network call was not expected.' }
        function Invoke-SteamCommand { throw 'SteamCMD login/download was not expected.' }
        Assert (-not (Test-WorkshopNeedsLogin -Items @('3110614158') -Action 'Both'))
        Assert (Test-WorkshopNeedsLogin -Items @('3110614158') -Action 'DownloadOnly')
        function Convert-SceneWallpaper {
            param($ItemPath, $WorkshopId, $OutputDir, $Title, [switch]$NoArchive)
            Assert ($ItemPath -eq $localScene -and $WorkshopId -eq '3110614158')
            return [pscustomobject]@{ Type = 'video'; Folder = 'captured'; Archive = 'captured.zip' }
        }
        $result = @(Invoke-WallpaperDownload -Items @('https://steamcommunity.com/sharedfiles/filedetails/?id=3110614158') -OutputDir $script:DefaultOutputDir)
        Assert ($result.Count -eq 1 -and $result[0].Archive -eq 'captured.zip')
    }
    Test 'batch preserves successful results, rejects failed cached items, and deduplicates IDs' {
        function Find-InstalledWorkshopItem { return $null }
        foreach ($id in @('111', '222')) {
            $cache = Join-Path $script:SteamCmdDir "steamapps\workshop\content\431960\$id"
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $cache 'wallpaper.mp4'), 'cached video')
        }
        $batchOutput = Join-Path $script:TestRoot 'batch-output'
        Assert-Throws { Invoke-WallpaperDownload -Items @('111', '111', '222') -Account 'guard_ok' -OutputDir $batchOutput -NoArchive -WarningAction SilentlyContinue } '1 of 2'
        $folders = @(Get-ChildItem -LiteralPath $batchOutput -Directory)
        Assert ($folders.Count -eq 1 -and $folders[0].Name -match '^111 -')
    }
    Test 'failure during packaging removes only its own staging files' {
        function Write-JsonFile { throw 'Simulated write failure' }
        try {
            Assert-Throws { Process-WallpaperFiles -ItemPath $video -OutputDir $script:DefaultOutputDir } 'Simulated'
            Assert (@(Get-ChildItem -LiteralPath $script:DefaultOutputDir -Force | Where-Object { $_.Name -like '.slb-*' }).Count -eq 0)
            Assert (Test-Path -LiteralPath $script:FirstResult.Archive)
        } finally { Remove-Item Function:\Write-JsonFile }
    }
} finally {
    $testPath = [IO.Path]::GetFullPath($script:TestRoot)
    $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($testPath.StartsWith($tempPath, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($testPath) -match '^steamlively-tests-[a-f0-9]{32}$') {
        $null = @(Get-SafeFiles $testPath)
        Remove-Item -LiteralPath $testPath -Recurse -Force
    } else { throw 'Refusing cleanup outside the test temp directory.' }
}
Write-Host "`n$script:Passed passed; $script:Failed failed."
if ($script:Failed) { exit 1 }
