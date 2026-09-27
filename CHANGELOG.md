## Unreleased

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
