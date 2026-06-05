param(
    [Parameter(Mandatory)]
    [string]$Query,
    [switch]$Auto,
    [switch]$Peerflix,
    [switch]$Aria2
)

$ErrorActionPreference = "Stop"

$trackers = @(
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://tracker.openbittorrent.com:80",
    "udp://tracker.publicbt.com:80",
    "udp://tracker.coppersurfer.tk:6969",
    "udp://tracker.leechers-paradise.org:6969",
    "udp://tracker.tiny-vps.com:6969",
    "udp://tracker.torrent.eu.org:451",
    "udp://open.demonii.com:1337",
    "udp://exodus.desync.com:6969",
    "udp://tracker.moeking.me:6969",
    "udp://tracker.dler.org:6969",
    "https://tracker.tamersunion.org:443/announce",
    "wss://tracker.btorrent.xyz",
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

$apiUrl = "https://apibay.org/q.php?q=$([System.Net.WebUtility]::UrlEncode($Query))&cat=0"
$results = curl.exe -s --max-time 15 $apiUrl 2>&1 | ConvertFrom-Json

if (-not $results -or -not $results[0].id) {
    Write-Host "No results found." -ForegroundColor Red
    exit 1
}

$results = $results | Where-Object { [int]$_.seeders -gt 0 } | Sort-Object { [int]$_.seeders } -Descending

Write-Host "`nResults for '$Query':" -ForegroundColor Cyan
$i = 0
foreach ($r in $results) {
    $sizeGb = [long]$r.size / 1GB
    $color = if ([int]$r.seeders -gt 100) { "Green" } elseif ([int]$r.seeders -gt 20) { "Yellow" } else { "DarkYellow" }
    Write-Host "$i) " -NoNewline
    Write-Host "$($r.name)" -ForegroundColor $color
    Write-Host "   Seeds: $($r.seeders) | Size: $('{0:N2}' -f $sizeGb) GB"
    $i++
}

if ($Auto) {
    $choice = 0
    Write-Host "`nAuto-selecting #0 ($($results[0].seeders) seeders)..." -ForegroundColor Green
} else {
    Write-Host "`nEnter number, 'p' peerflix, 'a' aria2, 'q' quit: " -NoNewline
    $input = Read-Host
    if ($input -eq 'q') { exit }
    if ($input -eq 'p') { $Peerflix = $true; $choice = 0; Write-Host "Using peerflix..." -ForegroundColor Cyan }
    elseif ($input -eq 'a') { $Aria2 = $true; $choice = 0; Write-Host "Using aria2c..." -ForegroundColor Cyan }
    elseif ($input -eq '' -or $input -match '^\d+$') { 
        $choice = if ($input -eq '') { 0 } else { [int]$input }
        if ($choice -ge $results.Count) { Write-Host "Invalid choice." -ForegroundColor Red; exit 1 }
    }
    else { Write-Host "Invalid choice." -ForegroundColor Red; exit 1 }
}

$selected = $results[$choice]
$hash = $selected.info_hash.ToUpper()
$name = $selected.name
$magnet = Make-Magnet $hash $name
$seeds = $selected.seeders
$totalSize = [long]$selected.size

Write-Host "`nStreaming: $name" -ForegroundColor Green
Write-Host "Seeders: $seeds | Size: $('{0:N2}' -f ($totalSize/1GB)) GB" -ForegroundColor Cyan

if ($Peerflix) {
    Write-Host "Starting peerflix... (press Ctrl+C to stop)" -ForegroundColor Green
    peerflix $magnet --mpv -c 200 --remove
    exit
}

if ($Aria2) {
    $tempDir = "$env:TEMP\aria2stream_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Write-Host "Starting aria2c..." -ForegroundColor Green
    $ariaArgs = @(
        "--max-connection-per-server=16", "--split=16", "--min-split-size=1M"
        "--bt-max-peers=200", "--seed-time=0", "--enable-dht=true"
        "--dht-listen-port=6881", "--listen-port=6881", "--max-overall-upload-limit=1K"
        "--file-allocation=none", "--allow-overwrite=true", "--summary-interval=5"
        "--console-log-level=error", "--dir=$tempDir", "$magnet"
    )
    $ariaProc = Start-Process -FilePath "aria2c" -ArgumentList $ariaArgs -NoNewWindow -PassThru
    Write-Host "Waiting for download..." -ForegroundColor Yellow
    $file = $null; $timeout = 120; $elapsed = 0
    while (!$file -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 2; $elapsed += 2
        if ($ariaProc.HasExited) { Write-Host "aria2c exited unexpectedly." -ForegroundColor Red; Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue; exit 1 }
        $files = Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '\.aria2$' -and $_.Length -gt 1MB }
        if ($files.Count -gt 0) { $file = $files[0].FullName }
    }
    if (!$file) { Write-Host "Timed out." -ForegroundColor Red; $ariaProc.Kill(); Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue; exit 1 }
    $port = 8888
    $serverProc = Start-Process -FilePath "node" -ArgumentList @("D:\scripts\stream-server.js", "$tempDir", "$totalSize", "$port") -NoNewWindow -PassThru
    Start-Sleep -Seconds 1
    Write-Host "Playing in mpv...`n" -ForegroundColor Green
    mpv --cache=yes --cache-secs=120 --demuxer-readahead-secs=60 "http://127.0.0.1:$port/"
    Write-Host "`nCleaning up..." -ForegroundColor Yellow
    if (-not $serverProc.HasExited) { $serverProc.Kill() }
    if (-not $ariaProc.HasExited) { $ariaProc.Kill() }
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    Write-Host "Done." -ForegroundColor Green
    exit
}

# Default: webtorrent (Node.js library, best streaming)
$tempDir = "$env:TEMP\wtstream_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$port = 8889
$readyFile = "$env:TEMP\wt_ready_$(Get-Random).tmp"

Write-Host "Starting webtorrent (WebTorrent protocol)..." -ForegroundColor Green
Write-Host "Press Ctrl+C to stop`n" -ForegroundColor DarkGray

$nodeProc = Start-Process -FilePath "node" -NoNewWindow -PassThru -ArgumentList @(
    "D:\scripts\stream-webtorrent.js", "$magnet", "$port", "$tempDir", "$readyFile"
)

Write-Host "Waiting for stream server..." -ForegroundColor Yellow
$timeout = 120; $elapsed = 0
while (!(Test-Path $readyFile) -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 2; $elapsed += 2
    if ($nodeProc.HasExited -and !(Test-Path $readyFile)) {
        Write-Host "`nWebtorrent exited unexpectedly." -ForegroundColor Red
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        Remove-Item -Force $readyFile -ErrorAction SilentlyContinue
        exit 1
    }
}
Remove-Item -Force $readyFile -ErrorAction SilentlyContinue

Write-Host "Connecting mpv..." -ForegroundColor Green
mpv --cache=yes --cache-secs=120 --demuxer-readahead-secs=60 "http://127.0.0.1:$port/"

Write-Host "`nCleaning up..." -ForegroundColor Yellow
if (-not $nodeProc.HasExited) { $nodeProc.Kill() }
Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
Write-Host "Done." -ForegroundColor Green
