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

Status: version 0.1.0, not published to pub.dev (`publish_to: none`).

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

The 7z, xz and lzma code comes only from the public domain LZMA SDK; the
other formats come from the permissive sources above or were written from
the format documents (PKWARE APPNOTE, RFC 1951 and 1952, POSIX ustar and
pax, WinZip AES, the RAR5 and ARJ technotes, and for the RAR 1.5 method
and the RAR 1.5 and 2.0 ciphers the format descriptions of rar-research,
with black box tests against RAR 1.55, WinRAR 2.90 and unrar). No code from the GNU LGPL
licensed parts of 7-Zip, from unRAR or from the GPL ARJ was read or used,
which is why this package can be BSD licensed; each notice is in
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

The RAR 1.5 method and the RAR 1.5 and 2.0 ciphers are independent
implementations, written from format descriptions and black box tests
with the old RAR programs and unrar, not from the code of any other
decoder.

Not supported: RAR recovery volumes (`.rev`), the ARJCRYPT ciphers of ARJ (`arj -hg`), ARJ
volume creation, cab, iso, wim and the other
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
not installed.

## Layout

- `lib/src/codec`: LZMA, LZMA2, PPMd, filters, BCJ2 (ports of the SDK's C
  files and their C++ coder wrappers); Deflate and Deflate64 (zlib),
  BZip2, PPMd var.I, the LHA and ARJ codecs, the RAR codecs.
- `lib/src/crypto`: AES, SHA-256, 7zAES, SHA-1, ZipCrypto, WinZip AES,
  the RAR 3.x and RAR5 key derivations and BLAKE2sp.
- `lib/src/format`: the 7z, xz, lzma and split handlers; gzip, bzip2, tar,
  zip, LHA, ARJ and RAR.
- `lib/src/cli`, `bin/zx.dart`: the command line (`zx`).
- `lib/src/api.dart`: the isolate based public API; `lib/src/pool.dart`
  and `lib/src/parallel.dart`: worker isolates and the parallel xz encoder.
- `docs/architecture.md`: how the port is organised and the rules a change
  must keep.
- `docs/performance.md`: measured numbers and how to measure.

## License

BSD 3-clause, Copyright (c) 2026 Max Brito, see `LICENSE`. The LZMA SDK by
Igor Pavlov, and the PPMd var.H and SHA-256 code it includes, are public
domain. The zlib, bzip2, libarchive, lhasa and BLAKE2 parts keep their own
permissive licenses, reproduced in `LICENSE`. See Credits above.
