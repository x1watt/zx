# Performance

What the port costs in time and memory, and how to measure it. Every
number was measured, with the method next to it. Read with
`docs/architecture.md`.

## 1. Reference numbers

Desktop, AMD Ryzen 7 3700X (8 cores, 16 threads), 16 GB shared with other
work (runs vary by about 10%). Dart 3.13.4, AOT build of `tool/bench.dart`
(`dart compile exe`), which calls the public API (so the numbers include
the isolate and the file handling). Reference: 7-Zip 23.01 (x64) at
`/usr/bin/7z`. Input: 37.5 MB in 820 files (the C and C++ sources of the
LZMA SDK, the Python 3 standard library sources, six shared libraries from
`/usr/lib/x86_64-linux-gnu`), 38.2 MB as one tar for xz. One run per case
with `tool/benchmark.sh` (wall time, user + system CPU and peak resident
size from `/usr/bin/time`); MB/s is input size over wall time.

### 7z

The port's 7z writer runs on one isolate, so the fair comparison is 7-Zip
with `-mmt1`. The 7-Zip default (16 threads) is listed for scale.

| Operation | zx | 7-Zip -mmt1 | 7-Zip, 16 threads |
|---|---|---|---|
| a -mx1 (LZMA2) | 2.43 s, 14.7 MB/s, 31 MB | 1.37 s, 26.1 MB/s, 14 MB | 0.30 s, 70 MB |
| a -mx5 (LZMA2) | 16.2 s, 2.2 MB/s, 330 MB | 10.2 s, 3.5 MB/s, 193 MB | 4.99 s, 200 MB |
| a -mx9 (LZMA2) | 18.6 s, 1.9 MB/s, 334 MB | 11.1 s, 3.2 MB/s, 323 MB | 5.18 s, 328 MB |
| a -m0=PPMd -mx5 | 7.66 s, 4.7 MB/s, 37 MB | 3.42 s, 10.5 MB/s, 27 MB | |
| x, LZMA2 -mx5 archive | 0.85 s, 42 MB/s, 43 MB | 0.62 s, 58 MB/s, 43 MB | |
| x, PPMd archive | 9.68 s, 3.7 MB/s, 34 MB | 4.18 s, 8.6 MB/s, 25 MB | |

Extraction timings are of archives made by 7-Zip (default settings), MB/s
is unpacked data. Archive sizes (zx, 7-Zip -mmt1): -mx1 11,663,720 and
11,663,726 bytes; -mx9 10,462,908 and 10,462,912; PPMd 12,007,311 and
12,007,314 (the few bytes are header fields). At -mx5 the port writes
10,666,164 bytes against 10,667,648: the level 5 dictionary of LzmaEnc.c
26.01 is 32 MB (`LZMA2:25`), 7-Zip 23.01 uses 16 MB (`LZMA2:24`).

So the port runs at 55 to 65% of 7-Zip's single thread speed for LZMA
and LZMA2 encoding, 45% for PPMd, and 70% for LZMA decoding. Peak memory
at -mx5 is higher than 7-Zip's (330 MB against 193 MB): the Dart heap
keeps the encoder's buffers, the match finder tables and the isolate's own
heap.

### xz, parallel blocks

xz with 4 MB blocks (`-ms=4m`), level 5, so that the input has about ten
independent blocks. Same bytes from both programs in every row (compared
with `cmp` for 8 threads, and by `test/api_test.dart`).

| Threads (-mmt) | zx | 7-Zip |
|---|---|---|
| 1 | 14.1 s, 2.5 MB/s, 52 MB | 4.09 s (7.4 s CPU), 55 MB |
| 4 | 4.95 s, 7.2 MB/s, 221 MB | 2.58 s, 108 MB |
| 8 | 3.45 s, 10.4 MB/s, 433 MB | 1.49 s, 211 MB |
| decompress | 0.98 s, 37 MB/s, 25 MB | 0.56 s, 64 MB/s, 23 MB |

With one thread 7-Zip still runs the LZMA match finder in a second thread
(LzFindMt.c), which the port does not have; with several threads it gives
each block two LZMA threads, while the port gives each block one isolate
(section 3). The parallel encoder scales about linearly with the isolates
(4 threads: 2.9 times, 8 threads: 4.1 times the single isolate). Memory
grows by one encoder per worker (about 45 MB each at this setting, the
dictionary being reduced to the block size) plus the blocks in flight.

Without `-ms`, the level 5 block is 4 times the dictionary (128 MB), so an
input under that size is one block and one thread: 38 MB took 16.8 s with
`threads: 4`, as with one.

### .zx, parallel blocks

AOT build of `bin/zx.dart`, 40 MB of C sources (the LZMA SDK's C folder,
zlib, bzip2, libarchive), LZMA2 level 5 in 2 MiB blocks (`-mbs=2m`), so
that there are 20 blocks; `/usr/bin/time`, one run each:

| | -mmt1 | -mmt4 |
|---|---|---|
| a | 8.69 s, 60 MB | 3.03 s, 183 MB |
| t | 0.78 s, 53 MB | 0.43 s, 64 MB |

The archive is 14.3 MB. Compression scales with the workers (2.9 times
with 4); each worker holds its block, its output and an LZMA2 encoder with
the dictionary reduced to the block. With the default 16 MiB blocks a
worker needs about 230 MB at level 5, so the number of workers is also
bounded by a memory limit (`zxWorkerMemory` against `-mmemuse`, by default
min(75% of the available memory, the available memory minus 1.5 GiB)).
The per file SHA-256 and TLSH are computed on the handler's isolate while
the workers code.

### .zx, dedup

`zx_writer.dart` with 64 KiB chunks, LZMA2 level 5 in 16 MiB blocks, 4
workers, AOT, this machine (the trees are in `ref/`); dedup on against
`-mdedup=off`:

| input | off | on | dedup found |
|---|---|---|---|
| cmix and cmix-lowmem (two versions of a tree, 14.5 MB) | 5.04 MB, 4.0 s | 5.05 MB, 2.9 s | 6.1 MB |
| the LZMA SDK twice (16.1 MB) | 1.93 MB, 5.1 s | 1.94 MB, 3.3 s | 8.1 MB |
| libarchive, lhasa, rars, libarchive again (78.5 MB) | 34.0 MB, 8.2 s | 22.0 MB, 7.6 s | 28.4 MB |
| cmix-lowmem appended to an archive of cmix (7.0 MB new) | 4.76 MB new | 0.31 MB new, 0.5 s | 6.1 MB |

Copies within one 16 MiB block are already found by LZMA2 (its window is
the block), so there dedup saves time (the duplicate data is not coded)
and not size; copies further apart, and data met again in a later
generation, are stored once. Most of these duplicates are whole files,
found by the whole-file check (same size and SHA-256).

The cost is on the handler's isolate: the fragmenter and a SHA-256 per
chunk. On 100 MB of random data stored (`-mx0`, one thread, without TLSH)
the write takes 1.82 s with dedup against 0.95 s without, so chunking and
hashing run at about 115 MB/s, far above the LZMA2 workers; the chunk
table adds 62 KB per 100 MB of unique data to every Index. Memory: the
chunk index costs about 70 bytes per chunk (about 1.1 GB per TB of unique
data).

### LZMA against the SDK itself

The LZMA encoder is a port of LzmaEnc.c with the single thread match
finder. On the 38 MB tar, `LzmaUtil` of the SDK built with `-DZ7_ST`
(`gcc -O2`) and the port at the same (default) settings write identical
files (10,972,137 bytes): 5.2 s against 16.2 s. The SDK built with its
multithreaded match finder writes 10,972,339 bytes: LzFindMt.c can pick
different matches on large inputs, so 7-Zip's output at levels 5 to 9
with more than one thread is equally valid but not always identical to
the single thread output. On the small inputs of the tests it is.

### zcm (context mixing, experimental)

`tool/zcm_bench.dart` compiled AOT (`dart compile exe`), one run per case,
in memory (no isolate), on the benchmark corpus: `text.md` (96,530 bytes
of English prose), `source.dart` (200,000 bytes of Dart), `x86.bin`
(142,312 bytes, an x86-64 ELF executable) and `kernel.bin` (262,144 bytes
of an ARM zImage, mostly already compressed). The machine was shared with
other work (load average 1.3 to 3), so speeds vary by about 15%. KB/s is
input KB per second of wall time; decoding runs at the same speed as
encoding (the same model runs). Sizes in bytes; every round trip was
checked.

| Level | text.md | source.dart | x86.bin | kernel.bin | total | enc KB/s |
|---|---|---|---|---|---|---|
| 1 (fast nibble model) | 30,302 | 38,338 | 52,726 | 250,950 | 372,316 | 609 |
| 2 (lean orders 2-6) | 27,881 | 34,175 | 48,684 | 249,305 | 360,045 | 254 |
| 3 (+ words, x86 contexts) | 26,248 | 31,469 | 45,572 | 249,281 | 352,570 | 122 |
| 4 (+ orders 5, 8, sparse, x86 parser) | 26,313 | 31,054 | 39,516 | 248,068 | 344,951 | 51 |
| 5 (+ indirect, 16 word contexts) | 26,110 | 30,186 | 39,269 | 247,942 | 343,507 | 39 |
| 6 (+ orders 7, 12, record, char groups, full x86) | 25,791 | 29,582 | 38,848 | 247,638 | 341,859 | 22 |
| 7 (+ byte histories, paq8px indirect, 6 mixer sets) | 25,817 | 29,473 | 38,740 | 247,574 | 341,604 | 14 |
| 8 (+ orders 16, 24, DMC) | 25,860 | 29,527 | 38,543 | 247,517 | 341,447 | 12 |
| 9 (+ PPMd var.H order 16) | 25,784 | 29,457 | 38,399 | 247,532 | 341,172 | 11 |
| 9 + LSTM 64x1, horizon 20 | 25,773 | | 38,306 | | | 3 to 5 |
| xz -9e | 33,440 | 43,268 | 54,520 | 250,012 | 381,240 | |
| 7z PPMd | 29,552 | 40,201 | 56,148 | 258,556 | 384,457 | |
| zpaq -m5 | 27,780 | 33,862 | 49,191 | 249,504 | 360,337 | |
| paq8px v216 -5 | 23,494 | 25,686 | 35,029 | 246,744 | 330,953 | 4 to 7.5 |
| paq8px v216 -8 | 23,481 | 25,611 | 34,961 | 246,748 | 330,801 | 3.5 to 7 |

paq8px was built from `ref/paq8px` with `clang++ -O3 -march=native` and
run under `systemd-run --user --scope -p MemoryMax=3G` (its -5 uses about
0.6 to 0.9 GB, -8 about 1.8 to 2.3 GB here; -9 and up need 4 to 29 GB).
cmix v21 needs about 30 GB and was not run on this 16 GB machine.

Findings:

- Level 1 reaches about 0.6 MB/s (the target was 1 MB/s): per bit it is
  one table read and update per order, a 7 input mixer and one APM; the
  rest is Dart's cost per operation (bounds checks, no SIMD). Level 2 is
  near zpaq -m5, level 3 better than zpaq -m5 on every file.
- Level 9 is 10% larger than paq8px -8 on text.md and x86.bin and 15%
  on source.dart (3% on the whole corpus, where kernel.bin dominates), at
  1.5 to 3 times its speed; levels 4 and 5 are within 11 to 21% of it at
  10 times its speed. paq8px has many more models (a
  text model with stemming, XML, nest, chart, sparse match and more
  word contexts) that zcm does not have yet.
- Above level 6 the extra models pay little on these small files (100
  to 260 KB): they need more data to learn. The time goes to the mixer
  (about half: 4 to 10 weight sets of 100 to 300 inputs, 32-bit integer
  weights) and to the context maps (about 40%, mostly memory latency).
- The x86 parser (paq8px ExeModel) is the largest single gain: x86.bin
  45,572 at level 3 (byte contexts only) against 39,516 at level 4.
- The LSTM is slow and gains little on inputs this small (its benefit in
  cmix shows on inputs of tens of MB); it is off unless asked for.
- Memory: the budget of each level (`zcmDefaultMemoryMiB`: 32 MiB at
  level 1 up to 3 GiB at level 9) is capped at 64 bytes per input byte
  plus 8 MiB, so these files used 13 to 24 MiB of tables. Level 1 on a
  1.5 MB file with `-m 256` peaked at 84 MB resident.
- Independent segments (the four files as one 700 KB input, segments of
  192 KiB): level 3 grows from 352,372 to 356,886 bytes (1.3%) and runs
  at 308 KB/s on 4 isolates instead of 120 KB/s; level 6 grows from
  339,642 to 345,032 (1.6%) at 49 KB/s instead of 22 KB/s. Larger
  segments lose less.

## 2. Rules for keeping it fast

- The hot loops follow rule 3 of `docs/architecture.md`: typed lists,
  locals instead of fields, no closures, no boxing, masking only where C
  relies on 32 bit wraparound.
- No byte loops in `async` functions: locals that live across an `await`
  are kept in a heap context. Everything except `api.dart`, `zx_api.dart`,
  `zx_worker.dart`, `parallel.dart` and `pool.dart` is synchronous, and
  in those the loops over bytes are in synchronous functions (the handlers,
  the extract and update callbacks of `zx_worker.dart`).
- `ZxArchive`: the listing comes to the caller with `Isolate.exit` (no
  copy) and is not sent back to the workers (each reads the headers again,
  which is cheap), except for a compressed tar, whose headers are only
  known after decoding it all. Messages to the caller carry no per item
  data: progress at most every 100 ms, the questions one at a time.
- Progress crosses isolates at most every 100 ms; per block or per MB
  callbacks inside the codecs stay on the worker isolate.
- Blocks cross isolates as `TransferableTypedData`, and the parallel
  encoder keeps at most one block per worker plus one in flight, so
  memory is bounded by the number of workers, not by the input.
- The 7z extraction decodes each solid block once, in order, and writes
  through a 64 KB buffered `FileOutStream`.

## 3. Open items

- `ZxArchive` on a compressed tar (x.tar.gz...): each operation decodes
  the archive in one pass from the start (listing, extracting one file,
  reading the first bytes for a preview), and an update decodes the tar
  to a temporary file first. A cache of the decoded tar for a session
  would make previews of large archives faster.
- `ZxArchive` restores folder times with one `touch` process per folder;
  archives with many thousands of folders spend time there.
- Nested archives (`-snest`, `ZxArchive.open(flatten: true)`): the search
  reads 512 bytes of each file item (and 16 at 32 KiB when the item is
  that long) to compare signatures, so a large file system costs one
  small read per file (the D340W firmware: about 0.5 s for 1500 files).
  Each `ZxArchive` operation opens the nested archives again from the
  layout found at open (no second search); a flattened compressed tar is
  decoded to a temporary file per operation, and items of formats without
  random access (7z, rar) are copied once at open.

- 7z compression on several isolates (LZMA2 blocks inside a folder,
  independent folders), see section 6 of `docs/architecture.md`.
- Multi-block xz decoding in parallel.
- .zx: the block results cross isolates through files in a temporary
  folder (`sync_pool.dart`); on a slow disk a tmpfs `TMPDIR` avoids the
  write and read of each decoded block.
- Phones: not measured yet. On a phone keep the levels at 5 or below and
  `threads` at 4 or below.

## 4. The desktop app

- A folder of the list is computed from `ZxArchive.children` (built once
  per listing) and sorted on the UI isolate (not measured yet on folders
  with many thousands of items); the rows are built lazily (fixed height
  list). Folder sizes are summed in one pass over the listing, on first
  use.
- The preview reads at most 512 KiB (`readBytes(maxBytes:)`) after a
  180 ms pause in the selection and cancels the read (the isolate is
  killed) when the selection changes. On a compressed tar each read
  decodes the archive from the start (section 3).
- Opening a file with its program extracts only that file
  (`extractToTemp`); the temporary copies are deleted a day later, at the
  next start.
- Opening a file item first asks `ZxArchive.probeNested` (one isolate
  that opens the parent and reads the first 512 bytes of the item, plus
  16 at 32 KiB when it is that long); only a match opens the nested
  archive. On the D340W firmware (`dart run`, JIT, this
  machine): probe of a section 40 to 150 ms, `openNested('rootfs')` (UBI)
  90 ms, then its UBIFS volume 94 ms; the whole flattened pak (1883
  items) 358 ms. A nested level on a 7z or rar parent copies the item to
  a temporary file first (deleted when the level is left).

## 5. How to measure

```sh
dart compile exe tool/bench.dart -o /tmp/zxbench
ZX=/tmp/zxbench tool/benchmark.sh <data dir> [runs] [filter]
```

`tool/benchmark.sh` runs every case sequentially (run nothing else heavy
at the same time) in a temporary folder and prints wall time, CPU, MB/s,
peak RSS and output size, for this port and for `/usr/bin/7z` (`SZ=` to
use another). `tool/lzma_bench.dart` and `tool/ppmd_bench.dart` measure
the codecs alone, in memory. `tool/zcm_bench.dart` measures the zcm levels
(`-l 1,3,6`, `-m MiB`, `-seg BYTES`, `-par THREADS`,
`-lstm cells,layers,horizon`, `-nodec`); run memory-heavy levels inside
a cgroup (`systemd-run --user --scope -p MemoryMax=3G`).
