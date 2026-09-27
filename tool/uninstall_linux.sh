#!/usr/bin/env bash
# Removes what tool/install_linux.sh installed: the desktop integration
# (desktop entry, icons, associations, Nautilus and Thunar entries; the
# previous default applications are given back), the launcher and the
# bundle. The settings in ~/.config/zx stay unless --purge is given.
set -euo pipefail

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
DEST="$DATA/zx/app"
PURGE=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

if [ -x "$DEST/zx_app" ]; then
  echo "Removing the desktop integration"
  "$DEST/zx_app" --remove-integration || true
else
  echo "No installed app at $DEST: removing the known files directly"
  rm -f "$DATA/applications/zx.desktop" \
        "$DATA/nautilus/scripts/Extract to folder (zx)" \
        "$CONFIG/zx/context-menu-disabled" \
        "$DATA/nautilus-python/extensions/zx_extract.py"
fi
rm -f "$HOME/.local/bin/zx-gui"
rm -rf "$DEST"
rmdir "$DATA/zx" 2>/dev/null || true
if [ "$PURGE" = 1 ]; then
  rm -rf "$CONFIG/zx"
fi
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" || true
echo "zx is uninstalled."
