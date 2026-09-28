// A small line editor for the interactive `zx sql` shell: the terminal is
// put in raw mode and keys are handled here (cursor moves, deletion,
// history with the arrow keys, Ctrl-A/E/K/U/W, Ctrl-C to drop the line,
// Ctrl-D at an empty line to end). The history is kept in a file.
//
// Bytes come from a synchronous reader (the CLI's standard input) and the
// screen is written through a callback, so it works with the CLI's
// synchronous streams.

import 'dart:io';

class LineEditor {
  /// Reads one byte, -1 at the end of the input.
  final int Function() readByte;

  /// Writes text to the terminal (and flushes it).
  final void Function(String s) write;

  /// Raw mode on (true) or off.
  final void Function(bool raw) setRaw;

  final String? historyPath;
  final List<String> history = [];
  static const int maxHistory = 1000;

  LineEditor(
      {required this.readByte,
      required this.write,
      required this.setRaw,
      this.historyPath}) {
    final p = historyPath;
    if (p == null) return;
    try {
      final f = File(p);
      if (f.existsSync()) {
        final lines = f.readAsLinesSync();
        history.addAll(lines.length > maxHistory
            ? lines.sublist(lines.length - maxHistory)
            : lines);
      }
    } on Object {
      // no history
    }
  }

  void _remember(String line) {
    if (line.trim().isEmpty) return;
    if (history.isNotEmpty && history.last == line) return;
    history.add(line);
    if (history.length > maxHistory) history.removeAt(0);
    final p = historyPath;
    if (p == null || line.contains('\n')) return;
    try {
      File(p).writeAsStringSync('$line\n', mode: FileMode.append);
    } on Object {
      // read-only home
    }
  }

  // one code point from the input (UTF-8), -1 at the end
  int _readRune() {
    final b = readByte();
    if (b < 0x80) return b;
    int need;
    int cp;
    if (b >= 0xF0) {
      need = 3;
      cp = b & 0x07;
    } else if (b >= 0xE0) {
      need = 2;
      cp = b & 0x0F;
    } else if (b >= 0xC0) {
      need = 1;
      cp = b & 0x1F;
    } else {
      return 0xFFFD;
    }
    for (var i = 0; i < need; i++) {
      final c = readByte();
      if (c < 0) return -1;
      cp = (cp << 6) | (c & 0x3F);
    }
    return cp;
  }

  /// Reads a line after showing [prompt]; null at the end of the input.
  String? readLine(String prompt) {
    setRaw(true);
    try {
      return _read(prompt);
    } finally {
      setRaw(false);
    }
  }

  String? _read(String prompt) {
    var buf = <int>[];
    var pos = 0;
    var hi = history.length;
    var saved = <int>[];

    void redraw() {
      final text = String.fromCharCodes(buf);
      final back = buf.length - pos;
      write('\r$prompt$text\x1b[K${back > 0 ? '\x1b[${back}D' : ''}');
    }

    void setBuf(List<int> b) {
      buf = List.of(b);
      pos = buf.length;
      redraw();
    }

    write(prompt);
    for (;;) {
      final c = _readRune();
      if (c < 0) {
        if (buf.isEmpty) {
          write('\r\n');
          return null;
        }
        write('\r\n');
        final s = String.fromCharCodes(buf);
        _remember(s);
        return s;
      }
      switch (c) {
        case 0x0D:
        case 0x0A:
          write('\r\n');
          final s = String.fromCharCodes(buf);
          _remember(s);
          return s;
        case 0x04: // Ctrl-D
          if (buf.isEmpty) {
            write('\r\n');
            return null;
          }
          if (pos < buf.length) {
            buf.removeAt(pos);
            redraw();
          }
        case 0x03: // Ctrl-C: drop the line
          write('^C\r\n');
          return '';
        case 0x01: // Ctrl-A
          pos = 0;
          redraw();
        case 0x05: // Ctrl-E
          pos = buf.length;
          redraw();
        case 0x02: // Ctrl-B
          if (pos > 0) pos--;
          redraw();
        case 0x06: // Ctrl-F
          if (pos < buf.length) pos++;
          redraw();
        case 0x0B: // Ctrl-K
          buf.removeRange(pos, buf.length);
          redraw();
        case 0x15: // Ctrl-U
          buf.removeRange(0, pos);
          pos = 0;
          redraw();
        case 0x17: // Ctrl-W: the word before the cursor
          var p = pos;
          while (p > 0 && buf[p - 1] == 0x20) {
            p--;
          }
          while (p > 0 && buf[p - 1] != 0x20) {
            p--;
          }
          buf.removeRange(p, pos);
          pos = p;
          redraw();
        case 0x0C: // Ctrl-L
          write('\x1b[H\x1b[2J');
          redraw();
        case 0x7F:
        case 0x08:
          if (pos > 0) {
            buf.removeAt(--pos);
            redraw();
          }
        case 0x1B:
          final a = readByte();
          if (a != 0x5B && a != 0x4F) break;
          var b = readByte();
          var num = 0;
          while (b >= 0x30 && b <= 0x39) {
            num = num * 10 + b - 0x30;
            b = readByte();
          }
          switch (b) {
            case 0x41: // up
              if (hi > 0) {
                if (hi == history.length) saved = List.of(buf);
                hi--;
                setBuf(history[hi].runes.toList());
              }
            case 0x42: // down
              if (hi < history.length) {
                hi++;
                setBuf(hi == history.length ? saved : history[hi].runes.toList());
              }
            case 0x43: // right
              if (pos < buf.length) pos++;
              redraw();
            case 0x44: // left
              if (pos > 0) pos--;
              redraw();
            case 0x48: // home
              pos = 0;
              redraw();
            case 0x46: // end
              pos = buf.length;
              redraw();
            case 0x7E: // ESC [ n ~
              if (num == 1 || num == 7) pos = 0;
              if (num == 4 || num == 8) pos = buf.length;
              if (num == 3 && pos < buf.length) buf.removeAt(pos);
              redraw();
          }
        case 0x09: // tab: two spaces
          buf.insertAll(pos, const [0x20, 0x20]);
          pos += 2;
          redraw();
        default:
          if (c < 0x20) break;
          buf.insert(pos++, c);
          if (pos == buf.length) {
            write(String.fromCharCode(c));
          } else {
            redraw();
          }
      }
    }
  }
}

/// The default history file of the shell.
String? defaultSqlHistoryPath() {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) return null;
  return '$home/.zx_sql_history';
}
