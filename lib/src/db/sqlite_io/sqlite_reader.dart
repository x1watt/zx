// A reader of SQLite database files written from the documented file
// format (https://www.sqlite.org/fileformat2.html), without the SQLite
// library: the 100 byte header, table and index b-trees (interior and
// leaf pages), cells with overflow pages, the schema table, the record
// format, WITHOUT ROWID tables (stored as index b-trees) and the UTF-8,
// UTF-16le and UTF-16be text encodings. Freelist pages are never visited.

import '../../host/io.dart';
import 'dart:typed_data';

import '../sql/ast.dart';
import '../sql/parser.dart';
import 'sqlite_format.dart';

/// A row of sqlite_schema.
class SqliteSchemaEntry {
  final String type; // table, index, view, trigger
  final String name;
  final String tableName;
  final int rootPage;
  final String? sql;
  const SqliteSchemaEntry(
      this.type, this.name, this.tableName, this.rootPage, this.sql);

  bool get isVirtual =>
      sql != null &&
      RegExp(r'^\s*CREATE\s+VIRTUAL\s', caseSensitive: false).hasMatch(sql!);

  @override
  String toString() => '$type $name ($tableName, page $rootPage)';
}

/// The shape of a table from its CREATE TABLE text.
class SqliteTableShape {
  final String name;
  final List<String> columns;
  final List<String?> types;
  final List<Object?> defaults;

  /// The INTEGER PRIMARY KEY column (the rowid alias), or -1.
  final int ipk;
  final bool withoutRowid;

  /// The primary key columns (for WITHOUT ROWID tables: the order of the
  /// fields that start each record).
  final List<int> pk;

  SqliteTableShape(this.name, this.columns, this.types, this.defaults,
      this.ipk, this.withoutRowid, this.pk);

  /// Parses [sql] (a CREATE TABLE statement).
  factory SqliteTableShape.parse(String sql) {
    final st = Parser.parse(sql).statements.single;
    if (st is! CreateTableStmt) {
      throw FormatException('not a CREATE TABLE statement: $sql');
    }
    final cols = [for (final c in st.columns) c.name];
    final types = [for (final c in st.columns) c.type];
    final defaults = <Object?>[];
    int idx(String n) {
      final l = n.toLowerCase();
      for (var i = 0; i < cols.length; i++) {
        if (cols[i].toLowerCase() == l) return i;
      }
      return -1;
    }

    final pk = <int>[];
    var ipk = -1;
    for (var i = 0; i < st.columns.length; i++) {
      Object? d;
      for (final k in st.columns[i].constraints) {
        if (k.kind == 'DEFAULT' && k.expr is LitExpr) {
          d = (k.expr as LitExpr).value;
        }
        if (k.kind == 'PK') {
          pk.add(i);
          if (!k.desc && (types[i] ?? '').toUpperCase() == 'INTEGER') ipk = i;
        }
      }
      defaults.add(d);
    }
    for (final k in st.constraints) {
      if (k.kind != 'PK') continue;
      for (final c in k.columns) {
        final e = c.e;
        final i = e is ColumnExpr ? idx(e.column) : -1;
        if (i >= 0 && !pk.contains(i)) pk.add(i);
      }
      if (pk.length == 1 &&
          (types[pk[0]] ?? '').toUpperCase() == 'INTEGER') {
        ipk = pk[0];
      }
    }
    if (pk.length != 1 || st.withoutRowid) ipk = -1;
    return SqliteTableShape(
        st.name, cols, types, defaults, ipk, st.withoutRowid, pk);
  }
}

/// A row of a table: its rowid (null for WITHOUT ROWID tables) and the
/// values of its columns in declaration order.
class SqliteRow {
  final int? rowid;
  final List<Object?> values;
  const SqliteRow(this.rowid, this.values);
}

/// Reads a SQLite database file.
class SqliteFileReader {
  final RandomAccessFile? _file;
  final Uint8List? _bytes;
  late final int pageSize;
  late final int usableSize;
  late final int pageCount;
  late final SqliteTextEncoding encoding;
  late final int userVersion;
  late final int schemaFormat;
  late final int freelistPages;
  final Map<int, Uint8List> _cache = {};
  List<SqliteSchemaEntry>? _schema;

  SqliteFileReader._(this._file, this._bytes) {
    final h = _read(0, 100);
    for (var i = 0; i < 16; i++) {
      if (h[i] != sqliteMagic[i]) {
        throw const FormatException('not a SQLite database file');
      }
    }
    final bd = ByteData.sublistView(h);
    final ps = bd.getUint16(16);
    pageSize = ps == 1 ? 65536 : ps;
    if (pageSize < 512 || pageSize & (pageSize - 1) != 0) {
      throw FormatException('bad page size $pageSize');
    }
    usableSize = pageSize - h[20];
    final len = _length();
    final counter = bd.getUint32(24);
    final inHeader = bd.getUint32(28);
    final validFor = bd.getUint32(92);
    pageCount = inHeader > 0 && counter == validFor
        ? inHeader
        : len ~/ pageSize;
    freelistPages = bd.getUint32(36);
    schemaFormat = bd.getUint32(44);
    encoding = switch (bd.getUint32(56)) {
      2 => SqliteTextEncoding.utf16le,
      3 => SqliteTextEncoding.utf16be,
      _ => SqliteTextEncoding.utf8,
    };
    userVersion = bd.getInt32(60);
  }

  /// Opens the file at [path].
  factory SqliteFileReader.open(String path) =>
      SqliteFileReader._(File(path).openSync(), null);

  /// Reads a database held in memory.
  factory SqliteFileReader.fromBytes(Uint8List bytes) =>
      SqliteFileReader._(null, bytes);

  void close() {
    _file?.closeSync();
    _cache.clear();
  }

  int _length() => _bytes?.length ?? _file!.lengthSync();

  Uint8List _read(int pos, int n) {
    final b = _bytes;
    if (b != null) {
      if (pos + n > b.length) throw const FormatException('file truncated');
      return Uint8List.sublistView(b, pos, pos + n);
    }
    final f = _file!;
    f.setPositionSync(pos);
    final r = f.readSync(n);
    if (r.length != n) throw const FormatException('file truncated');
    return r;
  }

  /// Page [n] (1 based).
  Uint8List page(int n) {
    if (n < 1 || n > pageCount) {
      throw FormatException('page $n out of range (1..$pageCount)');
    }
    final c = _cache[n];
    if (c != null) return c;
    final p = _read((n - 1) * pageSize, pageSize);
    if (_cache.length >= 256) _cache.remove(_cache.keys.first);
    _cache[n] = p;
    return p;
  }

  /// The rows of sqlite_schema.
  List<SqliteSchemaEntry> get schema {
    final s = _schema;
    if (s != null) return s;
    final out = <SqliteSchemaEntry>[];
    for (final (_, r) in tableRecords(1)) {
      if (r.length < 5) continue;
      out.add(SqliteSchemaEntry('${r[0]}', '${r[1]}', '${r[2]}',
          (r[3] as int?) ?? 0, r[4] as String?));
    }
    return _schema = out;
  }

  SqliteSchemaEntry? entry(String name) {
    final l = name.toLowerCase();
    for (final e in schema) {
      if (e.name.toLowerCase() == l) return e;
    }
    return null;
  }

  /// Names of the tables (not the internal sqlite_ ones).
  List<String> get tableNames => [
        for (final e in schema)
          if (e.type == 'table' && !e.name.toLowerCase().startsWith('sqlite_'))
            e.name
      ];

  // the payload of a cell: [size] bytes starting at [p] of page [pg]
  Uint8List _payload(Uint8List pg, int p, int size, bool tableLeaf) {
    final local = localPayload(size, usableSize, tableLeaf: tableLeaf);
    if (p + local > usableSize) throw const FormatException('cell overflows');
    if (local == size) return Uint8List.sublistView(pg, p, p + size);
    final out = Uint8List(size);
    out.setRange(0, local, pg, p);
    var got = local;
    var next = ByteData.sublistView(pg).getUint32(p + local);
    var guard = pageCount;
    while (got < size) {
      if (next == 0 || guard-- <= 0) {
        throw const FormatException('overflow chain too short');
      }
      final o = page(next);
      final n = size - got < usableSize - 4 ? size - got : usableSize - 4;
      out.setRange(got, got + n, o, 4);
      got += n;
      next = ByteData.sublistView(o).getUint32(0);
    }
    return out;
  }

  /// (rowid, record) of every row of the table b-tree at [root], in
  /// rowid order.
  Iterable<(int, List<Object?>)> tableRecords(int root) sync* {
    yield* _table(root, 0);
  }

  Iterable<(int, List<Object?>)> _table(int n, int depth) sync* {
    if (depth > 64) throw const FormatException('b-tree too deep');
    final pg = page(n);
    final h = n == 1 ? 100 : 0;
    final bd = ByteData.sublistView(pg);
    final flag = pg[h];
    final cells = bd.getUint16(h + 3);
    if (flag == 13) {
      for (var i = 0; i < cells; i++) {
        var p = bd.getUint16(h + 8 + 2 * i);
        final (size, l1) = readVarint(pg, p);
        p += l1;
        final (rowid, l2) = readVarint(pg, p);
        p += l2;
        yield (rowid, decodeSqliteRecord(_payload(pg, p, size, true), encoding));
      }
    } else if (flag == 5) {
      for (var i = 0; i < cells; i++) {
        final p = bd.getUint16(h + 12 + 2 * i);
        yield* _table(bd.getUint32(p), depth + 1);
      }
      yield* _table(bd.getUint32(h + 8), depth + 1);
    } else {
      throw FormatException('page $n is not a table b-tree page ($flag)');
    }
  }

  /// The records of the index b-tree at [root], in key order.
  Iterable<List<Object?>> indexRecords(int root) => _index(root, 0);

  Iterable<List<Object?>> _index(int n, int depth) sync* {
    if (depth > 64) throw const FormatException('b-tree too deep');
    final pg = page(n);
    final h = n == 1 ? 100 : 0;
    final bd = ByteData.sublistView(pg);
    final flag = pg[h];
    final cells = bd.getUint16(h + 3);
    if (flag != 10 && flag != 2) {
      throw FormatException('page $n is not an index b-tree page ($flag)');
    }
    final leaf = flag == 10;
    for (var i = 0; i < cells; i++) {
      var p = bd.getUint16(h + (leaf ? 8 : 12) + 2 * i);
      if (!leaf) {
        yield* _index(bd.getUint32(p), depth + 1);
        p += 4;
      }
      final (size, l) = readVarint(pg, p);
      yield decodeSqliteRecord(_payload(pg, p + l, size, false), encoding);
    }
    if (!leaf) yield* _index(bd.getUint32(h + 8), depth + 1);
  }

  /// The shape of table [name].
  SqliteTableShape shape(String name) {
    final e = entry(name);
    if (e == null || e.type != 'table' || e.sql == null) {
      throw ArgumentError('no such table: $name');
    }
    return SqliteTableShape.parse(e.sql!);
  }

  /// The rows of table [name], columns in declaration order.
  Iterable<SqliteRow> rows(String name) sync* {
    final e = entry(name);
    if (e == null || e.type != 'table') {
      throw ArgumentError('no such table: $name');
    }
    final s = shape(name);
    final n = s.columns.length;
    List<Object?> fill(List<Object?> r) {
      if (r.length >= n) return r.length == n ? r : r.sublist(0, n);
      return [...r, for (var i = r.length; i < n; i++) s.defaults[i]];
    }

    if (!s.withoutRowid) {
      for (final (rowid, r) in tableRecords(e.rootPage)) {
        final v = fill(r);
        if (s.ipk >= 0) v[s.ipk] = rowid;
        yield SqliteRow(rowid, v);
      }
      return;
    }
    // WITHOUT ROWID: the primary key columns, then the others
    final order = [
      ...s.pk,
      for (var i = 0; i < n; i++)
        if (!s.pk.contains(i)) i
    ];
    for (final r in indexRecords(e.rootPage)) {
      final v = List<Object?>.of(s.defaults);
      for (var k = 0; k < order.length && k < r.length; k++) {
        v[order[k]] = r[k];
      }
      yield SqliteRow(null, v);
    }
  }
}
