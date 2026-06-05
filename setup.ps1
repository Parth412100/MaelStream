<#
.SYNOPSIS
    One-command setup for MaelStream - checks and installs all dependencies.
#>

$C = @{ Green = "Green"; Cyan = "Cyan"; Yellow = "Yellow"; Red = "Red"; Gray = "DarkGray" }

function Section($msg) { Write-Host "`n==> $msg" -ForegroundColor $C.Cyan }
function Info($msg) { Write-Host "  $msg" -ForegroundColor $C.Gray }
function Ok($msg) { Write-Host "  [OK] $msg" -ForegroundColor $C.Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor $C.Yellow }
function Err($msg) { Write-Host "  [X] $msg" -ForegroundColor $C.Red }

Write-Host @"

 +======================================+
 |        MaelStream - Setup            |
 |  CLI torrent streaming pipeline      |
 +======================================+

"@ -ForegroundColor $C.Cyan

Section "Checking existing installations"

$missing = @()
$found = @{}

# --- Node.js ---
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $ver = node --version
    Ok "Node.js $ver - $($node.Source)"
    $found.Node = $true
} else {
    Warn "Node.js not found"
    $missing += "nodejs"
}

# --- mpv ---
$mpv = Get-Command mpv -ErrorAction SilentlyContinue
if ($mpv) {
    Ok "mpv - $($mpv.Source)"
    $found.mpv = $true
} else {
    Warn "mpv not found"
    $missing += "mpv"
}

# --- aria2c (optional) ---
$aria2 = Get-Command aria2c -ErrorAction SilentlyContinue
if ($aria2) {
    Ok "aria2c - $($aria2.Source)"
    $found.aria2 = $true
} else {
    Warn "aria2c not found (optional - only needed for 'a' engine)"
}

# --- peerflix (optional) ---
$peerflix = Get-Command peerflix -ErrorAction SilentlyContinue
if ($peerflix) {
    Ok "peerflix - $($peerflix.Source)"
    $found.peerflix = $true
} else {
    Warn "peerflix not found (optional - only needed for 'p' engine)"
}

# --- webtorrent library ---
$scriptDir = Split-Path -Parent $PSCommandPath
if (Test-Path "$scriptDir\node_modules\webtorrent") {
    Ok "WebTorrent library (local node_modules)"
    $found.webtorrent = $true
} else {
    Warn "WebTorrent library not installed locally"
    $missing += "webtorrent"
}

# --- winget ---
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Warn "winget not found (needed for auto-install). Install from Microsoft Store."
}

if ($missing.Count -eq 0) {
    Section "All good!"
    Info "Everything is installed. You can start streaming:"
    Info "  .\watch.ps1 `"movie name`""
    Info "  .\watch.ps1 `"movie name`" -Auto"
    exit
}

Section "Installing missing dependencies"

if ($missing -contains "nodejs" -and $winget) {
    Info "Installing Node.js (this may take a minute)..."
    winget install OpenJS.NodeJS.LTS --accept-package-agreements 2>&1 | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    if (Get-Command node -ErrorAction SilentlyContinue) {
        Ok "Node.js installed: $(node --version)"
    } else {
        Warn "Node.js installation may need a restart. Install manually from https://nodejs.org"
    }
}

if ($missing -contains "mpv" -and $winget) {
    Info "Installing mpv..."
    winget install mpv --accept-package-agreements 2>&1 | Out-Null
    if (Get-Command mpv -ErrorAction SilentlyContinue) {
        Ok "mpv installed"
    } else {
        Warn "mpv installation may need a restart. Install manually or from Windows Store."
    }
}

if ($missing -contains "webtorrent") {
    Info "Installing WebTorrent library (npm install)..."
    Push-Location $scriptDir
    npm install webtorrent@1.9.4 2>&1 | Out-Null
    Pop-Location
    if (Test-Path "$scriptDir\node_modules\webtorrent") {
        Ok "WebTorrent library installed"
    } else {
        Warn "npm install failed. Try manually: cd $scriptDir && npm install"
    }
}

Section "Installing optional tools"

if (-not $found.peerflix -and $winget) {
    $ans = Read-Host "  Install peerflix? (needed for 'p' engine) [Y/n]"
    if ($ans -ne 'n') {
        Info "Installing peerflix (npm install -g)..."
        npm install -g peerflix 2>&1 | Out-Null
        if (Get-Command peerflix -ErrorAction SilentlyContinue) {
            Ok "peerflix installed"
        } else {
            Warn "peerflix install failed. Try: npm install -g peerflix"
        }
    }
}

Section "Setup complete"

Write-Host @"

  You can now stream movies:

    cd $(Split-Path -Parent $PSCommandPath)
    .\watch.ps1 "movie name"
    .\watch.ps1 "movie name" -Auto

  Need help?  .\watch.ps1 -Help

"@ -ForegroundColor $C.Green
