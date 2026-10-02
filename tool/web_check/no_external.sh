#!/usr/bin/env bash
# Serves the assembled site (SITE_DIR as /zx/) and checks that the web
# version requests nothing from other hosts (tool/web_check/no_external.mjs),
# in every theme.
# Usage: tool/web_check/no_external.sh SITE_DIR [WORK_DIR]
set -euo pipefail
cd "$(dirname "$0")/../.."
site=$(cd "$1" && pwd)
work=${2:-.webtest/noext}
rm -rf "$work"; mkdir -p "$work"
ln -s "$site" "$work/zx"
here=tool/web_check
browser=${BROWSER:-$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || command -v chromium-browser)}
node "$here/serve.mjs" "$work" 8765 & srv=$!
"$browser" --headless=new --disable-gpu --no-sandbox --no-first-run \
  --remote-debugging-port=9335 --user-data-dir="$work/.chrome" about:blank \
  >"$work/browser.log" 2>&1 & chr=$!
trap 'kill $srv $chr 2>/dev/null || true' EXIT
for t in dark eighties green; do
  node "$here/no_external.mjs" "http://localhost:8765/zx/online/#theme=$t" 9335 15
done
