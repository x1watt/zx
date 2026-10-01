# zx

**One archiver for everything, in pure Dart.** zx reads and writes 7z,
zip, rar, tar, gz, bz2, xz, zpaq, arj, lzh and its own `.zx` format, opens
disc images, disk images and device firmware down to their files, ships a
SQL database inside every archive, and compresses with context mixing
models that land within a few percent of paq8px, from a command line that
speaks 7-Zip's language.

No native code, no FFI, no plugins: it runs wherever Dart runs (Linux,
Windows, macOS, Android, iOS), as a library, a command line tool (`zx`)
and a file explorer app.

Version 0.5.0. BSD 3-clause, Copyright (c) 2026 Max Brito.

---

## Highlights

- **7-Zip, ported.** The public domain LZMA SDK (7z, xz, lzma, LZMA,
  LZMA2, PPMd, BCJ2, AES-256) is ported function by function: at the same
  settings the encoders write **the same bytes as 7-Zip**, and the command
  line takes 7-Zip's commands and switches.
- **Every common format.** zip/jar (Deflate, Deflate64, BZip2, LZMA,
  PPMd, ZipCrypto, WinZip AES, Zip64), RAR 1.5 to RAR 7 (reading, with
  every RAR cipher) and RAR5 (writing, with volumes and recovery records),
  tar and compressed tars, gzip, bzip2, xz, zpaq (journaling, all
  versions), ARJ, LHA.
- **Images and firmware.** ISO 9660 (Joliet, Rock Ridge, El Torito), UDF,
  MBR, GPT, FAT, ext2/3/4, SquashFS, cramfs, JFFS2, UBI, UBIFS, cpio,
  U-Boot images, device trees and Reolink firmware, opened through every
  nesting level (`firmware.pak > rootfs > etc`).
- **`.zx`, a format that never goes stale.** Any codec inside one
  container, explicit "needs zx X" compatibility, parallel blocks,
  deduplication, append-only versions with dates and per-file timelines,
  SHA-256 and TLSH per file, encryption, volumes spread over several disks.
- **zcm, context mixing in nine levels.** From 1.2 MB/s to a cmix-class
  mode, built on the models of zpaq, paq8px and cmix: smaller than xz and
  7-Zip at every level, smaller than paq8px on English text and source
  code.
- **zxdb, a database in every archive.** SQLite's SQL (checked against
  sqlite3), key-value stores, time series for logs, full-text search,
  `AS OF` time travel, and built-in tables that find any file by SHA-256
  or by similarity, 5 to 20 times smaller than SQLite.
- **A file explorer.** Browse the file system and walk into archives like
  folders, on the desktop and on Android.

---

## Install

| You have | Do |
|---|---|
| Linux, Windows or macOS, no Dart | Download a binary (`zx-linux-x64`, `zx-windows-x64.exe`, `zx-macos-arm64`...) from the releases, rename it `zx`, put it on the PATH |
| The Dart SDK | `dart pub global activate --source path <repo>` |
| The desktop app (Linux) | `tool/install_linux.sh`, or the `.deb` from `tool/build_deb.sh` |
| Android | the APK from `app/build/app/outputs/flutter-apk/` (`cd app && flutter build apk --split-per-abi`) |

Binaries are built by `.github/workflows/release.yml` (six targets) or
locally with `tool/build_binaries.sh`. Details: [docs/app.md](docs/app.md).

---

## The command line

```
zx <command> [<switches>...] <archive> [<files>...] [@listfile]
```

The syntax is 7-Zip's: if you know `7z`, you know `zx`.

| Command | Does |
|---|---|
| `a` | add files (creates the archive) |
| `u` | update (add new and changed files) |
| `x` | extract with full paths |
| `e` | extract without paths |
| `l` | list (`-slt` for every property) |
| `t` | test integrity |
| `d` | delete |
| `rn` | rename inside the archive |
| `h` | hashes of files (`-scrcSHA256`...) |
| `i` | supported formats and codecs |
| `b` | benchmark |
| `sql` | run SQL on a `.zx` database (zx extension) |

Common switches (all of 7-Zip's work):

| Switch | Meaning |
|---|---|
| `-o{dir}` | output folder |
| `-p{password}` | password; `-mhe` also encrypts file names |
| `-t{type}` | archive type (`-tzip`, `-t7z`, `-tzx`, `-ttar`...); default from the extension |
| `-mx={0..9}` | level; `-mm=`, `-m0=` choose the method |
| `-r` | recurse; `-x!pattern`, `-i!pattern` exclude/include |
| `-v{size}` | split into volumes (`-v4g`) |
| `-ao{a,s,t,u}` | overwrite mode (all, skip, rename new, rename old) |
| `-y` | yes to all |
| `-si`, `-so` | read from stdin / write to stdout |
| `-sdel` | delete files after adding |
| `-bb{0..3}` | output detail |

zx extensions (not in 7-Zip):

| Switch | Meaning |
|---|---|
| `-snest[N]` | list, test or extract through nested archives and images as one tree |
| `-mversion=N` or `=YYYY-MM-DD[ HH:MM]` | read an archive (.zx, zpaq) as it was at that version or date |
| `-mtimeline=path` | every version of one file, with dates |
| `-mgenerations` | list the versions of a .zx archive |
| `-mcompact[=N]` | rewrite a .zx keeping only the last N versions |
| `-m0=zcm:auto`, `-mtime=10m`, `-mmem=2g` | pick the strongest zcm level that fits a time and memory budget |
| `-mdedup=on/off` | chunk-level deduplication in .zx (on by default) |
| `-mvdir=DIR[:SIZE\|:full]` | write volumes to several folders/disks in order |
| `-mvsearch=DIR` | where to look for volumes when reading |
| `-mmemuse=SIZE` | cap the memory of parallel workers |

### Examples

```sh
# Everyday archives
zx a backup.7z ~/docs                     # 7z, LZMA2, 7-Zip's defaults
zx a -mx9 -psecret -mhe backup.7z ~/docs  # max level, encrypted names
zx x backup.7z -o/restore                 # extract
zx a site.zip public/ -mm=Deflate -mx9    # zip
zx a src.tar.gz src/                      # a tar written straight into gzip
zx x release.tar.xz -oout                 # tar.xz extracted in one pass
zx x photos.rar                           # any RAR, 1.5 to 7
zx a -v700m -mrr=5% big.rar data/         # RAR5 volumes with recovery record

# The .zx format
zx a backup.zx ~/docs                     # first version
zx a backup.zx ~/docs                     # second version: only the changes
zx l backup.zx -mgenerations              # versions with their dates
zx x backup.zx -mversion=2026-09-01 -oold # the archive as it was that day
zx l backup.zx -mtimeline=docs/plan.txt   # every version of one file
zx a -mcompact backup.zx                  # drop old versions, keep the last
zx a -m0=zcm:auto -mtime=10m corpus.zx texts/   # strongest zcm in 10 minutes
zx a -m0=zcm:cmix -mmem=8g corpus.zx texts/     # cmix-class, slow, smallest
zx a -v4g -v25g -mvdir=/mnt/a:full -mvdir=/mnt/b:full huge.zx data/

# Firmware and disk images
zx l -snest firmware.pak                  # sections, kernel, rootfs files...
zx x -snest -snld20 firmware.pak -oout    # the whole root file system
zx l disk.img                             # partitions; zx l -snest for files

# The database inside an archive
zx sql backup.zx "SELECT path, size FROM zx_files ORDER BY size DESC LIMIT 10"
zx sql backup.zx "SELECT path, distance FROM similar('docs/report.pdf', 20)"
zx sql notes.zx                           # interactive shell, like sqlite3
```

Full reference of every switch: [docs/cli.md](docs/cli.md).

---

## Formats

| Format | Read | Write |
|---|---|---|
| **zx** (`.zx`) | everything | everything (see below) |
| 7z | all methods of the LZMA SDK, AES, split volumes | LZMA, LZMA2, PPMd, filters, BCJ2, AES, solid, update in place of 7-Zip's rules |
| zip, jar, docx, epub, apk... | Store, Shrink, Reduce, Implode, Deflate, Deflate64, BZip2, LZMA, xz, PPMd; ZipCrypto, WinZip AES; Zip64 | Store, Deflate, Deflate64, BZip2, LZMA, xz, PPMd; ZipCrypto, AES-128/192/256 |
| rar | RAR 1.5, 2.0, 2.9, 3.x, RAR5, RAR 7; all ciphers; volumes | RAR5 with volumes, recovery records, encryption |
| tar | ustar, GNU, pax, sparse, long names | GNU or pax |
| tar.gz, tgz, tar.bz2, tar.xz, tar.lzma | as one archive | as one archive |
| gz, bz2, xz, lzma | yes | yes |
| zpaq | every version, encryption | appends versions (dedup, deletions), zpaq 7.15 and zpaqfranz compatible |
| arj, lzh/lha | all methods, ARJ passwords and volumes | yes |
| ISO 9660, UDF | Joliet, Rock Ridge, El Torito, zisofs; UDF 1.02 to 2.60 | |
| SquashFS, cramfs, JFFS2, UBI, UBIFS | all compressors | |
| MBR, GPT, FAT, ext2/3/4, cpio | yes | |
| uImage, device tree, Reolink pak | firmware sections, decompressed kernels, `.dts` source | |

Files are recognized by their content, not their name: a 7z renamed
`.txt` or a tar.gz made in a pipe opens correctly.

---

## The .zx format

`.zx` is zx's own container ([specification](docs/zx-format.md),
[design](docs/zx-format-design.md)). The extension says only "zx can read
this"; every block names the codec chain that made it, so new algorithms
never need a new extension.

- **Explicit compatibility.** Every file records the oldest zx version
  that can decode it and the features it needs. An older zx refuses at
  once: "needs zx 0.7.0 or later: codec zstd-long".
- **Any codec, per block.** LZMA2, LZMA, PPMd, PPMd8, BZip2, Deflate,
  zpaq, zcm and the branch filters, chosen per block or automatically.
- **Parallel.** Blocks of up to 64 MiB are coded by worker isolates: 3x
  faster on 4 threads, identical output for any thread count. A memory
  guard keeps the workers inside the free RAM.
- **Deduplication.** Files are cut into content-defined chunks (zpaq's
  fragmenter); a chunk already stored, in this update or any earlier one,
  is stored once. A second version of a source tree costs 0.3 MB instead
  of 4.8 MB; the chunk index scales to 100 GiB with 13 MB of RAM.
- **Versions with dates.** Every update appends a generation and never
  rewrites old bytes; an interrupted update is simply ignored. Read the
  archive as of a version or a date, list one file's timeline, compact
  when you want the space back.
- **Find by content.** Every file has its SHA-256 (sorted for binary
  search) and a TLSH similarity digest.
- **Encryption.** scrypt, AES-256-CTR and HMAC-SHA-256; names hidden by
  default; a wrong password is reported immediately.
- **Volumes over several disks.** A list of volume sizes, destination
  folders with budgets or "until full", search folders when reading;
  updates add new volumes, so old disks can stay offline.
- **Pipes.** Written to stdout and read from stdin in one pass.

---

## Compression: zcm

zcm is zx's context mixing codec family, built on the models of zpaq,
paq8px and cmix (credited below) and rewritten in Dart with fully
deterministic arithmetic, so an archive decodes identically on every
machine. Each level scales its models to a memory budget, and
`-m0=zcm:auto` picks the strongest level that fits your time and memory.

| Level | Speed (AOT) | Memory | Use |
|---|---|---|---|
| 1 | 1.2 MB/s | ~40 MiB | fast, already better than xz |
| 3 | 200 KB/s | ~30 MiB | beats zpaq's strongest method |
| 5 | 85 KB/s | ~35 MiB | paq8-style models with data detection |
| 7 | 10 KB/s | ~170 MiB | paq8px text, image and audio models |
| 9 | 4 to 6 KB/s | ~400 MiB | everything, plus PPMd and gain gating |
| cmix preset | 2 to 3 KB/s | as budget allows | adds cmix's LSTM byte mixer |

Small corpus (text, source code, an x86 binary, a firmware slice; 700,986
bytes), total compressed bytes:

| Compressor | Bytes |
|---|---|
| 7z PPMd | 384,433 |
| xz -9e | 381,240 |
| zpaq method 5 | 357,160 |
| zcm level 1 | 366,552 |
| zcm level 3 | 350,935 |
| zcm level 5 | 341,206 |
| zcm level 9 | 331,324 |
| paq8px -8 (C++, 2.4 GB of RAM) | 330,801 |

zcm level 9 against paq8px -8, per kind of data:

| Data | zcm vs paq8px |
|---|---|
| English text | 0.7 to 5% smaller |
| Source code (C++, Dart) | 0.5 to 1% smaller |
| Grayscale image | +0.05% |
| Color photo (PPM / BMP) | +0.45% / +3.45% |
| 16-bit stereo music | +0.96% |
| 8-bit voice | +0.34% |
| x86 binary | +2.6% |

What makes it work: data-type detection per block (text, x86 code,
images including headerless raw ones, audio), an English dictionary
transform, paq8px's word, text (with a stemmer), match, sparse, x86,
image and audio models, two-layer mixers with SSE stages, PPMd and DMC
as byte predictors gated by measured gain, and cmix's LSTM byte mixer.
Speeds and all measurements: [docs/performance.md](docs/performance.md).
zcm is experimental (stream version 1.0): the default `.zx` codec is
still LZMA2 until benchmarks pick one.

---

## zxdb: the database inside every archive

A `.zx` archive can hold a database next to its files
([design](docs/zxdb-design.md), [SQL reference](docs/zxdb-sql.md)).
Every commit is an archive version, so every table can be read as it was.

```sql
-- built into every archive, no setup
SELECT path, size FROM zx_files WHERE sha256 = x'9f86d081...';
SELECT path, distance FROM similar('photos/IMG_0042.jpg', 20);
SELECT path FROM zx_files AS OF '2026-09-01' WHERE path LIKE 'docs/%';
SELECT * FROM zx_file_history WHERE path = 'docs/plan.txt';

-- your own tables, SQLite dialect, compression per table
CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)
  WITH (compression = 'max');
SELECT * FROM notes AS OF GENERATION 42;
SELECT * FROM HISTORY OF notes WHERE id = 7;

-- key-value stores and time series
CREATE KV STORE settings WITH (ttl = '30d');
CREATE TIMESERIES logs (ts DATETIME, level TEXT, msg TEXT)
  PARTITION BY DAY RETENTION '400d' WITH (tags = (level), fts = on);
SELECT count(*) FROM logs WHERE ts >= '2026-09-01' AND level = 'error';
```

- **SQL**: SQLite's dialect, verified differentially against sqlite3
  3.45.1 with fuzzing (joins, CTEs, upsert, RETURNING, JSON functions,
  dates).
- **Key-value stores**: get in 1.4 us, 315k sequential and 161k random
  puts per second, TTL, change streams.
- **Time series**: columnar segments (delta-of-delta timestamps, XOR
  floats, dictionaries, zcm text), partitions, retention, rollups,
  full-text search; 1M log lines take 8.6x less space than SQLite.
- **Metadata compatible with arca**: descriptions, tags, subtitles,
  transcripts, screenshots and fingerprints keyed by SHA-256, with
  lossless import and export of arca sidecars, and BM25 full-text search.
- **Find by content**: SHA-256 lookup in 2 us; the 20 most similar files
  among a million in under 15 ms (TLSH band index).
- **Tools**: `zx sql` (batch or interactive shell, sqlite3-compatible
  output and dot commands, `.asof`, `.import-sqlite`, `.export-sqlite`),
  and a pure Dart reader and writer of SQLite files.

Against sqlite3 (100k rows): point select 4.8 us vs 11.7 us; files 4 to
20 times smaller depending on data and level (20k JSON records: 158 KiB
at `max` vs 2,680 KiB).

---

## The app

zx is also a file explorer (Flutter; desktop and Android):

- places, drives and bookmarks; breadcrumbs that continue into archives;
  list and icon views with thumbnails; search; file operations with
  progress, trash and conflict handling;
- archives, nested archives, disk images and firmware open like folders:
  copy out to extract, paste in to add;
- `.zx` archives show their versions and a Data view with the database
  (tables, KV stores, time series, queries, file metadata, find similar);
- compression settings: Auto (time budget) or manual (method, memory,
  LSTM, threads, dedup);
- Linux integration: file associations and "Extract to folder" in the
  file manager menus; Android: all-files storage access, SD and USB
  volumes, open from and share to other apps.

More: [docs/app.md](docs/app.md) and [app/README.md](app/README.md).

---

## Library

```dart
import 'package:zx/zx.dart';

// Any format, in a background isolate
final a = await ZxArchive.open('backup.zx');
for (final item in a.items) print('${item.path} ${item.size}');
await a.extract('/restore');
await a.add([ZxSource('/home/me/docs')]);
final old = await ZxArchive.open('backup.zx', date: '2026-09-01');
final similar = a.findSimilar('docs/report.pdf'); // (item, distance) pairs

// A database in an archive
final db = await ZxDatabaseAsync.open('notes.zx');
await db.execute('CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, v TEXT)');
await db.execute('INSERT INTO t (v) VALUES (?)', ['hello']);
final r = await db.execute('SELECT * FROM t');
```

Heavy work runs in worker isolates, never on the UI isolate. API guide:
[docs/api.md](docs/api.md).

---

## Under the hood

- [docs/architecture.md](docs/architecture.md): how the code is organized
  and the rules every change keeps.
- [docs/performance.md](docs/performance.md): every number, with the
  method to reproduce it.
- [docs/zx-format.md](docs/zx-format.md), [docs/zxdb-sql.md](docs/zxdb-sql.md),
  [docs/cli.md](docs/cli.md).

Tests (`dart test`, `cd app && flutter test`) compare against the real
tools wherever they exist: 7z, xz, zip/unzip, tar, gzip, bzip2, rar and
unrar, arj, lhasa, zpaq and zpaqfranz, sqlite3, mksquashfs, xorriso,
mkfs.* and paq8px.

---

## Credits

zx stands on the work of many people. Every file names its sources.

| Work | Authors |
|---|---|
| LZMA SDK: 7z, xz, lzma, LZMA, LZMA2, branch filters, BCJ2, 7zAES, the 7zr program | **Igor Pavlov** (public domain) |
| PPMd var.H and var.I | **Dmitry Shkarin** (public domain) |
| SHA-256 | **Wei Dai**, Crypto++ (public domain) |
| zlib: Deflate, Deflate64 | **Jean-loup Gailly** and **Mark Adler** |
| bzip2 | **Julian Seward** |
| libarchive: tar, zip, RAR readers, LHA | **Tim Kientzle** and contributors |
| rardecode: RAR 2.0, RAR 3.x keys, RAR 7 | **Nicholas Waples** |
| lhasa: LHA decoders | **Simon Howard** |
| zpaq, libzpaq, the fragmenter | **Matt Mahoney** (public domain) |
| zpaqfranz | **Franco Corbelli** |
| divsufsort, scrypt | **Yuta Mori**, **Colin Percival** |
| TLSH | **Jonathan Oliver**, **Chun Cheng**, **Yanggui Chen** (Trend Micro) |
| BLAKE2 | **Samuel Neves** and the BLAKE2 team |
| paq8, lpaq | **Matt Mahoney**, **Alexander Rhatushnyak**, **Serge Osnach** |
| paq8px models (text, image, audio, x86, SSE...) | **Jan Ondrus**, **Marcio Pais**, **Andrew Epstein**, **Zoltan Gotthardt**, **Sebastian Lehmann** and the paq8px authors; **Florin Ghido** (audio predictor) |
| cmix: LSTM, byte mixer, dictionary | **Byron Knoll** |

The full notices are in [LICENSE](LICENSE). 7-Zip is a registered
trademark of Igor Pavlov; zx is not affiliated with or endorsed by him.

## License

BSD 3-clause, Copyright (c) 2026 Max Brito. See [LICENSE](LICENSE).
