## Unreleased

- **Two programs**: `zx`, the command line, and `zx-gui`, the app (the
  app's executable was `zx_app`); on Android the app is `zx.apk`
  (tool/build_apk.sh), and on Termux `zx` installs with
  `dart pub global activate --source git https://github.com/x1watt/zx`.
- **New logo**: a database marked ZX squeezed in a clamp (logo/), in the
  app, the web page and the Windows executables (icon and version
  information, tool/windows_exe_icon.sh).
- **Signed generations** (docs/zx-format.md section 17): .zx versions
  signed with NOSTR keys by an admin and maintainers, checked by anyone
  without the password (`zx seal`, `-msign`); the Footer is 40 bytes.
- **Archive READMEs** (docs/readme.md): a README.md in an archive describes
  it; `zx readme`, and the app shows it below the items.
- **The app is a file explorer** (app/README.md "Using it",
  docs/architecture.md section 11): a sidebar with the places, drives and
  volumes, pinned folders and recent archives; breadcrumbs with an
  editable path (Ctrl+L, also into archives); Back, Forward, Up; details
  or icons with image thumbnails; hidden files; filter and a recursive
  search in a worker isolate; free space in the status bar. File
  operations: open, open with, cut, copy, paste, drag and drop, rename,
  new folder, move to the freedesktop.org trash, permanent delete,
  properties with SHA-256; in worker isolates with progress, cancel and
  a Replace / Skip / Keep both question. Archives open as folders in
  place: copy out is an extract, paste in is an add with the default
  settings, the breadcrumbs go on into the archive and nested archives;
  Compress to .zx, Extract here and Extract to "name/" in the context
  menu. A phone layout below 600 pixels (drawer, large rows, long press
  selection, bottom actions, Paste here). The places, free space, open
  with and share are behind `PlatformPlaces` (app/lib/src/platform).
- **Data view**: DATETIME columns (tables, views, time series and query
  results) come from the declared types of the SQL result and show in
  local time; the version selector lists the versions written after the
  archive was opened.
- **Android app** (app/android, app/lib/src/platform/android_*.dart,
  app/README.md "Android"): Android 7.0 (API 24) and later, APKs per ABI
  (arm64-v8a, armeabi-v7a, x86_64). Storage through "All files access"
  (MANAGE_EXTERNAL_STORAGE, asked for after an in-app explanation; the
  runtime storage permissions on Android 7 to 10) with the Storage Access
  Framework as the fallback (document tree picker; list, copy in and out,
  delete, rename and make folders through the `zx/android` channel).
  Places: internal storage and its standard folders, SD cards and USB
  drives (StorageManager), the app's own folder. zx opens archives from
  other apps (ACTION_VIEW by MIME type and extension: zip, 7z, rar, tar,
  gz, bz2, xz, lzma, lzh, arj, zpaq, iso, zx, split volumes), "Share to
  zx" compresses the shared files into a new archive, and files open
  with other apps and are shared out through a FileProvider. TMPDIR and
  HOME point into the app's private storage, so the library's temporary
  files and the settings work unchanged. zcm Auto reads /proc/meminfo on
  Android (checked on an emulator with 678 MB available: level 5 with
  64 MiB).
- **zxdb time series** (`lib/src/db/ts/`, docs/zxdb-design.md section 12,
  docs/zxdb-sql.md "Time series"): `CREATE TIMESERIES ... PARTITION BY
  HOUR|DAY|WEEK|MONTH RETENTION '400d' WITH (compression, fts, tags)`,
  `DROP TIMESERIES`, `CREATE ROLLUP name ON series EVERY '1h' AS SELECT
  ... GROUP BY ...` (materialized, kept up to date at each seal) and
  `DROP ROLLUP`, and the Dart API `db.series(name)` (`appendAll`, `seal`,
  `scan`/`query` by time range, columns, tag equality and full-text
  words, AS OF by generation or time). Rows are buffered, then sealed per
  partition into column segments: delta of delta timestamps, delta
  integers, XOR floats, per segment dictionaries, text coded with the
  series' compression (zcm by default), Bloom filters on tag columns, an
  optional full-text index. SQL scans read only the partitions, segments
  and columns they need and give `ORDER BY ts` without a sort (the
  planner passes ORDER BY to virtual tables now). Retention drops whole
  partitions at seal and VACUUM. Importers for JSON lines, CSV, syslog
  (RFC 3164 and 5424) and `journalctl -o json`. Benchmark:
  `tool/zxdb_bench_ts.dart`. Rollups take any WHERE expression over the
  series' columns (the SQL evaluator) and include rows still in the
  write buffer at read time (merged with the stored buckets). A hot tier
  (`hot_days`, one day by default) keeps an LZ4 copy of recent
  partitions' text for series with slow text coding, so a cold read of
  the last day of `max` logs runs at 156 MB/s instead of 0.16 MB/s.
  `ZxDatabaseAsync` exposes the series (`ZxSeriesAsync`: create, drop,
  `appendAll` packed by column across the isolate boundary, `seal`,
  `stats`, and `scanBatches`, a Stream of row batches with
  backpressure). Time constraints need no `zx_ns()` any more: the DATETIME
  columns of virtual tables compare as time, so `ts >= '2026-09-01'`,
  `ts BETWEEN '2026-09-01 10:00' AND '2026-09-02'`, `ts > datetime('now',
  '-1 day')` and `ts > unixepoch('now') - 86400` prune partitions and
  filter the same rows (plain tables keep SQLite's rules);
  `datetime(ts)` and the other date functions read DATETIME columns as
  ns; `ZxSqlResult.types` / `isDatetime(i)` let UIs format them, and the
  `zx sql` shell prints them as ISO text (`.datetime off` for ns).
  `FROM HISTORY OF series` lists the rows each generation appended and
  the partitions retention dropped.
- **`zx sql`** (zx extension command, docs/zxdb-sql.md "The zx sql
  shell"): SQL on the database of a `.zx` archive from the command line,
  in batch (`zx sql x.zx "SELECT ..."`) or as a shell reading the
  standard input (scripts with line numbers in errors; on a terminal line
  editing and history). sqlite3's output modes (list, csv, json, line,
  table, box, markdown, quote, tabs, checked against sqlite3) and dot
  commands (`.tables`, `.schema`, `.indexes`, `.mode`, `.headers`,
  `.import` CSV/JSON, `.export`, `.read`, `.param`, `.timer`, `.bail`...),
  plus `.asof`, `.generations`, `.kv`, `.vacuum [ultra]`,
  `.import-arca` / `.export-arca` and `.import-sqlite` / `.export-sqlite`.
- **SQLite import and export** (`lib/src/db/sqlite_io/`): a pure Dart
  reader and writer of SQLite database files (all page sizes, overflow
  pages, WITHOUT ROWID tables, UTF-8/16; exported files pass sqlite3's
  `PRAGMA integrity_check`).
- **App: Data view** for archives with a database: tables, views, KV
  stores, time series and system tables; a table browser with paging and
  sorting; a query box with CSV/JSON export; file metadata (description,
  tags, subtitles, screenshots) in Properties and the preview; Find
  similar files, Find by SHA-256 and Archive > New database. Nested and
  older-version views are read only. All database work runs in a worker
  isolate (`ZxDatabaseAsync`).

- **zxdb storage engine** (`lib/src/db/engine`, docs/zxdb-design.md
  section 11): a database inside any `.zx` archive, next to its files.
  Copy-on-write B+trees of logical pages (4 to 64 KiB, prefix-compressed
  keys, large values in overflow pages) named by id through a page map
  versioned per generation; every commit is an archive generation
  (snapshots of any generation or time, crash safe), file updates and
  database commits interleave in one archive under a writer lock shared
  by processes and isolates. Pages go to a write buffer coded with LZ4 at
  commit and are folded to their tree's compression (`store`, `fast`,
  `balanced`, `max` = zcm, `ultra`, or a chain) by worker isolates,
  without holding the lock; vacuum compacts the archive (database
  included) and can recompress everything. Large transactions spill their
  pages to the file. Format: feature bit `database`, block type 7, Index
  record 0x49 (docs/zx-format.md section 16).
- **Key-value stores** (`ZxDatabase.open(path).kv(name)`, `kv.dart`):
  get, put, delete, prefix and range scans, batches, `watch`, TTL per
  store or per key, group commit; `ZxDatabaseAsync` runs the database in
  a worker isolate for Flutter apps. `ZxMemoryStore` implements the
  storage contract in memory.
- **LZ4 encoder** (`codec/lz4/lz4_encode.dart`): the LZ4 block and frame
  formats with a hash chain match finder; `.zx` writes LZ4 now (codec 9).
- **.zx updates and compaction** take the writer lock of an archive that
  has a database (or a lock file), refuse an archive another writer
  changed since it was opened, and compaction keeps the database.
- **zcm 1.0**: zcm is experimental and its stream version is fixed at 1
  (it is not bumped when the output changes; streams of earlier builds
  may not decode). The budget of small inputs follows the level
  (up to 2 KiB of tables per input byte at levels 8 and 9, 1 KiB at 7,
  256 bytes at 6, 64 bytes below: the strong levels were starved of
  context map memory, -2 to -4% on text, code and x86), paq8px's match
  model with four candidates, recovery and minimum lengths per data type
  (levels 7 to 9), paq8px's text model with its English stemmer and word
  classes (levels 8 and 9, with its state in the text SSE chain). Ported
  but not used by any level (measured, gains below 0.05%): paq8px's
  sparse match, sparse bit and linear prediction models
  (`zcm_sparse.dart`). Level 9 adds paq8px's similarity model pair on
  binary and x86 data (-0.25% there) and gates PPMd and DMC by a quick
  gain check, so it is below level 8 on every file (it was above on
  compressed data). `tableBytes` counts every table, the dictionary word
  list is regenerated by `tool/zcm_gen_dict.dart`. With the LSTM at
  level 9 (the cmix preset) the LSTM is cmix's byte mixer: PPMd's byte
  distribution is a dense input beside the previous byte (-0.2% against
  no LSTM on 32 KiB of text and code, where the plain LSTM lost 0.06%).
  cmix's FXCM model was reviewed and not ported (docs/performance.md).
  The x86 model's inputs are doubled on exe blocks as in paq8px (x86.bin
  -0.8% at level 4, -0.2% at level 9).
- **.zx dedup at scale**: the chunks of earlier generations are kept in
  chunk runs (block type 6, Index record 0x36, `docs/zx-format.md`
  section 6.4.1), sorted by SHA-256 and searched on disk through fences
  and a Bloom filter (1.5 bytes of memory a chunk instead of about 100),
  written once per generation and merged in size tiers, instead of a
  chunk table loaded whole and written in every Index (58 MB per Index
  for 100 GiB of unique data). Chunk tables of 0.5.0 are migrated. The
  whole-file check is streamed (a file of the size of a stored one keeps
  its new chunks in a temporary spill file, never in memory). Encrypted
  archives with a clear Index now deduplicate across generations.
- **.zx from a pipe**: the input is copied (memory, or a temporary file
  with `-mpipetemp=DIR`) and read as a file, so entries deleted or
  replaced by a later generation are not extracted and `-mversion` works;
  `-mpipe=onepass` keeps the one pass reader (every version, in order).
- **.zx updates**: an archive that can not be opened for appending (held
  by another program) is written again and renamed, with retries;
  compaction keeps the zpaq method of zpaq blocks (stored in the chain
  props; blocks of 0.5.0 are copied whole); `-mvdir=DIR:full` works
  without `df`/PowerShell by reserving each volume's space as it is
  written.
- **Compression settings for .zx** (zx switches): `-m0=zcm:auto` chooses
  the zcm level, memory and workers for the machine and the input and
  prints the choice (`zcm level 6, 1.2 GiB, 2 threads, estimated 3 min`,
  details with `-bb1`); `-mtime=90s|10m|2h|fast|balanced|max` (the time
  budget; alone it means zcm:auto), `-mmem=SIZE` (the zcm memory: the
  budget of all workers with auto, the model of each block with a level),
  `-mlstm[=C/L/H]` and `-mlstm-`, `-mcal` (measure the machine first),
  named `-mx` levels (`-mx=ultra`: zcm 8, the other methods 9). A bad
  zx switch prints its reason before E_INVALIDARG.
- `ZxOptions.compression`: `ZxCompression.auto(timeBudget:, speed:,
  memoryBudget:, calibrate:, allowLstm:, threads:)` and
  `ZxCompression.manual(zcm: ZcmOptions(...) | chain: '...', threads:,
  blockSize:)`; `ZxArchive.estimate(sources, options:)` returns the
  chosen settings, the estimated time, peak memory and output size range
  and warnings without compressing (`ZxEstimate`, with `compression` to
  pin them). `ZcmOptions`, `zcmLevelByName`, `zcmDefaultMemoryMiB` and
  `ZxAutoSpeed` are exported.
- App: a Compression section for .zx archives in the New archive and Add
  dialogs and in Settings (Auto with a speed preset or minutes and the
  estimated choice; Manual with the method, zcm level names, memory with
  the machine's safe maximum, LSTM and threads; warnings for memory and
  long runs); the progress dialog shows the speed and the time left.

## 0.5.0

- **.zx**, the format of zx itself (`docs/zx-format.md`, format version 1),
  read and written by the command line tool (format `zx`, `.zx`, the magic
  `89 5A 58 0D 0A 1A 0A 00` at offset 0, found whatever the extension),
  `ZxArchive` and the app, where it is the default format of new archives
  (MIME type `application/x-zx`, installed with a shared-mime-info file by
  the integration and the .deb).
  - A container: each block names its coder chain from a registry
    (`lib/src/format/zx/zx_codecs.dart`, `registerZxCodec`): store, LZMA2,
    LZMA, PPMd (var.H), PPMd8 (var.I), BZip2, Deflate, zpaq, the branch
    filters (BCJ, ARM, ARMT, ARM64, PPC, SPARC, IA64, RISCV) and Delta;
    zstd, LZ4 and LZO1X are read. Every file states the oldest zx that
    reads it and the features it needs; older readers refuse with a clear
    message (a newer format or reader version, an unknown required
    feature, an unknown critical record, an unknown codec).
  - Solid blocks of 16 MiB (`-mbs`, `-ms=off`), coded in parallel by
    worker isolates from the synchronous handler (`lib/src/sync_pool.dart`)
    and decoded in parallel at extraction, with the same bytes as one
    thread; block checks CRC-32C (new, `lib/src/util/crc32c.dart`),
    xxHash64, SHA-256 or BLAKE2sp; a damaged block fails only its files.
  - Every file has its SHA-256 (with a sorted lookup table) and a TLSH
    digest (new, `lib/src/util/tlsh.dart`, identical to the reference
    tool); `ZxArchive.findBySha256`, `findSimilar`.
  - Updates append generations in place, with their UTC times: `-mversion=N`
    or `-mversion=YYYY-MM-DD[ HH:MM[:SS]]` (also `ZxArchive.open(version:,
    date:)`), `l -mgenerations`, `l -mtimeline=path` (`ZxArchive.timeline`),
    `a -mcompact[=N]` (`ZxArchive.compact`), crash safety (the last valid
    Footer is used, the next update overwrites a partial one).
  - Encryption: scrypt keys, AES-256-CTR, HMAC-SHA-256, a password check
    (a wrong password is refused at once), the names encrypted by default.
  - Streamed files for pipes (`-so`, `-si`), with resynchronisation after
    damage.
  - Multi-volume sets: `-v` lists of sizes, `-mvdir=DIR[:SIZE|:full]`
    destination folders, `-mvsearch=DIR` search folders; volumes are
    recognized by their header; an update adds new volumes.
- The zx version is `lib/src/version.dart` (`zxVersionString`).
- The Split handler leaves `x.zx.001` to the zx handler.
- **zcm** (experimental, `lib/src/codec/zcm`): a family of context mixing
  codecs in nine levels, from a fast nibble model (about 0.6 MB/s) to
  paq8px style model sets with text, x86 and byte history models (levels
  6 to 8) and a level 9 that adds PPMd and an optional LSTM (after cmix).
  Deterministic (integer models, IEEE-exact float code for the LSTM,
  golden hashes in the tests), the memory budget stored in the stream,
  independent segments coded on worker isolates
  (`zcmCompressParallel`), automatic settings from the machine
  (`zcm_auto.dart`), `tool/zcm_bench.dart`. Codec id 0x10000 for the .zx
  registry (experimental range). Credits to paq8, paq8px and cmix in
  LICENSE and README.

## 0.4.0

- Firmware and disk image formats, read only, in the command line tool
  and `ZxArchive`: Reolink pak, U-Boot uImage (payload decompressed),
  device trees (nodes, properties and a `.dts`), cpio, ISO 9660 (Joliet,
  Rock Ridge, El Torito, zisofs), UDF, SquashFS, cramfs, JFFS2, UBI,
  UBIFS, MBR and GPT disk images, FAT and ext2/3/4. New codecs for them:
  LZO, LZ4, zstd and a zlib helper.
- Nested archives (zx extension): container formats (pak, uImage, UBI,
  MBR, GPT) mark their items as images. `-snest[N]` for `l`, `t`, `x`
  and `e` shows an archive as one tree in which every item that is an
  archive or an image (a container item, or any item whose first bytes
  match a known signature) is a folder with its contents, down to N levels
  (default 4); a folder whose archive holds a single archive shows that
  one directly (a firmware's `rootfs/` holds the UBIFS files). Without the
  switch nothing changes.
- `ZxArchive.open(path, flatten: true, maxDepth: 4)`: the same tree in the
  library (`ZxItem.nestedFormat`, `ZxItem.nestChain`), with extract,
  test, readBytes and extractToTemp; `ZxArchive.openNested(item)` opens
  an item as an archive (in place through the handler's item stream, or
  from a temporary copy), with `parent` and `nestPath`; `close()` deletes
  the temporary files. Nested and flattened archives are read only.
- Hard links are extracted as hard links (`ln`, `mklink /H`), or as
  copies where the file system has none, by the command line tool (which
  printed "Cannot create hard link") and by the library (which copied).
- zpaq journaling archives, read and write, in the command line tool,
  `ZxArchive` and the app (format `zpaq`, `.zpaq`, `application/x-zpaq`),
  with the engine vendored from zpaq-flutter (`lib/src/zpaq`,
  `tool/sync_zpaq.sh`). Every update appends a version: deduplicated
  fragments, deletions recorded, renames without recompression, the old
  versions untouched. `-mversion=N` lists, extracts and tests the archive
  as of version N (`l -slt` prints `Versions` and each item's `Version`);
  `ZxArchive.open(path, version: N)`, `ZxArchive.versions` and
  `ZxVersion`. Methods 0 to 5 (`-mx`, default 1) or a zpaq method string
  (`-mm=`), encryption of new archives as zpaq `-key` (`-p`), the
  zpaqfranz hashes and CRC-32. Checked both ways against zpaq 7.15 and
  zpaqfranz.
- `ZxArchive.probeNested(item)`: the format of an item as the signatures
  at its start say (an item of a container is tried with the full
  detection), read in the background isolate; `ZxVersion` is exported.
- The app: nested archives. Double click, Enter or "Open as archive" on
  a file that is an archive (a firmware section, a partition, an ISO in a
  tar, a zip in a 7z...) opens it as a new level; a level that holds a
  single archive shows that one (a pak's `rootfs` shows its UBIFS files).
  The path bar shows the chain (`firmware.pak > rootfs > etc > init.d`)
  with a mark at each archive boundary, the title bar too; Back and Up
  leave the level at the item it was opened from. Nested levels are
  read-only (the actions say why); extract, test, preview and "Open with
  default program" work in them. Other files still open with their
  program.
- The app: View, "Show inner filesystems" (saved, off by default) opens
  archives with their nested file systems as folders, read-only.
- The app: a version selector for zpaq archives in the status bar and in
  the Archive menu ("Show version"), with the date of each version; an
  older version is shown read-only.
- The app: icons for disk, firmware and file system images and for the
  sections of containers; the Info dialog shows the nesting chain, the
  formats and the container details (the MTD table of a pak, the uImage
  header), the item properties the details of a section.

## 0.3.0

- zx, a desktop archive manager (Flutter, `app/`) for Linux, Windows and
  macOS on the `ZxArchive` API: folder tree, sortable file list with
  multi selection, path bar with history, quick filter, preview of text
  and images, open with the default program; extract (all, selection,
  with or without paths, overwrite questions), test, add (dialog and drag
  and drop), delete, rename, new folder, comment, new archives in every
  writable format with level, method, password, encrypted names and
  solid; password and progress dialogs with cancel; light and dark
  themes; recent archives.
- `zx_app --extract-to-folder <archive>...`: extracts each archive into a
  folder named after it, in a small window.
- Desktop integration at user level, from the settings or the command
  line (`--install-integration`, `--remove-integration`,
  `--integration-status`): on Linux a desktop entry with the archive MIME
  types, the default application in mimeapps.list (restored when switched
  off), a Nautilus script and nautilus-python extension and a Thunar
  custom action for "Extract to folder"; on Windows the HKCU ProgID,
  OpenWithProgids and an "Extract to folder" verb; on macOS the document
  types of the bundle.
- `tool/install_linux.sh` and `tool/uninstall_linux.sh`.

## 0.2.0

- New formats in the command line tool, each registered with 7-Zip's
  name, extensions and switches:
  - zip (and jar, zipx, docx, epub...): extract Store, Shrink, Reduce,
    Implode, Deflate, Deflate64, BZip2, LZMA, xz, PPMd with ZipCrypto and
    WinZip AES; create and update with Store, Deflate, BZip2, LZMA, xz and
    PPMd (`-mm=`), ZipCrypto or AES (`-mem=`, `-p`), `-mcu`.
  - tar: ustar, GNU and pax headers, long names, sparse files; writes GNU
    or pax (`-mm=gnu|pax|posix`).
  - gzip and bzip2 files (several members or streams).
  - LZH: every method lhasa decodes; writes lh5, lh6, lh7 and lh0.
  - ARJ: methods 0 to 4, both ways.
  - RAR: extracts RAR 2.9, 3.x and RAR5; creates RAR5.
- Codecs: Deflate and Deflate64 (zlib 1.3.1), BZip2 (bzip2 1.0.8), PPMd
  var.I, the LHA and ARJ codecs, the RAR codecs; SHA-1, ZipCrypto, WinZip
  AES, the RAR5 key derivation and BLAKE2sp. `zx i` lists them.
- Compressed tar archives as one archive: x.tar.gz, x.tgz, x.tar.bz2,
  x.tbz2, x.tar.xz, x.txz (and x.tar.lzma, x.tlz for reading) are listed,
  tested and extracted as tar archives (read in one pass, no temporary
  file), created by writing the tar straight into the compressor, and
  updated through a temporary tar. `-ttar` and the type chain
  `-ttar.gzip` do the same for any name; `-tgzip`, `-tbzip2`, `-txz` keep
  7-Zip's single level.
- Format names `Arj` and `Lzh` as 7-Zip writes them.
- Install notes for the `zx` command in the README.

## 0.1.0

- First version: a Dart port of the LZMA SDK 26.01 (the 7zr program).
  LZMA, LZMA2 and PPMd encoders and decoders with the SDK's output; the
  x86, PPC, IA64, ARM, ARMT, ARM64, SPARC and RISCV branch filters, BCJ2,
  Delta, SWAP2, SWAP4; AES-256 and 7zAES.
- The 7z handler: reading, writing and updating archives (solid blocks,
  filter analysis, header compression and encryption, anti items), byte
  for byte the archives 7-Zip writes with the same switches.
- The xz handler (all checks, filters, multi-block and multi-stream files),
  the lzma and lzma86 handler, split volumes.
- Isolate based API: `SevenZipArchive` (list, extract, test, readFile, add,
  delete, rename) with progress and cancellation, xz and lzma file helpers,
  in memory helpers.
- Parallel xz compression in worker isolates, with the same bytes as
  `7z a -txz -mmt=N`.
- The `7z` command line tool with 7zr's commands and switches.
