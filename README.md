# zx

A **port**, not a new archiver: a pure Dart implementation of 7-Zip as the
public domain LZMA SDK has it, which is the complete `7zr` program. It
gives Dart and Flutter programs 7z archives (with LZMA, LZMA2, PPMd, the
branch filters, BCJ2, Delta and AES-256 encryption), xz and lzma files,
and a command line tool with 7-Zip's commands and switches. The encoders
write **byte for byte the output of the SDK** at the same settings, so
archives match 7-Zip's (see Compatibility for the one exception), and
7-Zip reads everything written here.

On top of the SDK, the command line tool reads and writes zip (and jar),
tar, gzip, bzip2, tar.gz / tgz, tar.bz2, tar.xz, LZH and ARJ, and reads
RAR (writing RAR5), ported from permissively licensed sources (zlib,
bzip2, libarchive, lhasa, rardecode) or written from the format
specifications.

No native code, no FFI, no plugins, no run-time dependencies: it works
wherever `dart:io` does (Android, iOS, Linux, macOS, Windows). All heavy
work happens in background isolates, so the UI isolate never blocks.

Status: version 0.5.0, not published to pub.dev (`publish_to: none`).
Version 0.3.0 added **zx**, a desktop archive manager (Flutter, in `app/`),
see Desktop app below. Version 0.4.0 reads firmware and disk images (pak,
uImage, device trees, cpio, ISO, UDF, SquashFS, cramfs, JFFS2, UBI, UBIFS,
MBR, GPT, FAT, ext) and opens the archives nested in them (see Nested
archives below), and reads and writes zpaq journaling archives, every
version of them (engine vendored from the author's zpaq-flutter port of
libzpaq and zpaq 7.15). Version 0.5.0 adds **.zx**, the format of zx
itself (see The .zx format below): any codec inside one container,
explicit compatibility, parallel blocks, appended generations with
history by date, SHA-256 and TLSH per file, encryption and volumes spread
over several disks. It is the default format of the app.

## Credits

All the design, the formats and the codecs behind this package come from
other people. This is a rewrite in Dart of their work, function by
function, and it would not exist without it.

| | |
|---|---|
| **LZMA SDK**: 7z, xz and lzma formats, LZMA, LZMA2, the branch filters, BCJ2, Delta, 7zAES, the 7zr program | **Igor Pavlov**: <https://www.7-zip.org/sdk.html>. Public domain. Version 26.01 is the specification this port follows, file by file. |
| **PPMd var.H**, the PPMd model used by 7z (`lib/src/codec/ppmd`) | **Dmitry Shkarin** (2001). Public domain, as included in the LZMA SDK. |
| **SHA-256** (`lib/src/crypto/sha256.dart`) | **Wei Dai**, from the Crypto++ library. Public domain, as included in the LZMA SDK. |
| **zlib**: Deflate, Deflate64 (contrib/infback9), used by gzip and zip (`lib/src/codec/deflate`) | **Jean-loup Gailly** and **Mark Adler**: <https://zlib.net>. zlib license. Version 1.3.1. |
| **bzip2 / libbzip2**: BZip2, used by bzip2 files and zip (`lib/src/codec/bzip2`) | **Julian Seward**: <https://sourceware.org/bzip2/>. bzip2 license (BSD style). Version 1.0.8. |
| **libarchive**: tar, zip, the RAR 2.9/3.x and RAR5 readers, parts of the LHA reader | **Tim Kientzle** and contributors (Michihiro Nakajima, Andres Mejia, Grzegorz Antoniak and others): <https://www.libarchive.org>. BSD 2-clause. |
| **rardecode**: the RAR 2.0 decoder with its audio mode, the RAR 3.x key derivation and encrypted headers, RAR 7 (compression version 1) decoding (`lib/src/codec/rar/rar2_decoder.dart`, `lib/src/crypto/rar3_kdf.dart`, `lib/src/codec/rar/rar5_decoder.dart`) | **Nicholas Waples**: <https://github.com/nwaples/rardecode>. BSD 2-clause. |
| **lhasa**: the LHA decoders (`lib/src/codec/lzh`) | **Simon Howard**: <https://github.com/fragglet/lhasa>. ISC license. |
| **PPMd var.I**, zip method 98 (`lib/src/codec/ppmd8`) | **Dmitry Shkarin** (2001), as ported to C by Igor Pavlov. Public domain. |
| **BLAKE2sp**, the RAR5 file hash | **Samuel Neves**, the BLAKE2 reference code. CC0 1.0. |
| **zpaq**: the ZPAQ journaling format, libzpaq, the ZPAQL machine (`lib/src/zpaq`, vendored from the author's zpaq-flutter port) | **Matt Mahoney**: <http://mattmahoney.net/dc/zpaq.html>. Public domain. zpaq 7.15 is the specification. |
| **zpaqfranz**: the per file attribute extension (hashes and CRC-32) and its tables | **Franco Corbelli**: <https://github.com/fcorbelli/zpaqfranz>. MIT. |
| **divsufsort** (in libzpaq), **scrypt** (the zpaq `-key` derivation, also the .zx key derivation) | **Yuta Mori** (MIT) and **Colin Percival** (BSD 2-clause). |
| **TLSH**, the similarity digest of .zx entries (`lib/src/util/tlsh.dart`) | **Jonathan Oliver**, **Chun Cheng** and **Yanggui Chen** (Trend Micro): "TLSH: A Locality Sensitive Hash" (2013), <https://github.com/trendmicro/tlsh>. Apache 2.0 or BSD 3-clause; used under the BSD license. |
| **zcm**, the experimental context mixing codecs (`lib/src/codec/zcm`): paq8 and lpaq (StateMap, APM, ContextMap, mixer, match, word, sparse, record, indirect, DMC and x86 models, the arithmetic coder) | **Matt Mahoney** (paq8, lpaq1: <http://mattmahoney.net/dc/>), with **Alexander Rhatushnyak** and **Serge Osnach** (paq8 exe and model work). GNU GPL. |
| zcm: the paq8px state table, byte history context map, char group, indirect, E8/E9 transform and SSE designs | the **paq8px** authors: Jan Ondrus, **Marcio Pais**, **Andrew Epstein**, **Zoltan Gotthardt**, Simon Berger, Moises Cardona, Surya Kandau and others (<https://github.com/hxim/paq8px>). GNU GPL. |
| zcm: the LSTM byte model, byte models turned into bit predictions | **Byron Knoll** (cmix, <https://github.com/byronknoll/cmix>, and lstm-compress). GNU GPL v3. |
| zcm: PPMd var.H as a byte predictor | **Dmitry Shkarin** (PPMd), through the LZMA SDK port in `lib/src/codec/ppmd`. |

The 7z, xz and lzma code comes only from the public domain LZMA SDK; the
other formats come from the permissive sources above or were written from
the format documents (PKWARE APPNOTE, RFC 1951 and 1952, POSIX ustar and
pax, WinZip AES, the RAR5 and ARJ technotes, and for the RAR 1.5 method
and the RAR 1.5 and 2.0 ciphers the format descriptions of rar-research,
with black box tests against RAR 1.55, WinRAR 2.90 and unrar). No code from the GNU LGPL
licensed parts of 7-Zip, from unRAR or from the GPL ARJ was read or used,
which is why this package can be BSD licensed (with one exception: the
experimental zcm codecs in `lib/src/codec/zcm` are new Dart code that
draws on paq8, paq8px and cmix, credited above); each notice is in
`LICENSE`. 7-Zip is a registered trademark of Igor Pavlov; this
package is not affiliated with or endorsed by him.

The Dart port itself (the ports of the SDK files, the isolate based API,
the parallel encoder, the tooling and the tests) is Copyright (c) 2026 Max
Brito, BSD 3-clause, see `LICENSE`.

## What you get

- **7z archives**: create, update (add, replace, delete, rename without
  recompressing), list, extract, test. Solid and non solid, 7-Zip's
  automatic filter choice for executables, header compression, split
  volumes (`name.7z.001`).
- **Methods**: LZMA, LZMA2, PPMd, Copy; filters BCJ, BCJ2, ARM, ARMT,
  ARM64, PPC, IA64, SPARC, RISCV, Delta, SWAP2, SWAP4; 7zAES (AES-256 with
  the SHA-256 key derivation), with or without encrypted file names.
- **xz**: create and extract, all checks (none, CRC32, CRC64, SHA-256),
  the branch filters and Delta, multi-block files with sizes in the block
  headers, multi-stream files. Compression with several threads runs the
  blocks in parallel isolates and writes the bytes `7z a -txz -mmt=N`
  writes.
- **lzma**: `.lzma` (LzmaAlone) and `.lzma86` files.
- **Other formats** (command line tool): see the table below.
- **Levels 0 to 9** exactly as 7-Zip maps them to dictionary, match finder
  and fast bytes.

## Compatibility

Checked by the tests against 7-Zip 23.01 (`/usr/bin/7z`) and xz:

| | |
|---|---|
| Archives made by 7-Zip are read here | yes, all SDK methods, solid, encrypted, split |
| Archives made here are read by 7-Zip | yes |
| Same settings, same bytes (LZMA, LZMA2, PPMd, filters, xz with `-mmt`) | yes, see below |
| xz files, both ways with xz 5 | yes |

The LZMA encoder is the SDK's single thread encoder: on a 38 MB input it
writes the same file as the SDK's `LzmaUtil` built single threaded. 7-Zip
with more than one thread uses a multithreaded match finder at levels 5 to
9, which can choose other matches on inputs of several MB, so those
archives are equally valid but not always identical. The port also follows
SDK 26.01 where it differs from older 7-Zip versions (level 5 uses a 32 MB
dictionary; 7-Zip 23.01 used 16 MB).

### Formats of the command line tool

| Format | Extract | Create and update | Checked with |
|---|---|---|---|
| 7z | all SDK methods, AES | LZMA, LZMA2, PPMd, Copy, filters, AES | 7z |
| xz | yes | yes | xz, 7z |
| lzma, lzma86 | yes | lzma: one file, the LZMA `-m` switches (`-mx`, `-md`, `-mfb`, `-mlc`...); lzma86 through the library | xz, 7z |
| zip, jar (and zipx, docx, epub...) | Store, Shrink, Reduce, Implode, Deflate, Deflate64, BZip2, LZMA, xz, PPMd; ZipCrypto, WinZip AES | Store, Deflate, Deflate64, BZip2, LZMA, xz, PPMd (`-mm=`); ZipCrypto, AES-128/192/256 (`-mem=`, `-p`); `-mcu`, `-mx` | unzip, jar, 7z |
| tar | ustar, GNU, pax, long names, sparse files | GNU (default), pax (`-mm=pax`, `-mm=posix`) | tar |
| gzip (`.gz`) | several members | one file, Deflate, `-mx` | gzip |
| bzip2 (`.bz2`) | several streams | one file, `-mx` | bzip2 |
| tar.gz, tgz, tar.bz2, tbz2, tar.xz, txz, tar.lzma, tlz | as one archive (see below) | as one archive | tar |
| LZH (`.lzh`, `.lha`) | every method lhasa decodes (lh0 to lh7, lzs, lz4, lz5, pm0 to pm2) | lh5 (default), lh6, lh7, lh0 (`-mm=`) | lhasa, jlha |
| ARJ | methods 0 to 4, garbled files (`-p`), multi-volume archives (`x.arj`, `x.a01`...), UNIX links | methods 0 to 4 (`-mm=`, default 1), garbled files (`-p`), symbolic links (`-snl`) | arj 3.10 |
| RAR (`.rar`) | RAR 1.5, 2.0 (with audio blocks), 2.9, 3.x, RAR5 and RAR 7 (compression version 1), volumes, the RAR 1.5, RAR 2.0, RAR 3.x and RAR5 encryption (data and headers) | RAR5: volumes (`-v`, `name.part1.rar`...), recovery record (`-mrr=<n>`), encryption (`-p`, `-mhe`) | unrar, rar 7.00; rar 3.93, RAR 2.90 and RAR 1.55 (DOSBox) for the fixtures |
| cpio | newc, crc, odc, afio large ASCII, old binary (both byte orders), hard and symbolic links | no (extract only) | cpio |
| ISO 9660 (`.iso`) | Joliet, Rock Ridge, El Torito boot images, zisofs, raw 2352 byte sector images | no (extract only) | xorriso, genisoimage, 7z |
| UDF (`.iso`, `.udf`) | UDF volumes, ISO/UDF bridge discs | no (extract only) | mkudffs, 7z |
| SquashFS | version 4.0, gzip, lzma, xz, lzo, lz4 and zstd | no (extract only) | mksquashfs, unsquashfs |
| cramfs | both byte orders, holes, the extended block pointers | no (extract only) | mkfs.cramfs |
| JFFS2 | both byte orders; none, zero, rtime, zlib, lzo and lzma nodes | no (extract only) | mkfs.jffs2 |
| UBI, UBIFS | UBI volumes; UBIFS with lzo, zlib and zstd | no (extract only) | ubinize, mkfs.ubifs |
| MBR, GPT (disk images) | partitions as items, named after their file system (`0.fat`, `1.ext`) | no (extract only) | sfdisk, sgdisk, 7z |
| FAT | FAT12, FAT16, FAT32, long names | no (extract only) | mkfs.vfat, mtools |
| ext2, ext3, ext4 | block maps and extents, inline data, links, devices (the journal is not replayed) | no (extract only) | mke2fs, debugfs |
| Reolink pak (firmware) | the sections (loader, device tree, U-Boot, kernel, rootfs, app...) | no (extract only) | pakler |
| uImage (U-Boot legacy image) | the payload, decompressed (gzip, bzip2, lzma, lzo, lz4, zstd) | no (extract only) | mkimage |
| Device tree (`.dtb`) | the nodes and properties as files, plus the source (`.dts`) | no (extract only) | dtc |
| zx (`.zx`, zx's own format) | every generation (`-mversion=N` or a date), every codec of the registry (zstd, LZ4 and LZO1X read only), encryption, volume sets, streamed files from a pipe (`-si`) | appends a generation per update (in place, a set gets new volumes); any chain (`-m0=`, `-mf=`), solid or not, encryption (`-p`, names too by default), volumes (`-v`, `-mvdir`), compaction (`-mcompact`) | the tests (it is zx's own) |
| zpaq (`.zpaq`, journaling) | every version (`-mversion=N`, default the last), all methods, encryption (`-p`, zpaq `-key`), the zpaqfranz hashes and CRC-32 | appends a version per update: deduplicated fragments, deletions recorded, renames without recompression; methods 0 to 5 (`-mx`, default 1) or a zpaq method string (`-mm=`), encryption when created (`-p`) | zpaq 7.15, zpaqfranz |

The RAR 1.5 method and the RAR 1.5 and 2.0 ciphers are independent
implementations, written from format descriptions and black box tests
with the old RAR programs and unrar, not from the code of any other
decoder.

Not supported: RAR recovery volumes (`.rev`), the ARJCRYPT ciphers of ARJ (`arj -hg`), ARJ
volume creation, cab, wim and the other
formats of the full 7-Zip, and the Deflate, Deflate64, BZip2 and ZSTD
methods inside 7z (such archives list, and those items report
`unsupportedMethod`). Also absent: SFX modules, NTFS alternate streams and
security data, restoring POSIX permissions (dates are restored), and the
web platform. The library API (`SevenZipArchive` and the helpers) covers
7z, xz and lzma; the other formats have synchronous handlers in
`lib/src/format` and are used through the command line tool.

## Use

```yaml
dependencies:
  zx:
    path: ../zx   # or a git reference
```

```dart
import 'package:zx/zx.dart';

final archive = SevenZipArchive('/data/backup.7z', password: 'optional');

// Create or update: files with the same stored name are replaced.
await archive.add(
  [SevenZipSource('/data/user/0/app/files/photos')], // stored as photos/...
  options: const SevenZipOptions(level: 9, encryptHeaders: true),
  onProgress: (p) => print('${p.doneBytes} of ${p.totalBytes}'),
);

final listing = await archive.list();
for (final e in listing.entries) {
  print('${e.path} ${e.size} ${e.modified}');
}

// Everything, or a subtree, with a policy for existing files.
await archive.extract('/restore');
await archive.extract('/restore',
    paths: ['photos/2025'], overwrite: SevenZipOverwrite.skip);

final bytes = await archive.readFile('photos/cat.jpg');
print((await archive.test()).ok);

await archive.rename({'photos/cat.jpg': 'photos/tom.jpg'});
await archive.delete(['photos/2019']);
```

Cancel any operation with a token; its isolates are killed and the files
it was writing are removed:

```dart
final token = SevenZipCancelToken();
final job = archive.extract('/restore', cancel: token);
// later
token.cancel(); // job completes with SevenZipException(cancelled)
```

xz and lzma files, and small data in memory:

```dart
await xzCompressFile('big.tar', 'big.tar.xz', level: 6, threads: 4);
await xzDecompressFile('big.tar.xz', 'big.tar');
await lzmaCompressFile('a.bin', 'a.bin.lzma');

final packed = xzCompress(bytes);          // on the calling isolate
final plain = xzDecompress(packed);
final z = sevenZipCompressBytes({'a.txt': utf8.encode('hello')});
final files = sevenZipDecompressBytes(z);  // {'a.txt': [...]}
```

The in memory helpers run on the calling isolate; wrap them in
`Isolate.run` for large inputs.

### API

| | |
|---|---|
| `SevenZipArchive(path, {password})` | A 7z archive (or `name.7z.001` for split volumes). The password is used for encrypted data and names, and encrypts new data in `add`. |
| `list()` | `SevenZipListing`: entries (`SevenZipEntry`: path, size, packed size, CRC, times, attributes, method, encrypted, block), solid, number of blocks, sizes. |
| `extract(dir, {paths, overwrite, restoreTimes, onProgress, cancel})` | Extracts into `dir`. `paths` selects stored names; a directory selects everything below it. Returns `SevenZipExtractResult` (files, dirs, bytes, skipped, errors, `wrongPassword`). |
| `test({paths, onProgress, cancel})` | Decodes and checks CRCs without writing. |
| `readFile(name)` | One stored file as bytes. |
| `add(sources, {options, onProgress, cancel})` | Creates or updates. Returns `SevenZipUpdateResult`. |
| `delete(names, ...)`, `rename(map, ...)` | Remove items, or rename them (a directory with its contents) without recompressing. |
| `xzCompressFile`, `xzDecompressFile`, `lzmaCompressFile`, `lzmaDecompressFile` | File to file, in a background isolate, with progress and cancellation. |
| `xzCompress`, `xzDecompress`, `lzmaCompress`, `lzmaDecompress`, `sevenZipCompressBytes`, `sevenZipDecompressBytes` | In memory, on the calling isolate. |

`SevenZipOptions` sets `level` (0 to 9, default 5), `method` (`'LZMA2'`,
`'LZMA'`, `'PPMd'`, `'Copy'`, or with properties such as
`'LZMA2:d=64m:fb=64'`), `solid` or `solidBlock` (`'64m'`, `'100f'`, `'e'`),
`filter` (`'BCJ2'`, `'ARM64'`, `'off'`...), `encryptHeaders`, `threads`,
`storeSymlinks` and `switches`, any other `-m` switch body (`'qs'`,
`'hc=off'`, `'tm=off'`). They are 7-Zip's switches, applied by the ported
7z handler, so their meaning and defaults are 7-Zip's.

Errors are `SevenZipException` with a `kind` (`SevenZipError.wrongPassword`,
`crc`, `data`, `isNotArc`, `unsupportedMethod`, `cancelled`...), and cross
the isolate boundary unchanged.

### Lower level

`package:zx/zx.dart` also exports the synchronous building blocks, for
programs that run them in their own isolates or need streams:
`SevenZipReader` and `SevenZipWriter.update` (items kept, replaced,
renamed, added from any `InStream`), `XzArchive`, `LzmaAloneArchive`,
`MultiInStream` / `MultiOutStream` for volumes, the stream classes, and the
codecs (`LzmaCompressor`, `Lzma2Compressor`, `PpmdCompressor`, their
decoder streams, `createFilterEncoder`, `Crc32`, `Crc64`, `Sha256`). They
block while they work: do not call them on the UI isolate.

### In a Flutter app

Call the API from anywhere; each operation runs in its own isolate.
Progress arrives on the calling isolate at most every 100 ms. Extraction
writes `name.zx-part` and renames it only when the file is complete and its
CRC matched, so a failed or cancelled extraction never leaves a half
written file under the real name; an update writes the new archive beside
the old one and renames it at the end.

Memory is 7-Zip's: the LZMA encoder needs about 11 times the dictionary
(level 5: 16 MB dictionary, about 200 MB; level 9: 64 MB, about 700 MB),
the decoder about the dictionary. On phones prefer levels up to 5. See
`docs/performance.md`.

## Command line

The package includes 7zr's command line as the `zx` program, with the same
commands and switches as 7-Zip:

```sh
zx <command> [<switches>...] <archive> [<files>...]
zx a -mx9 backup.7z docs/
zx x -psecret backup.7z -oout
zx l -slt backup.7z
zx a site.zip public/ -mm=deflate -mx9
zx a -psecret -mem=AES256 private.zip notes/
zx a src.tar.gz src/            # a tar written straight into gzip
zx x release.tar.xz -oout
zx a old.lzh docs/ -mm=lh7
zx t backup.arj
zx a backup.zpaq docs/          # a new version of a zpaq backup
zx l backup.zpaq -mversion=2    # as it was after version 2
zx a backup.zx docs/            # a new generation of a .zx archive
zx x backup.zx -mversion=2026-09-01 -oold   # as of a date
```

The format comes from the extension (`-t` chooses it: `-tzip`, `-ttar`,
`-tgzip`, `-tbzip2`, `-tLzh`, `-tArj`, `-tRar5`...), and the `-m`
switches are the ones 7-Zip has for that format.

**Compressed tar archives.** 7-Zip opens `x.tar.gz` as a gzip archive that
holds one file, `x.tar`. `zx` treats a tar inside gzip, bzip2, xz or lzma
as one archive when the names say so (`x.tar.gz`, `x.tgz`, `x.tar.bz2`,
`x.tbz2`, `x.tar.xz`, `x.txz`, `x.tar.lzma`, `x.tlz`..., or a stored name
ending in `.tar`): `l` lists the tar items (with a block for each level,
as 7-Zip prints nested archives), `x`, `e` and `t` read the tar in one
pass through the decompressor, `a` writes the tar straight into the
compressor, and `a`, `u`, `d` and `rn` on an existing archive decompress
the tar to a temporary file (in the `-w` folder or next to the archive),
update it and write the new archive in its place. `-m` switches go to the
compressor (`-mx`, `-mmt`...), except `-mm=gnu|pax|posix`, `-mtm`, `-mtc`,
`-mta`, `-mtp` and `-mcp`, which go to tar. `-ttar` opens any compressed
tar this way, and so does the type chain `-ttar.gzip` (7-Zip's order:
tar inside gzip). `-tgzip`, `-tbzip2`, `-txz` and `-tlzma` keep 7-Zip's
view of one compressed file.

**zpaq archives** are journals: every `a`, `u`, `d` or `rn` appends a new
version and never rewrites the old ones (the new file is the old one plus
the version). Files are cut into fragments and a fragment already stored
in any version is not stored again; unchanged files cost nothing, a
deleted file is recorded as a deletion, a renamed one reuses its
fragments. `l`, `x`, `e` and `t` show the last version, or the version N
with `-mversion=N` (`l -slt` prints `Versions` and each item's
`Version`); an archive opened at an older version is not updated.
Methods: `-mx=0` to `-mx=5` (zpaq's levels, default 1; higher values are
5) or `-mm=<zpaq method>` (`14`, `x4.3ci1`...), `-mfragment=N` (zpaq
`-fragment`), `-mhash=xxh64|sha1|off` (the zpaqfranz file hash, default
XXHASH64). `-p` encrypts a new archive as zpaq `-key` does (AES-256 in CTR
mode, scrypt); an encrypted archive has no signature and is recognized by
its `.zpaq` extension (or `-tzpaq`). The update runs on one thread
(`-mmt` is accepted and ignored). Archives stay readable and writable by
zpaq 7.15 and zpaqfranz, in both directions.

### The .zx format

`.zx` is zx's own container (specification: `docs/zx-format.md`, design:
`docs/zx-format-design.md`). The extension and the magic bytes
(`89 5A 58 0D 0A 1A 0A 00`) only say "zx can read this": every block
names its coder chain, so new codecs come without a new extension. Every
file states the oldest zx release that can read it and the features it
needs, and an older zx refuses cleanly ("needs zx 0.7.0 or later") before
reading any data.

- **Codecs**: LZMA2 (the default for now: the default chain will be
  chosen by benchmarks), LZMA, PPMd (var.H), PPMd8 (var.I), BZip2,
  Deflate, zpaq (context mixing, one zpaq block per zx block) and store,
  after the filters BCJ, ARM, ARMT, ARM64, PPC, SPARC, IA64, RISCV and
  Delta; zstd, LZ4 and LZO1X are read. Experimental codec families
  register in their own id range (`registerZxCodec`): **zcm** (id
  0x10000), context mixing in nine levels from about 0.6 MB/s (level 1)
  to paq8px style models (levels 6 to 8, 12 to 22 KB/s) and level 9 with
  PPMd and an optional LSTM (`-m0=zcm:level=3`, `-m0=zcm:cmix:mem=4g`;
  `lib/src/codec/zcm`, `docs/performance.md`). An archive that uses it
  can only be read by the zx version that wrote it or a later one.
- **Blocks** of 16 MiB (`-mbs=4k..64m`), solid by default (`-ms=off`: a
  file per block), coded in parallel by worker isolates (`-mmt`; by
  default as many as half the processors and about 1 GiB of memory
  allow). A damaged block fails only the files that use it; every block
  has a check (`-mcheck=xxh64|crc32c|sha256|blake2sp|none`).
- **Generations**: every `a`, `u`, `d` or `rn` appends a generation in
  place, with its time; the old bytes are never rewritten, and an
  interrupted update is ignored and overwritten by the next one. `l`, `x`,
  `e`, `t` read any generation: `-mversion=3`, `-mversion=2026-09-01`,
  `-mversion="2026-09-01 14:30"` (local time, the last generation up to
  the end of that day or minute). `l -mgenerations` lists them, `l
  -mtimeline=path` lists the versions of one file with the generation
  (and date) that wrote each and the one that replaced or deleted it.
  `a -mcompact[=N] x.zx` (without file names) rewrites the archive with
  the data of the last N generations only (1 by default); `-mcompact`
  with an update compacts after it. `l -slt` shows `Wasted`, the bytes a
  compaction frees.
- **Hashes**: every file has its SHA-256 (sorted in a lookup table) and a
  TLSH digest (similar files, `ZxArchive.findSimilar`).
- **Encryption**: `-p` (scrypt, AES-256-CTR, HMAC-SHA-256); the names are
  encrypted too unless `-mhe=off`. A wrong password is refused at once.
- **Streamed**: written to a pipe (`zx a -tzx -so x.zx dir | ...`) the
  file has inline records, and `zx x -tzx -si` reads it in one pass.
- **Volumes**: `-v` (repeat it for a list of sizes, the last one
  repeating: `-v4g -v25g`), `-mvdir=DIR[:SIZE|:full]` (destination
  folders in order, each with a budget or until its disk is full),
  `-mvsearch=DIR` (folders where volumes are looked for when reading;
  volumes are recognized by their header, whatever their names). An
  update of a set adds new volumes and leaves the old ones as they are.

```sh
zx a -m0=PPMd8:o=8:mem=256m notes.zx notes/
zx a -mf=ARM64 -m0=LZMA2:d=64m firmware.zx build/
zx a -m0=zcm:level=6 -mmt2 texts.zx texts/
zx a -v4g -v25g -mvdir=/mnt/disk1:100g -mvdir=/mnt/disk2:full big.zx data/
zx l -mvsearch=/mnt/disk2 /mnt/disk1/big.zx.001
zx l -mtimeline=docs/plan.txt backup.zx
```

In the library: `ZxArchive.create`, `open(version:, date:,
searchDirs:)`, `add`, `delete`, `rename`, `extract`, `test`, `compact`,
`timeline`, `findBySha256`, `findSimilar`, and `ZxOptions.volumeSizes` and
`volumeDirs`; the synchronous building blocks (`ZxWriter`,
`ZxArchiveReader`, `ZxHandler`, `Tlsh`) are exported by `package:zx/zx.dart`.

### Nested archives

Firmware and disk images hold images inside images: a Reolink pak holds a
uImage kernel and UBI images whose volumes are UBIFS file systems, a disk
image holds FAT and ext partitions. By default `zx` behaves as 7-Zip and
opens one level: `zx l firmware.pak` lists the sections. The zx switch
`-snest[N]` (not in 7-Zip) shows the whole thing as one tree for `l`, `t`,
`x` and `e`: every item that is itself an archive or an image becomes a
folder holding its contents, down to N levels (default 4):

```sh
zx l -snest firmware.pak        # loader, fdt/..., kernel/..., rootfs/bin/...
zx x -snest firmware.pak -oout  # out/rootfs/ holds the root file system
zx t -snest disk.img
```

The items of the container formats (pak, uImage, UBI, MBR, GPT) are
always tried; any other item is tried when its first bytes match the
signature of a known format (so an ISO inside a tar opens, a text file
never does). A folder whose archive holds a single archive shows that one
directly (`rootfs/` holds the UBIFS files of the only UBI volume); a
compressed file or a device tree inside a file system (`x.gz`, `x.dtb`)
stays a file. `-t` chains work as before. Symbolic links of firmware file
systems often point up (`../bin/busybox`) or are absolute, which 7-Zip
refuses by default: add `-snld20` to create them.

The library does the same: `ZxArchive.open(path, flatten: true)` lists,
extracts, tests and reads the tree (`ZxItem.nestedFormat` marks the
folders of nested archives), and `archive.openNested(item)` opens one
item as an archive of its own, with `parent` and `nestPath` to go back.
Both are read only; `close()` deletes the temporary copies made for
formats without random access to their items (7z, rar).

Hard links (tar, cpio, SquashFS, UBIFS, ext...) are extracted as hard
links, or as copies where the file system has none.

`ZxArchive` handles zpaq like the other formats (`ZxArchive.create(
'backup.zpaq', sources)`, `add`, `delete`, `rename`, `extract`, `test`,
`readBytes`; `ZxOptions.method` is the zpaq method, `password` encrypts a
new archive). `archive.versions` lists the versions (`ZxVersion`: number,
time, added, deleted, packed size) and `ZxArchive.open(path, version: 2)`
opens the archive as it was after version 2, read only:

```dart
final a = await ZxArchive.open('backup.zpaq');
print('${a.numVersions} versions');
final old = await ZxArchive.open('backup.zpaq', version: 1);
await old.extract('/restore-v1');
```

### Installing

- With the Dart SDK: `dart pub global activate --source path <repo>` puts
  a `zx` command on the PATH (in `~/.pub-cache/bin`, which must be on it).
- Without it: copy a binary from `dist/` (or from a release) into a
  folder on the PATH, as `zx` (`zx.exe` on Windows), and make it
  executable (`chmod +x`).

Native binaries (no Dart SDK needed to run them):

| File | Platform |
|---|---|
| `zx-linux-x64`, `zx-linux-arm64` | Linux |
| `zx-windows-x64.exe`, `zx-windows-arm64.exe` | Windows |
| `zx-macos-arm64`, `zx-macos-x64` | macOS (Apple silicon, Intel) |

The GitHub workflow `.github/workflows/release.yml` builds all six on
native runners and attaches them to the release when a `v*` tag is pushed.
Locally, `tool/build_binaries.sh` writes them to `dist/`: the Dart SDK
cross-compiles only to Linux, so from Linux it builds the two Linux
binaries, plus `zx-windows-x64.exe` when `DART_WINDOWS` points to a
Windows Dart SDK and wine is installed; on a Mac it builds that Mac's
binary. Without a binary, `dart run zx:zx ...` runs the same program from
source.

## Desktop app

`app/` is **zx**, a WinZip / 7-Zip File Manager style archive manager for
Linux, Windows and macOS, written with Flutter on the `ZxArchive` API (so
every format of the command line tool, and all the archive work in
background isolates: the window never freezes).

- Open archives from the command line, File > Open, drag and drop, or the
  recent list; browse with a folder tree, a breadcrumb path bar (Back,
  Forward, Up), a sortable file list (Name, Size, Packed, Ratio, Modified,
  Method, Encrypted, CRC), multi selection, a quick filter and a preview
  of text and images.
- Extract (all or the selection, with or without paths, overwrite policy
  with a per file question: Yes, No, Yes to all, No to all, Keep both,
  Cancel), extract here, test, open a file with its default program.
- Add files and folders (dialog or drag and drop, into the current folder
  of the archive) with level, method, password, encrypted names and solid;
  delete, rename, new folder, archive comment (zip, RAR5); new archives in
  7z, zip, tar.gz, tar.bz2, tar.xz, rar (RAR5), tar, lzh, arj, zpaq, gz,
  bz2, xz.
- Passwords are asked when needed (show / hide, wrong password retry);
  long operations show percent, current file, speed and Cancel. Actions a
  format does not allow are disabled with a tooltip saying why.
- Settings: theme (system, light, dark), default format and level,
  confirmations, and the desktop integration switches below.

### Installing on Linux

The normal install is the Debian package (Ubuntu, Debian and their
derivatives, amd64):

```sh
tool/build_deb.sh                        # writes dist/zx_<version>_amd64.deb
sudo apt install ./dist/zx_0.5.0_amd64.deb
nautilus -q                              # once, so Nautilus loads the extension
```

| What | Where |
|---|---|
| The release bundle | `/opt/zx` (`zx_app`) |
| Launcher, command line tool | `/usr/bin/zx-gui`, `/usr/bin/zx` |
| Desktop entry with the archive MIME types | `/usr/share/applications/zx.desktop` |
| Icon (SVG and PNG sizes) | `/usr/share/icons/hicolor/*/apps/zx.*` |
| The MIME type of .zx files (`application/x-zx`, magic and `*.zx`) | `/usr/share/mime/packages/zx-archive.xml` |
| Nautilus: top level `Extract to "name/"` item on archives | `/usr/lib/x86_64-linux-gnu/nautilus/extensions-4/libzx-nautilus.so` |
| Documentation, license | `/usr/share/doc/zx` |

The package needs nothing beyond the libraries of a GTK desktop: the
Nautilus item is a native extension (C, `native/nautilus/`), not a
nautilus-python script, so no other package has to be installed. The
package does not change anyone's default applications: each user turns
that on in Settings. The Nautilus item is on unless a user switches it
off in Settings (then `~/.config/zx/context-menu-disabled` exists and the
extension shows nothing; no restart needed). `sudo apt remove zx`
removes it all; the per user files (settings, `mimeapps.list` lines,
Thunar action) stay until switched off in Settings before removing.

Without root, a per user install:

```sh
tool/install_linux.sh            # build, install, associate, add the menu
tool/install_linux.sh --no-associations --no-context-menu
tool/uninstall_linux.sh [--purge]
```

| What | Where |
|---|---|
| The release bundle | `~/.local/share/zx/app` (`zx_app`) |
| Launcher | `~/.local/bin/zx-gui` |
| Desktop entry with the archive MIME types | `~/.local/share/applications/zx.desktop` |
| Icon (SVG and PNG sizes) | `~/.local/share/icons/hicolor/*/apps/zx.*` |
| The MIME type of .zx files | `~/.local/share/mime/packages/zx-archive.xml` |
| Default application (when associated) | `~/.config/mimeapps.list` (the previous defaults are restored when switched off) |
| Nautilus: "Extract to folder (zx)" under Scripts | `~/.local/share/nautilus/scripts/` |
| Thunar custom action (merged, other actions kept) | `~/.config/Thunar/uca.xml` |

A per user install can not add a top level Nautilus item (Nautilus
loads extensions only from the system folder), so there it is under
Scripts in the right-click menu.

The two switches of Settings (associate archive types, "Extract to
folder" in the file manager) install and remove the per user files: the
Thunar action and, for a per user install, the Nautilus script; with the
package the menu switch turns its Nautilus extension on and off. The
switches and the script call the same code, also reachable as
`zx_app --install-integration [--associations] [--context-menu]`,
`zx_app --remove-integration [...]` and `zx_app --integration-status`.
`zx_app --extract-to-folder a.zip b.tar.gz` extracts each archive into a
new folder named after it next to it (`b.tar.gz` gives `b/`, an existing
name gives `b (2)/`), in a small progress window that asks for a password
when needed and closes itself; this is what the menu entries run.

Windows (per user, `HKCU\Software\Classes`, no administrator rights) and
macOS (document types in `Info.plist`, a Finder Quick Action) are
described in `app/README.md`.

## Speed

Measured on an 8 core x86-64 desktop with 37.5 MB of mixed files (C
sources, Python sources, shared libraries), AOT build, against 7-Zip 23.01;
`docs/performance.md` has all the numbers and the method:

| | zx | 7-Zip, 1 thread |
|---|---|---|
| 7z a, level 1 | 2.4 s | 1.4 s |
| 7z a, level 5 | 16.2 s | 10.2 s |
| 7z a, level 9 | 18.6 s | 11.1 s |
| 7z a, PPMd | 7.7 s | 3.4 s |
| 7z x, LZMA2 | 0.85 s | 0.62 s |
| xz, 4 MB blocks, 8 threads | 3.5 s | 1.5 s (8 threads) |

The 7z writer runs on one isolate; xz compression uses one isolate per
block (section 6 of `docs/architecture.md`).

## Tests

```sh
dart analyze
dart test
```

Tests that compare with `/usr/bin/7z` or `xz` are skipped when those are
not installed. The zpaq interop tests (`test/zpaq_test.dart`) look for
`zpaq` and `zpaqfranz` on the PATH or in `ZPAQ_BIN` and `ZPAQFRANZ_BIN`.
The .zx tests are `test/zx_format_test.dart`, `test/zx_generations_test.dart`
and `test/zx_tlsh_test.dart` (TLSH vectors made with the reference
`tlsh_unittest` tool; a zstd block is made with `zstd` when it is
installed). The desktop app has widget tests and end to end tests that
drive the real Linux app against real archives:

```sh
cd app
flutter analyze
flutter test
flutter test integration_test -d linux
```

## Layout

- `lib/src/codec`: LZMA, LZMA2, PPMd, filters, BCJ2 (ports of the SDK's C
  files and their C++ coder wrappers); Deflate and Deflate64 (zlib),
  BZip2, PPMd var.I, the LHA and ARJ codecs, the RAR codecs;
  `codec/zcm`: the zcm context mixing codecs (after paq8, paq8px and
  cmix), with `tool/zcm_bench.dart`.
- `lib/src/crypto`: AES, SHA-256, 7zAES, SHA-1, ZipCrypto, WinZip AES,
  the RAR 3.x and RAR5 key derivations and BLAKE2sp.
- `lib/src/format`: the 7z, xz, lzma and split handlers; gzip, bzip2, tar,
  zip, LHA, ARJ, RAR and zpaq; `format/zx`: the .zx format (structures,
  codec registry, reader, writer, handler).
- `lib/src/zpaq`: the zpaq engine, vendored from zpaq-flutter (the
  upstream); `tool/sync_zpaq.sh` copies it again.
- `lib/src/cli`, `bin/zx.dart`: the command line (`zx`).
- `lib/src/api.dart`: the isolate based public API; `lib/src/pool.dart`
  and `lib/src/parallel.dart`: worker isolates and the parallel xz encoder;
  `lib/src/sync_pool.dart`: worker isolates for synchronous code (the .zx
  blocks).
- `app/`: the desktop archive manager (Flutter), `tool/build_deb.sh` (the
  Debian package), `tool/install_linux.sh` and `tool/uninstall_linux.sh`
  (per user install).
- `native/nautilus/`: the Nautilus extension of the package (C, with a
  test harness: `make -C native/nautilus test`).
- `docs/architecture.md`: how the port is organised and the rules a change
  must keep.
- `docs/performance.md`: measured numbers and how to measure.
- `docs/zx-format.md`: the specification of .zx, and
  `docs/zx-format-design.md`, its design.

## License

BSD 3-clause, Copyright (c) 2026 Max Brito, see `LICENSE`. The LZMA SDK by
Igor Pavlov, and the PPMd var.H and SHA-256 code it includes, are public
domain. The zlib, bzip2, libarchive, lhasa and BLAKE2 parts keep their own
permissive licenses, reproduced in `LICENSE`. See Credits above.
