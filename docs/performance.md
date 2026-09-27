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

### LZMA against the SDK itself

The LZMA encoder is a port of LzmaEnc.c with the single thread match
finder. On the 38 MB tar, `LzmaUtil` of the SDK built with `-DZ7_ST`
(`gcc -O2`) and the port at the same (default) settings write identical
files (10,972,137 bytes): 5.2 s against 16.2 s. The SDK built with its
multithreaded match finder writes 10,972,339 bytes: LzFindMt.c can pick
different matches on large inputs, so 7-Zip's output at levels 5 to 9
with more than one thread is equally valid but not always identical to
the single thread output. On the small inputs of the tests it is.

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

## 5. How to measure

```sh
dart compile exe tool/bench.dart -o /tmp/zxbench
ZX=/tmp/zxbench tool/benchmark.sh <data dir> [runs] [filter]
```

`tool/benchmark.sh` runs every case sequentially (run nothing else heavy
at the same time) in a temporary folder and prints wall time, CPU, MB/s,
peak RSS and output size, for this port and for `/usr/bin/7z` (`SZ=` to
use another). `tool/lzma_bench.dart` and `tool/ppmd_bench.dart` measure
the codecs alone, in memory.
