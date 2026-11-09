# Reusable code

Pieces of code worth reusing instead of writing again. Add to it when you
write or find something with potential for reuse, and check it before
writing a new feature.

## Used by `zx mount`

| Code | Where | Reuse it for |
|---|---|---|
| `ZxFs` and `FsBackend` | `lib/src/mount/zx_fs.dart` | An archive as a file system with staging, a journal and one-update commits. FUSE-free: a macFUSE, WinFsp, WebDAV or NFS front end only needs to call it. `FsBackend` is the seam for fakes in tests. |
| `serveFuse`, frame reader/writer (`_R`, `_W`) | `lib/src/mount/fuse_bridge.dart` | Length-prefixed binary requests over a child's pipes, one at a time. Any native helper process (a Windows or macOS daemon speaking the same protocol, the Nautilus-style helpers) can use it. |
| `native/fuse/zx-rpc.h` | `native/fuse` | The daemon side of the pipe protocol (buffers, framed requests, errno translation, a lock). `zx-mount.c` (libfuse 3) and `zx-mount-fuse2.c` (WinFsp, macFUSE) both include it; a daemon for another file system API (FUSE-T, Dokan, a Finder extension) includes it too. |
| `lib/src/cli/mount_windows.dart` | `lib/src/cli/` | Drive letter helpers, state files with a stop request between a server and `zx umount`, Run key (`reg`) helpers. The state-file handshake suits any background process that must be stopped gracefully without signals. |
| `ZxDrives` mixin | `app/lib/src/integration.dart` | The app side of drives at login for any system with the zx command line tool: it reads `mounts.conf`, the CLI does the rest. |
| `parseSizeArg` | `lib/src/cli/size_arg.dart` | "95m", "1g" arguments (`zx parts`, `zx mount`). |
| `selfCommand`, `findDaemon` | `lib/src/cli/mount_command.dart` | Starting this program again (AOT executable or `dart script.dart`) and locating a native helper next to it, in the source tree or in the lib folders. Candidates to move to a shared `cli/` util if a second helper appears. |
| `MountEntry`, `readMountTable`, `writeMountTable` | `lib/src/cli/mount_command.dart` | A tiny INI file with `[section]` and `key = value` (no dependency). Reuse for any other per-user table of items (settings, saved sources). |
| `systemdUnit` and `zx mounts enable-boot` | `lib/src/cli/mount_command.dart` | Per-user systemd template units (`name@.service`) for other background jobs, such as a scheduled backup or a sync. |
| `activeMounts` | `lib/src/cli/mount_command.dart` | Parsing `/proc/self/mountinfo` (octal escapes) to find mounts of a filesystem type. |
| `tool/fetch_fuse_headers.sh`, `native/fuse/Makefile` | `tool/`, `native/fuse` | Building C helpers against `-dev` headers fetched without root (same pattern as `fetch_nautilus_headers.sh`), with the `-fcf-protection` probe for non-x86. |
| FileMode.append in Dart | `ZxFs.open` | In `dart:io`, `FileMode.append` opens read-write without truncating and `setPositionSync` + writes work at any offset. `FileMode.write` and `writeOnly` truncate. Use `append` for random-access writes. |

## Found in the code base, worth using

| Code | Where | Notes |
|---|---|---|
| `ZxArchive.children`, `[]`, `items` | `lib/src/zx_api.dart` | The tree view of a listing, with implied folders. |
| `ZxArchive.extractToTemp` | `lib/src/zx_api.dart` | One file out of any format into a folder; used for the mount's read cache. For parts of a file use `readRange`. |
| `ZxArchive.readRange` | `lib/src/zx_api.dart`, `workerReadRange` | Bytes of an item from an offset, decoding only the blocks involved (null when the format has no random access). Previews, media players, hex views, anything that needs the middle of a big file. |
| `ZxArchive.add/delete/rename/createFolder` | `lib/src/zx_api.dart` | Updates that write a new archive and rename it over the old one, or append a generation. |
| `CliIo`-free async commands | `runSevenZipCliProcess` in `lib/src/cli/main.dart` | The place to hook long-running (async) commands: dispatch before the synchronous 7-Zip parser. |
| `ZxDb` (also `ZxSqlDb`), `package:zx/zxdb.dart` | `lib/src/db/handle/zx_db.dart` | zxdb where a program would use SQLite: synchronous SQL with map rows, transactions, KV, time series, compaction policy. The entry point for apps that embed zxdb (XPRS uses it for all its stores). |
| `ZxKeys.derive` cache | `lib/src/format/zx/zx_crypto.dart` | Any code that opens the same encrypted archive repeatedly gets its keys without scrypt; `zxKdfRuns` to assert it in tests. |
| `ZxWebFs` and its `File`/`RandomAccessFile`/`Directory` | `lib/src/host/web_fs.dart` | Synchronous dart:io-shaped files in memory for code compiled to the web, with a change list (64 KiB chunks, deletions, renames by id) for the host to persist. Anything else in zx that writes files (an archive update in the web app) can run on it. |
| `ZxTextIndex`, `ZxDb.textIndex` | `lib/src/db/text_index.dart` | BM25 full-text search over any keyed documents with named, weighted fields, kept in the caller's transaction. Use it instead of a scan with LIKE for search boxes (XPRS: the media archive, the Nostr relay store). |

## zxdb full-text search

| Code | Where | Reuse it for |
|---|---|---|
| `ftsTokenize`, `ftsFold`, `ftsStem` | `lib/src/db/fts_text.dart` | Words of a text for any index or search: Unicode letters and digits, lowercase, diacritics folded. Used by the metadata index, the fts5 tables and the time series text index. |
| `ftsBm25`, `ftsIdfFts5`, `ftsIdfPositive` | `lib/src/db/fts_text.dart` | BM25 scoring (SQLite fts5's order of operations, so the same doubles). |
| `ftsTermRange` | `lib/src/db/fts_text.dart` | The key range of a text component (exact or prefix) in keycodec keys: prefix scans over any index tree. |
| `ZxVirtualTableModule`, `ZxSql.registerModule` | `lib/src/db/sql/vtab.dart`, `zx_sql.dart` | A new `CREATE VIRTUAL TABLE ... USING x(...)` kind whose definition persists in the catalog (fts5 is the example: `lib/src/db/sql/fts5.dart`). |
| `ZxVtabContext.writableTree` | `lib/src/db/sql/vtab.dart` | Writes of a virtual table that a failed statement in an explicit transaction undoes. |

## zxdb from an application

| Code | Where | Reuse it for |
|---|---|---|
| `zxDbOpenFile`, `zxDbOpenMemory` | `lib/src/db/handle/zx_db.dart` (`package:zx/zxdb.dart`) | `ZxDb.open` with zxdb's desktop defaults: any application store, package:sqlite3-shaped (rows as maps, prepared statements that survive a compaction, transactions), one database per file per isolate, compaction by itself. |
| `zxPackBytes`, `zxUnpackBytes`, `zxLooksPacked` | `lib/src/format/zx/zx_pack.dart` (`package:zx/zxdb.dart`, `package:zx/zx.dart`) | One small file encrypted and compressed as a one-entry .zx in memory, synchronous: key files, settings, blobs kept beside a database. Pass `scryptLog2N: 1` when the password is already a random key. |
| `ZxDbStore.livePages` | `lib/src/db/engine/store.dart` | A database's live size for a byte budget (the file's length counts history until a vacuum). |
