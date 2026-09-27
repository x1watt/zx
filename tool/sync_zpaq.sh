#!/bin/sh
# Copies the zpaq engine from zpaq-flutter (the upstream of lib/src/zpaq)
# into this package.
#
# zpaq-flutter (package `zpaq`, by the same author) is the pure Dart port of
# libzpaq / zpaq 7.15 and of zpaqfranz's attribute format. zx vendors it so
# that it keeps no run-time dependencies: lib/src/zpaq is a copy of
# zpaq-flutter/lib/src (same layout, plus lib/zpaq.dart as zpaq.dart), and
# the small tests of zpaq-flutter become test/zpaq_*_test.dart. Do not edit
# the copies: change zpaq-flutter, then run this script from the zx folder:
#
#   tool/sync_zpaq.sh [path/to/zpaq-flutter]     (default ../zpaq-flutter)
#
# Each copied file gets the zx license header; the notices inside the files
# (divsufsort) are kept. The format handler of zx (lib/src/format/zpaq) is
# not touched.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-$here/../zpaq-flutter}
src=$(cd "$src" && pwd)
dst=$here/lib/src/zpaq

if [ ! -f "$src/lib/zpaq.dart" ] || [ ! -d "$src/lib/src" ]; then
  echo "not a zpaq-flutter checkout: $src" >&2
  exit 1
fi

header='// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.
'

# prepend the header and rewrite package imports
copy() {
  mkdir -p "$(dirname "$2")"
  {
    printf '%s\n' "$header"
    sed -e "s#package:zpaq/src/#package:zx/src/zpaq/#g" \
        -e "s#package:zpaq/zpaq.dart#package:zx/src/zpaq/zpaq.dart#g" \
        -e "s#^export 'src/#export '#" \
        "$1"
  } > "$2"
}

rm -rf "$dst"
mkdir -p "$dst"
(cd "$src/lib/src" && find . -name '*.dart' -type f) | sort | while read -r f; do
  copy "$src/lib/src/$f" "$dst/${f#./}"
done
copy "$src/lib/zpaq.dart" "$dst/zpaq.dart"

# the small tests (the heavy benchmarks, the threads comparison on large
# inputs and the interop test of zpaq-flutter stay there; test/zpaq_test.dart
# checks interop through the zx command line)
for t in archive crypto_hash generated lz_tables native_pcomp scan suffix_array; do
  if [ -f "$src/test/${t}_test.dart" ]; then
    copy "$src/test/${t}_test.dart" "$here/test/zpaq_${t}_test.dart"
  fi
done

# comments and docs stay plain ASCII
if grep -rnP '[^\x00-\x7F]' "$dst" >/dev/null 2>&1; then
  echo "warning: non-ASCII characters in lib/src/zpaq:" >&2
  grep -rlP '[^\x00-\x7F]' "$dst" >&2
fi
echo "synced $(find "$dst" -name '*.dart' | wc -l) files from $src"
