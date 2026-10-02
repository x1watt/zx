// Opens a page in a headless Chromium (started with --remote-debugging-port)
// and fails when it, or any worker of it, requests anything from another
// host: the web version must work offline and leak no address of its
// readers to other servers. Prints every request.
// Usage: node no_external.mjs <url> [port] [seconds]
const [url, port = '9335', secs = '15'] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let t;
for (let i = 0; i < 300 && !t; i++) {
  try {
    t = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, {method: 'PUT'})).json();
  } catch { await sleep(200); }
}
if (!t) { console.error('no browser'); process.exit(2); }
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r, {once: true}));
let id = 0;
const pending = new Map();
const seen = new Set();
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  if (m.method === 'Network.requestWillBeSent') seen.add(m.params.request.url.split('?')[0]);
});
const send = (method, params = {}, sessionId) => new Promise((r) => {
  const i = ++id; pending.set(i, r);
  ws.send(JSON.stringify({id: i, method, params, ...(sessionId ? {sessionId} : {})}));
});
// the requests of workers too
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.method === 'Target.attachedToTarget') {
    send('Network.enable', {}, m.params.sessionId);
    send('Runtime.runIfWaitingForDebugger', {}, m.params.sessionId);
  }
});
await send('Network.enable');
await send('Target.setAutoAttach', {autoAttach: true, waitForDebuggerOnStart: true, flatten: true});
await send('Page.navigate', {url});
await sleep(Number(secs) * 1000);
const host = new URL(url).host;
const outside = [...seen].filter((u) => /^https?:/.test(u) && new URL(u).host !== host);
for (const u of [...seen].sort()) console.log(u);
ws.close();
if (outside.length) {
  console.error('requests to other hosts:\n' + outside.join('\n'));
  process.exit(1);
}
console.log(`no request outside ${host} (${seen.size} requests)`);
process.exit(0);
