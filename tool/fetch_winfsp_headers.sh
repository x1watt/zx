#!/usr/bin/env bash
# Puts the FUSE headers of WinFsp (winfsp/winfsp on GitHub, tag v2.0) into
# ref/build-deps/winfsp/inc/fuse, for building native/fuse/zx-mount-fuse2.c
# for Windows (make -C native/fuse windows). They are GPLv3 with the FLOSS
# exception: they are fetched, not committed. The program links to
# winfsp-x64.dll dynamically and needs the WinFsp installer at run time.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/ref/build-deps/winfsp/inc/fuse"
TAG="${WINFSP_TAG:-v2.0}"
if [ -f "$DIR/fuse.h" ] && [ -f "$DIR/winfsp_fuse.h" ]; then
  echo "headers already in $DIR"
  exit 0
fi
mkdir -p "$DIR"
for f in fuse.h fuse_common.h fuse_opt.h winfsp_fuse.h; do
  curl -fsSL -o "$DIR/$f" "https://raw.githubusercontent.com/winfsp/winfsp/$TAG/inc/fuse/$f"
done
echo "headers in $DIR"
