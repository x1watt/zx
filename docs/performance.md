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
hashing run at about 115 MB/s, far above the LZMA2 workers.

### .zx, seals (signed generations)

AOT, 16 threads, this machine; 35.5 MB of Dart source and 40 MB of
random data (41.2 MB archive), each time the mean of 5 runs, without and
with `-msign` (docs/zx-format.md section 17):

| write | plain | signed | cost |
|---|---|---|---|
| `-mx5` (LZMA2) | 6.93 s | 6.96 s | +0.4% |
| `-mx0` (store) | 2.89 s | 3.01 s | +4.4% |

| read | time |
|---|---|
| open and list (the Seal is not read) | 0.01 s |
| `zx seal` (the quick check: Index hashes, signatures, chain, roles) | 0.01 s |
| `zx seal -full` (every stored byte, no password) | 0.33 s |

The block workers hash each payload right after coding it (the "core"
digest, in parallel); the writer's isolate hashes only the block headers,
the last 32 bytes of each payload and the small blocks it writes itself
(inline records, the Index): about 4.5 KB of a 1.2 MB archive in a test
with one 35 MB file. SHA-256 runs at about 130 MB/s per isolate here
(BLAKE2sp, measured for the choice, at 107 MB/s), so the cost shows only
when the coder is faster than the hash, as with store. A BIP-340
signature takes 2.3 ms and a verification 1.6 ms (pure Dart on BigInt,
with a table for the generator). The full check is one sequential
SHA-256 pass over the file. An archive that is not sealed writes and
reads exactly as before.

### .zx, the chunk index at scale

`tool/zx_dedup_scale.dart` (AOT, one process per case, under
`systemd-run --user --scope -p MemoryMax=3G -p MemorySwapMax=0`) simulates
the chunks of a large archive without writing its data: 1,638,400 chunks
(100 GiB of unique data at 64 KiB) with synthetic SHA-256 values.

| | zx 0.5.0 (chunk table, 0x34) | chunk runs (0x36) |
|---|---|---|
| per Index | 58 MB (every generation) | 17 bytes (record 0x36; the whole Index of the test: 415 bytes) |
| on disk | in every Index | 77 MB (49.5 bytes a chunk), once and at merges |
| writer memory, last generation | +157 MB for the index alone (100 bytes a chunk), 255 MB resident after opening | 2.4 MB kept (1.5 bytes a chunk), 13 MB resident after opening |
| append of 64 MiB of new data, peak | 431 MB | 123 MB (64 MiB of it the tool's input) |
| append time | 3.1 s | 1.5 s |
| 200,000 lookups of stored chunks | 49 ms (memory) | 1.7 s, one 3 KiB page read each |
| 200,000 lookups of new chunks | | 31 ms (0.8% of pages read, the Bloom filter) |

The append rows are a real append (`prepare` then `append`, stored
data, one thread) to an archive whose last Index knows the 1.6 M chunks:
the zx 0.5.0 row is the writer of the previous release (git HEAD before
the change) on its chunk table; the new writer on that same archive peaks
at 319 MB once (it loads the table and writes it as a run), then at 78 MB.
At 16.8 M chunks (1 TiB): the run is 792 MB, opened in 36 ms with 25 MB
kept; the index of zx 0.5.0 alone takes 1.47 GB, and building its chunk
table in the same process passes 3 GB (the process is killed). Merging two
runs of 819,200 records takes 0.66 s (8.4 M: 9.6 s), streamed page by
page (+11 MB resident).

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

`tool/zcm_bench.dart` compiled AOT (`dart compile exe`), in memory (no
isolate), one process per level (peak RSS is the process maximum), on two
corpora. The small one: `text.md` (96,530 bytes of English prose),
`source.dart` (200,000 bytes of Dart), `x86.bin` (142,312 bytes, an
x86-64 ELF executable) and `kernel.bin` (262,144 bytes of an ARM zImage,
mostly already compressed). The large one, in `ref/zcm-corpus` (not in
git; see below): `book.txt` (Pride and Prejudice, Project Gutenberg),
`source.cpp` (the first 837,756 bytes of paq8px's sources), `x86_64.elf`
(/usr/bin/gpg), `firmware.bin` (1 MiB of a router firmware image),
`photo.ppm` and `photo.bmp` (640x480 and 512x384 24-bit photos),
`gray.pgm` (640x480 gray), `music.wav` (6 s of synthesized 16-bit stereo
music with reverb) and `voice8.wav` (3 s of 8-bit mono noise). Sizes in
bytes, stream version 2; every round trip was checked (levels 7 to 9 of
the large corpus were encoded only; decoding runs at the same speed).
KB/s is input KB per second of wall time; up to four levels ran at the
same time on the 16 core machine, so the speeds are 10 to 20% below a
quiet machine (alone: level 1 1,278 KB/s, level 3 209 KB/s, level 5 89
KB/s on the small corpus).

Small corpus, zcm 1.0 (stream version 1), 2026-09-28, second run:
every table counted in the budget, the quick gain check on PPMd and DMC,
the similarity model pair at level 9, paq8px's input boost of the x86
model and cmix's byte mixer with the LSTM. One process per level, capped
at 3 GiB, encode only (round trips in test/zcm_test.dart); another
agent's benchmark ran beside it, so the speeds are about 10% low (level
3 alone the same morning: 206 KB/s, level 1 1,238 KB/s). x86.bin was
measured again after the x86 boost (the other files do not change):

| Level | text.md | source.dart | x86.bin | kernel.bin | total | enc KB/s | peak RSS MiB |
|---|---|---|---|---|---|---|---|
| 1 | 26,632 | 36,163 | 52,805 | 250,952 | 366,552 | 1,068 | 40 |
| 2 | 25,291 | 32,400 | 48,676 | 249,474 | 355,841 | 257 | 35 |
| 3 | 24,730 | 30,923 | 45,767 | 249,515 | 350,935 | 181 | 27 |
| 4 | 24,295 | 29,810 | 39,254 | 248,646 | 342,005 | 86 | 28 |
| 5 | 24,105 | 29,138 | 39,212 | 248,392 | 340,847 | 75 | 34 |
| 6 | 23,330 | 27,598 | 37,495 | 248,676 | 337,099 | 24 | 93 |
| 7 | 22,554 | 25,886 | 36,682 | 248,247 | 333,369 | 10 | 166 |
| 8 | 22,339 | 25,386 | 36,303 | 247,999 | 332,027 | 5 | 397 |
| 9 | 22,325 | 25,366 | 35,877 | 247,687 | 331,255 | 4 | 404 |
| 9, cmix preset (LSTM 64/1/20 as byte mixer) | 22,270 | 25,274 | 35,870 (before the boost) | 247,662 | 331,076 | 2 | 416 |
| paq8px v216 -8 | 23,481 | 25,611 | 34,961 | 246,748 | 330,801 | 3.5 to 7 | 1,800 to 2,300 |

Against paq8px -8: text.md -4.9%, source.dart -1.0% (-1.3% with the
cmix preset), x86.bin +2.6%, kernel.bin +0.4%. On the large corpus at
level 9 (same build before the x86 boost, alone except for one other
benchmark): source.cpp 84,685 bytes (paq8px -8 85,093: -0.5%, it was
+4% for stream version 2), x86_64.elf 280,199 (272,823: +2.7%), 3 to 4
KB/s, 1,781 MiB peak RSS (2 KiB of tables per input byte).

- Level 3 speed: the detector (text, x86 and binary per 64 KiB block,
  the media headers, the raw image test on binary blocks) takes 1 to 3
  ms per file of the small corpus (`zcmDetectSegments`, JIT), under 0.1%
  of the level 3 time; level 3 runs at 206 KB/s alone (181 KB/s with
  another benchmark beside it), so nothing was changed there.
- paq8px's input boost of the x86 model (ExeModel `setScale(128)` on exe
  blocks; zcm's `X86Model.scale`): on the first 128 KiB of x86.bin, 64
  (none), 80, 96, 112, 128: level 8 35,298, 35,230, 35,194, 35,186,
  35,205; level 5 38,038, 37,839 (96), 37,795 (112), 37,775 (128); level
  4 38,122 to 37,818 (128). zcm uses 128 like paq8px: x86.bin -0.8% at
  level 4, -0.5% at 6, -0.2% at 9.
- Measured and not used (level 8, x86.bin and kernel.bin, 284,396
  bytes): the x86 model on binary blocks too (paq8px runs its ExeModel
  on every block and lets it find code itself; `-x exeall`) 284,641
  (+0.09%, kernel.bin +0.1%), paq8px's text model on binary blocks
  (`-x txbin`) 284,992 (+0.2%). A larger memory budget does not change
  the first 128 KiB of x86.bin (the budget is capped by the input size).

Measured for zcm 1.0 (the memory budget of today, level 8 on x86.bin
and kernel.bin, 284,396 bytes without them):

- paq8px's similarity model pair (2,048 byte window): 283,680 (-0.25%),
  6 to 4 KB/s. Level 9 uses it on binary and x86 data.
- Sparse bit model 284,306 (-0.03%), linear prediction 284,341
  (-0.02%), sparse match 284,468 (+0.03%): no level uses them.
- The quick gain check (`ZcmGainGate`, zcm_components.dart): PPMd and
  DMC give their inputs to the mixer only while their own prediction
  saves more than about 1/32 bit per bit over the last 4,096 bits. Level
  9 was 29 bytes above level 8 without it (kernel.bin, compressed data,
  248,107 against 247,999); with it every file of level 9 is below level
  8 (kernel.bin 247,990 before the similarity model).
- The LSTM at level 9 on the first 32 KiB of text.md: without 8,717
  bytes at 5 KB/s, small (64/1/20) 8,721 at 3 KB/s, cmix's large
  (200/2/100) 8,721 at 1 KB/s. On inputs of this size the LSTM does not
  pay, so the cmix preset keeps the small network; the large one stays
  an explicit choice (`lstm=large`).
- cmix's byte mixer (mixer/byte-mixer.cpp, `ByteMixerModel` in
  zcm_byte_models.dart): an LSTM whose inputs are the previous byte and
  the byte distribution of PPMd (times 16; cmix's factor 2 was 0.1%
  worse), its own byte distribution turned into bit inputs like the other
  byte models. On the first 32 KiB of text.md and source.dart at level 9
  (64 cells, 1 layer, horizon 20): without an LSTM 14,265 bytes at 4
  KB/s, the plain LSTM 14,273 at 3 KB/s, the plain LSTM and the byte
  mixer 14,261, the byte mixer alone 14,238 (-0.19%) at 2 KB/s; with 32
  cells and no option 14,250 (-0.1%) at 3 KB/s. With the lstm option at
  level 9 (the cmix preset) the LSTM is now the byte mixer; plain level 9
  does not use it (-0.1% for a quarter of the speed).
- cmix's FXCM model (fxcmv1.cpp, 4,910 lines) was read but not ported:
  it is the whole fx-cmix enwik predictor (its own mixers, APMs, context
  maps, the enwik dictionary decoder with its codeword streams 2b/3b/4b,
  the wiki table and template column contexts, an English stemmer),
  and it takes the final probability of cmix's LSTM byte mixer as an
  input. Most of what is not tied to enwik (bracket, column and
  indentation contexts, the stemmer, word classes) is already in zcm
  through paq8px's text and word models (zcm_text.dart,
  zcm_words.dart, the word model of zcm_models.dart).

Small corpus, build of 2026-09-27 (one process per level, alone on the
machine, capped at 3 GiB, encode only; the round trips are checked by
test/zcm_test.dart):

| Level | text.md | source.dart | x86.bin | kernel.bin | total | enc KB/s | peak RSS MiB |
|---|---|---|---|---|---|---|---|
| 1 | 26,632 | 36,163 | 52,805 | 250,952 | 366,552 | 1,228 | 40 |
| 2 | 25,291 | 32,400 | 48,676 | 249,474 | 355,841 | 303 | 34 |
| 3 | 24,730 | 30,923 | 45,767 | 249,515 | 350,935 | 202 | 26 |
| 4 | 24,353 | 29,810 | 39,558 | 248,646 | 342,367 | 95 | 28 |
| 5 | 24,202 | 29,138 | 39,474 | 248,392 | 341,206 | 85 | 34 |
| 6 | 23,330 | 27,598 | 37,686 | 248,676 | 337,290 | 24 | 93 |
| 7 | 22,554 | 25,886 | 36,843 | 248,232 | 333,515 | 10 | 166 |
| 8 | 22,339 | 25,386 | 36,379 | 247,999 | 332,103 | 6 | 437 |
| 9 | 22,325 | 25,366 | 36,341 | 248,107 | 332,139 | 6 | 403 |
| paq8px v216 -8 | 23,481 | 25,611 | 34,961 | 246,748 | 330,801 | 3.5 to 7 | 1,800 to 2,300 |

Steps of version 3, measured at level 7 on the small corpus (text.md,
source.dart, x86.bin, kernel.bin) and on the first 300,000 bytes of
book.txt without the dictionary (book300):

- The memory of small inputs: the budget was 64 bytes per input byte
  plus 8 MiB at every level, so a 200 KB file at level 7 had about 7 MiB
  for all its context maps (a hundred contexts, three bucket lookups per
  byte each) and they thrashed. With 1 KiB per input byte at level 7:
  text.md 23,110 to 22,581 (-2.3%), source.dart 27,107 to 25,998
  (-4.1%), x86.bin 38,004 to 36,986 (-2.7%), kernel.bin unchanged; 4 KiB
  per byte gains another 0.3% at twice the memory. Levels 2 to 5 do not
  gain (few contexts), level 6 gains 0.5% with 256 bytes per byte.
  `zcmTableBytesPerInputByte` is 64 (levels 1 to 5), 256 (6), 1 KiB
  (7) and 2 KiB (8, 9).
- paq8px's match model (four candidates, recovery after a one byte
  mismatch, minimum lengths 4/6/8 for text and binary, 3/5/8 for x86):
  text.md -0.1%, source.dart -0.4%, book300 -0.2%, x86.bin -0.6%,
  about 10% slower. At levels 3 and 5 it gains 0.8% and 0.3% but costs
  40% and 25% of the speed (below the targets): only levels 7 to 9 use
  it.
- paq8px's text model with its English stemmer (28 contexts with run
  and byte history inputs, ten mixer weight sets, its state in the text
  SSE chain): text.md -0.8%, source.dart -1.7%, book300 -1.3%, but half
  the speed; levels 8 and 9 use it. With the old memory budget it gained
  nothing (0.1%): the new contexts only diluted the starved maps.
- Level 9 was 36 bytes above level 8 in total: kernel.bin (compressed
  data) lost 0.04% with PPMd and DMC while the other files gained (fixed
  in zcm 1.0 by the quick gain check, above).
- Ported and measured, not used by any level (gains below 0.3% on these
  files for their cost): paq8px's sparse bit model (-0.05%), linear
  prediction (-0.02%), sparse match (+0.07%) and the similarity model
  pair with a 2,048 byte window (-0.26%, 2.4 times slower), all on
  x86.bin, kernel.bin and 256 KiB of firmware.bin.

Small corpus, stream version 2 (before the steps above):

| Level | text.md | source.dart | x86.bin | kernel.bin | total | enc KB/s | dec KB/s | peak RSS MiB |
|---|---|---|---|---|---|---|---|---|
| 1 | 26,632 | 36,163 | 52,805 | 250,952 | 366,552 | 1,091 | 1,138 | 38 |
| 2 | 25,291 | 32,400 | 48,676 | 249,474 | 355,841 | 266 | 269 | 37 |
| 3 | 24,730 | 30,923 | 45,767 | 249,515 | 350,935 | 179 | 180 | 34 |
| 4 | 24,353 | 29,810 | 39,558 | 248,646 | 342,367 | 90 | 89 | 34 |
| 5 | 24,202 | 29,138 | 39,474 | 248,392 | 341,206 | 82 | 82 | 36 |
| 6 | 23,569 | 28,224 | 38,430 | 248,675 | 338,898 | 29 | 29 | 85 |
| 7 | 23,110 | 27,107 | 38,004 | 248,123 | 336,344 | 12 | 12 | 116 |
| 8 | 23,110 | 27,113 | 37,541 | 247,850 | 335,614 | 8 | 8 | 180 |
| 9 | 23,110 | 26,676 | 37,192 | 247,896 | 334,874 | 8 | 8 | 187 |
| zx 0.5 (version 1) level 3 | 26,248 | 31,469 | 45,572 | 249,281 | 352,570 | 122 | | |
| zx 0.5 (version 1) level 5 | 26,110 | 30,186 | 39,269 | 247,942 | 343,507 | 39 | | |
| zx 0.5 (version 1) level 9 | 25,784 | 29,457 | 38,399 | 247,532 | 341,172 | 11 | | |
| xz -9e | 33,440 | 43,268 | 54,520 | 250,012 | 381,240 | | | |
| 7z PPMd -mx9 (archive) | 29,544 | 40,193 | 56,140 | 258,556 | 384,433 | | | |
| zpaq method 5 (`lib/src/zpaq`) | 27,071 | 33,169 | 48,341 | 248,579 | 357,160 | | | |
| paq8px v216 -5 | 23,494 | 25,686 | 35,029 | 246,744 | 330,953 | 4 to 7.5 | | 600 to 900 |
| paq8px v216 -8 | 23,481 | 25,611 | 34,961 | 246,748 | 330,801 | 3.5 to 7 | | 1,800 to 2,300 |

Large corpus (6,758,876 bytes), stream version 2 (not measured again
for version 3 yet):

| Level | book.txt | source.cpp | x86_64.elf | firmware.bin | photo.ppm | photo.bmp | gray.pgm | music.wav | voice8.wav | total | enc KB/s | peak RSS MiB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 166,577 | 124,764 | 423,438 | 581,076 | 174,186 | 216,372 | 51,242 | 806,642 | 17,377 | 2,561,674 | 1,141 | 53 |
| 2 | 158,892 | 112,611 | 386,164 | 563,185 | 154,995 | 190,727 | 48,307 | 651,110 | 16,846 | 2,282,837 | 261 | 62 |
| 3 | 155,524 | 106,330 | 364,087 | 563,028 | 104,885 | 141,775 | 34,028 | 411,593 | 15,617 | 1,896,867 | 121 | 62 |
| 4 | 153,840 | 102,018 | 308,929 | 548,147 | 104,882 | 139,445 | 34,025 | 411,693 | 15,617 | 1,818,596 | 85 | 66 |
| 5 | 153,022 | 99,012 | 308,155 | 546,483 | 104,448 | 139,230 | 33,872 | 410,820 | 15,651 | 1,810,693 | 83 | 74 |
| 6 | 151,255 | 93,271 | 296,357 | 535,823 | 96,466 | 139,943 | 31,295 | 380,542 | 15,483 | 1,740,435 | 21 | 125 |
| 7 | 150,136 | 88,949 | 296,160 | 533,537 | 95,020 | 136,866 | 30,699 | 379,679 | 15,424 | 1,726,470 | 11 | 118 |
| 8 | 150,139 | 88,966 | 291,832 | 529,940 | 95,017 | 136,646 | 30,701 | 379,686 | 15,424 | 1,718,351 | 9 | 143 |
| 9 | 148,830 | 88,714 | 289,481 | 527,057 | 95,018 | 136,644 | 30,701 | 379,683 | 15,424 | 1,711,552 | 9 | 144 |
| xz -9e | 223,640 | 146,500 | 478,896 | 558,976 | 176,456 | 241,872 | 56,364 | 668,704 | 22,480 | 2,573,888 | | |
| 7z PPMd -mx9 (archive) | 180,645 | 141,442 | 410,356 | 609,164 | 193,652 | 264,029 | 55,477 | 679,210 | 17,484 | 2,551,459 | | |
| zpaq method 5 | 168,047 | 114,223 | 394,031 | 550,662 | 126,384 | 169,226 | 48,569 | 608,116 | 16,788 | 2,196,046 | | |
| paq8px v216 -5 | 150,410 | 85,705 | 275,804 | 497,312 | 84,996 | 122,544 | 26,887 | 344,154 | 14,919 | 1,602,731 | 3 to 13 | 600 to 1,160 |
| paq8px v216 -8 | 149,803 | 85,093 | 272,823 | | | | | | | | 3 to 8 | 2,000 to 2,400 |

paq8px was built from `ref/paq8px` with `clang++ -O3 -march=native` and
run under `systemd-run --user --scope -p MemoryMax=3G` (its -5 uses about
0.6 to 1.2 GB, -8 about 2 to 2.4 GB here, so -8 ran only on three files
of the large corpus; -9 and up need 4 to 29 GB). cmix v21 needs about 30
GB and was not run on this 16 GB machine. The large corpus is made by:
`curl` of `https://www.gutenberg.org/cache/epub/1342/pg1342.txt`;
`cat` of `ref/paq8px/src/{,model/,text/}*.{cpp,hpp}` sorted (837,756
bytes); ImageMagick `convert` of
`/usr/share/backgrounds` photos (`-resize 640x480!`, `BMP3:` for the
BMP, `-colorspace Gray` for the PGM); `sox` synth plucks mixed with sine
pads, reverb and a stereo remix for `music.wav`, band passed pink noise
with tremolo for `voice8.wav`; `dd` of 1 MiB at 20 MiB of the D340W
firmware.

Findings:

- Speed targets: level 1 is one class without model objects (1.1 to 1.3
  MB/s, from 0.6); level 3 (orders 2, 3, 4, 6, a 5 context word model, 5
  exe contexts, 3 mixer weight sets) 180 to 210 KB/s from 122; level 5
  (plus sparse contexts, a 16 context word model and the x86 parser) 82
  to 89 KB/s from 39; every level is smaller than zx 0.5's same level on
  the small corpus in total. Most of the speed came from
  `vm:unsafe:no-bounds-checks` on the hot functions (about 20%), from
  fewer contexts where they did not pay (at level 5 the orders 5 and 8
  and the indirect model cost 30% of the time for 0.1% of the size), and
  from fewer mixer weight sets.
- The English dictionary transform (cmix) is the largest single gain on
  text: text.md 25,791 to 23,711 at level 6 (8%), source.dart 3.7%
  (identifiers and comments are English words). It is applied when at
  least half of the words of a segment are in the dictionary, and only
  when the inverse gives the segment back exactly.
- Level 7 to 9 against paq8px -8: text.md 1.6% smaller (with the
  dictionary transform; paq8px does not use one by default), book.txt
  0.7% smaller at level 9; source.dart 4% and source.cpp 4% larger,
  x86 6% (x86.bin, x86_64.elf), firmware 6%, images 12 to 14%, audio 3
  to 10%. The large corpus total is 6.8% above paq8px -5 at level 9 (it
  was more than 40% above before the image and audio models: level 3
  generic contexts give 2,251,488 against 1,896,867 now).
- The steps measured on text.md and source.dart at level 7 (small
  corpus): the paq8px word model -0.6% and -2.2%; the paq8px SSE chain
  with APMPost -0.3%; the final mixer layer learning rate lowered from
  56..14 to 8..2 (16.16) -1.9% on both; paq8px's order 0 and 1 slow and
  fast maps -0.1 to -0.2%; at level 9 PPMd memory taken beside the
  budget instead of from the context maps, and DMC, -1.6% on source.dart.
  The 16 bit final probabilities were neutral on these files.
- Image models: photo.ppm 154,597 at level 3 with generic contexts to
  95,020 at level 7 (-39%), photo.bmp 190,185 to 136,866 (-28%),
  gray.pgm 48,452 to 30,699 (-37%). Residual histograms with the
  per-predictor error of the neighbors (paq8px ResidualMap) and a
  quarter of the budget for them gave the largest steps; two least
  squares fits 5 to 6%; more predictors from paq8px's list made these
  small images worse (more mixer inputs than data).
- Audio: music.wav 662,983 with generic contexts to 379,679 at level 7
  (-43%), voice8.wav -8.5%. The mixer weight sets selected by the recent
  residual sizes matter most: with one set instead of three the light
  model loses 7%.
- Media against paq8px v216 -8 (level 7, stream version 1): photo.ppm
  94,454 / 85,039 (+11.1%), photo.bmp 136,032 / 122,539 (+11.0%),
  gray.pgm 30,494 / 26,887 (+13.4%), music.wav 378,850 / 343,808
  (+10.2%), voice8.wav 15,360 / 14,920 (+2.9%). paq8px's six image fits
  (32 to 8 pixels, forgetting 0.7 to 0.98, solved every byte) instead of
  zcm's two: +0.7% on the first half of photo.bmp, neutral on gray.pgm;
  beside them +0.2%, so zcm keeps its two. paq8px Audio16BitModel's fit
  and LMS set (eight fits of 28 to 128 samples, LMS of 1920, 704 and
  2458 taps): -1.1% on the first 256 KiB of music.wav, +0.9% on
  voice8.wav, at half the speed (replaced by the port below).
- paq8px's audio models ported faithfully (`zcm_audio_px.dart`: the
  exact sparse tap patterns of the eight fits per channel, the LMS rates,
  the second prediction plus the other channel's last residual, the
  residual maps of 8-bit audio with the coding loss contexts, the five
  mixer selectors and the audio SSE stage), level 7, 2026-09-28:
  music.wav 378,850 to 349,067 (+1.5% against paq8px -8), voice8.wav
  15,360 to 14,998 (+0.5%). Then, on the first 256 KiB of music.wav
  (paq8px -8 86,955) and voice8.wav: without the order-n contexts on
  audio 88,318 to 88,106 and faster (paq8px uses only its order model's
  one selector there too); one predictor selector instead of ten neutral
  (-18) and faster; a weight set and an APM in the residual of the
  predictor with the smallest recent errors -0.17%; the final mixer layer
  by the bit of the sample (16 sets) -0.11%; the APM side of the SSE
  stage weighed 7/8 instead of 1/2 -0.19%. Neutral or worse: other mixer
  learning rates (24, 40, 72, 96), input scales 1/2 to 2, a third APM,
  the final layer also by the error size, an 8 bit residual selector.
  Result (levels 7 to 9 alike): music.wav 347,111 against 343,808
  (+0.96%), voice8.wav 14,971 against 14,920 (+0.34%), 11 KB/s on
  music.wav and 8 KB/s on voice8.wav (paq8px -8 about 21 KB/s on
  music.wav); level 7 was 12 KB/s before with 378,850, level 8 5 KB/s.
  The fits' covariance update and Cholesky factorization in Float64x2
  gained about 10% of the speed; the LMS steps use a two step Newton
  reciprocal square root from a bit pattern (no dart:math).
- paq8px's image models as whole models (`zcm_image_px.dart`, levels 7
  to 9, 2026-09-28): Image24BitModel (122 predictors through three
  residual maps, six least squares fits, 31 hashed and 40 bit contexts,
  20 mixer selectors, a mixer per color plane) and the gray part of
  Image8BitModel, with their SSE stages and only the order and match
  selectors of the predictor. Level 7 against paq8px v216 -8: photo.ppm
  85,422 / 85,039 (+0.45%, was +11.1%), photo.bmp 126,768 / 122,539
  (+3.45%, was +11.0%), gray.pgm 26,901 / 26,887 (+0.05%, was +13.4%).
  The earlier finding that more predictors lose held only for zcm's
  generic mixer selectors: with paq8px's selectors and SSE the whole set
  pays. Speed 2 to 3 KB/s on color images and 7 KB/s on gray (was 9 to
  12; paq8px -8 about 9 KB/s), peak RSS 589 MiB. Negative results: a
  slower first mixer layer (20 to 6 instead of 56 to 14) -1.2 to -2.2% on
  the first 100 to 128 rows but -0.1% (photo.bmp) and +0.45% (photo.ppm)
  on the whole files; the final layer rate 3 to 1 or 20 to 4 +0.4 to
  +0.8%; four times the context map and bit map memory, and paq8px's run
  map with byte history inputs in the context map, neutral. The residual
  maps, fits and SSE tables are fixed (about 25 MiB for color, 8 MiB for
  gray) and can exceed the quarter of the budget for small images.
- paq8px's chart, nest and XML models were ported (`zcm_words.dart`) but
  are not used by any level: on these files they cost 0.1 to 0.7% (more
  inputs than the data can train), the orders 16 and 24 likewise.
- Memory: the budget of each level (`zcmDefaultMemoryMiB`) is capped at
  64 bytes per input byte plus 8 MiB; the image and audio models may add
  a quarter each, and PPMd at level 9 a quarter. Peak RSS stays below 190
  MiB on these inputs.

### zxdb (the database in a .zx archive)

`tool/zxdb_bench.dart` (AOT, `durable: false`, 16 KiB pages, 128 MiB page
cache, values of about 150 bytes of JSON); the table with the SQLite
comparison and the TLSH band index is in docs/zxdb-design.md section 11.3.

| Operation | Result |
|---|---|
| KV get, 10k / 100k hot keys spread over 1M | 1.4 / 2.8 us |
| KV get, cold (caches dropped) | 133 us |
| KV put, batches of 10k, ascending | 315k puts/s (was 267k) |
| KV put, 1M random keys from empty, batches of 10k | 100k puts/s, 116 MiB file (was 10.8k, 1.3 GB) |
| KV put, 500k random keys into a 1M tree, batches of 10k | 161k puts/s (128 MiB page cache), file +28 MiB; the fold after them 5.3 s |
| full scan of 1.24M entries (with delta runs) | 0.96 s (1.3M entries/s) |
| KV put autocommit, durable false / true | 0.89 ms / 7.5 ms a commit (was 9 ms / 15 ms) |
| KV put with group commit (2 ms), durable false / true | 170k / 34k puts/s |
| size, 20k JSON records (2.4 MiB): sqlite3 / fast / balanced / max | 2,680 / 638 / 272 / 158 KiB |
| LZ4 encode (single probe, text) / decode | about 100 MB/s / 6.7 GB/s |

SQL against sqlite3 3.45.1 (the `sqlite3` tool reading a script, so its
times include parsing each statement; `synchronous=OFF`), 100k rows
`(id INTEGER PRIMARY KEY, v TEXT)` of JSON, transactions of 10k:

| | zxdb (fast) | sqlite3 |
|---|---|---|
| insert, sequential ids | 178k rows/s | 367k rows/s |
| insert, random ids | 82k rows/s | 136k rows/s |
| select by id (prepared) | 5.0 / 5.6 us | 11.9 / 12.1 us (CLI) |
| scan, count(*) and sum(length(v)), warm | 46 / 59 ms (was 86 / 98) | 26 ms |
| autocommit insert (each a commit) | 1.0 / 1.1 ms | 85 us (synchronous=OFF), 16 ms (FULL) |
| file | 3,329 / 3,770 KiB | 12,288 / 12,680 KiB |

Sizes and reads per compression level (SQL tables, 20k rows, after fold
and vacuum; cold: the first select of a freshly opened archive, which
decodes one page block; hot: select by id in the page cache):

| Dataset (text size) | sqlite3 | store | fast | balanced | max |
|---|---|---|---|---|---|
| JSON records (2,327 KiB) | 2,444 KiB | 2,364 | 642 (3.6x) | 285 (8.2x) | 162 (14.3x) |
| text rows (5,945 KiB) | 6,316 KiB | 6,008 | 2,856 (2.1x) | 1,174 (5.1x) | 762 (7.8x) |
| numeric rows (538 KiB) | 496 KiB | 476 | 309 (1.7x) | 153 (3.5x) | 93 (5.8x) |
| first read cold | | 13 to 17 ms | 13 to 16 ms | 18 to 31 ms | 1.7 to 4.5 s |
| read hot | | 4.6 to 4.9 us | 4.6 to 4.9 us | 4.8 to 5.0 us | 4.5 to 5.0 us |

- A `max` tree pays its cold zcm decode once per 256 KiB block; the page
  and block caches keep it (hot reads are the same at every level).
- Random writes into a large tree go through the delta layer (sorted
  runs, docs/zxdb-design.md 11.2). A put checks whether its key exists
  (exact entry count): with the base in the page cache that is about
  Puts are blind (no read of the key; the entry count is settled when
  asked or at the fold). Reading the key to keep the count exact at each
  put gave 27k puts/s into a 1M tree with the default 128 MiB page cache
  (the base did not fit: a cold page read a put), 85k with 512 MiB.
- Runs are merged when 8 of a size class exist (4: 125k puts/s, more
  rewrites).
- SQL scans: a scanned row is decoded on first use (`LazyRow`), so
  count(*) does not decode records (24 to 11 ms for 100k rows, the
  tree scan alone is 4.4 ms); `length()` counts code units in one pass
  instead of `String.runes` (sum(length(v)) 62 to 40 ms). The rest is
  the record decode (11 ms, mostly UTF-8) and the expression evaluation.
- The earlier table said 1.1 ms per 1000 autocommit inserts: a unit
  error (seconds printed as ms); each insert is a commit of 1 ms.
- The writer lock wrote its marker with an fsync: 6 ms a transaction.
  Removed (the marker only names the process; an empty one is stale
  after 10 s).

- A cold read decodes the whole page block of the page (64 KiB at commit,
  256 KiB after a fold) and checks it (xxHash64): about 60 us for LZ4
  blocks, seconds for zcm blocks.
- Sequential loads split the right edge page 7/8 to 1/8, so appended
  pages are full (random loads leave pages about 70% full).
- The page cache keeps pages flat (keys and values in two buffers):
  before that, one object per key and value made 100k hot keys of 1M cost
  50 us a get (the working set did not fit).

### zxdb time series

`tool/zxdb_bench_ts.dart` (AOT, `durable: false`, 4 seal workers, the
machine shared with other work), docs/zxdb-design.md section 12.
Synthetic web/server log: 1M lines, 146.5 MiB of text over 5.8 days
(zstd -19: 17.38 MiB, xz -9: 16.77 MiB, sqlite3 with an index on ts:
153.9 MiB). Scan speeds are MB/s of the raw text the rows stand for.

| Compression | Append (batches of 100k) | Seal | Archive | vs sqlite3 | Scan all cols cold / one day warm | ts + numbers cold |
|---|---|---|---|---|---|---|
| fast | 480k rows/s | 4.5 s | 31.7 MiB | 4.9x smaller | 143 / 875 MB/s | 724 MB/s |
| balanced | 520k rows/s | 11.5 s | 21.8 MiB | 7.1x smaller | 107 / 617 MB/s | 637 MB/s |
| max (zcm) | 531k rows/s | 267 s | 17.8 MiB | 8.6x smaller | minutes (zcm decode) | fast |

Real logs, `journalctl -o json -n 200000` (every field kept; JSON export
198 MiB, zstd -19 14.1 MiB, xz -9 14.5 MiB, sqlite3 148.9 MiB): fast
19.9 MiB, balanced 7.9 MiB (1.8x smaller than zstd -19 of the JSON,
18.8x smaller than sqlite3), append 140k rows/s (about 1 KB of fields
per row). The max run did not finish in the time given (a cold scan of
zcm text runs at zcm's decode speed).

- The column split beats xz on the journal (repeated field names and
  values become dictionaries) but not on the synthetic access log, whose
  text is one free column (max: 0.94 of xz's size ratio).
- A full warm scan of 1M rows exceeds the decoded column cache (256 MiB)
  and runs at cold speed; a day fits (875 MB/s).
- The hot tier (`--hot 1`, 200k lines, 29.3 MiB of text over 1.2 days,
  max): a cold read of the last day, all columns, 0.16 MB/s without it,
  156 MB/s with it; the LZ4 copy takes 3.5 MiB beside 3.6 MiB of max
  segments (docs/zxdb-design.md 12.3). Seal of max: 117 s for 200k lines.
- The buffer blocks stay under 16 KiB so the tree keeps them inline: as
  overflow values each was hashed (SHA-256) for deduplication at put.

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
- Seals (signed generations): payloads are hashed by the block workers
  that code them, never again on the writer's isolate (the "core"
  digest of zx_seal.dart travels with the coded block); opening an
  archive does not read its Seal, and the quick check hashes only the
  Indexes.
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
`-lstm cells,layers,horizon`, `-nodec`, `-nodict`, `-nodetect`; it prints
the peak RSS of the process); run memory-heavy levels inside a cgroup
(`systemd-run --user --scope -p MemoryMax=3G -p MemorySwapMax=0`).

## 6. The web version

Measured with `tool/web_check/run_e2e.sh` (headless Chromium, the engine
and the server on this machine), docs/architecture.md section 20.

- The engine is 2.1 MB of WebAssembly (`dart compile wasm -O2`), 0.8 MB
  gzipped, loaded once by the worker; the UI is Flutter's own build.
- Remote archives: a .zx of 6.36 MB (300 incompressible files in solid
  blocks) is listed with 2 range requests and 594 KB (the pinned head of
  64 KiB and tail of 128 KiB, in 256 KiB blocks); reading one file
  fetches its block (here the rest of the file, in one request: the
  blocks are large), and extracting all 300 files then needs no other
  request. Runs of missing blocks are fetched in one request, and the
  readahead doubles on sequential reads up to 4 MiB, so a long read is a
  few large requests, not one per block. The block cache of a URL holds
  64 MiB (least recently used), with the head and tail pinned.
- Uploaded files are read in 1 MiB blocks with `FileReaderSync` (8 MiB of
  cache per file): nothing is copied whole, so a file of several GB opens
  like a small one.
- On the UI thread: the JSON parse of a listing (the browser's
  JSON.parse) and the `ZxItem` objects made from it, and the check of a
  README's links. The README parse runs in the engine. Not measured yet
  on listings of 100,000 items.
- Not measured yet: the engine's codec speed against the native AOT
  build. The engine is single threaded (no SharedArrayBuffer on GitHub
  Pages), so .zx blocks decode one at a time.
- `readBytes` of a whole file (Download) holds the file in the engine's
  memory and once more as a Blob: a download is bounded by the memory of
  the tab.

