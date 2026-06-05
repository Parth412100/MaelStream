const WebTorrent = require('webtorrent');
const http = require('http');
const fs = require('fs');

const magnet = process.argv[2];
const port = parseInt(process.argv[3], 10) || 8888;
const useEnv = process.argv[4] === '--use-env';
const tempDir = useEnv ? process.env.WT_TEMP_DIR : (process.argv[4] || process.env.TEMP);
const readyFile = process.argv[5];
const doneFile = process.argv[6];
const noSigint = process.argv[7] === '--no-sigint';

const client = new WebTorrent({ dht: true, tracker: true, utp: false });
let serverStarted = false;

function formatTime(seconds) {
    if (seconds <= 0 || !isFinite(seconds)) return '--:--';
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = Math.floor(seconds % 60);
    if (h > 0) return `${h}h ${m}m`;
    if (m > 0) return `${m}m ${s}s`;
    return `${s}s`;
}

function formatSpeed(bytesPerSec) {
    if (bytesPerSec <= 0) return '0 B/s';
    const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
    const i = Math.min(Math.floor(Math.log(bytesPerSec) / Math.log(1024)), units.length - 1);
    return (bytesPerSec / Math.pow(1024, i)).toFixed(i > 0 ? 1 : 0) + ' ' + units[i];
}

function formatBytes(bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
    return (bytes / Math.pow(1024, i)).toFixed(i > 0 ? 1 : 0) + ' ' + units[i];
}

function createFileServer(file, port) {
    const totalSize = file.length;
    const server = http.createServer((req, res) => {
        const range = req.headers.range;
        if (range) {
            const match = range.match(/bytes=(\d+)-(\d*)/);
            if (!match) {
                res.writeHead(416, { 'Content-Range': `bytes */${totalSize}` });
                return res.end();
            }
            const start = parseInt(match[1], 10);
            const end = match[2] ? parseInt(match[2], 10) : Math.min(start + 5 * 1024 * 1024 - 1, totalSize - 1);
            const stream = file.createReadStream({ start, end });
            res.writeHead(206, {
                'Content-Range': `bytes ${start}-${end}/${totalSize}`,
                'Content-Length': end - start + 1,
                'Accept-Ranges': 'bytes',
                'Content-Type': 'video/mp4',
                'Connection': 'keep-alive'
            });
            stream.pipe(res);
            stream.on('error', () => { try { res.end(); } catch {} });
        } else {
            res.writeHead(200, {
                'Content-Length': totalSize,
                'Accept-Ranges': 'bytes',
                'Content-Type': 'video/mp4'
            });
            if (req.method === 'HEAD') return res.end();
            const stream = file.createReadStream();
            stream.pipe(res);
            stream.on('error', () => { try { res.end(); } catch {} });
        }
    });
    server.listen(port, () => {
        serverStarted = true;
        try { fs.writeFileSync(readyFile, 'ready'); } catch {}
        console.error(`\n  [WebTorrent] Stream ready!`);
        console.error(`  [WebTorrent] Server: http://127.0.0.1:${port}/`);
        // Show progress line
        const totalGB = (totalSize / 1e9).toFixed(2);
        let lastUpdate = 0;
        setInterval(() => {
            const downloaded = torrent.downloaded;
            const speed = torrent.downloadSpeed;
            const progress = (torrent.progress * 100).toFixed(1);
            const peers = torrent.numPeers;
            const remaining = speed > 0 ? (totalSize - downloaded) / speed : 0;
            // Only line if changed
            const now = Date.now();
            if (now - lastUpdate > 2000) {
                lastUpdate = now;
                if (progress < 100) {
                    console.error(`  [WebTorrent] ${progress}% of ${totalGB} GB | ${formatSpeed(speed)} | ${formatBytes(downloaded)} downloaded | ETA ${formatTime(remaining)} | ${peers} peers`);
                } else if (progress >= 100) {
                    console.error(`  [WebTorrent] 100% of ${totalGB} GB | download complete`);
                }
            }
        }, 2000);
    });
}

client.on('error', (err) => {
    console.error('\n  [WebTorrent] Error:', err.message);
    process.exit(1);
});

let torrent = null;

client.add(magnet, { path: tempDir }, (t) => {
    torrent = t;
    const videoExts = ['.mkv', '.mp4', '.avi', '.webm', '.mov', '.m4v', '.flv', '.wmv'];
    const sorted = torrent.files.sort((a, b) => b.length - a.length);
    const file = sorted.find(f => videoExts.some(ext => f.name.toLowerCase().endsWith(ext))) || sorted[0];
    if (!file) {
        console.error('\n  [WebTorrent] No files found in torrent.');
        process.exit(1);
    }
    console.error(`\n  [WebTorrent] Downloading: ${file.name}`);
    console.error(`  [WebTorrent] Size: ${(file.length / 1e9).toFixed(2)} GB`);
    console.error(`  [WebTorrent] Looking for peers...`);
    torrent.on('done', () => {
        console.error(`\n  [WebTorrent] Download complete!`);
        if (doneFile) { try { fs.writeFileSync(doneFile, 'done'); } catch {} }
    });
    createFileServer(file, port);
});

setTimeout(() => {
    if (!serverStarted) {
        console.error('\n  [WebTorrent] Timed out after 3 minutes. No peers found.');
        process.exit(1);
    }
}, 180000);

if (!noSigint) {
    process.on('SIGTERM', () => { if (client) client.destroy(() => process.exit(0)); });
    process.on('SIGINT', () => { if (client) client.destroy(() => process.exit(0)); });
}
