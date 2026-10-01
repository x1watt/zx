# zx library API

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

