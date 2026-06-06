param(
    [Parameter(Position = 0)]
    [string]$Query,
    [switch]$Auto,
    [switch]$Keep,
    [switch]$Help
)

if ($Help -or $Query -eq '-?' -or $Query -eq '--help' -or $Query -eq '/?') {
    Write-Host @"

  MaelStream - Torrent Streaming CLI

  USAGE:
    .\watch.ps1 "movie name"          Search and stream
    .\watch.ps1 "movie name" -Auto    Auto-select best result
    .\watch.ps1 "movie name" -Keep    Stream + keep downloaded files
    .\watch.ps1 -Help                 This help

  Run .\setup.ps1 first to install dependencies.

"@ -ForegroundColor Cyan
    exit
}

$ErrorActionPreference = "Stop"

$C = @{ Green = "Green"; Cyan = "Cyan"; Yellow = "Yellow"; Red = "Red"; Gray = "DarkGray" }

function Section($msg) { Write-Host "`n==> $msg" -ForegroundColor $C.Cyan }
function Info($msg) { Write-Host "  $msg" -ForegroundColor $C.Gray }
function Ok($msg) { Write-Host "  [OK] $msg" -ForegroundColor $C.Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor $C.Yellow }
function Err($msg) { Write-Host "  [X] $msg" -ForegroundColor $C.Red; exit 1 }

if (-not $Query) {
    Section "Usage: .\watch.ps1 `"movie name`""
    $Query = Read-Host "Search for"
    if (-not $Query) { exit }
}

Section "Checking dependencies"

$scriptDir = Split-Path -Parent $PSCommandPath

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Err "Node.js not found. Run: winget install OpenJS.NodeJS.LTS"
} else { Ok "Node.js $(node --version)" }

$ciMpvDir = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\mpv-player.mpv-CI.MSVC_Microsoft.Winget.Source_8wekyb3d8bbwe"
if (Test-Path "$ciMpvDir\mpv.exe") {
    $script:mpvPath = "$ciMpvDir\mpv.exe"
    Ok "mpv (CI build)"
} elseif (Get-Command mpv -ErrorAction SilentlyContinue) {
    $script:mpvPath = "mpv"
    Ok "mpv"
} else {
    Err "mpv not found. Run: winget install mpv-player.mpv-CI.MSVC"
}

if (-not (Test-Path "$scriptDir\node_modules\webtorrent")) {
    Err "WebTorrent library not found. Run: cd $scriptDir && npm install"
} else { Ok "WebTorrent library" }

$orphans = Get-Process -Name "node" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "stream-webtorrent" }
if ($orphans) { $orphans | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }

$portCheck = netstat -ano | Select-String ":8889\s"
if ($portCheck) {
    $foundPid = ($portCheck.Line -replace '.*\s+(\d+)$', '$1') -as [int]
    if ($foundPid -and $foundPid -ne $PID) { Stop-Process -Id $foundPid -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
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

function Sanitize-FileName($name) {
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $valid = $name.ToCharArray() | ForEach-Object {
        if ($_ -in $invalid) { '_' } else { $_ }
    }
    return -join $valid
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
if ($results.Count -eq 0) { Err "All results have 0 seeders." }

$i = 0
foreach ($r in $results) {
    $sizeGb = [long]$r.size / 1GB
    $color = if ([int]$r.seeders -gt 100) { $C.Green } elseif ([int]$r.seeders -gt 20) { $C.Yellow } else { $C.Gray }
    Write-Host "  $i) " -NoNewline -ForegroundColor $C.Cyan
    Write-Host "$($r.name)" -ForegroundColor $color
    Write-Host "     Seeds: $($r.seeders) | Size: $('{0:N2}' -f $sizeGb) GB"
    $i++
}

if ($Auto) {
    Write-Host "  Auto-selected #0 ($($results[0].seeders) seeders)" -ForegroundColor $C.Green
} else {
    Write-Host "`n  Choose result [0-$($results.Count-1)] or press Enter for best:" -ForegroundColor $C.Cyan
    $input = Read-Host "  Your choice"
    if ($input -eq 'q') { exit }
    if ($input -ne '' -and $input -match '^\d+$') {
        if ([int]$input -lt $results.Count) { $selected = $results[[int]$input] }
        else { Err "Invalid choice." }
    }
}

if (-not $selected) { $selected = $results[0] }

$hash = $selected.info_hash.ToUpper()
$name = $selected.name
$magnet = Make-Magnet $hash $name
$totalSize = [long]$selected.size

Section "Streaming"
Write-Host "  Title:    $name" -ForegroundColor $C.Green
Write-Host "  Size:     $('{0:N2}' -f ($totalSize/1GB)) GB" -ForegroundColor $C.Cyan
Write-Host "  Seeders:  $($selected.seeders)" -ForegroundColor $C.Cyan
Write-Host "  Close mpv to stop`n" -ForegroundColor $C.Gray

$tempDir = if ($Keep) {
    $dlDir = Join-Path $scriptDir "downloads"
    Join-Path $dlDir (Sanitize-FileName $name)
} else {
    Join-Path $env:TEMP "maelstream_$(Get-Random)"
}
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$port = 8889
$readyFile = "$env:TEMP\wt_ready_$(Get-Random).tmp"

$env:WT_TEMP_DIR = $tempDir
$proc = Start-Process -FilePath "node" -NoNewWindow -PassThru -ArgumentList @(
    "$scriptDir\stream-webtorrent.js", "$magnet", "$port", "--use-env", "$readyFile"
)

$timeout = 90; $elapsed = 0
Write-Host "  WebTorrent: finding peers..." -ForegroundColor $C.Gray
while (!(Test-Path $readyFile) -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 2; $elapsed += 2
    if ($proc.HasExited -and !(Test-Path $readyFile)) {
        Write-Host ""
        Warn "WebTorrent engine failed."
        if (-not $proc.HasExited) { $proc.Kill() }
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        Remove-Item -Force $readyFile -ErrorAction SilentlyContinue
        exit 1
    }
}
if (!(Test-Path $readyFile)) {
    Warn "WebTorrent timed out after ${timeout}s."
    if (-not $proc.HasExited) { $proc.Kill() }
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    Remove-Item -Force $readyFile -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item -Force $readyFile -ErrorAction SilentlyContinue

Write-Host "  Launching mpv..." -ForegroundColor $C.Green
Start-Process -Wait -FilePath $script:mpvPath -ArgumentList @(
    "--vo=direct3d",
    "--cache=yes",
    "--keep-open=yes",
    "--no-terminal",
    "--ontop",
    "http://127.0.0.1:$port/"
)

Write-Host "`n  Cleaning up..." -ForegroundColor $C.Yellow
if (-not $proc.HasExited) { $proc.Kill() }
if ($Keep) {
    Write-Host "  Files kept at: $tempDir" -ForegroundColor $C.Green
} else {
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}
Write-Host "  Done." -ForegroundColor $C.Green
