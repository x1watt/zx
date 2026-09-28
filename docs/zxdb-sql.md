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
CREATE ROLLUP [IF NOT EXISTS] name [(cols)] [EVERY '1h'] [RETENTION '...'] [WITH (...)]
  AS SELECT ... [EVERY '1h'];
DROP KV STORE | TIMESERIES | ROLLUP [IF EXISTS] name;
VACUUM [ULTRA];
```

### Time travel (**Deviation**)

- `FROM t AS OF '2026-09-01'` reads t as of the last generation committed
  at or before that time (any time value `datetime()` accepts; an
  integer is ns since 1970 UTC, a REAL is seconds).
  `FROM t AS OF GENERATION 42` reads generation 42. The table
  definition is the one of that generation. It works on tables and
  virtual tables (they get the snapshot in their context); a view named
  with AS OF reads the current state of its tables. `t AS OF ... AS x` and `t x AS OF ...` are both
  accepted.
- `FROM HISTORY OF t` yields one row per change of each row across all
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
