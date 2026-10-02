#!/usr/bin/env bash
# The browser test of the web engine: compiles the engine (dart2wasm) and
# tool/web_check/client_e2e.dart (dart2js, as the UI is), writes the
# fixtures, serves them with serve.mjs (ports 8765 and 8766) and runs the
# page in headless Chromium through cdp_run.mjs. Fails unless every check
# passes.
#
# Usage: tool/web_check/run_e2e.sh [DIR]   (default .webtest/e2e; snap
# Chromium can not read /tmp)
set -euo pipefail
cd "$(dirname "$0")/../.."
dir=${1:-.webtest/e2e}
mkdir -p "$dir/engine"
here=tool/web_check

dart compile wasm -O2 web_engine/zx_engine.dart -o "$dir/engine/zx_engine.wasm" >/dev/null
cp web_engine/zx_engine_worker.js "$dir/engine/"
dart compile js ${JSOPT:--O2} -o "$dir/client.js" "$here/client_e2e.dart" >/dev/null
dart run "$here/make_fixtures.dart" "$dir/fx" >/dev/null
cp "$dir"/fx/* "$dir/"

cat > "$dir/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>running</title><pre id="out">running</pre>
<script type="module">
const names = ['t.7z', 't.zip', 't.zx', 't.tar.gz', 'sealed.zx', 'secret.zx', 'db.zx', 'many.zx'];
window.zxFixtures = {};
for (const n of names) {
  window.zxFixtures[n] = new File([await (await fetch(n)).blob()], n);
}
window.zxExpected = await (await fetch('expected.json')).text();
const s = document.createElement('script');
s.src = 'client.js';
document.body.append(s);
</script>
HTML

browser=$(command -v chromium || command -v chromium-browser || command -v google-chrome || command -v google-chrome-stable)
rm -f "$dir/.requests.log"
node "$here/serve.mjs" "$dir" 8765 & srv=$!
"$browser" --headless --disable-gpu --no-sandbox --remote-debugging-port=9333 \
  --user-data-dir="$dir/.chrome" about:blank >/dev/null 2>&1 & chr=$!
trap 'kill $srv $chr 2>/dev/null || true' EXIT
sleep 1
out=$(node "$here/cdp_run.mjs" "http://localhost:8765/" 9333 120)
echo "$out"
grep -q '^ALL PASSED' <<<"$out"
