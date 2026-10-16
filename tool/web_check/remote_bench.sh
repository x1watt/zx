#!/usr/bin/env bash
# Measures SQL on a remote database in headless Chromium (remote_bench.dart):
# compiles the engine and the page, serves them on localhost:8765 and
# prints the cold and warm times, requests and bytes of each query.
#
# Usage: [BS=BLOCKBYTES] tool/web_check/remote_bench.sh URL "SQL" ["SQL" ...]
#   tool/web_check/remote_bench.sh \
#     https://huggingface.co/datasets/USER/NAME/resolve/main/db.zx.parts \
#     "SELECT count(*) FROM page_meta"
set -euo pipefail
cd "$(dirname "$0")/../.."
dir=.webtest/remote
url=$1
shift
mkdir -p "$dir/engine"
here=tool/web_check
dart compile wasm -O2 web_engine/zx_engine.dart -o "$dir/engine/zx_engine.wasm" >/dev/null
cp web_engine/zx_engine_worker.js "$dir/engine/"
dart compile js -O2 -o "$dir/bench.js" "$here/remote_bench.dart" >/dev/null
cat > "$dir/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>running</title><pre id="out">running</pre>
<script src="bench.js"></script>
HTML
query="url=$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "$url")"
if [ -n "${BS:-}" ]; then query+="&bs=$BS"; fi
for s in "$@"; do
  query+="&sql=$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "$s")"
done
browser=${BROWSER:-$(command -v google-chrome || command -v chromium || command -v chromium-browser)}
node "$here/serve.mjs" "$dir" 8765 & srv=$!
"$browser" --headless=new --disable-gpu --no-sandbox --no-first-run \
  --remote-debugging-port=9334 --user-data-dir="$dir/.chrome" about:blank \
  >"$dir/browser.log" 2>&1 & chr=$!
trap 'kill $srv $chr 2>/dev/null || true' EXIT
node "$here/cdp_run.mjs" "http://localhost:8765/?$query" 9334 600
