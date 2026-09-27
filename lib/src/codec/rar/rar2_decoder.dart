// The RAR 2.0 decompressor (unpack versions 20 and 26, the method of RAR
// 2.x archives, with its audio ("multimedia") blocks): port of rardecode
// (github.com/nwaples/rardecode, Nicholas Waples, BSD 2-clause, see
// LICENSE): decode20.go (decoder20, readCodeLengthTable20), decode20_lz.go
// (lz20Decoder), decode20_audio.go (audio20Decoder), the Huffman decoder
// of huffman.go (huffmanDecoder) and the tables of decode29_lz.go.
//
// Differences with rardecode: the packed data is an InStream and the
// output an OutStream, the window is written to the output as it fills
// (decodeReader), the bits after the end of the packed data read as zeros
// (the Huffman decoder reads 15 bits ahead) up to a limit, and the LZ
// state (offsets, length) is also cleared when a non solid file starts.
// The RAR 1.5 method (unpack version 15) is not in rardecode: it is the
// independent implementation of rar15_decoder.dart.

import 'dart:typed_data';

import '../../io/streams.dart';

/// audioSize
const int _audioSize = 257;

/// main20Size, offset20Size, length20Size
const int _main20Size = 298;
const int _offset20Size = 48;
const int _length20Size = 28;

/// maxCodeLength, maxQuickBits
const int _maxCodeLength = 15;
const int _maxQuickBits = 10;

/// The smallest window (RAR 2.0 dictionaries are 64 KiB to 1 MiB, and the
/// distances reach 1 MiB + 64 KiB).
const int _minWindow = 1 << 21;

// lengthBase, lengthExtraBits, offsetBase, offsetExtraBits,
// shortOffsetBase, shortOffsetExtraBits (decode29_lz.go)
const List<int> _lengthBase = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, //
  24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224,
];
const List<int> _lengthExtraBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, //
  2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5,
];
const List<int> _offsetBase = [
  0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, //
  128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096,
  6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304,
  131072, 196608, 262144, 327680, 393216, 458752, 524288,
  589824, 655360, 720896, 786432, 851968, 917504, 983040,
];
const List<int> _offsetExtraBits = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, //
  6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14,
  15, 15, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
];
const List<int> _shortOffsetBase = [0, 4, 8, 16, 32, 64, 128, 192];
const List<int> _shortOffsetExtraBits = [2, 2, 3, 4, 5, 6, 6, 6];

SevenZipException _bad([String m = 'bad RAR 2.0 data']) =>
    SevenZipException('RAR: $m', SevenZipError.data);

/// huffmanDecoder: canonical codes by limits, with a quick table.
final class _Huffman {
  final Uint32List limit = Uint32List(_maxCodeLength + 1);
  final Uint32List pos = Uint32List(_maxCodeLength + 1);
  Uint16List symbol = Uint16List(0);
  int numSymbols = 0;
  int min = 0;
  int quickBits = 0;
  final Uint8List quickLen = Uint8List(1 << _maxQuickBits);
  final Uint16List quickSym = Uint16List(1 << _maxQuickBits);

  // huffmanDecoder.init
  void init(Uint8List codeLengths, int off, int n) {
    final count = Uint32List(_maxCodeLength + 1);
    for (var i = 0; i < n; i++) {
      final l = codeLengths[off + i];
      if (l != 0) count[l]++;
    }
    pos[0] = 0;
    limit[0] = 0;
    min = 0;
    for (var i = 1; i <= _maxCodeLength; i++) {
      // uint16 arithmetic
      limit[i] = (limit[i - 1] + (count[i] << (_maxCodeLength - i))) & 0xFFFF;
      pos[i] = (pos[i - 1] + count[i - 1]) & 0xFFFF;
      if (min == 0 && limit[i] > 0) min = i;
    }
    if (symbol.length < n) {
      symbol = Uint16List(n);
    } else {
      symbol.fillRange(0, n, 0);
    }
    numSymbols = n;
    for (var i = 0; i <= _maxCodeLength; i++) {
      count[i] = pos[i];
    }
    for (var i = 0; i < n; i++) {
      final l = codeLengths[off + i];
      if (l != 0) {
        final p = count[l];
        if (p < n) symbol[p] = i;
        count[l]++;
      }
    }
    quickBits = n >= 298 ? _maxQuickBits : _maxQuickBits - 3;
    var bits = 1;
    for (var i = 0; i < (1 << quickBits); i++) {
      final v = i << (_maxCodeLength - quickBits);
      while (v >= limit[bits] && bits < _maxCodeLength) {
        bits++;
      }
      quickLen[i] = bits;
      final dist = ((v - limit[bits - 1]) & 0xFFFF) >> (_maxCodeLength - bits);
      final p = pos[bits] + dist;
      quickSym[i] = p < n ? symbol[p] : 0;
    }
  }
}

/// audioVar
final class _AudioVar {
  final Int32List k = Int32List(5);
  final Int32List d = Int32List(4);
  int lastDelta = 0;
  final Int32List dif = Int32List(11);
  int byteCount = 0;
  int lastChar = 0;

  void reset() {
    k.fillRange(0, 5, 0);
    d.fillRange(0, 4, 0);
    lastDelta = 0;
    dif.fillRange(0, 11, 0);
    byteCount = 0;
    lastChar = 0;
  }
}

/// The RAR 2.0 decoder state (decoder20 with its lz20Decoder and
/// audio20Decoder); it lives across the files of a solid archive.
final class Rar2Decoder {
  // the window (decodeReader), positions are absolute
  Uint8List _win = Uint8List(0);
  int _mask = 0;
  int _pos = 0;

  // decoder20
  bool _hdrRead = false;
  bool _isAudio = false;
  final Uint8List _codeLength = Uint8List(_audioSize * 4);

  // lz20Decoder
  int _length = 0;
  final Int64List _offset = Int64List(4);
  final _Huffman _mainDecoder = _Huffman();
  final _Huffman _offsetDecoder = _Huffman();
  final _Huffman _lengthDecoder = _Huffman();

  // audio20Decoder
  int _chans = 1;
  int _curChan = 0;
  int _chanDelta = 0;
  final List<_Huffman> _audioDecoders = [
    _Huffman(),
    _Huffman(),
    _Huffman(),
    _Huffman()
  ];
  final List<_AudioVar> _vars = [
    _AudioVar(),
    _AudioVar(),
    _AudioVar(),
    _AudioVar()
  ];

  final _Huffman _bl = _Huffman();
  final Uint8List _bitLength = Uint8List(19);

  // rarBitReader
  InStream? _src;
  final Uint8List _inBuf = Uint8List(1 << 16);
  int _inPos = 0;
  int _inLen = 0;
  bool _inEof = false;
  int _overrun = 0;
  int _bitBuf = 0;
  int _bitCount = 0;

  /// Decodes one file of [unpSize] bytes from [src] into [out].
  /// [dictSize] is the dictionary size of the file header; [solid]
  /// continues the state of the previous file.
  // decodeReader.init, decoder20.init
  void decodeFile(
      InStream src, OutStream out, int unpSize, int dictSize, bool solid) {
    final reset = !solid || _win.isEmpty;
    if (reset) {
      var size = _minWindow;
      while (size < dictSize) {
        size <<= 1;
      }
      if (_win.length != size) {
        _win = Uint8List(size);
      } else {
        _win.fillRange(0, size, 0);
      }
      _mask = size - 1;
      _pos = 0;
      _hdrRead = false;
      _isAudio = false;
      _codeLength.fillRange(0, _codeLength.length, 0);
      _length = 0;
      _offset.fillRange(0, 4, 0);
      // audio20Decoder.reset
      _chans = 1;
      _curChan = 0;
      _chanDelta = 0;
      for (final v in _vars) {
        v.reset();
      }
    }
    _src = src;
    _inPos = 0;
    _inLen = 0;
    _inEof = false;
    _overrun = 0;
    _bitBuf = 0;
    _bitCount = 0;
    try {
      _fill(out, unpSize);
    } finally {
      _src = null;
    }
  }

  // The bit reader (rarBitReader), reading zeros after the end.

  int _readByte() {
    if (_inPos == _inLen) {
      if (!_inEof) {
        _inLen = readFully(_src!, _inBuf, 0, _inBuf.length);
        _inPos = 0;
        if (_inLen < _inBuf.length) _inEof = true;
      }
      if (_inPos == _inLen) {
        if (++_overrun > 64) {
          throw const SevenZipException(
              'RAR: truncated file data', SevenZipError.unexpectedEnd);
        }
        return 0;
      }
    }
    return _inBuf[_inPos++];
  }

  @pragma('vm:prefer-inline')
  int _peek(int n) {
    while (_bitCount < n) {
      _bitBuf = ((_bitBuf << 8) | _readByte()) & 0xFFFFFFFFFFFF;
      _bitCount += 8;
    }
    return (_bitBuf >> (_bitCount - n)) & ((1 << n) - 1);
  }

  // readBits
  @pragma('vm:prefer-inline')
  int _bits(int n) {
    final v = _peek(n);
    _bitCount -= n;
    return v;
  }

  // huffmanDecoder.readSym
  int _sym(_Huffman h) {
    final v = _peek(_maxCodeLength);
    if (v < h.limit[h.quickBits]) {
      final i = v >> (_maxCodeLength - h.quickBits);
      _bitCount -= h.quickLen[i];
      return h.quickSym[i];
    }
    var bits = h.min;
    while (bits < _maxCodeLength && v >= h.limit[bits]) {
      bits++;
    }
    if (bits == 0) throw _bad('Huffman decode failed');
    _bitCount -= bits;
    final dist = ((v - h.limit[bits - 1]) & 0xFFFF) >> (_maxCodeLength - bits);
    final p = h.pos[bits] + dist;
    if (p >= h.numSymbols) throw _bad('Huffman decode failed');
    return h.symbol[p];
  }

  // readCodeLengthTable20
  void _readCodeLengthTable(int n) {
    final bitLength = _bitLength;
    for (var i = 0; i < 19; i++) {
      bitLength[i] = _bits(4);
    }
    _bl.init(bitLength, 0, 19);
    final table = _codeLength;
    for (var i = 0; i < n;) {
      final l = _sym(_bl);
      if (l < 16) {
        table[i] = (table[i] + l) & 0xF;
        i++;
        continue;
      }
      if (l == 16) {
        if (i == 0) throw _bad('invalid Huffman code length table');
        var e = i + _bits(2) + 3;
        if (e > n) e = n;
        final v = table[i - 1];
        while (i < e) {
          table[i++] = v;
        }
        continue;
      }
      var e = i + (l == 17 ? _bits(3) + 3 : _bits(7) + 11);
      if (e > n) e = n;
      while (i < e) {
        table[i++] = 0;
      }
    }
  }

  // decoder20.readBlockHeader
  void _readBlockHeader() {
    _isAudio = _bits(1) != 0;
    if (_bits(1) == 0) _codeLength.fillRange(0, _codeLength.length, 0);
    if (_isAudio) {
      // audio20Decoder.init
      _chans = _bits(2) + 1;
      if (_curChan >= _chans) _curChan = 0;
      _readCodeLengthTable(_audioSize * _chans);
      for (var i = 0; i < _chans; i++) {
        _audioDecoders[i].init(_codeLength, i * _audioSize, _audioSize);
      }
    } else {
      // lz20Decoder.init
      _readCodeLengthTable(_main20Size + _offset20Size + _length20Size);
      _mainDecoder.init(_codeLength, 0, _main20Size);
      _offsetDecoder.init(_codeLength, _main20Size, _offset20Size);
      _lengthDecoder.init(
          _codeLength, _main20Size + _offset20Size, _length20Size);
    }
    _hdrRead = true;
  }

  // decoder20.fill with the window of decodeReader: decodes [size] bytes
  // and writes them to [out]
  void _fill(OutStream out, int size) {
    final start = _pos;
    final end = start + size;
    var written = start;
    while (_pos < end) {
      if (!_hdrRead) _readBlockHeader();
      final bool endOfBlock;
      if (_isAudio) {
        endOfBlock = _fillAudio(end);
      } else {
        endOfBlock = _fillLz(end);
      }
      if (endOfBlock) _hdrRead = false;
      // at most half a window was decoded: write it before it is
      // overwritten
      final to = _pos < end ? _pos : end;
      _write(out, written, to);
      written = to;
    }
  }

  void _write(OutStream out, int from, int to) {
    if (to <= from) return;
    final a = from & _mask;
    final n = to - from;
    if (a + n <= _win.length) {
      out.write(_win, a, n);
    } else {
      final n1 = _win.length - a;
      out.write(_win, a, n1);
      out.write(_win, 0, n - n1);
    }
  }

  // decodeReader.copyBytes
  void _copyBytes(int length, int offset) {
    final w = _win;
    final mask = _mask;
    var p = _pos;
    for (var i = 0; i < length; i++) {
      w[p & mask] = w[(p - offset) & mask];
      p++;
    }
    _pos = p;
  }

  // the offsets history: copy(d.offset[1:], d.offset[:])
  @pragma('vm:prefer-inline')
  void _shiftOffsets() {
    final o = _offset;
    o[3] = o[2];
    o[2] = o[1];
    o[1] = o[0];
  }

  // lz20Decoder.fill: true at the end of the block (a new table follows).
  // Decodes up to [end] or at most half a window, so that the output can
  // be written before it is overwritten.
  bool _fillLz(int end) {
    final limit = _pos + (_win.length >> 1);
    final stop = end < limit ? end : limit;
    while (_pos < stop) {
      final sym = _sym(_mainDecoder);
      if (sym < 256) {
        // literal
        _win[_pos & _mask] = sym;
        _pos++;
        continue;
      }
      if (sym > 269) {
        // decodeOffset
        var i = sym - 270;
        _length = _lengthBase[i] + 3;
        var bits = _lengthExtraBits[i];
        if (bits > 0) _length += _bits(bits);
        i = _sym(_offsetDecoder);
        if (i >= _offset20Size) throw _bad();
        var offset = _offsetBase[i] + 1;
        bits = _offsetExtraBits[i];
        if (bits > 0) offset += _bits(bits);
        if (offset >= 0x2000) {
          _length++;
          if (offset >= 0x40000) _length++;
        }
        _shiftOffsets();
        _offset[0] = offset;
      } else if (sym == 269) {
        return true;
      } else if (sym == 256) {
        // use previous offset and length
        _shiftOffsets();
      } else if (sym < 261) {
        // decodeLength
        final offset = _offset[sym - 257];
        _shiftOffsets();
        _offset[0] = offset;
        final i = _sym(_lengthDecoder);
        _length = _lengthBase[i] + 2;
        final bits = _lengthExtraBits[i];
        if (bits > 0) _length += _bits(bits);
        if (offset >= 0x101) {
          _length++;
          if (offset >= 0x2000) {
            _length++;
            if (offset >= 0x40000) _length++;
          }
        }
      } else {
        // decodeShortOffset
        final i = sym - 261;
        _shiftOffsets();
        var offset = _shortOffsetBase[i] + 1;
        final bits = _shortOffsetExtraBits[i];
        if (bits > 0) offset += _bits(bits);
        _offset[0] = offset;
        _length = 2;
      }
      _copyBytes(_length, _offset[0]);
    }
    return false;
  }

  // audio20Decoder.fill: true at the end of the block
  bool _fillAudio(int end) {
    final limit = _pos + (_win.length >> 1);
    final stop = end < limit ? end : limit;
    while (_pos < stop) {
      final sym = _sym(_audioDecoders[_curChan]);
      if (sym == 256) return true;
      _win[_pos & _mask] = _decodeAudio(sym);
      _pos++;
      _curChan++;
      if (_curChan >= _chans) _curChan = 0;
    }
    return false;
  }

  // audio20Decoder.decode
  int _decodeAudio(int delta) {
    final v = _vars[_curChan];
    final k = v.k;
    final d = v.d;
    final dif = v.dif;
    v.byteCount++;
    d[3] = d[2];
    d[2] = d[1];
    d[1] = v.lastDelta - d[0];
    d[0] = v.lastDelta;
    var pch = 8 * v.lastChar +
        k[0] * d[0] +
        k[1] * d[1] +
        k[2] * d[2] +
        k[3] * d[3] +
        k[4] * _chanDelta;
    pch = (pch >> 3) & 0xFF;
    final ch = pch - delta;
    // int(int8(delta)) << 3
    final dl = (delta >= 128 ? delta - 256 : delta) << 3;

    dif[0] += _abs(dl);
    dif[1] += _abs(dl - d[0]);
    dif[2] += _abs(dl + d[0]);
    dif[3] += _abs(dl - d[1]);
    dif[4] += _abs(dl + d[1]);
    dif[5] += _abs(dl - d[2]);
    dif[6] += _abs(dl + d[2]);
    dif[7] += _abs(dl - d[3]);
    dif[8] += _abs(dl + d[3]);
    dif[9] += _abs(dl - _chanDelta);
    dif[10] += _abs(dl + _chanDelta);

    // int(int8(ch - v.lastChar))
    final cd = (ch - v.lastChar) & 0xFF;
    _chanDelta = cd >= 128 ? cd - 256 : cd;
    v.lastDelta = _chanDelta;
    v.lastChar = ch;

    if ((v.byteCount & 0x1F) != 0) return ch & 0xFF;

    var numMinDif = 0;
    var minDif = dif[0];
    dif[0] = 0;
    for (var i = 1; i < 11; i++) {
      if (dif[i] < minDif) {
        minDif = dif[i];
        numMinDif = i;
      }
      dif[i] = 0;
    }
    if (numMinDif > 0) {
      numMinDif--;
      final i = numMinDif >> 1;
      if ((numMinDif & 1) == 0) {
        if (k[i] >= -16) k[i]--;
      } else if (k[i] < 16) {
        k[i]++;
      }
    }
    return ch & 0xFF;
  }

  static int _abs(int x) => x < 0 ? -x : x;
}
