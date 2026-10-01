#!/usr/bin/env bash
# Builds the Android app as dist/zx.apk (one APK for every ABI). With
# --split, one APK per ABI instead: dist/zx-arm64-v8a.apk (almost every
# phone of the last years), dist/zx-armeabi-v7a.apk (older 32 bit phones)
# and dist/zx-x86_64.apk (emulators, Chromebooks).
#
# The build goes through ~/bin/android-build-locked when it exists (one
# Android or Flutter build at a time on the machine).
#
# Usage: tool/build_apk.sh [--split]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist

run=(flutter)
[ -x "$HOME/bin/android-build-locked" ] && run=("$HOME/bin/android-build-locked" flutter)

out=app/build/app/outputs/flutter-apk
if [ "${1:-}" = --split ]; then
  (cd app && "${run[@]}" build apk --release --split-per-abi)
  for abi in arm64-v8a armeabi-v7a x86_64; do
    cp "$out/app-$abi-release.apk" "dist/zx-$abi.apk"
  done
else
  (cd app && "${run[@]}" build apk --release)
  cp "$out/app-release.apk" dist/zx.apk
fi
ls -l dist/zx*.apk
