#!/bin/sh
# Builds the RAR 1.5, RAR 2.x and RAR 3.x fixtures of test/rar_test.dart
# in test/data/rar_legacy (rar 7 can not write these formats any more):
#
#   rar15_*.rar  RAR 1.5 compression (unpack version 15) and the RAR 1.5
#                cipher, written by RAR 1.55 for DOS under DOSBox.
#   rar20_*.rar  RAR 2.0 compression (unpack version 20), written by the
#                console Rar.exe 2.90 of WinRAR 2.90 under wine; -mm and
#                -mmf make audio (multimedia) blocks; -p uses the RAR 2.0
#                cipher.
#   rar3_*.rar   RAR 3.x AES encryption (-p file data, -hp headers too),
#                written by rar 3.93 for Linux.
#
# The programs are the shareware versions, kept in ref/tools/legacy (not
# committed): rar 3.93 and WinRAR 2.90 from rarlab.com, RAR 1.55 for DOS
# from a collection of DOS archivers on archive.org (rarlab.com no longer
# has it). DOSBox is the system one, or the Ubuntu package unpacked into
# ref/tools/legacy/dosbox (apt-get download, no root needed). The archives
# are checked with unrar.
#
# Usage: sh tool/rar_legacy_fixtures.sh [out_dir]
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/test/data/rar_legacy}
tools=$root/ref/tools/legacy
mkdir -p "$out" "$tools"
out=$(cd "$out" && pwd)

if [ ! -x "$tools/rar393/rar" ]; then
  mkdir -p "$tools/rar393"
  curl -sSL -o "$tools/rarlinux-3.9.3.tar.gz" \
    https://www.rarlab.com/rar/rarlinux-3.9.3.tar.gz
  tar xzf "$tools/rarlinux-3.9.3.tar.gz" -C "$tools/rar393" --strip-components=1
fi
if [ ! -f "$tools/wrar290/Rar.exe" ]; then
  curl -sSL -o "$tools/wrar290.exe" https://www.rarlab.com/rar/wrar290.exe
  unrar x -inul -y "$tools/wrar290.exe" "$tools/wrar290/"
fi

if [ ! -f "$tools/rar155/RAR.EXE" ]; then
  mkdir -p "$tools/rar155"
  curl -sSL -o "$tools/archive_utilities.zip" \
    "https://archive.org/download/archiveutilities/Archive%20Utilities.zip"
  unzip -o -q -j "$tools/archive_utilities.zip" \
    'Archive Utilities/rar155.zip' -d "$tools/rar155"
  unzip -o -q "$tools/rar155/rar155.zip" -d "$tools/rar155"
  # rar155.exe is a self extracting RAR 1.5 archive
  (cd "$tools/rar155" && unrar e -inul -y rar155.exe RAR.EXE)
fi
echo "8199a543b1dfbb8229b5079f2d88e1d679731138ce540054f27da74c89e128e6  $tools/rar155/RAR.EXE" |
  sha256sum -c --quiet
dosbox=$(command -v dosbox || true)
dosbox_libs=
if [ -z "$dosbox" ]; then
  dosbox=$tools/dosbox/usr/bin/dosbox
  dosbox_libs=$tools/dosbox/usr/lib/x86_64-linux-gnu
  if [ ! -x "$dosbox" ]; then
    mkdir -p "$tools/dosbox"
    (cd "$tools/dosbox" &&
      apt-get download dosbox libsdl-sound1.2 libsdl-net1.2 libmikmod3 &&
      for d in ./*.deb; do dpkg -x "$d" .; done)
  fi
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

# deterministic sources: PCM like data (one to four channels) and text
python3 - <<'EOF'
import math, struct
def lcg(seed):
    s = seed
    while True:
        s = (s * 1103515245 + 12345) & 0x7fffffff
        yield (s >> 16) & 0xff
r = lcg(7)
b = bytearray()
for i in range(6000):
    l = int(12000 * math.sin(i / 9.0) + 3000 * math.sin(i / 2.1)) + next(r) - 128
    rr = int(9000 * math.sin(i / 13.0)) + next(r) - 128
    b += struct.pack('<hh', l, rr)
open('st16.pcm', 'wb').write(b)
b = bytearray()
for i in range(5000):
    for c in range(4):
        b.append((int(128 + 100 * math.sin(i * 2 * math.pi / (50 + c * 13)))
                  + (next(r) & 3)) & 0xff)
open('ch4.pcm', 'wb').write(b)
open('mono8.pcm', 'wb').write(
    bytes(int(128 + 120 * math.sin(i / 7.0)) & 0xff for i in range(12000)))
words = [b'alpha', b'beta', b'gamma', b'archive', b'volume', b' ', b'\n',
         b'solid', b'window', b'filter']
t = bytearray()
while len(t) < 30000:
    t += words[next(r) % len(words)]
open('text.txt', 'wb').write(t)
open('rand.bin', 'wb').write(bytes(next(r) for _ in range(5000)))
EOF

export WINEPREFIX="$tools/wineprefix" WINEDEBUG=-all
# Rar.exe takes "/..." for a switch: it writes in the work folder
rar2() { wine "$tools/wrar290/Rar.exe" "$@" >/dev/null; mv "$2" "$out/"; }
rar3() { "$tools/rar393/rar" "$@" -inul; }

# RAR 1.55 for DOS: the commands of a batch file run in DOSBox (no
# window, no sound), in the work folder
rar15() {
  cp "$tools/rar155/RAR.EXE" RAR.EXE
  printf '%s\r\n' "$@" exit > GO.BAT
  cat > dosbox.conf <<'CONF'
[cpu]
core=dynamic
cycles=max
[mixer]
nosound=true
[speaker]
pcspeaker=false
CONF
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy LD_LIBRARY_PATH=$dosbox_libs \
    "$dosbox" -conf dosbox.conf -c "mount c $work" -c c: -c go.bat \
    >/dev/null 2>&1
  rm -f RAR.EXE GO.BAT dosbox.conf
}

rm -f "$out"/rar15_*.rar "$out"/rar20_*.rar "$out"/rar3_*.rar
rar2 a rar20_lz.rar -m3 -y text.txt rand.bin
rar2 a rar20_audio_solid.rar -m5 -mm -s -y st16.pcm text.txt mono8.pcm
rar2 a rar20_audio4.rar -m5 -mmf -y ch4.pcm
rar2 a rar20_crypt.rar -m3 -ppassword -y text.txt
printf 'An archive comment of RAR 2.90, long enough to be compressed. %s\r\n' \
  'An archive comment of RAR 2.90.' > cmt.txt
rar2 a rar20_comment.rar -m3 -zcmt.txt -y mono8.pcm
rar2 a rar20_crypt_solid.rar -m5 -s -mm "-pa longer password" -y \
  mono8.pcm text.txt rand.bin
rar2 a rar20_crypt_stored.rar -m0 -ppassword -y mono8.pcm
printf 'An archive comment of RAR 1.55, long enough to be compressed. %s\r\n' \
  'An archive comment of RAR 1.55.' > cmt15.txt
rar15 'RAR a -y -m3 R15LZ.RAR TEXT.TXT RAND.BIN' \
  'RAR a -y -m5 -s R15SOL.RAR TEXT.TXT MONO8.PCM RAND.BIN ST16.PCM' \
  'RAR a -y -m3 -ppassword R15CRY.RAR TEXT.TXT RAND.BIN' \
  'RAR a -y -m0 -ppassword R15CRS.RAR MONO8.PCM' \
  'RAR a -y -m3 -zCMT15.TXT R15CMT.RAR MONO8.PCM'
for f in LZ:lz SOL:solid CRY:crypt CRS:crypt_stored CMT:comment; do
  mv "R15${f%%:*}.RAR" "$out/rar15_${f#*:}.rar"
done
rar3 a -m3 -ppassword "$out/rar3_p.rar" text.txt rand.bin
rar3 a -m0 -ppassword "$out/rar3_p_stored.rar" mono8.pcm
rar3 a -m5 -s -hppassword "$out/rar3_hp_solid.rar" text.txt st16.pcm ch4.pcm
rar3 a -m3 -v20k -hppassword "$out/rar3_hp_vol.rar" text.txt st16.pcm
rar3 a -m3 "-p$(printf 'p\303\244ss\342\202\254')" "$out/rar3_p_unicode.rar" \
  text.txt

for f in "$out"/rar15_*.rar "$out"/rar20_*.rar "$out"/rar3_*.rar; do
  case $f in
    *part2.rar) continue ;;
    *unicode*) pw=$(printf 'p\303\244ss\342\202\254') ;;
    *rar20_crypt_solid*) pw='a longer password' ;;
    *) pw=password ;;
  esac
  unrar t -inul "-p$pw" "$f" || echo "unrar t failed: $f" >&2
done
ls -l "$out"
