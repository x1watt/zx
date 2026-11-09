// fts5: full-text virtual tables with SQLite's FTS5 syntax
// (docs/zxdb-sql.md "Full-text search (fts5)").
//
//   CREATE VIRTUAL TABLE docs USING fts5(title, body, id UNINDEXED,
//       tokenize = 'unicode61');
//   INSERT INTO docs(title, body, id) VALUES (?, ?, ?);
//   SELECT id FROM docs WHERE docs MATCH '"hello" "wor"*'
//       ORDER BY bm25(docs);
//
// Columns are indexed unless UNINDEXED. Every table has two hidden
// columns, as in SQLite: one named after the table (the left side of
// `docs MATCH ...`) and `rank`; during a MATCH scan both hold the row's
// BM25 score (SQLite's convention: negative, lower is better), which is
// what bm25(docs) returns.
//
// Storage: one tree (the name the catalog reserved), keys by keycodec.dart:
//   ('r', rowid)              [column values..., token count, terms...]
//   ('p', term, rowid)        [token count, (column, n, positions...)...]
//   ('u', column, value, rowid)  empty: the UNINDEXED columns, so `=` on
//                             one of them (DELETE ... WHERE id = ?) is a
//                             lookup, not a scan
//   ('s')                     [rows, tokens]
// Positions (token numbers in the column) make phrases ("a b") and `^`
// exact. Writes go through the statement's write transaction (undone with
// it).
//
// Query syntax (FTS5's): phrases ("quoted" or bare words, `+` joins
// phrases, `*` makes the last token a prefix), implicit AND, AND, OR, NOT,
// parentheses, column filters (`col:`, `{a b}:`, `-col:`) and `^` (the
// phrase starts its column). NEAR(...) is not supported.
//
// The tokenizer is unicode61's work done by fts_text.dart: letters and
// digits, lowercase, common diacritics removed (also sharp s to ss, ae
// and oe ligatures split, which unicode61 does not do).

import 'dart:typed_data';

import '../fts_text.dart';
import '../keycodec.dart';
import '../record.dart';
import '../storage_api.dart';
import 'functions.dart';
import 'lexer.dart';
import 'value.dart' show toText;
import 'vtab.dart';

/// Registers the fts5 module and the bm25() function.
void zxFts5Register(
    void Function(String name, ZxVirtualTableModule module) registerModule,
    ZxFunctionRegistry functions) {
  registerModule('fts5', ZxFts5Module());
  functions.scalar(ZxScalarFunction('bm25', 1, -1, (args, ctx) {
    if (args.length > 1) {
      throw const ZxDbException(
          'bm25: column weights are not supported', ZxDbError.unsupported);
    }
    final v = args[0];
    if (v == null || v is num) return v;
    throw const ZxDbException(
        'bm25: the argument must be an fts5 table (its hidden column)');
  }, deterministic: false));
}

ZxDbException _unsupported(String m) =>
    ZxDbException('fts5: $m', ZxDbError.unsupported);

class ZxFts5Module extends ZxVirtualTableModule {
  @override
  void create(ZxWriteTxn txn, ZxVirtualTableDef def) {
    _Spec.parse(def);
    if (txn.tree(def.tree) == null) txn.createTree(def.tree);
  }

  @override
  ZxVirtualTable connect(ZxVirtualTableDef def) =>
      _Fts5Table(_Spec.parse(def), def.tree);

  @override
  void destroy(ZxWriteTxn txn, ZxVirtualTableDef def) {
    if (txn.tree(def.tree) != null) txn.dropTree(def.tree);
  }
}

// ---------------------------------------------------------------------------
// the arguments

class _Spec {
  final String name;
  final List<String> columns;
  final List<bool> indexed;
  _Spec(this.name, this.columns, this.indexed);

  static _Spec parse(ZxVirtualTableDef def) {
    final cols = <String>[];
    final idx = <bool>[];
    for (final a in def.args) {
      final toks = Lexer(a).tokenize()..removeLast();
      if (toks.isEmpty) throw ZxDbException('fts5: empty argument');
      if (toks.length >= 2 && toks[1].type == Tok.op && toks[1].text == '=') {
        final key = toks[0].text.toLowerCase();
        final value = toks.length == 3 &&
                (toks[2].type == Tok.string || toks[2].type == Tok.ident ||
                    toks[2].type == Tok.integer)
            ? toks[2].text
            : a.substring(toks[1].end).trim();
        _option(key, value);
        continue;
      }
      final t0 = toks[0];
      if (t0.type != Tok.ident && t0.type != Tok.string) {
        throw ZxDbException('fts5: parse error in "$a"');
      }
      var indexed = true;
      if (toks.length == 2 && toks[1].kw == 'UNINDEXED') {
        indexed = false;
      } else if (toks.length != 1) {
        throw ZxDbException('fts5: parse error in "$a"');
      }
      final n = t0.text;
      final l = n.toLowerCase();
      if (l == 'rank' || l == 'rowid' || l == def.name.toLowerCase()) {
        throw ZxDbException('fts5: reserved fts5 column name: $n');
      }
      if (cols.any((c) => c.toLowerCase() == l)) {
        throw ZxDbException('fts5: duplicate column name: $n');
      }
      cols.add(n);
      idx.add(indexed);
    }
    if (cols.isEmpty) throw const ZxDbException('fts5: no columns');
    return _Spec(def.name, cols, idx);
  }

  static void _option(String key, String value) {
    switch (key) {
      case 'tokenize':
        final w = value
            .split(RegExp(r'\s+'))
            .where((x) => x.isNotEmpty)
            .map((x) => x.replaceAll(RegExp('^[\'"]|[\'"]\$'), ''))
            .toList();
        if (w.isEmpty || w[0].toLowerCase() != 'unicode61') {
          throw _unsupported('tokenizer "$value" (only unicode61)');
        }
        for (var i = 1; i < w.length; i += 2) {
          final v = i + 1 < w.length ? w[i + 1] : '';
          if (w[i] == 'remove_diacritics' && (v == '1' || v == '2')) continue;
          throw _unsupported('unicode61 option ${w[i]} $v');
        }
      case 'prefix':
        break; // prefix indexes only speed up prefix queries
      case 'detail':
        if (value.toLowerCase() != 'full') {
          throw _unsupported('detail=$value (only full)');
        }
      case 'columnsize':
        if (value != '0' && value != '1') {
          throw ZxDbException('fts5: malformed columnsize=$value');
        }
      case 'content':
      case 'content_rowid':
      case 'contentless_delete':
      case 'contentless_unindexed':
      case 'locale':
      case 'tokendata':
        throw _unsupported('option $key');
      default:
        throw ZxDbException('fts5: unrecognized option: "$key"');
    }
  }
}

// ---------------------------------------------------------------------------
// keys

final Uint8List _statsKey = encodeKey(const ['s']);
final Uint8List _rowsFrom = encodeKey(const ['r']);
final Uint8List _rowsTo = prefixEnd(_rowsFrom)!;
Uint8List _rowKey(int rowid) => encodeKey(['r', rowid]);
Uint8List _postKey(String term, int rowid) => encodeKey(['p', term, rowid]);

// ---------------------------------------------------------------------------
// the table

class _Fts5Table extends ZxWritableVirtualTable {
  final _Spec spec;
  final String tree;
  final int ncol;

  // bumped by every write through this table (the MATCH result cache)
  int _writes = 0;
  ZxSnapshot? _cacheSnap;
  int _cacheWrites = -1;
  String? _cacheKey;
  List<(int, double)>? _cacheHits;
  Map<int, double>? _cacheScores;

  /// The scores of [hits] by rowid (kept with the cached result).
  Map<int, double> _scores(List<(int, double)> hits) {
    if (identical(hits, _cacheHits)) {
      return _cacheScores ??= {for (final (id, s) in hits) id: s};
    }
    return {for (final (id, s) in hits) id: s};
  }

  _Fts5Table(this.spec, this.tree) : ncol = spec.columns.length;

  @override
  late final List<ZxVtabColumn> columns = [
    for (final c in spec.columns) ZxVtabColumn(c),
    ZxVtabColumn(spec.name, null, true),
    const ZxVtabColumn('rank', null, true),
  ];

  @override
  bool get enforcesOmitted => true;

  // ---- planning
  //
  // idxStr: the roles of the arguments, comma separated: m<col> (a MATCH
  // query, col -1 for the whole row), r= r> r>= r< r<= (rowid), u<col>
  // (= on an UNINDEXED column). idxNum bit 1: rows in score order; bit 2:
  // the statement reads no column (no row lookups).

  @override
  void bestIndex(ZxIndexInfo info) {
    final roles = <String>[];
    var n = 0;
    var unindexed = false;
    void take(int i, String role, {bool omit = false}) {
      info.argvIndex[i] = ++n;
      info.omit[i] = omit;
      roles.add(role);
    }

    for (var i = 0; i < info.constraints.length; i++) {
      final c = info.constraints[i];
      if (!c.usable) continue;
      final col = c.column;
      if (c.op == ZxConstraintOp.match ||
          (c.op == ZxConstraintOp.eq && col == ncol)) {
        if (col == ncol + 1) {
          throw _unsupported('rank MATCH (rank functions)');
        }
        if (col == ncol || (col >= 0 && col < ncol)) {
          take(i, 'm${col == ncol ? -1 : col}', omit: true);
        } else {
          throw ZxDbException('fts5: unable to use MATCH on the rowid');
        }
        continue;
      }
      if (col == -1) {
        const ops = {
          ZxConstraintOp.eq: 'r=',
          ZxConstraintOp.gt: 'r>',
          ZxConstraintOp.ge: 'r>=',
          ZxConstraintOp.lt: 'r<',
          ZxConstraintOp.le: 'r<=',
        };
        final r = ops[c.op];
        if (r != null) take(i, r);
        continue;
      }
      if (c.op == ZxConstraintOp.eq &&
          col >= 0 &&
          col < ncol &&
          !spec.indexed[col] &&
          !unindexed) {
        unindexed = true;
        take(i, 'u$col');
      }
    }
    info.idxStr = roles.join(',');
    final match = roles.any((r) => r.startsWith('m'));
    if (match) {
      info.estimatedCost = 100;
      info.estimatedRows = 100;
      final ob = info.orderBy;
      if (ob.length == 1 &&
          !ob[0].desc &&
          (ob[0].column == ncol || ob[0].column == ncol + 1)) {
        info.idxNum |= 1;
        info.orderByConsumed = true;
      }
      if (!info.columnsUsed.any((c) => c >= 0 && c < ncol)) info.idxNum |= 2;
    } else if (roles.contains('r=')) {
      info.estimatedCost = 1;
      info.estimatedRows = 1;
    } else if (unindexed) {
      info.estimatedCost = 10;
      info.estimatedRows = 10;
    } else {
      info.estimatedCost = roles.isEmpty ? 1e6 : 1e5;
    }
  }

  @override
  ZxVtabCursor open(ZxVtabContext ctx) => _Fts5Cursor(this, ctx);

  ZxTree? _tree(ZxSnapshot s) => s.tree(tree);

  ZxWritableTree _wtree(ZxVtabContext ctx) {
    final t = ctx.writableTree(tree);
    if (t == null) {
      throw ZxDbException('fts5: missing storage of ${spec.name}', ZxDbError.corrupt);
    }
    return t;
  }

  static (int, int) _stats(ZxTree t) {
    final v = t.get(_statsKey);
    if (v == null) return (0, 0);
    final r = decodeRecord(v);
    return (r[0] as int, r[1] as int);
  }

  static void _addStats(ZxWritableTree t, int rows, int tokens) {
    final (r, k) = _stats(t);
    t.put(_statsKey, encodeRecord([r + rows, k + tokens]));
  }

  // ---- writes

  @override
  int insert(ZxVtabContext ctx, int? rowid, List<Object?> values) =>
      insertOr(ctx, rowid, values, ZxConflictMode.abort)!;

  @override
  int? insertOr(ZxVtabContext ctx, int? rowid, List<Object?> values,
      ZxConflictMode mode) {
    final t = _wtree(ctx);
    _writes++;
    final cmd = values.length > ncol ? values[ncol] : null;
    if (cmd != null) {
      _command(t, toText(cmd)!);
      return null;
    }
    if (rowid == null) {
      final c = t.scan(from: _rowsFrom, to: _rowsTo, reverse: true);
      try {
        rowid = c.moveNext() ? (decodeKey(c.key)[1] as int) + 1 : 1;
      } finally {
        c.close();
      }
    } else if (t.get(_rowKey(rowid)) != null) {
      if (mode == ZxConflictMode.ignore) return null;
      if (mode != ZxConflictMode.replace) {
        throw ZxDbException(
            'UNIQUE constraint failed: ${spec.name}.rowid', ZxDbError.constraint);
      }
      _deleteRow(t, rowid);
    }
    _writeRow(t, rowid, values);
    return rowid;
  }

  void _command(ZxWritableTree t, String cmd) {
    switch (cmd) {
      case 'optimize':
      case 'merge':
      case 'integrity-check':
      case 'rebuild':
        return;
      case 'delete-all':
        t.deleteRange();
        return;
    }
    throw _unsupported('command "$cmd"');
  }

  void _writeRow(ZxWritableTree t, int rowid, List<Object?> values) {
    final vals = [for (var c = 0; c < ncol; c++) values[c]];
    // term: column: positions
    final terms = <String, Map<int, List<int>>>{};
    var d = 0;
    for (var c = 0; c < ncol; c++) {
      if (!spec.indexed[c]) continue;
      final s = toText(vals[c]);
      if (s == null) continue;
      final toks = ftsTokenize(s, maxLength: null);
      for (var p = 0; p < toks.length; p++) {
        ((terms[toks[p]] ??= {})[c] ??= []).add(p);
      }
      d += toks.length;
    }
    t.put(_rowKey(rowid), encodeRecord([...vals, d, ...terms.keys]));
    for (final e in terms.entries) {
      final v = <Object?>[d];
      for (final ce in e.value.entries) {
        v
          ..add(ce.key)
          ..add(ce.value.length)
          ..addAll(ce.value);
      }
      t.put(_postKey(e.key, rowid), encodeRecord(v));
    }
    for (var c = 0; c < ncol; c++) {
      if (spec.indexed[c] || vals[c] == null) continue;
      t.put(encodeKey(['u', c, vals[c], rowid]), Uint8List(0));
    }
    _addStats(t, 1, d);
  }

  bool _deleteRow(ZxWritableTree t, int rowid) {
    final v = t.get(_rowKey(rowid));
    if (v == null) return false;
    final r = decodeRecord(v);
    final d = r[ncol] as int;
    for (var i = ncol + 1; i < r.length; i++) {
      t.delete(_postKey(r[i] as String, rowid));
    }
    for (var c = 0; c < ncol; c++) {
      if (spec.indexed[c] || r[c] == null) continue;
      t.delete(encodeKey(['u', c, r[c], rowid]));
    }
    t.delete(_rowKey(rowid));
    _addStats(t, -1, -d);
    return true;
  }

  @override
  void update(ZxVtabContext ctx, int rowid, List<Object?> values) {
    final t = _wtree(ctx);
    _writes++;
    _deleteRow(t, rowid);
    _writeRow(t, rowid, values);
  }

  @override
  void delete(ZxVtabContext ctx, int rowid) {
    _writes++;
    _deleteRow(_wtree(ctx), rowid);
  }

  // ---- queries

  /// The rows matching [queries] (each restricted to a column or -1) with
  /// their scores, in rowid order.
  List<(int, double)> _search(ZxSnapshot s, List<(int, String)> queries) {
    final key = [for (final (c, q) in queries) '$c\u0000$q'].join('\u0001');
    if (identical(_cacheSnap, s) && _cacheWrites == _writes && _cacheKey == key) {
      return _cacheHits!;
    }
    final t = _tree(s);
    var out = <(int, double)>[];
    if (t != null) {
      _Node? root;
      for (final (c, q) in queries) {
        var n = _QueryParser(q, spec).parse();
        if (n != null && c >= 0) n.restrict({c});
        root = _andNode(root, n);
      }
      if (root != null) out = _Searcher(t).run(root);
    }
    _cacheSnap = s;
    _cacheWrites = _writes;
    _cacheKey = key;
    _cacheHits = out;
    _cacheScores = null;
    return out;
  }
}

class _Fts5Cursor extends ZxVtabCursor {
  final _Fts5Table t;
  final ZxVtabContext ctx;
  ZxTree? _tree;
  // a MATCH scan or a list of rowids, else a cursor over the rows
  List<(int, double)>? _hits;
  List<int>? _ids;
  bool _noRows = false;
  int _i = 0;
  ZxCursor? _c;
  int _rowid = 0;
  List<Object?>? _row;
  double? _score;

  _Fts5Cursor(this.t, this.ctx);

  @override
  void filter(int idxNum, String? idxStr, List<Object?> args) {
    close();
    _noRows = idxNum & 2 != 0;
    _tree = t._tree(ctx.snapshot);
    _hits = null;
    _ids = null;
    _i = 0;
    final tree = _tree;
    if (tree == null) {
      _ids = const [];
      return;
    }
    final roles = idxStr == null || idxStr.isEmpty ? const <String>[] : idxStr.split(',');
    final queries = <(int, String)>[];
    int? eq;
    var eqNone = false;
    Uint8List from = _rowsFrom;
    Uint8List? to = _rowsTo;
    (int, Object?)? unindexed;
    for (var k = 0; k < roles.length && k < args.length; k++) {
      final r = roles[k];
      final a = args[k];
      if (r.startsWith('m')) {
        final q = toText(a);
        if (q == null) {
          _ids = const [];
          return;
        }
        queries.add((int.parse(r.substring(1)), q));
        continue;
      }
      if (r.startsWith('u')) {
        unindexed = (int.parse(r.substring(1)), a);
        continue;
      }
      // rowid bounds: only integers narrow (the executor tests the rest)
      if (a is! int) {
        if (r == 'r=' && a == null) eqNone = true;
        continue;
      }
      switch (r) {
        case 'r=':
          eq = a;
        case 'r>':
          final after = prefixEnd(_rowKey(a));
          if (after != null) from = _max(from, after);
        case 'r>=':
          from = _max(from, _rowKey(a));
        case 'r<':
          to = _min(to, _rowKey(a));
        case 'r<=':
          to = _min(to, prefixEnd(_rowKey(a)));
      }
    }
    if (eqNone) {
      _ids = const [];
      return;
    }
    if (queries.isNotEmpty) {
      var h = t._search(ctx.snapshot, queries);
      if (eq != null || unindexed != null) {
        // few candidate rows (a join on the rowid or an UNINDEXED column):
        // look them up in the result
        final scores = t._scores(h);
        h = [
          for (final id in eq != null ? [eq] : _unindexedRowids(tree, unindexed!))
            if (scores[id] != null) (id, scores[id]!)
        ];
      }
      if (idxNum & 1 != 0) {
        h = [...h]..sort((x, y) {
            final c = x.$2.compareTo(y.$2);
            return c != 0 ? c : x.$1.compareTo(y.$1);
          });
      }
      _hits = h;
      return;
    }
    if (eq != null) {
      _ids = [eq];
      return;
    }
    if (unindexed != null) {
      _ids = _unindexedRowids(tree, unindexed);
      return;
    }
    _c = tree.scan(from: from, to: to);
  }

  static List<int> _unindexedRowids(ZxTree tree, (int, Object?) u) {
    final f = encodeKey(['u', u.$1, u.$2]);
    final ids = <int>[];
    final c = tree.scan(from: f, to: prefixEnd(f));
    try {
      while (c.moveNext()) {
        ids.add(decodeKey(c.key).last as int);
      }
    } finally {
      c.close();
    }
    return ids;
  }

  static Uint8List _max(Uint8List a, Uint8List b) =>
      zxCompareKeys(b, a) > 0 ? b : a;
  static Uint8List? _min(Uint8List? a, Uint8List? b) =>
      b == null ? a : (a == null || zxCompareKeys(b, a) < 0 ? b : a);

  bool _load(int rowid) {
    if (_noRows) {
      // only the rowid and the score are read: no row lookups
      _rowid = rowid;
      _row = null;
      return true;
    }
    final v = _tree!.get(_rowKey(rowid));
    if (v == null) return false;
    _rowid = rowid;
    _row = decodeRecord(v);
    return true;
  }

  @override
  bool next() {
    final h = _hits;
    if (h != null) {
      while (_i < h.length) {
        final (id, score) = h[_i++];
        if (_load(id)) {
          _score = score;
          return true;
        }
      }
      return false;
    }
    final ids = _ids;
    if (ids != null) {
      _noRows = false;
      while (_i < ids.length) {
        if (_load(ids[_i++])) {
          _score = 0.0;
          return true;
        }
      }
      return false;
    }
    final c = _c;
    if (c == null || !c.moveNext()) return false;
    _rowid = decodeKey(c.key)[1] as int;
    _row = decodeRecord(c.value);
    _score = 0.0;
    return true;
  }

  @override
  Object? column(int i) => i < t.ncol ? (_row?[i]) : _score;

  @override
  int get rowid => _rowid;

  @override
  void close() {
    _c?.close();
    _c = null;
  }
}

// ---------------------------------------------------------------------------
// query expressions

abstract class _Node {
  void phrases(List<_Phrase> out);

  /// Limits the phrases to the columns [cols].
  void restrict(Set<int> cols) {
    final l = <_Phrase>[];
    phrases(l);
    for (final p in l) {
      p.cols = p.cols == null ? Set.of(cols) : p.cols!.intersection(cols);
    }
  }
}

class _Phrase extends _Node {
  /// (term, prefix) in order.
  final List<(String, bool)> tokens;
  Set<int>? cols;
  bool initial = false;
  _Phrase(this.tokens);

  @override
  void phrases(List<_Phrase> out) => out.add(this);
}

class _Bool extends _Node {
  final String op; // AND, OR, NOT
  final _Node a, b;
  _Bool(this.op, this.a, this.b);

  @override
  void phrases(List<_Phrase> out) {
    a.phrases(out);
    b.phrases(out);
  }
}

// empty phrases ("" or no tokens) are left out of the expression, as in
// FTS5; a query left empty matches nothing
_Node? _andNode(_Node? a, _Node? b) =>
    a == null ? b : (b == null ? a : _Bool('AND', a, b));
_Node? _orNode(_Node? a, _Node? b) =>
    a == null ? b : (b == null ? a : _Bool('OR', a, b));
_Node? _notNode(_Node? a, _Node? b) =>
    a == null ? null : (b == null ? a : _Bool('NOT', a, b));

enum _Q { str, lp, rp, lcp, rcp, colon, plus, star, minus, caret, and, or, not, near, eof }

class _QTok {
  final _Q k;
  final String text;
  const _QTok(this.k, this.text);
}

class _QueryParser {
  final String q;
  final _Spec spec;
  final List<_QTok> _t = [];
  int _i = 0;
  _QueryParser(this.q, this.spec) {
    _lex();
  }

  ZxDbException _syntax([String? near]) => ZxDbException(
      'fts5: syntax error near "${near ?? (_i < _t.length ? _t[_i].text : '')}"',
      ZxDbError.syntax);

  static bool _bare(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F ||
      c == 0x1A ||
      c >= 0x80;

  void _lex() {
    var p = 0;
    final n = q.length;
    while (true) {
      while (p < n && ' \t\n\r\f\v'.contains(q[p])) {
        p++;
      }
      if (p >= n) break;
      final ch = q[p];
      const singles = {
        '(': _Q.lp,
        ')': _Q.rp,
        '{': _Q.lcp,
        '}': _Q.rcp,
        ':': _Q.colon,
        '+': _Q.plus,
        '*': _Q.star,
        '-': _Q.minus,
        '^': _Q.caret,
      };
      final s = singles[ch];
      if (s != null) {
        _t.add(_QTok(s, ch));
        p++;
        continue;
      }
      if (ch == '"') {
        final sb = StringBuffer();
        p++;
        while (true) {
          if (p >= n) throw _syntax(q.substring(q.lastIndexOf('"')));
          if (q[p] == '"') {
            if (p + 1 < n && q[p + 1] == '"') {
              sb.write('"');
              p += 2;
              continue;
            }
            p++;
            break;
          }
          sb.write(q[p++]);
        }
        _t.add(_QTok(_Q.str, sb.toString()));
        continue;
      }
      if (!_bare(ch.codeUnitAt(0))) throw _syntax(ch);
      final st = p;
      while (p < n && _bare(q.codeUnitAt(p))) {
        p++;
      }
      final w = q.substring(st, p);
      var k = _Q.str;
      if (w == 'AND') k = _Q.and;
      if (w == 'OR') k = _Q.or;
      if (w == 'NOT') k = _Q.not;
      if (w == 'NEAR') {
        var j = p;
        while (j < n && q[j] == ' ') {
          j++;
        }
        if (j < n && q[j] == '(') k = _Q.near;
      }
      _t.add(_QTok(k, w));
    }
    _t.add(const _QTok(_Q.eof, ''));
  }

  _QTok get _cur => _t[_i];
  _Q get _k => _t[_i].k;

  void _expect(_Q k) {
    if (_k != k) throw _syntax();
    _i++;
  }

  _Node? parse() {
    final n = _or();
    if (_k != _Q.eof) throw _syntax();
    return n;
  }

  // precedence, loosest first: OR, AND, NOT, implicit AND (FTS5's)
  _Node? _or() {
    var l = _andExpr();
    while (_k == _Q.or) {
      _i++;
      l = _orNode(l, _andExpr());
    }
    return l;
  }

  _Node? _andExpr() {
    var l = _notExpr();
    while (_k == _Q.and) {
      _i++;
      l = _andNode(l, _notExpr());
    }
    return l;
  }

  _Node? _notExpr() {
    var l = _list();
    while (_k == _Q.not) {
      _i++;
      l = _notNode(l, _list());
    }
    return l;
  }

  bool get _startsItem =>
      _k == _Q.str ||
      _k == _Q.lp ||
      _k == _Q.lcp ||
      _k == _Q.minus ||
      _k == _Q.caret ||
      _k == _Q.near;

  _Node? _list() {
    if (!_startsItem) throw _syntax();
    var l = _item();
    while (_startsItem) {
      l = _andNode(l, _item());
    }
    return l;
  }

  int _column(String name) {
    final l = name.toLowerCase();
    for (var c = 0; c < spec.columns.length; c++) {
      if (spec.columns[c].toLowerCase() == l) return c;
    }
    throw ZxDbException('fts5: no such column: $name');
  }

  _Node? _item() {
    // column filter
    Set<int>? cols;
    final neg = _k == _Q.minus;
    if (neg) _i++;
    if (_k == _Q.lcp) {
      _i++;
      cols = {};
      while (_k == _Q.str) {
        cols.add(_column(_cur.text));
        _i++;
      }
      _expect(_Q.rcp);
      _expect(_Q.colon);
    } else if (_k == _Q.str && _t[_i + 1].k == _Q.colon) {
      cols = {_column(_cur.text)};
      _i += 2;
    } else if (neg) {
      throw _syntax();
    }
    if (cols != null && neg) {
      cols = {
        for (var c = 0; c < spec.columns.length; c++)
          if (!cols.contains(c)) c
      };
    }
    _Node? n;
    if (_k == _Q.lp) {
      _i++;
      n = _or();
      _expect(_Q.rp);
    } else if (_k == _Q.near) {
      throw _unsupported('NEAR queries');
    } else {
      var initial = false;
      if (_k == _Q.caret) {
        initial = true;
        _i++;
      }
      n = _phrase();
      if (n is _Phrase) n.initial = initial;
    }
    if (n != null && cols != null) n.restrict(cols);
    return n;
  }

  _Node? _phrase() {
    final toks = <(String, bool)>[];
    while (true) {
      if (_k != _Q.str) throw _syntax();
      final words = ftsTokenize(_cur.text, maxLength: null);
      _i++;
      for (final w in words) {
        toks.add((w, false));
      }
      if (_k == _Q.star) {
        _i++;
        if (words.isNotEmpty) toks[toks.length - 1] = (toks.last.$1, true);
      }
      if (_k != _Q.plus) break;
      _i++;
    }
    return toks.isEmpty ? null : _Phrase(toks);
  }
}

// ---------------------------------------------------------------------------
// evaluation and BM25 (as SQLite's fts5 bm25(): per phrase, IDF
// ln((N - hits + 0.5) / (hits + 0.5)) floored at 1e-6, the phrase's
// occurrences in the row, the row's token count over the average; the
// score is minus the sum)

/// A phrase's occurrences in one row: the row's token count and the count.
typedef _Hit = (int, int);

class _Searcher {
  final ZxTree t;
  final Map<_Phrase, Map<int, _Hit>> _hits = Map.identity();
  _Searcher(this.t);

  List<(int, double)> run(_Node root) {
    final phrases = <_Phrase>[];
    root.phrases(phrases);
    for (final p in phrases) {
      _hits[p] = _phraseHits(p);
    }
    final rows = _eval(root).toList()..sort();
    if (rows.isEmpty) return const [];
    final (n, tokens) = _Fts5Table._stats(t);
    final avg = n == 0 || tokens == 0 ? 1.0 : tokens / n;
    final idf = [for (final p in phrases) ftsIdfFts5(n, _hits[p]!.length)];
    return [
      for (final r in rows)
        () {
          var score = 0.0;
          int? d;
          for (var i = 0; i < phrases.length; i++) {
            final h = _hits[phrases[i]]![r];
            if (h == null) continue;
            d = h.$1;
            score += ftsBm25(idf[i], h.$2, d, avg);
          }
          return (r, -score);
        }()
    ];
  }

  Set<int> _eval(_Node n) {
    if (n is _Phrase) return _hits[n]!.keys.toSet();
    final b = n as _Bool;
    final x = _eval(b.a);
    switch (b.op) {
      case 'AND':
        if (x.isEmpty) return x;
        return x.intersection(_eval(b.b));
      case 'OR':
        return x.union(_eval(b.b));
      default:
        if (x.isEmpty) return x;
        return x.difference(_eval(b.b));
    }
  }

  /// The postings of one token: rowid to (token count, column to
  /// positions).
  Map<int, (int, Map<int, List<int>>)> _postings(String term, bool prefix) {
    final out = <int, (int, Map<int, List<int>>)>{};
    final (from, to) = ftsTermRange(const ['p'], term, prefix: prefix);
    final c = t.scan(from: from, to: to);
    try {
      while (c.moveNext()) {
        final rowid = decodeKey(c.key).last as int;
        final v = decodeRecord(c.value);
        final e = out[rowid] ??= (v[0] as int, <int, List<int>>{});
        for (var i = 1; i + 1 < v.length;) {
          final col = v[i] as int, k = v[i + 1] as int;
          (e.$2[col] ??= []).addAll([for (var j = 0; j < k; j++) v[i + 2 + j] as int]);
          i += 2 + k;
        }
      }
    } finally {
      c.close();
    }
    if (prefix) {
      for (final e in out.values) {
        for (final l in e.$2.values) {
          l.sort();
        }
      }
    }
    return out;
  }

  Map<int, _Hit> _phraseHits(_Phrase p) {
    if (p.tokens.length == 1 && p.cols == null && !p.initial) {
      // one token anywhere: counts, no positions
      final (term, prefix) = p.tokens[0];
      final out = <int, _Hit>{};
      final (from, to) = ftsTermRange(const ['p'], term, prefix: prefix);
      final c = t.scan(from: from, to: to);
      try {
        while (c.moveNext()) {
          final rowid = decodeKey(c.key).last as int;
          final v = decodeRecord(c.value);
          var n = 0;
          for (var i = 1; i + 1 < v.length; i += 2 + (v[i + 1] as int)) {
            n += v[i + 1] as int;
          }
          final h = out[rowid];
          out[rowid] = (v[0] as int, (h?.$2 ?? 0) + n);
        }
      } finally {
        c.close();
      }
      return out;
    }
    final lists = <Map<int, (int, Map<int, List<int>>)>>[];
    for (final (term, prefix) in p.tokens) {
      final l = _postings(term, prefix);
      if (l.isEmpty) return const {};
      lists.add(l);
    }
    var smallest = lists[0];
    for (final l in lists) {
      if (l.length < smallest.length) smallest = l;
    }
    final out = <int, _Hit>{};
    for (final rowid in smallest.keys) {
      if (!lists.every((l) => l.containsKey(rowid))) continue;
      final first = lists[0][rowid]!;
      var count = 0;
      for (final ce in first.$2.entries) {
        final col = ce.key;
        if (p.cols != null && !p.cols!.contains(col)) continue;
        final others = [
          for (var k = 1; k < lists.length; k++) lists[k][rowid]!.$2[col]?.toSet()
        ];
        if (others.any((s) => s == null)) continue;
        for (final pos in ce.value) {
          if (p.initial && pos != 0) continue;
          var ok = true;
          for (var k = 1; k < lists.length && ok; k++) {
            ok = others[k - 1]!.contains(pos + k);
          }
          if (ok) count++;
        }
      }
      if (count > 0) out[rowid] = (first.$1, count);
    }
    return out;
  }
}
