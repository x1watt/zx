// The `zx sql` command (zx extension): options, opening the database and
// the input loop of the shell (lib/src/cli/sql_shell.dart).
//
//   zx sql [options] ARCHIVE [SQL | .command] ...
//
// With SQL arguments they run in order and the program ends; without
// them statements are read from the standard input (an interactive shell
// with line editing on a terminal).

import 'dart:convert';
import '../host/io.dart';

import '../db/zxdb.dart';
import 'globals.dart';
import 'line_editor.dart';
import 'platform.dart';
import 'sql_shell.dart';
import 'std_stream.dart';

const String zxSqlUsage = '''
Usage: zx sql [OPTIONS] ARCHIVE [SQL | .COMMAND ...]
Runs SQL on the database of a .zx archive (created on first write). With no
SQL, reads statements from the standard input (an interactive shell on a
terminal; ".help" lists the dot commands).
OPTIONS:
   -box -csv -json -line -list -markdown -quote -table -tabs  output mode
   -header / -noheader    turn headers on or off
   -separator SEP         column separator
   -nullvalue TEXT        text for NULL values
   -cmd COMMAND           run COMMAND before the input
   -bail                  stop after the first error
   -readonly              open the archive read only
   -p{Password}           password of an encrypted archive
   -version               show the SQL version
''';

/// Runs `zx sql` with [args] (after the word "sql"); returns the exit
/// code.
int runSqlCommand(List<String> args, CliIo io) {
  void out(String s) => gStdOut.write(s);
  void err(String s) {
    gStdOut.flush();
    gStdErr.write(s);
  }

  String? mode;
  bool? headers;
  String? sep;
  String? nullValue;
  final cmds = <String>[];
  var bail = false;
  var readOnly = false;
  String? password;
  String? archive;
  final sqlArgs = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (archive == null && a.startsWith('-') && a.length > 1) {
      final o = a.startsWith('--') ? a.substring(2) : a.substring(1);
      if (sqlShellModes.contains(o)) {
        mode = o;
      } else if (o == 'header' || o == 'headers') {
        headers = true;
      } else if (o == 'noheader') {
        headers = false;
      } else if (o == 'bail') {
        bail = true;
      } else if (o == 'readonly') {
        readOnly = true;
      } else if ((o == 'cmd' || o == 'separator' || o == 'nullvalue') &&
          i + 1 < args.length) {
        final v = args[++i];
        if (o == 'cmd') cmds.add(v);
        if (o == 'separator') sep = v;
        if (o == 'nullvalue') nullValue = v;
      } else if (o == 'version') {
        out('3.45.1 (zxdb)\n');
        return 0;
      } else if (o == 'help' || o == 'h') {
        out(zxSqlUsage);
        return 0;
      } else if (a.startsWith('-p')) {
        password = a.substring(2);
      } else {
        err('zx sql: Error: unknown option: $a\n$zxSqlUsage');
        return 1;
      }
      continue;
    }
    if (archive == null) {
      archive = a;
    } else {
      sqlArgs.add(a);
    }
  }
  if (archive == null) {
    err(zxSqlUsage);
    return 1;
  }
  final cwd = io.workingDirectory;
  var path = archive;
  if (cwd != null && !File(path).isAbsolute) path = '$cwd/$path';
  ZxDatabase db;
  try {
    final exists = File(path).existsSync();
    if (!exists && readOnly) {
      err('Error: unable to open database "$archive": no such file\n');
      return 1;
    }
    db = ZxDatabase.open(path,
        password: password, readOnly: readOnly, create: !exists);
  } on ZxDbException catch (e) {
    err('Error: unable to open database "$archive": ${e.message}\n');
    return 1;
  } on FileSystemException catch (e) {
    err('Error: unable to open database "$archive": ${e.message}\n');
    return 1;
  }
  final shell =
      ZxSqlShell(db, password: password, out: out, err: err, cwd: cwd);
  shell.bail = bail;
  if (mode != null) {
    shell.mode = mode;
    if (mode == 'csv') shell.colSep = ',';
  }
  if (headers != null) shell.headers = headers;
  if (sep != null) shell.colSep = sep;
  if (nullValue != null) shell.nullValue = nullValue;
  try {
    for (final c in cmds) {
      shell.runArgument(c);
      if (shell.quit) return shell.errors > 0 ? 1 : 0;
    }
    if (sqlArgs.isNotEmpty) {
      for (final s in sqlArgs) {
        shell.runArgument(s);
        if (shell.quit || (bail && shell.errors > 0)) break;
      }
      return shell.errors > 0 ? 1 : 0;
    }
    if (io.stdinIsTerminal) {
      _interactive(shell, io);
      return 0;
    }
    // a script on the standard input
    final lines = _StdinLines();
    for (;;) {
      final l = lines.next();
      if (l == null) break;
      shell.feedLine(l);
      if (shell.quit) break;
    }
    if (!shell.quit) shell.finish();
    return shell.errors > 0 ? 1 : 0;
  } finally {
    shell.close();
    try {
      db.close();
    } on Object catch (e) {
      err('Error: $e\n');
    }
    gStdOut.flush();
  }
}

class _StdinLines {
  String? next() {
    final s = gStdIn;
    if (s.eof) return null;
    final bytes = s.scanAStringUntilNewLine() ?? const <int>[];
    if (s.eof && bytes.isEmpty) return null;
    var l = utf8.decode(bytes, allowMalformed: true);
    if (l.endsWith('\r')) l = l.substring(0, l.length - 1);
    return l;
  }
}

void _interactive(ZxSqlShell shell, CliIo io) {
  shell.interactive = true;
  gStdOut.write('zx sql (zxdb, SQLite 3.45 dialect)\n'
      'Enter ".help" for usage hints.\n');
  gStdOut.flush();
  LineEditor? ed;
  if (!kIsWin) {
    ed = LineEditor(
        readByte: gStdIn.getChar,
        write: (s) {
          gStdOut.write(s);
          gStdOut.flush();
        },
        setRaw: (raw) {
          try {
            stdin.echoMode = !raw;
            stdin.lineMode = !raw;
          } on Object {
            // not a terminal after all
          }
        },
        historyPath: defaultSqlHistoryPath());
  }
  final lines = _StdinLines();
  for (;;) {
    final prompt = shell.continuing ? '   ...> ' : 'zx> ';
    String? l;
    if (ed != null) {
      l = ed.readLine(prompt);
    } else {
      gStdOut.write(prompt);
      gStdOut.flush();
      l = lines.next();
    }
    if (l == null) break;
    shell.feedLine(l);
    gStdOut.flush();
    if (shell.quit) return;
  }
  shell.finish();
}
