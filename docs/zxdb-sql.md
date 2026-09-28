# zxdb SQL reference

The SQL language of zxdb (docs/zxdb-design.md). Sections are kept by
the module that implements them.

## System tables, metadata and search

Tables and functions that every database session gets from the system
layer (`lib/src/db/system/`, `lib/src/db/meta/`; design notes in
`docs/zxdb-design.md` section 10). All are virtual tables: they read the
archive or their own trees, and they take `AS OF` like any table.

### zx_files (read-only, every archive)

| Column | Type | Meaning |
|---|---|---|
| path | TEXT | entry path, `/` separated |
| kind | TEXT | file, dir, symlink, hardlink, chardev, blockdev, fifo, socket |
| size | INTEGER | bytes of content |
| packed | INTEGER | the entry's share of the packed bytes of its blocks |
| mtime, ctime | DATETIME | ns since 1970 UTC (NULL when not stored) |
| mode | INTEGER | POSIX permission bits (NULL when not stored) |
| sha256 | BLOB | 32 bytes (NULL in the clear Index of an encrypted archive) |
| tlsh | TEXT | TLSH digest, `T1` and 70 hex digits (NULL for small or uniform files) |
| since_generation | INTEGER | the generation that wrote this content |
| method | TEXT | the coder chain(s) of its blocks |
| encrypted | INTEGER | 1 when its data is encrypted |

Fast plans: `sha256 = ?` (binary search in the archive's SHA-256 table),
`path = ?`, path ranges, `path GLOB 'dir/*'`, `path LIKE 'dir/%'` (when
the prefix has no letters), `ORDER BY path`; `since_generation`
comparisons are applied during the scan.

```sql
SELECT path, size FROM zx_files WHERE sha256 = x'9f86d081...';
SELECT path FROM zx_files AS OF '2026-09-01' WHERE path GLOB 'docs/*';
SELECT path FROM zx_files WHERE since_generation > 40;
```

### zx_generations (read-only)

number, time (DATETIME), comment, added, deleted, packed: one row per
generation (docs/zx-format.md 9.1). Plans on `number`.

### zx_file_history (read-only)

path, generation, time, sha256, size, event (`added`, `changed`,
`deleted`): every change of every path, oldest first. `path = ?` walks
only the generations in which that file changed; `generation = ?`
compares one generation with the one before. A deleted row carries the
hash and size of the version deleted. Rewriting the same content gives no
row.

```sql
SELECT generation, time, event FROM zx_file_history WHERE path = 'notes.txt';
SELECT path, event FROM zx_file_history WHERE generation = 42;
```

### similar(query, n [, mode]) (table-valued)

The n files nearest to `query` by TLSH distance, nearest first: columns
path, sha256, tlsh, distance. `query` is a TLSH digest, a path of the
archive (that entry is left out) or a SHA-256 BLOB. `mode`: omitted or
`'band'` uses the band index (approximate, recall about 100% in tests),
`'exact'` scans every digest, a number is a maximum distance. zx
deviation: SQLite has no such function.

```sql
SELECT path, distance FROM similar('docs/report.pdf', 20);
SELECT path, distance FROM similar(:digest, 50, 80);
```

### Scalar functions

| Function | Result |
|---|---|
| `sha256(x)` | 32 byte BLOB of a BLOB (TEXT is hashed as UTF-8) |
| `tlsh(x)` | TLSH digest TEXT, NULL for input under 50 bytes or too uniform |
| `tlsh_distance(a, b)` | INTEGER distance, NULL when a digest does not parse |
| `fts_match(sha256, query)` | 1 when the file matches the full-text query, else 0 |

### Metadata tables (writable, databases only)

Arca-compatible, keyed by content (SHA-256 BLOB), so metadata follows the
bytes through renames and applies to every copy; join to `zx_files` on
`sha256`.

| Table | Primary key | Other columns |
|---|---|---|
| zx_meta | sha256 | path, size, title, description, mime, sha1 (hex), added (ISO 8601 text), tags (ARRAY), extra (JSON) |
| zx_layers | sha256, n | kind, language, origin, tool, model, created, file, content (TEXT), content_ref, attrs (JSON) |
| zx_media | sha256, kind, n | caption, width, height, time_offset (REAL, seconds), mime, content_ref, data (BLOB) |
| zx_fingerprints | sha256, algorithm | value, tool, created |

- `zx_layers.kind`: subtitles, transcript, ocr, caption, chapters, lyrics,
  description, text...; `n` orders the layers of a file (arca's list
  order). `file` is the sidecar file name (`Talk.en.srt`), `content` its
  text, `content_ref` an archive path holding it.
- `zx_media.kind`: preview (a still, arca's `<sha256>.jpg`), gif (arca's
  animated preview), screenshot, thumbnail, cover.
- `extra` and `attrs` keep what arca's format has beyond the columns, so
  export is byte for byte; keys starting with `$` are zx bookkeeping.
- Writes keep the full-text index up to date in the same transaction.

```sql
SELECT f.path, m.title FROM zx_files f JOIN zx_meta m ON m.sha256 = f.sha256;
SELECT language, tool FROM zx_layers WHERE sha256 = :h AND kind = 'subtitles';
```

Shell: `.import-arca DIR` and `.export-arca DIR` (library functions
`arcaImport` / `arcaExport` in `lib/src/db/meta/arca_io.dart`) read and
write arca's `*.arca.json` manifests (`arca-manifest/1`), `<name>.<lang>.srt`
subtitles and `previews/<sha256>.jpg|gif`.

### fts_search(query, n) (table-valued)

The n best files for a full-text query, best first: columns sha256, path,
title, score (BM25, higher is better).

Query language: words are ANDed; `a OR b`; `-word` excludes; `word*` is a
prefix; `"a b"` ANDs its words (no positions); `field:word` limits a word
to a field: `name`, `title`, `description`, `tag` (whole tags:
`tag:dipole-antenna`), `subtitles`, `transcript` (transcripts, subtitles
and captions), `ocr`, `caption`, `chapters`, `lyrics`, `text`, `layer`
(any layer), `lang` (a filter: files with a layer in that language;
`lang:pt` matches `pt-BR`). Words are lowercased with Latin and Greek
accents folded, so `estacao` also finds the accented spelling.

```sql
SELECT path, score FROM fts_search('antenna tag:aprs -draft', 20);
SELECT path FROM zx_files WHERE fts_match(sha256, 'transcript:digipeater');
```

## The SQL language and engine

The engine (`lib/src/db/sql/`, entry point `ZxSql` in `zx_sql.dart`)
follows SQLite 3.45: its syntax, its type rules (storage classes,
affinity, comparison), its NULL handling and its functions. Where zxdb
differs, the text says **Deviation**. A differential test
(`test/zxdb_sql_test.dart`) runs the same scripts on zxdb and on the
`sqlite3` shell and compares the results: a fixed list of queries and
write scripts, several thousand random expressions over values of every
storage class, and random queries that exercise the planner (indexes,
joins, IN, ranges, ORDER BY with LIMIT).

### Dart API

```dart
final sql = ZxSql(store);                  // any ZxStore
sql.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
final r = sql.execute('INSERT INTO t (name) VALUES (?), (?)', ['a', 'b']);
r.changes;                                 // 2
r.lastInsertRowid;                         // 2
sql.execute('SELECT * FROM t WHERE id = :id', {'id': 1}).rows;
final st = sql.prepare('SELECT name FROM t WHERE id > ?');
final cur = st.query([0]);                 // streaming cursor
while (cur.moveNext()) print(cur.current);
cur.close();                               // releases its snapshot
```

- `execute(sql, [params])` runs one or more statements and returns the
  result of the last: `columns`, `rows`, `changes`, `lastInsertRowid`
  (`maps` and `scalar` are conveniences).
- `prepare(sql)` parses once; `execute`, `query` (streaming) and `select`
  bind parameters per call. Parsed text is also cached by `execute`.
- Parameters: `?`, `?NNN`, `:name`, `@name`, `$name`, bound from a List
  (by position) or a Map (by name, with or without the prefix
  character). Dart values map to SQL values as follows: null, int,
  double, String and Uint8List as themselves, `List<int>` as BLOB, bool
  as 1 or 0, DateTime as ns since the epoch (zx DATETIME), other Lists
  and Maps as JSON text.
- Errors are `ZxDbException` with a kind: `syntax`, `constraint`,
  `unsupported`, `busy`, `readOnly`, `notFound` or `generic`. Messages
  are SQLite's (`no such table: t`, `UNIQUE constraint failed: t.a`).
- Transactions: without BEGIN every statement is atomic on its own (a
  snapshot for reads, one write transaction, and so one archive
  generation, per writing statement). `BEGIN ... COMMIT` spans one write
  transaction and one generation; `ROLLBACK` discards it. A statement
  that fails inside an explicit transaction is undone on its own and the
  transaction stays open, as in SQLite. A streaming cursor outside a
  transaction reads its own snapshot until it is closed.
- Session state: `lastInsertRowid`, `changes`, `totalChanges`,
  `inTransaction`; `close()` rolls back an open transaction.

### Extension points

- Functions: `sql.functions.scalar(ZxScalarFunction(...))`,
  `sql.functions.addScalar(name, nArgs, fn)` and
  `sql.functions.aggregate(ZxAggregateFunction(...))`. A function gets a
  `ZxFunctionContext`: the statement time, the snapshot or transaction,
  and whether each argument carries the JSON subtype.
- Virtual tables: `sql.registerVirtualTable(name, table)` and
  `sql.addVirtualTableResolver(fn)`; the interface (`ZxVirtualTable`,
  best index negotiation, cursors, table-valued functions, writable
  tables with conflict modes) is documented in
  `lib/src/db/sql/vtab.dart`. The system tables above are built on it.
- zx statements: `sql.registerStatementHook(kind, hook)` for
  `CREATE KV STORE`, `DROP KV STORE`, `CREATE TIMESERIES`,
  `DROP TIMESERIES`, `CREATE ROLLUP`, `DROP ROLLUP` and `VACUUM`. The
  hook receives the parsed statement and the write transaction (none for
  VACUUM). Without a hook these statements fail with
  `ZxDbException(unsupported)`, "... is not yet supported".

### Types

The storage classes are SQLite's: NULL, INTEGER (64-bit), REAL, TEXT
(UTF-8) and BLOB. Column affinity follows SQLite's rules from the
declared type (INT: INTEGER; CHAR, CLOB, TEXT: TEXT; BLOB or no type:
BLOB; REAL, FLOA, DOUB: REAL; anything else: NUMERIC), and so do
conversions on storage, comparison affinity, `CAST` and arithmetic
(integer overflow gives a REAL; division by zero gives NULL).

zx types (**Deviation**: SQLite has no such types):

| Declared type | Affinity | Stored as | Checks and conversions |
|---|---|---|---|
| BOOLEAN, BOOL | NUMERIC | INTEGER 0/1 | text 'true' / 'false' (any case) become 1 / 0 |
| DATETIME, TIMESTAMP | NUMERIC | INTEGER, ns since 1970 UTC | date/time text (the formats of `datetime()`, up to 9 fraction digits) is converted to ns; a REAL is rounded |
| JSON | TEXT (SQLite would give NUMERIC) | TEXT | must be valid JSON, else a constraint error; BLOB is refused. Values read from a JSON column carry the JSON subtype, so `json_object('d', col)` embeds them |
| ARRAY | TEXT | TEXT, a JSON array | must be a JSON array |

`zx_datetime(ns)` renders a DATETIME value as
`YYYY-MM-DD HH:MM:SS.nnnnnnnnn`; `zx_ns(timevalue, modifiers...)` gives
ns for any time value of the date functions.

### Statements

- `CREATE TABLE [IF NOT EXISTS] name (columns, constraints) [WITH (options)]`
  and `CREATE TABLE name AS SELECT`. Column constraints: PRIMARY KEY
  [ASC|DESC] [AUTOINCREMENT], NOT NULL, UNIQUE, DEFAULT (literal or
  expression), CHECK, COLLATE, REFERENCES (parsed, not enforced), each
  with ON CONFLICT. Table constraints: PRIMARY KEY, UNIQUE, CHECK,
  FOREIGN KEY (parsed, not enforced). `INTEGER PRIMARY KEY` is the rowid;
  other primary keys are enforced by an automatic unique index
  (`sqlite_autoindex_<table>_<n>`), as in SQLite.
- `WITH (key = value, ...)` table options (**Deviation**): `compression`
  ('store', 'fast', 'balanced', 'max', 'ultra' or a .zx chain) and
  `page_size` (bytes or '16k'); they become the `TreeOptions` of the
  table's and its indexes' trees. Other keys are kept in the catalog for
  other modules. `ALTER TABLE t SET (options)` changes them.
- `CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON t (col [COLLATE c] [ASC|DESC], ... | expr) [WHERE ...]`,
  `DROP INDEX`, `CREATE VIEW [(columns)] AS select`, `DROP VIEW`,
  `DROP TABLE [IF EXISTS]`.
- `ALTER TABLE t RENAME TO n`, `RENAME [COLUMN] a TO b`,
  `ADD [COLUMN] def`, `DROP [COLUMN] c` (not for key, unique or indexed
  columns), `SET (options)`.
- `INSERT [OR REPLACE|IGNORE|ABORT|FAIL|ROLLBACK] INTO t [(cols)] VALUES (...), (...) | SELECT ... | DEFAULT VALUES`,
  `REPLACE INTO`, upserts `ON CONFLICT [(cols)] DO NOTHING | DO UPDATE SET ... [WHERE ...]`
  (several clauses allowed, `excluded.col` is the proposed row), and
  `RETURNING`.
- `UPDATE [OR ...] t SET col = expr, (a, b) = (x, y) [FROM ...] [WHERE ...] [RETURNING ...]`,
  `DELETE FROM t [WHERE ...] [RETURNING ...]`.
- `SELECT [DISTINCT] ... FROM ... [WHERE] [GROUP BY] [HAVING] [ORDER BY ... [ASC|DESC] [NULLS FIRST|LAST]] [LIMIT n [OFFSET m] | LIMIT m, n]`,
  joins (`JOIN`, `INNER`, `LEFT [OUTER]`, `CROSS`, comma, `NATURAL`,
  `USING`), subqueries (scalar, `IN`, `EXISTS`, in FROM), compound
  `UNION`, `UNION ALL`, `INTERSECT`, `EXCEPT`, `VALUES` as a query,
  `WITH [RECURSIVE]` common table expressions, `INDEXED BY` and
  `NOT INDEXED`, table-valued functions in FROM (arguments may refer to
  tables to their left), row values in `=`, `<>`, `IS` and `SET`.
- `BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE] [TRANSACTION]`, `COMMIT` / `END`,
  `ROLLBACK`.
- `PRAGMA`: `table_info`, `table_xinfo`, `index_list`, `index_info`,
  `table_list`, `user_version` (read and set), `schema_version`,
  `database_list`, `integrity_check` (always 'ok'), `function_list`,
  `journal_mode` ('zx'), `foreign_keys` (0), `encoding`. Other pragmas are
  accepted and do nothing, as SQLite does with unknown ones.
- `EXPLAIN QUERY PLAN stmt`: rows (id, parent, notused, detail) in
  SQLite's wording (`SCAN t`, `SEARCH t USING INDEX i (a=?)`,
  `SEARCH t USING COVERING INDEX i (a>?)`,
  `SEARCH t USING INTEGER PRIMARY KEY (rowid=?)`,
  `SEARCH t USING AUTOMATIC COVERING INDEX (b=?)`,
  `USE TEMP B-TREE FOR ORDER BY`, `SCALAR SUBQUERY`, `MATERIALIZE x`...).
  **Deviation**: plain `EXPLAIN` also returns the query plan (there is no
  bytecode).
- `ANALYZE` and `REINDEX` are accepted and do nothing.
- `sqlite_schema` (also `sqlite_master`, `zx_schema`) lists tables,
  indexes and views with their SQL. **Deviation**: the `rootpage` column
  holds the name of the storage tree.

zx statements (**Deviation**, passed to hooks):

```sql
CREATE KV STORE [IF NOT EXISTS] name [WITH (ttl = '7d', compression = 'fast')];
CREATE TIMESERIES [IF NOT EXISTS] logs (ts DATETIME, level TEXT, message TEXT)
  PARTITION BY DAY RETENTION '400d' [WITH (compression = 'max')];
CREATE ROLLUP [IF NOT EXISTS] name [(cols)] [ON series] [EVERY '1h'] [RETENTION '...'] [WITH (...)]
  AS SELECT ... [EVERY '1h'];
DROP KV STORE | TIMESERIES | ROLLUP [IF EXISTS] name;
VACUUM [ULTRA];
```

### Time series (**Deviation**)

A time series is an append-only table of rows with a time, stored in
column segments per time partition (docs/zxdb-design.md sections 2.3 and
12). `ZxDatabase.sql` knows them; the Dart API is `db.series(name)`.

```sql
CREATE TIMESERIES [IF NOT EXISTS] logs (
  ts DATETIME, host TEXT, level TEXT, message TEXT, fields JSON, latency REAL
) PARTITION BY HOUR | DAY | WEEK | MONTH   -- default DAY
  RETENTION '400d'                          -- optional: ms, s, m, h, d, w, y
  WITH (compression = 'max', fts = on, tags = (host, level));
DROP TIMESERIES [IF EXISTS] logs;           -- its rollups too
```

- The time column is the DATETIME column named `ts`, else the first
  DATETIME column; its values are ns since 1970 UTC (INTEGER). Rows
  without a time are refused. Column types convert values as for tables
  (DATETIME text to ns, JSON objects to text, BOOLEAN to 0/1); a column's
  values keep their own types otherwise.
- Options: `compression` (of the text columns and dictionaries: `store`,
  `fast`, `balanced`, `max` (the default, zcm), `ultra` or a chain),
  `fts = on` (a full-text index on the column `message`, else the first
  TEXT column) or `fts = column`, `tags = (col, ...)` (a Bloom filter per
  segment and tag column), `segment_rows` (131072), `seal_rows`
  (1048576: an append or INSERT that leaves this many rows in the write
  buffer seals it) and `hot_days` (1; 0 or `off` disables it; a number
  of days or a duration such as `'36h'`): the hot tier, an LZ4 copy of
  the text columns of the partitions that ended less than that many days
  ago, which scans read instead of the slow coded text. It applies only
  when `compression` is slower than LZ4 (not `fast` or `store`); the
  copies go when their partition ages out (at each seal and at VACUUM,
  relative to the clock) and with their segment.
- `INSERT` appends to the write buffer. `UPDATE` and `DELETE` fail: rows
  go by retention (whole partitions, at each seal and at VACUUM, relative
  to the clock) or with `DROP TIMESERIES`.
- `SELECT` reads the sealed segments and the write buffer. Constraints
  `ts =, <, <=, >, >=`, `ts BETWEEN a AND b` and `ts IN (...)` choose the
  partitions and segments read. The value may be ns, date/time text
  (`'2026-09-01'`, `'2026-09-01 10:00'`, `'2026-09-01T10:00:00.5Z'`,
  `'...+02:00'`, the result of `datetime('now', '-1 day')`), or the result
  of `unixepoch(...)` (seconds) or `julianday(...)` (days), also plus or
  minus a number (`unixepoch('now') - 86400`): see "DATETIME columns of
  virtual tables" below. `zx_ns(...)` still works.
  `tag = value` skips the segments whose Bloom filter excludes the value.
  `ORDER BY ts` or `ORDER BY ts DESC` is the scan's own order (no sort).
  Only the columns the query uses are decoded.
- Full-text search: the hidden column `search`, `WHERE search = 'timeout
  upstream'`: rows whose indexed column holds every word (`word*` matches
  a prefix; words are folded like the metadata full-text index: lower
  case, accents removed).
- `FROM logs AS OF ...` reads the series as it was. `FROM HISTORY OF
  logs` yields, per generation, the rows it appended (`zx_op = 'append'`,
  in time order) and one row per partition it dropped by retention
  (`zx_op = 'retention'`: `ts` is the partition start, `zx_rows` the rows
  dropped, the other columns NULL), with the columns of the series, then
  `zx_generation`, `zx_time`, `zx_op` and `zx_rows` (1 for an append).
  Seals move rows without changing them and give no rows. It reads the
  partitions that changed between consecutive generations, so it is
  meant for audits, not for big series with many generations.

DATETIME columns of virtual tables (**Deviation**): the time column of a
series, a rollup's `ts` and the DATETIME columns of the system tables
hold ns and have the comparison affinity DATETIME. In a comparison
(`=`, `<>`, `<`, `<=`, `>`, `>=`, `IS`, `BETWEEN`, `IN`) with such a
column the other operand is converted to ns first: date/time text in the
formats of `datetime()` (a date alone, a time with or without seconds,
up to 9 fraction digits, `T` or a space, `Z` or an offset), numeric text
to a number, a `unixepoch()` value (and that value plus or minus a
number) from seconds, a `julianday()` value from days; other values are
compared as they are (text that is not a time sorts after every
integer). The same converted value is what the table receives for
partition pruning, so pruning and the executor's own test agree. Plain
tables keep SQLite's rules: a DATETIME column there has NUMERIC affinity
and `ts >= '2026-09-01'` compares an integer with text. A DATETIME
column (of any table) given to `date`, `time`, `datetime`, `julianday`,
`unixepoch` or `strftime` is read as ns, not as a Julian day number, so
`datetime(ts)` gives `2026-09-01 10:00:00`; `zx_datetime(ts)` keeps the
9 fraction digits. SELECT returns DATETIME values as integers;
`ZxSqlResult.types` (and `ZxSqlCursor.types`) give the declared type of
each result column that reads a column (also through views and
subqueries), `isDatetime(i)` tests it and `zxFormatDatetimeNs(v)`
formats ns as ISO text (UTC), which the `zx sql` shell does for DATETIME
columns (`.datetime off` prints ns; json and quote modes always print
ns).

```sql
CREATE ROLLUP hourly ON logs EVERY '1h' RETENTION '5y' AS
  SELECT level, count(*) AS n, avg(latency) AS lat, max(latency) AS worst
  FROM logs WHERE host <> 'test' GROUP BY level;
SELECT * FROM hourly WHERE ts >= zx_ns('2026-09-01') ORDER BY ts;
DROP ROLLUP [IF EXISTS] hourly;
```

- A rollup is a materialized aggregate per time bucket: its rows are
  `ts` (the bucket start) and the select's columns. The select has group
  columns (in GROUP BY) and aggregates `count(*)`, `count(x)`, `sum`,
  `total`, `avg`, `min`, `max`, `first(x)` and `last(x)` (by time); its
  WHERE is any expression over the series' columns (functions, `OR`,
  arithmetic, subqueries; no aggregates), evaluated with the SQL
  engine's evaluator on each row. An AND of comparisons of a column with
  literals (`=`, `<>`, `<`, `<=`, `>`, `>=`, `IN`, `IS [NOT] NULL`,
  `LIKE`) takes a faster matcher. `ON series` or the FROM names the
  series; EVERY is required.
- It is filled from the sealed rows when it is created and stored at
  each seal. Reads see the write buffer too: the buffered rows in the
  range read are aggregated when the rollup is queried and merged with
  the stored buckets, so a row counts as soon as it is appended (and
  once: the seal stores it and empties the buffer in one transaction).
  Its data outlives the series' retention; its own RETENTION drops old
  buckets at each seal (and hides older buffered rows).

### Time travel (**Deviation**)

- `FROM t AS OF '2026-09-01'` reads t as of the last generation committed
  at or before that time (any time value `datetime()` accepts; an
  integer is ns since 1970 UTC, a REAL is seconds).
  `FROM t AS OF GENERATION 42` reads generation 42. The table
  definition is the one of that generation. It works on tables and
  virtual tables (they get the snapshot in their context); a view named
  with AS OF reads the current state of its tables. `t AS OF ... AS x` and `t x AS OF ...` are both
  accepted.
- `FROM HISTORY OF t` (for a time series see "Time series") yields one row per change of each row across all
  generations: the columns of t, then `zx_generation`, `zx_time` (ns)
  and `zx_op` ('insert', 'update' or 'delete'; a delete row carries the
  values deleted), plus the rowid. It reads every generation, so it is
  meant for small tables and audits.

### Functions

Scalar: `abs`, `char`, `coalesce`, `concat`, `concat_ws`, `format`,
`glob`, `hex`, `ifnull`, `iif`, `instr`, `last_insert_rowid`, `changes`,
`total_changes`, `length`, `octet_length`, `like`, `likely`,
`unlikely`, `likelihood`, `lower`, `upper` (ASCII only, as SQLite
without ICU), `ltrim`, `rtrim`, `trim`, `max`, `min` (several
arguments), `nullif`, `printf`, `quote`, `random`, `randomblob`,
`replace`, `round`, `sign`, `substr`, `substring`, `typeof`, `unhex`,
`unicode`, `zeroblob`, `sqlite_version` ('3.45.1'), `zx_version`; math:
`ceil`, `ceiling`, `floor`, `trunc`, `sqrt`, `exp`, `ln`, `log`,
`log10`, `log2`, `pow`, `power`, `mod`, `pi`, `sin`, `cos`, `tan`,
`asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `degrees`,
`radians`.

Date and time: `date`, `time`, `datetime`, `julianday`, `unixepoch`,
`strftime` with SQLite's time values and modifiers (NNN days / hours /
minutes / seconds / months / years, start of day / month / year,
weekday N, unixepoch, julianday, auto, localtime, utc, subsec,
+YYYY-MM-DD HH:MM:SS and -YYYY-MM-DD HH:MM:SS shifts). `strftime` also has `%G`, `%V`, `%g`,
`%u`, `%U`, `%F`, `%T`, `%R`, `%e`, `%k`, `%l`, `%p`, `%P`, `%I`
(**Deviation** against 3.45, which lacks some of them; newer SQLite has
them). `timediff` is not provided. The time of a statement ('now',
`CURRENT_TIMESTAMP`) is fixed when it starts.

Aggregates: `count`, `sum` (integer overflow is an error), `total`,
`avg`, `min`, `max` (a lone min or max makes the bare columns come from
its row, as in SQLite), `group_concat(x [, sep])`, `string_agg(x, sep)`,
`json_group_array`, `json_group_object`; `DISTINCT`, `FILTER (WHERE ...)`
and `ORDER BY` inside the call (`group_concat(x ORDER BY y)`).

JSON (json1): `json`, `json_valid`, `json_extract`, `->`, `->>`,
`json_type`, `json_array`, `json_object`, `json_array_length`,
`json_quote`, `json_set`, `json_insert`, `json_replace`, `json_remove`,
`json_patch`, `json_pretty`, table-valued `json_each` and `json_tree`.
Arguments from JSON functions (and zx JSON columns) keep the JSON
subtype. **Deviations**: no JSONB (a BLOB argument is an error, where
SQLite 3.45 reads it as JSONB); numbers are rewritten in canonical form
(`json('1e2')` gives `100.0`, SQLite keeps `1e2`); `json_pretty` indents
with Dart's encoder; `json_each.id` is a sequence number, not a byte
offset.

Collations: BINARY, NOCASE (ASCII), RTRIM. LIKE is case insensitive for
ASCII, GLOB case sensitive; both are false when either side is a BLOB,
as in SQLite. `REGEXP` uses Dart regular expressions (SQLite has no
built-in REGEXP; its shell has one); `MATCH` is not supported.

### Planner and executor

- Nested loop joins in the order written (**Deviation**: SQLite may
  reorder inner joins; results are the same, row order without ORDER BY
  may differ). For each table it chooses among: a rowid lookup (`=`,
  `IN`), a rowid range, an index with equality on a prefix of its
  columns (one of them may be an `IN` list or an uncorrelated
  `IN (SELECT ...)`) and an optional range on the next column, a full
  scan, and for inner tables of a join an automatic hash index built once
  per statement. Covering indexes are read without touching the table.
  An index (or the rowid order) that yields the ORDER BY order avoids
  the sort, including DESC and NULLS FIRST / LAST where it matches.
- Aggregation is by hashing; DISTINCT, UNION, INTERSECT and EXCEPT use
  hash sets. UNION, INTERSECT and EXCEPT results come out sorted, like
  SQLite's.
- Uncorrelated subqueries run once per statement; correlated ones per
  row. Subqueries in FROM, views and CTEs are streamed when they are the
  outer loop and materialized once otherwise. **Deviation**: views and
  FROM subqueries are not flattened into the outer query, so a WHERE on a
  view does not reach the view's tables.
- Recursive CTEs run SQLite's queue algorithm one row at a time, so
  `LIMIT` on the outer query stops an unbounded recursion.
- Partial indexes are maintained and enforce uniqueness but are not used
  to answer queries; expression indexes likewise (**Deviation**).
- At most 62 tables in one FROM clause.

### Storage layout

Table rows are kept in the tree `t:<name>` (key: rowid, 8 bytes big
endian with the sign bit flipped; value: a record,
`lib/src/db/record.dart`), each index in `i:<index name>` (key: the
indexed values in the order-preserving encoding of
`lib/src/db/keycodec.dart`, then the rowid; empty value), and the
catalog in `sql:catalog` (layout in `lib/src/db/sql/catalog.dart`). Tree
names are fixed when an object is created, so renaming a table does not
move data (a new object whose tree name is taken gets `#2`, `#3`...).
Rows written before `ALTER TABLE ADD COLUMN` are not rewritten; the
default fills the missing columns on read, as in SQLite.

### Other deviations and limits

- `WITHOUT ROWID` is accepted, and such tables are stored with a rowid
  (the primary key is enforced by a unique index). `STRICT` is accepted
  and not enforced. `TEMP` tables are ordinary tables.
- Not supported: RIGHT and FULL joins, window functions, generated
  columns, triggers, foreign key enforcement, `SAVEPOINT` / `RELEASE`,
  `ATTACH`.
- `OR FAIL` behaves as `OR ABORT` (the statement's earlier changes are
  undone too).
- Renaming a table or column does not rewrite views that use it.
- `printf('%.0f', x)` truncates, as SQLite 3.45 does; printf prints at
  most 16 significant digits.

## The zx sql shell

`zx sql [OPTIONS] ARCHIVE [SQL | .COMMAND ...]` (`lib/src/cli/sql_command.dart`,
`lib/src/cli/sql_shell.dart`) is the database's command line, modeled on
the `sqlite3` program. The archive is created when it does not exist
(its database on the first write). Arguments after the archive run in
order (SQL or dot commands) and the program ends; without them statements
are read from the standard input: a script (errors are reported with the
line of the statement, `Parse error near line 3: no such table: t`, and
the exit code is 1 when there were any), or an interactive shell on a
terminal (prompt `zx> `, continuation `   ...> `, line editing with the
arrow keys, Home/End, Ctrl-A/E/K/U/W, Ctrl-C to drop the line, history
in `~/.zx_sql_history`). A statement ends at a `;` outside quotes and
comments; several statements may share a line and one may span lines.

Options: `-list`, `-csv`, `-json`, `-line`, `-table`, `-box`, `-markdown`,
`-quote`, `-tabs` (output mode), `-header` / `-noheader`, `-separator SEP`,
`-nullvalue TEXT`, `-cmd COMMAND` (run before the input), `-bail` (stop at
the first error), `-readonly`, `-p{Password}`, `-help`.

Output modes print what sqlite3 3.45 prints (checked against it in
`test/cli_sql_test.dart`): `list` (`|` separated, headers off by default),
`csv` (RFC 4180 quoting as sqlite3 does it; rows end in CRLF after `.mode
csv` and in LF with `-csv`, as in sqlite3), `json` (one array per
statement), `line`, `table`, `box`, `markdown` (headers always, cells with
new lines on several lines, tabs expanded), `quote` (SQL literals) and
`tabs`. REALs print as `%!.15g`. **Deviation**: `json` and `quote` print a
REAL with the fewest digits (15 to 17) that read back as the same value,
where sqlite3 prints up to 20 digits (`0.1`, sqlite3 `0.100000000000000005`).
Statements with no rows print nothing (no header either).

Dot commands:

| Command | Effect |
|---|---|
| `.tables [PATTERN]` | tables, views and KV stores (a LIKE pattern also matches the system tables, `.tables zx_%`), in columns as sqlite3 prints them |
| `.schema [PATTERN]` | the CREATE statements (and `CREATE KV STORE`; with a pattern, the metadata tables' DDL) |
| `.indexes [TABLE]` | index names |
| `.mode MODE`, `.headers on\|off`, `.nullvalue TEXT`, `.separator COL [ROW]` | output settings |
| `.import [--csv\|--json] [--skip N] FILE TABLE` | CSV (a missing table is created with TEXT columns named by the first row; into an existing table every row is data), or JSON (`.json`, `.jsonl`, `.ndjson` or `--json`: an array of objects or one object per line; a new table gets the keys as untyped columns, nested values become JSON text); one transaction |
| `.export FILE TABLE\|QUERY` | writes a table or a query: `.csv` (header, CRLF), `.json` (an array of objects), `.jsonl` (one object per line); BLOBs as hex (zx extension; sqlite3 has no .export) |
| `.read FILE` | runs a file of statements and dot commands |
| `.param set NAME VALUE`, `.param unset NAME`, `.param list`, `.param clear` | named parameters (`:x`, `@x`, `$x`) for the statements; VALUE is a SQL expression, text when it does not parse |
| `.datetime on\|off` | (zx) DATETIME columns print as ISO text in UTC (on, the default) or as ns; the json and quote modes always print ns |
| `.timer on\|off` | prints `Run Time: real S` after each statement (no user and sys times) |
| `.bail on\|off`, `.print TEXT`, `.help`, `.quit` / `.exit` | as in sqlite3 |
| `.asof GEN\|DATE\|off` | (zx) the session reads the database as of a generation or the last one at or before a time (any time value of `datetime()`); writes are refused until `.asof off`. System tables still read the current archive unless the query says `AS OF` |
| `.generations` | (zx) the generations: number, time (UTC), comment |
| `.kv` | (zx) the KV stores: name, TTL, entries |
| `.vacuum [ultra]` | (zx) `VACUUM` (`ultra`: recompress every page with the strongest chain) and the bytes freed |
| `.import-arca DIR`, `.export-arca DIR` | (zx) arca manifests, subtitles and previews into / out of the metadata tables (`arcaImport` / `arcaExport`) |
| `.import-sqlite FILE [TABLE...]`, `.export-sqlite FILE [TABLE...]` | (zx) tables, rows, indexes and views from / to a SQLite database file (`sqliteImport` / `sqliteExport` in `lib/src/db/sqlite_io/`) |
