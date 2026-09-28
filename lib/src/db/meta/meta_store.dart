// The arca-compatible metadata tables (docs/zxdb-design.md 1.2), stored
// through the storage contract (storage_api.dart) as trees shaped like the
// SQL engine's WITHOUT ROWID tables: key = the primary key values encoded
// by keycodec.dart, value = the whole row encoded by record.dart. They are
// exposed to SQL as writable virtual tables ([ZxMetaVTable]) so that every
// write goes through [ZxMetaDb] and keeps the full-text index (fts.dart)
// up to date in the same transaction.
//
//   zx_meta          PK sha256: path, size, title, description, mime,
//                    sha1, added, tags (ARRAY, JSON text), extra (JSON)
//   zx_layers        PK (sha256, n): kind, language, origin, tool, model,
//                    created, file, content (TEXT), content_ref, attrs
//   zx_media         PK (sha256, kind, n): caption, width, height,
//                    time_offset, mime, content_ref, data (BLOB)
//   zx_fingerprints  PK (sha256, algorithm): value, tool, created
//
// Field semantics follow arca (arca_core library.dart LibraryFile,
// sidecars.dart, core_service.dart _placeSubtitles; whitepaper appendices
// A to C); arca_io.dart maps manifests to rows and back losslessly:
//   - sha256 is the 32 byte BLOB (arca writes it as lowercase hex), so it
//     joins zx_files.sha256; sha1 stays hex TEXT ('' when unknown).
//   - added and created keep arca's ISO 8601 text as written
//     (DateTime.toIso8601String of UTC: '2026-09-24T16:12:14.000Z').
//   - a layer is one element of the manifest's "layers" list, n its
//     position; kind = its "type" (arca writes 'subtitles'), file = the
//     sidecar file name, content = the sidecar text when imported,
//     content_ref = an archive path holding it; attrs keeps the keys arca
//     does not define and the key order when it is not arca's.
//   - zx_meta.extra likewise keeps unknown manifest keys (and the order).

import 'dart:convert';
import 'dart:typed_data';

import '../keycodec.dart';
import '../record.dart';
import '../storage_api.dart';
import '../system/sys_vtab.dart';
import '../../format/zx/zx_reader.dart' show zxParseGenerationDate;
import 'fts.dart';

class MetaTableSpec {
  final String name;
  final List<SysColumn> columns;
  final List<int> primaryKey;
  const MetaTableSpec(this.name, this.columns, this.primaryKey);

  int col(String n) {
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].name == n) return i;
    }
    throw ArgumentError('$name has no column $n');
  }

  /// The CREATE TABLE statement of the table (the system schema, for
  /// .schema and for the SQL engine's catalog).
  String get ddl {
    final cols = [for (final c in columns) '  ${c.name} ${c.type}'];
    final pk = [for (final i in primaryKey) columns[i].name].join(', ');
    return 'CREATE TABLE $name (\n${cols.join(',\n')},\n'
        '  PRIMARY KEY ($pk)\n) WITHOUT ROWID;';
  }
}

abstract final class ZxMetaSchema {
  // zx_meta columns
  static const mSha256 = 0,
      mPath = 1,
      mSize = 2,
      mTitle = 3,
      mDescription = 4,
      mMime = 5,
      mSha1 = 6,
      mAdded = 7,
      mTags = 8,
      mExtra = 9;
  static const meta = MetaTableSpec('zx_meta', [
    SysColumn('sha256', 'BLOB'),
    SysColumn('path', 'TEXT'),
    SysColumn('size', 'INTEGER'),
    SysColumn('title', 'TEXT'),
    SysColumn('description', 'TEXT'),
    SysColumn('mime', 'TEXT'),
    SysColumn('sha1', 'TEXT'),
    SysColumn('added', 'TEXT'),
    SysColumn('tags', 'ARRAY'),
    SysColumn('extra', 'JSON'),
  ], [
    0
  ]);

  // zx_layers columns
  static const lSha256 = 0,
      lN = 1,
      lKind = 2,
      lLanguage = 3,
      lOrigin = 4,
      lTool = 5,
      lModel = 6,
      lCreated = 7,
      lFile = 8,
      lContent = 9,
      lContentRef = 10,
      lAttrs = 11;
  static const layers = MetaTableSpec('zx_layers', [
    SysColumn('sha256', 'BLOB'),
    SysColumn('n', 'INTEGER'),
    SysColumn('kind', 'TEXT'),
    SysColumn('language', 'TEXT'),
    SysColumn('origin', 'TEXT'),
    SysColumn('tool', 'TEXT'),
    SysColumn('model', 'TEXT'),
    SysColumn('created', 'TEXT'),
    SysColumn('file', 'TEXT'),
    SysColumn('content', 'TEXT'),
    SysColumn('content_ref', 'TEXT'),
    SysColumn('attrs', 'JSON'),
  ], [
    0,
    1
  ]);

  // zx_media columns
  static const dSha256 = 0,
      dKind = 1,
      dN = 2,
      dCaption = 3,
      dWidth = 4,
      dHeight = 5,
      dTimeOffset = 6,
      dMime = 7,
      dContentRef = 8,
      dData = 9;
  static const media = MetaTableSpec('zx_media', [
    SysColumn('sha256', 'BLOB'),
    SysColumn('kind', 'TEXT'),
    SysColumn('n', 'INTEGER'),
    SysColumn('caption', 'TEXT'),
    SysColumn('width', 'INTEGER'),
    SysColumn('height', 'INTEGER'),
    SysColumn('time_offset', 'REAL'),
    SysColumn('mime', 'TEXT'),
    SysColumn('content_ref', 'TEXT'),
    SysColumn('data', 'BLOB'),
  ], [
    0,
    1,
    2
  ]);

  // zx_fingerprints columns
  static const fSha256 = 0, fAlgorithm = 1, fValue = 2, fTool = 3, fCreated = 4;
  static const fingerprints = MetaTableSpec('zx_fingerprints', [
    SysColumn('sha256', 'BLOB'),
    SysColumn('algorithm', 'TEXT'),
    SysColumn('value', 'BLOB'),
    SysColumn('tool', 'TEXT'),
    SysColumn('created', 'TEXT'),
  ], [
    0,
    1
  ]);

  static const all = [meta, layers, media, fingerprints];

  /// Creates the metadata and full-text trees that are missing.
  static void create(ZxWriteTxn t) {
    for (final s in all) {
      if (t.tree(s.name) == null) t.createTree(s.name);
    }
    ZxFts.createTrees(t);
  }

  /// Whether [s] has the metadata schema.
  static bool exists(ZxSnapshot s) => s.tree(meta.name) != null;
}

/// Row access to the metadata tables of one snapshot or write transaction.
/// Writes (on a [ZxWriteTxn]) keep the full-text index current: each
/// change of zx_meta or zx_layers reindexes that file's document, at once
/// or, inside [batch], once at its end.
class ZxMetaDb {
  final ZxSnapshot s;
  late final ZxFts fts = ZxFts(this);
  Set<String>? _dirty;

  ZxMetaDb(this.s);

  bool get writable => s is ZxWriteTxn;
  ZxWriteTxn get _txn {
    final t = s;
    if (t is! ZxWriteTxn) {
      throw const ZxDbException(
          'the metadata tables are read-only here', ZxDbError.readOnly);
    }
    return t;
  }

  ZxTree? tree(MetaTableSpec spec) => s.tree(spec.name);

  ZxWritableTree _wtree(MetaTableSpec spec) {
    final t = _txn;
    final x = t.tree(spec.name);
    if (x != null) return x;
    ZxMetaSchema.create(t);
    return t.tree(spec.name)!;
  }

  static Uint8List keyOf(MetaTableSpec spec, List<Object?> row) =>
      encodeKey([for (final i in spec.primaryKey) row[i]]);

  static List<Object?> _normalize(MetaTableSpec spec, List<Object?> row) {
    if (row.length > spec.columns.length) {
      throw ZxDbException('${spec.name}: ${row.length} values for '
          '${spec.columns.length} columns', ZxDbError.constraint);
    }
    final r = [...row];
    while (r.length < spec.columns.length) {
      r.add(null);
    }
    for (final i in spec.primaryKey) {
      if (r[i] == null) {
        throw ZxDbException(
            '${spec.name}.${spec.columns[i].name} may not be NULL',
            ZxDbError.constraint);
      }
    }
    if (r[0] is! Uint8List || (r[0] as Uint8List).length != 32) {
      throw ZxDbException('${spec.name}.sha256 must be a 32 byte BLOB',
          ZxDbError.constraint);
    }
    for (var i = 0; i < r.length; i++) {
      final v = r[i];
      if (v is List && v is! Uint8List) r[i] = jsonEncode(v);
      if (v is Map) r[i] = jsonEncode(v);
      if (v is bool) r[i] = v ? 1 : 0;
    }
    return r;
  }

  static List<Object?> decodeRow(MetaTableSpec spec, Uint8List v) {
    final r = decodeRecord(v);
    while (r.length < spec.columns.length) {
      r.add(null);
    }
    return r;
  }

  /// The row with primary key [key], or null.
  List<Object?>? get(MetaTableSpec spec, List<Object?> key) {
    final t = tree(spec);
    if (t == null) return null;
    final v = t.get(encodeKey(key));
    return v == null ? null : decodeRow(spec, v);
  }

  /// Rows whose primary key starts with [prefix] (all rows when empty), in
  /// key order.
  Iterable<List<Object?>> scan(MetaTableSpec spec,
      [List<Object?> prefix = const []]) sync* {
    final t = tree(spec);
    if (t == null) return;
    Uint8List? from, to;
    if (prefix.isNotEmpty) {
      from = encodeKey(prefix);
      to = prefixEnd(from);
    }
    final c = t.scan(from: from, to: to);
    try {
      while (c.moveNext()) {
        yield decodeRow(spec, c.value);
      }
    } finally {
      c.close();
    }
  }

  /// Writes [row]; with [replace] false an existing key is an error.
  void put(MetaTableSpec spec, List<Object?> row, {bool replace = true}) {
    final r = _normalize(spec, row);
    final t = _wtree(spec);
    final k = keyOf(spec, r);
    if (!replace && t.get(k) != null) {
      throw ZxDbException(
          'UNIQUE constraint failed: ${spec.name} primary key',
          ZxDbError.constraint);
    }
    t.put(k, encodeRecord(r));
    _touched(spec, r[0] as Uint8List);
  }

  /// Deletes the row with key [key]; true when it existed.
  bool delete(MetaTableSpec spec, List<Object?> key) {
    final t = _wtree(spec);
    final ok = t.delete(encodeKey(key));
    if (ok && key.isNotEmpty && key[0] is Uint8List) {
      _touched(spec, key[0] as Uint8List);
    }
    return ok;
  }

  /// Deletes every row of [spec] whose key starts with [prefix].
  int deletePrefix(MetaTableSpec spec, List<Object?> prefix) {
    final t = _wtree(spec);
    final from = encodeKey(prefix);
    final n = t.deleteRange(from: from, to: prefixEnd(from));
    if (n > 0 && prefix.isNotEmpty && prefix[0] is Uint8List) {
      _touched(spec, prefix[0] as Uint8List);
    }
    return n;
  }

  /// Deletes everything known about [sha256] in the four tables.
  void deleteFile(Uint8List sha256) {
    for (final spec in ZxMetaSchema.all) {
      deletePrefix(spec, [sha256]);
    }
  }

  void _touched(MetaTableSpec spec, Uint8List sha) {
    if (spec.name != ZxMetaSchema.meta.name &&
        spec.name != ZxMetaSchema.layers.name) {
      return;
    }
    final d = _dirty;
    if (d != null) {
      d.add(String.fromCharCodes(sha));
    } else {
      fts.reindex(sha);
    }
  }

  /// Runs [body] with the full-text maintenance deferred to its end (one
  /// reindex per file changed).
  T batch<T>(T Function() body) {
    if (_dirty != null) return body();
    _dirty = <String>{};
    try {
      return body();
    } finally {
      final d = _dirty!;
      _dirty = null;
      for (final k in d) {
        fts.reindex(Uint8List.fromList(k.codeUnits));
      }
    }
  }

  // ---- typed helpers

  List<Object?>? meta(Uint8List sha256) =>
      get(ZxMetaSchema.meta, [sha256]);

  List<List<Object?>> layersOf(Uint8List sha256) =>
      scan(ZxMetaSchema.layers, [sha256]).toList();

  List<List<Object?>> mediaOf(Uint8List sha256) =>
      scan(ZxMetaSchema.media, [sha256]).toList();

  List<List<Object?>> fingerprintsOf(Uint8List sha256) =>
      scan(ZxMetaSchema.fingerprints, [sha256]).toList();

  /// Decodes an ARRAY column value (JSON text) to strings.
  static List<String> tagsOf(Object? v) {
    if (v is List) return [for (final x in v) '$x'];
    if (v is! String || v.isEmpty) return const [];
    try {
      final l = jsonDecode(v);
      if (l is List) return [for (final x in l) '$x'];
    } on FormatException {
      // a plain text value: one tag
    }
    return [v];
  }
}

// ---------------------------------------------------------------------------
// SQL exposure

/// Where the metadata tables read from and write to (sys_vtab.dart).
typedef ZxMetaAccess = SysDbAccess;

/// A [ZxMetaAccess] over a store: reads see the open transaction when
/// there is one; writes need one ([begin] or an outer transaction set in
/// [txn]).
class ZxStoreMetaAccess implements ZxMetaAccess {
  final ZxStore store;
  ZxWriteTxn? txn;
  ZxStoreMetaAccess(this.store, [this.txn]);

  @override
  (ZxSnapshot, void Function()) read(SysAsOf? asOf) {
    if (asOf == null) {
      final t = txn;
      if (t != null) return (t, () {});
      final s = store.snapshot();
      return (s, s.close);
    }
    final ZxSnapshot s;
    if (asOf.generation != null) {
      s = store.snapshot(generation: asOf.generation);
    } else if (asOf.date != null) {
      final end = zxParseGenerationDate(asOf.date!);
      if (end == null) {
        throw ZxDbException('bad date "${asOf.date}"', ZxDbError.syntax);
      }
      s = store.snapshot(atTimeNs: end - 1);
    } else {
      s = store.snapshot(atTimeNs: asOf.timeNs);
    }
    return (s, s.close);
  }

  @override
  ZxWriteTxn get writeTxn {
    final t = txn;
    if (t == null) {
      throw const ZxDbException(
          'no write transaction is open', ZxDbError.readOnly);
    }
    return t;
  }
}

/// One metadata table as a writable virtual table.
class ZxMetaVTable extends SysWritableVTable {
  final MetaTableSpec spec;
  final ZxMetaAccess access;
  ZxMetaVTable(this.spec, this.access);

  @override
  String get name => spec.name;
  @override
  List<SysColumn> get columns => spec.columns;
  @override
  List<int> get primaryKey => spec.primaryKey;

  // idxNum = number of leading primary key columns fixed by equality.
  @override
  void bestIndex(SysIndexInfo info) {
    var fixed = 0;
    for (final col in spec.primaryKey) {
      var found = -1;
      for (var i = 0; i < info.constraints.length; i++) {
        final c = info.constraints[i];
        if (c.usable && c.column == col && c.op == SysOp.eq) {
          found = i;
          break;
        }
      }
      if (found < 0) break;
      info.use(found);
      fixed++;
    }
    info.idxNum = fixed;
    info.estimatedCost = fixed == spec.primaryKey.length
        ? 1
        : fixed > 0
            ? 10
            : 10000;
    info.estimatedRows = fixed == spec.primaryKey.length ? 1 : 1000;
    final ob = info.orderBy;
    var inOrder = ob.isNotEmpty && ob.length <= spec.primaryKey.length;
    for (var i = 0; inOrder && i < ob.length; i++) {
      inOrder = ob[i].column == spec.primaryKey[i] && !ob[i].desc;
    }
    info.orderByConsumed = inOrder;
  }

  @override
  SysCursor open(SysIndexInfo info, List<Object?> args, {SysAsOf? asOf}) {
    final (s, release) = access.read(asOf);
    try {
      final db = ZxMetaDb(s);
      final prefix = args.sublist(0, info.idxNum);
      // a key column compared with a value of another type matches nothing
      final rows = db.scan(spec, prefix).toList();
      return SysListCursor(rows);
    } finally {
      release();
    }
  }

  ZxMetaDb get _db => ZxMetaDb(access.writeTxn);

  @override
  void insert(List<Object?> row, {bool replace = false}) =>
      _db.put(spec, row, replace: replace);

  @override
  List<Object?>? rowByKey(List<Object?> key) => _db.get(spec, key);

  @override
  void update(List<Object?> oldKey, List<Object?> row) {
    final db = _db;
    db.batch(() {
      final newKey = [for (final i in spec.primaryKey) row[i]];
      if (encodeKey(newKey).toString() != encodeKey(oldKey).toString()) {
        db.delete(spec, oldKey);
      }
      db.put(spec, row);
    });
  }

  @override
  bool delete(List<Object?> key) => _db.delete(spec, key);
}

/// The four metadata tables over [access].
List<ZxMetaVTable> zxMetaTables(ZxMetaAccess access) =>
    [for (final s in ZxMetaSchema.all) ZxMetaVTable(s, access)];
