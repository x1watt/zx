// BLAKE2s and BLAKE2sp (the file hash of RAR5 archives): port of the BLAKE2
// reference implementation as libarchive ships it (archive_blake2s_ref.c,
// archive_blake2sp_ref.c, archive_blake2_impl.h; Samuel Neves, CC0 1.0 /
// OpenSSL / Apache 2.0 at the user's option, see LICENSE), without keys.

import 'dart:typed_data';

const int blake2sBlockBytes = 64;
const int blake2sOutBytes = 32;
const int _parallelismDegree = 8;

const List<int> _iv = [
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, //
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];

const List<int> _sigma = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
  14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3,
  11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4,
  7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8,
  9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13,
  2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9,
  12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11,
  13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10,
  6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5,
  10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0,
];

final Uint8List _sigmaBytes = Uint8List.fromList(_sigma);

/// blake2s_state.
final class Blake2s {
  final Uint32List h = Uint32List(8);
  int t0 = 0;
  int t1 = 0;
  int f0 = 0;
  int f1 = 0;
  final Uint8List buf = Uint8List(blake2sBlockBytes);
  int bufLen = 0;
  int outLen = 0;
  bool lastNode = false;

  final Uint32List _m = Uint32List(16);
  final Uint32List _v = Uint32List(16);

  // blake2s_init_param: [p0..p3] are the first four words of the
  // parameter block (the rest is zero: no salt, no personalization)
  void initParam(int outLen, int p0, int p1, int p2, int p3) {
    for (var i = 0; i < 8; i++) {
      h[i] = _iv[i];
    }
    h[0] ^= p0;
    h[1] ^= p1;
    h[2] ^= p2;
    h[3] ^= p3;
    t0 = t1 = f0 = f1 = 0;
    buf.fillRange(0, blake2sBlockBytes, 0);
    bufLen = 0;
    lastNode = false;
    this.outLen = outLen;
  }

  // blake2s_init
  void init(int outLen) =>
      initParam(outLen, outLen | (1 << 16) | (1 << 24), 0, 0, 0);

  // blake2s_increment_counter
  void _incrementCounter(int inc) {
    t0 = (t0 + inc) & 0xFFFFFFFF;
    if (t0 < inc) t1 = (t1 + 1) & 0xFFFFFFFF;
  }

  // blake2s_compress
  void _compress(Uint8List input, int off) {
    final m = _m;
    final v = _v;
    for (var i = 0; i < 16; i++) {
      final o = off + i * 4;
      m[i] = input[o] |
          (input[o + 1] << 8) |
          (input[o + 2] << 16) |
          (input[o + 3] << 24);
    }
    for (var i = 0; i < 8; i++) {
      v[i] = h[i];
    }
    v[8] = _iv[0];
    v[9] = _iv[1];
    v[10] = _iv[2];
    v[11] = _iv[3];
    v[12] = t0 ^ _iv[4];
    v[13] = t1 ^ _iv[5];
    v[14] = f0 ^ _iv[6];
    v[15] = f1 ^ _iv[7];
    final sg = _sigmaBytes;
    for (var r = 0; r < 10; r++) {
      final s = r * 16;
      _g(v, m, 0, 4, 8, 12, sg[s + 0], sg[s + 1]);
      _g(v, m, 1, 5, 9, 13, sg[s + 2], sg[s + 3]);
      _g(v, m, 2, 6, 10, 14, sg[s + 4], sg[s + 5]);
      _g(v, m, 3, 7, 11, 15, sg[s + 6], sg[s + 7]);
      _g(v, m, 0, 5, 10, 15, sg[s + 8], sg[s + 9]);
      _g(v, m, 1, 6, 11, 12, sg[s + 10], sg[s + 11]);
      _g(v, m, 2, 7, 8, 13, sg[s + 12], sg[s + 13]);
      _g(v, m, 3, 4, 9, 14, sg[s + 14], sg[s + 15]);
    }
    for (var i = 0; i < 8; i++) {
      h[i] = h[i] ^ v[i] ^ v[i + 8];
    }
  }

  // G
  @pragma('vm:prefer-inline')
  static void _g(
      Uint32List v, Uint32List m, int a, int b, int c, int d, int x, int y) {
    var va = v[a], vb = v[b], vc = v[c], vd = v[d];
    va = (va + vb + m[x]) & 0xFFFFFFFF;
    vd ^= va;
    vd = ((vd >> 16) | (vd << 16)) & 0xFFFFFFFF;
    vc = (vc + vd) & 0xFFFFFFFF;
    vb ^= vc;
    vb = ((vb >> 12) | (vb << 20)) & 0xFFFFFFFF;
    va = (va + vb + m[y]) & 0xFFFFFFFF;
    vd ^= va;
    vd = ((vd >> 8) | (vd << 24)) & 0xFFFFFFFF;
    vc = (vc + vd) & 0xFFFFFFFF;
    vb ^= vc;
    vb = ((vb >> 7) | (vb << 25)) & 0xFFFFFFFF;
    v[a] = va;
    v[b] = vb;
    v[c] = vc;
    v[d] = vd;
  }

  // blake2s_update
  void update(Uint8List input, int off, int inLen) {
    if (inLen <= 0) return;
    final left = bufLen;
    final fill = blake2sBlockBytes - left;
    if (inLen > fill) {
      bufLen = 0;
      buf.setRange(left, left + fill, input, off);
      _incrementCounter(blake2sBlockBytes);
      _compress(buf, 0);
      off += fill;
      inLen -= fill;
      while (inLen > blake2sBlockBytes) {
        _incrementCounter(blake2sBlockBytes);
        _compress(input, off);
        off += blake2sBlockBytes;
        inLen -= blake2sBlockBytes;
      }
    }
    buf.setRange(bufLen, bufLen + inLen, input, off);
    bufLen += inLen;
  }

  // blake2s_final
  void finalTo(Uint8List out, int outOff) {
    _incrementCounter(bufLen);
    // blake2s_set_lastblock
    if (lastNode) f1 = 0xFFFFFFFF;
    f0 = 0xFFFFFFFF;
    buf.fillRange(bufLen, blake2sBlockBytes, 0);
    _compress(buf, 0);
    final tmp = Uint8List(blake2sOutBytes);
    for (var i = 0; i < 8; i++) {
      final w = h[i];
      tmp[i * 4] = w & 0xFF;
      tmp[i * 4 + 1] = (w >> 8) & 0xFF;
      tmp[i * 4 + 2] = (w >> 16) & 0xFF;
      tmp[i * 4 + 3] = (w >> 24) & 0xFF;
    }
    out.setRange(outOff, outOff + outLen, tmp);
  }
}

/// blake2sp_state: BLAKE2sp with a 32 byte digest and no key, as RAR5
/// uses it.
final class Blake2sp {
  final List<Blake2s> s =
      List.generate(_parallelismDegree, (_) => Blake2s(), growable: false);
  final Blake2s r = Blake2s();
  final Uint8List buf = Uint8List(_parallelismDegree * blake2sBlockBytes);
  int bufLen = 0;
  final int outLen;

  Blake2sp([this.outLen = blake2sOutBytes]) {
    init();
  }

  // the first four parameter words of blake2sp_init_leaf / _root
  static int _p0(int outLen) => outLen | (_parallelismDegree << 16) | (2 << 24);

  // blake2sp_init
  void init() {
    buf.fillRange(0, buf.length, 0);
    bufLen = 0;
    // blake2sp_init_root: node_depth 1, inner_length 32
    r.initParam(outLen, _p0(outLen), 0, 0, (1 << 16) | (blake2sOutBytes << 24));
    for (var i = 0; i < _parallelismDegree; i++) {
      // blake2sp_init_leaf: node_offset i, inner_length 32, the leaf
      // output length is inner_length
      s[i].initParam(outLen, _p0(outLen), 0, i, blake2sOutBytes << 24);
      s[i].outLen = blake2sOutBytes;
    }
    r.lastNode = true;
    s[_parallelismDegree - 1].lastNode = true;
  }

  // blake2sp_update
  void update(Uint8List input, [int off = 0, int? len]) {
    var inLen = len ?? input.length - off;
    var left = bufLen;
    final fill = buf.length - left;
    if (left != 0 && inLen >= fill) {
      buf.setRange(left, left + fill, input, off);
      for (var i = 0; i < _parallelismDegree; i++) {
        s[i].update(buf, i * blake2sBlockBytes, blake2sBlockBytes);
      }
      off += fill;
      inLen -= fill;
      left = 0;
    }
    const stripe = _parallelismDegree * blake2sBlockBytes;
    for (var i = 0; i < _parallelismDegree; i++) {
      var inLen2 = inLen;
      var in2 = off + i * blake2sBlockBytes;
      while (inLen2 >= stripe) {
        s[i].update(input, in2, blake2sBlockBytes);
        in2 += stripe;
        inLen2 -= stripe;
      }
    }
    off += inLen - inLen % stripe;
    inLen %= stripe;
    if (inLen > 0) buf.setRange(left, left + inLen, input, off);
    bufLen = left + inLen;
  }

  // blake2sp_final
  Uint8List digest() {
    final hash = Uint8List(_parallelismDegree * blake2sOutBytes);
    for (var i = 0; i < _parallelismDegree; i++) {
      if (bufLen > i * blake2sBlockBytes) {
        var left = bufLen - i * blake2sBlockBytes;
        if (left > blake2sBlockBytes) left = blake2sBlockBytes;
        s[i].update(buf, i * blake2sBlockBytes, left);
      }
      s[i].finalTo(hash, i * blake2sOutBytes);
    }
    for (var i = 0; i < _parallelismDegree; i++) {
      r.update(hash, i * blake2sOutBytes, blake2sOutBytes);
    }
    final out = Uint8List(outLen);
    r.finalTo(out, 0);
    return out;
  }

  /// BLAKE2sp of [data].
  static Uint8List hash(Uint8List data) => (Blake2sp()..update(data)).digest();
}
