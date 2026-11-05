#!/usr/bin/env bash
# Builds the zx command line tool as native executables into dist/.
#
# The Dart SDK only cross-compiles to Linux, so from a Linux host this
# builds linux-x64 and linux-arm64 directly. windows-x64 is built too when
# DART_WINDOWS points to a Windows Dart SDK (bin/dart.exe) and wine is
# installed. macOS binaries must be built on a Mac (or by the GitHub
# workflow in .github/workflows/release.yml, which builds all platforms).
# Windows builds get the zx icon and version information
# (tool/windows_exe_icon.sh).
#
# Usage: tool/build_binaries.sh
#        DART_WINDOWS=/path/to/dart-sdk tool/build_binaries.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist

host_os=$(uname -s)
if [ "$host_os" = Linux ]; then
  dart compile exe --target-os linux --target-arch x64 bin/zx.dart -o dist/zx-linux-x64
  dart compile exe --target-os linux --target-arch arm64 bin/zx.dart -o dist/zx-linux-arm64
  if [ -n "${DART_WINDOWS:-}" ] && command -v wine >/dev/null; then
    WINEDEBUG=-all wine "$DART_WINDOWS/bin/dart.exe" compile exe bin/zx.dart -o dist/zx-windows-x64.exe
    tool/windows_exe_icon.sh dist/zx-windows-x64.exe
  fi
elif [ "$host_os" = Darwin ]; then
  arch=$(uname -m)
  [ "$arch" = x86_64 ] && arch=x64
  dart compile exe bin/zx.dart -o "dist/zx-macos-$arch"
else
  dart compile exe bin/zx.dart -o dist/zx-windows-x64.exe
  tool/windows_exe_icon.sh dist/zx-windows-x64.exe
fi
# The daemon of "zx mount" for Windows (needs WinFsp headers, fetched, and a
# MinGW cross compiler: apt install gcc-mingw-w64-x86-64). Ship it next to
# zx.exe as zx-mount.exe; users install WinFsp (https://winfsp.dev).
if [ "$host_os" = Linux ] && command -v x86_64-w64-mingw32-gcc >/dev/null; then
  tool/fetch_winfsp_headers.sh
  make -C native/fuse clean windows
  cp native/fuse/zx-mount.exe dist/zx-mount-windows-x64.exe
fi
ls -l dist
