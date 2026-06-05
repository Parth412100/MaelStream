param(
    [Parameter(Position = 0)]
    [string]$Query,

    [switch]$Auto,
    [switch]$Peerflix,
    [switch]$Aria2,
    [switch]$NoFallback,
    [switch]$Help,
    [switch]$Download,
    [Alias('o')]
    [string]$OutDir = "$env:USERPROFILE\Downloads\MaelStream",
    [Alias('e')]
    [ValidateSet('webtorrent', 'peerflix', 'aria2c')]
    [string]$Engine
)

if ($Help -or $Query -eq '-?' -or $Query -eq '--help' -or $Query -eq '/?') {
    Write-Host @"

  MaelStream v1.0 - Torrent Streaming CLI

 USAGE:
    .\watch.ps1 "movie name"              Search and stream
    .\watch.ps1 "movie name" -Auto        Auto-select best result
    .\watch.ps1 "movie name" -Download    Download (no streaming)
    .\watch.ps1 "movie name" -Engine peerflix   Use specific engine

 ENGINES:
    webtorrent (default) - WebTorrent library, best peer discovery
    peerflix              - torrent-stream backend
    aria2c                - C++ engine, fallback

 DOWNLOAD:
    -Download        Download the file instead of streaming
    -OutDir <path>   Save to this folder (default: ~\Downloads\MaelStream)

 AUTO-FALLBACK:
    If one engine fails to find peers, the next is tried automatically.
    Use -NoFallback to disable this.

 EXAMPLES:
    .\watch.ps1 "mortal kombat 2021"
    .\watch.ps1 "inception 2010" -Auto
    .\watch.ps1 "inception 2010" -Download
    .\watch.ps1 "tenet" -e peerflix

 TIPS:
    . Pick torrents with 100+ seeders for best speed
    . Close mpv to stop streaming and clean up temp files
    . For downloads, press Ctrl+C to cancel (partial file saved)
    . Run .\setup.ps1 first to install dependencies

"@ -ForegroundColor Cyan
    exit
}

$ErrorActionPreference = "Stop"
$ErrorView = "NormalView"

$C = @{ Green = "Green"; Cyan = "Cyan"; Yellow = "Yellow"; Red = "Red"; Gray = "DarkGray"; Magenta = "Magenta" }

function Section($msg) { Write-Host "`n==> $msg" -ForegroundColor $C.Cyan }
function Info($msg) { Write-Host "  $msg" -ForegroundColor $C.Gray }
function Ok($msg) { Write-Host "  [OK] $msg" -ForegroundColor $C.Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor $C.Yellow }
function Err($msg) { Write-Host "  [X] $msg" -ForegroundColor $C.Red; exit 1 }
function Tip($msg) { Write-Host "  -> $msg" -ForegroundColor $C.Magenta }

if (-not $Query) {
    Section "Usage: .\watch.ps1 `"movie name`""
    Info "Example: .\watch.ps1 `"mortal kombat 2021`""
    Info "Use -Help for full instructions.`n"
    $Query = Read-Host "Search for"
    if (-not $Query) { exit }
}

Section "Checking dependencies"

$allGood = $true

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Err "Node.js is not installed. Run: winget install OpenJS.NodeJS.LTS"
    $allGood = $false
} else { Ok "Node.js $(node --version)" }

if (-not (Get-Command mpv -ErrorAction SilentlyContinue)) {
    Err "mpv is not installed. Run: winget install mpv"
    $allGood = $false
} else { Ok "mpv" }

if (-not (Get-Command peerflix -ErrorAction SilentlyContinue)) {
    Warn "peerflix not found (auto-fallback will skip it)"
    Warn "  Install: npm install -g peerflix"
} else { Ok "peerflix" }

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not (Test-Path "$scriptDir\node_modules\webtorrent")) {
    Warn "WebTorrent library not installed"
    Warn "  Run: cd $scriptDir && npm install"
    $allGood = $false
} else { Ok "WebTorrent library" }

if (-not $allGood) {
    Write-Host "`nSome dependencies are missing. Run .\setup.ps1 to fix." -ForegroundColor $C.Yellow
    exit 1
}

$trackers = @(
    "udp://tracker.opentrackr.org:1337/announce"
    "udp://tracker.openbittorrent.com:80"
    "udp://tracker.torrent.eu.org:451"
    "udp://open.demonii.com:1337"
    "udp://exodus.desync.com:6969"
    "udp://tracker.moeking.me:6969"
    "udp://tracker.dler.org:6969"
    "https://tracker.tamersunion.org:443/announce"
    "udp://tracker.altrosky.nl:6969/announce"
    "udp://tracker.qu.ax:6969/announce"
    "wss://tracker.btorrent.xyz"
    "wss://tracker.openwebtorrent.com"
)

function Make-Magnet($hash, $name) {
    $encName = [System.Net.WebUtility]::UrlEncode($name)
    $base = "magnet:?xt=urn:btih:$hash&dn=$encName"
    foreach ($tr in $trackers) {
        $base += "&tr=$([System.Net.WebUtility]::UrlEncode($tr))"
    }
    return $base
}

Section "Searching TPB for '$Query'"
Write-Host ""

$encodedQuery = [System.Net.WebUtility]::UrlEncode($Query)
$apiUrl = "https://apibay.org/q.php?q=$encodedQuery&cat=0"
$json = ""
try { $json = curl.exe -s --max-time 15 $apiUrl 2>&1 } catch { Err "Failed to reach TPB API. Check your connection." }
$results = $json | ConvertFrom-Json

if (-not $results -or -not $results[0].id) {
    Err "No results found for '$Query'. Try different keywords."
}

$results = $results | Where-Object { [int]$_.seeders -gt 0 } | Sort-Object { [int]$_.seeders } -Descending

if ($results.Count -eq 0) {
    Err "All results have 0 seeders. Try a different movie."
}

$i = 0
foreach ($r in $results) {
    $sizeGb = [long]$r.size / 1GB
    $color = if ([int]$r.seeders -gt 100) { $C.Green } elseif ([int]$r.seeders -gt 20) { $C.Yellow } else { $C.Gray }
    Write-Host "  $i) " -NoNewline -ForegroundColor $C.Cyan
    Write-Host "$($r.name)" -ForegroundColor $color
    Write-Host "     Seeds: $($r.seeders) | Size: $('{0:N2}' -f $sizeGb) GB"
    $i++
}

$choice = 0
$userPickedEngine = $false

if ($Engine) {
    $userPickedEngine = $Engine
    if (-not $Auto) { $Auto = $true }
}

if ($Auto) {
    $choice = 0
    Ok "Auto-selected #0 ($($results[0].seeders) seeders)"
} else {
    Write-Host "`n  Choose result [0-$($results.Count-1)]" -NoNewline -ForegroundColor $C.Cyan
    Write-Host "  or: [p]eerflix [a]ria2c [d]ownload [q]uit" -ForegroundColor $C.Gray
    Write-Host "  (just press Enter for best result, auto-fallback on)" -ForegroundColor $C.Gray
    $input = Read-Host "`n  Your choice"

    if ($input -eq 'q') { Write-Host "  Bye!" -ForegroundColor $C.Cyan; exit }
    if ($input -eq 'p') { $userPickedEngine = "peerflix"; $choice = 0; Ok "Engine: Peerflix (no auto-fallback)" }
    elseif ($input -eq 'a') { $userPickedEngine = "aria2c"; $choice = 0; Ok "Engine: aria2c (no auto-fallback)" }
    elseif ($input -eq 'd') { $Download = $true; $choice = 0; $Auto = $true; Ok "Download mode (press d again or -Download flag)" }
    elseif ($input -eq '' -or $input -match '^\d+$') {
        $choice = if ($input -eq '') { 0 } else { [int]$input }
        if ($choice -ge $results.Count) { Err "Invalid choice. Pick 0-$($results.Count-1)" }
    } else { Err "Invalid choice." }
}

$selected = $results[$choice]
$hash = $selected.info_hash.ToUpper()
$name = $selected.name
$magnet = Make-Magnet $hash $name
$seeds = $selected.seeders
$totalSize = [long]$selected.size

# ─── Helper: Sanitize filename ────────────────────────────────────────────

function Sanitize-FileName($name) {
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $valid = $name.ToCharArray() | ForEach-Object {
        if ($_ -in $invalid) { '_' } else { $_ }
    }
    return -join $valid
}

# ─── Engine functions ────────────────────────────────────────────────────

function Stream-WebTorrent($magnet, $totalSize) {
    $tempDir = "$env:TEMP\wtstream_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $port = 8889
    $readyFile = "$env:TEMP\wt_ready_$(Get-Random).tmp"

    Info "WebTorrent: finding peers and starting HTTP server..."
    $proc = Start-Process -FilePath "node" -NoNewWindow -PassThru -ArgumentList @(
        "$scriptDir\stream-webtorrent.js", "$magnet", "$port", "$tempDir", "$readyFile"
    )

    $timeout = 30; $elapsed = 0
    while (!(Test-Path $readyFile) -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 2; $elapsed += 2
        if ($proc.HasExited -and !(Test-Path $readyFile)) {
            Write-Host ""
            Warn "WebTorrent engine failed - couldn't find peers."
            if (-not $proc.HasExited) { $proc.Kill() }
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            Remove-Item -Force $readyFile -ErrorAction SilentlyContinue
            return $false
        }
    }
    if (!(Test-Path $readyFile)) {
        Warn "WebTorrent timed out after 30s (no peers yet, but still trying...)"
        if (-not $proc.HasExited) { $proc.Kill() }
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        Remove-Item -Force $readyFile -ErrorAction SilentlyContinue
        return $false
    }
    Remove-Item -Force $readyFile -ErrorAction SilentlyContinue

    Write-Host "  Launching mpv... (close mpv to stop)" -ForegroundColor $C.Green
    mpv --cache=yes --cache-secs=120 --demuxer-readahead-secs=60 "http://127.0.0.1:$port/"

    Write-Host "`n  Cleaning up..." -ForegroundColor $C.Yellow
    if (-not $proc.HasExited) { $proc.Kill() }
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    return $true
}

function Stream-Peerflix($magnet) {
    if (-not (Get-Command peerflix -ErrorAction SilentlyContinue)) {
        Warn "peerflix not installed - skipping."
        return $false
    }
    Info "Peerflix: launching..."
    peerflix $magnet --mpv -c 200 --remove
    if ($LASTEXITCODE -ne 0) {
        Warn "Peerflix engine failed."
        return $false
    }
    return $true
}

function Stream-Aria2c($magnet, $totalSize) {
    if (-not (Get-Command aria2c -ErrorAction SilentlyContinue)) {
        Warn "aria2c not installed - skipping."
        return $false
    }
    $tempDir = "$env:TEMP\aria2stream_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Info "aria2c: starting download..."

    $ariaArgs = @(
        "--max-connection-per-server=16", "--split=16", "--min-split-size=1M"
        "--bt-max-peers=200", "--seed-time=0", "--enable-dht=true"
        "--dht-listen-port=6881", "--listen-port=6881", "--max-overall-upload-limit=1K"
        "--file-allocation=none", "--allow-overwrite=true", "--summary-interval=5"
        "--console-log-level=error", "--dir=$tempDir", "$magnet"
    )
    $ariaProc = Start-Process -FilePath "aria2c" -ArgumentList $ariaArgs -NoNewWindow -PassThru

    $file = $null; $timeout = 120; $elapsed = 0
    while (!$file -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 2; $elapsed += 2
        if ($ariaProc.HasExited) {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            return $false
        }
        $files = Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '\.aria2$' -and $_.Length -gt 1MB }
        if ($files.Count -gt 0) { $file = $files[0].FullName }
    }
    if (!$file) { Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue; return $false }

    $port = 8888
    $svReadyFile = "$env:TEMP\aria2_ready_$(Get-Random).tmp"
    $serverProc = Start-Process -FilePath "node" -ArgumentList @("$scriptDir\stream-server.js", "$tempDir", "$totalSize", "$port", "$svReadyFile") -NoNewWindow -PassThru
    $svTimeout = 10; $svElapsed = 0
    while (!(Test-Path $svReadyFile) -and $svElapsed -lt $svTimeout) {
        Start-Sleep -Milliseconds 500; $svElapsed += 0.5
        if ($serverProc.HasExited) { break }
    }
    Remove-Item -Force $svReadyFile -ErrorAction SilentlyContinue

    Write-Host "  Launching mpv... (close mpv to stop)" -ForegroundColor $C.Green
    mpv --cache=yes --cache-secs=120 --demuxer-readahead-secs=60 "http://127.0.0.1:$port/"

    Write-Host "`n  Cleaning up..." -ForegroundColor $C.Yellow
    if (-not $serverProc.HasExited) { $serverProc.Kill() }
    if (-not $ariaProc.HasExited) { $ariaProc.Kill() }
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    return $true
}

# ─── Save (download) functions ───────────────────────────────────────────

function Save-WebTorrent($magnet, $totalSize, $outDir) {
    $tempDir = "$env:TEMP\wtsave_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $port = 8889
    $readyFile = "$env:TEMP\wt_ready_$(Get-Random).tmp"
    $doneFile = "$env:TEMP\wt_done_$(Get-Random).tmp"

    Info "WebTorrent: downloading..."
    $proc = Start-Process -FilePath "node" -NoNewWindow -PassThru -ArgumentList @(
        "$scriptDir\stream-webtorrent.js", "$magnet", "$port", "$tempDir", "$readyFile", "$doneFile"
    )

    $timeout = 120; $elapsed = 0
    while (!(Test-Path $readyFile) -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 2; $elapsed += 2
        if ($proc.HasExited -and !(Test-Path $readyFile)) {
            Write-Host ""
            Warn "WebTorrent failed to start."
            if (-not $proc.HasExited) { $proc.Kill() }
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            Remove-Item -Force $readyFile, $doneFile -ErrorAction SilentlyContinue
            return $false
        }
    }
    if (!(Test-Path $readyFile)) {
        Warn "WebTorrent timed out starting download."
        if (-not $proc.HasExited) { $proc.Kill() }
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        Remove-Item -Force $readyFile, $doneFile -ErrorAction SilentlyContinue
        return $false
    }
    Remove-Item -Force $readyFile -ErrorAction SilentlyContinue

    Info "Downloading... (waiting for completion)"
    while (!(Test-Path $doneFile)) {
        Start-Sleep -Seconds 2
        if ($proc.HasExited -and !(Test-Path $doneFile)) {
            Warn "WebTorrent process exited before download completed."
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            Remove-Item -Force $doneFile -ErrorAction SilentlyContinue
            return $false
        }
    }
    Remove-Item -Force $doneFile -ErrorAction SilentlyContinue

    $files = Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Where-Object Length -gt 1MB
    $largest = $files | Sort-Object Length -Descending | Select-Object -First 1
    if (-not $largest) {
        Warn "No files found in download."
        if (-not $proc.HasExited) { $proc.Kill() }
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        return $false
    }

    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $destName = Sanitize-FileName $largest.Name
    $destPath = Join-Path $outDir $destName
    if (Test-Path $destPath) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($destName)
        $ext = [System.IO.Path]::GetExtension($destName)
        $destPath = Join-Path $outDir "$base`_$((Get-Date -Format 'yyyyMMdd_HHmmss'))$ext"
    }
    Move-Item -Path $largest.FullName -Destination $destPath -Force

    if (-not $proc.HasExited) { $proc.Kill() }
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    return $destPath
}

function Save-Aria2c($magnet, $totalSize, $outDir) {
    if (-not (Get-Command aria2c -ErrorAction SilentlyContinue)) {
        Warn "aria2c not installed - skipping."
        return $false
    }
    $tempDir = "$env:TEMP\aria2save_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Info "aria2c: downloading..."

    $ariaArgs = @(
        "--max-connection-per-server=16", "--split=16", "--min-split-size=1M"
        "--bt-max-peers=200", "--seed-time=0", "--enable-dht=true"
        "--dht-listen-port=6881", "--listen-port=6881", "--max-overall-upload-limit=1K"
        "--file-allocation=none", "--allow-overwrite=true", "--summary-interval=5"
        "--console-log-level=error", "--dir=$tempDir", "$magnet"
    )
    $ariaProc = Start-Process -FilePath "aria2c" -ArgumentList $ariaArgs -NoNewWindow -PassThru

    $file = $null; $timeout = 86400; $elapsed = 0
    while (!$file -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 5; $elapsed += 5
        if ($ariaProc.HasExited) {
            # aria2c exited - check if we have files
            $files = Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '\.aria2$' -and $_.Length -gt 1MB }
            if ($files.Count -gt 0) { $file = $files[0].FullName; break }
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            return $false
        }
        $files = Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '\.aria2$' -and $_.Length -gt 1MB }
        if ($files.Count -gt 0) {
            # Check if download is complete (aria2c process ended, or file stopped growing)
            $currentSize = ($files | Measure-Object -Property Length -Sum).Sum
            if ($currentSize -ge $totalSize -or $ariaProc.HasExited) {
                $file = ($files | Sort-Object Length -Descending | Select-Object -First 1).FullName
                break
            }
        }
    }
    if (-not $file) {
        if (-not $ariaProc.HasExited) { $ariaProc.Kill() }
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        return $false
    }

    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $destName = Sanitize-FileName (Split-Path $file -Leaf)
    $destPath = Join-Path $outDir $destName
    if (Test-Path $destPath) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($destName)
        $ext = [System.IO.Path]::GetExtension($destName)
        $destPath = Join-Path $outDir "$base`_$((Get-Date -Format 'yyyyMMdd_HHmmss'))$ext"
    }
    Move-Item -Path $file -Destination $destPath -Force

    if (-not $ariaProc.HasExited) { $ariaProc.Kill() }
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    return $destPath
}

# ─── Launch with fallback chain ─────────────────────────────────────────

if ($Download) {
    Section "Downloading"
    Write-Host "  Title:    $name" -ForegroundColor $C.Green
    Write-Host "  Size:     $('{0:N2}' -f ($totalSize/1GB)) GB" -ForegroundColor $C.Cyan
    Write-Host "  Seeders:  $seeds" -ForegroundColor $C.Cyan
    Write-Host "  Save to:  $OutDir" -ForegroundColor $C.Magenta
    Write-Host "  Press Ctrl+C to cancel`n" -ForegroundColor $C.Gray

    $engines = if ($userPickedEngine) { @($userPickedEngine) } else { @("webtorrent", "aria2c") }
    $saved = $false
    $attempted = @()

    foreach ($engine in $engines) {
        $attempted += $engine
        Write-Host "  Trying engine: $engine" -ForegroundColor $C.Yellow
        $result = switch ($engine) {
            "webtorrent" { Save-WebTorrent $magnet $totalSize $OutDir }
            "aria2c"     { Save-Aria2c $magnet $totalSize $OutDir }
        }
        if ($result) { $saved = $result; break }
        Write-Host "  [$engine] failed." -ForegroundColor $C.Red
        if (-not $NoFallback -and $engine -ne $engines[-1]) {
            Write-Host "  -> Falling back to next engine..." -ForegroundColor $C.Yellow
        }
    }
    if (-not $saved) { Write-Host ""; Err "All engines failed: $($attempted -join ', ')" }
    Write-Host ""
    Write-Host "  Download complete!" -ForegroundColor $C.Green
    Write-Host "  Location: $saved" -ForegroundColor $C.Cyan
} else {
    Section "Starting stream"
    Write-Host "  Title:    $name" -ForegroundColor $C.Green
    Write-Host "  Size:     $('{0:N2}' -f ($totalSize/1GB)) GB" -ForegroundColor $C.Cyan
    Write-Host "  Seeders:  $seeds" -ForegroundColor $C.Cyan
    if ($userPickedEngine) {
        Write-Host "  Engine:   $userPickedEngine (manual selection, no fallback)" -ForegroundColor $C.Magenta
    } else {
        Write-Host "  Engine:   webtorrent (auto-fallback on: peerflix -> aria2c)" -ForegroundColor $C.Magenta
    }
    Write-Host "  Press Ctrl+C to stop at any time`n" -ForegroundColor $C.Gray

    $engines = @()
    if ($userPickedEngine) {
        if (-not $PSBoundParameters.ContainsKey('NoFallback')) { $NoFallback = $true }
        switch ($userPickedEngine) {
            "webtorrent" { $engines = @("webtorrent") }
            "peerflix"   { $engines = @("peerflix") }
            "aria2c"     { $engines = @("aria2c") }
        }
    } else {
        $engines = @("webtorrent", "peerflix", "aria2c")
    }

    $streamed = $false
    $attempted = @()
    foreach ($engine in $engines) {
        $attempted += $engine
        Write-Host "  Trying engine: $engine" -ForegroundColor $C.Yellow
        $result = switch ($engine) {
            "webtorrent" { Stream-WebTorrent $magnet $totalSize }
            "peerflix"   { Stream-Peerflix $magnet }
            "aria2c"     { Stream-Aria2c $magnet $totalSize }
        }
        if ($result) { $streamed = $true; break }
        Write-Host "  [$engine] failed." -ForegroundColor $C.Red
        if (-not $NoFallback -and $engine -ne $engines[-1]) {
            Write-Host "  -> Falling back to next engine..." -ForegroundColor $C.Yellow
        }
    }
    if (-not $streamed) {
        Write-Host ""
        Err "All engines failed: $($attempted -join ', ')"
    }
}
