const http = require('http');
const fs = require('fs');
const path = require('path');

const dir = process.argv[2];
const totalSize = parseInt(process.argv[3], 10);
const port = parseInt(process.argv[4], 10);
const readyFile = process.argv[5];

let currentSize = 0;

function getCurrentSize() {
    try {
        const files = fs.readdirSync(dir).filter(f => !f.endsWith('.aria2'));
        if (files.length === 0) return 0;
        const target = path.join(dir, files.sort((a, b) => {
            return fs.statSync(path.join(dir, b)).size - fs.statSync(path.join(dir, a)).size;
        })[0]);
        return fs.statSync(target).size;
    } catch { return 0; }
}

setInterval(() => { currentSize = getCurrentSize(); }, 1000);

const server = http.createServer((req, res) => {
    const range = req.headers.range;
    currentSize = getCurrentSize();
    const available = Math.min(currentSize, totalSize);

    if (range) {
        const match = range.match(/bytes=(\d+)-(\d*)/);
        if (!match) {
            res.writeHead(416);
            return res.end();
        }
        const start = parseInt(match[1], 10);
        const end = match[2] ? parseInt(match[2], 10) : Math.min(start + 5 * 1024 * 1024 - 1, totalSize - 1);
        const chunkSize = end - start + 1;

        if (start >= available) {
            res.writeHead(416, { 'Content-Range': `bytes */${totalSize}` });
            return res.end();
        }

        const serveEnd = Math.min(end, available - 1);
        const serveSize = serveEnd - start + 1;

        try {
            const files = fs.readdirSync(dir).filter(f => !f.endsWith('.aria2'));
            const target = path.join(dir, files.sort((a, b) => {
                return fs.statSync(path.join(dir, b)).size - fs.statSync(path.join(dir, a)).size;
            })[0]);
            const stream = fs.createReadStream(target, { start, end: serveEnd });
            res.writeHead(206, {
                'Content-Range': `bytes ${start}-${serveEnd}/${totalSize}`,
                'Content-Length': serveSize,
                'Accept-Ranges': 'bytes',
                'Content-Type': 'video/mp4',
                'Connection': 'keep-alive'
            });
            stream.pipe(res);
            stream.on('error', () => { res.end(); });
        } catch {
            res.writeHead(404);
            res.end();
        }
    } else {
        res.writeHead(200, {
            'Content-Length': totalSize,
            'Accept-Ranges': 'bytes',
            'Content-Type': 'video/mp4'
        });
        if (req.method === 'HEAD') return res.end();
        try {
            const files = fs.readdirSync(dir).filter(f => !f.endsWith('.aria2'));
            const target = path.join(dir, files.sort((a, b) => {
                return fs.statSync(path.join(dir, b)).size - fs.statSync(path.join(dir, a)).size;
            })[0]);
            const stream = fs.createReadStream(target, { end: available - 1 });
            stream.pipe(res);
            stream.on('error', () => { res.end(); });
        } catch {
            res.writeHead(404);
            res.end();
        }
    }
});

server.listen(port, () => {
    if (readyFile) { try { fs.writeFileSync(readyFile, 'ready'); } catch {} }
    process.stdout.write(`Stream server on port ${port}`);
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
