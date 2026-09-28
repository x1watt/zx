#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

# Stop both the app executable and any Flutter runner still attached to it.
pkill -x zx_app 2>/dev/null || true
pkill -f '[f]lutter_tools.snapshot run -d linux' 2>/dev/null || true

FLUTTER="${FLUTTER:-flutter}"
LOCK="$HOME/bin/android-build-locked"
if [[ -x "$LOCK" ]]; then
  exec "$LOCK" "$FLUTTER" run -d linux "$@"
fi
exec "$FLUTTER" run -d linux "$@"
