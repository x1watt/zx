// SQL tokenizer (SQLite lexical rules).

import 'dart:typed_data';

import '../storage_api.dart';

enum Tok {
  ident, // word or quoted identifier
  string,
  blob,
  integer,
  real,
  param,
  op, // punctuation and operators
  eof,
}

class Token {
  final Tok type;

  /// Source text for words and operators; decoded value for strings and
  /// quoted identifiers.
  final String text;
  final int pos;
  final int end;

  /// True for "quoted", [bracketed] or `backticked` identifiers (never
  /// keywords).
  final bool quoted;
  final Object? value; // int, double, Uint8List for literals
  const Token(this.type, this.text, this.pos, this.end,
      {this.quoted = false, this.value});

  /// Upper case word (for keyword tests); empty for non words.
  String get kw => type == Tok.ident && !quoted ? text.toUpperCase() : '';

  @override
  String toString() => '$type($text)';
}

class Lexer {
  final String src;
  int _p = 0;
  Lexer(this.src);

  static ZxDbException _err(String m) => ZxDbException(m, ZxDbError.syntax);

  List<Token> tokenize() {
    final out = <Token>[];
    while (true) {
      final t = _next();
      out.add(t);
      if (t.type == Tok.eof) break;
    }
    return out;
  }

  static bool _identStart(int c) =>
      (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127;
  static bool _identPart(int c) =>
      _identStart(c) || (c >= 48 && c <= 57) || c == 36;
  static bool _digit(int c) => c >= 48 && c <= 57;

  Token _next() {
    final s = src;
    final n = s.length;
    // Skip spaces and comments.
    while (_p < n) {
      final c = s.codeUnitAt(_p);
      if (c == 32 || c == 9 || c == 10 || c == 13 || c == 12) {
        _p++;
      } else if (c == 45 && _p + 1 < n && s.codeUnitAt(_p + 1) == 45) {
        while (_p < n && s.codeUnitAt(_p) != 10) {
          _p++;
        }
      } else if (c == 47 && _p + 1 < n && s.codeUnitAt(_p + 1) == 42) {
        final e = s.indexOf('*/', _p + 2);
        _p = e < 0 ? n : e + 2;
      } else {
        break;
      }
    }
    if (_p >= n) return Token(Tok.eof, '', n, n);
    final st = _p;
    final c = s.codeUnitAt(_p);
    // Blob literal.
    if ((c == 120 || c == 88) && _p + 1 < n && s.codeUnitAt(_p + 1) == 39) {
      final e = s.indexOf("'", _p + 2);
      if (e < 0) throw _err('unrecognized token: "${s.substring(st)}"');
      final hex = s.substring(_p + 2, e);
      if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
        throw _err('unrecognized token: "${s.substring(st, e + 1)}"');
      }
      final b = Uint8List(hex.length ~/ 2);
      for (var i = 0; i < b.length; i++) {
        b[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
      }
      _p = e + 1;
      return Token(Tok.blob, s.substring(st, _p), st, _p, value: b);
    }
    if (_identStart(c)) {
      while (_p < n && _identPart(s.codeUnitAt(_p))) {
        _p++;
      }
      return Token(Tok.ident, s.substring(st, _p), st, _p);
    }
    if (_digit(c) || (c == 46 && _p + 1 < n && _digit(s.codeUnitAt(_p + 1)))) {
      return _number();
    }
    switch (c) {
      case 39: // '
        final b = StringBuffer();
        _p++;
        while (true) {
          if (_p >= n) throw _err('unrecognized token: "${s.substring(st)}"');
          final d = s.codeUnitAt(_p);
          if (d == 39) {
            if (_p + 1 < n && s.codeUnitAt(_p + 1) == 39) {
              b.write("'");
              _p += 2;
              continue;
            }
            _p++;
            break;
          }
          b.writeCharCode(d);
          _p++;
        }
        return Token(Tok.string, b.toString(), st, _p);
      case 34: // "
      case 96: // `
        final q = c;
        final b = StringBuffer();
        _p++;
        while (true) {
          if (_p >= n) throw _err('unrecognized token: "${s.substring(st)}"');
          final d = s.codeUnitAt(_p);
          if (d == q) {
            if (_p + 1 < n && s.codeUnitAt(_p + 1) == q) {
              b.writeCharCode(q);
              _p += 2;
              continue;
            }
            _p++;
            break;
          }
          b.writeCharCode(d);
          _p++;
        }
        return Token(Tok.ident, b.toString(), st, _p, quoted: true);
      case 91: // [
        final e = s.indexOf(']', _p);
        if (e < 0) throw _err('unrecognized token: "${s.substring(st)}"');
        _p = e + 1;
        return Token(Tok.ident, s.substring(st + 1, e), st, _p, quoted: true);
      case 63: // ?
        _p++;
        while (_p < n && _digit(s.codeUnitAt(_p))) {
          _p++;
        }
        return Token(Tok.param, s.substring(st, _p), st, _p);
      case 58: // :
      case 64: // @
      case 36: // $
        _p++;
        while (_p < n && (_identPart(s.codeUnitAt(_p)) || s.codeUnitAt(_p) == 58)) {
          // $a::b style Tcl names are accepted as part of the name.
          if (s.codeUnitAt(_p) == 58 &&
              !(_p + 1 < n && s.codeUnitAt(_p + 1) == 58)) {
            break;
          }
          _p++;
        }
        if (_p == st + 1) throw _err('unrecognized token: "${s[st]}"');
        return Token(Tok.param, s.substring(st, _p), st, _p);
    }
    // Operators, longest first.
    const ops = [
      '->>', '||', '->', '<=', '>=', '==', '!=', '<>', '<<', '>>', //
      '(', ')', ',', ';', '.', '+', '-', '*', '/', '%', '<', '>', '=', //
      '&', '|', '~',
    ];
    for (final o in ops) {
      if (s.startsWith(o, _p)) {
        _p += o.length;
        return Token(Tok.op, o, st, _p);
      }
    }
    throw _err('unrecognized token: "${s[_p]}"');
  }

  Token _number() {
    final s = src;
    final n = s.length;
    final st = _p;
    if (s.codeUnitAt(_p) == 48 &&
        _p + 1 < n &&
        (s.codeUnitAt(_p + 1) | 32) == 120) {
      _p += 2;
      final hs = _p;
      while (_p < n && RegExp(r'[0-9a-fA-F]').hasMatch(s[_p])) {
        _p++;
      }
      final hex = s.substring(hs, _p);
      if (hex.isEmpty || hex.length > 16) {
        throw _err('hex literal too big: ${s.substring(st, _p)}');
      }
      final v = BigInt.parse(hex, radix: 16).toSigned(64).toInt();
      return Token(Tok.integer, s.substring(st, _p), st, _p, value: v);
    }
    var isReal = false;
    while (_p < n && _digit(s.codeUnitAt(_p))) {
      _p++;
    }
    if (_p < n && s.codeUnitAt(_p) == 46) {
      isReal = true;
      _p++;
      while (_p < n && _digit(s.codeUnitAt(_p))) {
        _p++;
      }
    }
    if (_p < n && (s.codeUnitAt(_p) | 32) == 101) {
      var j = _p + 1;
      if (j < n && (s.codeUnitAt(j) == 43 || s.codeUnitAt(j) == 45)) j++;
      if (j < n && _digit(s.codeUnitAt(j))) {
        isReal = true;
        _p = j;
        while (_p < n && _digit(s.codeUnitAt(_p))) {
          _p++;
        }
      }
    }
    if (_p < n && _identStart(s.codeUnitAt(_p))) {
      throw _err('unrecognized token: "${s.substring(st, _p + 1)}"');
    }
    final text = s.substring(st, _p);
    if (!isReal) {
      final v = int.tryParse(text);
      if (v != null) return Token(Tok.integer, text, st, _p, value: v);
      return Token(Tok.real, text, st, _p, value: double.parse(text));
    }
    var t = text;
    if (t.startsWith('.')) t = '0$t';
    t = t.replaceFirst(RegExp(r'\.(?=[eE]|$)'), '');
    return Token(Tok.real, text, st, _p, value: double.parse(t));
  }
}
