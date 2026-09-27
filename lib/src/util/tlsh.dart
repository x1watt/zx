// TLSH, the Trend Micro Locality Sensitive Hash (Oliver, Cheng and Chen,
// "TLSH: A Locality Sensitive Hash", 4th Cybercrime and Trustworthy
// Computing Workshop, 2013), in its standard variant: 128 buckets, a one
// byte checksum, a sliding window of 5 bytes, and the "T1" text form of
// 72 characters. Similar inputs get digests at a small distance
// ([tlshDistance]).
//
// Written from the paper and from the behavior of the reference
// implementation (github.com/trendmicro/tlsh, TLSH 4.x, dual Apache 2.0 /
// BSD 3-clause licensed, used here under the BSD license, see LICENSE):
// the Pearson table, the six bucket triplets and their salts, the
// quartile encoding, the length capture table and the distance function
// are its constants, so that the digests are the ones of its `tlsh` tool
// (test/zx_tlsh_test.dart compares them).

import 'dart:typed_data';

/// Pearson's sample random table (v_table of the reference).
final Uint8List _vTable = Uint8List.fromList(const [
  1, 87, 49, 12, 176, 178, 102, 166, 121, 193, 6, 84, 249, 230, 44, 163, //
  14, 197, 213, 181, 161, 85, 218, 80, 64, 239, 24, 226, 236, 142, 38, 200,
  110, 177, 104, 103, 141, 253, 255, 50, 77, 101, 81, 18, 45, 96, 31, 222,
  25, 107, 190, 70, 86, 237, 240, 34, 72, 242, 20, 214, 244, 227, 149, 235,
  97, 234, 57, 22, 60, 250, 82, 175, 208, 5, 127, 199, 111, 62, 135, 248,
  174, 169, 211, 58, 66, 154, 106, 195, 245, 171, 17, 187, 182, 179, 0, 243,
  132, 56, 148, 75, 128, 133, 158, 100, 130, 126, 91, 13, 153, 246, 216, 219,
  119, 68, 223, 78, 83, 88, 201, 99, 122, 11, 92, 32, 136, 114, 52, 10,
  138, 30, 48, 183, 156, 35, 61, 26, 143, 74, 251, 94, 129, 162, 63, 152,
  170, 7, 115, 167, 241, 206, 3, 150, 55, 59, 151, 220, 90, 53, 23, 131,
  125, 173, 15, 238, 79, 95, 89, 16, 105, 137, 225, 224, 217, 160, 37, 123,
  118, 73, 2, 157, 46, 116, 9, 145, 134, 228, 207, 212, 202, 215, 69, 229,
  27, 188, 67, 124, 168, 252, 42, 4, 29, 108, 21, 247, 19, 205, 39, 203,
  233, 40, 186, 147, 198, 192, 155, 33, 164, 191, 98, 204, 165, 180, 117, 76,
  140, 36, 210, 172, 41, 54, 159, 8, 185, 232, 113, 196, 231, 47, 146, 120,
  51, 65, 28, 144, 254, 221, 93, 189, 194, 139, 112, 43, 71, 109, 184, 209,
]);

/// The upper bound of each length class (topval of l_capturing).
const List<int> _topVal = [
  1, 2, 3, 5, 7, 11, 17, 25, 38, 57, 86, 129, 194, 291, 437, 656, 854, //
  1110, 1443, 1876, 2439, 3171, 3475, 3823, 4205, 4626, 5088, 5597, 6157,
  6772, 7450, 8195, 9014, 9916, 10907, 11998, 13198, 14518, 15970, 17567,
  19323, 21256, 23382, 25720, 28292, 31121, 34233, 37656, 41422, 45564,
  50121, 55133, 60646, 66711, 73382, 80721, 88793, 97672, 107439, 118183,
  130002, 143002, 157302, 173032, 190335, 209369, 230306, 253337, 278670,
  306538, 337191, 370911, 408002, 448802, 493682, 543050, 597356, 657091,
  722800, 795081, 874589, 962048, 1058252, 1164078, 1280486, 1408534,
  1549388, 1704327, 1874759, 2062236, 2268459, 2495305, 2744836, 3019320,
  3321252, 3653374, 4018711, 4420582, 4862641, 5348905, 5883796, 6472176,
  7119394, 7831333, 8614467, 9475909, 10423501, 11465851, 12612437,
  13873681, 15261050, 16787154, 18465870, 20312458, 22343706, 24578077,
  27035886, 29739474, 32713425, 35984770, 39583245, 43541573, 47895730,
  52685306, 57953837, 63749221, 70124148, 77136564, 84850228, 93335252,
  102668779, 112935659, 124229227, 136652151, 150317384, 165349128,
  181884040, 200072456, 220079703, 242087671, 266296456, 292926096,
  322218735, 354440623, 389884688, 428873168, 471760495, 518936559,
  570830240, 627913311, 690704607, 759775136, 835752671, 919327967,
  1011260767, 1112386880, 1223623232, 1345985727, 1480584256, 1628642751,
  1791507135, 1970657856, 2167723648, 2384496256, 2622945920, 2885240448,
  3173764736, 3491141248, 3840255616, 4224281216,
];

/// The smallest input that gets a digest (MIN_DATA_LENGTH).
const int tlshMinLength = 50;

const int _buckets = 128;
const int _codeSize = 32;

// l_capturing: the length class of [len] (the length modulo 2^32, as the
// reference keeps it in an unsigned int).
int _lCapturing(int len) {
  if (len <= _topVal[0]) return 0;
  var lo = 1, hi = _topVal.length - 1;
  if (len > _topVal[hi]) return _topVal.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (len <= _topVal[mid]) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return lo;
}

/// A running TLSH computation: [update] with the data in any number of
/// pieces, then [digest].
class Tlsh {
  // 256 counters as in the reference; the digest uses the first 128
  final Uint32List _bucket = Uint32List(256);
  int _w1 = 0, _w2 = 0, _w3 = 0, _w4 = 0;
  int _checksum = 0;
  int _length = 0;

  /// Bytes seen so far.
  int get length => _length;

  // TlshImpl::update (fast_update5 for a window of 5 and a one byte
  // checksum): each byte after the fourth adds six Pearson hashes of
  // triplets of the window to the buckets.
  void update(Uint8List data, [int off = 0, int? end]) {
    final e = end ?? data.length;
    final v = _vTable;
    final bucket = _bucket;
    var w1 = _w1, w2 = _w2, w3 = _w3, w4 = _w4;
    var ck = _checksum;
    var fed = _length;
    for (var i = off; i < e; i++) {
      final w0 = data[i];
      if (fed >= 4) {
        ck = v[v[v[1 ^ w0] ^ w1] ^ ck];
        bucket[v[v[v[49 ^ w0] ^ w1] ^ w2]]++;
        bucket[v[v[v[12 ^ w0] ^ w1] ^ w3]]++;
        bucket[v[v[v[178 ^ w0] ^ w2] ^ w3]]++;
        bucket[v[v[v[166 ^ w0] ^ w2] ^ w4]]++;
        bucket[v[v[v[84 ^ w0] ^ w1] ^ w4]]++;
        bucket[v[v[v[230 ^ w0] ^ w3] ^ w4]]++;
      }
      fed++;
      w4 = w3;
      w3 = w2;
      w2 = w1;
      w1 = w0;
    }
    _w1 = w1;
    _w2 = w2;
    _w3 = w3;
    _w4 = w4;
    _checksum = ck;
    _length = fed;
  }

  // TlshImpl::final and TlshImpl::hash(showvers = 1): the "T1" digest,
  // or null when the input is shorter than [tlshMinLength] bytes or has
  // too little variation (half of the buckets or more empty).
  String? digest() {
    final len = _length & 0xFFFFFFFF;
    if (len < tlshMinLength) return null;
    final sorted = Uint32List(_buckets)..setRange(0, _buckets, _bucket);
    sorted.sort();
    final q1 = sorted[_buckets ~/ 4 - 1];
    final q2 = sorted[_buckets ~/ 2 - 1];
    final q3 = sorted[_buckets - _buckets ~/ 4 - 1];
    if (q3 == 0) return null;
    var nonzero = 0;
    for (var i = 0; i < _buckets; i++) {
      if (_bucket[i] > 0) nonzero++;
    }
    if (nonzero <= _buckets ~/ 2) return null;
    final code = Uint8List(_codeSize);
    for (var i = 0; i < _codeSize; i++) {
      var h = 0;
      for (var j = 0; j < 4; j++) {
        final k = _bucket[4 * i + j];
        if (q3 < k) {
          h += 3 << (j * 2);
        } else if (q2 < k) {
          h += 2 << (j * 2);
        } else if (q1 < k) {
          h += 1 << (j * 2);
        }
      }
      code[i] = h;
    }
    final lValue = _lCapturing(len) & 0xFF;
    final q1r = (q1 * 100 ~/ q3) % 16;
    final q2r = (q2 * 100 ~/ q3) % 16;
    final sb = StringBuffer('T1');
    sb.write(_hex(_swap(_checksum)));
    sb.write(_hex(_swap(lValue)));
    sb.write(_hex(_swap(q1r | (q2r << 4))));
    for (var i = _codeSize - 1; i >= 0; i--) {
      sb.write(_hex(code[i]));
    }
    return sb.toString();
  }

  /// The digest of [data].
  static String? of(Uint8List data, [int off = 0, int? end]) =>
      (Tlsh()..update(data, off, end)).digest();
}

int _swap(int b) => ((b >> 4) & 0x0F) | ((b << 4) & 0xF0);

const String _hexDigits = '0123456789ABCDEF';

String _hex(int b) => '${_hexDigits[b >> 4]}${_hexDigits[b & 15]}';

/// The fields of a digest (lsh_bin_struct), parsed from its text form.
class TlshDigest {
  final int checksum;
  final int lValue;
  final int q1Ratio;
  final int q2Ratio;

  /// The 32 code bytes in the order of the reference's tmp_code.
  final Uint8List code;
  TlshDigest._(
      this.checksum, this.lValue, this.q1Ratio, this.q2Ratio, this.code);

  /// Parses "T1" followed by 70 hex digits (or the 70 digits alone, the
  /// old form); null when [s] is not a digest of this variant.
  static TlshDigest? parse(String s) {
    var start = 0;
    if (s.startsWith('T1')) start = 2;
    if (s.length != start + 70) return null;
    final b = Uint8List(35);
    for (var i = 0; i < 35; i++) {
      final hi = _hexValue(s.codeUnitAt(start + 2 * i));
      final lo = _hexValue(s.codeUnitAt(start + 2 * i + 1));
      if (hi < 0 || lo < 0) return null;
      b[i] = (hi << 4) | lo;
    }
    final q = _swap(b[2]);
    final code = Uint8List(_codeSize);
    for (var i = 0; i < _codeSize; i++) {
      code[i] = b[3 + _codeSize - 1 - i];
    }
    return TlshDigest._(_swap(b[0]), _swap(b[1]), q & 15, q >> 4, code);
  }
}

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

// mod_diff
int _modDiff(int x, int y, int r) {
  int dl, dr;
  if (y > x) {
    dl = y - x;
    dr = x + r - y;
  } else {
    dl = x - y;
    dr = y + r - x;
  }
  return dl > dr ? dr : dl;
}

// the distance of two bit pairs (bit_pairs_diff_table)
int _pairDiff(int a, int b) {
  final d = (a - b).abs();
  return d == 3 ? 6 : d;
}

/// The TLSH distance of two digests (lsh_bin_totalDiff): 0 for identical
/// inputs, growing with the difference; under about 100 the inputs are
/// usually related. [lengthDiff] includes the length difference, as the
/// reference does by default. Null when a digest does not parse.
int? tlshDistance(String a, String b, {bool lengthDiff = true}) {
  final x = TlshDigest.parse(a), y = TlshDigest.parse(b);
  if (x == null || y == null) return null;
  var diff = 0;
  if (lengthDiff) {
    final ld = _modDiff(x.lValue, y.lValue, 256);
    diff = ld <= 1 ? ld : ld * 12;
  }
  final q1 = _modDiff(x.q1Ratio, y.q1Ratio, 16);
  diff += q1 <= 1 ? q1 : (q1 - 1) * 12;
  final q2 = _modDiff(x.q2Ratio, y.q2Ratio, 16);
  diff += q2 <= 1 ? q2 : (q2 - 1) * 12;
  if (x.checksum != y.checksum) diff++;
  for (var i = 0; i < _codeSize; i++) {
    var u = x.code[i], v = y.code[i];
    for (var k = 0; k < 4; k++) {
      diff += _pairDiff(u & 3, v & 3);
      u >>= 2;
      v >>= 2;
    }
  }
  return diff;
}
