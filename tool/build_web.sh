#!/usr/bin/env bash
# Builds the web version (docs/app.md "The web version") into
# app/build/web: the Flutter UI (lib/main_web.dart, dart2wasm with the
# dart2js fallback) and the engine worker (web_engine/zx_engine.dart,
# dart2wasm) in app/build/web/engine/. The site is published with it as
# https://x1watt.github.io/zx/online/ (.github/workflows/pages.yml).
#
# The Flutter build goes through ~/bin/android-build-locked (one Android or
# Flutter build at a time on the machine); without it the script refuses
# to run, except in CI ($CI set), where builds run alone.
#
# Usage: tool/build_web.sh [--base-href /zx/online/]
set -euo pipefail
cd "$(dirname "$0")/.."

base=/zx/online/
if [ "${1:-}" = --base-href ]; then base=$2; fi

if [ -x "$HOME/bin/android-build-locked" ]; then
  run=("$HOME/bin/android-build-locked" flutter)
elif [ -n "${CI:-}" ]; then
  run=(flutter)
else
  echo "build_web: ~/bin/android-build-locked is missing; builds go through it" >&2
  exit 1
fi

(cd app && "${run[@]}" build web --release --wasm --no-web-resources-cdn \
  --base-href "$base" -t lib/main_web.dart)

out=app/build/web
mkdir -p "$out/engine"
dart compile wasm -O2 web_engine/zx_engine.dart -o "$out/engine/zx_engine.wasm"
rm -f "$out/engine/zx_engine.wasm.map"
cp web_engine/zx_engine_worker.js "$out/engine/"
ls -l "$out/engine"
