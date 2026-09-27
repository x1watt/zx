// The RAR5 decompressor (compression algorithm versions 0 and 1, methods 1
// to 5): port of the decoding part of libarchive's
// archive_read_support_format_rar5.c (Grzegorz Antoniak, BSD 2-clause, see
// LICENSE): the block headers, the Huffman tables, the LZ decoding with the
// distance cache and the DELTA, E8, E8E9 and ARM filters.
//
// Version 1 (RAR 7.0, dictionaries above 4 GB) is not in libarchive; it
// follows nwaples/rardecode (decode50.go, BSD 2-clause, see LICENSE): the
// distance table has 80 slots instead of 64 (offsetSize7, tableSize7), so
// that a distance can have up to 38 extra bits, and nothing else changes.
//
// The C reader works on libarchive's read-ahead buffers and hands out
// window slices; here the packed data is an [InStream] and the output an
// [OutStream], and the window is flushed whenever half of it is pending
// (the same rule do_uncompress_block uses to return early). Positions are
// absolute counts over the whole solid stream (the C solid_offset plus
// write_ptr).

import 'dart:typed_data';

import '../../io/streams.dart';

const int _huffBC = 20;
const int _huffNC = 306;
const int _huffDC = 64;
const int _huffLDC = 16;
const int _huffRC = 44;
const int _huffTableSize = _huffNC + _huffDC + _huffRC + _huffLDC;

/// The distance table of compression algorithm version 1 (offsetSize7).
const int _huffDC7 = 80;
const int _huffTableSize7 = _huffNC + _huffDC7 + _huffRC + _huffLDC;

/// FILTER_TYPE
abstract final class Rar5FilterType {
  static const delta = 0;
  static const e8 = 1;
  static const e8e9 = 2;
  static const arm = 3;
}

/// struct decode_table.
final class Rar5DecodeTable {
  int size = 0;
  final Int32List decodeLen = Int32List(16);
  final Uint32List decodePos = Uint32List(16);
  int quickBits = 0;
  final Uint8List quickLen = Uint8List(1 << 10);
  final Uint16List quickNum = Uint16List(1 << 10);
  final Uint16List decodeNum = Uint16List(_huffNC);

  // create_decode_tables: false when the lengths are over-subscribed
  bool create(Uint8List bitLength, int off, int size) {
    final lc = Int32List(16);
    final decodePosClone = Uint32List(16);
    decodeNum.fillRange(0, decodeNum.length, 0);
    this.size = size;
    quickBits = size == _huffNC ? 10 : 7;
    for (var i = 0; i < size; i++) {
      lc[bitLength[off + i] & 15]++;
    }
    lc[0] = 0;
    decodePos[0] = 0;
    decodeLen[0] = 0;
    var upperLimit = 0;
    for (var i = 1; i < 16; i++) {
      upperLimit += lc[i];
      decodeLen[i] = upperLimit << (16 - i);
      decodePos[i] = decodePos[i - 1] + lc[i - 1];
      upperLimit <<= 1;
    }
    if (upperLimit > 65536) return false;
    decodePosClone.setAll(0, decodePos);
    for (var i = 0; i < size; i++) {
      final clen = bitLength[off + i] & 15;
      if (clen > 0) {
        final lastPos = decodePosClone[clen];
        decodeNum[lastPos] = i;
        decodePosClone[clen]++;
      }
    }
    final quickDataSize = 1 << quickBits;
    var curLen = 1;
    for (var code = 0; code < quickDataSize; code++) {
      final bitField = code << (16 - quickBits);
      while (curLen < 16 && bitField >= decodeLen[curLen]) {
        curLen++;
      }
      quickLen[code] = curLen;
      var dist = bitField - decodeLen[curLen - 1];
      dist >>= (16 - curLen);
      final pos = decodePos[curLen & 15] + dist;
      if (curLen < 16 && pos < size) {
        quickNum[code] = decodeNum[pos];
      } else {
        quickNum[code] = 0;
      }
    }
    return true;
  }
}

class _Filter {
  final int type;
  final int channels;
  final int blockStart; // absolute
  final int blockLength;
  _Filter(this.type, this.channels, this.blockStart, this.blockLength);
}

SevenZipException _dataError(String m) =>
    SevenZipException('RAR5: $m', SevenZipError.data);

/// The RAR5 decoder state; it lives across the files of a solid stream.
final class Rar5Decoder {
  Uint8List _win = Uint8List(0);
  int _winMask = 0;
  int _winSize = 0;

  int _wr = 0; // absolute write position
  int _written = 0; // absolute position flushed to the output
  int _fileStart = 0;
  int _fileEnd = 0;

  final Int64List _dist = Int64List(4);
  int _lastLen = 0;
  bool _tablesRead = false;

  final Rar5DecodeTable _bd = Rar5DecodeTable();
  final Rar5DecodeTable _ld = Rar5DecodeTable();
  final Rar5DecodeTable _dd = Rar5DecodeTable();
  final Rar5DecodeTable _ldd = Rar5DecodeTable();
  final Rar5DecodeTable _rd = Rar5DecodeTable();

  final List<_Filter> _filters = [];
  int _lastFilterStart = 0;
  int _lastFilterLength = 0;

  // current block
  Uint8List _blk = Uint8List(0);
  int _blkSize = 0;
  int _in = 0;
  int _bit = 0;
  int _bitSize = 0;

  OutStream? _out;
  Uint8List _filtered = Uint8List(0);

  /// The window size that decoding needs: a power of two that holds the
  /// dictionary ([dictSize], which is not a power of two for some version 1
  /// sizes), reduced when the data to decode ([dataSize]: the file, or all
  /// the files of a solid stream) is smaller than it.
  static int windowSizeFor(int dictSize, int dataSize) {
    var w = 1 << 17;
    while (w < dictSize && w < dataSize * 2) {
      w <<= 1;
    }
    return w;
  }

  /// The number of distance slots: 64, or 80 for algorithm version 1.
  int _numDC = _huffDC;

  /// Decodes one file of [unpSize] bytes from [src] (its packed data) into
  /// [out] (null to only advance the solid state). [solid] continues the
  /// state of the previous file. [winSize] is a power of two.
  /// [algoVersion] is the compression algorithm version of the file header
  /// (0 or 1).
  void decodeFile(
      InStream src, OutStream? out, int unpSize, int winSize, bool solid,
      [int algoVersion = 0]) {
    // decoder50.init: the table layout of the version
    final numDC = algoVersion == 1 ? _huffDC7 : _huffDC;
    if (numDC != _numDC) {
      _numDC = numDC;
      _tablesRead = false;
    }
    if (!solid || _win.isEmpty) {
      if (_win.length != winSize) {
        _win = Uint8List(winSize);
      } else {
        _win.fillRange(0, winSize, 0);
      }
      _winSize = winSize;
      _winMask = winSize - 1;
      _wr = 0;
      _written = 0;
      _tablesRead = false;
      _dist.fillRange(0, 4, 0);
      _lastLen = 0;
    } else if (winSize > _winSize) {
      throw _dataError('the window size changes inside a solid stream');
    }
    _out = out;
    _fileStart = _wr;
    _fileEnd = _wr + unpSize;
    _written = _wr;
    _filters.clear();
    _lastFilterStart = 0;
    _lastFilterLength = 0;
    if (unpSize == 0) return;
    try {
      for (;;) {
        final last = _readBlock(src);
        _decodeBlock();
        if (last) break;
      }
      _flush();
      if (_wr != _fileEnd || _filters.isNotEmpty) {
        throw _dataError('unexpected end of the compressed data');
      }
    } finally {
      _out = null;
    }
  }

  final Uint8List _hdr = Uint8List(6);

  // parse_block_header + the block read of process_block. Returns the
  // last block flag.
  bool _readBlock(InStream src) {
    final h = _hdr;
    if (readFully(src, h, 0, 3) != 3) {
      throw const SevenZipException(
          'RAR5: unexpected end of data', SevenZipError.unexpectedEnd);
    }
    final flags = h[0];
    final byteCount = (flags >> 3) & 7;
    if (byteCount > 2) throw _dataError('unsupported block header size');
    if (byteCount > 0) readExactly(src, h, 3, byteCount);
    var blockSize = h[2];
    if (byteCount >= 1) blockSize |= h[3] << 8;
    if (byteCount >= 2) blockSize |= h[4] << 16;
    final cks = (0x5A ^
            flags ^
            (blockSize & 0xFF) ^
            ((blockSize >> 8) & 0xFF) ^
            ((blockSize >> 16) & 0xFF)) &
        0xFF;
    if (cks != h[1]) throw _dataError('block checksum error');
    if (_blk.length < blockSize + 16) _blk = Uint8List(blockSize + 16 + 1024);
    readExactly(src, _blk, 0, blockSize);
    _blk.fillRange(blockSize, blockSize + 16, 0);
    _blkSize = blockSize;
    _in = 0;
    _bit = 0;
    _bitSize = 1 + (flags & 7);
    if ((flags & 0x80) != 0) {
      _parseTables();
      _tablesRead = true;
    }
    if (!_tablesRead) throw _dataError('no Huffman tables');
    return (flags & 0x40) != 0;
  }

  // read_bits_16
  @pragma('vm:prefer-inline')
  int _bits16() {
    final b = _blk;
    final i = _in;
    return (((b[i] << 16) | (b[i + 1] << 8) | b[i + 2]) >> (8 - _bit)) & 0xFFFF;
  }

  // read_bits_32
  int _bits32() {
    final b = _blk;
    final i = _in;
    final v = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
    return (((v << _bit) | (b[i + 4] >> (8 - _bit))) & 0xFFFFFFFF);
  }

  // skip_bits
  @pragma('vm:prefer-inline')
  void _skip(int n) {
    final nb = _bit + n;
    _in += nb >> 3;
    _bit = nb & 7;
  }

  // read_consume_bits (n up to 16)
  int _getBits(int n) {
    final v = _bits16() >> (16 - n);
    _skip(n);
    return v;
  }

  void _checkIn() {
    if (_in >= _blkSize) throw _dataError('premature end of a block');
  }

  // decode_number
  @pragma('vm:prefer-inline')
  int _decodeNumber(Rar5DecodeTable t) {
    final bitField = _bits16() & 0xFFFE;
    final qb = t.quickBits;
    if (bitField < t.decodeLen[qb]) {
      final code = bitField >> (16 - qb);
      _skip(t.quickLen[code]);
      return t.quickNum[code];
    }
    var bits = 15;
    for (var i = qb + 1; i < 15; i++) {
      if (bitField < t.decodeLen[i]) {
        bits = i;
        break;
      }
    }
    _skip(bits);
    var dist = bitField - t.decodeLen[bits - 1];
    dist >>= (16 - bits);
    var pos = t.decodePos[bits] + dist;
    if (pos >= t.size) pos = 0;
    return t.decodeNum[pos];
  }

  // parse_tables
  void _parseTables() {
    final bitLength = Uint8List(_huffBC);
    final numDC = _numDC;
    final tableSize =
        numDC == _huffDC7 ? _huffTableSize7 : _huffTableSize;
    final table = Uint8List(tableSize);
    final p = _blk;
    var nibbleMask = 0xF0;
    var nibbleShift = 4;
    var i = 0;
    for (var w = 0; w < _huffBC;) {
      if (i >= _blkSize) throw _dataError('truncated Huffman tables');
      var value = (p[i] & nibbleMask) >> nibbleShift;
      if (nibbleMask == 0x0F) ++i;
      nibbleMask ^= 0xFF;
      nibbleShift ^= 4;
      if (value == 15) {
        value = (p[i] & nibbleMask) >> nibbleShift;
        if (nibbleMask == 0x0F) ++i;
        nibbleMask ^= 0xFF;
        nibbleShift ^= 4;
        if (value == 0) {
          bitLength[w++] = 15;
        } else {
          for (var k = 0; k < value + 2 && w < _huffBC; k++) {
            bitLength[w++] = 0;
          }
        }
      } else {
        bitLength[w++] = value;
      }
    }
    _in = i;
    _bit = nibbleShift ^ 4;
    if (!_bd.create(bitLength, 0, _huffBC)) {
      throw _dataError('bad Huffman tables');
    }
    for (i = 0; i < tableSize;) {
      _checkIn();
      final num = _decodeNumber(_bd);
      if (num < 16) {
        table[i++] = num;
      } else if (num < 18) {
        int n;
        if (num == 16) {
          n = (_bits16() >> 13) + 3;
          _skip(3);
        } else {
          n = (_bits16() >> 9) + 11;
          _skip(7);
        }
        if (i == 0) throw _dataError('bad Huffman tables');
        while (n-- > 0 && i < tableSize) {
          table[i] = table[i - 1];
          i++;
        }
      } else {
        int n;
        if (num == 18) {
          n = (_bits16() >> 13) + 3;
          _skip(3);
        } else {
          n = (_bits16() >> 9) + 11;
          _skip(7);
        }
        while (n-- > 0 && i < tableSize) {
          table[i++] = 0;
        }
      }
    }
    var idx = 0;
    if (!_ld.create(table, idx, _huffNC)) throw _dataError('bad tables');
    idx += _huffNC;
    if (!_dd.create(table, idx, numDC)) throw _dataError('bad tables');
    idx += numDC;
    if (!_ldd.create(table, idx, _huffLDC)) throw _dataError('bad tables');
    idx += _huffLDC;
    if (!_rd.create(table, idx, _huffRC)) throw _dataError('bad tables');
  }

  // parse_filter_data
  int _filterData() {
    final bytes = _getBits(2) + 1;
    var data = 0;
    for (var i = 0; i < bytes; i++) {
      data += (_bits16() >> 8) << (i * 8);
      _skip(8);
    }
    return data;
  }

  // parse_filter
  void _parseFilter() {
    final blockStart = _filterData();
    final blockLength = _filterData();
    final type = _bits16() >> 13;
    _skip(3);
    final start = _wr + blockStart;
    if (blockLength < 4 ||
        blockLength > 0x400000 ||
        blockLength > (_winSize >> 1) ||
        (_lastFilterLength != 0 &&
            start < _lastFilterStart + _lastFilterLength)) {
      throw _dataError('invalid filter');
    }
    var channels = 0;
    if (type == Rar5FilterType.delta) channels = _getBits(5) + 1;
    _filters.add(_Filter(type, channels, start, blockLength));
    _lastFilterStart = start;
    _lastFilterLength = blockLength;
  }

  // decode_code_length
  int _codeLength(int code) {
    var length = 2;
    if (code < 8) return length + code;
    final lbits = code ~/ 4 - 1;
    length += (4 | (code & 3)) << lbits;
    return length + _getBits(lbits);
  }

  // copy_string
  void _copyString(int len, int dist) {
    final wr = _wr;
    if (len > _fileEnd - wr) {
      throw _dataError('unpacked data exceeds the declared size');
    }
    if (dist > wr || dist > _winSize) {
      throw _dataError('distance points before the start of the data');
    }
    final w = _win;
    final mask = _winMask;
    final dst = wr & mask;
    final srcPos = (wr - dist) & mask;
    if (dist >= len && dst + len <= w.length && srcPos + len <= w.length) {
      w.setRange(dst, dst + len, w, srcPos);
    } else {
      for (var i = 0; i < len; i++) {
        w[(wr + i) & mask] = w[(wr + i - dist) & mask];
      }
    }
    _wr = wr + len;
  }

  // do_uncompress_block
  void _decodeBlock() {
    final half = _winSize >> 1;
    final lastByte = _blkSize - 1;
    for (;;) {
      if (_wr - _written > half) _flush();
      if (_in > lastByte || (_in == lastByte && _bit >= _bitSize)) break;
      final num = _decodeNumber(_ld);
      if (num < 256) {
        if (_wr >= _fileEnd) {
          throw _dataError('unpacked data exceeds the declared size');
        }
        _win[_wr & _winMask] = num;
        _wr++;
        continue;
      }
      if (num >= 262) {
        var len = _codeLength(num - 262);
        final distSlot = _decodeNumber(_dd);
        var dist = 1;
        int dbits;
        if (distSlot < 4) {
          dbits = 0;
          dist += distSlot;
        } else {
          dbits = distSlot ~/ 2 - 1;
          dist += (2 | (distSlot & 1)) << dbits;
        }
        if (dbits > 0) {
          if (dbits >= 4) {
            if (dbits > 4) {
              final n = dbits - 4;
              if (n <= 32) {
                final add = _bits32();
                _skip(n);
                dist += (add >> (32 - n)) << 4;
              } else {
                // version 1: up to 34 bits (decodeOffset)
                final hi = _bits32();
                _skip(32);
                final lo = _getBits(n - 32);
                dist += ((hi << (n - 32)) | lo) << 4;
              }
            }
            dist += _decodeNumber(_ldd);
          } else {
            dist += _getBits(dbits);
          }
        }
        if (dist > 0x100) {
          len++;
          if (dist > 0x2000) {
            len++;
            if (dist > 0x40000) len++;
          }
        }
        final d = _dist;
        d[3] = d[2];
        d[2] = d[1];
        d[1] = d[0];
        d[0] = dist;
        _lastLen = len;
        _copyString(len, dist);
        continue;
      }
      if (num == 256) {
        _parseFilter();
        continue;
      }
      if (num == 257) {
        if (_lastLen != 0) _copyString(_lastLen, _dist[0]);
        continue;
      }
      // dist_cache_touch
      final idx = num - 258;
      final d = _dist;
      final dist = d[idx];
      for (var i = idx; i > 0; i--) {
        d[i] = d[i - 1];
      }
      d[0] = dist;
      final lenSlot = _decodeNumber(_rd);
      final len = _codeLength(lenSlot);
      _lastLen = len;
      _copyString(len, dist);
    }
  }

  // writes window bytes [from, to) to the output
  void _writeWindow(int from, int to) {
    final out = _out;
    if (out == null || to <= from) return;
    final w = _win;
    final a = from & _winMask;
    final b = to & _winMask;
    if (a < b || b == 0) {
      out.write(w, a, to - from);
    } else {
      out.write(w, a, _winSize - a);
      out.write(w, 0, b);
    }
  }

  // apply_filters and the output part of do_uncompress_file: writes all
  // the decoded data that no pending filter covers, running the filters
  // whose blocks are complete
  void _flush() {
    while (_filters.isNotEmpty) {
      final f = _filters.first;
      if (_wr >= f.blockStart + f.blockLength) {
        if (_written < f.blockStart) {
          _writeWindow(_written, f.blockStart);
          _written = f.blockStart;
        }
        if (_written != f.blockStart) throw _dataError('bad filter order');
        _runFilter(f);
        _written += f.blockLength;
        _filters.removeAt(0);
        continue;
      }
      final end = f.blockStart < _wr ? f.blockStart : _wr;
      if (end > _written) {
        _writeWindow(_written, end);
        _written = end;
      }
      return;
    }
    _writeWindow(_written, _wr);
    _written = _wr;
  }

  int _winByte(int pos) => _win[pos & _winMask];

  // run_filter
  void _runFilter(_Filter f) {
    final len = f.blockLength;
    if (_filtered.length < len) _filtered = Uint8List(len);
    final dst = _filtered;
    final start = f.blockStart;
    switch (f.type) {
      case Rar5FilterType.delta:
        // run_delta_filter
        var src = 0;
        for (var i = 0; i < f.channels; i++) {
          var prev = 0;
          for (var d = i; d < len; d += f.channels) {
            prev = (prev - _winByte(start + src)) & 0xFF;
            dst[d] = prev;
            src++;
          }
        }
      case Rar5FilterType.e8:
      case Rar5FilterType.e8e9:
        _copyOut(start, len, dst);
        _e8e9(f, dst, f.type == Rar5FilterType.e8e9);
      case Rar5FilterType.arm:
        _copyOut(start, len, dst);
        // run_arm_filter
        final rel = start - _fileStart;
        for (var i = 0; i < len - 3; i += 4) {
          if (_winByte(start + i + 3) == 0xEB) {
            var offset = (_winByte(start + i) |
                    (_winByte(start + i + 1) << 8) |
                    (_winByte(start + i + 2) << 16)) &
                0xFFFFFF;
            offset = (offset - (i + rel) ~/ 4) & 0xFFFFFFFF;
            offset = (offset & 0x00FFFFFF) | 0xEB000000;
            dst[i] = offset & 0xFF;
            dst[i + 1] = (offset >> 8) & 0xFF;
            dst[i + 2] = (offset >> 16) & 0xFF;
            dst[i + 3] = (offset >> 24) & 0xFF;
          }
        }
      default:
        throw SevenZipException('RAR5: unsupported filter type ${f.type}',
            SevenZipError.unsupportedMethod);
    }
    _out?.write(dst, 0, len);
  }

  void _copyOut(int start, int len, Uint8List dst) {
    final a = start & _winMask;
    if (a + len <= _winSize) {
      dst.setRange(0, len, _win, a);
    } else {
      final n1 = _winSize - a;
      dst.setRange(0, n1, _win, a);
      dst.setRange(n1, len, _win, 0);
    }
  }

  // run_e8e9_filter
  void _e8e9(_Filter f, Uint8List dst, bool extended) {
    const fileSize = 0x1000000;
    final start = f.blockStart;
    final rel = start - _fileStart;
    final len = f.blockLength;
    for (var i = 0; i < len - 4;) {
      final b = _winByte(start + i++);
      if (b == 0xE8 || (extended && b == 0xE9)) {
        final offset = (i + rel) % fileSize;
        final addr = _winByte(start + i) |
            (_winByte(start + i + 1) << 8) |
            (_winByte(start + i + 2) << 16) |
            (_winByte(start + i + 3) << 24);
        int? v;
        if ((addr & 0x80000000) != 0) {
          if (((addr + offset) & 0x80000000) == 0) {
            v = (addr + fileSize) & 0xFFFFFFFF;
          }
        } else {
          if (((addr - fileSize) & 0x80000000) != 0) {
            v = (addr - offset) & 0xFFFFFFFF;
          }
        }
        if (v != null) {
          dst[i] = v & 0xFF;
          dst[i + 1] = (v >> 8) & 0xFF;
          dst[i + 2] = (v >> 16) & 0xFF;
          dst[i + 3] = (v >> 24) & 0xFF;
        }
        i += 4;
      }
    }
  }
}
