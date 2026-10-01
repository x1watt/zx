#!/usr/bin/env bash
# Gives a Windows build of the zx command line tool its icon (logo/zx.ico)
# and version information (shown in Explorer's Properties), with rcedit.
#
# `dart compile exe` appends the compiled program to the executable, and
# editing the resources of such a file has broken it in some Dart releases
# (dart-lang/sdk#46445). So the resources are written into a copy, the
# copy is run, and it replaces the original only when it works; otherwise
# the executable stays as it was and a warning is printed. The build never
# fails because of the icon.
#
# Runs on Windows (Git Bash, as in .github/workflows/release.yml) or, from
# Linux, through wine.
#
# Usage: tool/windows_exe_icon.sh dist/zx-windows-x64.exe
set -euo pipefail
cd "$(dirname "$0")/.."

exe="$1"
[ -f "$exe" ] || { echo "windows_exe_icon: no such file: $exe" >&2; exit 1; }

RCEDIT_URL=https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe
RCEDIT_SHA256=3e7801db1a5edbec91b49a24a094aad776cb4515488ea5a4ca2289c400eade2a

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) run=() ;;
  *)
    if command -v wine >/dev/null; then
      run=(env WINEDEBUG=-all wine)
    else
      echo "windows_exe_icon: not on Windows and no wine: $exe keeps no icon" >&2
      exit 0
    fi
    ;;
esac

warn() {
  echo "::warning::windows_exe_icon: $1; $exe is left without an icon" >&2
  exit 0
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

rcedit="$work/rcedit-x64.exe"
curl -fsSL --retry 3 -o "$rcedit" "$RCEDIT_URL" || warn "rcedit could not be downloaded"
if command -v sha256sum >/dev/null; then
  sum=$(sha256sum "$rcedit" | cut -d' ' -f1)
else
  sum=$(shasum -a 256 "$rcedit" | cut -d' ' -f1)
fi
[ "$sum" = "$RCEDIT_SHA256" ] || warn "rcedit has an unexpected SHA-256 ($sum)"

version=$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' pubspec.yaml | head -1)
[ -n "$version" ] || version=0.0.0

copy="$work/zx.exe"
cp "$exe" "$copy"
"${run[@]}" "$rcedit" "$copy" \
  --set-icon "logo/zx.ico" \
  --set-file-version "$version" \
  --set-product-version "$version" \
  --set-version-string FileDescription "zx archiver" \
  --set-version-string ProductName "zx" \
  --set-version-string CompanyName "Max Brito" \
  --set-version-string LegalCopyright "Copyright (c) 2026 Max Brito, BSD 3-clause" \
  --set-version-string OriginalFilename "zx.exe" \
  --set-version-string InternalName "zx" \
  || warn "rcedit failed"

# the edited executable must still run: list the formats, then a round
# trip through a small archive
probe="$work/probe"
mkdir -p "$probe/in"
echo hello > "$probe/in/a.txt"
"${run[@]}" "$copy" i > /dev/null 2>&1 || warn "the edited executable does not start"
( cd "$probe" && "${run[@]}" "$copy" a t.zx ./in > /dev/null 2>&1 \
  && "${run[@]}" "$copy" x -oout t.zx > /dev/null 2>&1 \
  && cmp -s in/a.txt out/in/a.txt ) || warn "the edited executable does not work"

cp "$copy" "$exe"
echo "windows_exe_icon: $exe has the zx icon and version $version"
