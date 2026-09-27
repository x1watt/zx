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
