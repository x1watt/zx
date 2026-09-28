// The public entry of zxdb, the database inside a .zx archive
// (docs/zxdb-design.md): ZxDatabase.open gives the store (ZxStore, which
// the SQL engine uses), the key-value stores, the generations and
// snapshots, fold and vacuum. Synchronous: Flutter apps use
// ZxDatabaseAsync (zxdb_async.dart), which runs it in a worker isolate.
//
// Every commit made here runs the hooks of the database layer first: the
// metadata tables are created with the database (meta/meta_store.dart),
// and the TLSH band index takes the digests of the file generations
// written since it was last brought up to date (system/tlsh_index.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'engine/store.dart';
import 'kv.dart';
import 'kv_sql.dart';
import 'meta/meta_store.dart';
import 'sql/zx_sql.dart';
import 'storage_api.dart';
import 'system/archive_view.dart';
import 'system/sql_adapter.dart';
import 'system/tlsh_index.dart';
import 'ts/ts_api.dart';
import 'ts/ts_sql.dart';

export 'engine/store.dart' show ZxDbStore, ZxDbStoreOptions, ZxDbFoldResult;
export 'kv.dart';
export 'storage_api.dart';
export 'ts/ts_api.dart';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// A database in a .zx archive.
class ZxDatabase {
  final ZxDbStore store;
  final String? _password;

  /// With group commit, writes of the KV API gather in one transaction
  /// that is committed when this window has passed (at the next write,
  /// or by a timer when the isolate's event loop runs), by [flush], and
  /// by [close]. Their changes are durable only then.
  final Duration? groupCommit;

  /// Bring the TLSH band index up to date at each commit (when a file
  /// generation was written since).
  bool syncTlsh = true;

  /// The clock of the TTLs (ms since epoch); tests may set it.
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  ZxWriteTxn? _pending;
  final List<ZxKvChange> _pendingChanges = [];
  DateTime? _pendingSince;
  Timer? _timer;
  ZxSnapshot? _snap;
  int _snapGen = -1;
  final StreamController<ZxKvChange> _changes =
      StreamController<ZxKvChange>.broadcast(sync: true);
  bool _closed = false;

  /// Called after each commit made here with its generation (the async
  /// API folds in the background from it).
  void Function(int generation)? onCommit;

  ZxDatabase._(this.store, this._password, this.groupCommit);

  /// Opens the database of the archive at [archivePath]. With [create] a
  /// missing archive is made, and the metadata tables are created in a
  /// new database. [options] tune the store (page size, caches, default
  /// compression 'max'...).
  static ZxDatabase open(String archivePath,
      {String? password,
      bool readOnly = false,
      bool create = false,
      Duration? groupCommit,
      ZxDbStoreOptions? options}) {
    final st = ZxDbStore.open(archivePath,
        password: password,
        readOnly: readOnly,
        create: create,
        options: options);
    final db = ZxDatabase._(st, password, groupCommit);
    st.beforeCommit = db._beforeCommit;
    st.afterCommit = (g) => db.onCommit?.call(g);
    if (create && !readOnly && st.root == null) {
      db.transaction((t) {}, comment: 'database initialized', force: true);
    }
    return db;
  }

  bool get readOnly => store.readOnly;
  String get path => store.path;

  void _checkOpen() {
    if (_closed) throw StateError('the database is closed');
  }

  /// The changes of every KV store committed by this process.
  Stream<ZxKvChange> get changes => _changes.stream;

  // ---- reading

  /// The state reads see: the pending group commit, else the last
  /// generation (checked for commits of other writers at each call).
  ZxSnapshot readSnapshot() {
    _checkOpen();
    final p = _pending;
    if (p != null) return p;
    final g = store.lastGeneration;
    var s = _snap;
    if (s == null || _snapGen != g) {
      s?.close();
      s = _snap = store.snapshot();
      _snapGen = s.generation;
    }
    return s;
  }

  /// A snapshot of the last generation, of generation [generation], or of
  /// the last one at or before [atTimeNs].
  ZxSnapshot snapshot({int? generation, int? atTimeNs}) {
    _checkOpen();
    return store.snapshot(generation: generation, atTimeNs: atTimeNs);
  }

  /// Generations with times, oldest first.
  List<({int generation, int timeNs, String? comment})> get generations =>
      store.generations;

  // ---- writing

  /// Runs [f] in a write transaction and commits it (one generation);
  /// returns [f]'s result. A pending group commit is committed first.
  /// [waitMs]: how long to wait for another writer.
  T transaction<T>(T Function(ZxWriteTxn t) f,
      {String? comment, int waitMs = 5000, bool force = false}) {
    _checkOpen();
    flush();
    final t = store.begin(waitMs: waitMs);
    try {
      final r = f(t);
      _commit(t, comment, force: force);
      return r;
    } catch (_) {
      _rollbackQuietly(t);
      rethrow;
    }
  }

  void _rollbackQuietly(ZxWriteTxn t) {
    try {
      t.rollback();
    } on StateError {
      // committed or closed
    }
  }

  // the commit hooks (every commit of the store, SQL ones included)
  void _beforeCommit(ZxWriteTxn t) {
    if (store.root == null) {
      // a new database gets the metadata tables
      ZxMetaSchema.create(t);
    }
    if (syncTlsh) _syncTlsh(t);
  }

  int _commit(ZxWriteTxn t, String? comment, {bool force = false}) {
    if (force && t.tree(zxKvMetaTree) == null) t.createTree(zxKvMetaTree);
    return t.commit(comment: comment);
  }

  void _syncTlsh(ZxWriteTxn t) {
    final done = ZxTlshStore.indexedGeneration(t) ?? 0;
    var need = false;
    for (final g in store.archiveGenerations) {
      if (g.number > done && g.added > 0) need = true;
    }
    if (!need) return;
    final v = ZxArchiveView.open(store.path, password: _password);
    if (v == null) return;
    try {
      ZxTlshStore.sync(t, v);
    } finally {
      v.close();
    }
  }

  /// Commits the pending group commit now.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final p = _pending;
    if (p == null) return;
    _pending = null;
    _pendingSince = null;
    final changes = List.of(_pendingChanges);
    _pendingChanges.clear();
    int g;
    try {
      g = _commit(p, 'group commit');
    } catch (_) {
      _rollbackQuietly(p);
      rethrow;
    }
    _emit(changes, g);
  }

  void _emit(List<ZxKvChange> changes, int g) {
    if (!_changes.hasListener) return;
    for (final c in changes) {
      _changes.add(ZxKvChange(c.store, c.key, c.value, g));
    }
  }

  // runs [f] in the pending group commit, or in its own transaction
  void _write(void Function(ZxWriteTxn t, List<ZxKvChange> changes) f) {
    _checkOpen();
    if (readOnly) {
      throw const ZxDbException('the database is read only', ZxDbError.readOnly);
    }
    final window = groupCommit;
    if (window == null) {
      final t = store.begin();
      final changes = <ZxKvChange>[];
      int g;
      try {
        f(t, changes);
        g = _commit(t, null);
      } catch (_) {
        _rollbackQuietly(t);
        rethrow;
      }
      _emit(changes, g);
      return;
    }
    var p = _pending;
    if (p == null) {
      p = _pending = store.begin();
      _pendingSince = DateTime.now();
      _timer = Timer(window, () {
        if (!_closed) flush();
      });
    }
    try {
      f(p, _pendingChanges);
    } catch (_) {
      // a failed write drops the whole pending transaction
      _pending = null;
      _pendingChanges.clear();
      _timer?.cancel();
      _rollbackQuietly(p);
      rethrow;
    }
    if (DateTime.now().difference(_pendingSince!) >= window) flush();
  }

  // ---- SQL

  ZxSql? _sql;
  ZxArchiveView? _view;

  /// A SQL session on this database (docs/zxdb-sql.md), made on first
  /// use: the tables of the SQL catalog, the system tables over the
  /// archive's files (as they were when the session was made, also after
  /// a VACUUM; [resetSql] makes a new session), the metadata tables, and
  /// the KV stores as tables `name (key, value)`; CREATE KV STORE, DROP
  /// KV STORE and VACUUM work. Writes of SQL to KV stores are not seen by
  /// [ZxKvStore.watch].
  ZxSql get sql {
    _checkOpen();
    final have = _sql;
    if (have != null) return have;
    final q = ZxSql(store);
    final v = _view = ZxArchiveView.open(store.path, password: _password);
    ZxSystemSql(archive: v, database: true)
        .register(q.registerVirtualTable, q.functions);
    zxTsRegisterSql(q, nowMs: () => nowMs());
    zxKvRegisterSql(q,
        vacuum: (ultra) => vacuum(ultra: ultra, recompress: ultra));
    return _sql = q;
  }

  /// Closes the SQL session (an open SQL transaction is rolled back); the
  /// next use of [sql] makes a new one that sees the archive as it is.
  void resetSql() {
    _sql?.close();
    _sql = null;
    _view?.close();
    _view = null;
  }

  // ---- key-value stores

  /// The settings of KV store [name] (at snapshot [at]).
  ZxKvSettings kvSettings(String name, {ZxSnapshot? at}) {
    final m = (at ?? readSnapshot()).tree(zxKvMetaTree);
    final v = m?.get(_utf8(name));
    if (v == null) {
      throw ZxDbException('no KV store "$name"', ZxDbError.notFound);
    }
    return ZxKvSettings.decode(v);
  }

  /// The names of the KV stores.
  List<String> get kvStores {
    final m = readSnapshot().tree(zxKvMetaTree);
    if (m == null) return const [];
    final out = <String>[];
    final c = m.scan();
    while (c.moveNext()) {
      out.add(utf8.decode(c.key));
    }
    return out;
  }

  /// KV store [name]: the current state (writable), or its state at a
  /// generation or a time (read only). Throws ZxDbException(notFound).
  ZxKvStore kv(String name, {int? generation, int? atTimeNs}) {
    _checkOpen();
    final at = generation == null && atTimeNs == null
        ? null
        : store.snapshot(generation: generation, atTimeNs: atTimeNs);
    kvSettings(name, at: at);
    return ZxKvStore(this, name, at: at);
  }

  /// Creates KV store [name] with a default [ttl] and a [compression]
  /// ('fast' by default: KV reads want speed; any TreeOptions name).
  ZxKvStore createKvStore(String name,
      {Duration? ttl, String? compression = 'fast', int? pageSize}) {
    if (name.isEmpty) {
      throw const ZxDbException('empty KV store name', ZxDbError.constraint);
    }
    _write((t, _) {
      final meta = t.tree(zxKvMetaTree) ?? t.createTree(zxKvMetaTree);
      if (meta.get(_utf8(name)) != null) {
        throw ZxDbException('KV store "$name" exists', ZxDbError.constraint);
      }
      t.createTree(zxKvTreeName(name),
          TreeOptions(compression: compression, pageSize: pageSize));
      meta.put(_utf8(name),
          ZxKvSettings(ttl?.inMilliseconds, ttl != null).encode());
    });
    return ZxKvStore(this, name);
  }

  /// Drops KV store [name] and its data.
  void dropKvStore(String name) {
    _write((t, _) {
      final meta = t.tree(zxKvMetaTree);
      if (meta == null || meta.get(_utf8(name)) == null) {
        throw ZxDbException('no KV store "$name"', ZxDbError.notFound);
      }
      meta.delete(_utf8(name));
      t.dropTree(zxKvTreeName(name));
    });
  }

  /// Applies writes of KV store [name]: (key, value or null to delete,
  /// ttl).
  void kvApply(String name, List<(Uint8List, Uint8List?, Duration?)> ops) {
    _write((t, changes) {
      final meta = t.tree(zxKvMetaTree);
      final mv = meta?.get(_utf8(name));
      final tree = t.tree(zxKvTreeName(name));
      if (mv == null || tree == null) {
        throw ZxDbException('no KV store "$name"', ZxDbError.notFound);
      }
      final s = ZxKvSettings.decode(mv);
      final now = nowMs();
      var expiring = false;
      for (final (key, value, ttl) in ops) {
        if (value == null) {
          tree.delete(key);
          changes.add(ZxKvChange(name, Uint8List.fromList(key), null, 0));
          continue;
        }
        final ms = ttl?.inMilliseconds ?? s.ttlMs;
        if (ms != null) expiring = true;
        tree.put(key, zxKvEncode(value, ms == null ? null : now + ms));
        changes.add(ZxKvChange(
            name, Uint8List.fromList(key), Uint8List.fromList(value), 0));
      }
      if (expiring && !s.mayExpire) {
        meta!.put(_utf8(name), ZxKvSettings(s.ttlMs, true).encode());
      }
    });
  }

  /// Removes the expired values of KV store [name]; returns how many.
  int kvPurge(String name) {
    var n = 0;
    _write((t, changes) {
      final tree = t.tree(zxKvTreeName(name));
      if (tree == null) {
        throw ZxDbException('no KV store "$name"', ZxDbError.notFound);
      }
      final now = nowMs();
      final doomed = <Uint8List>[];
      final c = tree.scan();
      while (c.moveNext()) {
        final d = zxKvDecode(c.value);
        final e = d?.expiresAtMs;
        if (e != null && e <= now) doomed.add(c.key);
      }
      for (final k in doomed) {
        tree.delete(k);
        changes.add(ZxKvChange(name, k, null, 0));
      }
      n = doomed.length;
    });
    return n;
  }

  // the stores whose values may expire
  List<String> _expiringStores() {
    final m = readSnapshot().tree(zxKvMetaTree);
    if (m == null) return const [];
    final out = <String>[];
    final c = m.scan();
    while (c.moveNext()) {
      if (ZxKvSettings.decode(c.value).mayExpire) out.add(utf8.decode(c.key));
    }
    return out;
  }

  // ---- maintenance

  /// Removes expired KV values, then folds the write buffer
  /// (ZxDbStore.fold).
  ZxDbFoldResult fold() {
    _checkOpen();
    flush();
    if (!readOnly) {
      for (final s in _expiringStores()) {
        kvPurge(s);
      }
    }
    return store.fold();
  }

  /// VACUUM: removes expired KV values, then compacts the archive keeping
  /// the last [keep] generations; [recompress] codes every page again
  /// with its tree's chain, [ultra] with the strongest (VACUUM ULTRA).
  /// Returns the bytes freed.
  int vacuum({int keep = 1, bool recompress = false, bool ultra = false}) {
    _checkOpen();
    flush();
    for (final s in _expiringStores()) {
      kvPurge(s);
    }
    if (!readOnly) sealAllSeries(); // time series: segments, retention
    _snap?.close();
    _snap = null;
    return store.vacuum(keep: keep, recompress: recompress, ultra: ultra);
  }

  /// Commits a pending group commit and closes the archive.
  void close() {
    if (_closed) return;
    try {
      flush();
    } finally {
      _closed = true;
      _timer?.cancel();
      _snap?.close();
      _sql?.close();
      _view?.close();
      store.close();
      _changes.close();
    }
  }
}
