// The database of the open .zx archive (zxdb, docs/zxdb-design.md): the
// connection runs ZxDatabase in a worker isolate (ZxDatabaseAsync), so
// every query, commit and page decoding happens off the UI isolate. This
// file holds the session state of the Data view, the catalog listing and
// the queries of the file metadata, the similar files and the SHA-256
// search, and the CSV and JSON export of results.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zx/zx.dart';

/// The database calls the app needs (a fake in the tests).
abstract class DbConnection {
  Future<ZxSqlResult> execute(String sql, [Object? params]);
  Future<List<String>> kvStores();

  /// The names of the time series.
  Future<List<String>> seriesNames();

  /// A new SQL session that sees the archive's files as they are now.
  Future<void> resetSql();
  Future<void> close();
}

/// Opens the database of [path]; null when the archive has none (and
/// [create] is false).
typedef DbOpener = Future<DbConnection?> Function(
  String path, {
  String? password,
  bool readOnly,
  bool create,
});

/// A [DbConnection] over ZxDatabaseAsync.
class AsyncDbConnection implements DbConnection {
  final ZxDatabaseAsync db;
  AsyncDbConnection(this.db);

  @override
  Future<ZxSqlResult> execute(String sql, [Object? params]) =>
      db.execute(sql, params);

  @override
  Future<List<String>> kvStores() => db.kvStores();

  @override
  Future<List<String>> seriesNames() => db.seriesNames();

  @override
  Future<void> resetSql() => db.resetSql();

  @override
  Future<void> close() => db.close();
}

/// The default [DbOpener]: checks for a database in a background isolate,
/// then opens it in a worker isolate.
Future<DbConnection?> openAsyncDb(
  String path, {
  String? password,
  bool readOnly = false,
  bool create = false,
}) async {
  if (!create && !await ZxDatabaseAsync.hasDatabase(path, password: password)) {
    return null;
  }
  final db = await ZxDatabaseAsync.open(
    path,
    password: password,
    readOnly: readOnly,
    create: create,
  );
  return AsyncDbConnection(db);
}

/// The system tables every database session has (docs/zxdb-sql.md).
const kSystemTables = [
  'zx_files',
  'zx_generations',
  'zx_file_history',
  'zx_meta',
  'zx_layers',
  'zx_media',
  'zx_fingerprints',
];

enum DbObjectKind { table, view, kv, series, system }

class DbObject {
  final String name;
  final DbObjectKind kind;
  const DbObject(this.name, this.kind);
}

/// The metadata of one file (zx_meta, zx_layers, zx_media).
class FileMeta {
  String? title;
  String? description;
  String? mime;
  List<String> tags = [];
  final List<({String kind, String? language, String? file, String? tool})>
  layers = [];
  final List<({String kind, String? caption, Uint8List data})> media = [];

  bool get isEmpty =>
      title == null &&
      description == null &&
      mime == null &&
      tags.isEmpty &&
      layers.isEmpty &&
      media.isEmpty;
}

/// A result row set with its columns.
class DbRows {
  final List<String> columns;
  final List<List<Object?>> rows;

  /// The columns declared DATETIME or TIMESTAMP (ns since 1970 UTC, shown
  /// as dates).
  final Set<String> datetimeColumns;
  const DbRows(this.columns, this.rows, {this.datetimeColumns = const {}});
}

/// The quoted SQL identifier of [name].
String sqlIdent(String name) => '"${name.replaceAll('"', '""')}"';

/// True when [sql] only reads (SELECT, WITH, VALUES, EXPLAIN, a PRAGMA
/// without a value).
bool sqlIsRead(String sql) {
  final s = sql.trimLeft().toLowerCase();
  if (s.startsWith('pragma')) return !s.contains('=');
  return s.startsWith('select') ||
      s.startsWith('with') ||
      s.startsWith('values') ||
      s.startsWith('explain');
}

/// The state of the database of one archive view.
class DbSession extends ChangeNotifier {
  final String path;
  final String? password;

  /// Why writes are refused (a nested level, an older version...), or null.
  final String? readOnlyWhy;

  /// The generation shown (an older version of the archive), or null for
  /// the current state.
  final int? asOfGeneration;
  final DbOpener opener;

  DbConnection? _conn;
  bool _checked = false;
  bool _closed = false;
  Object? error;

  /// Bumped after each write (views that cache reload).
  int version = 0;

  /// Called after a statement that may have written (the archive has a
  /// new generation).
  VoidCallback? onWrite;

  DbSession(
    this.path, {
    this.password,
    this.readOnlyWhy,
    this.asOfGeneration,
    this.opener = openAsyncDb,
  });

  bool get readOnly => readOnlyWhy != null;
  bool get checked => _checked;

  /// True when the archive has a database (after [start]).
  bool get available => _conn != null;

  /// Checks for a database and opens it.
  Future<void> start() async {
    try {
      final c = await opener(path, password: password, readOnly: readOnly);
      if (_closed) {
        await c?.close();
        return;
      }
      _conn = c;
    } catch (e) {
      error = e;
    }
    _checked = true;
    if (!_closed) notifyListeners();
  }

  /// Creates a database in the archive (Archive, New database).
  Future<void> create() async {
    if (readOnly) {
      throw ZxDbException('$readOnlyWhy (read-only)', ZxDbError.readOnly);
    }
    if (_conn != null) return;
    final c = await opener(path, password: password, create: true);
    if (_closed) {
      await c?.close();
      return;
    }
    _conn = c;
    _checked = true;
    version++;
    notifyListeners();
    onWrite?.call();
  }

  DbConnection get _c {
    final c = _conn;
    if (c == null) {
      throw const ZxDbException('the archive has no database');
    }
    return c;
  }

  /// Runs [sql]; a statement that writes bumps [version] and calls
  /// [onWrite].
  Future<ZxSqlResult> execute(String sql, [Object? params]) async {
    final read = sqlIsRead(sql);
    if (!read && readOnly) {
      throw ZxDbException(
        'the database is read-only here: $readOnlyWhy',
        ZxDbError.readOnly,
      );
    }
    final r = await _c.execute(sql, params);
    if (!read && !_closed) {
      version++;
      notifyListeners();
      onWrite?.call();
    }
    return r;
  }

  /// The archive changed (files added...): the next queries see it.
  Future<void> archiveChanged() async {
    final c = _conn;
    if (c == null || _closed) return;
    await c.resetSql();
    version++;
    notifyListeners();
  }

  /// `name` with the AS OF clause of an older version.
  String from(String name) => asOfGeneration == null
      ? sqlIdent(name)
      : '${sqlIdent(name)} AS OF GENERATION $asOfGeneration';

  /// The tables, views, KV stores and system tables, grouped.
  Future<List<DbObject>> objects() async {
    final out = <DbObject>[];
    final kv = (await _c.kvStores()).toSet();
    final series = (await _c.seriesNames()).toSet();
    final r = await _c.execute(
      'SELECT type, name FROM sqlite_schema '
      "WHERE type <> 'index' ORDER BY name",
    );
    for (final row in r.rows) {
      final type = '${row[0]}'.toLowerCase();
      final name = '${row[1]}';
      if (name.startsWith('sqlite_') || kSystemTables.contains(name)) {
        continue;
      }
      if (kv.contains(name) || series.contains(name)) continue;
      out.add(
        DbObject(
          name,
          type == 'view'
              ? DbObjectKind.view
              : type.contains('series') || type.contains('rollup')
              ? DbObjectKind.series
              : DbObjectKind.table,
        ),
      );
    }
    for (final t in series.toList()..sort()) {
      out.add(DbObject(t, DbObjectKind.series));
    }
    for (final k in kv.toList()..sort()) {
      out.add(DbObject(k, DbObjectKind.kv));
    }
    for (final s in kSystemTables) {
      out.add(DbObject(s, DbObjectKind.system));
    }
    return out;
  }

  /// One page of [table]: [limit] rows from [offset], sorted by [sortBy].
  Future<DbRows> page(
    String table, {
    int offset = 0,
    int limit = 100,
    String? sortBy,
    bool ascending = true,
  }) async {
    final order = sortBy == null
        ? ''
        : ' ORDER BY ${sqlIdent(sortBy)} ${ascending ? 'ASC' : 'DESC'}';
    final r = await _c.execute(
      'SELECT * FROM ${from(table)}$order LIMIT $limit OFFSET $offset',
    );
    final dt = <String>{};
    try {
      final info = await _c.execute('PRAGMA table_info(${sqlIdent(table)})');
      for (final row in info.rows) {
        final t = '${row[2]}'.toUpperCase();
        if (t.contains('DATETIME') || t.contains('TIMESTAMP')) {
          dt.add('${row[1]}');
        }
      }
    } on ZxDbException {
      // a virtual table without table_info
    }
    return DbRows(r.columns, r.rows, datetimeColumns: dt);
  }

  /// All rows of [table] (for an export).
  Future<DbRows> all(String table, {String? sortBy, bool ascending = true}) =>
      page(table, limit: -1, sortBy: sortBy, ascending: ascending);

  Future<int> count(String table) async {
    final r = await _c.execute('SELECT count(*) FROM ${from(table)}');
    return (r.scalar as int?) ?? 0;
  }

  /// The metadata of the file at archive [path].
  Future<FileMeta> fileMeta(String path) async {
    final m = FileMeta();
    final sha = await _c.execute(
      'SELECT sha256 FROM ${from('zx_files')} WHERE path = ?',
      [path],
    );
    final h = sha.scalar;
    if (h is! Uint8List) return m;
    final meta = await _c.execute(
      'SELECT title, description, mime, tags FROM ${from('zx_meta')} '
      'WHERE sha256 = ?',
      [h],
    );
    if (meta.rows.isNotEmpty) {
      final row = meta.rows.first;
      m.title = _text(row[0]);
      m.description = _text(row[1]);
      m.mime = _text(row[2]);
      final t = row[3];
      if (t is String && t.isNotEmpty) {
        try {
          final l = jsonDecode(t);
          if (l is List) m.tags = [for (final x in l) '$x'];
        } on FormatException {
          m.tags = [t];
        }
      }
    }
    final layers = await _c.execute(
      'SELECT kind, language, file, tool FROM ${from('zx_layers')} '
      'WHERE sha256 = ? ORDER BY n',
      [h],
    );
    for (final l in layers.rows) {
      m.layers.add((
        kind: '${l[0]}',
        language: _text(l[1]),
        file: _text(l[2]),
        tool: _text(l[3]),
      ));
    }
    final media = await _c.execute(
      'SELECT kind, caption, data FROM ${from('zx_media')} '
      'WHERE sha256 = ? AND data IS NOT NULL ORDER BY kind, n LIMIT 12',
      [h],
    );
    for (final r in media.rows) {
      final d = r[2];
      if (d is Uint8List) {
        m.media.add((kind: '${r[0]}', caption: _text(r[1]), data: d));
      }
    }
    return m;
  }

  static String? _text(Object? v) =>
      v == null || (v is String && v.isEmpty) ? null : '$v';

  /// The [n] files nearest to [path] by TLSH distance.
  Future<List<({String path, int distance})>> similar(
    String path, {
    int n = 20,
  }) async {
    final r = await _c.execute('SELECT path, distance FROM similar(?, ?)', [
      path,
      n,
    ]);
    return [
      for (final row in r.rows)
        (path: '${row[0]}', distance: (row[1] as num?)?.toInt() ?? 0),
    ];
  }

  /// The files whose content has the SHA-256 [hex] (64 hex digits).
  Future<List<({String path, int size})>> bySha256(String hex) async {
    final h = parseSha256(hex);
    if (h == null) {
      throw const ZxDbException('a SHA-256 is 64 hexadecimal digits');
    }
    final r = await _c.execute(
      'SELECT path, size FROM ${from('zx_files')} WHERE sha256 = ?',
      [h],
    );
    return [
      for (final row in r.rows)
        (path: '${row[0]}', size: (row[1] as num?)?.toInt() ?? 0),
    ];
  }

  /// Closes the connection (its worker isolate ends).
  Future<void> close() async {
    _closed = true;
    final c = _conn;
    _conn = null;
    await c?.close();
  }
}

/// The 32 bytes of a SHA-256 written in hex (spaces allowed), or null.
Uint8List? parseSha256(String text) {
  final s = text.replaceAll(RegExp(r'\s'), '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(s)) return null;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// A DATETIME value (ns since 1970 UTC) as text.
String nsDateText(int ns) {
  final d = DateTime.fromMicrosecondsSinceEpoch(ns ~/ 1000, isUtc: true);
  String two(int x) => x.toString().padLeft(2, '0');
  final frac = ns % 1000000000;
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}'
      '${frac == 0 ? '' : '.${frac.toString().padLeft(9, '0')}'}';
}

/// A value as the grid shows it.
String cellText(Object? v, {int maxChars = 200, bool datetime = false}) {
  if (v == null) return 'NULL';
  if (datetime && v is int) return nsDateText(v);
  if (v is Uint8List) {
    if (v.length <= 32) return "x'${_hex(v)}'";
    return '<BLOB ${v.length} bytes>';
  }
  var s = '$v';
  if (s.length > maxChars) s = '${s.substring(0, maxChars)}...';
  return s.replaceAll('\n', ' ');
}

String _csvField(Object? v) {
  if (v == null) return '';
  final s = v is Uint8List ? _hex(v) : '$v';
  if (s.contains(RegExp('[",\n\r]'))) return '"${s.replaceAll('"', '""')}"';
  return s;
}

/// The rows as CSV (RFC 4180, a header line; BLOBs in hex).
String rowsToCsv(DbRows r) {
  final sb = StringBuffer();
  sb.write('${r.columns.map(_csvField).join(',')}\r\n');
  for (final row in r.rows) {
    sb.write('${row.map(_csvField).join(',')}\r\n');
  }
  return sb.toString();
}

/// The rows as a JSON array of objects (BLOBs in hex).
String rowsToJson(DbRows r) {
  final list = [
    for (final row in r.rows)
      {
        for (var i = 0; i < r.columns.length; i++)
          r.columns[i]: row[i] is Uint8List
              ? _hex(row[i] as Uint8List)
              : row[i],
      },
  ];
  return const JsonEncoder.withIndent('  ').convert(list);
}
