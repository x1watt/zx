#!/usr/bin/env bash
# Puts the headers of libnautilus-extension-dev into ref/build-deps/root
# (without root: apt-get download and dpkg-deb -x), for building
# native/nautilus when the package is not installed. Nothing to do when
# pkg-config already finds libnautilus-extension-4.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/ref/build-deps"
if pkg-config --exists libnautilus-extension-4; then
  echo "libnautilus-extension-dev is installed: nothing to fetch"
  exit 0
fi
if [ -f "$DEPS/root/usr/include/nautilus/nautilus-extension.h" ]; then
  echo "headers already in $DEPS/root"
  exit 0
fi
mkdir -p "$DEPS"
cd "$DEPS"
rm -f libnautilus-extension-dev_*.deb
apt-get download libnautilus-extension-dev
dpkg-deb -x libnautilus-extension-dev_*.deb root
echo "headers in $DEPS/root/usr/include/nautilus"
