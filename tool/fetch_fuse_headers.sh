#!/usr/bin/env bash
# Puts the headers of libfuse3-dev into ref/build-deps/root (without root:
# apt-get download and dpkg-deb -x), for building
# native/fuse when the package is not installed. Nothing to do when
# pkg-config already finds fuse3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/ref/build-deps"
if pkg-config --exists fuse3; then
  echo "libfuse3-dev is installed: nothing to fetch"
  exit 0
fi
if [ -f "$DEPS/root/usr/include/fuse3/fuse.h" ]; then
  echo "headers already in $DEPS/root"
  exit 0
fi
mkdir -p "$DEPS"
cd "$DEPS"
rm -f libfuse3-dev_*.deb
apt-get download libfuse3-dev
dpkg-deb -x libfuse3-dev_*.deb root
echo "headers in $DEPS/root/usr/include/fuse3"
