// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

import 'io.dart';
import 'native_pcomp.dart';
import 'predictor.dart';
import 'sha1.dart';
import 'zpaql.dart';

/// Arithmetic decoder.
class Decoder extends ZReader implements BitDecoder {
  ZReader? input;
  int _low = 1, _high = 0xFFFFFFFF, _curr = 0;
  int _rpos = 0, _wpos = 0;
  final Predictor pr;
  static const int _bufsize = 1 << 16;
  final Uint8List _buf = Uint8List(_bufsize);

  Decoder(Zpaql z) : pr = Predictor(z);

  void init() {
    pr.init();
    if (pr.isModeled) {
      _low = 1;
      _high = 0xFFFFFFFF;
      _curr = 0;
    } else {
      _low = _high = _curr = 0;
    }
  }

  @override
  int get() {
    if (_rpos == _wpos) {
      _rpos = 0;
      _wpos = input != null ? input!.read(_buf, 0, _bufsize) : 0;
    }
    return _rpos < _wpos ? _buf[_rpos++] : -1;
  }

  /// How many bytes were read ahead from [input] but not consumed.
  int get buffered => _wpos - _rpos;

  @override
  int decodeBit(int p) => _decode(p);

  int _decode(int p) {
    if (_curr < _low || _curr > _high) zpaqError('archive corrupted');
    final mid = _low + (((_high - _low) * p) >> 16);
    int y;
    if (_curr <= mid) {
      y = 1;
      _high = mid;
    } else {
      y = 0;
      _low = mid + 1;
    }
    while ((_high ^ _low) < 0x1000000) {
      _high = ((_high << 8) & 0xFFFFFFFF) | 255;
      _low = (_low << 8) & 0xFFFFFFFF;
      if (_low == 0) _low = 1;
      final c = get();
      if (c < 0) zpaqError('unexpected end of file');
      _curr = ((_curr << 8) & 0xFFFFFFFF) | c;
    }
    return y;
  }

  /// Decompresses one byte, or returns -1 at end of segment.
  int decompress() {
    if (pr.isModeled) {
      if (_curr == 0) {
        for (var i = 0; i < 4; ++i) {
          _curr = ((_curr << 8) | get()) & 0xFFFFFFFF;
        }
      }
      if (_decode(0) != 0) {
        if (_curr != 0) zpaqError('decoding end of stream');
        return -1;
      }
      var c = 1;
      while (c < 256) {
        c += c + pr.decodeBit(this);
      }
      return c - 256;
    } else {
      if (_curr == 0) {
        for (var i = 0; i < 4; ++i) {
          _curr = ((_curr << 8) | get()) & 0xFFFFFFFF;
        }
        if (_curr == 0) return -1;
      }
      --_curr;
      return get();
    }
  }

  /// Stored (unmodeled) fast path: copies up to [n] bytes of the current
  /// stored run. Returns the count copied, 0 at end of segment.
  int decompressStored(Uint8List out, int off, int n) {
    if (_curr == 0) {
      for (var i = 0; i < 4; ++i) {
        final c = get();
        if (c < 0) zpaqError('unexpected end of file');
        _curr = ((_curr << 8) | c) & 0xFFFFFFFF;
      }
      if (_curr == 0) return 0;
    }
    if (n > _curr) n = _curr;
    var done = 0;
    while (done < n) {
      if (_rpos == _wpos) {
        _rpos = 0;
        _wpos = input != null ? input!.read(_buf, 0, _bufsize) : 0;
        if (_wpos == 0) zpaqError('unexpected end of file');
      }
      var k = _wpos - _rpos;
      if (k > n - done) k = n - done;
      out.setRange(off + done, off + done + k, _buf, _rpos);
      _rpos += k;
      done += k;
    }
    _curr -= n;
    return n;
  }

  /// Skips to the end of the compressed data and returns the next byte.
  int skip() {
    var c = -1;
    if (pr.isModeled) {
      while (_curr == 0) {
        _curr = get();
        if (_curr < 0) zpaqError('unexpected end of file');
      }
      while (_curr != 0 && (c = get()) >= 0) {
        _curr = ((_curr << 8) | c) & 0xFFFFFFFF;
      }
      while ((c = get()) == 0) {}
      return c;
    } else {
      if (_curr == 0) {
        for (var i = 0; i < 4 && (c = get()) >= 0; ++i) {
          _curr = ((_curr << 8) | c) & 0xFFFFFFFF;
        }
      }
      while (_curr > 0) {
        while (_curr > 0) {
          --_curr;
          if (get() < 0) zpaqError('skipped to EOF');
        }
        for (var i = 0; i < 4 && (c = get()) >= 0; ++i) {
          _curr = ((_curr << 8) | c) & 0xFFFFFFFF;
        }
      }
      if (c >= 0) c = get();
      return c;
    }
  }
}

/// Runs the PCOMP program (or passes data through) on decoded bytes.
class PostProcessor {
  int _state = 0; // 0=INIT, 1=PASS, 2..4=loading, 5=POST
  int _hsize = 0;
  int _ph = 0, _pm = 0;
  final Zpaql z = Zpaql();

  /// Use native Dart decoders for zpaq's standard postprocessors.
  static bool nativeEnabled = true;

  /// Expected output size of the segment, or 0 if unknown.
  int sizeHint = 0;
  NativePcomp? _native;
  final ZBuffer _nativeIn = ZBuffer(1 << 16);

  void init(int h, int m) {
    _native = null;
    _nativeIn.clear();
    _state = _hsize = 0;
    _ph = h;
    _pm = m;
    z.clear();
  }

  int get state => _state;

  set output(ZWriter? w) => z.output = w;
  set sha1(Sha1? s) => z.sha1 = s;

  /// Inputs byte [c] (or -1 at end of segment). Returns the new state.
  int write(int c) {
    switch (_state) {
      case 0:
        if (c < 0) zpaqError('Unexpected EOS');
        _state = c + 1;
        if (_state > 2) zpaqError('unknown post processing type');
        if (_state == 1) z.clear();
      case 1:
        if (c >= 0) {
          z.outc(c);
        } else {
          z.flush();
        }
      case 2:
        if (c < 0) zpaqError('Unexpected EOS');
        _hsize = c;
        _state = 3;
      case 3:
        if (c < 0) zpaqError('Unexpected EOS');
        _hsize += c * 256;
        if (_hsize < 1) zpaqError('Empty PCOMP');
        z.header = Uint8List(_hsize + 300);
        z.cend = 8;
        z.hbegin = z.hend = z.cend + 128;
        z.header[4] = _ph;
        z.header[5] = _pm;
        _state = 4;
      case 4:
        if (c < 0) zpaqError('Unexpected EOS');
        z.header[z.hend++] = c;
        if (z.hend - z.hbegin == _hsize) {
          _hsize = (z.cend - 2) + z.hend - z.hbegin;
          z.header[0] = _hsize & 255;
          z.header[1] = _hsize >> 8;
          z.initp();
          _state = 5;
          if (nativeEnabled) {
            _native = recognizePcomp(z.header, z.hbegin, z.hend - z.hbegin);
          }
        }
      case 5:
        final nat = _native;
        if (nat != null) {
          if (c >= 0) {
            _nativeIn.put(c);
          } else {
            final out = decodeNative(
                nat, _nativeIn.data, _nativeIn.size, 1 << _pm, sizeHint);
            _nativeIn.clear();
            z.flush();
            final o = z.output;
            // An empty ZBuffer output takes the decoded block as it is.
            if (!(o is ZBuffer && o.adopt(out))) o?.write(out, 0, out.length);
            z.sha1?.add(out, 0, out.length);
          }
          break;
        }
        z.run(c);
        if (c < 0) z.flush();
    }
    return _state;
  }

  /// Reserves room for [n] bytes of postprocessor input.
  void reserveInput(int n) => _nativeIn.reserve(n);

  /// True if [writeBulk] can take the data: passed through, or collected
  /// for a native postprocessor.
  bool get acceptsBulk => _state == 1 || (_state == 5 && _native != null);

  /// Writes a run of data bytes (not the end of segment) at once.
  void writeBulk(Uint8List buf, int off, int n) {
    if (_state == 1) {
      writePass(buf, off, n);
    } else {
      _nativeIn.write(buf, off, n);
    }
  }

  /// Writes a run of bytes in PASS mode.
  void writePass(Uint8List buf, int off, int n) {
    z.flush();
    z.output?.write(buf, off, n);
    z.sha1?.add(buf, off, off + n);
  }
}

enum _DState { block, filename, comment, data, segend }

enum _DecodeState { firstseg, seg, skip }

/// Parses and decompresses ZPAQ blocks and segments.
class Decompresser {
  final Zpaql _z;
  final Decoder _dec;
  final PostProcessor _pp = PostProcessor();
  _DState _state = _DState.block;
  _DecodeState _decodeState = _DecodeState.firstseg;

  Decompresser() : this._(Zpaql());
  Decompresser._(Zpaql z)
      : _z = z,
        _dec = Decoder(z);

  set input(ZReader r) => _dec.input = r;
  set output(ZWriter? w) => _pp.output = w;

  /// Expected size of the next segment's output (0 if unknown), used to
  /// size buffers once.
  set sizeHint(int n) {
    _pp.sizeHint = n;
    if (n > 0) _pp.reserveInput(n);
  }

  set sha1(Sha1? s) => _pp.sha1 = s;

  int get buffered => _dec.buffered;

  /// Memory needed by the last found block.
  double memory = 0;

  /// Finds the start of the next block. Returns false at end of input.
  bool findBlock() {
    var h1 = 0x3D49B113, h2 = 0x29EB7F93, h3 = 0x2614BE13, h4 = 0x3828EB13;
    int c;
    while ((c = _dec.get()) != -1) {
      h1 = (h1 * 12 + c) & 0xFFFFFFFF;
      h2 = (h2 * 20 + c) & 0xFFFFFFFF;
      h3 = (h3 * 28 + c) & 0xFFFFFFFF;
      h4 = (h4 * 44 + c) & 0xFFFFFFFF;
      if (h1 == 0xB16B88F1 &&
          h2 == 0xFF5376F1 &&
          h3 == 0x72AC5BF1 &&
          h4 == 0x2F909AF1) {
        break;
      }
    }
    if (c == -1) return false;
    c = _dec.get();
    if (c != 1 && c != 2) zpaqError('unsupported ZPAQ level');
    if (_dec.get() != 1) zpaqError('unsupported ZPAQL type');
    _z.read(_dec);
    if (c == 1 && _z.header.length > 6 && _z.header[6] == 0) {
      zpaqError('ZPAQ level 1 requires at least 1 component');
    }
    memory = _z.memory();
    _state = _DState.filename;
    _decodeState = _DecodeState.firstseg;
    return true;
  }

  /// Reads a segment header. Returns the filename, or null at end of block.
  String? findFilename() {
    final c = _dec.get();
    if (c == 1) {
      final b = <int>[];
      while (true) {
        final ch = _dec.get();
        if (ch == -1) zpaqError('unexpected EOF');
        if (ch == 0) {
          _state = _DState.comment;
          return String.fromCharCodes(b);
        }
        b.add(ch);
      }
    } else if (c == 255) {
      _state = _DState.block;
      return null;
    }
    zpaqError('missing segment or end of block');
  }

  /// Reads the segment comment (as raw latin-1 bytes).
  String readComment() {
    _state = _DState.data;
    final b = <int>[];
    while (true) {
      final c = _dec.get();
      if (c == -1) zpaqError('unexpected EOF');
      if (c == 0) break;
      b.add(c);
    }
    if (_dec.get() != 0) zpaqError('missing reserved byte');
    return String.fromCharCodes(b);
  }

  static const int _chunk = 1 << 16;
  Uint8List? _tmp;

  /// Decompresses the whole segment into the output.
  void decompress() {
    if (_decodeState == _DecodeState.skip) {
      zpaqError('decompression after skipped segment');
    }
    if (_decodeState == _DecodeState.firstseg) {
      _dec.init();
      _pp.init(_z.header[4], _z.header[5]);
      _decodeState = _DecodeState.seg;
    }
    while ((_pp.state & 3) != 1) {
      _pp.write(_dec.decompress());
    }
    if (!_dec.pr.isModeled && _pp.acceptsBulk) {
      // Stored data, passed through or decoded natively at the end of the
      // segment (method 1): copy runs directly, not byte by byte.
      final tmp = _tmp ??= Uint8List(_chunk);
      while (true) {
        final n = _dec.decompressStored(tmp, 0, _chunk);
        if (n == 0) break;
        _pp.writeBulk(tmp, 0, n);
      }
      _pp.write(-1);
      _state = _DState.segend;
      return;
    }
    final dec = _dec, pp = _pp;
    while (true) {
      final c = dec.decompress();
      pp.write(c);
      if (c == -1) {
        _state = _DState.segend;
        return;
      }
    }
  }

  /// Reads the end of segment. Returns the stored SHA-1 or null if absent.
  Uint8List? readSegmentEnd() {
    var c = 0;
    if (_state == _DState.data) {
      c = _dec.skip();
      _decodeState = _DecodeState.skip;
    } else if (_state == _DState.segend) {
      c = _dec.get();
    }
    _state = _DState.filename;
    if (c == 254) return null;
    if (c == 253) {
      final r = Uint8List(20);
      for (var i = 0; i < 20; ++i) {
        final x = _dec.get();
        if (x < 0) zpaqError('unexpected EOF');
        r[i] = x;
      }
      return r;
    }
    zpaqError('missing end of segment marker');
  }
}

/// Decompresses every block and segment of a raw ZPAQ stream into [out].
void decompressAll(ZReader input, ZWriter out) {
  final d = Decompresser()
    ..input = input
    ..output = out;
  while (d.findBlock()) {
    while (d.findFilename() != null) {
      d.readComment();
      d.decompress();
      d.readSegmentEnd();
    }
  }
}
