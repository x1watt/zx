// A test server for the web version: serves DIR on PORT (the page's
// origin) and on PORT+1 (another origin, for remote archives) where the
// first path component chooses how the server behaves:
//   /range/F    CORS, byte ranges (206), Content-Range and ETag exposed
//   /bare/F     CORS, byte ranges, no headers exposed (as most hosts)
//   /norange/F  CORS, Range ignored (always 200 with the whole file)
//   /nocors/F   byte ranges, no CORS headers (the browser blocks it)
// Every request is logged to DIR/.requests.log (method, path, Range).
// Usage: node serve.mjs DIR [PORT]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const [dir, portArg = '8765'] = process.argv.slice(2);
const port = Number(portArg);
const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json',
  '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml',
};
const log = fs.createWriteStream(path.join(dir, '.requests.log'), {flags: 'a'});

function serve(req, res, file, mode) {
  log.write(`${req.method} ${req.url} ${req.headers.range ?? '-'}\n`);
  const headers = {'Cache-Control': 'no-store', 'Accept-Ranges': 'bytes'};
  if (mode !== 'nocors' && mode !== 'page') {
    headers['Access-Control-Allow-Origin'] = '*';
    if (mode === 'range') {
      headers['Access-Control-Expose-Headers'] = 'Content-Range, ETag';
    }
  }
  if (req.method === 'OPTIONS') {
    headers['Access-Control-Allow-Headers'] = 'Range';
    res.writeHead(204, headers);
    return res.end();
  }
  let st;
  try { st = fs.statSync(file); } catch { res.writeHead(404, headers); return res.end(); }
  if (!st.isFile()) { res.writeHead(404, headers); return res.end(); }
  headers['Content-Type'] = types[path.extname(file)] ?? 'application/octet-stream';
  headers['ETag'] = `"${st.size}-${st.mtimeMs}"`;
  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? '');
  if (m && mode !== 'norange' && mode !== 'page') {
    let start = m[1] === '' ? st.size - Number(m[2]) : Number(m[1]);
    let end = m[1] === '' || m[2] === '' ? st.size - 1 : Number(m[2]);
    if (end >= st.size) end = st.size - 1;
    if (start > end) { res.writeHead(416, headers); return res.end(); }
    headers['Content-Range'] = `bytes ${start}-${end}/${st.size}`;
    headers['Content-Length'] = end - start + 1;
    res.writeHead(206, headers);
    if (req.method === 'HEAD') return res.end();
    return fs.createReadStream(file, {start, end}).pipe(res);
  }
  headers['Content-Length'] = st.size;
  res.writeHead(200, headers);
  if (req.method === 'HEAD') return res.end();
  fs.createReadStream(file).pipe(res);
}

http.createServer((req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  serve(req, res, path.join(dir, p === '/' ? 'index.html' : p), 'page');
}).listen(port);

http.createServer((req, res) => {
  const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const [, mode, ...rest] = p.split('/');
  serve(req, res, path.join(dir, ...rest), mode);
}).listen(port + 1);
