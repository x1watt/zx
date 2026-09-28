// Recursive descent parser for the zxdb SQL dialect, with Pratt parsing
// for expressions (SQLite operator precedence).

import '../storage_api.dart';
import 'ast.dart';
import 'lexer.dart';

/// Words that cannot be used as bare identifiers or implicit aliases.
const Set<String> _reserved = {
  'ADD', 'ALL', 'ALTER', 'AND', 'AS', 'BETWEEN', 'BY', 'CASE', 'CHECK', //
  'COLLATE', 'COMMIT', 'CONSTRAINT', 'CREATE', 'CROSS', 'DEFAULT', //
  'DELETE', 'DISTINCT', 'DROP', 'ELSE', 'END', 'ESCAPE', 'EXCEPT', //
  'EXISTS', 'FROM', 'FULL', 'GLOB', 'GROUP', 'HAVING', 'IN', 'INDEX', //
  'INNER', 'INSERT', 'INTERSECT', 'INTO', 'IS', 'ISNULL', 'JOIN', 'LEFT', //
  'LIKE', 'LIMIT', 'MATCH', 'NATURAL', 'NOT', 'NOTNULL', 'NULL', 'OFFSET', //
  'ON', 'OR', 'ORDER', 'OUTER', 'PRIMARY', 'REFERENCES', 'REGEXP', //
  'RETURNING', 'RIGHT', 'SELECT', 'SET', 'TABLE', 'THEN', 'TO', 'UNION', //
  'UNIQUE', 'UPDATE', 'USING', 'VALUES', 'WHEN', 'WHERE', 'WINDOW', 'WITH', //
  'INDEXED', 'ROLLBACK', 'BEGIN', 'OVER', 'FILTER',
};

/// The result of parsing a script: statements plus parameter names.
class ParsedScript {
  final List<Stmt> statements;

  /// Parameter names by 1-based index (null for anonymous ones); the
  /// length is the highest index used.
  final List<String?> paramNames;
  ParsedScript(this.statements, this.paramNames);
}

class Parser {
  final String src;
  final List<Token> _t;
  int _i = 0;
  final List<String?> _params = [];

  Parser(this.src) : _t = Lexer(src).tokenize();

  static ParsedScript parse(String sql) {
    final p = Parser(sql);
    final out = <Stmt>[];
    while (true) {
      while (p._isOp(';')) {
        p._i++;
      }
      if (p._cur.type == Tok.eof) break;
      final start = p._cur.pos;
      final s = p._statement();
      s.sql = sql.substring(start, p._t[p._i - 1].end);
      out.add(s);
      if (p._cur.type != Tok.eof && !p._isOp(';')) {
        throw p._error();
      }
    }
    return ParsedScript(out, p._params);
  }

  /// Parses one expression (used for stored DEFAULT / CHECK text).
  static Expr parseExpr(String sql) {
    final p = Parser(sql);
    final e = p._expr();
    if (p._cur.type != Tok.eof) throw p._error();
    return e;
  }

  // ------------------------------------------------------------ helpers

  Token get _cur => _t[_i];
  Token _peek([int k = 1]) =>
      _i + k < _t.length ? _t[_i + k] : _t[_t.length - 1];

  ZxDbException _error([Token? t]) {
    t ??= _cur;
    if (t.type == Tok.eof) {
      return const ZxDbException('incomplete input', ZxDbError.syntax);
    }
    return ZxDbException(
        'near "${src.substring(t.pos, t.end)}": syntax error', ZxDbError.syntax);
  }

  bool _isKw(String k) => _cur.kw == k;
  bool _isOp(String o) => _cur.type == Tok.op && _cur.text == o;

  bool _acceptKw(String k) {
    if (_isKw(k)) {
      _i++;
      return true;
    }
    return false;
  }

  bool _acceptKws(List<String> ks) {
    for (var j = 0; j < ks.length; j++) {
      if (_peek(j).kw != ks[j]) return false;
    }
    _i += ks.length;
    return true;
  }

  void _expectKw(String k) {
    if (!_acceptKw(k)) throw _error();
  }

  bool _acceptOp(String o) {
    if (_isOp(o)) {
      _i++;
      return true;
    }
    return false;
  }

  void _expectOp(String o) {
    if (!_acceptOp(o)) throw _error();
  }

  bool _isName(Token t) =>
      t.type == Tok.ident && (t.quoted || !_reserved.contains(t.kw));

  /// An identifier (plain or quoted). Also accepts a string literal where
  /// SQLite does (names in CREATE statements).
  String _name() {
    final t = _cur;
    if (_isName(t) || (t.type == Tok.string)) {
      _i++;
      return t.text;
    }
    throw _error();
  }

  /// Optional schema prefix: main.t -> t.
  String _qualifiedName() {
    var n = _name();
    if (_isOp('.') && _isName(_peek())) {
      _i++;
      n = _name();
    }
    return n;
  }

  bool _ifNotExists() => _acceptKws(['IF', 'NOT', 'EXISTS']);
  bool _ifExists() => _acceptKws(['IF', 'EXISTS']);

  // ------------------------------------------------------------ statements

  Stmt _statement() {
    final k = _cur.kw;
    switch (k) {
      case 'SELECT':
      case 'VALUES':
      case 'WITH':
        return _withStatement();
      case 'INSERT':
      case 'REPLACE':
        return _insert(null);
      case 'UPDATE':
        return _update(null);
      case 'DELETE':
        return _delete(null);
      case 'CREATE':
        return _create();
      case 'DROP':
        return _drop();
      case 'ALTER':
        return _alter();
      case 'BEGIN':
        _i++;
        _acceptKw('DEFERRED') || _acceptKw('IMMEDIATE') || _acceptKw('EXCLUSIVE');
        _acceptKw('TRANSACTION');
        return TxnStmt('BEGIN');
      case 'COMMIT':
      case 'END':
        _i++;
        _acceptKw('TRANSACTION');
        return TxnStmt('COMMIT');
      case 'ROLLBACK':
        _i++;
        _acceptKw('TRANSACTION');
        if (_acceptKw('TO')) {
          _acceptKw('SAVEPOINT');
          return TxnStmt('ROLLBACK TO', _name());
        }
        return TxnStmt('ROLLBACK');
      case 'SAVEPOINT':
        _i++;
        return TxnStmt('SAVEPOINT', _name());
      case 'RELEASE':
        _i++;
        _acceptKw('SAVEPOINT');
        return TxnStmt('RELEASE', _name());
      case 'PRAGMA':
        return _pragma();
      case 'EXPLAIN':
        _i++;
        final qp = _acceptKws(['QUERY', 'PLAN']);
        return ExplainStmt(qp, _statement());
      case 'VACUUM':
        _i++;
        String? mode;
        if (_cur.type == Tok.ident && _cur.kw == 'ULTRA') {
          mode = 'ULTRA';
          _i++;
        }
        return VacuumStmt(mode);
      case 'ANALYZE':
      case 'REINDEX':
        _i++;
        if (_isName(_cur)) _qualifiedName();
        return NoopStmt(k);
    }
    throw _error();
  }

  Stmt _withStatement() {
    WithClause? w;
    if (_isKw('WITH')) w = _with();
    switch (_cur.kw) {
      case 'INSERT':
      case 'REPLACE':
        return _insert(w);
      case 'UPDATE':
        return _update(w);
      case 'DELETE':
        return _delete(w);
    }
    return _selectAfterWith(w);
  }

  WithClause _with() {
    _expectKw('WITH');
    final rec = _acceptKw('RECURSIVE');
    final ctes = <Cte>[];
    do {
      final name = _name();
      List<String>? cols;
      if (_acceptOp('(')) {
        cols = [];
        do {
          cols.add(_name());
        } while (_acceptOp(','));
        _expectOp(')');
      }
      _expectKw('AS');
      bool? mat;
      if (_acceptKws(['NOT', 'MATERIALIZED'])) {
        mat = false;
      } else if (_acceptKw('MATERIALIZED')) {
        mat = true;
      }
      _expectOp('(');
      final s = _select();
      _expectOp(')');
      ctes.add(Cte(name, cols, s, mat));
    } while (_acceptOp(','));
    return WithClause(rec, ctes);
  }

  SelectStmt _select() {
    WithClause? w;
    if (_isKw('WITH')) w = _with();
    return _selectAfterWith(w);
  }

  SelectStmt _selectAfterWith(WithClause? w) {
    final parts = <SelectBody>[_selectCore()];
    final ops = <String>[];
    while (true) {
      String? op;
      if (_acceptKws(['UNION', 'ALL'])) {
        op = 'UNION ALL';
      } else if (_acceptKw('UNION')) {
        op = 'UNION';
      } else if (_acceptKw('INTERSECT')) {
        op = 'INTERSECT';
      } else if (_acceptKw('EXCEPT')) {
        op = 'EXCEPT';
      }
      if (op == null) break;
      ops.add(op);
      parts.add(_selectCore());
    }
    final body = parts.length == 1 ? parts[0] : CompoundSelect(parts, ops);
    final order = <OrderTerm>[];
    if (_acceptKws(['ORDER', 'BY'])) order.addAll(_orderTerms());
    Expr? limit, offset;
    if (_acceptKw('LIMIT')) {
      limit = _expr();
      if (_acceptKw('OFFSET')) {
        offset = _expr();
      } else if (_acceptOp(',')) {
        // LIMIT offset, count
        offset = limit;
        limit = _expr();
      }
    }
    return SelectStmt(w, body, order, limit, offset);
  }

  List<OrderTerm> _orderTerms() {
    final out = <OrderTerm>[];
    do {
      final e = _expr();
      var desc = false;
      if (_acceptKw('DESC')) {
        desc = true;
      } else {
        _acceptKw('ASC');
      }
      bool? nf;
      if (_acceptKws(['NULLS', 'FIRST'])) {
        nf = true;
      } else if (_acceptKws(['NULLS', 'LAST'])) {
        nf = false;
      }
      out.add(OrderTerm(e, desc, nf));
    } while (_acceptOp(','));
    return out;
  }

  SelectBody _selectCore() {
    if (_acceptKw('VALUES')) {
      final rows = <List<Expr>>[];
      do {
        _expectOp('(');
        final r = <Expr>[];
        do {
          r.add(_expr());
        } while (_acceptOp(','));
        _expectOp(')');
        if (rows.isNotEmpty && r.length != rows[0].length) {
          throw const ZxDbException(
              'all VALUES must have the same number of terms',
              ZxDbError.syntax);
        }
        rows.add(r);
      } while (_acceptOp(','));
      return ValuesCore(rows);
    }
    _expectKw('SELECT');
    var distinct = false;
    if (_acceptKw('DISTINCT')) {
      distinct = true;
    } else {
      _acceptKw('ALL');
    }
    final cols = <ResultColumn>[];
    do {
      cols.add(_resultColumn());
    } while (_acceptOp(','));
    var from = <JoinItem>[];
    if (_acceptKw('FROM')) from = _from();
    Expr? where, having;
    final group = <Expr>[];
    if (_acceptKw('WHERE')) where = _expr();
    if (_acceptKws(['GROUP', 'BY'])) {
      do {
        group.add(_expr());
      } while (_acceptOp(','));
    }
    if (_acceptKw('HAVING')) having = _expr();
    if (_isKw('WINDOW')) {
      throw const ZxDbException(
          'window functions are not supported', ZxDbError.unsupported);
    }
    return SelectCore(distinct, cols, from, where, group, having);
  }

  ResultColumn _resultColumn() {
    if (_acceptOp('*')) return const ResultColumn(null, null, '*', star: true);
    if (_isName(_cur) &&
        _peek().type == Tok.op &&
        _peek().text == '.' &&
        _peek(2).type == Tok.op &&
        _peek(2).text == '*') {
      final t = _name();
      _i += 2;
      return ResultColumn(null, null, '$t.*', star: true, starTable: t);
    }
    final st = _cur.pos;
    final e = _expr();
    final text = src.substring(st, _t[_i - 1].end);
    String? alias;
    if (_acceptKw('AS')) {
      alias = _name();
    } else if ((_isName(_cur) || _cur.type == Tok.string) &&
        !_isHistoryOrAsOf()) {
      alias = _name();
    }
    return ResultColumn(e, alias, text);
  }

  List<JoinItem> _from() {
    final out = <JoinItem>[];
    out.add(JoinItem('', _fromSource()));
    while (true) {
      String? type;
      var natural = false;
      if (_acceptOp(',')) {
        type = ',';
      } else {
        natural = _acceptKw('NATURAL');
        if (_acceptKw('LEFT')) {
          _acceptKw('OUTER');
          type = 'LEFT';
        } else if (_acceptKw('RIGHT')) {
          _acceptKw('OUTER');
          type = 'RIGHT';
        } else if (_acceptKw('FULL')) {
          _acceptKw('OUTER');
          type = 'FULL';
        } else if (_acceptKw('INNER')) {
          type = 'INNER';
        } else if (_acceptKw('CROSS')) {
          type = 'CROSS';
        } else if (_isKw('JOIN')) {
          type = 'INNER';
        }
        if (type == null) {
          if (natural) throw _error();
          break;
        }
        _expectKw('JOIN');
      }
      final src = _fromSource();
      Expr? on;
      List<String>? using;
      if (type != ',') {
        if (_acceptKw('ON')) {
          on = _expr();
        } else if (_acceptKw('USING')) {
          _expectOp('(');
          using = [];
          do {
            using.add(_name());
          } while (_acceptOp(','));
          _expectOp(')');
        }
      }
      out.add(JoinItem(type, src, natural: natural, on: on, using: using));
    }
    return out;
  }

  String? _alias() {
    if (_isKw('AS') && _peek().kw != 'OF') {
      _i++;
      return _name();
    }
    if (_isName(_cur) && !_isHistoryOrAsOf()) return _name();
    return null;
  }

  // `EVERY '1h'` / `RETENTION '7d'` after a rollup query are not aliases.
  bool _isHistoryOrAsOf() =>
      (_cur.kw == 'EVERY' || _cur.kw == 'RETENTION') &&
      _peek().type == Tok.string;

  AsOf? _asOf() {
    if (_isKw('AS') && _peek().kw == 'OF') {
      _i += 2;
      if (_acceptKw('GENERATION')) return AsOf(generation: _primaryOrUnary());
      return AsOf(time: _primaryOrUnary());
    }
    return null;
  }

  Expr _primaryOrUnary() => _exprBp(11);

  FromSource _fromSource() {
    if (_acceptOp('(')) {
      if (_isKw('SELECT') || _isKw('VALUES') || _isKw('WITH')) {
        final s = _select();
        _expectOp(')');
        return SubquerySource(s, _alias());
      }
      // Parenthesised join: (a JOIN b ...) becomes a subquery over it.
      final items = _from();
      _expectOp(')');
      final core = SelectCore(false,
          const [ResultColumn(null, null, '*', star: true)], items, null, [], null);
      return SubquerySource(SelectStmt(null, core, [], null, null), _alias());
    }
    if (_cur.kw == 'HISTORY' && _peek().kw == 'OF') {
      _i += 2;
      final name = _qualifiedName();
      return TableSource(name, _alias(), history: true);
    }
    final name = _qualifiedName();
    if (_acceptOp('(')) {
      final args = <Expr>[];
      if (!_isOp(')')) {
        do {
          args.add(_expr());
        } while (_acceptOp(','));
      }
      _expectOp(')');
      return FuncSource(name.toLowerCase(), args, _alias());
    }
    var asOf = _asOf();
    final alias = _alias();
    asOf ??= _asOf();
    String? indexedBy;
    var notIndexed = false;
    if (_acceptKws(['INDEXED', 'BY'])) {
      indexedBy = _name();
    } else if (_acceptKws(['NOT', 'INDEXED'])) {
      notIndexed = true;
    }
    return TableSource(name, alias,
        asOf: asOf, indexedBy: indexedBy, notIndexed: notIndexed);
  }

  String? _conflictClause() {
    if (_acceptKws(['ON', 'CONFLICT'])) {
      final k = _cur.kw;
      if (['ROLLBACK', 'ABORT', 'FAIL', 'IGNORE', 'REPLACE'].contains(k)) {
        _i++;
        return k;
      }
      throw _error();
    }
    return null;
  }

  InsertStmt _insert(WithClause? w) {
    String? or;
    if (_acceptKw('REPLACE')) {
      or = 'REPLACE';
    } else {
      _expectKw('INSERT');
      if (_acceptKw('OR')) {
        final k = _cur.kw;
        if (!['ROLLBACK', 'ABORT', 'FAIL', 'IGNORE', 'REPLACE'].contains(k)) {
          throw _error();
        }
        _i++;
        or = k;
      }
    }
    _expectKw('INTO');
    final table = _qualifiedName();
    String? alias;
    if (_acceptKw('AS')) alias = _name();
    List<String>? cols;
    if (_acceptOp('(')) {
      cols = [];
      do {
        cols.add(_name());
      } while (_acceptOp(','));
      _expectOp(')');
    }
    SelectStmt? sel;
    var defaults = false;
    if (_acceptKws(['DEFAULT', 'VALUES'])) {
      defaults = true;
    } else {
      sel = _select();
    }
    final ups = <Upsert>[];
    while (_isKw('ON') && _peek().kw == 'CONFLICT') {
      _i += 2;
      List<Expr>? target;
      Expr? tw;
      if (_acceptOp('(')) {
        target = [];
        do {
          final e = _expr();
          if (_acceptKw('COLLATE')) _name();
          _acceptKw('ASC') || _acceptKw('DESC');
          target.add(e);
        } while (_acceptOp(','));
        _expectOp(')');
        if (_acceptKw('WHERE')) tw = _expr();
      }
      _expectKw('DO');
      if (_acceptKw('NOTHING')) {
        ups.add(Upsert(target, tw, true, const [], null));
      } else {
        _expectKw('UPDATE');
        _expectKw('SET');
        final sets = _setClauses();
        Expr? wh;
        if (_acceptKw('WHERE')) wh = _expr();
        ups.add(Upsert(target, tw, false, sets, wh));
      }
    }
    final ret = _returning();
    return InsertStmt(w, or, table, alias, cols, sel, defaults, ups, ret);
  }

  List<ResultColumn>? _returning() {
    if (!_acceptKw('RETURNING')) return null;
    final cols = <ResultColumn>[];
    do {
      cols.add(_resultColumn());
    } while (_acceptOp(','));
    return cols;
  }

  List<SetClause> _setClauses() {
    final sets = <SetClause>[];
    do {
      List<String> cols;
      if (_acceptOp('(')) {
        cols = [];
        do {
          cols.add(_name());
        } while (_acceptOp(','));
        _expectOp(')');
      } else {
        cols = [_name()];
      }
      _expectOp('=');
      sets.add(SetClause(cols, _expr()));
    } while (_acceptOp(','));
    return sets;
  }

  UpdateStmt _update(WithClause? w) {
    _expectKw('UPDATE');
    String? or;
    if (_acceptKw('OR')) {
      or = _cur.kw;
      _i++;
    }
    final table = _qualifiedName();
    String? alias;
    if (_acceptKw('AS')) {
      alias = _name();
    } else if (_isName(_cur) && !_isKw('SET')) {
      alias = _name();
    }
    _expectKw('SET');
    final sets = _setClauses();
    List<JoinItem>? from;
    if (_acceptKw('FROM')) from = _from();
    Expr? where;
    if (_acceptKw('WHERE')) where = _expr();
    final ret = _returning();
    return UpdateStmt(w, or, table, alias, sets, from, where, ret);
  }

  DeleteStmt _delete(WithClause? w) {
    _expectKw('DELETE');
    _expectKw('FROM');
    final table = _qualifiedName();
    String? alias;
    if (_acceptKw('AS')) {
      alias = _name();
    } else if (_isName(_cur)) {
      alias = _name();
    }
    Expr? where;
    if (_acceptKw('WHERE')) where = _expr();
    final ret = _returning();
    return DeleteStmt(w, table, alias, where, ret);
  }

  Map<String, Object?> _options() {
    final m = <String, Object?>{};
    _expectOp('(');
    if (_acceptOp(')')) return m;
    do {
      final k = _cur;
      if (k.type != Tok.ident && k.type != Tok.string) throw _error();
      _i++;
      var key = k.text.toLowerCase();
      while (_acceptOp('.')) {
        key = '$key.${_name().toLowerCase()}';
      }
      Object? v = true;
      if (_acceptOp('=')) {
        final t = _cur;
        if (t.type == Tok.string) {
          v = t.text;
          _i++;
        } else if (t.type == Tok.integer || t.type == Tok.real) {
          v = t.value;
          _i++;
        } else if (t.type == Tok.op && (t.text == '-' || t.text == '+')) {
          _i++;
          final n = _cur;
          if (n.type != Tok.integer && n.type != Tok.real) throw _error();
          _i++;
          v = t.text == '-' ? -(n.value as num) : n.value;
        } else if (t.type == Tok.ident) {
          v = t.text;
          _i++;
        } else {
          throw _error();
        }
      }
      m[key] = v;
    } while (_acceptOp(','));
    _expectOp(')');
    return m;
  }

  Stmt _create() {
    _expectKw('CREATE');
    final temp = _acceptKw('TEMP') || _acceptKw('TEMPORARY');
    if (_acceptKw('TABLE')) return _createTable(temp);
    if (_acceptKws(['UNIQUE', 'INDEX'])) return _createIndex(true);
    if (_acceptKw('INDEX')) return _createIndex(false);
    if (_acceptKw('VIEW')) {
      final ine = _ifNotExists();
      final name = _qualifiedName();
      List<String>? cols;
      if (_acceptOp('(')) {
        cols = [];
        do {
          cols.add(_name());
        } while (_acceptOp(','));
        _expectOp(')');
      }
      _expectKw('AS');
      return CreateViewStmt(ine, name, cols, _select());
    }
    if (_cur.kw == 'KV' && _peek().kw == 'STORE') {
      _i += 2;
      final ine = _ifNotExists();
      final name = _qualifiedName();
      final opts = _acceptKw('WITH') ? _options() : <String, Object?>{};
      return CreateKvStoreStmt(ine, name, opts);
    }
    if (_cur.kw == 'TIMESERIES') {
      _i++;
      final ine = _ifNotExists();
      final name = _qualifiedName();
      final cols = <ColumnDefAst>[];
      _expectOp('(');
      do {
        cols.add(_columnDef());
      } while (_acceptOp(','));
      _expectOp(')');
      String? part, ret;
      var opts = <String, Object?>{};
      while (true) {
        if (_acceptKws(['PARTITION', 'BY'])) {
          part = _name();
        } else if (_cur.kw == 'RETENTION') {
          _i++;
          ret = _stringLit();
        } else if (_acceptKw('WITH')) {
          opts = _options();
        } else {
          break;
        }
      }
      return CreateTimeseriesStmt(ine, name, cols, part, ret, opts);
    }
    if (_cur.kw == 'ROLLUP') {
      _i++;
      final ine = _ifNotExists();
      final name = _qualifiedName();
      List<String>? cols;
      if (_acceptOp('(')) {
        cols = [];
        do {
          cols.add(_name());
        } while (_acceptOp(','));
        _expectOp(')');
      }
      String? every, ret;
      var opts = <String, Object?>{};
      void tail() {
        while (true) {
          if (_cur.kw == 'EVERY') {
            _i++;
            every = _stringLit();
          } else if (_cur.kw == 'RETENTION') {
            _i++;
            ret = _stringLit();
          } else if (_isKw('WITH') && _peek().type == Tok.op &&
              _peek().text == '(') {
            _i++;
            opts = _options();
          } else {
            break;
          }
        }
      }

      tail();
      _expectKw('AS');
      final sel = _select();
      tail();
      return CreateRollupStmt(ine, name, cols, sel, every, ret, opts);
    }
    throw _error();
  }

  String _stringLit() {
    if (_cur.type != Tok.string) throw _error();
    return _t[_i++].text;
  }

  CreateTableStmt _createTable(bool temp) {
    final ine = _ifNotExists();
    final name = _qualifiedName();
    if (_acceptKw('AS')) {
      final s = _select();
      return CreateTableStmt(ine, temp, name, [], [], {}, s);
    }
    _expectOp('(');
    final cols = <ColumnDefAst>[];
    final cons = <TableConstraintAst>[];
    do {
      if (_isKw('CONSTRAINT') ||
          _isKw('PRIMARY') ||
          _isKw('UNIQUE') ||
          _isKw('CHECK') ||
          _cur.kw == 'FOREIGN') {
        cons.add(_tableConstraint());
      } else {
        if (cons.isNotEmpty) throw _error();
        cols.add(_columnDef());
      }
    } while (_acceptOp(','));
    _expectOp(')');
    var withoutRowid = false, strict = false;
    Map<String, Object?> opts = {};
    while (true) {
      if (_cur.kw == 'WITHOUT') {
        _i++;
        if (_cur.kw != 'ROWID') throw _error();
        _i++;
        withoutRowid = true;
      } else if (_cur.kw == 'STRICT') {
        _i++;
        strict = true;
      } else if (_isKw('WITH') && _peek().type == Tok.op && _peek().text == '(') {
        _i++;
        opts = _options();
      } else {
        break;
      }
      if (!_acceptOp(',') && !(_isKw('WITH') || _cur.kw == 'STRICT' || _cur.kw == 'WITHOUT')) {
        break;
      }
    }
    return CreateTableStmt(ine, temp, name, cols, cons, opts, null,
        withoutRowid: withoutRowid, strict: strict);
  }

  static const _typeStop = {
    'CONSTRAINT', 'PRIMARY', 'NOT', 'NULL', 'UNIQUE', 'CHECK', 'DEFAULT', //
    'COLLATE', 'REFERENCES', 'GENERATED', 'AS',
  };

  ColumnDefAst _columnDef() {
    final name = _name();
    String? type;
    final words = <String>[];
    while (_cur.type == Tok.ident &&
        !_cur.quoted &&
        !_typeStop.contains(_cur.kw)) {
      words.add(_cur.text);
      _i++;
    }
    if (words.isNotEmpty) {
      type = words.join(' ');
      if (_acceptOp('(')) {
        final st = _cur.pos;
        var depth = 1;
        while (depth > 0) {
          if (_cur.type == Tok.eof) throw _error();
          if (_isOp('(')) depth++;
          if (_isOp(')')) depth--;
          _i++;
        }
        type = '$type(${src.substring(st, _t[_i - 1].pos).trim()})';
      }
    }
    final cons = <ColumnConstraint>[];
    while (true) {
      if (_acceptKw('CONSTRAINT')) _name();
      if (_acceptKws(['PRIMARY', 'KEY'])) {
        var desc = false;
        if (_acceptKw('DESC')) {
          desc = true;
        } else {
          _acceptKw('ASC');
        }
        final cc = _conflictClause();
        final auto = _cur.kw == 'AUTOINCREMENT';
        if (auto) _i++;
        cons.add(ColumnConstraint('PK',
            desc: desc, autoincrement: auto, conflict: cc));
      } else if (_acceptKws(['NOT', 'NULL'])) {
        cons.add(ColumnConstraint('NOTNULL', conflict: _conflictClause()));
      } else if (_acceptKw('NULL')) {
        _conflictClause();
      } else if (_acceptKw('UNIQUE')) {
        cons.add(ColumnConstraint('UNIQUE', conflict: _conflictClause()));
      } else if (_acceptKw('CHECK')) {
        _expectOp('(');
        final e = _expr();
        _expectOp(')');
        cons.add(ColumnConstraint('CHECK', expr: e));
      } else if (_acceptKw('DEFAULT')) {
        Expr e;
        if (_acceptOp('(')) {
          e = _expr();
          _expectOp(')');
        } else if (_isOp('-') || _isOp('+')) {
          final neg = _isOp('-');
          _i++;
          final lit = _primary();
          e = neg ? UnaryExpr('-', lit) : lit;
        } else if (_cur.type == Tok.ident && !_cur.quoted &&
            !const {'NULL', 'TRUE', 'FALSE', 'CURRENT_TIME', 'CURRENT_DATE',
              'CURRENT_TIMESTAMP'}.contains(_cur.kw)) {
          // DEFAULT word: taken as a string, as SQLite does.
          e = LitExpr(_cur.text);
          _i++;
        } else {
          e = _primary();
        }
        cons.add(ColumnConstraint('DEFAULT', expr: e));
      } else if (_acceptKw('COLLATE')) {
        cons.add(ColumnConstraint('COLLATE', collation: _name()));
      } else if (_acceptKw('REFERENCES')) {
        _skipForeignKeyClause();
      } else if (_cur.kw == 'GENERATED' || _isKw('AS')) {
        if (_cur.kw == 'GENERATED') {
          _i++;
          if (_cur.kw != 'ALWAYS') throw _error();
          _i++;
        }
        _expectKw('AS');
        _expectOp('(');
        final e = _expr();
        _expectOp(')');
        var stored = false;
        if (_cur.kw == 'STORED') {
          stored = true;
          _i++;
        } else if (_cur.kw == 'VIRTUAL') {
          _i++;
        }
        cons.add(ColumnConstraint('GENERATED', expr: e, desc: stored));
      } else {
        break;
      }
    }
    return ColumnDefAst(name, type, cons);
  }

  void _skipForeignKeyClause() {
    _qualifiedName();
    if (_acceptOp('(')) {
      do {
        _name();
      } while (_acceptOp(','));
      _expectOp(')');
    }
    while (true) {
      if (_acceptKw('ON')) {
        _i++; // DELETE / UPDATE
        if (_acceptKw('SET')) {
          _i++;
        } else if (_cur.kw == 'CASCADE' || _cur.kw == 'RESTRICT') {
          _i++;
        } else if (_cur.kw == 'NO') {
          _i += 2;
        }
      } else if (_cur.kw == 'MATCH') {
        _i += 2;
      } else if (_cur.kw == 'DEFERRABLE' ||
          (_isKw('NOT') && _peek().kw == 'DEFERRABLE')) {
        if (_isKw('NOT')) _i++;
        _i++;
        if (_cur.kw == 'INITIALLY') _i += 2;
      } else {
        break;
      }
    }
  }

  TableConstraintAst _tableConstraint() {
    if (_acceptKw('CONSTRAINT')) _name();
    if (_acceptKws(['PRIMARY', 'KEY'])) {
      final cols = _indexedColumns();
      _cur.kw == 'AUTOINCREMENT' ? _i++ : null;
      return TableConstraintAst('PK', cols, null, _conflictClause());
    }
    if (_acceptKw('UNIQUE')) {
      final cols = _indexedColumns();
      return TableConstraintAst('UNIQUE', cols, null, _conflictClause());
    }
    if (_acceptKw('CHECK')) {
      _expectOp('(');
      final e = _expr();
      _expectOp(')');
      return TableConstraintAst('CHECK', const [], e, null);
    }
    if (_cur.kw == 'FOREIGN') {
      _i++;
      _expectKw('KEY');
      _indexedColumns();
      _expectKw('REFERENCES');
      _skipForeignKeyClause();
      return const TableConstraintAst('FK', [], null, null);
    }
    throw _error();
  }

  List<IndexedColumn> _indexedColumns() {
    _expectOp('(');
    final out = <IndexedColumn>[];
    do {
      final e = _expr();
      String? coll;
      Expr inner = e;
      if (e is CollateExpr) {
        coll = e.collation;
        inner = e.e;
      }
      var desc = false;
      if (_acceptKw('DESC')) {
        desc = true;
      } else {
        _acceptKw('ASC');
      }
      out.add(IndexedColumn(inner, coll, desc));
    } while (_acceptOp(','));
    _expectOp(')');
    return out;
  }

  CreateIndexStmt _createIndex(bool unique) {
    final ine = _ifNotExists();
    final name = _qualifiedName();
    _expectKw('ON');
    final table = _qualifiedName();
    final cols = _indexedColumns();
    Expr? where;
    if (_acceptKw('WHERE')) where = _expr();
    return CreateIndexStmt(unique, ine, name, table, cols, where);
  }

  Stmt _drop() {
    _expectKw('DROP');
    String kind;
    if (_acceptKw('TABLE')) {
      kind = 'TABLE';
    } else if (_acceptKw('INDEX')) {
      kind = 'INDEX';
    } else if (_acceptKw('VIEW')) {
      kind = 'VIEW';
    } else if (_cur.kw == 'KV' && _peek().kw == 'STORE') {
      _i += 2;
      kind = 'KV STORE';
    } else if (_cur.kw == 'TIMESERIES') {
      _i++;
      kind = 'TIMESERIES';
    } else if (_cur.kw == 'ROLLUP') {
      _i++;
      kind = 'ROLLUP';
    } else {
      throw _error();
    }
    final ie = _ifExists();
    return DropStmt(kind, ie, _qualifiedName());
  }

  Stmt _alter() {
    _expectKw('ALTER');
    _expectKw('TABLE');
    final table = _qualifiedName();
    if (_cur.kw == 'RENAME') {
      _i++;
      if (_acceptKw('TO')) {
        return AlterTableStmt(table, 'RENAME TO', newName: _name());
      }
      _acceptKw('COLUMN');
      final old = _name();
      _expectKw('TO');
      return AlterTableStmt(table, 'RENAME COLUMN',
          oldColumn: old, newName: _name());
    }
    if (_acceptKw('ADD')) {
      _acceptKw('COLUMN');
      return AlterTableStmt(table, 'ADD COLUMN', column: _columnDef());
    }
    if (_acceptKw('DROP')) {
      _acceptKw('COLUMN');
      return AlterTableStmt(table, 'DROP COLUMN', oldColumn: _name());
    }
    if (_acceptKw('SET')) {
      return AlterTableStmt(table, 'SET', options: _options());
    }
    throw _error();
  }

  Stmt _pragma() {
    _expectKw('PRAGMA');
    final name = _qualifiedName().toLowerCase();
    Object? value;
    var call = false;
    Object? pragmaValue() {
      final t = _cur;
      if (t.type == Tok.op && (t.text == '-' || t.text == '+')) {
        _i++;
        final n = _cur;
        _i++;
        final v = n.value as num;
        return t.text == '-' ? -v : v;
      }
      _i++;
      if (t.type == Tok.integer || t.type == Tok.real) return t.value;
      if (t.type == Tok.string || t.type == Tok.ident) return t.text;
      throw _error(t);
    }

    if (_acceptOp('=')) {
      value = pragmaValue();
    } else if (_acceptOp('(')) {
      call = true;
      value = pragmaValue();
      _expectOp(')');
    }
    return PragmaStmt(name, value, call);
  }

  // ------------------------------------------------------------ expressions

  Expr _expr() => _exprBp(0);

  // Binding powers (higher binds tighter):
  //  OR 1, AND 2, NOT 3, equality/IS/IN/LIKE/BETWEEN 4, comparison 5,
  //  bitwise 6, additive 7, multiplicative 8, concat/-> 9, COLLATE 10,
  //  unary 11.
  Expr _exprBp(int minBp) {
    Expr left;
    if (_isKw('NOT')) {
      _i++;
      if (minBp > 3) {
        left = UnaryExpr('NOT', _exprBp(3));
      } else {
        left = UnaryExpr('NOT', _exprBp(3));
      }
    } else {
      left = _unary();
    }
    while (true) {
      final t = _cur;
      if (t.type == Tok.op) {
        final o = t.text;
        int bp;
        switch (o) {
          case '||':
          case '->':
          case '->>':
            bp = 9;
          case '*':
          case '/':
          case '%':
            bp = 8;
          case '+':
          case '-':
            bp = 7;
          case '&':
          case '|':
          case '<<':
          case '>>':
            bp = 6;
          case '<':
          case '<=':
          case '>':
          case '>=':
            bp = 5;
          case '=':
          case '==':
          case '!=':
          case '<>':
            bp = 4;
          default:
            return left;
        }
        if (bp <= minBp) return left;
        _i++;
        final right = _exprBp(bp);
        var op = o;
        if (op == '==') op = '=';
        if (op == '<>') op = '!=';
        left = BinaryExpr(op, left, right);
        continue;
      }
      if (t.type != Tok.ident || t.quoted) return left;
      final k = t.kw;
      switch (k) {
        case 'OR':
          if (1 <= minBp) return left;
          _i++;
          left = BinaryExpr('OR', left, _exprBp(1));
          continue;
        case 'AND':
          if (2 <= minBp) return left;
          _i++;
          left = BinaryExpr('AND', left, _exprBp(2));
          continue;
        case 'COLLATE':
          if (10 <= minBp) return left;
          _i++;
          left = CollateExpr(left, _name());
          continue;
      }
      if (4 <= minBp) return left;
      switch (k) {
        case 'IS':
          _i++;
          var not = _acceptKw('NOT');
          if (_acceptKws(['DISTINCT', 'FROM'])) {
            not = !not;
          }
          final r = _exprBp(4);
          left = BinaryExpr(not ? 'IS NOT' : 'IS', left, r);
          continue;
        case 'ISNULL':
          _i++;
          left = IsNullExpr(false, left);
          continue;
        case 'NOTNULL':
          _i++;
          left = IsNullExpr(true, left);
          continue;
        case 'NOT':
          final n = _peek().kw;
          if (n == 'NULL') {
            _i += 2;
            left = IsNullExpr(true, left);
            continue;
          }
          if (n == 'IN' || n == 'LIKE' || n == 'GLOB' || n == 'BETWEEN' ||
              n == 'REGEXP' || n == 'MATCH') {
            _i++;
            left = _postfixPredicate(left, true);
            continue;
          }
          return left;
        case 'IN':
        case 'LIKE':
        case 'GLOB':
        case 'BETWEEN':
        case 'REGEXP':
        case 'MATCH':
          left = _postfixPredicate(left, false);
          continue;
      }
      return left;
    }
  }

  Expr _postfixPredicate(Expr left, bool not) {
    final k = _cur.kw;
    _i++;
    switch (k) {
      case 'IN':
        if (_acceptOp('(')) {
          if (_isKw('SELECT') || _isKw('VALUES') || _isKw('WITH')) {
            final s = _select();
            _expectOp(')');
            return InSelectExpr(not, left, s);
          }
          final list = <Expr>[];
          if (!_isOp(')')) {
            do {
              list.add(_expr());
            } while (_acceptOp(','));
          }
          _expectOp(')');
          return InListExpr(not, left, list);
        }
        // IN table-name or IN table-function(...)
        final name = _qualifiedName();
        final args = <Expr>[];
        if (_acceptOp('(')) {
          if (!_isOp(')')) {
            do {
              args.add(_expr());
            } while (_acceptOp(','));
          }
          _expectOp(')');
          final core = SelectCore(false,
              const [ResultColumn(null, null, '*', star: true)],
              [JoinItem('', FuncSource(name.toLowerCase(), args, null))],
              null, [], null);
          return InSelectExpr(not, left, SelectStmt(null, core, [], null, null));
        }
        final core = SelectCore(
            false,
            const [ResultColumn(null, null, '*', star: true)],
            [JoinItem('', TableSource(name, null))],
            null,
            [],
            null);
        return InSelectExpr(not, left, SelectStmt(null, core, [], null, null));
      case 'BETWEEN':
        final lo = _exprBp(4);
        _expectKw('AND');
        final hi = _exprBp(4);
        return BetweenExpr(not, left, lo, hi);
      default:
        final pat = _exprBp(4);
        Expr? esc;
        if (_acceptKw('ESCAPE')) esc = _exprBp(4);
        return LikeExpr(k, not, left, pat, esc);
    }
  }

  Expr _unary() {
    if (_isOp('-') || _isOp('+') || _isOp('~')) {
      final o = _cur.text;
      _i++;
      final e = _exprBp(10);
      if (o == '-' && e is LitExpr && e.value is num) {
        final v = e.value as num;
        return LitExpr(v is int ? -v : -(v as double));
      }
      return UnaryExpr(o, e);
    }
    return _primary();
  }

  int _maxParam = 0;
  final Map<String, int> _named = {};

  ParamExpr _param(Token t) {
    final s = t.text;
    if (s == '?') {
      final idx = ++_maxParam;
      _setParam(idx, null);
      return ParamExpr(idx, null);
    }
    if (s.startsWith('?')) {
      final idx = int.parse(s.substring(1));
      if (idx < 1 || idx > 32766) {
        throw ZxDbException('variable number must be between ?1 and ?32766',
            ZxDbError.syntax);
      }
      if (idx > _maxParam) _maxParam = idx;
      _setParam(idx, null);
      return ParamExpr(idx, null);
    }
    final ex = _named[s];
    if (ex != null) return ParamExpr(ex, s);
    final idx = ++_maxParam;
    _named[s] = idx;
    _setParam(idx, s);
    return ParamExpr(idx, s);
  }

  void _setParam(int idx, String? name) {
    while (_params.length < idx) {
      _params.add(null);
    }
    if (name != null) _params[idx - 1] = name;
  }

  Expr _primary() {
    final t = _cur;
    switch (t.type) {
      case Tok.integer:
      case Tok.real:
      case Tok.blob:
        _i++;
        return LitExpr(t.value);
      case Tok.string:
        _i++;
        return LitExpr(t.text);
      case Tok.param:
        _i++;
        return _param(t);
      case Tok.op:
        if (t.text == '(') {
          _i++;
          if (_isKw('SELECT') || _isKw('VALUES') || _isKw('WITH')) {
            final s = _select();
            _expectOp(')');
            return SubqueryExpr(s);
          }
          final e = _expr();
          if (_isOp(',')) {
            final items = [e];
            while (_acceptOp(',')) {
              items.add(_expr());
            }
            _expectOp(')');
            return RowExpr(items);
          }
          _expectOp(')');
          return e;
        }
        throw _error();
      case Tok.eof:
        throw _error();
      case Tok.ident:
        break;
    }
    if (!t.quoted) {
      switch (t.kw) {
        case 'NULL':
          _i++;
          return const LitExpr(null);
        case 'TRUE':
          _i++;
          return const LitExpr(1);
        case 'FALSE':
          _i++;
          return const LitExpr(0);
        case 'CURRENT_TIME':
        case 'CURRENT_DATE':
        case 'CURRENT_TIMESTAMP':
          _i++;
          return CurrentTimeExpr(t.kw);
        case 'CASE':
          _i++;
          Expr? base;
          if (!_isKw('WHEN')) base = _expr();
          final whens = <(Expr, Expr)>[];
          while (_acceptKw('WHEN')) {
            final w = _expr();
            _expectKw('THEN');
            whens.add((w, _expr()));
          }
          if (whens.isEmpty) throw _error();
          Expr? orElse;
          if (_acceptKw('ELSE')) orElse = _expr();
          _expectKw('END');
          return CaseExpr(base, whens, orElse);
        case 'CAST':
          _i++;
          _expectOp('(');
          final e = _expr();
          _expectKw('AS');
          final words = <String>[];
          while (_cur.type == Tok.ident) {
            words.add(_cur.text);
            _i++;
          }
          var type = words.join(' ');
          if (_acceptOp('(')) {
            while (!_isOp(')')) {
              if (_cur.type == Tok.eof) throw _error();
              _i++;
            }
            _i++;
          }
          if (type.isEmpty) type = '';
          _expectOp(')');
          return CastExpr(e, type);
        case 'EXISTS':
          _i++;
          _expectOp('(');
          final s = _select();
          _expectOp(')');
          return ExistsExpr(s);
        case 'NOT':
          _i++;
          return UnaryExpr('NOT', _exprBp(3));
        case 'RAISE':
          _i++;
          _expectOp('(');
          final action = _cur.kw;
          _i++;
          String? msg;
          if (_acceptOp(',')) msg = _stringLit();
          _expectOp(')');
          return RaiseExpr(action, msg);
      }
      if (_reserved.contains(t.kw) &&
          !(_peek().type == Tok.op && _peek().text == '(' &&
              const {'REPLACE', 'LIKE', 'GLOB', 'MATCH', 'REGEXP'}.contains(t.kw))) {
        throw _error();
      }
    }
    // Function call?
    if (_peek().type == Tok.op && _peek().text == '(') {
      final name = t.text.toLowerCase();
      _i += 2;
      final args = <Expr>[];
      var distinct = false, star = false;
      List<OrderTerm>? order;
      if (_acceptOp('*')) {
        star = true;
      } else if (!_isOp(')')) {
        distinct = _acceptKw('DISTINCT');
        do {
          args.add(_expr());
        } while (_acceptOp(','));
        if (_acceptKws(['ORDER', 'BY'])) order = _orderTerms();
      }
      _expectOp(')');
      Expr? filter;
      if (_acceptKw('FILTER')) {
        _expectOp('(');
        _expectKw('WHERE');
        filter = _expr();
        _expectOp(')');
      }
      if (_isKw('OVER')) {
        throw const ZxDbException(
            'window functions are not supported', ZxDbError.unsupported);
      }
      return FuncExpr(name, args,
          distinct: distinct, star: star, filter: filter, orderBy: order);
    }
    // Column reference: [schema.]table.column or column.
    _i++;
    if (_isOp('.') && (_isName(_peek()) || _peek().type == Tok.ident)) {
      _i++;
      final second = _cur.text;
      _i++;
      if (_isOp('.') && _peek().type == Tok.ident) {
        _i++;
        final third = _cur.text;
        _i++;
        return ColumnExpr(second, third);
      }
      return ColumnExpr(t.text, second);
    }
    return ColumnExpr(null, t.text);
  }
}
