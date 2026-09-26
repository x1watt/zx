// The RAR 2.9 / 3.x decompressor (unpack versions 29 and 36): port of the
// decoding part of libarchive's archive_read_support_format_rar.c (Tim
// Kientzle, Andres Mejia; BSD 2-clause, see LICENSE): parse_codes,
// read_next_symbol, create_code, add_value, make_table, expand, the LZSS
// window, the PPMd blocks (with rar_ppmd.dart) and the filters
// (parse_filter, run_filters, execute_filter: the standard RAR VM programs
// DELTA, E8, E8E9, RGB and AUDIO, recognized by their fingerprints).
//
// Differences with libarchive: the packed data is an InStream and the
// output an OutStream; the state is kept between the files of a solid
// archive (libarchive refuses solid archives); the PPMd memory size does
// not resize the LZ window; a filter block may continue in PPMd blocks,
// and PPMd escape code 3 reads a filter like the LZ code 257 does
// (libarchive rejects both). Not supported, as in libarchive: other RAR VM
// programs (ITANIUM and custom code) and the RAR 1.5 / 2.0 compression
// methods (unpack versions 15, 20, 26).

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc.dart';
import '../ppmd/ppmd7.dart';
import 'rar_ppmd.dart';

const int _mainCodeSize = 299;
const int _offsetCodeSize = 60;
const int _lowOffsetCodeSize = 17;
const int _lengthCodeSize = 28;
const int _huffmanTableSize =
    _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize + _lengthCodeSize;
const int _maxSymbolLength = 0xF;
const int _maxSymbols = 20;

// Virtual machine properties
const int _vmMemorySize = 0x40000;
const int _programWorkSize = 0x3C000;
const int _programSystemGlobalAddress = _programWorkSize;
const int _programSystemGlobalSize = 0x40;
const int _programUserGlobalSize = 0x2000 - _programSystemGlobalSize;

const List<int> _lengthBases = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, //
  24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224,
];
const List<int> _lengthBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, //
  2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5,
];
const List<int> _offsetBases = [
  0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, //
  64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072,
  4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304,
  131072, 196608, 262144, 327680, 393216, 458752, 524288, 589824,
  655360, 720896, 786432, 851968, 917504, 983040, 1048576, 1310720,
  1572864, 1835008, 2097152, 2359296, 2621440, 2883584, 3145728,
  3407872, 3670016, 3932160,
];
const List<int> _offsetBits = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, //
  5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
  11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
  16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
  18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
];
const List<int> _shortBases = [0, 4, 8, 16, 32, 64, 128, 192];
const List<int> _shortBits = [2, 2, 3, 4, 5, 6, 6, 6];

SevenZipException _bad([String m = 'bad RAR file data']) =>
    SevenZipException('RAR: $m', SevenZipError.data);

/// struct huffman_code: a code tree with a lookup table.
final class _HuffmanCode {
  Int32List tree = Int32List(0); // branches[2] per node
  int numEntries = 0;
  int minLength = 0;
  int maxLength = 0;
  int tableSize = 0;
  Int32List tableLength = Int32List(0);
  Int32List tableValue = Int32List(0);
  bool hasTable = false;

  // new_node
  void _newNode() {
    final i = numEntries * 2;
    if (i + 2 > tree.length) {
      final n = Int32List(tree.isEmpty ? 512 : tree.length * 2);
      n.setRange(0, tree.length, tree);
      tree = n;
    }
    tree[i] = -1;
    tree[i + 1] = -2;
  }

  // create_code
  void create(Uint8List lengths, int off, int numSymbols, int maxLen) {
    numEntries = 0;
    _newNode();
    numEntries = 1;
    minLength = 0x7FFFFFFF;
    maxLength = -0x80000000;
    hasTable = false;
    var codeBits = 0;
    var symbolsLeft = numSymbols;
    for (var i = 1; i <= maxLen; i++) {
      for (var j = 0; j < numSymbols; j++) {
        if (lengths[off + j] != i) continue;
        _addValue(j, codeBits, i);
        codeBits++;
        if (--symbolsLeft <= 0) break;
      }
      if (symbolsLeft <= 0) break;
      codeBits <<= 1;
    }
  }

  // add_value
  void _addValue(int value, int codeBits, int length) {
    hasTable = false;
    if (length > maxLength) maxLength = length;
    if (length < minLength) minLength = length;
    var lastNode = 0;
    for (var bitPos = length - 1; bitPos >= 0; bitPos--) {
      final bit = (codeBits >> bitPos) & 1;
      if (tree[lastNode * 2] == tree[lastNode * 2 + 1]) {
        throw _bad('prefix found');
      }
      if (tree[lastNode * 2 + bit] < 0) {
        _newNode();
        tree[lastNode * 2 + bit] = numEntries++;
      }
      lastNode = tree[lastNode * 2 + bit];
    }
    if (!(tree[lastNode * 2] == -1 && tree[lastNode * 2 + 1] == -2)) {
      throw _bad('prefix found');
    }
    tree[lastNode * 2] = value;
    tree[lastNode * 2 + 1] = value;
  }

  // make_table
  void makeTable() {
    if (maxLength < minLength || maxLength > 10) {
      tableSize = 10;
    } else {
      tableSize = maxLength;
    }
    final n = 1 << tableSize;
    if (tableLength.length < n) {
      tableLength = Int32List(n);
      tableValue = Int32List(n);
    }
    _makeTableRecurse(0, 0, 0, tableSize);
    hasTable = true;
  }

  // make_table_recurse
  void _makeTableRecurse(int node, int table, int depth, int maxDepth) {
    if (node < 0 || node >= numEntries) {
      throw _bad('invalid location in the Huffman tree');
    }
    final currTableSize = 1 << (maxDepth - depth);
    if (tree[node * 2] == tree[node * 2 + 1]) {
      for (var i = 0; i < currTableSize; i++) {
        tableLength[table + i] = depth;
        tableValue[table + i] = tree[node * 2];
      }
    } else if (depth == maxDepth) {
      tableLength[table] = maxDepth + 1;
      tableValue[table] = node;
    } else {
      _makeTableRecurse(tree[node * 2], table, depth + 1, maxDepth);
      _makeTableRecurse(
          tree[node * 2 + 1], table + currTableSize ~/ 2, depth + 1, maxDepth);
    }
  }
}

/// struct rar_program_code
final class _ProgramCode {
  Uint8List? staticData;
  int fingerprint = 0;
  int usageCount = 0;
  int oldFilterLength = 0;
}

/// struct rar_filter
final class _Filter {
  final _ProgramCode prog;
  final Uint32List initialRegisters = Uint32List(8);
  Uint8List globalData;
  final int blockStartPos;
  final int blockLength;
  int filteredBlockAddress = 0;
  int filteredBlockLength = 0;
  _Filter(this.prog, this.globalData, this.blockStartPos, this.blockLength);
}

/// struct memory_bit_reader
final class _MemBitReader {
  final Uint8List bytes;
  final int length;
  int offset = 0;
  int bits = 0;
  int available = 0;
  bool atEof = false;
  _MemBitReader(this.bytes, this.length);

  // membr_bits
  int getBits(int n) {
    if (n > available && (atEof || !_fill(n))) return 0;
    available -= n;
    return (bits >> available) & ((1 << n) - 1);
  }

  // membr_fill
  bool _fill(int n) {
    while (available < n && offset < length) {
      bits = ((bits << 8) | bytes[offset++]) & 0xFFFFFFFFFFFF;
      available += 8;
    }
    if (n > available) {
      atEof = true;
      return false;
    }
    return true;
  }

  // membr_next_rarvm_number
  int nextRarVmNumber() {
    switch (getBits(2)) {
      case 0:
        return getBits(4);
      case 1:
        final val = getBits(8);
        if (val >= 16) return val;
        return 0xFFFFFF00 | (val << 4) | getBits(4);
      case 2:
        return getBits(16);
      default:
        return getBits(32);
    }
  }
}

/// The RAR 2.9 / 3.x decoder state; it lives across the files of a solid
/// archive.
final class Rar3Decoder {
  // LZSS window
  Uint8List _win = Uint8List(0);
  int _mask = 0;
  int _pos = 0; // absolute position

  // Huffman codes
  final Uint8List _lengthTable = Uint8List(_huffmanTableSize);
  final _HuffmanCode _mainCode = _HuffmanCode();
  final _HuffmanCode _offsetCode = _HuffmanCode();
  final _HuffmanCode _lowOffsetCode = _HuffmanCode();
  final _HuffmanCode _lengthCode = _HuffmanCode();
  final _HuffmanCode _preCode = _HuffmanCode();
  bool _codesValid = false;

  int _lastLength = 0;
  int _lastOffset = 0;
  final Int64List _oldOffset = Int64List(4);
  int _lastLowOffset = 0;
  int _numLowOffsetRepeats = 0;
  bool _startNewTable = true;

  // PPMd
  bool _isPpmdBlock = false;
  bool _ppmdValid = false;
  int _ppmdEscape = 2;
  Ppmd7? _ppmd;
  RarPpmdRangeDecoder? _rc;

  // filters
  final List<_ProgramCode> _progs = [];
  final List<_Filter> _stack = [];
  int _filterStart = _noFilter;
  int _lastFilterNum = 0;
  Uint8List? _vm;

  static const int _noFilter = 0x7FFFFFFFFFFFFFFF;

  // bit reader (rar_br)
  InStream? _src;
  final Uint8List _inBuf = Uint8List(1 << 16);
  int _inPos = 0;
  int _inLen = 0;
  bool _inEof = false;
  int _overrun = 0;
  int _bitBuf = 0;
  int _bitCount = 0;

  // the current file
  int _fileStart = 0;
  int _fileEnd = 0;
  int _outPos = 0;
  OutStream? _out;
  bool _newFile = false;
  bool _ppmdEod = false;

  /// Decodes one file of [unpSize] bytes from [src] into [out]. [unpVer]
  /// is the unpack version of the file header, [dictSize] its dictionary
  /// size; [solid] continues the state of the previous file.
  void decodeFile(InStream src, OutStream out, int unpSize, int unpVer,
      int dictSize, bool solid) {
    if (unpVer != 29 && unpVer != 36) {
      throw SevenZipException(
          'RAR: the compression method of unpack version $unpVer '
          '(RAR 1.5 / 2.0) is not supported',
          SevenZipError.unsupportedMethod);
    }
    if (!solid || _win.isEmpty) {
      var size = 0x10000;
      while (size < dictSize) {
        size <<= 1;
      }
      if (size > 0x400000) size = 0x400000;
      if (_win.length != size) {
        _win = Uint8List(size);
      } else {
        _win.fillRange(0, size, 0);
      }
      _mask = size - 1;
      _pos = 0;
      _lengthTable.fillRange(0, _huffmanTableSize, 0);
      _oldOffset.fillRange(0, 4, 0);
      _lastLength = 0;
      _lastOffset = 0;
      _lastLowOffset = 0;
      _numLowOffsetRepeats = 0;
      _startNewTable = true;
      _codesValid = false;
      _isPpmdBlock = false;
      _ppmdValid = false;
      _progs.clear();
      _stack.clear();
      _filterStart = _noFilter;
      _lastFilterNum = 0;
    }
    // a PPMd block ended with its end marker: the next file of a solid
    // archive starts with new tables
    if (_ppmdEod) _startNewTable = true;
    _src = src;
    _inPos = 0;
    _inLen = 0;
    _inEof = false;
    _overrun = 0;
    _bitBuf = 0;
    _bitCount = 0;
    _out = out;
    _fileStart = _pos;
    _fileEnd = _pos + unpSize;
    _outPos = _pos;
    _newFile = false;
    _ppmdEod = false;
    try {
      _decode();
    } finally {
      _src = null;
      _out = null;
    }
  }

  // read_data_compressed: decodes and writes up to the end of the file
  void _decode() {
    final winSize = _win.length;
    while (_outPos < _fileEnd) {
      if (_stack.isNotEmpty && _filterStart == _outPos) {
        _runFilters();
        continue;
      }
      if (_newFile || _ppmdEod) break;
      if (_startNewTable) _parseCodes();
      if (_isPpmdBlock) {
        _decodePpmd(_outPos + (winSize >> 1));
      } else {
        var end = _outPos + winSize;
        if (winSize > 260) end -= 260;
        if (_filterStart < end) end = _filterStart;
        _expand(end);
      }
      var to = _pos;
      if (to > _fileEnd) to = _fileEnd;
      if (_filterStart < to) to = _filterStart;
      _write(_outPos, to);
      _outPos = to;
    }
    if (_outPos < _fileEnd) {
      throw const SevenZipException(
          'RAR: unexpected end of data', SevenZipError.unexpectedEnd);
    }
  }

  void _write(int from, int to) {
    if (to <= from) return;
    final out = _out!;
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

  // The bit reader (rar_br).

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

  // rar_br_fillup
  @pragma('vm:prefer-inline')
  void _need(int n) {
    while (_bitCount < n) {
      _bitBuf = ((_bitBuf << 8) | _readByte()) & 0xFFFFFFFFFFFF;
      _bitCount += 8;
    }
  }

  // rar_br_bits (after rar_br_read_ahead)
  @pragma('vm:prefer-inline')
  int _peek(int n) {
    _need(n);
    return (_bitBuf >> (_bitCount - n)) & ((1 << n) - 1);
  }

  @pragma('vm:prefer-inline')
  int _bits(int n) {
    final v = _peek(n);
    _bitCount -= n;
    return v;
  }

  // ppmd_read / rar_decode_byte
  int _byte() => _bits(8);

  // The LZSS window.

  // lzss_emit_match
  void _emitMatch(int offset, int length) {
    final w = _win;
    final mask = _mask;
    final pos = _pos;
    final end = pos + length;
    if (end > _fileEnd + 0x10000) throw _bad();
    final d = pos & mask;
    final s = (pos - offset) & mask;
    if (offset >= length && d + length <= w.length && s + length <= w.length) {
      w.setRange(d, d + length, w, s);
    } else {
      for (var i = 0; i < length; i++) {
        w[(pos + i) & mask] = w[(pos + i - offset) & mask];
      }
    }
    _pos = end;
  }

  // read_next_symbol
  int _symbol(_HuffmanCode code) {
    if (!code.hasTable) code.makeTable();
    final bits = _peek(code.tableSize);
    final length = code.tableLength[bits];
    final value = code.tableValue[bits];
    if (length <= code.tableSize) {
      _bitCount -= length;
      return value;
    }
    _bitCount -= code.tableSize;
    var node = value;
    final tree = code.tree;
    while (tree[node * 2] != tree[node * 2 + 1]) {
      final bit = _bits(1);
      final next = tree[node * 2 + bit];
      if (next < 0) throw _bad('invalid prefix code');
      node = next;
    }
    return tree[node * 2];
  }

  // parse_codes
  void _parseCodes() {
    _codesValid = false;
    // skip to the next byte
    _bitCount &= ~7;
    _isPpmdBlock = _bits(1) != 0;
    if (_isPpmdBlock) {
      final ppmdFlags = _bits(7);
      var memSize = 0;
      if ((ppmdFlags & 0x20) != 0) memSize = (_bits(8) + 1) << 20;
      int? initEsc;
      if ((ppmdFlags & 0x40) != 0) {
        initEsc = _bits(8);
        _ppmdEscape = initEsc;
      } else {
        _ppmdEscape = 2;
      }
      if ((ppmdFlags & 0x20) != 0) {
        var maxOrder = (ppmdFlags & 0x1F) + 1;
        if (maxOrder > 16) maxOrder = 16 + (maxOrder - 16) * 3;
        if (maxOrder == 1) throw _bad('bad PPMd order');
        final p = _ppmd ??= Ppmd7();
        p.alloc(memSize);
        if (initEsc != null) p.initEsc = initEsc;
        final rc = _rc = RarPpmdRangeDecoder(_byte);
        if (!rc.init()) throw _bad('bad PPMd range decoder');
        p.init(maxOrder);
        _ppmdValid = true;
      } else {
        if (!_ppmdValid) throw _bad('invalid PPMd sequence');
        if (initEsc != null) _ppmd!.initEsc = initEsc;
        final rc = _rc = RarPpmdRangeDecoder(_byte);
        if (!rc.init()) throw _bad('bad PPMd range decoder');
      }
    } else {
      _lastLowOffset = 0;
      _numLowOffsetRepeats = 0;
      if (_bits(1) == 0) _lengthTable.fillRange(0, _huffmanTableSize, 0);
      final bitLengths = Uint8List(_maxSymbols);
      for (var i = 0; i < _maxSymbols;) {
        bitLengths[i++] = _bits(4);
        if (bitLengths[i - 1] == 0xF) {
          final zeroCount = _bits(4);
          if (zeroCount != 0) {
            i--;
            for (var j = 0; j < zeroCount + 2 && i < _maxSymbols; j++) {
              bitLengths[i++] = 0;
            }
          }
        }
      }
      _preCode.create(bitLengths, 0, _maxSymbols, _maxSymbolLength);
      final lt = _lengthTable;
      for (var i = 0; i < _huffmanTableSize;) {
        final val = _symbol(_preCode);
        if (val < 16) {
          lt[i] = (lt[i] + val) & 0xF;
          i++;
        } else if (val < 18) {
          if (i == 0) throw _bad();
          final n = val == 16 ? _bits(3) + 3 : _bits(7) + 11;
          for (var j = 0; j < n && i < _huffmanTableSize; j++) {
            lt[i] = lt[i - 1];
            i++;
          }
        } else {
          final n = val == 18 ? _bits(3) + 3 : _bits(7) + 11;
          for (var j = 0; j < n && i < _huffmanTableSize; j++) {
            lt[i++] = 0;
          }
        }
      }
      _mainCode.create(lt, 0, _mainCodeSize, _maxSymbolLength);
      _offsetCode.create(lt, _mainCodeSize, _offsetCodeSize, _maxSymbolLength);
      _lowOffsetCode.create(lt, _mainCodeSize + _offsetCodeSize,
          _lowOffsetCodeSize, _maxSymbolLength);
      _lengthCode.create(
          lt,
          _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize,
          _lengthCodeSize,
          _maxSymbolLength);
      _codesValid = true;
    }
    _startNewTable = false;
  }

  // the PPMd part of read_data_compressed: decodes up to [limit]
  void _decodePpmd(int limit) {
    final p = _ppmd!;
    final rc = _rc!;
    final esc = _ppmdEscape;
    while (_pos < limit && _pos < _fileEnd) {
      final sym = rarPpmdDecodeSymbol(p, rc);
      if (sym < 0) throw _bad('invalid PPMd symbol');
      if (sym != esc) {
        _win[_pos & _mask] = sym;
        _pos++;
        continue;
      }
      final code = rarPpmdDecodeSymbol(p, rc);
      if (code < 0) throw _bad('invalid PPMd symbol');
      switch (code) {
        case 0:
          _startNewTable = true;
          return;
        case 2:
          _ppmdEod = true;
          return;
        case 3:
          // a filter, its bytes coded like in LZ blocks (read_filter)
          _readFilter(() {
            final c = rarPpmdDecodeSymbol(p, rc);
            if (c < 0) throw _bad('invalid PPMd symbol');
            return c;
          });
        case 4:
          var offs = 0;
          for (var i = 2; i >= 0; i--) {
            final c = rarPpmdDecodeSymbol(p, rc);
            if (c < 0) throw _bad('invalid PPMd symbol');
            offs |= c << (i * 8);
          }
          final length = rarPpmdDecodeSymbol(p, rc);
          if (length < 0) throw _bad('invalid PPMd symbol');
          _emitMatch(offs + 2, length + 32);
        case 5:
          final length = rarPpmdDecodeSymbol(p, rc);
          if (length < 0) throw _bad('invalid PPMd symbol');
          _emitMatch(1, length + 4);
        default:
          _win[_pos & _mask] = sym;
          _pos++;
      }
    }
  }

  // expand: decodes LZ symbols up to [end] (or a new table, a PPMd
  // block, the end of the file)
  void _expand(int end) {
    if (_filterStart < end) end = _filterStart;
    if (!_codesValid) throw _bad('no Huffman tables');
    while (_pos < end) {
      if (_isPpmdBlock) return;
      final symbol = _symbol(_mainCode);
      if (symbol < 256) {
        _win[_pos & _mask] = symbol;
        _pos++;
        continue;
      }
      int offs, len;
      if (symbol == 256) {
        final newFile = _bits(1) == 0;
        if (newFile) {
          _newFile = true;
          _startNewTable = _bits(1) != 0;
          return;
        }
        _parseCodes();
        if (_isPpmdBlock) return;
        continue;
      } else if (symbol == 257) {
        _readFilter(_byte);
        if (_filterStart < end) end = _filterStart;
        continue;
      } else if (symbol == 258) {
        if (_lastLength == 0) continue;
        offs = _lastOffset;
        len = _lastLength;
      } else if (symbol <= 262) {
        final offsIndex = symbol - 259;
        offs = _oldOffset[offsIndex];
        final lenSymbol = _symbol(_lengthCode);
        if (lenSymbol >= _lengthBases.length) throw _bad();
        len = _lengthBases[lenSymbol] + 2;
        if (_lengthBits[lenSymbol] > 0) len += _bits(_lengthBits[lenSymbol]);
        for (var i = offsIndex; i > 0; i--) {
          _oldOffset[i] = _oldOffset[i - 1];
        }
        _oldOffset[0] = offs;
      } else if (symbol <= 270) {
        offs = _shortBases[symbol - 263] + 1;
        if (_shortBits[symbol - 263] > 0) {
          offs += _bits(_shortBits[symbol - 263]);
        }
        len = 2;
        for (var i = 3; i > 0; i--) {
          _oldOffset[i] = _oldOffset[i - 1];
        }
        _oldOffset[0] = offs;
      } else {
        if (symbol - 271 >= _lengthBases.length) throw _bad();
        len = _lengthBases[symbol - 271] + 3;
        if (_lengthBits[symbol - 271] > 0) {
          len += _bits(_lengthBits[symbol - 271]);
        }
        final offsSymbol = _symbol(_offsetCode);
        if (offsSymbol >= _offsetBases.length) throw _bad();
        offs = _offsetBases[offsSymbol] + 1;
        final ob = _offsetBits[offsSymbol];
        if (ob > 0) {
          if (offsSymbol > 9) {
            if (ob > 4) offs += _bits(ob - 4) << 4;
            if (_numLowOffsetRepeats > 0) {
              _numLowOffsetRepeats--;
              offs += _lastLowOffset;
            } else {
              final lowOffsetSymbol = _symbol(_lowOffsetCode);
              if (lowOffsetSymbol == 16) {
                _numLowOffsetRepeats = 15;
                offs += _lastLowOffset;
              } else {
                offs += lowOffsetSymbol;
                _lastLowOffset = lowOffsetSymbol;
              }
            }
          } else {
            offs += _bits(ob);
          }
        }
        if (offs >= 0x40000) len++;
        if (offs >= 0x2000) len++;
        for (var i = 3; i > 0; i--) {
          _oldOffset[i] = _oldOffset[i - 1];
        }
        _oldOffset[0] = offs;
      }
      _lastOffset = offs;
      _lastLength = len;
      _emitMatch(offs, len);
    }
  }

  // The filters.

  // read_filter, with the bytes from the LZ bit stream or from PPMd
  void _readFilter(int Function() byte) {
    final flags = byte();
    var length = (flags & 0x07) + 1;
    if (length == 7) {
      length = byte() + 7;
    } else if (length == 8) {
      length = byte() << 8;
      length |= byte();
    }
    final code = Uint8List(length);
    for (var i = 0; i < length; i++) {
      code[i] = byte();
    }
    if (!_parseFilter(code, length, flags)) throw _bad('bad filter');
  }

  // parse_filter
  bool _parseFilter(Uint8List bytes, int length, int flags) {
    final br = _MemBitReader(bytes, length);
    final numProgs = _progs.length;
    int num;
    if ((flags & 0x80) != 0) {
      num = br.nextRarVmNumber();
      if (num == 0) {
        _stack.clear();
        _progs.clear();
      } else {
        num--;
      }
      if (num > numProgs) return false;
      _lastFilterNum = num;
    } else {
      num = _lastFilterNum;
    }
    _ProgramCode? prog = num < _progs.length ? _progs[num] : null;
    if (prog != null) prog.usageCount++;
    var blockStartPos = br.nextRarVmNumber() + _pos;
    if ((flags & 0x40) != 0) blockStartPos += 258;
    int blockLength;
    if ((flags & 0x20) != 0) {
      blockLength = br.nextRarVmNumber();
    } else {
      blockLength = prog?.oldFilterLength ?? 0;
    }
    if (blockLength > _win.length) return false;
    final registers = Uint32List(8);
    registers[3] = _programSystemGlobalAddress;
    registers[4] = blockLength;
    registers[5] = prog?.usageCount ?? 0;
    registers[7] = _vmMemorySize;
    if ((flags & 0x10) != 0) {
      final mask = br.getBits(7);
      for (var i = 0; i < 7; i++) {
        if ((mask & (1 << i)) != 0) registers[i] = br.nextRarVmNumber();
      }
    }
    if (prog == null) {
      final len = br.nextRarVmNumber();
      if (len == 0 || len > 0x10000) return false;
      final byteCode = Uint8List(len);
      for (var i = 0; i < len; i++) {
        byteCode[i] = br.getBits(8);
      }
      prog = _compileProgram(byteCode);
      if (prog == null) return false;
      _progs.add(prog);
    }
    prog.oldFilterLength = blockLength;
    Uint8List? globalData;
    var globalDataLen = 0;
    if ((flags & 0x08) != 0) {
      globalDataLen = br.nextRarVmNumber();
      if (globalDataLen > _programUserGlobalSize) return false;
      globalData = Uint8List(globalDataLen + _programSystemGlobalSize);
      for (var i = 0; i < globalDataLen; i++) {
        globalData[i + _programSystemGlobalSize] = br.getBits(8);
      }
    }
    if (br.atEof) return false;
    // create_filter
    final gLen = globalDataLen > _programSystemGlobalSize
        ? globalDataLen
        : _programSystemGlobalSize;
    final g = Uint8List(gLen);
    if (globalData != null) {
      g.setRange(0, globalDataLen, globalData);
    }
    final filter = _Filter(prog, g, blockStartPos, blockLength);
    filter.initialRegisters.setAll(0, registers);
    for (var i = 0; i < 7; i++) {
      _le32(g, i * 4, registers[i]);
    }
    _le32(g, 0x1C, blockLength);
    _le32(g, 0x20, 0);
    _le32(g, 0x2C, prog.usageCount);
    _stack.add(filter);
    if (_stack.length == 1) _filterStart = blockStartPos;
    return true;
  }

  static void _le32(Uint8List b, int o, int v) {
    b[o] = v & 0xFF;
    b[o + 1] = (v >> 8) & 0xFF;
    b[o + 2] = (v >> 16) & 0xFF;
    b[o + 3] = (v >> 24) & 0xFF;
  }

  static int _rd32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  // compile_program
  static _ProgramCode? _compileProgram(Uint8List bytes) {
    final length = bytes.length;
    var xor = 0;
    for (var i = 1; i < length; i++) {
      xor ^= bytes[i];
    }
    if (length == 0 || xor != bytes[0]) return null;
    final br = _MemBitReader(bytes, length)..offset = 1;
    final prog = _ProgramCode();
    prog.fingerprint = Crc32.of(bytes) | (length << 32);
    if (br.getBits(1) != 0) {
      final staticDataLen = br.nextRarVmNumber();
      if (staticDataLen >= _vmMemorySize) return null;
      final sd = Uint8List(staticDataLen + 1);
      for (var i = 0; i < sd.length; i++) {
        sd[i] = br.getBits(8);
      }
      prog.staticData = sd;
    }
    return prog;
  }

  // run_filters
  void _runFilters() {
    var filter = _stack.first;
    final start = _filterStart;
    final end = start + filter.blockLength;
    _filterStart = _noFilter;
    // the block may be coded with LZ or PPMd (a filter declared in an LZ
    // block can cover data of a following PPMd block)
    while (_pos < end && !_newFile && !_ppmdEod) {
      if (_startNewTable) _parseCodes();
      if (_isPpmdBlock) {
        _decodePpmd(end);
      } else {
        _expand(end);
      }
    }
    if (_stack.isEmpty || !identical(_stack.first, filter)) {
      throw _bad('filter stack changed');
    }
    if (_pos < end) throw _bad('filter block was not fully decompressed');
    final vm = _vm ??= Uint8List(_vmMemorySize + 4);
    if (filter.blockLength > _vmMemorySize) throw _bad();
    // copy_from_lzss_window
    {
      final a = start & _mask;
      final n = filter.blockLength;
      if (a + n <= _win.length) {
        vm.setRange(0, n, _win, a);
      } else {
        final n1 = _win.length - a;
        vm.setRange(0, n1, _win, a);
        vm.setRange(n1, n, _win, 0);
      }
    }
    _executeFilter(filter, vm, start - _fileStart);
    var lastAddress = filter.filteredBlockAddress;
    var lastLength = filter.filteredBlockLength;
    _stack.removeAt(0);
    while (_stack.isNotEmpty &&
        _stack.first.blockStartPos == start &&
        _stack.first.blockLength == lastLength) {
      filter = _stack.first;
      vm.setRange(0, lastLength, vm, lastAddress);
      _executeFilter(filter, vm, start - _fileStart);
      lastAddress = filter.filteredBlockAddress;
      lastLength = filter.filteredBlockLength;
      _stack.removeAt(0);
    }
    if (_stack.isNotEmpty) {
      if (_stack.first.blockStartPos < end) throw _bad();
      _filterStart = _stack.first.blockStartPos;
    }
    // the filtered bytes, cut at the end of the file
    var n = lastLength;
    if (_outPos + n > _fileEnd) n = _fileEnd - _outPos;
    if (n > 0) _out!.write(vm, lastAddress, n);
    _outPos = end;
  }

  // execute_filter
  void _executeFilter(_Filter f, Uint8List vm, int pos) {
    final fp = f.prog.fingerprint;
    bool ok;
    if (fp == 0x1D0E06077D) {
      ok = _filterDelta(f, vm);
    } else if (fp == 0x35AD576887) {
      ok = _filterE8(f, vm, pos, false);
    } else if (fp == 0x393CD7E57E) {
      ok = _filterE8(f, vm, pos, true);
    } else if (fp == 0x951C2C5DC8) {
      ok = _filterRgb(f, vm);
    } else if (fp == 0xD8BC85E701) {
      ok = _filterAudio(f, vm);
    } else {
      throw const SevenZipException('RAR: unsupported RAR VM filter program',
          SevenZipError.unsupportedMethod);
    }
    if (!ok) throw _bad('bad filter');
  }

  // execute_filter_delta
  static bool _filterDelta(_Filter f, Uint8List vm) {
    final length = f.initialRegisters[4];
    final numChannels = f.initialRegisters[0];
    if (length > _programWorkSize ~/ 2 ||
        numChannels == 0 ||
        numChannels > 128) {
      return false;
    }
    var src = 0;
    final dst = length;
    for (var i = 0; i < numChannels; i++) {
      var lastByte = 0;
      for (var idx = i; idx < length; idx += numChannels) {
        if (src >= dst) return false;
        lastByte = (lastByte - vm[src++]) & 0xFF;
        vm[dst + idx] = lastByte;
      }
    }
    f.filteredBlockAddress = length;
    f.filteredBlockLength = length;
    return true;
  }

  // execute_filter_e8
  static bool _filterE8(_Filter f, Uint8List vm, int pos, bool e9also) {
    final length = f.initialRegisters[4];
    const fileSize = 0x1000000;
    if (length > _programWorkSize || length <= 4) return false;
    for (var i = 0; i <= length - 5; i++) {
      if (vm[i] == 0xE8 || (e9also && vm[i] == 0xE9)) {
        final currPos = (pos + i + 1) & 0xFFFFFFFF;
        var address = _rd32(vm, i + 1);
        if (address >= 0x80000000) address -= 0x100000000;
        if (address < 0 && currPos >= -address) {
          _le32(vm, i + 1, (address + fileSize) & 0xFFFFFFFF);
        } else if (address >= 0 && address < fileSize) {
          _le32(vm, i + 1, (address - currPos) & 0xFFFFFFFF);
        }
        i += 4;
      }
    }
    f.filteredBlockAddress = 0;
    f.filteredBlockLength = length;
    return true;
  }

  // execute_filter_rgb
  static bool _filterRgb(_Filter f, Uint8List vm) {
    final stride = f.initialRegisters[0];
    final byteOffset = f.initialRegisters[1];
    final blockLength = f.initialRegisters[4];
    if (blockLength > _programWorkSize ~/ 2 ||
        stride > blockLength ||
        blockLength < 3 ||
        byteOffset > 2) {
      return false;
    }
    var src = 0;
    final dst = blockLength;
    for (var i = 0; i < 3; i++) {
      var byte = 0;
      var prev = dst + i - stride;
      for (var j = i; j < blockLength; j += 3) {
        if (src >= dst) return false;
        if (prev >= dst) {
          final p0 = vm[prev];
          final p3 = vm[prev + 3];
          final delta1 = (p3 - p0).abs();
          final delta2 = (byte - p0).abs();
          final delta3 = (p3 - p0 + byte - p0).abs();
          if (delta1 > delta2 || delta1 > delta3) {
            byte = delta2 <= delta3 ? p3 : p0;
          }
        }
        byte = (byte - vm[src++]) & 0xFF;
        vm[dst + j] = byte;
        prev += 3;
      }
    }
    for (var i = byteOffset; i < blockLength - 2; i += 3) {
      vm[dst + i] = (vm[dst + i] + vm[dst + i + 1]) & 0xFF;
      vm[dst + i + 2] = (vm[dst + i + 2] + vm[dst + i + 1]) & 0xFF;
    }
    f.filteredBlockAddress = blockLength;
    f.filteredBlockLength = blockLength;
    return true;
  }

  // execute_filter_audio
  static bool _filterAudio(_Filter f, Uint8List vm) {
    final length = f.initialRegisters[4];
    final numChannels = f.initialRegisters[0];
    if (length > _programWorkSize ~/ 2 ||
        numChannels == 0 ||
        numChannels > 128) {
      return false;
    }
    var src = 0;
    final dst = length;
    final weight = Int32List(5);
    final delta = Int32List(4);
    final error = Int32List(11);
    for (var i = 0; i < numChannels; i++) {
      weight.fillRange(0, 5, 0);
      delta.fillRange(0, 4, 0);
      error.fillRange(0, 11, 0);
      var lastDelta = 0;
      var count = 0;
      var lastByte = 0;
      for (var j = i; j < length; j += numChannels) {
        if (src >= dst) return false;
        var d = vm[src++];
        if (d >= 0x80) d -= 0x100; // int8_t delta
        delta[2] = delta[1];
        delta[1] = _s16(lastDelta - delta[0]);
        delta[0] = lastDelta;
        final predByte = ((8 * lastByte +
                    weight[0] * delta[0] +
                    weight[1] * delta[1] +
                    weight[2] * delta[2]) >>
                3) &
            0xFF;
        final byte = (predByte - d) & 0xFF;
        final predError = d * 8;
        error[0] += predError.abs();
        error[1] += (predError - delta[0]).abs();
        error[2] += (predError + delta[0]).abs();
        error[3] += (predError - delta[1]).abs();
        error[4] += (predError + delta[1]).abs();
        error[5] += (predError - delta[2]).abs();
        error[6] += (predError + delta[2]).abs();
        var ld = (byte - lastByte) & 0xFF;
        if (ld >= 0x80) ld -= 0x100; // int8_t lastdelta
        lastDelta = ld;
        lastByte = byte;
        vm[dst + j] = byte;
        if ((count++ & 0x1F) == 0) {
          var idx = 0;
          for (var k = 1; k < 7; k++) {
            if (error[k] < error[idx]) idx = k;
          }
          error.fillRange(0, 11, 0);
          switch (idx) {
            case 1:
              if (weight[0] >= -16) weight[0]--;
            case 2:
              if (weight[0] < 16) weight[0]++;
            case 3:
              if (weight[1] >= -16) weight[1]--;
            case 4:
              if (weight[1] < 16) weight[1]++;
            case 5:
              if (weight[2] >= -16) weight[2]--;
            case 6:
              if (weight[2] < 16) weight[2]++;
          }
        }
      }
    }
    f.filteredBlockAddress = length;
    f.filteredBlockLength = length;
    return true;
  }

  // int16_t wraparound of the audio state
  static int _s16(int v) {
    v &= 0xFFFF;
    return v >= 0x8000 ? v - 0x10000 : v;
  }
}
