# MaelStream

**A CLI torrent streaming pipeline for Windows** — search The Pirate Bay, pick a torrent, and stream directly to `mpv` with zero buffering ceremony.

Three engines: WebTorrent (default), Peerflix, aria2c.

---

## Quick Start

```powershell
# 1. Clone
git clone https://github.com/Parth412100/MaelStream.git
cd MaelStream

# 2. Auto-setup (installs everything)
.\setup.ps1

# 3. Stream!
.\watch.ps1 "mortal kombat 2021"
```

That's it. The setup script checks for Node.js, mpv, WebTorrent library, peerflix, and aria2c — installing any that are missing.

---

## Features

- **TPB search** — queries `apibay.org` for torrent metadata, sorts by seeders
- **Three streaming engines**:
  - *WebTorrent* (default) — Node.js WebTorrent library, hybrid WebRTC+TCP peer discovery
  - *Peerflix* — battle-tested torrent-stream over HTTP
  - *aria2c* — fast C++ engine + Node.js HTTP range server
- **HTTP Range-request server** — every engine serves partial content so `mpv` can seek freely
- **Auto-mode** — skip the prompt, stream the best result immediately
- **Full cleanup** — kills all processes and deletes temp files on exit

---

## Prerequisites

| Dependency | Install | Notes |
|---|---|---|
| **Node.js** (v18+) | `winget install OpenJS.NodeJS.LTS` | Required for all engines |
| **mpv** | `winget install mpv` | Video player, also available via Windows Store |
| **Git** | `winget install Git.Git` | Only needed for cloning the repo |
| **aria2c** (optional) | `winget install aria2.aria2` | Fallback engine #2 |

---

## Installation

```powershell
# 1. Clone the repository
git clone https://github.com/Parth412100/MaelStream.git
cd MaelStream

# 2. Install local Node.js dependencies
npm install

# 3. Install global tools
npm install -g peerflix
```

To verify everything is in your PATH:

```powershell
Get-Command node, mpv, peerflix, aria2c -ErrorAction SilentlyContinue
```

All four should resolve. Missing one? Run the corresponding `winget install` command from the table above.

---

## Usage

```powershell
# Search and stream a movie
.\watch.ps1 "mortal kombat 2021"

# Auto-select the top result
.\watch.ps1 "inception" -Auto
```

At the prompt:
- **`Enter`** or **number** → stream with WebTorrent (default engine)
- **`p`** → stream with Peerflix
- **`a`** → stream with aria2c
- **`q`** → quit

Close `mpv` to stop the download and clean up temp files.

---

## Engine Architecture

```
                   ┌─────────────────────┐
                   │    TPB API Search    │
                   │  apibay.org/q.php   │
                   └────────┬────────────┘
                            │ magnet URI
                            ▼
       ┌────────────┬───────┴───────┬────────────┐
       │            │               │            │
       ▼            ▼               ▼            ▼
  WebTorrent    Peerflix         aria2c       (future)
  (default)     (p)              (a)
       │            │               │
       │  HTTP      │  HTTP         │  partial file
       │  Range     │  Range        │  + Node.js
       │  server    │  server       │  HTTP server
       │            │               │
       └────────────┴───────────────┘
                        │
                        ▼
                      mpv
                (with —cache=120s)
```

**WebTorrent engine** uses the [webtorrent](https://github.com/webtorrent/webtorrent) npm library (v1.9.4). It creates an HTTP server with full `Range` header support so `mpv` can seek through partially-downloaded files. Peer discovery uses DHT, trackers, and WebRTC.

**Peerflix** runs `peerflix —mpv -c 200 —remove`, piping the magnet through its own HTTP server. Simple and reliable, but uses the older `torrent-stream` backend.

**aria2c engine** launches the C++ aria2c binary to download pieces, then a lightweight Node.js server (`stream-server.js`) serves the partial file with byte-range support. Designed as a fallback for cases where Node.js-based clients struggle.

---

## Troubleshooting & Error History

### 1. `TypeError: file.createServer is not a function`
**Symptoms:** WebTorrent downloaded metadata and found peers, then crashed when trying to start the HTTP server.
**Root cause:** `webtorrent@2.x` dropped `File.createServer()`. Version 1.9.4 (which has it) was pinned.
**Fix:** `npm install webtorrent@1.9.4`

---

### 2. `EPERM: operation not permitted` during `npm install -g webtorrent-cli`
**Symptoms:** Global installation of `webtorrent-cli` failed with native module errors on Windows. The `ip-set` package inside the dependency chain calls `only-allow pnpm`, which blocks `npm`.
**Root cause:** The `ip-set` npm package enforces `pnpm` as the package manager. Combined with Windows filesystem permission issues on `tar-fs` temp directories during install.
**Fix:** Switch to the `webtorrent` library (not the CLI) installed locally (`npm install webtorrent@1.9.4`), then write a custom Node.js wrapper script.

---

### 3. `peerflix is exiting` immediately
**Symptoms:** Peerflix printed "info peerflix is exiting..." and stopped before any data was exchanged.
**Root cause:** The magnet link or tracker parameters were malformed. The PowerShell script was appending trackers via `&tr=...` URL parameters that sometimes exceeded URL length limits or contained encoding issues.
**Fix:** Verified magnet format by testing with `peerflix` directly. Rebuilt the tracker list with verified working URLs. Added WebTorrent as the default engine since it handles metadata exchange more robustly.

---

### 4. `aria2c: unknown option — sequential-download=true`
**Symptoms:** aria2c refused to start with the error "unknown option — sequential-download=true".
**Root cause:** The option `--sequential-download` does not exist in aria2c's BitTorrent mode. It only applies to HTTP/FTP sequential URI fetching (`--force-sequential`), not torrent piece ordering.
**Fix:** Removed the invalid flag. For streaming with aria2c, the architecture was changed to: download pieces in normal (rarest-first) order → serve via a custom Node.js HTTP server → `mpv` reads via HTTP with seek support.

---

### 5. `CN:0 SD:0 DL:0B` — aria2c finds zero peers
**Symptoms:** aria2c connects to trackers (CONNECT replies received) but never discovers peers. ANNOUNCE messages time out.
**Root cause:** ISP in India throttling/interfering with UDP tracker traffic. DHT bootstrap also had compatibility issues ("Missing token" errors). The CONNECT reply came through, but the ANNOUNCE response was consistently dropped.
**Fix:** Switched to WebTorrent as the primary engine, which uses WebRTC (different protocol) and has more resilient peer discovery. Fallback to aria2c with HTTP/HTTPS trackers (TCP-based) worked in some cases.

---

### 6. `[WinError 10061] No connection could be made because the target machine actively refused it`
**Symptoms:** `mpv` started before the WebTorrent HTTP server was ready, hitting a "connection refused" error.
**Root cause:** Race condition — the Node.js process hadn't finished metadata exchange and server startup before `mpv` tried to connect.
**Fix:** Added a ready-file signaling mechanism: the Node.js server writes a marker file to disk once `server.listen()` fires. The PowerShell script polls for this file (with a 120-second timeout) before launching `mpv`.

---

### 7. TPB/YTS/1337x API blocked even over VPN
**Symptoms:** All web-based streaming providers (VidSrc, fzmovies, sflix, etc.) and torrent indexers (YTS, 1337x, RARBG, EZTV) returned timeouts or 404s. Only `apibay.org` (TPB API) worked.
**Root cause:** Cloudflare blocks datacenter IP ranges used by ProtonVPN. The Indian ISP also blocks these domains via DNS poisoning.
**Fix:** Switched to TPB API (`apibay.org`) as the sole search source. Added all available categories (`cat=0`) since category-specific filters (`cat=201`) returned empty results.

---

### 8. ProtonVPN P2P speeds at ~20 KB/s
**Symptoms:** ProtonVPN WireGuard tunnel was up, but torrent download speeds were unusably slow (0-1 peers found).
**Root cause:** ProtonVPN's free/datacenter IPs are blocked or throttled by trackers and peer swarms. P2P-optimized servers require a paid plan.
**Fix:** Disconnected VPN entirely. Direct P2P connections (without VPN) found more peers and achieved higher speeds, despite ISP throttling.

---

## File Reference

| File | Purpose |
|---|---|
| `watch.ps1` | Main entry point — search + select + stream |
| `stream-webtorrent.js` | WebTorrent engine — metadata exchange + HTTP server |
| `stream-server.js` | aria2c engine — serves partial files with Range support |
| `package.json` | npm metadata (pins `webtorrent@1.9.4`) |

---

## License

MIT
