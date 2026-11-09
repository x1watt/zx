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

### The README of an archive

`ZxArchive.readmeIn(dir)` is the README of a folder (README.md,
README.markdown, README.txt or README, any case), `readme(dir:)` reads and
parses it in background isolates: a `ZxReadme` with the document
(`MdDocument`: `MdHeading`, `MdParagraph`, `MdList`, `MdTable`... with
`MdText`, `MdLink`, `MdImage`... inlines) and the links and images that
can not work. `classifyReadmeUrl` says where a link or image points (an
entry, a heading, another place, or blocked): an image is shown only from
the archive. See docs/readme.md.

### Signed generations

`ZxOptions(signKey: 'nsec1...')` signs the new generation (a new archive
is sealed with the key as its admin). `ZxArchive.seals({full})` checks the
seals in a background isolate, without the password, and returns a
`ZxGenerationSeal` per generation (state sealed, pending, broken or
plain, signer, role, policy); `zxSealSummary` makes one line of them.
`ZxArchive.sign(key, ...)` appends a signed generation with the same
files: it activates sealing, changes the roles (maintainers, rule, a new
admin with its acceptance) or signs the history. `generateSecretKey`,
`publicKeyOf`, `npubEncode`, `nsecEncode`, `parsePublicKey`,
`schnorrSign` and `schnorrVerify` are exported. For a database,
`ZxDbStoreOptions(signer: key, sealEveryMicros: ...)`. See
docs/zx-format.md section 17.

### An application database

`package:zx/zxdb.dart` is the database alone, for a program that wants
zxdb where it would use SQLite (no archiver, no isolate pool): `ZxSqlDb`
(`lib/src/db/zx_sql_db.dart`).

```dart
import 'package:zx/zxdb.dart';

final db = ZxSqlDb.open('/data/app/notes.zx', password: secretHex, scryptLog2N: 1);
db.execute('CREATE TABLE IF NOT EXISTS n (id INTEGER PRIMARY KEY, t TEXT) '
    "WITH (compression = 'fast')");
db.transaction(() {
  for (final t in texts) db.execute('INSERT INTO n (t) VALUES (?)', [t]);
});
for (final r in db.select('SELECT id, t FROM n WHERE t LIKE ?', ['%x%'])) {
  print('${r['id']} ${r.columnAt(1)}');
}
db.kv('cache', ttl: const Duration(days: 1)).putString('k', 'v');
db.maybeCompact();          // when idle: rewrite the file once it has grown
db.dispose();
```

- Synchronous, like an SQLite binding: `execute`, `select` (rows are maps
  by column name, `columnAt(i)` by position), `prepare`, `updatedRows`,
  `lastInsertRowId`, `transaction(fn)` (one commit; rolled back when `fn`
  throws; `fn` must not await). The SQL is zxdb's (docs/zxdb-sql.md).
- Every write outside a transaction is a commit of its own (about a
  millisecond and some bytes of file each): batch writes in transactions.
- The file only grows; `maybeCompact()` rewrites it when it passed twice
  its size after the last compaction (`stats()` gives the sizes). It holds
  the writer lock while it rewrites: call it when idle, or from another
  isolate that opens the same file.
- Several isolates and processes may open one file: one writer at a time
  (a write waits `lockWaitMs` for the other, then throws
  `ZxDbError.busy`), and a read sees the others' commits (at every
  statement with the default `refreshMicros: 0`).
- Encryption: `password`. For a random secret of full strength (a key
  derived by the program, as hex) pass `scryptLog2N: 1` when creating:
  the secret needs no stretching, so opening costs no KDF time. Derived
  keys are cached per process (`ZxKeys.clearCache`), so reopening and
  following other writers cost no KDF either. A wrong or missing password
  is `ZxDbError.wrongPassword`.
- `kv(name)`: a KV store (created on first use) with TTLs; its writes
  commit on their own, so inside a transaction write through SQL on its
  table `name (key, value)`. `series(name)`: a time series.
- `systemTables: true` adds the system tables (zx_files...), the metadata
  tables and full-text search over the archive's files.
- `ZxSqlDb.memory()`: SQL in memory only (tests).

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

