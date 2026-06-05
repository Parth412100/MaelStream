const WebTorrent = require('webtorrent');
const http = require('http');
const fs = require('fs');
const path = require('path');

const magnet = process.argv[2];
const port = parseInt(process.argv[3], 10) || 8888;
const tempDir = process.argv[4] || process.env.TEMP;
const readyFile = process.argv[5];

const client = new WebTorrent({ dht: true, tracker: true, utp: false });

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
        try { fs.writeFileSync(readyFile, 'ready'); } catch {}
        console.error(`Stream ready: http://127.0.0.1:${port}/`);
    });
}

client.add(magnet, { path: tempDir }, (torrent) => {
    const file = torrent.files[0];
    if (!file) {
        console.error('No files in torrent');
        process.exit(1);
    }
    console.error(`Downloading: ${file.name} (${(file.length / 1e9).toFixed(2)} GB)`);
    console.error(`Peers: ${torrent.numPeers}`);
    createFileServer(file, port);
});

setTimeout(() => {
    process.exit(1);
}, 180000);

process.on('SIGTERM', () => { if (client) client.destroy(() => process.exit(0)); });
process.on('SIGINT', () => { if (client) client.destroy(() => process.exit(0)); });
