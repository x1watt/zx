#!/bin/bash
# Reference benchmark against 7-Zip (/usr/bin/7z).
#
#   dart compile exe tool/bench.dart -o /tmp/zxbench
#   ZX=/tmp/zxbench tool/benchmark.sh <data dir> [runs] [filter]
#
# For every case prints the best wall time of [runs] runs (default 3), the
# CPU time (user + system) and the peak resident size of that run, and the
# output size. [filter] is a grep pattern on the case names. Works in a
# temporary folder, the data is only read. Run it alone: the cases are
# sequential on purpose.
set -u
data=$(realpath "$1")
runs=${2:-3}
filter=${3:-.}
SZ=${SZ:-/usr/bin/7z}
export LC_NUMERIC=C
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
bytes=$(du -sb "$data" | cut -f1)

# best <name> <output file or dir> <setup command, may be empty> <command...>
best() {
  local name=$1 out=$2 setup=$3; shift 3
  echo "$name" | grep -qE "$filter" || return 0
  local bw=999999 bc=0 bm=0 w u s m
  for _ in $(seq "$runs"); do
    [ -n "$setup" ] && bash -c "$setup"
    /usr/bin/time -f "%e %U %S %M" -o t.txt "$@" >/dev/null 2>&1
    read -r w u s m < t.txt
    if (( $(echo "$w < $bw" | bc) )); then
      bw=$w; bc=$(echo "$u + $s" | bc); bm=$m
    fi
  done
  local size=$(du -sb "$out" 2>/dev/null | cut -f1)
  printf "%-26s %7.2f s %7.2f s cpu %6.1f MB/s %5d MB rss %10s bytes\n" \
    "$name" "$bw" "$bc" "$(echo "$bytes / 1048576 / $bw" | bc -l)" \
    $((bm / 1024)) "$size"
}

for x in 1 5 9; do
  best "zx  7z a -mx$x" z.7z "rm -f z.7z" "$ZX" a z.7z "$data" x=$x mt=1
  best "7z  7z a -mx$x -mmt1" s.7z "rm -f s.7z" "$SZ" a s.7z "$data/." -mx$x -mmt1
  best "7z  7z a -mx$x" s.7z "rm -f s.7z" "$SZ" a s.7z "$data/." -mx$x
done
best "zx  7z a PPMd -mx5" z.7z "rm -f z.7z" "$ZX" a z.7z "$data" x=5 0=PPMd
best "7z  7z a PPMd -mx5" s.7z "rm -f s.7z" "$SZ" a s.7z "$data/." -mx5 -m0=PPMd -mmt1

# Extraction of the same archives, made by 7z.
for m in "-mx5" "-m0=PPMd"; do
  rm -f r.7z; "$SZ" a r.7z "$data/." $m >/dev/null
  best "zx  7z x $m" xd "rm -rf xd" "$ZX" x r.7z xd
  best "7z  7z x $m" xs "rm -rf xs" "$SZ" x r.7z -oxs
done

# xz: the parallel block encoder, 4 MB blocks (-ms=4m) so that a 36 MB
# input has blocks for every thread.
tar -cf in.tar -C "$data" .
for t in 1 4 8; do
  best "zx  xz -mx5 -ms=4m mt$t" z.xz "rm -f z.xz" "$ZX" xz in.tar z.xz 5 $t s=4m
  best "7z  xz -mx5 -ms=4m mt$t" s.xz "rm -f s.xz" "$SZ" a -txz s.xz in.tar -mx5 -ms=4m -mmt=$t
done
rm -f r.xz; "$SZ" a -txz r.xz in.tar -mx5 >/dev/null
best "zx  unxz" o.tar "rm -f o.tar" "$ZX" unxz r.xz o.tar
best "7z  unxz" xs2 "rm -rf xs2" "$SZ" e r.xz -oxs2
