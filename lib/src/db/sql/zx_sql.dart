// ZxSql: the SQL engine of zxdb over a ZxStore (docs/zxdb-sql.md).
//
//   final sql = ZxSql(store);
//   sql.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
//   sql.execute('INSERT INTO t (name) VALUES (?)', ['a']);
//   final r = sql.execute('SELECT * FROM t WHERE id = :id', {'id': 1});
//   final st = sql.prepare('SELECT name FROM t WHERE id > ?');
//   final cur = st.query([0]);            // streaming
//   while (cur.moveNext()) print(cur.current);
//   cur.close();
//
// Transactions: every statement runs in its own transaction (a snapshot
// for reads, one write transaction committed at the end for writes),
// unless BEGIN opened an explicit one, which spans until COMMIT or
// ROLLBACK and is one archive generation. A failing statement inside an
// explicit transaction leaves no partial changes (statement undo log).

import 'dart:typed_data';

import '../keycodec.dart';
import '../storage_api.dart';
import 'ast.dart';
import 'catalog.dart';
import 'dml.dart';
import 'eval.dart';
import 'functions.dart';
import 'parser.dart';
import 'planner.dart';
import 'sql_result.dart';
import 'value.dart';
import 'vtab.dart';

export 'functions.dart'
    show
        ZxFunctionRegistry,
        ZxScalarFunction,
        ZxAggregateFunction,
        ZxAggregateState,
        ZxFunctionContext;
export 'sql_result.dart';
export 'vtab.dart';

/// Streaming result of a query.
class ZxSqlCursor {
  final List<String> columns;

  /// Declared types of the columns, as [ZxSqlResult.types].
  final List<String?> types;
  final RowIter _it;
  final void Function() _onClose;
  bool _closed = false;
  List<Object?>? _cur;
  ZxSqlCursor._(this.columns, this._it, this._onClose, {this.types = const []});

  /// True when column [i] holds DATETIME values (ns since 1970 UTC).
  bool isDatetime(int i) => zxIsDatetimeType(i < types.length ? types[i] : null);

  bool moveNext() {
    if (_closed) return false;
    try {
      if (_it.moveNext()) {
        _cur = _it.current;
        return true;
      }
    } catch (_) {
      close();
      rethrow;
    }
    close();
    return false;
  }

  List<Object?> get current => _cur!;

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _it.close();
    } finally {
      _onClose();
    }
  }

  /// Reads the remaining rows and closes the cursor.
  List<List<Object?>> toList() {
    final out = <List<Object?>>[];
    while (moveNext()) {
      out.add(current);
    }
    return out;
  }
}

/// Context given to statement hooks (zx extension statements).
class ZxSqlHookContext {
  final ZxSql sql;

  /// The write transaction (null for VACUUM, which runs outside one).
  final ZxWriteTxn? txn;
  final ZxSnapshot snapshot;
  final List<Object?> params;
  const ZxSqlHookContext(this.sql, this.txn, this.snapshot, this.params);
}

/// Handles a parsed zx statement (CreateKvStoreStmt, CreateTimeseriesStmt,
/// CreateRollupStmt, DropStmt of those kinds, VacuumStmt). Returns a
/// result or null (no rows).
typedef ZxSqlStatementHook = ZxSqlResult? Function(
    Stmt stmt, ZxSqlHookContext ctx);

/// A prepared statement (parsed once; planned per execution).
class ZxSqlStatement {
  final ZxSql _sql;
  final ParsedScript _script;
  final String sql;
  ZxSqlStatement._(this._sql, this._script, this.sql);

  /// Number of parameters (highest index).
  int get parameterCount => _script.paramNames.length;

  /// Names of the parameters by index (null for anonymous ones).
  List<String?> get parameterNames => _script.paramNames;

  ZxSqlResult execute([Object? params]) =>
      _sql._executeScript(_script, params);

  ZxSqlCursor query([Object? params]) => _sql._query(_script, params);

  List<List<Object?>> select([Object? params]) => query(params).toList();
}

class ZxSql {
  final ZxStore store;
  final SqlEnv _env;
  final Map<String, ZxSqlStatementHook> _hooks = {};
  ZxWriteTxn? _txn;
  Catalog? _catalog;
  int _lastRowid = 0;
  int _changes = 0;
  int _totalChanges = 0;
  final Map<String, ParsedScript> _parseCache = {};

  ZxSql(this.store, {ZxFunctionRegistry? functions})
      : _env = SqlEnv(store, functions ?? ZxFunctionRegistry());

  /// Scalar and aggregate functions (register more here).
  ZxFunctionRegistry get functions => _env.functions;

  /// Makes [name] a table (an eponymous virtual table).
  void registerVirtualTable(String name, ZxVirtualTable vt) {
    _env.vtabs[name.toLowerCase()] = vt;
  }

  /// Resolves table names not in the catalog (called with the name and
  /// the snapshot of the statement).
  void addVirtualTableResolver(
      ZxVirtualTable? Function(String name, ZxSnapshot snap) resolver) {
    _env.resolvers.add(resolver);
  }

  /// Registers the handler of a zx statement kind: 'CREATE KV STORE',
  /// 'DROP KV STORE', 'CREATE TIMESERIES', 'DROP TIMESERIES',
  /// 'CREATE ROLLUP', 'DROP ROLLUP', 'VACUUM'.
  void registerStatementHook(String kind, ZxSqlStatementHook hook) {
    _hooks[kind.toUpperCase()] = hook;
  }

  bool get inTransaction => _txn != null;
  int get lastInsertRowid => _lastRowid;
  int get changes => _changes;
  int get totalChanges => _totalChanges;

  /// Runs one or more statements; returns the result of the last one.
  ZxSqlResult execute(String sql, [Object? params]) =>
      _executeScript(_parse(sql), params);

  /// Prepares a statement (or a script).
  ZxSqlStatement prepare(String sql) => ZxSqlStatement._(this, _parse(sql), sql);

  /// Runs a query and returns a streaming cursor. Close it (or read it to
  /// the end) to release its snapshot.
  ZxSqlCursor query(String sql, [Object? params]) => _query(_parse(sql), params);

  /// Rows of a query.
  List<List<Object?>> select(String sql, [Object? params]) =>
      query(sql, params).toList();

  /// Rolls back an open transaction.
  void close() {
    if (_txn != null) {
      _txn!.rollback();
      _txn = null;
    }
  }

  ParsedScript _parse(String sql) {
    final c = _parseCache[sql];
    if (c != null) return c;
    final p = Parser.parse(sql);
    if (_parseCache.length > 256) _parseCache.clear();
    _parseCache[sql] = p;
    return p;
  }

  List<Object?> _bind(ParsedScript s, Object? params) {
    final n = s.paramNames.length;
    final out = List<Object?>.filled(n, null);
    if (params == null) return out;
    if (params is List) {
      for (var i = 0; i < n && i < params.length; i++) {
        out[i] = fromDart(params[i]);
      }
      if (params.length > n && n > 0) {
        throw ZxDbException('too many parameters: ${params.length} for $n');
      }
      return out;
    }
    if (params is Map) {
      for (var i = 0; i < n; i++) {
        final name = s.paramNames[i];
        if (name == null) {
          if (params.containsKey(i + 1)) out[i] = fromDart(params[i + 1]);
          continue;
        }
        if (params.containsKey(name)) {
          out[i] = fromDart(params[name]);
        } else if (params.containsKey(name.substring(1))) {
          out[i] = fromDart(params[name.substring(1)]);
        }
      }
      return out;
    }
    throw ArgumentError('params must be a List or a Map');
  }

  int _now() => DateTime.now().microsecondsSinceEpoch * 1000;

  Catalog _catalogFor(ZxSnapshot snap) {
    final v = Catalog.readVersion(snap);
    final c = _catalog;
    if (c != null && c.version == v) return c;
    final n = Catalog.load(snap);
    n.version = v;
    _catalog = n;
    return n;
  }

  ZxSqlResult _executeScript(ParsedScript s, Object? params) {
    final p = _bind(s, params);
    ZxSqlResult r = const ZxSqlResult([], [], 0, 0);
    for (final st in s.statements) {
      r = _run(st, p);
    }
    return r;
  }

  ZxSqlCursor _query(ParsedScript s, Object? params) {
    final p = _bind(s, params);
    if (s.statements.isEmpty) {
      return ZxSqlCursor._(const [], ListIter(const []), () {});
    }
    for (var i = 0; i < s.statements.length - 1; i++) {
      _run(s.statements[i], p);
    }
    final st = s.statements.last;
    if (st is! SelectStmt) {
      final r = _run(st, p);
      return ZxSqlCursor._(r.columns, ListIter(r.rows), () {}, types: r.types);
    }
    final snap = _txn ?? store.snapshot();
    final own = _txn == null;
    try {
      final ctx = _ctx(snap, null, p);
      final plan = Planner(ctx).planSelect(st, null, null);
      final it = plan.open(null);
      return ZxSqlCursor._(plan.columns, it, () {
        ctx.closeExtra();
        if (own) snap.close();
      }, types: _typesOf(plan));
    } catch (_) {
      if (own) snap.close();
      rethrow;
    }
  }

  static List<String?> _typesOf(SelectPlan plan) => [
        for (final e in plan.colInfo)
          e.declType ?? (e.aff == Affinity.timeNs ? 'DATETIME' : null)
      ];

  ExecCtx _ctx(ZxSnapshot snap, ZxWriteTxn? txn, List<Object?> params) =>
      ExecCtx(_env, snap, txn, _catalogFor(snap), params, _now(),
          lastRowid: _lastRowid, totalChangesBase: _totalChanges);

  static bool _isRead(Stmt st) =>
      st is SelectStmt ||
      st is ExplainStmt ||
      (st is PragmaStmt && (st.value == null || st.call)) ||
      st is NoopStmt;

  ZxSqlResult _run(Stmt st, List<Object?> params) {
    if (st is TxnStmt) return _txnStmt(st);
    if (st is VacuumStmt) {
      final h = _hooks['VACUUM'];
      if (h == null) {
        throw const ZxDbException('VACUUM is not yet supported', ZxDbError.unsupported);
      }
      final snap = _txn ?? store.snapshot();
      try {
        return h(st, ZxSqlHookContext(this, null, snap, params)) ??
            const ZxSqlResult([], [], 0, 0);
      } finally {
        if (_txn == null) snap.close();
      }
    }
    if (_isRead(st) && !(st is PragmaStmt && _pragmaWrites(st))) {
      final snap = _txn ?? store.snapshot();
      final ctx = _ctx(snap, _txn, params);
      try {
        return _readStmt(st, ctx);
      } finally {
        ctx.closeExtra();
        if (_txn == null) snap.close();
      }
    }
    // Writes.
    final explicit = _txn != null;
    final txn = _txn ?? store.begin();
    final ctx = _ctx(txn, txn, params);
    if (explicit) ctx.undo = UndoLog();
    try {
      final r = _writeStmt(st, ctx);
      if (!explicit) txn.commit();
      _changes = ctx.nChanges;
      _totalChanges += ctx.nChanges;
      _lastRowid = ctx.lastRowid;
      return ZxSqlResult(r.columns, r.rows, ctx.nChanges, ctx.lastRowid);
    } on RollbackSignal catch (e) {
      _catalog = null;
      if (explicit) {
        ctx.undo = null;
        _txn!.rollback();
        _txn = null;
      } else {
        txn.rollback();
      }
      throw e.error;
    } catch (_) {
      _catalog = null;
      if (explicit) {
        ctx.undo?.undo();
      } else {
        try {
          txn.rollback();
        } catch (_) {}
      }
      rethrow;
    } finally {
      ctx.closeExtra();
    }
  }

  bool _pragmaWrites(PragmaStmt p) =>
      p.value != null && !p.call && p.name == 'user_version';

  ZxSqlResult _txnStmt(TxnStmt st) {
    switch (st.kind) {
      case 'BEGIN':
        if (_txn != null) {
          throw const ZxDbException(
              'cannot start a transaction within a transaction');
        }
        _txn = store.begin();
        return const ZxSqlResult([], [], 0, 0);
      case 'COMMIT':
        if (_txn == null) {
          throw const ZxDbException(
              'cannot commit - no transaction is active');
        }
        final t = _txn!;
        _txn = null;
        t.commit();
        return const ZxSqlResult([], [], 0, 0);
      case 'ROLLBACK':
        if (_txn == null) {
          throw const ZxDbException(
              'cannot rollback - no transaction is active');
        }
        final t = _txn!;
        _txn = null;
        _catalog = null;
        t.rollback();
        return const ZxSqlResult([], [], 0, 0);
    }
    throw ZxDbException('${st.kind} is not supported', ZxDbError.unsupported);
  }

  // ---------------------------------------------------------- reads

  ZxSqlResult _readStmt(Stmt st, ExecCtx ctx) {
    if (st is SelectStmt) {
      final plan = Planner(ctx).planSelect(st, null, null);
      return ZxSqlResult(plan.columns, drain(plan.open(null)), 0, _lastRowid,
          types: _typesOf(plan));
    }
    if (st is ExplainStmt) return _explain(st, ctx);
    if (st is PragmaStmt) return _pragma(st, ctx);
    return const ZxSqlResult([], [], 0, 0);
  }

  ZxSqlResult _explain(ExplainStmt st, ExecCtx ctx) {
    ctx.eqp = [];
    final pl = Planner(ctx);
    final s = st.stmt;
    if (s is SelectStmt) {
      pl.planSelect(s, null, null);
    } else if (s is UpdateStmt || s is DeleteStmt) {
      final table = s is UpdateStmt ? s.table : (s as DeleteStmt).table;
      final td = ctx.catalog.table(table);
      if (td == null) throw ZxDbException('no such table: $table');
      pl.planDmlScan(
          td,
          s is UpdateStmt ? s.alias : (s as DeleteStmt).alias,
          s is UpdateStmt ? s.where : (s as DeleteStmt).where,
          s is UpdateStmt ? s.from : null,
          (sc) => [],
          null);
    } else if (s is InsertStmt && s.select != null) {
      pl.planSelect(s.select!, null, null);
    }
    final rows = ctx.eqp!;
    ctx.eqp = null;
    return ZxSqlResult(const ['id', 'parent', 'notused', 'detail'], rows, 0, 0);
  }

  ZxSqlResult _pragma(PragmaStmt p, ExecCtx ctx) {
    ZxSqlResult rows(List<String> cols, List<List<Object?>> r) =>
        ZxSqlResult(cols, r, 0, 0);
    final cat = ctx.catalog;
    switch (p.name) {
      case 'table_info':
      case 'table_xinfo':
        final td = cat.table('${p.value}');
        if (td == null) {
          final v = cat.view('${p.value}');
          if (v == null) return rows(const [], const []);
          final plan = Planner(ctx).planSelect(v.select, null, null);
          return rows(const ['cid', 'name', 'type', 'notnull', 'dflt_value', 'pk'], [
            for (var i = 0; i < plan.columns.length; i++)
              [i, v.columns != null && i < v.columns!.length ? v.columns![i] : plan.columns[i], '', 0, null, 0]
          ]);
        }
        return rows(
            ['cid', 'name', 'type', 'notnull', 'dflt_value', 'pk', if (p.name == 'table_xinfo') 'hidden'],
            [
              for (var i = 0; i < td.columns.length; i++)
                [
                  i,
                  td.columns[i].name,
                  td.columns[i].type ?? '',
                  td.columns[i].notNull ? 1 : 0,
                  td.columns[i].defaultExpr == null ? null : exprToSql(td.columns[i].defaultExpr!),
                  td.pkColumns.contains(i) ? td.pkColumns.indexOf(i) + 1 : 0,
                  if (p.name == 'table_xinfo') 0,
                ]
            ]);
      case 'index_list':
        final td = cat.table('${p.value}');
        if (td == null) return rows(const [], const []);
        final ixs = td.indexes.reversed.toList();
        return rows(const ['seq', 'name', 'unique', 'origin', 'partial'], [
          for (var i = 0; i < ixs.length; i++)
            [
              i,
              ixs[i].name,
              ixs[i].unique ? 1 : 0,
              ixs[i].origin == 'index' ? 'c' : (ixs[i].origin == 'pk' ? 'pk' : 'u'),
              ixs[i].where != null ? 1 : 0
            ]
        ]);
      case 'index_info':
      case 'index_xinfo':
        final ix = cat.index('${p.value}');
        if (ix == null) return rows(const [], const []);
        final td = cat.table(ix.table)!;
        return rows(const ['seqno', 'cid', 'name'], [
          for (var i = 0; i < ix.columns.length; i++)
            [
              i,
              ix.columns[i].col,
              ix.columns[i].col >= 0 ? td.columns[ix.columns[i].col].name : null
            ]
        ]);
      case 'table_list':
        return rows(const ['schema', 'name', 'type', 'ncol', 'wr', 'strict'], [
          for (final t in cat.tables.values)
            ['main', t.name, 'table', t.columns.length, 0, t.strict ? 1 : 0],
          for (final v in cat.views.values) ['main', v.name, 'view', 0, 0, 0],
        ]);
      case 'user_version':
        return rows(const ['user_version'], [
          [Catalog.readInt(ctx.snap, 'user_version')]
        ]);
      case 'schema_version':
        return rows(const ['schema_version'], [
          [Catalog.readVersion(ctx.snap)]
        ]);
      case 'database_list':
        return rows(const ['seq', 'name', 'file'], [
          [0, 'main', '']
        ]);
      case 'integrity_check':
      case 'quick_check':
        return rows(const ['integrity_check'], [
          ['ok']
        ]);
      case 'function_list':
        return rows(const ['name', 'builtin', 'type'], [
          for (final n in functions.scalarNames) [n, 1, 's'],
          for (final n in functions.aggregateNames) [n, 1, 'a'],
        ]);
      case 'journal_mode':
        return rows(const ['journal_mode'], [
          ['zx']
        ]);
      case 'foreign_keys':
        return rows(const ['foreign_keys'], [
          [0]
        ]);
      case 'encoding':
        return rows(const ['encoding'], [
          ['UTF-8']
        ]);
    }
    // Unknown pragmas are ignored, as in SQLite.
    return rows(const [], const []);
  }

  // ---------------------------------------------------------- writes

  DmlResult _writeStmt(Stmt st, ExecCtx ctx) {
    if (st is InsertStmt) return Dml(ctx).insert(st);
    if (st is UpdateStmt) return Dml(ctx).update(st);
    if (st is DeleteStmt) return Dml(ctx).delete(st);
    if (st is PragmaStmt) {
      if (st.name == 'user_version') {
        Catalog.writeInt(ctx.txn!, 'user_version', toInt(st.value));
      }
      return DmlResult(0);
    }
    final ddl = _Ddl(this, ctx);
    if (st is CreateTableStmt) return ddl.createTable(st);
    if (st is CreateIndexStmt) return ddl.createIndex(st);
    if (st is CreateViewStmt) return ddl.createView(st);
    if (st is AlterTableStmt) return ddl.alter(st);
    if (st is DropStmt) {
      switch (st.kind) {
        case 'TABLE':
          return ddl.dropTable(st);
        case 'INDEX':
          return ddl.dropIndex(st);
        case 'VIEW':
          return ddl.dropView(st);
      }
      return _hook('DROP ${st.kind}', st, ctx);
    }
    if (st is CreateKvStoreStmt) return _hook('CREATE KV STORE', st, ctx);
    if (st is CreateTimeseriesStmt) return _hook('CREATE TIMESERIES', st, ctx);
    if (st is CreateRollupStmt) return _hook('CREATE ROLLUP', st, ctx);
    throw ZxDbException('unsupported statement', ZxDbError.unsupported);
  }

  DmlResult _hook(String kind, Stmt st, ExecCtx ctx) {
    final h = _hooks[kind];
    if (h == null) {
      throw ZxDbException('$kind is not yet supported', ZxDbError.unsupported);
    }
    final r = h(st, ZxSqlHookContext(this, ctx.txn, ctx.snap, ctx.params));
    _catalog = null;
    return DmlResult(0, r?.columns ?? const [], r?.rows ?? const []);
  }

  void _invalidate() => _catalog = null;
}

// ------------------------------------------------------------ DDL

class _Ddl {
  final ZxSql sql;
  final ExecCtx ctx;
  _Ddl(this.sql, this.ctx);

  ZxWriteTxn get txn => ctx.txn!;
  Catalog get cat => ctx.catalog;

  ZxDbException err(String m) => ZxDbException(m);

  void _checkName(String name) {
    if (name.toLowerCase().startsWith('sqlite_')) {
      throw err('object name reserved for internal use: $name');
    }
  }

  void _done() {
    Catalog.bumpVersion(txn);
    sql._invalidate();
  }

  DmlResult createTable(CreateTableStmt st) {
    _checkName(st.name);
    if (cat.nameTaken(st.name) || sql._env.vtabs.containsKey(st.name.toLowerCase())) {
      if (st.ifNotExists && cat.table(st.name) != null) return DmlResult(0);
      if (st.ifNotExists) return DmlResult(0);
      throw err('table ${st.name} already exists');
    }
    if (st.temp) {
      // TEMP tables are ordinary tables here (no separate temp schema).
    }
    CreateTableStmt def = st;
    List<List<Object?>>? rows;
    if (st.asSelect != null) {
      final plan = Planner(ctx).planSelect(st.asSelect!, null, null);
      rows = drain(plan.open(null));
      String typeOf(Affinity a) => switch (a) {
            Affinity.integer => 'INT',
            Affinity.real => 'REAL',
            Affinity.text => 'TEXT',
            Affinity.numeric => 'NUM',
            Affinity.timeNs => 'DATETIME',
            _ => '',
          };
      final seen = <String>{};
      def = CreateTableStmt(false, false, st.name, [
        for (var i = 0; i < plan.columns.length; i++)
          ColumnDefAst(
              seen.add(plan.columns[i].toLowerCase())
                  ? plan.columns[i]
                  : '${plan.columns[i]}:$i',
              typeOf(plan.colInfo[i].aff).isEmpty ? null : typeOf(plan.colInfo[i].aff),
              const [])
      ], const [], st.options, null);
    }
    for (final c in def.columns) {
      if (c.constraints.any((k) => k.kind == 'GENERATED')) {
        throw const ZxDbException('generated columns are not supported', ZxDbError.unsupported);
      }
    }
    final tree = freeTreeName(txn, 't:${st.name.toLowerCase()}');
    final td = buildTableDef(def, tree);
    final opts = treeOptionsOf(td.options);
    txn.createTree(tree, opts);
    for (final ix in td.indexes) {
      ix.treeName = freeTreeName(txn, ix.treeName);
      txn.createTree(ix.treeName, opts);
    }
    Catalog.putTable(txn, td);
    _done();
    if (rows != null && rows.isNotEmpty) {
      final c2 = Catalog.load(txn);
      final ctx2 = ExecCtx(ctx.env, txn, txn, c2, const [], ctx.nowNs);
      ctx2.undo = ctx.undo;
      final pl = Planner(ctx2);
      final w = TableWriter(ctx2, pl, c2.table(st.name)!);
      var id = 0;
      for (final r in rows) {
        final row = [
          for (var i = 0; i < r.length; i++) columnValue(w.td.columns[i], r[i], st.name),
          ++id
        ];
        w.writeRow(id, row);
      }
    }
    return DmlResult(0);
  }

  DmlResult createIndex(CreateIndexStmt st) {
    _checkName(st.name);
    if (cat.nameTaken(st.name)) {
      if (st.ifNotExists) return DmlResult(0);
      throw err('index ${st.name} already exists');
    }
    final td = cat.table(st.table);
    if (td == null) throw err('no such table: ${st.table}');
    final tree = freeTreeName(txn, 'i:${st.name.toLowerCase()}');
    final ix = buildIndexDef(st, td, tree);
    txn.createTree(tree, treeOptionsOf(td.options));
    td.indexes.add(ix);
    try {
      Catalog.putIndex(txn, ix, Catalog.indexSql(ix, td));
      // Populate.
      final pl = Planner(ctx);
      final w = TableWriter(ctx, pl, td);
      final k = td.indexes.length - 1;
      final c = w.tree.scan();
      final rowsList = <List<Object?>>[];
      try {
        while (c.moveNext()) {
          rowsList.add(w.rd.decode(decodeRowid(c.key), c.value));
        }
      } finally {
        c.close();
      }
      for (final row in rowsList) {
        final kv = w.keyValues(k, row);
        if (kv == null) continue;
        final rowid = row.last as int;
        if (ix.unique && w.conflict(k, kv, rowid) != null) {
          throw ZxDbException(w.uniqueMessage(k), ZxDbError.constraint);
        }
        w.itrees[k].put(w.indexKey(k, kv, rowid), Uint8List(0));
      }
    } finally {
      td.indexes.removeLast();
    }
    _done();
    return DmlResult(0);
  }

  DmlResult createView(CreateViewStmt st) {
    _checkName(st.name);
    if (cat.nameTaken(st.name)) {
      if (st.ifNotExists) return DmlResult(0);
      throw err('view ${st.name} already exists');
    }
    // Validate by planning.
    Planner(ctx).planSelect(st.select, null, null);
    Catalog.putView(txn, ViewDef(st.name, st.columns, st.select, st.sql));
    _done();
    return DmlResult(0);
  }

  DmlResult dropTable(DropStmt st) {
    final td = cat.table(st.name);
    if (td == null) {
      if (st.ifExists) return DmlResult(0);
      if (cat.view(st.name) != null) {
        throw err('use DROP VIEW to delete view ${st.name}');
      }
      throw err('no such table: ${st.name}');
    }
    for (final ix in td.indexes) {
      if (txn.tree(ix.treeName) != null) txn.dropTree(ix.treeName);
      Catalog.remove(txn, ix.name);
    }
    if (txn.tree(td.treeName) != null) txn.dropTree(td.treeName);
    Catalog.remove(txn, td.name);
    Catalog.deleteInt(txn, 'seq:${td.name.toLowerCase()}');
    _done();
    return DmlResult(0);
  }

  DmlResult dropIndex(DropStmt st) {
    final ix = cat.index(st.name);
    if (ix == null) {
      if (st.ifExists) return DmlResult(0);
      throw err('no such index: ${st.name}');
    }
    if (ix.auto) {
      throw err('index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped');
    }
    if (txn.tree(ix.treeName) != null) txn.dropTree(ix.treeName);
    Catalog.remove(txn, ix.name);
    _done();
    return DmlResult(0);
  }

  DmlResult dropView(DropStmt st) {
    final v = cat.view(st.name);
    if (v == null) {
      if (st.ifExists) return DmlResult(0);
      if (cat.table(st.name) != null) {
        throw err('use DROP TABLE to delete table ${st.name}');
      }
      throw err('no such view: ${st.name}');
    }
    Catalog.remove(txn, v.name);
    _done();
    return DmlResult(0);
  }

  DmlResult alter(AlterTableStmt st) {
    final td = cat.table(st.table);
    if (td == null) throw err('no such table: ${st.table}');
    switch (st.action) {
      case 'RENAME TO':
        final nn = st.newName!;
        _checkName(nn);
        if (cat.nameTaken(nn) && nn.toLowerCase() != td.name.toLowerCase()) {
          throw err('there is already another table or index with this name: $nn');
        }
        Catalog.remove(txn, td.name);
        for (final ix in td.indexes) {
          Catalog.remove(txn, ix.name);
        }
        final old = td.name;
        td.name = nn;
        var k = 0;
        for (final ix in td.indexes) {
          ix.table = nn;
          if (ix.auto) ix.name = 'sqlite_autoindex_${nn}_${++k}';
        }
        Catalog.putTable(txn, td);
        for (final ix in td.indexes) {
          if (!ix.auto) Catalog.putIndex(txn, ix, Catalog.indexSql(ix, td));
        }
        final seq = Catalog.readInt(txn, 'seq:${old.toLowerCase()}');
        if (seq != 0) {
          Catalog.deleteInt(txn, 'seq:${old.toLowerCase()}');
          Catalog.writeInt(txn, 'seq:${nn.toLowerCase()}', seq);
        }
      case 'RENAME COLUMN':
        final i = td.colIndex(st.oldColumn!);
        if (i < 0) throw err('no such column: "${st.oldColumn}"');
        if (td.colIndex(st.newName!) >= 0) {
          throw err('duplicate column name: ${st.newName}');
        }
        final oldName = td.columns[i].name;
        td.columns[i].name = st.newName!;
        // Rewrite CHECK and index expressions.
        final newChecks = [for (final c in td.checks) renameInExpr(c, oldName, st.newName!)];
        td.checks
          ..clear()
          ..addAll(newChecks);
        for (final c in td.columns) {
          final nc = [for (final k in c.checks) renameInExpr(k, oldName, st.newName!)];
          if (c.checks.isNotEmpty) {
            c.checks
              ..clear()
              ..addAll(nc);
          }
        }
        Catalog.putTable(txn, td);
        for (final ix in td.indexes) {
          if (!ix.auto) {
            final nix = IndexDef(
                ix.name,
                ix.table,
                [
                  for (final c in ix.columns)
                    IndexColumn(c.col, c.expr == null ? null : renameInExpr(c.expr!, oldName, st.newName!), c.desc, c.collation)
                ],
                ix.unique,
                ix.where == null ? null : renameInExpr(ix.where!, oldName, st.newName!),
                ix.treeName,
                ix.origin,
                ix.conflict);
            Catalog.putIndex(txn, nix, Catalog.indexSql(nix, td));
          }
        }
      case 'ADD COLUMN':
        final c = st.column!;
        if (td.colIndex(c.name) >= 0) throw err('duplicate column name: ${c.name}');
        for (final k in c.constraints) {
          if (k.kind == 'PK') throw err('Cannot add a PRIMARY KEY column');
          if (k.kind == 'UNIQUE') throw err('Cannot add a UNIQUE column');
          if (k.kind == 'GENERATED') {
            throw const ZxDbException('generated columns are not supported', ZxDbError.unsupported);
          }
        }
        final def = c.constraints.where((k) => k.kind == 'DEFAULT').toList();
        final nn = c.constraints.any((k) => k.kind == 'NOTNULL');
        if (def.isNotEmpty) {
          final e = def.first.expr!;
          if (e is CurrentTimeExpr || e is SubqueryExpr || e is FuncExpr) {
            throw err('Cannot add a column with non-constant default');
          }
        }
        if (nn && (def.isEmpty || (def.first.expr is LitExpr && (def.first.expr as LitExpr).value == null))) {
          if (_hasRows(td)) throw err('Cannot add a NOT NULL column with default value NULL');
        }
        final st2 = Parser.parse(tableSql(td)).statements.single as CreateTableStmt;
        final ntd = buildTableDef(
            CreateTableStmt(false, false, td.name, [...st2.columns, c], st2.constraints, td.options, null),
            td.treeName);
        for (var k = 0; k < ntd.indexes.length && k < td.indexes.length; k++) {
          ntd.indexes[k].treeName = td.indexes[k].treeName;
        }
        Catalog.putTable(txn, ntd);
      case 'DROP COLUMN':
        final i = td.colIndex(st.oldColumn!);
        if (i < 0) throw err('no such column: "${st.oldColumn}"');
        if (td.pkColumns.contains(i) || td.columns[i].unique) {
          throw err('cannot drop PRIMARY KEY or UNIQUE column: "${st.oldColumn}"');
        }
        if (td.indexes.any((ix) => ix.columns.any((c) => c.col == i))) {
          throw err('error in index: cannot drop indexed column "${st.oldColumn}"');
        }
        if (td.columns.length == 1) throw err('cannot drop column "${st.oldColumn}": no other columns exist');
        // Rewrite the rows without the column.
        final pl = Planner(ctx);
        final w = TableWriter(ctx, pl, td);
        final rowsList = <List<Object?>>[];
        final c = w.tree.scan();
        try {
          while (c.moveNext()) {
            rowsList.add(w.rd.decode(decodeRowid(c.key), c.value));
          }
        } finally {
          c.close();
        }
        final st2 = Parser.parse(tableSql(td)).statements.single as CreateTableStmt;
        final cols = [...st2.columns]..removeAt(i);
        final ntd = buildTableDef(
            CreateTableStmt(false, false, td.name, cols, st2.constraints, td.options, null),
            td.treeName);
        for (var k = 0; k < ntd.indexes.length && k < td.indexes.length; k++) {
          ntd.indexes[k].treeName = td.indexes[k].treeName;
        }
        Catalog.putTable(txn, ntd);
        final w2 = TableWriter(ctx, pl, ntd);
        for (final r in rowsList) {
          final rowid = r.last as int;
          final nr = [...r]..removeAt(i);
          w2.tree.put(encodeRowid(rowid), w2.recordOf(nr));
        }
      case 'SET':
        final opts = {...td.options, ...st.options!};
        td.options = opts;
        final to = treeOptionsOf(opts);
        txn.setTreeOptions(td.treeName, to);
        for (final ix in td.indexes) {
          if (txn.tree(ix.treeName) != null) txn.setTreeOptions(ix.treeName, to);
        }
        Catalog.putTable(txn, td);
    }
    _done();
    return DmlResult(0);
  }

  bool _hasRows(TableDef td) => (txn.tree(td.treeName)?.length ?? 0) > 0;
}

/// Renames column references in an expression.
Expr renameInExpr(Expr e, String from, String to) {
  final l = from.toLowerCase();
  Expr r(Expr x) => renameInExpr(x, from, to);
  if (e is ColumnExpr) {
    return e.column.toLowerCase() == l ? ColumnExpr(e.table, to) : e;
  }
  if (e is UnaryExpr) return UnaryExpr(e.op, r(e.e));
  if (e is BinaryExpr) return BinaryExpr(e.op, r(e.l), r(e.r));
  if (e is LikeExpr) {
    return LikeExpr(e.op, e.not, r(e.e), r(e.pattern), e.escape == null ? null : r(e.escape!));
  }
  if (e is BetweenExpr) return BetweenExpr(e.not, r(e.e), r(e.lo), r(e.hi));
  if (e is InListExpr) return InListExpr(e.not, r(e.e), [for (final x in e.list) r(x)]);
  if (e is IsNullExpr) return IsNullExpr(e.not, r(e.e));
  if (e is CaseExpr) {
    return CaseExpr(e.base == null ? null : r(e.base!),
        [for (final w in e.whens) (r(w.$1), r(w.$2))], e.orElse == null ? null : r(e.orElse!));
  }
  if (e is CastExpr) return CastExpr(r(e.e), e.type);
  if (e is CollateExpr) return CollateExpr(r(e.e), e.collation);
  if (e is FuncExpr) {
    return FuncExpr(e.name, [for (final a in e.args) r(a)],
        distinct: e.distinct, star: e.star, filter: e.filter == null ? null : r(e.filter!));
  }
  return e;
}


