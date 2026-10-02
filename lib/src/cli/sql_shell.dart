// `zx sql`: the SQL shell of a .zx archive's database (zx extension, see
// docs/zxdb-sql.md "The zx sql shell"). It follows the sqlite3 command
// line program: statements run one by one and their rows are printed in
// the current output mode (list, csv, json, line, table, box, markdown,
// quote, tabs, with sqlite3's formatting), and dot commands (.tables,
// .schema, .mode, .import, ...) control the session. zx adds .asof
// (read an older generation), .generations, .kv, .vacuum, .import-arca,
// .export-arca, .import-sqlite and .export-sqlite.
//
// The shell is independent of the process streams: it writes through
// callbacks and is fed lines, so tests drive it directly.

import 'dart:convert';
import '../host/io.dart';
import 'dart:typed_data';

import '../db/meta/arca_io.dart';
import '../db/meta/meta_store.dart';
import '../db/sql/value.dart' show formatG, realToText;
import '../db/sql/zx_sql.dart';
import '../db/sqlite_io/sqlite_io.dart';
import '../db/kv_sql.dart';
import '../db/system/archive_view.dart';
import '../db/system/sql_adapter.dart';
import '../db/zxdb.dart';

// ---------------------------------------------------------------------------
// statement splitting

/// Whether [text] ends a statement: a ';' outside quotes and comments
/// followed only by white space (sqlite3_complete without triggers).
bool sqlIsComplete(String text) {
  final (stmts, rest) = splitSqlStatements(text);
  return rest.trim().isEmpty && stmts.isNotEmpty;
}

/// Splits [text] into complete statements (without their ';') with the
/// line each starts on (1-based, from [firstLine]), and the text after the
/// last ';'.
(List<(String, int)>, String) splitSqlStatements(String text,
    [int firstLine = 1]) {
  final out = <(String, int)>[];
  var start = 0;
  var line = firstLine;
  var startLine = firstLine;
  var i = 0;
  final n = text.length;
  var seenText = false;
  while (i < n) {
    final c = text.codeUnitAt(i);
    if (c == 0x0A) {
      line++;
      i++;
      continue;
    }
    if (c == 0x27 || c == 0x22 || c == 0x60 || c == 0x5B) {
      final close = c == 0x5B ? 0x5D : c;
      if (!seenText) {
        seenText = true;
        startLine = line;
      }
      i++;
      while (i < n) {
        final d = text.codeUnitAt(i);
        if (d == 0x0A) line++;
        i++;
        if (d == close) {
          // a doubled quote continues the string
          if (close != 0x5D && i < n && text.codeUnitAt(i) == close) {
            i++;
            continue;
          }
          break;
        }
      }
      continue;
    }
    if (c == 0x2D && i + 1 < n && text.codeUnitAt(i + 1) == 0x2D) {
      while (i < n && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      continue;
    }
    if (c == 0x2F && i + 1 < n && text.codeUnitAt(i + 1) == 0x2A) {
      i += 2;
      while (i < n &&
          !(text.codeUnitAt(i) == 0x2A &&
              i + 1 < n &&
              text.codeUnitAt(i + 1) == 0x2F)) {
        if (text.codeUnitAt(i) == 0x0A) line++;
        i++;
      }
      i += 2;
      continue;
    }
    if (c == 0x3B) {
      final s = text.substring(start, i).trim();
      if (seenText && s.isNotEmpty) out.add((s, startLine));
      start = i + 1;
      seenText = false;
      i++;
      continue;
    }
    if (!seenText && c != 0x20 && c != 0x09 && c != 0x0D) {
      seenText = true;
      startLine = line;
    }
    i++;
  }
  return (out, start >= n || !seenText ? '' : text.substring(start));
}

// ---------------------------------------------------------------------------
// value rendering

/// The text sqlite3 shows for a value.
String sqlValueText(Object? v, [String nullValue = '']) {
  if (v == null) return nullValue;
  if (v is int) return v.toString();
  if (v is double) return realToText(v);
  if (v is String) return v;
  if (v is Uint8List) return utf8.decode(v, allowMalformed: true);
  return v.toString();
}

String _hexOf(List<int> b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// A SQL literal of a value (quote mode, .dump style).
String sqlQuote(Object? v) {
  if (v == null) return 'NULL';
  if (v is int) return v.toString();
  if (v is double) return realExactText(v);
  if (v is Uint8List) return "X'${_hexOf(v)}'";
  return "'${v.toString().replaceAll("'", "''")}'";
}

// sqlite3's needCsvQuote: controls, space, '"', '\'', 0x7f and above
bool _needsCsvQuote(String s, String sep) {
  if (s.isEmpty) return true;
  if (s.contains(sep)) return true;
  for (final b in utf8.encode(s)) {
    if (b < 0x21 || b == 0x22 || b == 0x27 || b >= 0x7F) return true;
  }
  return false;
}

String _csvField(Object? v, String sep, String nullValue, {bool name = false}) {
  if (v == null && !name) return nullValue;
  if (!name && (v is int || v is double)) return sqlValueText(v);
  final s = sqlValueText(v);
  if (_needsCsvQuote(s, sep)) return '"${s.replaceAll('"', '""')}"';
  return s;
}

String _jsonString(String s) {
  final sb = StringBuffer('"');
  for (final c in s.runes) {
    switch (c) {
      case 0x22:
        sb.write(r'\"');
      case 0x5C:
        sb.write(r'\\');
      case 0x08:
        sb.write(r'\b');
      case 0x0C:
        sb.write(r'\f');
      case 0x0A:
        sb.write(r'\n');
      case 0x0D:
        sb.write(r'\r');
      case 0x09:
        sb.write(r'\t');
      default:
        if (c < 0x20) {
          sb.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          sb.writeCharCode(c);
        }
    }
  }
  sb.write('"');
  return sb.toString();
}

/// A REAL with the digits needed to read it back (json and quote modes;
/// sqlite3 prints up to 20 digits there).
String realExactText(double d) {
  if (d == d.truncateToDouble() && d.abs() < 9.2e18) return '${d.toInt()}.0';
  final t = realToText(d);
  if (d.isNaN || d.isInfinite || double.tryParse(t) == d) return t;
  final u = formatG(d, 16, bang: true);
  if (double.tryParse(u) == d) return u;
  return formatG(d, 17, bang: true);
}

String _jsonValue(Object? v) {
  if (v == null) return 'null';
  if (v is int) return v.toString();
  if (v is double) return realExactText(v);
  return _jsonString(sqlValueText(v));
}

// the display width of a cell line (code points)
int _width(String s) => s.runes.length;

// sqlite3's column modes: tabs to the next multiple of 8, lines split
List<String> _cellLines(String s) {
  final out = <String>[];
  for (final l in s.split('\n')) {
    if (!l.contains('\t')) {
      out.add(l);
      continue;
    }
    final sb = StringBuffer();
    var w = 0;
    for (final c in l.runes) {
      if (c == 0x09) {
        do {
          sb.write(' ');
          w++;
        } while (w % 8 != 0);
      } else {
        sb.writeCharCode(c);
        w++;
      }
    }
    out.add(sb.toString());
  }
  return out;
}

String _pad(String s, int w) => s + ' ' * (w - _width(s));

String _center(String s, int w) {
  final pad = w - _width(s);
  final l = pad ~/ 2;
  return '${' ' * l}$s${' ' * (pad - l)}';
}

/// The output modes.
const List<String> sqlShellModes = [
  'list', 'csv', 'json', 'line', 'table', 'box', 'markdown', 'quote', //
  'tabs',
];

/// Formats query results as sqlite3 does in [mode]. Rows are given one by
/// one; the column modes (table, box, markdown) print at [end].
class SqlResultPrinter {
  final String mode;
  final bool headers;
  final String nullValue;
  final String colSep;
  final String rowSep;
  final void Function(String s) write;
  final List<String> columns;
  final List<List<String>> _cells = [];
  int _n = 0;

  SqlResultPrinter(this.mode, this.columns, this.write,
      {this.headers = false,
      this.nullValue = '',
      String? colSep,
      String? rowSep})
      : colSep = colSep ??
            (mode == 'csv' || mode == 'quote'
                ? ','
                : mode == 'tabs'
                    ? '\t'
                    : '|'),
        rowSep = rowSep ?? '\n';

  void row(List<Object?> r) {
    final first = _n++ == 0;
    switch (mode) {
      case 'list':
      case 'tabs':
        if (first && headers) write('${columns.join(colSep)}$rowSep');
        write('${[for (final v in r) sqlValueText(v, nullValue)].join(colSep)}$rowSep');
      case 'quote':
        if (first && headers) {
          write('${[for (final c in columns) sqlQuote(c)].join(colSep)}$rowSep');
        }
        write('${[for (final v in r) sqlQuote(v)].join(colSep)}$rowSep');
      case 'csv':
        if (first && headers) {
          write('${[
            for (final c in columns) _csvField(c, colSep, nullValue, name: true)
          ].join(colSep)}$rowSep');
        }
        write('${[
          for (final v in r) _csvField(v, colSep, nullValue)
        ].join(colSep)}$rowSep');
      case 'json':
        final sb = StringBuffer(first ? '[{' : ',\n{');
        for (var i = 0; i < columns.length; i++) {
          if (i > 0) sb.write(',');
          sb.write('${_jsonString(columns[i])}:${_jsonValue(r[i])}');
        }
        sb.write('}');
        write(sb.toString());
      case 'line':
        var w = 5;
        for (final c in columns) {
          if (_width(c) > w) w = _width(c);
        }
        final sb = StringBuffer(first ? '' : rowSep);
        for (var i = 0; i < columns.length; i++) {
          sb.write('${' ' * (w - _width(columns[i]))}${columns[i]} = '
              '${sqlValueText(r[i], nullValue)}$rowSep');
        }
        write(sb.toString());
      default:
        _cells.add([for (final v in r) sqlValueText(v, nullValue)]);
    }
  }

  void end() {
    if (_n == 0) return;
    switch (mode) {
      case 'json':
        write(']\n');
      case 'table':
      case 'box':
      case 'markdown':
        _columnar();
    }
  }

  void _columnar() {
    final nc = columns.length;
    final w = [for (final c in columns) _width(c)];
    final split = [
      for (final r in _cells) [for (final v in r) _cellLines(v)]
    ];
    var multi = false;
    for (final r in split) {
      for (var i = 0; i < nc; i++) {
        if (r[i].length > 1) multi = true;
        for (final l in r[i]) {
          if (_width(l) > w[i]) w[i] = _width(l);
        }
      }
    }
    final sb = StringBuffer();
    String rule(String l, String m, String r, String h) =>
        '$l${[for (final x in w) h * (x + 2)].join(m)}$r\n';
    String line(List<String> cells, String v, {bool center = false}) {
      final parts = [
        for (var i = 0; i < nc; i++)
          ' ${center ? _center(cells[i], w[i]) : _pad(cells[i], w[i])} '
      ];
      return '$v${parts.join(v)}$v\n';
    }

    void rows(String v, String? sep) {
      for (var k = 0; k < split.length; k++) {
        final r = split[k];
        var h = 1;
        for (final c in r) {
          if (c.length > h) h = c.length;
        }
        for (var j = 0; j < h; j++) {
          sb.write(line([for (final c in r) j < c.length ? c[j] : ''], v));
        }
        if (sep != null && multi && k + 1 < split.length) sb.write(sep);
      }
    }

    if (mode == 'table') {
      final r = rule('+', '+', '+', '-');
      sb.write(r);
      sb.write(line(columns, '|', center: true));
      sb.write(r);
      rows('|', r);
      sb.write(r);
    } else if (mode == 'box') {
      const h = '\u2500';
      const v = '\u2502';
      sb.write(rule('\u250c', '\u252c', '\u2510', h));
      sb.write(line(columns, v, center: true));
      final mid = rule('\u251c', '\u253c', '\u2524', h);
      sb.write(mid);
      rows(v, mid);
      sb.write(rule('\u2514', '\u2534', '\u2518', h));
    } else {
      sb.write(line(columns, '|', center: true));
      sb.write(rule('|', '|', '|', '-'));
      rows('|', null);
    }
    write(sb.toString());
  }
}

// ---------------------------------------------------------------------------
// CSV and JSON input

/// Parses CSV text (RFC 4180, sqlite3's .import rules): rows of fields.
List<List<String>> parseCsv(String text, {String sep = ','}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final f = StringBuffer();
  var i = 0;
  final n = text.length;
  var any = false;
  final sc = sep.codeUnitAt(0);
  while (i < n) {
    final c = text.codeUnitAt(i);
    if (c == 0x22 && f.isEmpty) {
      i++;
      while (i < n) {
        final d = text.codeUnitAt(i);
        if (d == 0x22) {
          if (i + 1 < n && text.codeUnitAt(i + 1) == 0x22) {
            f.write('"');
            i += 2;
            continue;
          }
          i++;
          break;
        }
        f.writeCharCode(d);
        i++;
      }
      any = true;
      continue;
    }
    if (c == sc) {
      row.add(f.toString());
      f.clear();
      any = true;
      i++;
      continue;
    }
    if (c == 0x0D || c == 0x0A) {
      if (any || f.isNotEmpty) {
        row.add(f.toString());
        rows.add(row);
      }
      row = <String>[];
      f.clear();
      any = false;
      if (c == 0x0D && i + 1 < n && text.codeUnitAt(i + 1) == 0x0A) i++;
      i++;
      continue;
    }
    f.writeCharCode(c);
    any = true;
    i++;
  }
  if (any || f.isNotEmpty) {
    row.add(f.toString());
    rows.add(row);
  }
  return rows;
}

/// JSON objects of a file: a JSON array of objects, or one object per line.
List<Map<String, Object?>> parseJsonRecords(String text) {
  final t = text.trim();
  if (t.isEmpty) return const [];
  if (t.startsWith('[')) {
    return [
      for (final o in jsonDecode(t) as List) (o as Map).cast<String, Object?>()
    ];
  }
  return [
    for (final l in const LineSplitter().convert(t))
      if (l.trim().isNotEmpty) (jsonDecode(l) as Map).cast<String, Object?>()
  ];
}

String sqlIdent(String s) => '"${s.replaceAll('"', '""')}"';

// ---------------------------------------------------------------------------
// the AS OF session store

class _AsOfStore implements ZxStore {
  final ZxStore base;
  final int generation;
  _AsOfStore(this.base, this.generation);

  @override
  ZxSnapshot snapshot({int? generation, int? atTimeNs}) {
    if (generation == null && atTimeNs == null) {
      return base.snapshot(generation: this.generation);
    }
    return base.snapshot(generation: generation, atTimeNs: atTimeNs);
  }

  @override
  ZxWriteTxn begin({int waitMs = 5000}) => throw ZxDbException(
      'read only: the session reads generation $generation (.asof off)',
      ZxDbError.readOnly);

  @override
  List<({int generation, int timeNs, String? comment})> get generations =>
      base.generations;

  @override
  void close() {}
}

// ---------------------------------------------------------------------------
// the shell

class _ShellError implements Exception {
  final String message;
  _ShellError(this.message);
}

/// One `zx sql` session.
class ZxSqlShell {
  final ZxDatabase db;
  final String? password;
  final void Function(String s) out;
  final void Function(String s) err;

  /// The directory relative file names are resolved against.
  final String? cwd;

  String mode = 'list';
  bool headers = false;
  String nullValue = '';
  String? colSep;
  String? rowSep;
  bool timer = false;

  /// DATETIME columns (ns since 1970 UTC) print as ISO text, except in
  /// the json and quote modes (exact values); `.datetime off` prints ns.
  bool datetimeText = true;
  bool bail = false;

  /// Named parameters (.param set).
  final Map<String, Object?> params = {};

  /// Errors seen (the exit code is 1 when there were any).
  int errors = 0;
  bool quit = false;

  /// Whether input comes from a terminal (errors then have no line).
  bool interactive = false;

  // the session reading an older generation (.asof), or null
  ZxSql? _asOf;
  int? asOfGeneration;
  ZxArchiveView? _asOfView;

  // pending lines of an incomplete statement
  final StringBuffer _pending = StringBuffer();
  int _pendingLine = 0;
  int _line = 0;
  int _readDepth = 0;

  ZxSqlShell(this.db,
      {this.password, required this.out, required this.err, this.cwd});

  ZxSql get sql => _asOf ?? db.sql;

  /// Whether a statement is waiting for more lines.
  bool get continuing => _pending.isNotEmpty;

  String _path(String p) {
    if (p.startsWith('~/')) {
      final home = Platform.environment['HOME'];
      if (home != null) return '$home${p.substring(1)}';
    }
    final c = cwd;
    if (c == null || p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p)) {
      return p;
    }
    return '$c/$p';
  }

  void close() {
    _asOfView?.close();
    _asOfView = null;
    _asOf?.close();
    _asOf = null;
  }

  // ---- input

  /// Feeds one input line (from a terminal or a script).
  void feedLine(String line) {
    _line++;
    if (_pending.isEmpty) {
      final t = line.trimLeft();
      if (t.startsWith('.')) {
        runDot(t);
        return;
      }
      if (t.isEmpty) return;
      _pendingLine = _line;
    }
    _pending.write(line);
    _pending.write('\n');
    final text = _pending.toString();
    final (stmts, rest) = splitSqlStatements(text, _pendingLine);
    if (stmts.isEmpty && rest.trim().isNotEmpty) return;
    if (rest.trim().isNotEmpty) return; // "a; b" waits for b's ';'
    _pending.clear();
    for (final (s, l) in stmts) {
      if (quit) break;
      runStatement(s, line: l);
      if (bail && errors > 0) quit = true;
    }
  }

  /// Runs what is left at the end of the input.
  void finish() {
    if (_pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();
    final (stmts, rest) = splitSqlStatements(text, _pendingLine);
    for (final (s, l) in stmts) {
      runStatement(s, line: l);
    }
    if (rest.trim().isNotEmpty) {
      runStatement(rest.trim(), line: _pendingLine);
    }
  }

  /// Runs [text] (statements, or a dot command) given on the command line.
  void runArgument(String text) {
    final t = text.trimLeft();
    if (t.startsWith('.')) {
      runDot(t);
      return;
    }
    final (stmts, rest) = splitSqlStatements(text);
    for (final (s, _) in stmts) {
      if (quit) return;
      runStatement(s);
      if (bail && errors > 0) quit = true;
    }
    if (rest.trim().isNotEmpty && !quit) runStatement(rest.trim());
  }

  void _error(String msg, {int? line, bool prepare = false}) {
    errors++;
    if (line == null || interactive) {
      err(prepare ? 'Parse error: $msg\n' : 'Runtime error: $msg\n');
    } else {
      err(prepare
          ? 'Parse error near line $line: $msg\n'
          : 'Runtime error near line $line: $msg\n');
    }
  }

  /// Runs one statement and prints its rows.
  void runStatement(String stmt, {int? line}) {
    final sw = Stopwatch()..start();
    ZxSqlCursor? cur;
    try {
      cur = sql.query(stmt, params.isEmpty ? null : params);
      final p = printer(cur.columns);
      final dt = datetimeText && mode != 'json' && mode != 'quote'
          ? [for (var i = 0; i < cur.columns.length; i++) if (cur.isDatetime(i)) i]
          : const <int>[];
      while (cur.moveNext()) {
        var r = cur.current;
        if (dt.isNotEmpty) {
          r = [...r];
          for (final i in dt) {
            if (r[i] is int) r[i] = zxFormatDatetimeNs(r[i]);
          }
        }
        p.row(r);
      }
      p.end();
    } on ZxDbException catch (e) {
      _error(e.message,
          line: line,
          prepare: e.kind == ZxDbError.syntax || e.message.startsWith('no such '));
    } on FormatException catch (e) {
      _error(e.message, line: line);
    } on StateError catch (e) {
      _error(e.message, line: line);
    } on ArgumentError catch (e) {
      _error('${e.message}', line: line);
    } finally {
      cur?.close();
    }
    if (timer) {
      out('Run Time: real ${(sw.elapsedMicroseconds / 1e6).toStringAsFixed(3)}\n');
    }
  }

  SqlResultPrinter printer(List<String> columns) => SqlResultPrinter(
      mode, columns, out,
      headers: headers, nullValue: nullValue, colSep: colSep, rowSep: rowSep);

  void _printRows(List<String> columns, List<List<Object?>> rows) {
    final p = printer(columns);
    for (final r in rows) {
      p.row(r);
    }
    p.end();
  }

  // names in columns, as .tables and .indexes print them
  void _printNames(List<String> names) {
    if (names.isEmpty) return;
    var maxLen = 0;
    for (final n in names) {
      if (_width(n) > maxLen) maxLen = _width(n);
    }
    var cols = 80 ~/ (maxLen + 2);
    if (cols < 1) cols = 1;
    final rows = (names.length + cols - 1) ~/ cols;
    final sb = StringBuffer();
    for (var i = 0; i < rows; i++) {
      for (var j = i; j < names.length; j += rows) {
        sb.write(j < rows ? '' : '  ');
        sb.write(_pad(names[j], maxLen));
      }
      sb.write('\n');
    }
    out(sb.toString());
  }

  // ---- dot commands

  static final List<String> _systemTables = [
    'zx_files', 'zx_generations', 'zx_file_history', 'zx_meta', //
    'zx_layers', 'zx_media', 'zx_fingerprints',
  ];

  static const String helpText = '''
.asof GEN|DATE|off       Read the database as of a generation or a time
.bail on|off             Stop after hitting an error (default off)
.datetime on|off         DATETIME columns as ISO text (on) or ns (off)
.export FILE [TABLE|SELECT ...]  Write a table or query to FILE (.csv,
                         .json: array of objects, .jsonl: one per line)
.export-arca DIR         Write arca manifests, subtitles, previews to DIR
.export-sqlite FILE      Write the tables and indexes to a SQLite file
.generations             List the generations of the archive
.headers on|off          Turn display of headers on or off
.help                    Show this message
.import FILE TABLE       Import CSV (or JSON, JSON lines) data into TABLE
.import-arca DIR         Read arca manifests (*.arca.json) under DIR
.import-sqlite FILE [TABLE...]  Import tables from a SQLite file
.indexes [TABLE]         Show names of indexes
.kv                      List the KV stores
.mode MODE               Set output mode: box csv json line list markdown
                         quote table tabs
.nullvalue STRING        Use STRING in place of NULL values
.param set|unset|list|clear [NAME [VALUE]]  Statement parameters
.print STRING...         Print literal STRING
.quit                    Exit this program (also .exit)
.read FILE               Read input from FILE
.schema [PATTERN]        Show the CREATE statements matching PATTERN
.separator COL [ROW]     Change the column and row separators
.tables [PATTERN]        List names of tables matching a LIKE pattern
.timer on|off            Turn the SQL timer on or off
.vacuum [ultra]          Compact the archive (ultra: recompress the pages)
''';

  static List<String> _args(String line) {
    final out = <String>[];
    var i = 0;
    final n = line.length;
    while (i < n) {
      final c = line[i];
      if (c == ' ' || c == '\t') {
        i++;
        continue;
      }
      if (c == '"' || c == "'") {
        final sb = StringBuffer();
        i++;
        while (i < n && line[i] != c) {
          if (c == '"' && line[i] == '\\' && i + 1 < n) {
            final e = line[i + 1];
            sb.write(e == 'n'
                ? '\n'
                : e == 't'
                    ? '\t'
                    : e);
            i += 2;
            continue;
          }
          sb.write(line[i++]);
        }
        i++;
        out.add(sb.toString());
        continue;
      }
      final s = i;
      while (i < n && line[i] != ' ' && line[i] != '\t') {
        i++;
      }
      out.add(line.substring(s, i));
    }
    return out;
  }

  bool _onOff(String? s) {
    if (s == null) throw _ShellError('Usage: on|off');
    final l = s.toLowerCase();
    if (l == 'on' || l == 'yes' || l == '1' || l == 'true') return true;
    if (l == 'off' || l == 'no' || l == '0' || l == 'false') return false;
    throw _ShellError('ERROR: Not a boolean value: "$s". Assuming "no".');
  }

  void _needWritable() {
    if (_asOf != null) {
      throw _ShellError('the session reads generation $asOfGeneration '
          '(.asof off to write)');
    }
    if (db.readOnly) throw _ShellError('the database is read only');
    if (db.sql.inTransaction) {
      throw _ShellError('not inside a transaction (COMMIT or ROLLBACK first)');
    }
  }

  /// Runs a dot command.
  void runDot(String line) {
    final a = _args(line.substring(1));
    if (a.isEmpty) return;
    final cmd = a[0].toLowerCase();
    try {
      _dot(cmd, a.sublist(1), line);
    } on _ShellError catch (e) {
      errors++;
      err('${e.message}\n');
    } on ZxDbException catch (e) {
      errors++;
      err('Error: ${e.message}\n');
    } on FileSystemException catch (e) {
      errors++;
      err('Error: ${e.message}${e.path == null ? '' : ': ${e.path}'}\n');
    } on FormatException catch (e) {
      errors++;
      err('Error: ${e.message}\n');
    }
    if (bail && errors > 0) quit = true;
  }

  void _dot(String cmd, List<String> a, String line) {
    switch (cmd) {
      case 'quit':
      case 'exit':
      case 'q':
        quit = true;
      case 'help':
        out(helpText);
      case 'headers':
      case 'header':
        headers = _onOff(a.isEmpty ? null : a[0]);
      case 'bail':
        bail = _onOff(a.isEmpty ? null : a[0]);
      case 'timer':
        timer = _onOff(a.isEmpty ? null : a[0]);
      case 'datetime':
        datetimeText = _onOff(a.isEmpty ? null : a[0]);
      case 'mode':
        if (a.isEmpty) {
          out('current output mode: $mode\n');
          return;
        }
        final m = a[0].toLowerCase();
        if (!sqlShellModes.contains(m)) {
          throw _ShellError('Error: mode should be one of: '
              '${sqlShellModes.join(' ')}');
        }
        mode = m;
        colSep = null;
        rowSep = m == 'csv' ? '\r\n' : null;
      case 'nullvalue':
        nullValue = a.isEmpty ? '' : a[0];
      case 'separator':
        if (a.isEmpty) throw _ShellError('Usage: .separator COL ?ROW?');
        colSep = a[0];
        if (a.length > 1) rowSep = a[1];
      case 'print':
        out('${a.join(' ')}\n');
      case 'tables':
        _tables(a.isEmpty ? null : a[0]);
      case 'indexes':
      case 'indices':
        final rows = sql.select(
            "SELECT name FROM sqlite_schema WHERE type = 'index'"
            "${a.isEmpty ? '' : ' AND tbl_name LIKE ?'} ORDER BY name",
            a.isEmpty ? null : [a[0]]);
        _printNames([for (final r in rows) r[0] as String]);
      case 'schema':
        _schema(a.isEmpty ? null : a[0]);
      case 'read':
        if (a.isEmpty) throw _ShellError('Usage: .read FILE');
        _read(_path(a[0]));
      case 'param':
      case 'parameter':
        _param(a);
      case 'import':
        _import(a);
      case 'export':
        _export(a, line);
      case 'asof':
        _asof(a.isEmpty ? null : a.join(' '));
      case 'generations':
        _printRows(const [
          'generation', 'time', 'comment'
        ], [
          for (final g in db.generations)
            [g.generation, _time(g.timeNs), g.comment]
        ]);
      case 'kv':
        final rows = <List<Object?>>[];
        for (final n in db.kvStores) {
          final s = db.kvSettings(n);
          final count = db.sql.select('SELECT count(*) FROM ${sqlIdent(n)}');
          rows.add([n, s.ttlMs == null ? null : '${s.ttlMs! ~/ 1000}s', count[0][0]]);
        }
        _printRows(const ['name', 'ttl', 'entries'], rows);
      case 'vacuum':
        _needWritable();
        final ultra = a.isNotEmpty && a[0].toLowerCase() == 'ultra';
        final freed = db.vacuum(ultra: ultra, recompress: ultra);
        db.resetSql();
        out('vacuum: $freed bytes freed\n');
      case 'import-arca':
        if (a.isEmpty) throw _ShellError('Usage: .import-arca DIR');
        _needWritable();
        final dir = _path(a[0]);
        if (!Directory(dir).existsSync()) {
          throw _ShellError('Error: cannot open "$dir"');
        }
        final r = db.transaction((t) => arcaImport(ZxMetaDb(t), dir),
            comment: 'arca import');
        out('imported: $r\n');
        for (final w in r.warnings) {
          err('warning: $w\n');
        }
      case 'export-arca':
        if (a.isEmpty) throw _ShellError('Usage: .export-arca DIR');
        final dir = _path(a[0]);
        Directory(dir).createSync(recursive: true);
        final snap = asOfGeneration == null
            ? db.snapshot()
            : db.snapshot(generation: asOfGeneration);
        final view = ZxArchiveView.open(db.path, password: password);
        try {
          final r = arcaExport(ZxMetaDb(snap), dir, archive: view);
          out('exported: $r\n');
        } finally {
          view?.close();
          snap.close();
        }
      case 'import-sqlite':
        if (a.isEmpty) throw _ShellError('Usage: .import-sqlite FILE [TABLE...]');
        _needWritable();
        final r = sqliteImport(db.sql, _path(a[0]),
            tables: a.length > 1 ? a.sublist(1) : null);
        out('imported: ${r.tables} tables, ${r.rows} rows, ${r.indexes} '
            'indexes, ${r.views} views\n');
        for (final w in r.warnings) {
          err('warning: $w\n');
        }
      case 'export-sqlite':
        if (a.isEmpty) {
          throw _ShellError('Usage: .export-sqlite FILE [TABLE...]');
        }
        final r = sqliteExport(sql, _path(a[0]),
            tables: a.length > 1 ? a.sublist(1) : null);
        out('exported: ${r.tables} tables, ${r.rows} rows, ${r.indexes} '
            'indexes, ${r.views} views\n');
        for (final w in r.warnings) {
          err('warning: $w\n');
        }
      default:
        throw _ShellError('Error: unknown command or invalid arguments:  '
            '"$cmd". Enter ".help" for help');
    }
  }

  static String _time(int ns) {
    final d = DateTime.fromMicrosecondsSinceEpoch(ns ~/ 1000, isUtc: true);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  void _tables(String? pattern) {
    final names = <String>{};
    for (final r in sql.select(
        "SELECT name FROM sqlite_schema WHERE type IN ('table', 'view')")) {
      final n = r[0] as String;
      if (!n.startsWith('sqlite_')) names.add(n);
    }
    names.addAll(db.kvStores);
    if (pattern != null) names.addAll(_systemTables);
    var list = names.toList();
    if (pattern != null) {
      final re = _likeRegExp(pattern);
      list = [for (final n in list) if (re.hasMatch(n)) n];
    }
    list.sort();
    _printNames(list);
  }

  static RegExp _likeRegExp(String p) {
    final sb = StringBuffer('^');
    for (final c in p.split('')) {
      sb.write(c == '%'
          ? '.*'
          : c == '_'
              ? '.'
              : RegExp.escape(c));
    }
    sb.write(r'$');
    return RegExp(sb.toString(), caseSensitive: false);
  }

  void _schema(String? pattern) {
    final re = pattern == null ? null : _likeRegExp(pattern);
    final sb = StringBuffer();
    for (final r in sql.select(
        'SELECT name, tbl_name, sql FROM sqlite_schema WHERE sql IS NOT NULL')) {
      if (re != null &&
          !re.hasMatch(r[0] as String) &&
          !re.hasMatch(r[1] as String)) {
        continue;
      }
      sb.write('${r[2]};\n');
    }
    for (final n in db.kvStores) {
      if (re != null && !re.hasMatch(n)) continue;
      sb.write('CREATE KV STORE ${sqlIdent(n)};\n');
    }
    if (re != null) {
      for (final s in ZxMetaSchema.all) {
        if (re.hasMatch(s.name)) sb.write('${s.ddl};\n');
      }
    }
    out(sb.toString());
  }

  void _read(String path) {
    if (_readDepth > 20) throw _ShellError('Error: .read nested too deeply');
    final text = File(path).readAsStringSync();
    _readDepth++;
    final savedLine = _line;
    final savedInteractive = interactive;
    interactive = false;
    _line = 0;
    try {
      for (final l in const LineSplitter().convert(text)) {
        if (quit) break;
        feedLine(l);
      }
      finish();
    } finally {
      _line = savedLine;
      interactive = savedInteractive;
      _readDepth--;
    }
    // .quit in a file read ends that file only, as in sqlite3
    if (_readDepth > 0) return;
    quit = false;
  }

  void _param(List<String> a) {
    final sub = a.isEmpty ? 'list' : a[0].toLowerCase();
    switch (sub) {
      case 'list':
        final sb = StringBuffer();
        var w = 0;
        for (final k in params.keys) {
          if (k.length > w) w = k.length;
        }
        for (final e in params.entries) {
          sb.write('${_pad(e.key, w)} ${sqlQuote(e.value)}\n');
        }
        out(sb.toString());
      case 'clear':
      case 'init':
        params.clear();
      case 'unset':
        if (a.length < 2) throw _ShellError('Usage: .param unset NAME');
        params.remove(a[1]);
      case 'set':
        if (a.length < 3) throw _ShellError('Usage: .param set NAME VALUE');
        final name = a[1];
        final text = a.sublist(2).join(' ');
        Object? v;
        try {
          v = db.sql.select('SELECT $text')[0][0];
        } on ZxDbException {
          v = text;
        }
        params[name] = v;
      default:
        throw _ShellError('Usage: .param set|unset|list|clear');
    }
  }

  void _asof(String? arg) {
    if (arg == null) {
      out(asOfGeneration == null
          ? 'current state\n'
          : 'generation $asOfGeneration\n');
      return;
    }
    if (arg.toLowerCase() == 'off' || arg.toLowerCase() == 'now') {
      close();
      asOfGeneration = null;
      return;
    }
    var g = int.tryParse(arg);
    if (g == null) {
      final ns = db.sql.select('SELECT zx_ns(?)', [arg])[0][0];
      if (ns is! int) throw _ShellError('Error: not a time: $arg');
      final snap = db.snapshot(atTimeNs: ns);
      g = snap.generation;
      snap.close();
    } else {
      db.snapshot(generation: g).close(); // checks that it exists
    }
    close();
    final q = ZxSql(_AsOfStore(db.store, g));
    final v = _asOfView = ZxArchiveView.open(db.path, password: password);
    ZxSystemSql(archive: v, database: true)
        .register(q.registerVirtualTable, q.functions);
    zxKvRegisterSql(q);
    _asOf = q;
    asOfGeneration = g;
    out('reading generation $g\n');
  }

  void _import(List<String> a) {
    var csv = true;
    var json = false;
    var skip = 0;
    final rest = <String>[];
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      if (x == '--csv') {
        csv = true;
      } else if (x == '--json') {
        json = true;
      } else if (x == '--skip' && i + 1 < a.length) {
        skip = int.parse(a[++i]);
      } else {
        rest.add(x);
      }
    }
    if (rest.length != 2) {
      throw _ShellError('Usage: .import [--csv|--json] [--skip N] FILE TABLE');
    }
    _needWritable();
    final file = _path(rest[0]);
    final table = rest[1];
    final lower = file.toLowerCase();
    if (lower.endsWith('.json') ||
        lower.endsWith('.jsonl') ||
        lower.endsWith('.ndjson')) {
      json = true;
    }
    final text = File(file).readAsStringSync();
    final exists = sql
        .select("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND "
            'lower(name) = lower(?)', [table])
        .isNotEmpty;
    List<String>? cols;
    List<List<Object?>> rows;
    if (json) {
      final recs = parseJsonRecords(text);
      if (exists) {
        cols = [
          for (final r in sql.execute('PRAGMA table_info(${sqlIdent(table)})').rows)
            r[1] as String
        ];
      } else {
        final keys = <String>[];
        for (final r in recs) {
          for (final k in r.keys) {
            if (!keys.contains(k)) keys.add(k);
          }
        }
        cols = keys;
      }
      rows = [
        for (final r in recs.skip(skip))
          [
            for (final c in cols)
              switch (r[c]) {
                final bool b => b ? 1 : 0,
                final List<Object?> l => jsonEncode(l),
                final Map<Object?, Object?> m => jsonEncode(m),
                final v => v,
              }
          ]
      ];
    } else {
      assert(csv);
      final data = parseCsv(text, sep: colSep == null || mode != 'csv' ? ',' : colSep!);
      var body = data;
      if (!exists) {
        if (data.isEmpty) throw _ShellError('Error: $file is empty');
        cols = data.first;
        body = data.sublist(1);
      }
      rows = [for (final r in body.skip(skip)) r];
    }
    final db2 = db.sql;
    if (!exists) {
      db2.execute('CREATE TABLE ${sqlIdent(table)} '
          '(${[for (final c in cols!) '${sqlIdent(c)}${json ? '' : ' TEXT'}'].join(', ')})');
    }
    final n = exists
        ? db2.execute('PRAGMA table_info(${sqlIdent(table)})').rows.length
        : cols!.length;
    final st = db2.prepare('INSERT INTO ${sqlIdent(table)}'
        '${json && exists ? ' (${[for (final c in cols!) sqlIdent(c)].join(', ')})' : ''}'
        ' VALUES (${List.filled(json && exists ? cols!.length : n, '?').join(', ')})');
    final width = json && exists ? cols!.length : n;
    db2.execute('BEGIN');
    var line = skip + (exists ? 0 : 1);
    try {
      for (final r in rows) {
        line++;
        var v = r;
        if (v.length != width) {
          if (!json) {
            err('$file:$line: expected $width columns but found ${v.length}'
                ' - ${v.length < width ? 'filling the rest with NULL' : 'extras ignored'}\n');
          }
          v = [
            for (var i = 0; i < width; i++) i < v.length ? v[i] : null
          ];
        }
        st.execute(v);
      }
      db2.execute('COMMIT');
    } catch (_) {
      db2.execute('ROLLBACK');
      rethrow;
    }
  }

  void _export(List<String> a, String line) {
    if (a.isEmpty) throw _ShellError('Usage: .export FILE [TABLE|SELECT ...]');
    final file = _path(a[0]);
    String query;
    if (a.length == 1) {
      throw _ShellError('Usage: .export FILE [TABLE|SELECT ...]');
    }
    // the rest of the line after the file name is the query or table
    final idx = line.indexOf(a[0]) + a[0].length;
    final rest = line.substring(idx).trim();
    final word = a.length == 2 && !a[1].contains(' ');
    if (word && !RegExp(r'^(select|with|values|pragma)\b', caseSensitive: false)
        .hasMatch(a[1])) {
      query = 'SELECT * FROM ${sqlIdent(a[1])}';
    } else {
      query = rest.endsWith(';') ? rest.substring(0, rest.length - 1) : rest;
    }
    final lower = file.toLowerCase();
    final cur = sql.query(query, params.isEmpty ? null : params);
    final sink = _SyncWriter(File(file).openSync(mode: FileMode.write));
    var n = 0;
    try {
      if (lower.endsWith('.json') || lower.endsWith('.jsonl') ||
          lower.endsWith('.ndjson')) {
        final lines = !lower.endsWith('.json');
        if (!lines) sink.write('[');
        while (cur.moveNext()) {
          final m = <String, Object?>{};
          for (var i = 0; i < cur.columns.length; i++) {
            final v = cur.current[i];
            m[cur.columns[i]] = v is Uint8List ? _hexOf(v) : v;
          }
          final j = jsonEncode(m);
          if (lines) {
            sink.write('$j\n');
          } else {
            sink.write(n == 0 ? '\n$j' : ',\n$j');
          }
          n++;
        }
        if (!lines) sink.write('\n]\n');
      } else {
        sink.write('${[
          for (final c in cur.columns) _csvField(c, ',', '', name: true)
        ].join(',')}\r\n');
        while (cur.moveNext()) {
          sink.write('${[
            for (final v in cur.current)
              v is Uint8List ? _hexOf(v) : _csvField(v, ',', '')
          ].join(',')}\r\n');
          n++;
        }
      }
    } finally {
      cur.close();
      sink.close();
    }
    out('exported $n rows to ${a[0]}\n');
  }
}

// buffered synchronous file output (the CLI runs synchronously)
class _SyncWriter {
  final RandomAccessFile raf;
  final StringBuffer _b = StringBuffer();
  _SyncWriter(this.raf);
  void write(String s) {
    _b.write(s);
    if (_b.length > 1 << 16) _flush();
  }

  void _flush() {
    raf.writeStringSync(_b.toString());
    _b.clear();
  }

  void close() {
    _flush();
    raf.closeSync();
  }
}
