// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

import 'compiler.dart';
import 'io.dart';
import 'predictor.dart';
import 'zpaql.dart';

/// Arithmetic encoder.
class Encoder {
  ZWriter? out;
  int _low = 1, _high = 0xFFFFFFFF;
  final Predictor pr;
  Uint8List _buf = Uint8List(0);

  Encoder(Zpaql z) : pr = Predictor(z);

  void init() {
    _low = 1;
    _high = 0xFFFFFFFF;
    pr.init();
    if (!pr.isModeled) {
      _low = 0;
      _buf = Uint8List(1 << 16);
    }
  }

  void _encode(int y, int p) {
    final mid = _low + (((_high - _low) * p) >> 16);
    if (y != 0) {
      _high = mid;
    } else {
      _low = mid + 1;
    }
    final o = out!;
    while ((_high ^ _low) < 0x1000000) {
      o.put(_high >> 24);
      _high = ((_high << 8) & 0xFFFFFFFF) | 255;
      _low = (_low << 8) & 0xFFFFFFFF;
      if (_low == 0) _low = 1;
    }
  }

  /// Compresses byte [c] (0..255) or -1 for end of segment.
  void compress(int c) {
    if (pr.isModeled) {
      if (c == -1) {
        _encode(1, 0);
      } else {
        _encode(0, 0);
        for (var i = 7; i >= 0; --i) {
          final y = (c >> i) & 1;
          _encode(y, pr.encodeBit(y) * 2 + 1);
        }
      }
    } else {
      if (_low != 0 && (c < 0 || _low == _buf.length)) {
        _flushStored();
      }
      if (c >= 0) _buf[_low++] = c;
    }
  }

  void _flushStored() {
    final o = out!;
    o.put((_low >> 24) & 255);
    o.put((_low >> 16) & 255);
    o.put((_low >> 8) & 255);
    o.put(_low & 255);
    o.write(_buf, 0, _low);
    _low = 0;
  }

  /// Stored mode: adds [n] bytes at once, same output as n compress() calls.
  void compressStored(Uint8List p, int off, int n) {
    while (n > 0) {
      if (_low != 0 && _low == _buf.length) _flushStored();
      var k = _buf.length - _low;
      if (k > n) k = n;
      _buf.setRange(_low, _low + k, p, off);
      _low += k;
      off += k;
      n -= k;
    }
  }
}

enum _CState { init, block1, seg1, block2, seg2 }

/// Writes ZPAQ blocks and segments.
class Compressor {
  final Zpaql _z;
  final Zpaql _pz = Zpaql();
  final Encoder _enc;
  ZReader? _in;
  _CState _state = _CState.init;

  Compressor() : this._(Zpaql());
  Compressor._(Zpaql z)
      : _z = z,
        _enc = Encoder(z);

  set output(ZWriter w) => _enc.out = w;
  set input(ZReader r) => _in = r;

  /// Writes the 13 byte locator tag.
  void writeTag() {
    const tag = [
      0x37, 0x6b, 0x53, 0x74, 0xa0, 0x31, 0x83, 0xd3, 0x8c, 0xb2, 0x28, 0xb0, //
      0xd3
    ];
    for (final c in tag) {
      _enc.out!.put(c);
    }
  }

  /// Starts a block from ZPAQL config source. Returns the PCOMP command text.
  String startBlockConfig(String config, List<int> args) {
    final r = Compiler(config, args, _z, _pz).compile();
    _writeBlockHeader();
    return r;
  }

  void _writeBlockHeader() {
    final o = _enc.out!;
    o.put(0x7a); // 'z'
    o.put(0x50); // 'P'
    o.put(0x51); // 'Q'
    o.put(1 + (_z.header[6] == 0 ? 1 : 0)); // level 1 or 2
    o.put(1);
    _z.write(o, false);
    _state = _CState.block1;
  }

  void startSegment([String filename = '', String comment = '']) {
    final o = _enc.out!;
    o.put(1);
    for (final c in filename.codeUnits) {
      o.put(c & 255);
    }
    o.put(0);
    for (final c in comment.codeUnits) {
      o.put(c & 255);
    }
    o.put(0);
    o.put(0);
    if (_state == _CState.block1) _state = _CState.seg1;
    if (_state == _CState.block2) _state = _CState.seg2;
  }

  void _postProcess() {
    if (_state == _CState.seg2) return;
    _enc.init();
    final len = _pz.hend - _pz.hbegin;
    if (len > 0) {
      _enc.compress(1);
      _enc.compress(len & 255);
      _enc.compress((len >> 8) & 255);
      for (var i = 0; i < len; ++i) {
        _enc.compress(_pz.header[_pz.hbegin + i]);
      }
    } else {
      _enc.compress(0);
    }
    _state = _CState.seg2;
  }

  /// Compresses all of the input.
  void compress() {
    if (_state == _CState.seg1) _postProcess();
    const bufsize = 1 << 14;
    final buf = Uint8List(bufsize);
    final enc = _enc;
    final stored = !enc.pr.isModeled;
    while (true) {
      final nr = _in!.read(buf, 0, bufsize);
      if (nr <= 0) return;
      if (stored) {
        enc.compressStored(buf, 0, nr);
      } else {
        for (var i = 0; i < nr; ++i) {
          enc.compress(buf[i]);
        }
      }
    }
  }

  void endSegment([Uint8List? sha1]) {
    if (_state == _CState.seg1) _postProcess();
    _enc.compress(-1);
    final o = _enc.out!;
    o.put(0);
    o.put(0);
    o.put(0);
    o.put(0);
    if (sha1 != null) {
      o.put(253);
      o.write(sha1, 0, 20);
    } else {
      o.put(254);
    }
    _state = _CState.block2;
  }

  void endBlock() {
    _enc.out!.put(255);
    _state = _CState.init;
  }
}
