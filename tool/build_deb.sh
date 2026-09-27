#!/usr/bin/env bash
# Builds the Debian package of zx: dist/zx_<version>_amd64.deb, the version
# taken from pubspec.yaml. No root is needed (dpkg-deb --root-owner-group).
#
#   /opt/zx/                         the Flutter release bundle (zx_app)
#   /usr/bin/zx                      the command line tool (AOT, bin/zx.dart)
#   /usr/bin/zx-gui                  the launcher of the app
#   /usr/share/applications/zx.desktop
#   /usr/share/icons/hicolor/*/apps/zx.{png,svg}
#   /usr/lib/x86_64-linux-gnu/nautilus/extensions-4/libzx-nautilus.so
#   /usr/share/doc/zx/               README, changelog, copyright
#
# The package sets no default application: that is the per user switch in
# the settings of the app. The Nautilus item is on unless switched off in
# the settings (~/.config/zx/context-menu-disabled).
#
# Usage: tool/build_deb.sh [--no-build]
#   --no-build   use the existing release bundle, CLI and extension
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BUILD=1
for a in "$@"; do
  case "$a" in
    --no-build) BUILD=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/^version:[[:space:]]*\([^[:space:]+]*\).*/\1/p' pubspec.yaml | head -1)"
[ -n "$VERSION" ] || { echo "no version in pubspec.yaml" >&2; exit 1; }
ARCH=amd64
MULTIARCH=x86_64-linux-gnu
[ "$(dpkg --print-architecture)" = "$ARCH" ] || {
  echo "this script builds $ARCH packages on an $ARCH host" >&2; exit 1; }

BUNDLE="$ROOT/app/build/linux/x64/release/bundle"
CLI="$ROOT/build/deb/zx"
EXT="$ROOT/native/nautilus/libzx-nautilus.so"
STAGE="$ROOT/build/deb/zx_${VERSION}_${ARCH}"
OUT="$ROOT/dist/zx_${VERSION}_${ARCH}.deb"

# ---- build the parts ----
if [ "$BUILD" = 1 ]; then
  echo "== Flutter release bundle"
  (cd app && flutter pub get >/dev/null)
  # heavy builds are serialized on the development machine
  if [ -x "$HOME/bin/android-build-locked" ]; then
    (cd app && "$HOME/bin/android-build-locked" flutter build linux --release)
  else
    (cd app && flutter build linux --release)
  fi
  echo "== command line tool"
  dart pub get >/dev/null
  mkdir -p "$(dirname "$CLI")"
  dart compile exe bin/zx.dart -o "$CLI"
  echo "== Nautilus extension"
  tool/fetch_nautilus_headers.sh
  make -C native/nautilus clean all test
fi
for f in "$BUNDLE/zx_app" "$CLI" "$EXT"; do
  [ -e "$f" ] || { echo "missing $f (drop --no-build)" >&2; exit 1; }
done

# ---- the tree ----
echo "== staging $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/opt" "$STAGE/usr/bin" \
  "$STAGE/usr/share/applications" "$STAGE/usr/share/doc/zx" \
  "$STAGE/usr/lib/$MULTIARCH/nautilus/extensions-4" \
  "$STAGE/usr/share/lintian/overrides"
cp -a "$BUNDLE" "$STAGE/opt/zx"
install -m 755 "$CLI" "$STAGE/usr/bin/zx"
cat > "$STAGE/usr/bin/zx-gui" <<'EOF'
#!/bin/sh
# zx archive manager
exec /opt/zx/zx_app "$@"
EOF
chmod 755 "$STAGE/usr/bin/zx-gui"
(cd app && dart tool/desktop_entry.dart /usr/bin/zx-gui) \
  > "$STAGE/usr/share/applications/zx.desktop"
if command -v desktop-file-validate >/dev/null; then
  desktop-file-validate "$STAGE/usr/share/applications/zx.desktop"
fi

ICONS="$ROOT/app/assets/icon"
install -D -m 644 "$ICONS/zx.svg" "$STAGE/usr/share/icons/hicolor/scalable/apps/zx.svg"
for s in 16 24 32 48 64 128 256 512; do
  install -D -m 644 "$ICONS/zx-$s.png" "$STAGE/usr/share/icons/hicolor/${s}x$s/apps/zx.png"
done

install -m 644 "$EXT" "$STAGE/usr/lib/$MULTIARCH/nautilus/extensions-4/libzx-nautilus.so"
strip --strip-unneeded "$STAGE/usr/lib/$MULTIARCH/nautilus/extensions-4/libzx-nautilus.so"

DOC="$STAGE/usr/share/doc/zx"
install -m 644 README.md "$DOC/README.md"
install -m 644 app/README.md "$DOC/README.app.md"
gzip -9n -c CHANGELOG.md > "$DOC/changelog.gz"
chmod 644 "$DOC/changelog.gz"
{
  echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
  echo "Upstream-Name: zx"
  echo "Comment: the third party sources zx is ported from and their licenses"
  echo " are listed in README.md (section Credits)."
  echo
  echo "Files: *"
  echo "Copyright: 2026 Max Brito"
  echo "License: BSD-3-Clause"
  echo
  echo "License: BSD-3-Clause"
  sed -e 's/^$/./' -e 's/^/ /' LICENSE
} > "$DOC/copyright"

# The Dart AOT executable carries its snapshot after the ELF sections, so
# it is not stripped; the bundle lives in /opt like other add-on packages.
cat > "$STAGE/usr/share/lintian/overrides/zx" <<'EOF'
zx: dir-or-file-in-opt [opt/zx/*]
zx: unstripped-binary-or-object [usr/bin/zx]
zx: embedded-library *
EOF

# normal modes
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f ! -perm -u+x -exec chmod 644 {} +
find "$STAGE" -type f -perm -u+x -exec chmod 755 {} +

# ---- control ----
echo "== dependencies"
# The shared libraries of the bundle and of the CLI (not of the Nautilus
# extension: it is loaded only by Nautilus, which brings its library).
mapfile -t ELFS < <(find "$STAGE/opt/zx" "$STAGE/usr/bin" -type f \
  -exec sh -c 'head -c4 "$1" | grep -q "ELF" && echo "$1"' _ {} \;)
DEPENDS=""
if command -v dpkg-shlibdeps >/dev/null; then
  SHL="$ROOT/build/deb/shlibdeps"
  rm -rf "$SHL" && mkdir -p "$SHL/debian"
  printf 'Source: zx\n\nPackage: zx\nArchitecture: any\n' > "$SHL/debian/control"
  DEPENDS="$(cd "$SHL" && dpkg-shlibdeps -O --ignore-missing-info \
    -l"$STAGE/opt/zx/lib" "${ELFS[@]}" 2>/dev/null \
    | sed -n 's/^shlibs:Depends=//p')"
fi
if [ -z "$DEPENDS" ]; then
  DEPENDS="libc6, libgcc-s1, libstdc++6, libglib2.0-0t64 | libglib2.0-0, libgtk-3-0t64 | libgtk-3-0"
fi
INSTALLED_SIZE="$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: zx
Version: $VERSION
Architecture: $ARCH
Maintainer: Max Brito <maxbrito.x1@gmail.com>
Installed-Size: $INSTALLED_SIZE
Depends: $DEPENDS
Recommends: xdg-utils
Suggests: nautilus | thunar
Section: utils
Priority: optional
Description: archive manager for 7z, zip, rar, tar, gz, bz2, xz, lzh and arj
 zx opens, creates and extracts archives: 7z, zip and jar, rar (1.5 to 7,
 creates RAR5), tar and the compressed tars, gz, bz2, xz, lzma, lzh, arj
 and split volumes. It is written in Dart on the zx library, a port of
 7-Zip.
 .
 The package contains the desktop app (zx-gui), the command line tool zx
 with the switches of 7-Zip, and a Nautilus extension that adds
 "Extract to <name>/" to the right-click menu of archives (it can be
 switched off in the settings of the app). Making zx the default program
 for archives is a per user choice in the settings of the app.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
  fi
  if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database /usr/share/mime || true
  fi
fi
exit 0
EOF
cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
case "$1" in
  remove|purge|abort-install|abort-upgrade)
    if command -v update-desktop-database >/dev/null 2>&1; then
      update-desktop-database -q /usr/share/applications || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
    fi
    if command -v update-mime-database >/dev/null 2>&1; then
      update-mime-database /usr/share/mime || true
    fi
    ;;
esac
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

# ---- build and check ----
mkdir -p dist
rm -f "$OUT"
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$OUT"
if command -v lintian >/dev/null; then
  lintian --info "$OUT" || true
else
  echo "(lintian is not installed: not linted)"
fi
echo
dpkg-deb -I "$OUT"
echo "Built $OUT"
echo "Install: sudo apt install ./$(realpath --relative-to="$ROOT" "$OUT")"
