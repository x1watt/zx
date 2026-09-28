# zxdb: the database built into every .zx archive (design, draft 1)

Status: being implemented. The storage engine, the KV stores (section 11)
and the system and metadata tables (section 10) are in; the SQL engine
is in progress.

Owner decisions (2026-09-28): the database lives inside `.zx` archives
with the files; key-value stores, long time series (logs) and per-file
metadata compatible with arca are core use cases; SHA-256 lookup and TLSH
similarity search are built into every archive and usable from SQL; the
language follows SQLite, with our own syntax where it is better; maximum
compression by default, with per-table choices.

## 1. What every archive gets

Every `.zx` archive can hold a database next to its files, in the same
container (new required feature bit `database`, catalog and pages as new
record and block types). Even an archive that never ran a SQL statement
exposes built-in system tables over its own entries, so these work on
any archive:

```sql
SELECT path, size FROM zx_files WHERE sha256 = x'9f86d0...';
SELECT path, tlsh_distance(tlsh, :t) AS d
  FROM zx_files WHERE tlsh_distance(tlsh, :t) < 60 ORDER BY d LIMIT 20;
SELECT path FROM zx_files AS OF '2026-09-01' WHERE path LIKE 'docs/%';
```

### 1.1 System tables (read-only views over the archive, no copy)

| Table | Columns (main) |
|---|---|
| `zx_files` | path, kind, size, packed, mtime, ctime, mode, sha256, tlsh, since_generation, method, encrypted |
| `zx_generations` | number, time, comment, added, deleted, packed |
| `zx_file_history` | path, generation, time, sha256, size, event (added/changed/deleted) |

`sha256` uses the archive's sorted SHA-256 table (binary search) and
`tlsh` the TLSH list; a TLSH band index (the digest split into bands,
each band a term, as arca's whitepaper Appendix C plans) makes
similarity queries sublinear.

### 1.2 Metadata tables (arca compatible, writable)

Arca today keeps per-file metadata in JSON sidecars next to each file
(`Name.arca.json`: format, file, size, sha256, sha1, mime, title,
description, tags, added, layers) plus `Name.<lang>.srt` subtitles and
previews named by SHA-256; its whitepaper plans screenshots with
captions, text layers of many kinds (OCR, transcripts, chapters,
lyrics...) and optional fingerprints (TLSH, PDQ, Chromaprint, MinHash).
zxdb gives these a home inside the archive:

| Table | Key | Columns |
|---|---|---|
| `zx_meta` | sha256 (plus path) | title, description, mime, sha1, added, tags (array), extra (JSON) |
| `zx_layers` | sha256, kind, language | kind (subtitles, transcript, ocr, caption, chapters, lyrics, description...), language, origin (machine/person/tool), tool, model, created, content (TEXT, full-text indexed) or content_ref (archive entry) |
| `zx_media` | sha256, kind, n | kind (screenshot, preview, gif, thumbnail, cover), caption, width, height, time_offset, content_ref or BLOB |
| `zx_fingerprints` | sha256, algorithm | algorithm (tlsh, pdq, chromaprint, minhash...), value, tool, created |

Metadata is keyed by SHA-256, like arca, so it follows the content
through renames and applies to every copy of the same bytes; `path`
joins through `zx_files`. Large media (screenshots, GIFs, subtitle
files) can be stored as rows (BLOB) or as archive entries referenced by
`content_ref`; both are deduplicated by the chunk store.

Arca interop:
- `zx sql x.zx ".import-arca DIR"` reads a folder's sidecars
  (`*.arca.json`, `*.<lang>.srt`, previews) into these tables, and
  `.export-arca DIR` writes them back next to extracted files, byte for
  byte in arca's manifest format (`arca-manifest/1`).
- Adding files from a folder with sidecars imports them automatically
  (option), so an arca collection packed into a `.zx` keeps everything.
- A `zx_fts` full-text index covers titles, descriptions, tags and layer
  text (subtitles are searchable, which arca does not do yet), with
  arca's prefixed terms (`tag:`, `transcript:`, `lang:`).

## 2. Three kinds of tables

### 2.1 Relational tables (SQLite-like)

Types with SQLite affinity (NULL, INTEGER, REAL, TEXT, BLOB) plus
BOOLEAN, DATETIME (ns), JSON and ARRAY as zx types. Primary keys,
secondary and unique indexes, NOT NULL, DEFAULT, CHECK. SQL: CREATE/
DROP/ALTER, INSERT (multi-row, ON CONFLICT), UPDATE, DELETE, SELECT
(joins, GROUP BY, HAVING, subqueries, DISTINCT, ORDER BY, LIMIT), CTEs,
transactions, PRAGMA, EXPLAIN QUERY PLAN; JSON functions like SQLite's
json1.

### 2.2 Key-value stores

```sql
CREATE KV STORE settings;                 -- keys and values are BLOB/TEXT
CREATE KV STORE cache WITH (ttl = '7d', compression = 'fast');
```

- Dart API that bypasses SQL for speed: `kv.get(key)`, `put`, `delete`,
  `scan(prefix / range)`, batches, `watch(prefix)` (stream of changes),
  optional TTL per store or per key.
- Stored as a B+tree with prefix-compressed keys; values over a threshold
  go to the chunk store (dedup).
- Also visible from SQL as a two-column table (`key`, `value`), so
  `SELECT * FROM settings WHERE key LIKE 'ui.%'` works.

### 2.3 Time series (logs, metrics, events)

```sql
CREATE TIMESERIES logs (
  ts DATETIME, level TEXT, source TEXT, message TEXT, fields JSON
) PARTITION BY DAY RETENTION '400d' WITH (compression = 'max');
```

- Append-optimised: rows are buffered, then sealed into per-partition
  column segments (one stream per column): delta-of-delta timestamps,
  dictionary-encoded repeated strings (levels, sources), and message
  text compressed with zcm, which already models text; logs are typically
  highly repetitive, so large ratios are expected.
- Queries by time range read only the partitions and columns they need
  (min/max per segment, bloom filters for tags); `ORDER BY ts` is free.
- Retention drops whole partitions; downsampling views
  (`CREATE ROLLUP ... EVERY '1h'`) keep aggregates of old data.
- Full-text index on message text (optional per series).
- Import from JSON lines, syslog/journald exports, CSV; arca's
  `events.jsonl` and circle logs are natural candidates.

## 3. Compression policy (maximum by default)

- Default for every table: `compression = 'max'`, taken from the archive
  settings (zcm auto: the best level that fits the machine's memory and a
  time budget).
- Per table (or per KV store / time series), set at creation or later:

```sql
CREATE TABLE notes (...) WITH (compression = 'balanced');
ALTER TABLE notes SET (compression = 'fast', page_size = '16k');
```

  Levels: `store`, `fast` (LZ4-class, point reads in microseconds),
  `balanced` (LZMA2 / zcm 1-3), `max` (zcm auto), `ultra` (zcm cmix
  preset, memory and time budget), or an explicit chain
  (`'zcm:level=7:mem=1g'`).
- To keep writes quick under `max`, new data lands in a small write
  buffer compressed with a fast codec and is folded into the max-
  compressed pages or segments at commit batches and at VACUUM (LSM
  style). Reads see both; the buffer size and fold schedule are
  settings. `VACUUM ULTRA` recompresses everything with the strongest
  settings when the user has time.
- Shared dictionaries per table are trained at VACUUM so small pages
  still compress well.

## 4. Transactions, versions, safety

- Every commit is a generation of the archive: copy-on-write pages, then a
  new Index and Footer; a crash keeps the previous commit (last valid
  footer). One writer, many readers on snapshots; a lock file coordinates
  processes and isolates. Group commit for many small writes.
- Time travel: `AS OF '2026-09-01'`, `AS OF GENERATION 42`, and
  `HISTORY OF table WHERE ...` for row history, on every table kind.
- VACUUM is the archive compaction (keeps N generations or everything
  since a date).
- Encryption, multi-volume and dedup apply to the database like to files.

## 5. SQL dialect

SQLite's language and behaviour where they fit (so existing SQL and
tools knowledge carry over); zx syntax where it is better: `CREATE KV
STORE`, `CREATE TIMESERIES ... PARTITION BY ... RETENTION`, `CREATE
ROLLUP`, `WITH (compression = ...)`, `AS OF`, `HISTORY OF`, functions
`sha256()`, `tlsh()`, `tlsh_distance()`, `similar(tlsh, n)` (table-valued
nearest neighbours), `fts_match()`, `zx_blob(path)` (read an archive
entry), `zx_add(path, blob)` (write one, inside the same transaction).
Documented in `docs/zxdb-sql.md` with each deviation from SQLite marked.

## 6. APIs and tools

- Dart: `ZxDatabase.open(archivePath, {password, readOnly})` (or
  `ZxArchive.database`), `execute`, prepared statements, typed rows,
  streaming cursors, transactions, `kv(name)`, `series(name)`; heavy
  work in a worker isolate, a synchronous API for CLI/server code.
- CLI: `zx sql x.zx "SELECT ..."` and an interactive shell (`zx sql x.zx`)
  with sqlite3-like dot commands (`.tables`, `.schema`, `.import`,
  `.export`, `.import-arca`, `.export-arca`, `.mode csv|json|table`).
- SQLite interop: import a SQLite file (its format is documented) and
  export to one.
- App: a "Data" view for archives with a database: tables, KV stores,
  time series (with a time chart), a query box, and per-file metadata
  (subtitles, screenshots, descriptions) shown in the file's
  properties and preview.

## 7. Performance targets (to measure against SQLite)

| Operation | Target (desktop, Dart AOT) |
|---|---|
| KV get, hot | < 10 us |
| KV put, batched | > 200k/s |
| Point select by key, hot | < 20 us |
| Log append, batched | > 500k rows/s into the buffer |
| Time range scan, sealed segments | > 200 MB/s logical |
| sha256 lookup in zx_files | < 50 us |
| TLSH similar-20 over 1M files | < 50 ms with the band index |
| Size vs SQLite (text/log heavy, max) | 5 to 20 times smaller |

## 8. Phases

1. Storage engine in the container: pages, copy-on-write B+tree, page
   map, commits as generations, snapshots, lock file, page cache, write
   buffer, a fast LZ4-class encoder.
2. System tables over archive entries (zx_files, generations, history),
   SHA-256 and TLSH band indexes; KV stores with their Dart API.
3. SQL parser, planner, executor (the SQLite subset + zx syntax), JSON
   functions, full-text index.
4. Metadata tables and arca import/export (sidecars, subtitles,
   previews), full-text over layers.
5. Time series: partitions, column segments, retention, rollups.
6. Compression policy per table, fold/VACUUM (incl. ULTRA), shared
   dictionaries, time travel queries.
7. CLI shell, SQLite import/export, app Data view.
8. Benchmarks vs SQLite; docs (`docs/zxdb-sql.md`, spec updates in
   `docs/zx-format.md`).

## 9. Decisions (owner, 2026-09-28)

1. Embedded only (no server mode). Several local processes can share one
   archive through the lock file.
2. Arca is not changed now; integration (arca using zxdb as its store)
   comes later. zxdb provides arca-compatible tables and import/export.

## 10. Implementation notes: system tables and metadata (phases 2 and 4)

Code: `lib/src/db/system/` (system tables, TLSH band index, functions,
SQL adapter) and `lib/src/db/meta/` (metadata tables, full-text index,
arca import/export). Tests: `test/zxdb_system_test.dart`,
`test/zxdb_meta_test.dart`, `test/zxdb_fts_test.dart`. Benchmark:
`tool/zxdb_bench_system.dart`. Reference of the tables and functions:
`docs/zxdb-sql.md`, section "System tables, metadata and search".

### 10.1 Virtual tables

The tables are written against a small interface of their own
(`system/sys_vtab.dart`, SQLite's xBestIndex / xFilter model: constraints
in, argvIndex / omit / idxNum / idxStr / cost out, a cursor per scan) and
adapted to the SQL engine's `sql/vtab.dart` by `system/sql_adapter.dart`
(`ZxSystemSql`), so they are testable without the SQL engine.

- `archive_view.dart` opens the archive once (`ZxArchiveReader`) and
  decodes the Index of a generation on first use (the last one always
  kept, 8 older ones in an LRU). Per Index it builds lazily: a path map
  (path = ?), a path-sorted order (ranges, `GLOB 'p*'`, `LIKE 'p%'` when p
  has no letters, `ORDER BY path`), and uses the archive's sorted SHA-256
  table (record 0x30; built from the entries when absent) for
  `sha256 = ?` by binary search.
- AS OF: a generation number, a date (the end of that day, minute or
  second in local time, as `-mversion`) or a time. Through SQL the scan's
  snapshot generation is used (a database commit is an archive
  generation).
- `zx_files.packed` is the entry's share of each block it uses (extent
  length over the block's unpacked size, times its packed size), so shared
  solid or dedup blocks are shared out; `method` is the chain name of its
  blocks; `encrypted` is 1 for entries with data in an archive with a KDF.
- `zx_file_history`: without a path, each generation is compared with the
  one before (entries whose since generation, attribute 0x76, is older are
  skipped without comparing). With `path = ?` it walks back from the last
  generation and jumps over the generations in which the content stayed
  the same (the since generation), as the timeline does. Events: added
  (path new), changed (new SHA-256, or without hashes a new since, size or
  kind), deleted (the deleted version's hash and size). A content written
  again unchanged gives no event.

### 10.2 TLSH band index

Scheme (`system/tlsh_index.dart`): the 32 body bytes of a digest (128
two-bit bucket codes) are cut into 16 bands of 2 bytes; a band value is a
term. Candidates are the digests sharing a band value with the query, or
(multi-probe level 1, the default) with one of the up to 16 variants of the
query's band in which one bucket moved by one step (a change that costs 1
in the distance). They are ranked by the exact distance, computed on a 35
byte binary form (header terms plus a 64 KiB byte-pair table, equal to
`tlshDistance`). TLSH's quartile coding keeps bucket values near uniform,
so a band value holds about N / 65536 digests.

- In memory, built per generation on first use: per band a counting sort
  of the digest numbers by band value (offsets[65537], ids[N]); about 100
  bytes per digest.
- Persisted when the archive has a database: trees `zx_tlsh_bands`
  (key [band][value][sha256], empty value), `zx_tlsh_digests` (sha256 to
  the 35 byte digest)
  and `zx_tlsh_state` (last generation indexed). Keyed by content, so one
  index serves every generation; AS OF filters the hits through the
  SHA-256 table of that generation. `ZxTlshStore.sync` adds the digests of
  content newer than the last generation indexed; `ZxSystemCatalog.
  beforeCommit` calls it. `similar()` uses the persisted form when it is
  up to date for the generation asked, the lazy one otherwise.
- An exact mode (`similar(q, n, 'exact')`) scans every digest with a
  per-query table of the distance of each 16-bit body word (16 lookups per
  digest).

Measured (`tool/zxdb_bench_system.dart`, AOT, this machine, 1M synthetic
digests: 1000 families of 20 near copies at 4 to 40 changed buckets, the
rest random; 100 queries, top 20):

| Operation | Time | Recall of the exact top 20 |
|---|---|---|
| band index build (in memory) | 156 ms, 102 MiB | |
| similar-20, bands, probe level 0 | 0.05 ms | 98.0% |
| similar-20, bands, probe level 1 (default) | 0.48 ms | 100.0% |
| similar-20, exact scan | 18.8 ms | 100% |
| similar-20, persisted index (memory store, 100k digests) | 0.64 ms | |
| zx_files WHERE sha256 = ? (100k files, through the table) | 2.0 us | |
| binary search in the SHA-256 table alone | 0.5 us | |
| zx_files WHERE path = ? | 2.4 us | |

Opening a 100k entry archive and decoding its Index took 0.5 s (paid
once per open).

### 10.3 Metadata tables

Stored through the storage contract as trees shaped like WITHOUT ROWID
tables (key: the primary key by `keycodec.dart`; value: the row by
`record.dart`), exposed to SQL as writable virtual tables so that every
write goes through `ZxMetaDb` and keeps the full-text index current in the
same transaction. `ZxMetaSchema.create(txn)` makes the trees; `.ddl`
gives the CREATE TABLE text for `.schema`.

Arca mapping (arca_core `LibraryFile.manifest()`, `Sidecars`,
`core_service.dart` `_placeSubtitles`): sha256 is the 32 byte BLOB (arca
writes hex); `added` and layer `created` keep arca's ISO 8601 text as
written; a manifest layer is one zx_layers row (n = its position, kind =
its `type`, file = the sidecar name, content = the sidecar text); unknown
keys, a key order or a null that is not arca's go to `zx_meta.extra` /
`zx_layers.attrs` (`$order`), and a manifest whose text still would not
come back identical (other whitespace) keeps it (`$raw`, used while the
rows still say the same). Subtitle files beside a file that its manifest
does not list are imported as layers with `$sidecar` (exported as files,
not listed). Previews `<sha256>.jpg|gif` become zx_media rows (kind
`preview` and `gif`, n 0, width and height read from the image).

Import / export are `arcaImport(db, dir, ...)` and `arcaExport(db, dir,
...)` in `meta/arca_io.dart`; manifests are written as arca does
(`JsonEncoder.withIndent('  ')`, a final newline, through a temporary
file and a rename), named by arca's rule (the stem, or the full name when
two files of a folder share a stem). The tests check byte identity on
fixtures and on this machine's real arca collections (read only).

### 10.4 Full-text index

`meta/fts.dart`: one document per file (SHA-256) from zx_meta (file name,
title, description, tags) and every zx_layers text (SRT / WebVTT cleaned
of cue numbers, times and tags). Trees `zx_fts_post` ((term, field,
sha256) to tf), `zx_fts_docs` (sha256 to the field lengths and the document's
terms, so a reindex deletes the old postings without re-reading
anything) and `zx_fts_stats` (per field document count and total length,
N, the stemming flag). BM25 (k1 1.2, b 0.75) per field with weights
(title and tag 3, name and tag words 2, description 1, chapters 0.8,
other layers 0.5, lang 0 as a filter). Incremental maintenance gives the
same trees as a rebuild (tested).

### 10.5 Wiring and open items

- SQL session: `ZxSystemSql(archive: ZxArchiveView.open(path), database:
  hasDb).register(sql.registerVirtualTable, sql.functions)`; at commit of a
  database transaction that writes an archive generation:
  `ZxTlshStore.sync(txn, archive)` (or `ZxSystemCatalog.beforeCommit`);
  on creating a database: `ZxMetaSchema.create(txn)`.
- The adapter maps the SQL engine's rowids to primary keys for UPDATE and
  DELETE (per statement). INSERT through the adapter does not replace:
  `INSERT OR REPLACE` needs the conflict mode in the vtab interface.
- The persisted band index is measured on the engine's B+tree in section
  11.3 (1M digests: 14 ms a query).
- The tokenizer folds Latin and Greek accents only; no phrase positions.

## 11. Implementation notes: storage engine and KV stores (phases 1 and 2)

Code: `lib/src/db/storage_api.dart` (the contract), `memory_store.dart`,
`engine/` (the store in the archive), `kv.dart`, `zxdb.dart`
(`ZxDatabase`), `zxdb_async.dart` (`ZxDatabaseAsync`),
`lib/src/format/zx/zx_lock.dart` (the writer lock),
`lib/src/codec/lz4/lz4_encode.dart`. Tests: `test/zxdb_store_test.dart`,
`test/zxdb_kv_test.dart`, `test/lz4_encode_test.dart`. Benchmark:
`tool/zxdb_bench.dart`. Format: `docs/zx-format.md` section 16;
architecture: `docs/architecture.md` section 17.

### 11.1 The contract, as implemented

- Keys are at most 1024 bytes (`zxMaxKeyLength`), compared as unsigned
  bytes (`zxCompareKeys`). `put` copies key and value; returned arrays
  must not be changed.
- A cursor of a tree of the write transaction follows the writes of that
  transaction: each step continues after the last key it returned, in the
  tree as it is then (the SQL engine can update the rows it scans).
- A transaction that wrote nothing commits nothing (it returns the
  generation it started from). `snapshot()` of a store without any
  generation gives generation 0, empty.
- `ZxMemoryStore` follows the same rules (one isolate: a second `begin`
  is busy at once); the engine's tests run the same contract tests on
  both and compare the engine with it under random operations.

### 11.2 Decisions taken while implementing

- **Pages by id, one page map per generation** (plan section 8, phase 1).
  A change to a leaf rewrites that leaf only; parents change on splits
  and merges. Fold and compaction move pages by rewriting map pages only.
- **Page blocks outside the block table.** Every Index holds the whole
  block table, so pages in it would make each commit write a table of
  every page ever written; pages are in blocks of their own type (7),
  located by the map, coded, checked and encrypted like data blocks.
- **Overflow values in overflow pages, deduplicated by whole value**
  (tree `zx$blob`, reference counts), instead of the archive's chunk
  store: extents into the block table would tie leaves to block numbers,
  which a compaction renumbers, so a compaction would have to rewrite
  every leaf holding a large value. With pages, a compaction only
  rewrites map pages. Values are not deduplicated against the files of
  the archive (open item).
- **Delta layer for random writes (LSM style, `engine/delta.dart`).** A
  tree of at least `lsmMinEntries` (64k) entries, or one that has runs,
  takes the writes of a transaction into a memtable (a sorted map in
  memory, `lsmMemBytes` at most before it is written). At commit the
  memtable goes into the tree directly when it has no runs and the
  writes are an append after its last key or at least 1/8 of its
  entries; otherwise it becomes a sorted run: a small B+tree of the same
  pages, written once and full, whose values are `0, value` or `1` (a
  deletion), recorded newest first in the tree's catalog record (version
  2, docs/zx-format.md 16.5). Reads merge memtable, runs and base (a get
  asks the runs newest first, then the base; a scan is a merge cursor
  that follows the writes of its transaction like TreeCursor). Runs of
  the same size class (a factor of 4) are merged when there are 8 of
  them, or when a tree has more than 20 runs (size tiered), and all of a tree's runs are folded into its base
  in one sorted pass when they exceed half of its entries, and at every
  `fold()` (so ZxDatabaseAsync folds them in its second isolate:
  `foldBacklogBytes` counts them) and vacuum. A fold writes each touched
  base page once. Every run is part of its generation's catalog, so
  snapshots and AS OF read them like pages. Puts are blind: they do not
  read the key (except that a key after the last key of a tree without
  runs is known to be new). The catalog record then marks the entry
  count as not exact (an upper bound, `ZxLengthEstimate.estimatedLength`,
  which the SQL planner uses); `length` settles it when asked (the
  delta's keys looked up in the base, in key order, cached by the
  snapshot, and written with the transaction's next commit), and a fold
  makes it exact. A delete still reads the key (it returns whether it
  was there). Each committed run has a Bloom filter (10 bits a key, built
  on first use from its keys, cached by the run's place in the file) so
  that a lookup skips the runs without the key. Pages of a sequential
  load are split at the right edge 7/8 to 1/8 instead of in the middle
  (appends leave full pages).
- **Incremental Index.** A database commit writes an Index with the
  records it changes and a reference to the last full Index (record
  0x4B, docs/zx-format.md 9.1.2) when that is less than half the size of
  the full one, and a full Index (a checkpoint) every
  `indexCheckpointCommits` (64) commits. Readers (the store, the
  archive reader, the pipe reader) resolve it with one more Index read;
  file updates and compactions write full Indexes, so the chain is never
  longer than one.
- **The write buffer is page based.** Pages of trees whose policy is not
  `store` or `fast` are written at commit with LZ4 and flagged; `fold()`
  codes them again with the tree's chain, in 256 KiB blocks (the unit of
  a cold read), by worker isolates, without the writer lock (the pages a
  commit changed meanwhile keep their new version). `max` is zcm at the
  level of zcm's automatic choice without a time budget (level 4) with
  its memory fitted to the machine; zcm decodes at the speed it encodes
  (about 85 KB/s at level 4), so a cold read of a `max` page costs up to
  a few seconds for a 256 KiB block; the page and block caches keep read
  pages decoded. KV stores are created `fast` by default for that reason.
- **Big transactions spill**: changed pages past `txnMemoryBytes` (128
  MiB) are written after the last Footer before the commit and read back
  through the cache; a rollback cuts them.
- **Commit hooks**, set by `ZxDatabase` on the store: a new database
  gets the metadata tables (`ZxMetaSchema.create`), and a commit brings
  the TLSH band index up to date (`ZxTlshStore.sync`) when a generation
  that added files came after the last one indexed (database commits add
  no files, so they do not open the archive view).
- **Flat pages in the cache**: a page read from the file keeps its full
  keys in one buffer and its inline values in another, with offsets (no
  object per entry); a get compares keys in place and returns a view of
  the value. The transaction changes list copies.
- **SQL wiring** (`ZxDatabase.sql`, `kv_sql.dart`): a `ZxSql` session with
  the system and metadata tables (`ZxSystemSql`), the KV stores as tables
  `name (key, value)` with a hidden `expires` column (TEXT when the bytes
  are UTF-8, else BLOB; key constraints narrow the scan), and the
  statements CREATE KV STORE (options `ttl`, `compression`, `page_size`),
  DROP KV STORE and VACUUM [ULTRA]. The commit hooks are the store's
  (`ZxDbStore.beforeCommit`), so SQL commits run them too.
- **Group commit** is a pending transaction of `ZxDatabase` (the writer
  lock is held while it is pending), committed when its window has
  passed (next write, a timer, `flush`, `close`).
- **Lock.** `<archive>.zx-lock` plus a marker per process for the
  isolates (dart:io's locks belong to the process); file updates and
  compactions of the zx handler take it when the archive has a database
  or the lock file exists.

### 11.3 Measured

AOT, Ryzen 7 3700X, 16 GB (shared), `tool/zxdb_bench.dart`, values of
about 150 bytes of JSON, `durable: false`:

| Operation | Result | Target (section 7) |
|---|---|---|
| KV get, 10k hot keys spread over 1M | 1.4 us (ZxTree.get: 1.1 us) | < 10 us |
| KV get, 100k hot keys spread over 1M | 2.6 us | |
| KV get, cold (caches dropped, LZ4 pages) | 133 us | |
| KV put, batches of 10k, ascending keys | 267k puts/s | > 200k/s |
| KV put, batches of 10k, random keys into 1M | 10.8k puts/s (1.3 GB before vacuum); with the delta layer 100k puts/s, 116 MiB | |
| KV put, 500k random keys into a 1M tree, batches of 10k | 161k puts/s (blind puts, 128 MiB page cache), file +28 MiB; the fold after them 5.3 s | 150k/s |
| 20k JSON records, 2.4 MiB: sqlite3 | 2,680 KiB | |
| same, zxdb fast / balanced / max | 638 / 272 / 158 KiB (4.2 / 9.9 / 17 times smaller) | 5 to 20 times (max) |
| 200k JSON records, 24 MiB: sqlite3 | 26,712 KiB | |
| same, zxdb fast / balanced | 6,374 / 2,711 KiB (4.2 / 9.9 times smaller) | |
| TLSH band index, 100k digests added in commits of 10k | 13.1 s (130k keys/s), 333 MiB before vacuum | |
| TLSH band index, 1M digests sorted in one transaction | 37 s (457k keys/s), 601 MiB | |
| TLSH similar-20 over the persisted 1M index | 14 ms warm, 19 ms cold (100 of 100 near duplicates found) | < 50 ms |

sqlite3 3.45.1, `CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT)
WITHOUT ROWID`, one transaction, then VACUUM; zxdb sizes after fold and
vacuum. The page size is 16 KiB, the page cache 128 MiB. The LZ4 encoder
codes about 100 MB/s of text (single probe) and decodes at 6.7 GB/s; zcm
level 4 codes and decodes about 85 KB/s. Earlier numbers before the flat
pages (one `Uint8List` per key and value in the cache): 50 us for 100k hot
keys of 1M, 76 ms for a TLSH query; 4 KiB pages give 2.1 us for 100k hot
keys of 1M, but slower cold reads (90 us) and appends.

### 11.4 Open items

- Random writes into a large tree go through the delta layer (11.2).
  Runs are built by TreeWriter puts and merged runs are written again
  about log8(delta / batch) times; a bulk page builder would make both
  cheaper. `length` of a tree with blind puts costs a base lookup per
  delta key until the next fold.
- An autocommit statement costs about 1 ms (a generation: page blocks,
  map pages, Index, Footer, file reopened for append); sqlite3 takes 85
  us with synchronous=OFF. Group commit is the answer for many small
  writes.
- The full Index still holds the whole generation list, so a checkpoint
  every 64 commits writes it (about 40 bytes a generation); incremental
  Indexes hold only the generations since their base.
- Shared dictionaries per tree (section 3): measured, not kept. Priming
  with a dictionary of the tree's own pages (measured as the coded size
  of dictionary plus block less that of the dictionary, JSON records)
  makes 4 KiB blocks 15% (LZ4) to 35% (LZMA2) smaller and 16 KiB blocks
  5 to 15% smaller, but the blocks zxdb writes are 64 KiB at commit and
  256 KiB at fold, where the gain is 1.6 to 4% (64 KiB) and 0.4 to 1.4%
  (256 KiB): not worth a preset dictionary in the format and the
  encoders.
- Overflow values are not deduplicated against file content or by chunks
  (only whole values).
- The TLSH band index: the persisted form's query reads the 35 byte
  digest of each candidate by a point lookup (about 4000 per query at 1M
  digests); storing the digest as the value of the band keys would make
  a query a set of range scans. Adding digests in random order rewrites
  most leaves of the band tree at each commit (see the first item):
  sorting a batch's keys before adding them, or adding them in large
  batches, helps.
- A cold read decodes a whole page block (64 KiB at commit, 256 KiB after
  a fold with zcm): a `max` tree that does not fit in the caches reads
  slowly (zcm decodes at about 85 KB/s at level 4).
- The SQL session (`ZxDatabase.sql`) sees the archive's files as they
  were when it was made (`resetSql`); SQL writes to KV stores are not
  seen by `watch`.


## 12. Implementation notes: time series (phase 5)

Code: `lib/src/db/ts/` (`ts_codec.dart` the column encodings,
`ts_store.dart` definitions, buffer, seal, retention and the scan,
`ts_rollup.dart`, `ts_sql.dart` the SQL tables and statements,
`ts_api.dart` the Dart API, `ts_import.dart` the importers). Tests:
`test/zxdb_ts_test.dart`. Benchmark: `tool/zxdb_bench_ts.dart`. SQL:
`docs/zxdb-sql.md`, "Time series".

### 12.1 Layout

Every structure is a tree of the storage contract, so snapshots, AS OF,
transactions and the write buffer of the store apply unchanged:

- `zx$ts`: the definitions (JSON by name) and per series its counters
  (next buffer block, next segment id, buffered rows and blocks).
- `ts:<name>:buf` (`fast`, 64 KiB pages): appended rows in blocks of
  about 12 KiB (count, time range, then per row the time as a zigzag
  varint and the tagged values of the other columns). Blocks stay inline
  in the leaves: an overflow value would be hashed for deduplication at
  every put. Row by row INSERTs make tiny blocks; past 1024 of them they
  are written again as big ones.
- `ts:<name>:dir` (`fast`): key (partition start, segment id), value the
  segment header: rows, time range, bytes per column, a Bloom filter per
  tag column (10 bits per distinct value, 4 probes).
- `ts:<name>:seg` (`store`: already coded): key (segment id, column),
  value the column blob.
- `ts:<name>:fts` (`fast`): key (segment id, term), value the rows of the
  segment holding the term (varint deltas). Keyed by segment first, so a
  segment's postings go with one range delete, and a query looks the
  words up in the segments it reads.
- `zx$rollup` and `rollup:<name>` (key (bucket, group values) with
  `keycodec.dart`, value the aggregate states).

### 12.2 Column encodings

One blob per column and segment (`ts_codec.dart`): a kind, the row
count, a null bitmap when some values are NULL, then sections. The time
column: delta of delta, zigzag varints. Integers: deltas, zigzag
varints. Floats: XOR with the previous value's bits, byte aligned (a
control byte gives the leading and trailing zero bytes, then the
meaningful bytes), which keeps Gorilla's idea without a bit writer.
Strings: a dictionary per segment when it has at most a quarter as many
distinct values as rows (or at most 16), else plain; the text of either
is joined with newlines when no value holds one (the form context models
like best), else length prefixed. Mixed types (an int among texts, a
BLOB) use tagged values. The kind is chosen per column and segment from
the values, so every value comes back with its type (an INTEGER column
may hold 3 and 3.0 apart).

Text sections (plain text, dictionaries, tagged values) are coded with
the series' compression chain (`zxDbChainFor`, `max` = zcm by default);
number and index sections with LZ4. A section keeps its raw form when
coding does not save bytes. The seal codes the big text sections in
worker isolates (`SyncJobPool`, as many as fit in the memory limit), the
small ones inline.

### 12.3 Seal, order, retention

`seal()` (also at VACUUM, `ZxDatabase.sealAllSeries`, and at an append
that leaves `seal_rows` rows buffered) reads the buffer, gives the rows
to the rollups, drops the rows of partitions past the retention, groups
the rest by partition, merges each partition's last segment when it has
fewer than half of `segment_rows`, sorts by time (stable) and writes
segments of at most `segment_rows` rows with new ids. Then partitions
whose end is before now minus the retention lose their segments.

The row order of a scan is time, then append order: segment ids grow
with seals and only the last segment of a partition is merged with newer
rows, so (time, segment id, row) is that order, and buffered rows come
after sealed rows of the same time. A scan builds each partition's row
list (per segment the time range by binary search, the full-text and
equality filters), and sorts it only when the sources overlap in time.

Decoded columns are kept in a process wide LRU cache (256 MiB by
default, `zxTsCacheBudget`), keyed by the series' random uid, the segment
id and the column: a segment never changes once written and ids are not
reused, so the cache needs no invalidation, and AS OF snapshots share it.

The hot tier (option `hot_days`, 1 by default, `ZxTsDef.hotDays`): a
cold read of zcm text runs at zcm's decode speed, so the seal also
writes, for segments of partitions that end less than `hot_days` before
now, each column with coded text sections again with those sections
coded by LZ4 (number and time sections are LZ4 already and are shared),
into `ts:<name>:hot` (`store`, keyed as the segment tree). Scans and
merges read the hot copy when there is one (same decoded values, same
cache key). Each seal (so also VACUUM) deletes the copies of partitions
that aged out, and every segment delete (merge, retention) deletes its
copy. Series with `fast` or `store` text keep no copy. Measured
(`tool/zxdb_bench_ts.dart --rows 200000 --levels max --hot 1`, 29.3 MiB
of synthetic log text over 1.2 days, all of it in the hot window): a
cold read of the last day, all columns, runs at 0.16 MB/s of raw text
without the copy (about 150 s for the day) and 156 MB/s with it; the
copy takes 3.5 MiB, about the size of the max segments of the same days
(3.6 MiB). So the copy roughly doubles the bytes of the hot days only:
with one day hot and a retention of months that is a few tenths of a
percent more, against reads of recent data that are about 1000 times
faster after a restart. That is why it is on by default with one day.

### 12.4 SQL wiring

`zxTsRegisterSql` (from `ZxDatabase.sql`) resolves series and rollups by
name at the statement's snapshot and registers the four statements. The
planner now passes ORDER BY terms to virtual tables (`ZxIndexInfo
.orderBy`) and skips the sort when `orderByConsumed` is set; a series
consumes `ORDER BY ts [DESC]`, a rollup `ORDER BY ts [DESC]`. The parser
takes `ON series` in CREATE ROLLUP and name lists in options (`tags =
(a, b)`).

Rollups (`ts_rollup.dart`): a WHERE that is not an AND of simple
comparisons is stored as SQL text and compiled per read or seal with
the SQL planner against the series' columns (`sql/row_expr.dart`:
`ZxRowExpr`, one source of plain rows, no store). A read aggregates the
buffered rows of its range (the block headers skip the others) into
(bucket, group) states, sorts them by key and merges them with the
stored states in one pass (both are in key order, either direction).

Async (`zxdb_async.dart`, `ZxDatabaseAsync.series(name)` /
`ZxSeriesAsync`): `createSeries`, `dropSeries`, `seriesNames`,
`sealAllSeries`, `appendAll`, `seal`, `stats`, `scanBatches` and
`query`. An appendAll is one message and one worker transaction, packed
by column: integer columns as an Int64List, float columns as a
Float64List (null bitmaps when needed; 64 KiB and more go as
TransferableTypedData), other columns (texts) as a List. Measured with
200k log rows (time, host, latency, int, 80 char message): the caller's
isolate spends 70 to 85 ms packing and sending against 90 to 110 ms for
sending the row Lists as they are; the worker spends about 100 ms
rebuilding rows, off the UI isolate. Joining the texts into one String
was slower (35 ms for the join alone; a List of Strings copies in 5 to
7 ms). A scan is a cursor in the worker (it keeps the snapshot of its
start); `scanBatches` asks for one batch at a time and only while the
Stream is not paused, so a slow listener holds one batch in flight;
cancel closes the cursor.

Time comparisons (`sql/value.dart`, `sql/eval.dart`): DATETIME columns
of virtual tables get the comparison affinity `Affinity.timeNs` (plain
tables keep NUMERIC). Comparisons wrap the other operand in `TimeNsEv`,
which parses date/time text to ns and scales `unixepoch()` seconds and
`julianday()` days (a unit carried by `Ev.timeUnit` through `+` and `-`
with a plain number); the planner hands that wrapped value to the table
as the constraint, so pruning and the executor's test see the same ns.
`BETWEEN` on a virtual table column is passed as `>=` and `<=`.
`Ev.declType` carries the declared type of column references through
views and subqueries into `ZxSqlResult.types`.

HISTORY OF a series (`ZxHistoryVirtualTable` in `sql/vtab.dart`,
implemented by `ZxTsSqlTable`): generation by generation, the segment
directory (ids per partition) and the raw buffer blocks are compared
with the previous generation; only partitions whose segments or buffered
rows changed are read at both generations and their rows diffed as
multisets. New rows are appends; rows gone are one retention row per
partition. Seals and block rewrites move rows without changing the
multiset, so they give nothing.

### 12.5 Open items

- A cold read of a `max` (zcm) text column older than the hot tier
  (12.3) decodes at zcm's speed (about 0.16 MB/s of raw log text); scans
  of time and number columns do not touch the text sections.

### 12.6 Measured

See docs/performance.md, "zxdb time series": 1M synthetic log lines
append at 480k to 530k rows/s into the buffer; archives are 4.9x
(fast), 7.1x (balanced) and 8.6x (max) smaller than sqlite3; journald
JSON with every field is 18.8x smaller than sqlite3 and 1.8x smaller
than zstd -19 of the export (balanced). Scans of sealed segments: 600
to 900 MB/s of raw text warm, 100 to 140 MB/s cold with LZ4 or LZMA2
text, over 600 MB/s for time and number columns.
