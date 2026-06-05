param(
    [Parameter(Position = 0)]
    [string]$Query,

    [switch]$Auto,
    [switch]$Peerflix,
    [switch]$Aria2,
    [switch]$Help,
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
   .\watch.ps1 "movie name" -Engine peerflix   Use specific engine

 ENGINES (press at prompt):
   [Enter]  WebTorrent (default, best peer discovery)
   [p]      Peerflix  (torrent-stream backend)
   [a]      aria2c    (C++ engine, fallback)

 EXAMPLES:
   .\watch.ps1 "mortal kombat 2021"
   .\watch.ps1 "inception 2010" -Auto
   .\watch.ps1 "tenet" -e peerflix

 TIPS:
   • Pick torrents with 100+ seeders for best speed
   • Close mpv to stop download and clean up temp files
   • Run .\setup.ps1 first to install dependencies

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
} else {
    $nodeVer = node --version
    Ok "Node.js $nodeVer"
}

if (-not (Get-Command mpv -ErrorAction SilentlyContinue)) {
    Err "mpv is not installed. Run: winget install mpv"
    $allGood = $false
} else { Ok "mpv" }

if (-not (Get-Command peerflix -ErrorAction SilentlyContinue)) {
    Warn "peerflix not found (optional, needed for 'p' engine)"
    Warn "Install: npm install -g peerflix"
} else { Ok "peerflix" }

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not (Test-Path "$scriptDir\node_modules\webtorrent")) {
    Warn "WebTorrent library not installed (needed for default engine)"
    Warn "Run: cd $scriptDir && npm install"
    $allGood = $false
} else { Ok "WebTorrent library" }

if (-not $allGood) {
    Write-Host "`nSome dependencies are missing. Run .\setup.ps1 to fix." -ForegroundColor $C.Yellow
    exit 1
}

$trackers = @(
    "udp://tracker.opentrackr.org:1337/announce"
    "udp://tracker.openbittorrent.com:80"
    "udp://tracker.publicbt.com:80"
    "udp://tracker.coppersurfer.tk:6969"
    "udp://tracker.leechers-paradise.org:6969"
    "udp://tracker.tiny-vps.com:6969"
    "udp://tracker.torrent.eu.org:451"
    "udp://open.demonii.com:1337"
    "udp://exodus.desync.com:6969"
    "udp://tracker.moeking.me:6969"
    "udp://tracker.dler.org:6969"
    "https://tracker.tamersunion.org:443/announce"
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
$results = curl.exe -s --max-time 15 $apiUrl 2>&1 | ConvertFrom-Json

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

$engineChoice = "webtorrent"
$choice = 0

if ($Engine) {
    $engineChoice = $Engine
    if ($Engine -eq 'peerflix') { $Peerflix = $true }
    elseif ($Engine -eq 'aria2c') { $Aria2 = $true }
    if (-not $Auto) { $Auto = $true }
}

if ($Auto) {
    $choice = 0
    $bestSeeds = $results[0].seeders
    Ok "Auto-selected #0 ($bestSeeds seeders)"
} else {
    Write-Host "`n  Choose result [0-$($results.Count-1)]" -NoNewline -ForegroundColor $C.Cyan
    Write-Host "  or engine: [p]eerflix [a]ria2c [q]uit" -ForegroundColor $C.Gray
    Write-Host "  (just press Enter for best result)" -ForegroundColor $C.Gray
    $input = Read-Host "`n  Your choice"

    if ($input -eq 'q') { Write-Host "  Bye!" -ForegroundColor $C.Cyan; exit }
    if ($input -eq 'p') { $Peerflix = $true; $choice = 0; $engineChoice = "peerflix"; Ok "Engine: Peerflix" }
    elseif ($input -eq 'a') { $Aria2 = $true; $choice = 0; $engineChoice = "aria2c"; Ok "Engine: aria2c" }
    elseif ($input -eq '' -or $input -match '^\d+$') {
        $choice = if ($input -eq '') { 0 } else { [int]$input }
        if ($choice -ge $results.Count) { Err "Invalid choice. Pick 0-$($results.Count-1)" }
        $engineChoice = "webtorrent"
        Ok "Engine: WebTorrent"
    } else { Err "Invalid choice." }
}

$selected = $results[$choice]
$hash = $selected.info_hash.ToUpper()
$name = $selected.name
$magnet = Make-Magnet $hash $name
$seeds = $selected.seeders
$totalSize = [long]$selected.size

Section "Starting stream"
Write-Host "  Title:    $name" -ForegroundColor $C.Green
Write-Host "  Size:     $('{0:N2}' -f ($totalSize/1GB)) GB" -ForegroundColor $C.Cyan
Write-Host "  Seeders:  $seeds" -ForegroundColor $C.Cyan
Write-Host "  Engine:   $engineChoice" -ForegroundColor $C.Magenta
Write-Host "  Press Ctrl+C to stop at any time`n" -ForegroundColor $C.Gray

if ($Peerflix) {
    Info "Starting peerflix..."
    peerflix $magnet --mpv -c 200 --remove
    Ok "Done"
    exit
}

if ($Aria2) {
    $tempDir = "$env:TEMP\aria2stream_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Info "Starting aria2c..."
    $ariaArgs = @(
        "--max-connection-per-server=16", "--split=16", "--min-split-size=1M"
        "--bt-max-peers=200", "--seed-time=0", "--enable-dht=true"
        "--dht-listen-port=6881", "--listen-port=6881", "--max-overall-upload-limit=1K"
        "--file-allocation=none", "--allow-overwrite=true", "--summary-interval=5"
        "--console-log-level=error", "--dir=$tempDir", "$magnet"
    )
    $ariaProc = Start-Process -FilePath "aria2c" -ArgumentList $ariaArgs -NoNewWindow -PassThru
    Info "Waiting for download..."
    $file = $null; $timeout = 120; $elapsed = 0
    while (!$file -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 2; $elapsed += 2
        if ($ariaProc.HasExited) {
            Info "aria2c exited early (ISP may be blocking P2P traffic)."
            Info "Try the default WebTorrent engine instead."
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            exit 1
        }
        $files = Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '\.aria2$' -and $_.Length -gt 1MB }
        if ($files.Count -gt 0) { $file = $files[0].FullName }
    }
    if (!$file) { Err "Timed out. Try a torrent with more seeders." }
    $port = 8888
    $serverProc = Start-Process -FilePath "node" -ArgumentList @("$scriptDir\stream-server.js", "$tempDir", "$totalSize", "$port") -NoNewWindow -PassThru
    Start-Sleep -Seconds 2
    Write-Host "  Launching mpv... (close mpv to stop)" -ForegroundColor $C.Green
    mpv --cache=yes --cache-secs=120 --demuxer-readahead-secs=60 "http://127.0.0.1:$port/"
    Write-Host "`n  Cleaning up..." -ForegroundColor $C.Yellow
    if (-not $serverProc.HasExited) { $serverProc.Kill() }
    if (-not $ariaProc.HasExited) { $ariaProc.Kill() }
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    Ok "Done"
    exit
}

# Default: WebTorrent engine
$tempDir = "$env:TEMP\wtstream_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$port = 8889
$readyFile = "$env:TEMP\wt_ready_$(Get-Random).tmp"

Info "WebTorrent is finding peers and starting HTTP server..."
$nodeProc = Start-Process -FilePath "node" -NoNewWindow -PassThru -ArgumentList @(
    "$scriptDir\stream-webtorrent.js", "$magnet", "$port", "$tempDir", "$readyFile"
)

$timeout = 120; $elapsed = 0
$showed_wait = $false
while (!(Test-Path $readyFile) -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 2; $elapsed += 2
    if (-not $showed_wait -and $elapsed -gt 10) {
        Write-Host "  Still waiting for peers (this can take a moment..."
        $showed_wait = $true
    }
    if ($nodeProc.HasExited -and !(Test-Path $readyFile)) {
        Write-Host ""
        Warn "WebTorrent couldn't find peers for this torrent."
        Tip "Try a result with more seeders, or use 'p' for peerflix engine."
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        Remove-Item -Force $readyFile -ErrorAction SilentlyContinue
        exit 1
    }
}
Remove-Item -Force $readyFile -ErrorAction SilentlyContinue

Write-Host "  Launching mpv... (close mpv to stop)" -ForegroundColor $C.Green
mpv --cache=yes --cache-secs=120 --demuxer-readahead-secs=60 "http://127.0.0.1:$port/"

Write-Host "`n  Cleaning up..." -ForegroundColor $C.Yellow
if (-not $nodeProc.HasExited) { $nodeProc.Kill() }
Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
Ok "Done"
