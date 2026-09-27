#!/usr/bin/env bash
# Installs the zx archive manager for the current user (no root needed):
#   ~/.local/share/zx/app          the release bundle
#   ~/.local/bin/zx-gui            a launcher
#   ~/.local/share/applications/zx.desktop and the icons (hicolor)
# and, unless switched off, the file associations and the "Extract to
# folder" entry of Nautilus and Thunar. Everything except the copy of the
# bundle is done by the app itself (zx_app --install-integration), the same
# code as the switches in its settings.
#
# Usage: tool/install_linux.sh [--no-build] [--no-associations]
#                              [--no-context-menu]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
DEST="$DATA/zx/app"
BINDIR="$HOME/.local/bin"
BUILD=1
ASSOC=1
MENU=1
for a in "$@"; do
  case "$a" in
    --no-build) BUILD=0 ;;
    --no-associations) ASSOC=0 ;;
    --no-context-menu) MENU=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

BUNDLE="$APP/build/linux/x64/release/bundle"
if [ "$BUILD" = 1 ]; then
  echo "Building the release bundle..."
  cd "$APP"
  flutter pub get >/dev/null
  # heavy builds are serialized on this machine
  if [ -x "$HOME/bin/android-build-locked" ]; then
    "$HOME/bin/android-build-locked" flutter build linux --release
  else
    flutter build linux --release
  fi
  cd - >/dev/null
fi
if [ ! -x "$BUNDLE/zx_app" ]; then
  echo "No bundle at $BUNDLE (build it, or drop --no-build)" >&2
  exit 1
fi

echo "Copying the bundle to $DEST"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST.new"
cp -a "$BUNDLE" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"

echo "Writing the launcher $BINDIR/zx-gui"
mkdir -p "$BINDIR"
cat > "$BINDIR/zx-gui" <<LAUNCHER
#!/bin/sh
# zx archive manager (installed by tool/install_linux.sh)
exec "$DEST/zx_app" "\$@"
LAUNCHER
chmod 755 "$BINDIR/zx-gui"

ARGS=(--install-integration)
[ "$ASSOC" = 1 ] && ARGS+=(--associations)
[ "$MENU" = 1 ] && ARGS+=(--context-menu)
[ "$ASSOC" = 0 ] && [ "$MENU" = 0 ] && ARGS+=(--register)
echo "Desktop integration: ${ARGS[*]}"
"$DEST/zx_app" "${ARGS[@]}"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "Note: $BINDIR is not on PATH; the desktop entry works anyway." ;;
esac
if [ "$MENU" = 1 ] && ! ls /usr/lib/*/nautilus/extensions-4/libnautilus-python.so >/dev/null 2>&1; then
  echo "Note: for the top level \"Extract to <name>/\" item in Nautilus install"
  echo "      python3-nautilus (sudo apt install python3-nautilus), then run nautilus -q."
  echo "      Until then the entry is under Scripts in the right-click menu."
fi
echo "Done. Start zx from the applications menu or with zx-gui."
