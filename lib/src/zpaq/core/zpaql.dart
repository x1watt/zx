// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

import 'io.dart';
import 'sha1.dart';

part 'hcomp.g.dart';

/// Component types.
const int compNone = 0,
    compCons = 1,
    compCm = 2,
    compIcm = 3,
    compMatch = 4,
    compAvg = 5,
    compMix2 = 6,
    compMix = 7,
    compIsse = 8,
    compSse = 9;

/// Number of bytes used to encode each component type.
final Int32List compsize = () {
  final t = Int32List(256);
  const s = [0, 2, 3, 2, 3, 4, 6, 6, 3, 5];
  for (var i = 0; i < s.length; ++i) {
    t[i] = s[i];
  }
  return t;
}();

const int _m32 = 0xFFFFFFFF;

/// A ZPAQL virtual machine holding either COMP+HCOMP or PCOMP.
///
/// Header layout (as libzpaq): hsize[2] hh hm ph pm n COMP... 0 (guard
/// gap of 128) HCOMP... 0.
class Zpaql {
  /// Destination for OUT, or null to discard.
  ZWriter? output;

  /// Checksum of everything output, or null.
  Sha1? sha1;

  Uint8List header = Uint8List(0);
  int cend = 0; // COMP in header[7..cend-1]
  int hbegin = 0, hend = 0; // HCOMP/PCOMP in header[hbegin..hend-1]

  Uint8List _m = Uint8List(0);
  Uint32List _h = Uint32List(0);
  Uint32List _r = Uint32List(0);
  int _mmask = 0, _hmask = 0;
  final Uint8List _outbuf = Uint8List(1 << 14);
  int _bufptr = 0;
  int _a = 0, _b = 0, _c = 0, _d = 0, _f = 0;

  Zpaql() {
    clear();
  }

  /// Element i of H (used by the predictor to read contexts).
  int hAt(int i) => _h[i & _hmask];
  Uint32List get hArray => _h;
  int get hMask => _hmask;

  void clear() {
    cend = hbegin = hend = 0;
    _a = _b = _c = _d = _f = 0;
    header = Uint8List(0);
    _h = Uint32List(0);
    _m = Uint8List(0);
    _r = Uint32List(0);
  }

  /// Reads a COMP+HCOMP header from [in2]. Returns the number of bytes read.
  int read(ZReader in2) {
    var hsize = in2.get();
    hsize += in2.get() * 256;
    if (hsize < 0) zpaqError('unexpected end of file');
    header = Uint8List(hsize + 300);
    cend = hbegin = hend = 0;
    header[cend++] = hsize & 255;
    header[cend++] = hsize >> 8;
    while (cend < 7) {
      header[cend++] = in2.get();
    }
    final n = header[cend - 1];
    for (var i = 0; i < n; ++i) {
      final type = in2.get();
      if (type < 0 || type > 255) zpaqError('unexpected end of file');
      header[cend++] = type;
      final size = compsize[type];
      if (size < 1) zpaqError('Invalid component type');
      if (cend + size > hsize) zpaqError('COMP overflows header');
      for (var j = 1; j < size; ++j) {
        header[cend++] = in2.get();
      }
    }
    if ((header[cend++] = in2.get()) != 0) zpaqError('missing COMP END');
    hbegin = hend = cend + 128;
    if (hend > hsize + 129) zpaqError('missing HCOMP');
    while (hend < hsize + 129) {
      final op = in2.get();
      if (op == -1) zpaqError('unexpected end of file');
      header[hend++] = op;
    }
    if ((header[hend++] = in2.get()) != 0) zpaqError('missing HCOMP END');
    return cend + hend - hbegin;
  }

  /// Writes the header. If [pp] then writes only the PCOMP size and code.
  bool write(ZWriter out2, bool pp) {
    if (header.length <= 6) return false;
    if (!pp) {
      for (var i = 0; i < cend; ++i) {
        out2.put(header[i]);
      }
    } else {
      out2.put((hend - hbegin) & 255);
      out2.put((hend - hbegin) >> 8);
    }
    for (var i = hbegin; i < hend; ++i) {
      out2.put(header[i]);
    }
    return true;
  }

  void inith() {
    _init(header[2], header[3]);
    _native = nativeEnabled ? _nativeHcomp(header, hbegin, hend) : null;
  }

  void initp() {
    _init(header[4], header[5]);
    _native = null;
  }

  /// Use Dart translations of makeConfig's context programs (see
  /// tool/gen_hcomp.dart); false forces the interpreter, for tests.
  static bool nativeEnabled = true;

  void Function(Zpaql, int)? _native;

  /// Approximate memory requirement in bytes.
  double memory() {
    double pow2(int x) => x <= 0 ? 1.0 : 1.0 * (1 << (x > 62 ? 62 : x));
    var mem = pow2(header[2] + 2) +
        pow2(header[3]) +
        pow2(header[4] + 2) +
        pow2(header[5]) +
        header.length;
    var cp = 7;
    for (var i = 0; i < header[6]; ++i) {
      final size = pow2(header[cp + 1]);
      switch (header[cp]) {
        case compCm:
          mem += 4 * size;
        case compIcm:
          mem += 64 * size + 1024;
        case compMatch:
          mem += 4 * size + pow2(header[cp + 2]);
        case compMix2:
          mem += 2 * size;
        case compMix:
          mem += 4 * size * header[cp + 3];
        case compIsse:
          mem += 64 * size + 2048;
        case compSse:
          mem += 128 * size;
      }
      cp += compsize[header[cp]];
    }
    return mem;
  }

  void _init(int hbits, int mbits) {
    if (hbits > 32) zpaqError('H too big');
    if (mbits > 32) zpaqError('M too big');
    if (hbits > 30 || mbits > 32) {
      zpaqError('ZPAQL memory requirement too large for this platform');
    }
    _h = Uint32List(1 << hbits);
    _hmask = (1 << hbits) - 1;
    _m = Uint8List(1 << mbits);
    _mmask = (1 << mbits) - 1;
    _r = Uint32List(256);
    _a = _b = _c = _d = _f = 0;
    _bufptr = 0;
  }

  /// Writes pending output to [output] and [sha1].
  void flush() {
    if (_bufptr == 0) return;
    output?.write(_outbuf, 0, _bufptr);
    sha1?.add(_outbuf, 0, _bufptr);
    _bufptr = 0;
  }

  void _outc(int ch) {
    _outbuf[_bufptr] = ch;
    if (++_bufptr == _outbuf.length) flush();
  }

  Never _err() => zpaqError('ZPAQL execution error');

  /// Runs the program with [input] in A (0..255, or 0xFFFFFFFF for EOS).
  @pragma('vm:unsafe:no-bounds-checks')
  void run(int input) {
    final nat = _native;
    if (nat != null) {
      nat(this, input);
      return;
    }
    final header = this.header;
    final m = _m, h = _h, r = _r;
    final mm = _mmask, hm = _hmask;
    final hbegin = this.hbegin, hend = this.hend;
    var a = input & _m32, b = _b, c = _c, d = _d, f = _f;
    var pc = hbegin;
    int x;
    while (true) {
      switch (header[pc++]) {
        case 0:
          _err();
        case 1:
          a = (a + 1) & _m32;
        case 2:
          a = (a - 1) & _m32;
        case 3:
          a ^= _m32;
        case 4:
          a = 0;
        case 7:
          a = r[header[pc++]];
        case 8:
          x = b;
          b = a;
          a = x;
        case 9:
          b = (b + 1) & _m32;
        case 10:
          b = (b - 1) & _m32;
        case 11:
          b ^= _m32;
        case 12:
          b = 0;
        case 15:
          b = r[header[pc++]];
        case 16:
          x = c;
          c = a;
          a = x;
        case 17:
          c = (c + 1) & _m32;
        case 18:
          c = (c - 1) & _m32;
        case 19:
          c ^= _m32;
        case 20:
          c = 0;
        case 23:
          c = r[header[pc++]];
        case 24:
          x = d;
          d = a;
          a = x;
        case 25:
          d = (d + 1) & _m32;
        case 26:
          d = (d - 1) & _m32;
        case 27:
          d ^= _m32;
        case 28:
          d = 0;
        case 31:
          d = r[header[pc++]];
        case 32:
          x = m[b & mm];
          m[b & mm] = a;
          a = (a & 0xFFFFFF00) | x;
        case 33:
          m[b & mm]++;
        case 34:
          m[b & mm]--;
        case 35:
          m[b & mm] = ~m[b & mm];
        case 36:
          m[b & mm] = 0;
        case 39:
          if (f != 0) {
            pc += ((header[pc] + 128) & 255) - 127;
          } else {
            ++pc;
          }
        case 40:
          x = m[c & mm];
          m[c & mm] = a;
          a = (a & 0xFFFFFF00) | x;
        case 41:
          m[c & mm]++;
        case 42:
          m[c & mm]--;
        case 43:
          m[c & mm] = ~m[c & mm];
        case 44:
          m[c & mm] = 0;
        case 47:
          if (f == 0) {
            pc += ((header[pc] + 128) & 255) - 127;
          } else {
            ++pc;
          }
        case 48:
          x = h[d & hm];
          h[d & hm] = a;
          a = x;
        case 49:
          h[d & hm]++;
        case 50:
          h[d & hm]--;
        case 51:
          h[d & hm] = ~h[d & hm];
        case 52:
          h[d & hm] = 0;
        case 55:
          r[header[pc++]] = a;
        case 56:
          _b = b;
          _c = c;
          _d = d;
          _f = f;
          _a = a;
          return;
        case 57:
          _outbuf[_bufptr] = a;
          if (++_bufptr == _outbuf.length) flush();
        case 59:
          a = ((a + m[b & mm] + 512) * 773) & _m32;
        case 60:
          h[d & hm] = (h[d & hm] + a + 512) * 773;
        case 63:
          pc += ((header[pc] + 128) & 255) - 127;
        case 64:
          break;
        case 65:
          a = b;
        case 66:
          a = c;
        case 67:
          a = d;
        case 68:
          a = m[b & mm];
        case 69:
          a = m[c & mm];
        case 70:
          a = h[d & hm];
        case 71:
          a = header[pc++];
        case 72:
          b = a;
        case 73:
          break;
        case 74:
          b = c;
        case 75:
          b = d;
        case 76:
          b = m[b & mm];
        case 77:
          b = m[c & mm];
        case 78:
          b = h[d & hm];
        case 79:
          b = header[pc++];
        case 80:
          c = a;
        case 81:
          c = b;
        case 82:
          break;
        case 83:
          c = d;
        case 84:
          c = m[b & mm];
        case 85:
          c = m[c & mm];
        case 86:
          c = h[d & hm];
        case 87:
          c = header[pc++];
        case 88:
          d = a;
        case 89:
          d = b;
        case 90:
          d = c;
        case 91:
          break;
        case 92:
          d = m[b & mm];
        case 93:
          d = m[c & mm];
        case 94:
          d = h[d & hm];
        case 95:
          d = header[pc++];
        case 96:
          m[b & mm] = a;
        case 97:
          m[b & mm] = b;
        case 98:
          m[b & mm] = c;
        case 99:
          m[b & mm] = d;
        case 100:
          break;
        case 101:
          m[b & mm] = m[c & mm];
        case 102:
          m[b & mm] = h[d & hm];
        case 103:
          m[b & mm] = header[pc++];
        case 104:
          m[c & mm] = a;
        case 105:
          m[c & mm] = b;
        case 106:
          m[c & mm] = c;
        case 107:
          m[c & mm] = d;
        case 108:
          m[c & mm] = m[b & mm];
        case 109:
          break;
        case 110:
          m[c & mm] = h[d & hm];
        case 111:
          m[c & mm] = header[pc++];
        case 112:
          h[d & hm] = a;
        case 113:
          h[d & hm] = b;
        case 114:
          h[d & hm] = c;
        case 115:
          h[d & hm] = d;
        case 116:
          h[d & hm] = m[b & mm];
        case 117:
          h[d & hm] = m[c & mm];
        case 118:
          break;
        case 119:
          h[d & hm] = header[pc++];
        case 128:
          a = (a + a) & _m32;
        case 129:
          a = (a + b) & _m32;
        case 130:
          a = (a + c) & _m32;
        case 131:
          a = (a + d) & _m32;
        case 132:
          a = (a + m[b & mm]) & _m32;
        case 133:
          a = (a + m[c & mm]) & _m32;
        case 134:
          a = (a + h[d & hm]) & _m32;
        case 135:
          a = (a + header[pc++]) & _m32;
        case 136:
          a = 0;
        case 137:
          a = (a - b) & _m32;
        case 138:
          a = (a - c) & _m32;
        case 139:
          a = (a - d) & _m32;
        case 140:
          a = (a - m[b & mm]) & _m32;
        case 141:
          a = (a - m[c & mm]) & _m32;
        case 142:
          a = (a - h[d & hm]) & _m32;
        case 143:
          a = (a - header[pc++]) & _m32;
        case 144:
          a = (a * a) & _m32;
        case 145:
          a = (a * b) & _m32;
        case 146:
          a = (a * c) & _m32;
        case 147:
          a = (a * d) & _m32;
        case 148:
          a = (a * m[b & mm]) & _m32;
        case 149:
          a = (a * m[c & mm]) & _m32;
        case 150:
          a = (a * h[d & hm]) & _m32;
        case 151:
          a = (a * header[pc++]) & _m32;
        case 152:
          a = a != 0 ? 1 : 0;
        case 153:
          a = b != 0 ? a ~/ b : 0;
        case 154:
          a = c != 0 ? a ~/ c : 0;
        case 155:
          a = d != 0 ? a ~/ d : 0;
        case 156:
          x = m[b & mm];
          a = x != 0 ? a ~/ x : 0;
        case 157:
          x = m[c & mm];
          a = x != 0 ? a ~/ x : 0;
        case 158:
          x = h[d & hm];
          a = x != 0 ? a ~/ x : 0;
        case 159:
          x = header[pc++];
          a = x != 0 ? a ~/ x : 0;
        case 160:
          a = 0;
        case 161:
          a = b != 0 ? a % b : 0;
        case 162:
          a = c != 0 ? a % c : 0;
        case 163:
          a = d != 0 ? a % d : 0;
        case 164:
          x = m[b & mm];
          a = x != 0 ? a % x : 0;
        case 165:
          x = m[c & mm];
          a = x != 0 ? a % x : 0;
        case 166:
          x = h[d & hm];
          a = x != 0 ? a % x : 0;
        case 167:
          x = header[pc++];
          a = x != 0 ? a % x : 0;
        case 168:
          break;
        case 169:
          a &= b;
        case 170:
          a &= c;
        case 171:
          a &= d;
        case 172:
          a &= m[b & mm];
        case 173:
          a &= m[c & mm];
        case 174:
          a &= h[d & hm];
        case 175:
          a &= header[pc++];
        case 176:
          a = 0;
        case 177:
          a &= ~b;
        case 178:
          a &= ~c;
        case 179:
          a &= ~d;
        case 180:
          a &= ~m[b & mm];
        case 181:
          a &= ~m[c & mm];
        case 182:
          a &= ~h[d & hm];
        case 183:
          a &= ~header[pc++];
        case 184:
          break;
        case 185:
          a |= b;
        case 186:
          a |= c;
        case 187:
          a |= d;
        case 188:
          a |= m[b & mm];
        case 189:
          a |= m[c & mm];
        case 190:
          a |= h[d & hm];
        case 191:
          a |= header[pc++];
        case 192:
          a = 0;
        case 193:
          a ^= b;
        case 194:
          a ^= c;
        case 195:
          a ^= d;
        case 196:
          a ^= m[b & mm];
        case 197:
          a ^= m[c & mm];
        case 198:
          a ^= h[d & hm];
        case 199:
          a ^= header[pc++];
        case 200:
          a = (a << (a & 31)) & _m32;
        case 201:
          a = (a << (b & 31)) & _m32;
        case 202:
          a = (a << (c & 31)) & _m32;
        case 203:
          a = (a << (d & 31)) & _m32;
        case 204:
          a = (a << (m[b & mm] & 31)) & _m32;
        case 205:
          a = (a << (m[c & mm] & 31)) & _m32;
        case 206:
          a = (a << (h[d & hm] & 31)) & _m32;
        case 207:
          a = (a << (header[pc++] & 31)) & _m32;
        case 208:
          a >>= (a & 31);
        case 209:
          a >>= (b & 31);
        case 210:
          a >>= (c & 31);
        case 211:
          a >>= (d & 31);
        case 212:
          a >>= (m[b & mm] & 31);
        case 213:
          a >>= (m[c & mm] & 31);
        case 214:
          a >>= (h[d & hm] & 31);
        case 215:
          a >>= (header[pc++] & 31);
        case 216:
          f = 1;
        case 217:
          f = a == b ? 1 : 0;
        case 218:
          f = a == c ? 1 : 0;
        case 219:
          f = a == d ? 1 : 0;
        case 220:
          f = a == m[b & mm] ? 1 : 0;
        case 221:
          f = a == m[c & mm] ? 1 : 0;
        case 222:
          f = a == h[d & hm] ? 1 : 0;
        case 223:
          f = a == header[pc++] ? 1 : 0;
        case 224:
          f = 0;
        case 225:
          f = a < b ? 1 : 0;
        case 226:
          f = a < c ? 1 : 0;
        case 227:
          f = a < d ? 1 : 0;
        case 228:
          f = a < m[b & mm] ? 1 : 0;
        case 229:
          f = a < m[c & mm] ? 1 : 0;
        case 230:
          f = a < h[d & hm] ? 1 : 0;
        case 231:
          f = a < header[pc++] ? 1 : 0;
        case 232:
          f = 0;
        case 233:
          f = a > b ? 1 : 0;
        case 234:
          f = a > c ? 1 : 0;
        case 235:
          f = a > d ? 1 : 0;
        case 236:
          f = a > m[b & mm] ? 1 : 0;
        case 237:
          f = a > m[c & mm] ? 1 : 0;
        case 238:
          f = a > h[d & hm] ? 1 : 0;
        case 239:
          f = a > header[pc++] ? 1 : 0;
        case 255:
          pc = hbegin + header[pc] + 256 * header[pc + 1];
          if (pc >= hend) _err();
        default:
          _err();
      }
    }
  }

  /// Outputs a byte directly (used by the PASS postprocessor).
  void outc(int ch) => _outc(ch);

  int get a => _a;
}
