// KV stores seen from SQL (docs/zxdb-design.md 2.2): the store "name" is
// a table `name (key, value)` with a hidden column `expires` (ms since
// 1970-01-01 UTC, NULL for none), and the statements CREATE KV STORE,
// DROP KV STORE and VACUUM of the SQL dialect are run here
// (ZxDatabase.sql wires them).
//
// Keys and values are bytes; a column gives TEXT when the bytes are valid
// UTF-8, else BLOB. Written values: TEXT as UTF-8, BLOB as is, numbers as
// their text. Expired values are not rows. A key constraint (=, <, <=, >,
// >=, LIKE 'prefix%') narrows the scan; the executor still tests every
// constraint, so the narrowing only has to keep the rows that match.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'kv.dart';
import 'sql/ast.dart';
import 'sql/zx_sql.dart';
import 'storage_api.dart';

Object? _sqlBytes(Uint8List b) {
  try {
    return const Utf8Decoder(allowMalformed: false).convert(b);
  } on FormatException {
    return Uint8List.fromList(b);
  }
}

Uint8List? _bytesOf(Object? v) {
  if (v == null) return null;
  if (v is Uint8List) return v;
  if (v is String) return Uint8List.fromList(utf8.encode(v));
  return Uint8List.fromList(utf8.encode('$v'));
}

// the key after every key that starts with k (k + 0x00 is the next key)
Uint8List _after(Uint8List k) => Uint8List(k.length + 1)..setRange(0, k.length, k);

/// A KV store as a SQL table.
class ZxKvSqlTable extends ZxWritableVirtualTable {
  final String store;

  // the keys of the rows handed out, by rowid (UPDATE and DELETE name
  // rows by rowid); bounded
  final LinkedHashMap<int, Uint8List> _rows = LinkedHashMap();
  int _nextRowid = 1;

  ZxKvSqlTable(this.store);

  String get treeName => zxKvTreeName(store);

  @override
  List<ZxVtabColumn> get columns => const [
        ZxVtabColumn('key'),
        ZxVtabColumn('value'),
        ZxVtabColumn('expires', 'INTEGER', true),
      ];

  static const _ops = {
    ZxConstraintOp.eq: 'eq',
    ZxConstraintOp.gt: 'gt',
    ZxConstraintOp.ge: 'ge',
    ZxConstraintOp.lt: 'lt',
    ZxConstraintOp.le: 'le',
    ZxConstraintOp.like: 'like',
  };

  @override
  void bestIndex(ZxIndexInfo info) {
    final used = <String>[];
    var n = 0;
    for (var i = 0; i < info.constraints.length; i++) {
      final c = info.constraints[i];
      final op = _ops[c.op];
      if (c.column != 0 || !c.usable || op == null) continue;
      info.argvIndex[i] = ++n;
      used.add(op);
    }
    info.idxStr = used.join(',');
    info.idxNum = used.isEmpty ? 0 : 1;
    info.estimatedCost = used.contains('eq') ? 10 : used.isEmpty ? 1e6 : 1e4;
  }

  int _rowid(Uint8List key) {
    final id = _nextRowid++;
    _rows[id] = key;
    if (_rows.length > (1 << 20)) _rows.remove(_rows.keys.first);
    return id;
  }

  Uint8List _keyOf(int rowid) {
    final k = _rows[rowid];
    if (k == null) {
      throw ZxDbException('unknown row $rowid of KV store "$store"');
    }
    return k;
  }

  ZxTree _tree(ZxSnapshot s) {
    final t = s.tree(treeName);
    if (t == null) {
      throw ZxDbException('no KV store "$store"', ZxDbError.notFound);
    }
    return t;
  }

  ZxWritableTree _wtree(ZxVtabContext ctx) {
    final txn = ctx.txn;
    if (txn == null) {
      throw const ZxDbException('no write transaction', ZxDbError.readOnly);
    }
    final t = txn.tree(treeName);
    if (t == null) {
      throw ZxDbException('no KV store "$store"', ZxDbError.notFound);
    }
    return t;
  }

  @override
  ZxVtabCursor open(ZxVtabContext ctx) => _KvSqlCursor(this, ctx);

  bool _live(ZxWritableTree t, Uint8List key, int nowMs) {
    final v = t.get(key);
    return v != null && zxKvLive(v, nowMs) != null;
  }

  void _put(ZxWritableTree t, List<Object?> values) {
    final key = _bytesOf(values[0]);
    if (key == null) {
      throw const ZxDbException('a KV key is not NULL', ZxDbError.constraint);
    }
    final value = _bytesOf(values[1]) ?? Uint8List(0);
    final exp = values.length > 2 ? values[2] : null;
    t.put(key, zxKvEncode(value, exp is int ? exp : null));
  }

  @override
  int insert(ZxVtabContext ctx, int? rowid, List<Object?> values) =>
      insertOr(ctx, rowid, values, ZxConflictMode.abort)!;

  @override
  int? insertOr(ZxVtabContext ctx, int? rowid, List<Object?> values,
      ZxConflictMode mode) {
    final t = _wtree(ctx);
    final key = _bytesOf(values[0]);
    if (key != null && _live(t, key, ctx.nowNs ~/ 1000000)) {
      if (mode == ZxConflictMode.ignore) return null;
      if (mode != ZxConflictMode.replace) {
        throw ZxDbException(
            'UNIQUE constraint failed: $store.key', ZxDbError.constraint);
      }
    }
    _put(t, values);
    return _rowid(key!);
  }

  @override
  void update(ZxVtabContext ctx, int rowid, List<Object?> values) {
    final t = _wtree(ctx);
    final old = _keyOf(rowid);
    final key = _bytesOf(values[0]);
    if (key != null && zxCompareKeys(key, old) != 0) {
      if (_live(t, key, ctx.nowNs ~/ 1000000)) {
        throw ZxDbException(
            'UNIQUE constraint failed: $store.key', ZxDbError.constraint);
      }
      t.delete(old);
      _rows[rowid] = key;
    }
    _put(t, values);
  }

  @override
  void delete(ZxVtabContext ctx, int rowid) {
    _wtree(ctx).delete(_keyOf(rowid));
    _rows.remove(rowid);
  }
}

class _KvSqlCursor extends ZxVtabCursor {
  final ZxKvSqlTable t;
  final ZxVtabContext ctx;
  ZxCursor? _c;
  Uint8List? _key;
  Uint8List? _value;
  int? _exp;
  int _rowid = 0;
  final int _now;

  _KvSqlCursor(this.t, this.ctx) : _now = ctx.nowNs ~/ 1000000;

  @override
  void filter(int idxNum, String? idxStr, List<Object?> args) {
    Uint8List? from, to;
    void lower(Uint8List k) {
      if (from == null || zxCompareKeys(k, from!) > 0) from = k;
    }

    void upper(Uint8List k) {
      if (to == null || zxCompareKeys(k, to!) < 0) to = k;
    }

    final ops = idxStr == null || idxStr.isEmpty ? const <String>[] : idxStr.split(',');
    for (var i = 0; i < ops.length && i < args.length; i++) {
      final a = args[i];
      // only text and bytes narrow the scan (the byte order of the keys is
      // their SQL order); other values leave it whole
      if (a is! String && a is! Uint8List) continue;
      final k = _bytesOf(a)!;
      switch (ops[i]) {
        case 'eq':
          lower(k);
          upper(_after(k));
        case 'gt':
          lower(_after(k));
        case 'ge':
          lower(k);
        case 'lt':
          upper(k);
        case 'le':
          upper(_after(k));
        case 'like':
          if (a is! String) break;
          // the literal prefix before the first wildcard; LIKE ignores
          // ASCII case, so only a prefix without letters narrows
          var p = 0;
          while (p < a.length && a[p] != '%' && a[p] != '_') {
            p++;
          }
          final pre = a.substring(0, p);
          if (pre.isEmpty || RegExp('[A-Za-z]').hasMatch(pre)) break;
          final pb = Uint8List.fromList(utf8.encode(pre));
          lower(pb);
          final e = zxPrefixEnd(pb);
          if (e != null) upper(e);
      }
    }
    if (from != null && to != null && zxCompareKeys(from!, to!) >= 0) {
      _c = null;
      return;
    }
    _c = t._tree(ctx.snapshot).scan(from: from, to: to);
  }

  @override
  bool next() {
    final c = _c;
    if (c == null) return false;
    while (c.moveNext()) {
      final d = zxKvDecode(c.value);
      if (d == null) continue;
      final e = d.expiresAtMs;
      if (e != null && e <= _now) continue;
      _key = c.key;
      _value = d.value;
      _exp = e;
      _rowid = t._rowid(Uint8List.fromList(c.key));
      return true;
    }
    return false;
  }

  @override
  Object? column(int i) => switch (i) {
        0 => _sqlBytes(_key!),
        1 => _sqlBytes(_value!),
        _ => _exp,
      };

  @override
  int get rowid => _rowid;

  @override
  void close() {
    _c?.close();
    _c = null;
  }
}

/// Parses a duration of the SQL options ('7d', '12h', '30m', '10s',
/// '500ms', '2w', or a number of seconds).
Duration? zxParseDuration(Object? v) {
  if (v == null) return null;
  if (v is int) return Duration(seconds: v);
  if (v is double) return Duration(milliseconds: (v * 1000).round());
  final m = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)?\s*$')
      .firstMatch('$v'.toLowerCase());
  if (m == null) {
    throw ZxDbException('bad duration "$v"', ZxDbError.syntax);
  }
  final n = double.parse(m[1]!);
  final ms = switch (m[2]) {
    'ms' => n,
    'm' => n * 60000,
    'h' => n * 3600000,
    'd' => n * 86400000,
    'w' => n * 604800000,
    _ => n * 1000,
  };
  return Duration(milliseconds: ms.round());
}

/// Wires the KV stores into a SQL session: their tables (resolved by
/// name), CREATE KV STORE, DROP KV STORE. [vacuum] runs VACUUM.
void zxKvRegisterSql(ZxSql sql, {void Function(bool ultra)? vacuum}) {
  final tables = <String, ZxKvSqlTable>{};
  sql.addVirtualTableResolver((name, snap) {
    final kvMeta = snap.tree(zxKvMetaTree);
    if (kvMeta == null ||
        kvMeta.get(Uint8List.fromList(utf8.encode(name))) == null) {
      return null;
    }
    return tables[name] ??= ZxKvSqlTable(name);
  });
  sql.registerStatementHook('CREATE KV STORE', (stmt, ctx) {
    final s = stmt as CreateKvStoreStmt;
    final t = ctx.txn;
    if (t == null) {
      throw const ZxDbException('no write transaction', ZxDbError.readOnly);
    }
    final meta = t.tree(zxKvMetaTree) ?? t.createTree(zxKvMetaTree);
    final key = Uint8List.fromList(utf8.encode(s.name));
    if (meta.get(key) != null) {
      if (s.ifNotExists) return null;
      throw ZxDbException('KV store "${s.name}" exists', ZxDbError.constraint);
    }
    final o = {
      for (final e in s.options.entries) e.key.toLowerCase(): e.value
    };
    final ttl = zxParseDuration(o['ttl']);
    final ps = o['page_size'];
    t.createTree(
        zxKvTreeName(s.name),
        TreeOptions(
            compression: (o['compression'] as String?) ?? 'fast',
            pageSize: ps is int
                ? ps
                : ps is String
                    ? _size(ps)
                    : null));
    meta.put(key, ZxKvSettings(ttl?.inMilliseconds, ttl != null).encode());
    return null;
  });
  sql.registerStatementHook('DROP KV STORE', (stmt, ctx) {
    final s = stmt as DropStmt;
    final t = ctx.txn;
    if (t == null) {
      throw const ZxDbException('no write transaction', ZxDbError.readOnly);
    }
    final meta = t.tree(zxKvMetaTree);
    final key = Uint8List.fromList(utf8.encode(s.name));
    if (meta == null || meta.get(key) == null) {
      if (s.ifExists) return null;
      throw ZxDbException('no KV store "${s.name}"', ZxDbError.notFound);
    }
    meta.delete(key);
    t.dropTree(zxKvTreeName(s.name));
    tables.remove(s.name);
    return null;
  });
  if (vacuum != null) {
    sql.registerStatementHook('VACUUM', (stmt, ctx) {
      vacuum((stmt as VacuumStmt).mode?.toUpperCase() == 'ULTRA');
      return null;
    });
  }
}

int _size(String s) {
  final m = RegExp(r'^(\d+)\s*([kKmM]?)').firstMatch(s.trim());
  if (m == null) throw ZxDbException('bad size "$s"', ZxDbError.syntax);
  final n = int.parse(m[1]!);
  return switch (m[2]!.toLowerCase()) {
    'k' => n << 10,
    'm' => n << 20,
    _ => n,
  };
}
