// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

import 'io.dart';
import 'zpaql.dart';

const List<String> _compname = [
  '', 'const', 'cm', 'icm', 'match', 'avg', 'mix2', 'mix', 'isse', 'sse' //
];

const List<String> _opcodelist = [
  'error', 'a++', 'a--', 'a!', 'a=0', '', '', 'a=r', //
  'b<>a', 'b++', 'b--', 'b!', 'b=0', '', '', 'b=r', //
  'c<>a', 'c++', 'c--', 'c!', 'c=0', '', '', 'c=r', //
  'd<>a', 'd++', 'd--', 'd!', 'd=0', '', '', 'd=r', //
  '*b<>a', '*b++', '*b--', '*b!', '*b=0', '', '', 'jt', //
  '*c<>a', '*c++', '*c--', '*c!', '*c=0', '', '', 'jf', //
  '*d<>a', '*d++', '*d--', '*d!', '*d=0', '', '', 'r=a', //
  'halt', 'out', '', 'hash', 'hashd', '', '', 'jmp', //
  'a=a', 'a=b', 'a=c', 'a=d', 'a=*b', 'a=*c', 'a=*d', 'a=', //
  'b=a', 'b=b', 'b=c', 'b=d', 'b=*b', 'b=*c', 'b=*d', 'b=', //
  'c=a', 'c=b', 'c=c', 'c=d', 'c=*b', 'c=*c', 'c=*d', 'c=', //
  'd=a', 'd=b', 'd=c', 'd=d', 'd=*b', 'd=*c', 'd=*d', 'd=', //
  '*b=a', '*b=b', '*b=c', '*b=d', '*b=*b', '*b=*c', '*b=*d', '*b=', //
  '*c=a', '*c=b', '*c=c', '*c=d', '*c=*b', '*c=*c', '*c=*d', '*c=', //
  '*d=a', '*d=b', '*d=c', '*d=d', '*d=*b', '*d=*c', '*d=*d', '*d=', //
  '', '', '', '', '', '', '', '', //
  'a+=a', 'a+=b', 'a+=c', 'a+=d', 'a+=*b', 'a+=*c', 'a+=*d', 'a+=', //
  'a-=a', 'a-=b', 'a-=c', 'a-=d', 'a-=*b', 'a-=*c', 'a-=*d', 'a-=', //
  'a*=a', 'a*=b', 'a*=c', 'a*=d', 'a*=*b', 'a*=*c', 'a*=*d', 'a*=', //
  'a/=a', 'a/=b', 'a/=c', 'a/=d', 'a/=*b', 'a/=*c', 'a/=*d', 'a/=', //
  'a%=a', 'a%=b', 'a%=c', 'a%=d', 'a%=*b', 'a%=*c', 'a%=*d', 'a%=', //
  'a&=a', 'a&=b', 'a&=c', 'a&=d', 'a&=*b', 'a&=*c', 'a&=*d', 'a&=', //
  'a&~a', 'a&~b', 'a&~c', 'a&~d', 'a&~*b', 'a&~*c', 'a&~*d', 'a&~', //
  'a|=a', 'a|=b', 'a|=c', 'a|=d', 'a|=*b', 'a|=*c', 'a|=*d', 'a|=', //
  'a^=a', 'a^=b', 'a^=c', 'a^=d', 'a^=*b', 'a^=*c', 'a^=*d', 'a^=', //
  'a<<=a', 'a<<=b', 'a<<=c', 'a<<=d', 'a<<=*b', 'a<<=*c', 'a<<=*d', 'a<<=', //
  'a>>=a', 'a>>=b', 'a>>=c', 'a>>=d', 'a>>=*b', 'a>>=*c', 'a>>=*d', 'a>>=', //
  'a==a', 'a==b', 'a==c', 'a==d', 'a==*b', 'a==*c', 'a==*d', 'a==', //
  'a<a', 'a<b', 'a<c', 'a<d', 'a<*b', 'a<*c', 'a<*d', 'a<', //
  'a>a', 'a>b', 'a>c', 'a>d', 'a>*b', 'a>*c', 'a>*d', 'a>', //
  '', '', '', '', '', '', '', '', //
  '', '', '', '', '', '', '', 'lj', //
  'post', 'pcomp', 'end', 'if', 'ifnot', 'else', 'endif', 'do', //
  'while', 'until', 'forever', 'ifl', 'ifnotl', 'elsel', ';' //
];

const int _jt = 39, _jf = 47, _jmp = 63, _lj = 255;
const int _post = 256,
    _pcomp = 257,
    _end = 258,
    _if = 259,
    _ifnot = 260,
    _else = 261,
    _endif = 262,
    _do = 263,
    _while = 264,
    _until = 265,
    _forever = 266,
    _ifl = 267,
    _ifnotl = 268,
    _elsel = 269;

/// Compiles ZPAQL configuration source into COMP/HCOMP ([hz]) and PCOMP
/// ([pz]) byte code, replacing $1..$9 with [args].
class Compiler {
  final String _src;
  final List<int> _args;
  final Zpaql hz, pz;
  int _in = 0;
  int _line = 1;
  int _state = 0;
  final List<int> _ifStack = [];
  final List<int> _doStack = [];

  Compiler(this._src, this._args, this.hz, this.pz);

  int _ch(int i) => i < _src.length ? _src.codeUnitAt(i) : 0;

  Never _syntaxError(String msg, [String? expected]) {
    final sb = StringBuffer('Config line $_line at ');
    var i = _in;
    for (var k = 0; k < 20 && _ch(i) > 32; ++k, ++i) {
      sb.writeCharCode(_ch(i));
    }
    sb.write(': $msg');
    if (expected != null) sb.write(', expected: $expected');
    zpaqError(sb.toString());
  }

  void _next() {
    for (; _in < _src.length; ++_in) {
      final c = _src.codeUnitAt(_in);
      if (c == 10) ++_line;
      if (c == 40) {
        // '('
        _state += 1 + (_state < 0 ? 1 : 0);
      } else if (_state > 0 && c == 41) {
        --_state;
      } else if (_state < 0 && c <= 32) {
        _state = 0;
      } else if (_state == 0 && c > 32) {
        _state = -1;
        break;
      }
    }
    if (_in >= _src.length) zpaqError('unexpected end of config');
  }

  static int _lower(int c) => (c >= 65 && c <= 90) ? c + 32 : c;

  bool _matchToken(String word) {
    var a = _in;
    var w = 0;
    for (; _ch(a) > 32 && _ch(a) != 40 && w < word.length; ++a, ++w) {
      if (_lower(_ch(a)) != _lower(word.codeUnitAt(w))) return false;
    }
    return w == word.length && (_ch(a) <= 32 || _ch(a) == 40);
  }

  int _rtokenList(List<String> list) {
    _next();
    for (var i = 0; i < list.length; ++i) {
      if (list[i].isNotEmpty && _matchToken(list[i])) return i;
    }
    _syntaxError('unexpected');
  }

  void _rtokenStr(String s) {
    _next();
    if (!_matchToken(s)) _syntaxError('expected', s);
  }

  int _atoi(int i) {
    var neg = false;
    if (_ch(i) == 45) {
      neg = true;
      ++i;
    } else if (_ch(i) == 43) {
      ++i;
    }
    var r = 0;
    while (_ch(i) >= 48 && _ch(i) <= 57) {
      r = r * 10 + _ch(i) - 48;
      ++i;
    }
    return neg ? -r : r;
  }

  int _rtokenNum(int low, int high) {
    _next();
    var r = 0;
    final c0 = _ch(_in), c1 = _ch(_in + 1);
    if (c0 == 36 && c1 >= 49 && c1 <= 57) {
      if (_ch(_in + 2) == 43) r = _atoi(_in + 3);
      r += _args[c1 - 49];
    } else if (c0 == 45 || (c0 >= 48 && c0 <= 57)) {
      r = _atoi(_in);
    } else {
      _syntaxError('expected a number');
    }
    if (r < low) _syntaxError('number too low');
    if (r > high) _syntaxError('number too high');
    return r;
  }

  int _compileComp(Zpaql z) {
    var op = 0;
    final compBegin = z.hend;
    final hd = z.header;
    while (true) {
      op = _rtokenList(_opcodelist);
      if (op == _post || op == _pcomp || op == _end) break;
      var operand = -1;
      var operand2 = -1;
      if (op == _if) {
        op = _jf;
        operand = 0;
        _ifStack.add(z.hend + 1);
      } else if (op == _ifnot) {
        op = _jt;
        operand = 0;
        _ifStack.add(z.hend + 1);
      } else if (op == _ifl || op == _ifnotl) {
        if (op == _ifl) hd[z.hend++] = _jt;
        if (op == _ifnotl) hd[z.hend++] = _jf;
        hd[z.hend++] = 3;
        op = _lj;
        operand = operand2 = 0;
        _ifStack.add(z.hend + 1);
      } else if (op == _else || op == _elsel) {
        if (op == _else) {
          op = _jmp;
          operand = 0;
        }
        if (op == _elsel) {
          op = _lj;
          operand = operand2 = 0;
        }
        if (_ifStack.isEmpty) _syntaxError('unmatched IF or DO');
        final a = _ifStack.removeLast();
        if (hd[a - 1] != _lj) {
          final j = (z.hend - a) + 1 + (op == _lj ? 1 : 0);
          if (j > 127) _syntaxError('IF too big, try IFL, IFNOTL');
          hd[a] = j;
        } else {
          final j = z.hend - compBegin + 2 + (op == _lj ? 1 : 0);
          hd[a] = j & 255;
          hd[a + 1] = (j >> 8) & 255;
        }
        _ifStack.add(z.hend + 1);
      } else if (op == _endif) {
        if (_ifStack.isEmpty) _syntaxError('unmatched IF or DO');
        final a = _ifStack.removeLast();
        var j = z.hend - a - 1;
        if (hd[a - 1] != _lj) {
          if (j > 127) _syntaxError('IF too big, try IFL, IFNOTL, ELSEL');
          hd[a] = j;
        } else {
          j = z.hend - compBegin;
          hd[a] = j & 255;
          hd[a + 1] = (j >> 8) & 255;
        }
      } else if (op == _do) {
        _doStack.add(z.hend);
      } else if (op == _while || op == _until || op == _forever) {
        if (_doStack.isEmpty) _syntaxError('unmatched IF or DO');
        final a = _doStack.removeLast();
        var j = a - z.hend - 2;
        if (j >= -127) {
          if (op == _while) op = _jt;
          if (op == _until) op = _jf;
          if (op == _forever) op = _jmp;
          operand = j & 255;
        } else {
          j = a - compBegin;
          if (op == _while) {
            hd[z.hend++] = _jf;
            hd[z.hend++] = 3;
          }
          if (op == _until) {
            hd[z.hend++] = _jt;
            hd[z.hend++] = 3;
          }
          op = _lj;
          operand = j & 255;
          operand2 = j >> 8;
        }
      } else if ((op & 7) == 7) {
        if (op == _lj) {
          operand = _rtokenNum(0, 65535);
          operand2 = operand >> 8;
          operand &= 255;
        } else if (op == _jt || op == _jf || op == _jmp) {
          operand = _rtokenNum(-128, 127);
          operand &= 255;
        } else {
          operand = _rtokenNum(0, 255);
        }
      }
      if (op >= 0 && op <= 255) hd[z.hend++] = op;
      if (operand >= 0) hd[z.hend++] = operand;
      if (operand2 >= 0) hd[z.hend++] = operand2;
      if (z.hend >= hd.length - 130 || z.hend - z.hbegin + z.cend - 2 > 65535) {
        _syntaxError('program too big');
      }
    }
    hd[z.hend++] = 0;
    return op;
  }

  /// Compiles the config. Returns the PCOMP command (text before ';').
  String compile() {
    hz.clear();
    pz.clear();
    hz.header = Uint8List(68000);
    _rtokenStr('comp');
    hz.header[2] = _rtokenNum(0, 255);
    hz.header[3] = _rtokenNum(0, 255);
    hz.header[4] = _rtokenNum(0, 255);
    hz.header[5] = _rtokenNum(0, 255);
    final n = hz.header[6] = _rtokenNum(0, 255);
    hz.cend = 7;
    for (var i = 0; i < n; ++i) {
      _rtokenNum(i, i);
      final type = _rtokenList(_compname);
      hz.header[hz.cend++] = type;
      final clen = compsize[type & 255];
      if (clen < 1 || clen > 10) _syntaxError('invalid component');
      for (var j = 1; j < clen; ++j) {
        hz.header[hz.cend++] = _rtokenNum(0, 255);
      }
    }
    hz.cend++; // END
    hz.hbegin = hz.hend = hz.cend + 128;
    _rtokenStr('hcomp');
    var op = _compileComp(hz);
    final hsize = (hz.cend - 2) + hz.hend - hz.hbegin;
    hz.header[0] = hsize & 255;
    hz.header[1] = hsize >> 8;
    var cmd = '';
    if (op == _post) {
      _rtokenNum(0, 0);
      _rtokenStr('end');
    } else if (op == _pcomp) {
      pz.header = Uint8List(68000);
      pz.header[4] = hz.header[4];
      pz.header[5] = hz.header[5];
      pz.cend = 8;
      pz.hbegin = pz.hend = pz.cend + 128;
      _next();
      final sb = StringBuffer();
      while (_in < _src.length && _src.codeUnitAt(_in) != 59) {
        sb.writeCharCode(_src.codeUnitAt(_in));
        ++_in;
      }
      if (_in < _src.length) ++_in;
      cmd = sb.toString();
      op = _compileComp(pz);
      final len = (pz.cend - 2) + pz.hend - pz.hbegin;
      pz.header[0] = len & 255;
      pz.header[1] = len >> 8;
      if (op != _end) _syntaxError('expected END');
    } else if (op != _end) {
      _syntaxError('expected END or POST 0 END or PCOMP cmd ; ... END');
    }
    return cmd;
  }
}
