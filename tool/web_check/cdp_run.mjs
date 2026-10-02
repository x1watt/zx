// Opens a page in a headless Chromium (started with --remote-debugging-port)
// through the DevTools protocol, waits until document.title is 'done' (or
// a timeout), and prints the text of #out and the console messages.
// Usage: node cdp_run.mjs <url> [port] [timeoutSeconds]
const [url, port = '9222', timeout = '60'] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 300 && !target; i++) {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, {method: 'PUT'});
    target = await res.json();
  } catch (e) { await sleep(200); }
}
if (!target) { console.error('no browser'); process.exit(2); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r, {once: true}));
let id = 0;
const pending = new Map();
const logs = [];
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') {
    logs.push(m.params.args.map((a) => a.value ?? a.description).join(' '));
  }
  if (m.method === 'Runtime.exceptionThrown') {
    logs.push('EXCEPTION ' + JSON.stringify(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text));
  }
});
const send = (method, params = {}) => new Promise((r) => {
  const i = ++id; pending.set(i, r); ws.send(JSON.stringify({id: i, method, params}));
});
await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', {url});
const end = Date.now() + Number(timeout) * 1000;
let text = '';
while (Date.now() < end) {
  const r = await send('Runtime.evaluate', {expression: "document.title + '\\u0000' + (document.getElementById('out')?.textContent ?? '')", returnByValue: true});
  const [title, out] = String(r.result?.result?.value ?? '').split('\u0000');
  text = out;
  if (title === 'done') break;
  await sleep(250);
}
console.log(text);
if (logs.length) console.log('--- console\n' + logs.join('\n'));
ws.close();
process.exit(0);
