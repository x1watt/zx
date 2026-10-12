#!/usr/bin/env bash
# Builds the parts of the self-extracting .zx archives (native/sfx): the
# engines (wasm3 and the host functions, static, one per CPU) with zig as
# the cross compiler, the decoder (zxsfx.wasm) with clang and wasm-ld, and
# writes them into lib/src/format/zx/zx_sfx_payload.dart.
#
# zig is downloaded into build/tools when it is not on the PATH (build/ is
# not committed). Usage: tool/build_sfx.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG_VERSION=0.13.0
if ! command -v zig >/dev/null; then
  tools=build/tools
  zig_dir="$tools/zig-linux-$(uname -m)-$ZIG_VERSION"
  if [ ! -x "$zig_dir/zig" ]; then
    mkdir -p "$tools"
    curl -sSL "https://ziglang.org/download/$ZIG_VERSION/zig-linux-$(uname -m)-$ZIG_VERSION.tar.xz" |
      tar xJ -C "$tools"
  fi
  PATH="$PWD/$zig_dir:$PATH"
fi

make -C native/sfx -j4 all
dart run tool/gen_sfx_payload.dart native/sfx/out lib/src/format/zx/zx_sfx_payload.dart
ls -l native/sfx/out
