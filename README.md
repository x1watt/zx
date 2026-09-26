# zx

A **port**, not a new archiver: a pure Dart implementation of 7-Zip as the
public domain LZMA SDK has it, which is the complete `7zr` program. It
gives Dart and Flutter programs 7z archives (with LZMA, LZMA2, PPMd, the
branch filters, BCJ2, Delta and AES-256 encryption), xz and lzma files,
and a command line tool with 7-Zip's commands and switches. The encoders
write **byte for byte the output of the SDK** at the same settings, so
archives match 7-Zip's (see Compatibility for the one exception), and
7-Zip reads everything written here.

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

Only the public domain LZMA SDK was used as a source. No code from the GNU
LGPL licensed parts of 7-Zip was read or used, which is why this package
can be BSD licensed. 7-Zip is a registered trademark of Igor Pavlov; this
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

Not in the SDK, so not here: zip, rar, gzip, bzip2, tar, cab, iso, wim and
the other formats of the full 7-Zip, and the Deflate, Deflate64, BZip2 and
ZSTD methods inside 7z (such archives list, and those items report
`unsupportedMethod`). Also absent: SFX modules, NTFS alternate streams and
security data, restoring POSIX permissions (dates are restored), and the
web platform.

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

The package includes 7zr's command line, with the same commands and
switches:

```sh
dart run zx:7z <command> [<switches>...] <archive> [<files>...]
dart run zx:7z a -mx9 backup.7z docs/
dart run zx:7z x -psecret backup.7z -oout
dart run zx:7z l -slt backup.7z
```

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
  files and their C++ coder wrappers).
- `lib/src/crypto`: AES, SHA-256, 7zAES.
- `lib/src/format`: the 7z, xz, lzma and split handlers.
- `lib/src/cli`, `bin/7z.dart`: the command line.
- `lib/src/api.dart`: the isolate based public API; `lib/src/pool.dart`
  and `lib/src/parallel.dart`: worker isolates and the parallel xz encoder.
- `docs/architecture.md`: how the port is organised and the rules a change
  must keep.
- `docs/performance.md`: measured numbers and how to measure.

## License

BSD 3-clause, Copyright (c) 2026 Max Brito, see `LICENSE`. The LZMA SDK by
Igor Pavlov, and the PPMd var.H and SHA-256 code it includes, are public
domain. See Credits above.
