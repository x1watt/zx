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
