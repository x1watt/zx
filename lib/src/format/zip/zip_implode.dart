// Zip method 6 (Implode) decoder, written from the PKWARE APPNOTE, section
// 5.3 (Imploding). No code of 7-Zip's or Info-ZIP's decoders is used.
//
// General purpose flag bit 1 selects an 8 KiB window (7 low distance bits)
// instead of 4 KiB (6 bits), bit 2 a third Shannon-Fano tree for literals
// (and a minimum match length of 3 instead of 2).
//
// The packed data starts with the trees, each stored as a byte count minus
// one and then bytes of (values - 1) << 4 | (bit length - 1) for runs of
// values in order: 256 literal values, 64 length values, 64 values for the
// high 6 bits of the distance. The codes come from the lengths as the
// APPNOTE describes: values sorted by length (ties in value order) get
// codes counting up from the last one, so that the longest codes are the
// smallest. The bits of the data follow, packed starting with the least
// significant bit of each byte, and a code is sent from its most
// significant bit on.
//
// Each token starts with one bit: 1 is a literal (a literal tree code, or 8
// plain bits without that tree), 0 a match: the low distance bits, the
// high distance bits from the distance tree, the length from the length
// tree (plus the minimum), and when the tree gave 63 one more byte added
// to the length. The match copies from distance + 1 back; bytes before the
// start of the output read as zeros.

import 'dart:typed_data';

import '../../io/streams.dart';

const int _kWinSize = 8192;
const int _kWinMask = _kWinSize - 1;

// A decoding table: indexed by the next maxBits input bits, each entry is
// value | bit length << 8 (0 for bit patterns no code starts with).
class _Tree {
  final Uint16List table;
  final int maxBits;
  _Tree(this.table, this.maxBits);
}

/// Decodes an Implode stream (zip method 6) of [outSize] bytes.
class ImplodeDecoder implements InStream {
  final InStream _in;
  int _remaining;
  final bool _bigWindow;
  final bool _literalTree;

  final Uint8List _inBuf = Uint8List(1 << 16);
  int _inPos = 0;
  int _inLim = 0;
  int _padBytes = 0;
  int _bitBuf = 0;
  int _bitCnt = 0;

  _Tree? _litTree;
  late _Tree _lenTree;
  late _Tree _distTree;
  bool _headerDone = false;

  final Uint8List _win = Uint8List(_kWinSize);
  int _winPos = 0;
  int _matchLen = 0;
  int _matchDist = 0;

  ImplodeDecoder(InStream packed, int outSize,
      {required bool bigWindow, required bool literalTree})
      : _in = packed,
        _remaining = outSize,
        _bigWindow = bigWindow,
        _literalTree = literalTree;

  // Reads the next chunk of packed data, or zero padding past its end.
  int _fill() {
    final n = _in.read(_inBuf, 0, _inBuf.length);
    if (n > 0) return n;
    _padBytes += 4;
    if (_padBytes > 64) throw _endError();
    _inBuf.fillRange(0, 4, 0);
    return 4;
  }

  static SevenZipException _endError() => const SevenZipException(
      'Unexpected end of Implode data', SevenZipError.unexpectedEnd);

  // A corrupt stream error, or an end error when it came from reading past
  // the end of the input (unread bits fewer than the padding).
  SevenZipException _corrupt(String msg, int unreadBits) =>
      unreadBits < _padBytes * 8 ? _endError() : SevenZipException(msg);

  int _byte() {
    if (_bitCnt >= 8) {
      final v = _bitBuf & 0xFF;
      _bitBuf >>= 8;
      _bitCnt -= 8;
      return v;
    }
    if (_inPos == _inLim) {
      _inLim = _fill();
      _inPos = 0;
    }
    return _inBuf[_inPos++];
  }

  // Reads one stored tree of [n] values and builds its decoding table.
  _Tree _readTree(int n) {
    final lens = Uint8List(n);
    final count = _byte() + 1;
    var k = 0;
    for (var i = 0; i < count; i++) {
      final b = _byte();
      final num = (b >> 4) + 1;
      final bits = (b & 15) + 1;
      if (k + num > n) {
        throw _corrupt('Bad Implode tree', _bitCnt + (_inLim - _inPos) * 8);
      }
      lens.fillRange(k, k + num, bits);
      k += num;
    }
    if (k != n) {
      throw _corrupt('Bad Implode tree', _bitCnt + (_inLim - _inPos) * 8);
    }

    // APPNOTE 5.3.8: values in order of length, ties in value order, get
    // left aligned 16 bit codes counting up from the last value.
    final order = Uint16List(n);
    var o = 0;
    var maxBits = 0;
    for (var len = 1; len <= 16; len++) {
      for (var i = 0; i < n; i++) {
        if (lens[i] == len) {
          order[o++] = i;
          maxBits = len;
        }
      }
    }
    final codes = Int32List(n);
    var code = 0;
    var inc = 0;
    var lastLen = 0;
    for (var j = n - 1; j >= 0; j--) {
      final i = order[j];
      code += inc;
      if (lens[i] != lastLen) {
        lastLen = lens[i];
        inc = 1 << (16 - lastLen);
      }
      codes[i] = code;
    }
    if (code + inc > 0x10000) {
      throw _corrupt('Bad Implode tree', _bitCnt + (_inLim - _inPos) * 8);
    }

    // The input is read from the low bit up and a code starts with its high
    // bit, so the table index of a code is its bits reversed.
    final table = Uint16List(1 << maxBits);
    for (var i = 0; i < n; i++) {
      final len = lens[i];
      final c = codes[i] >> (16 - len);
      var r = 0;
      for (var b = 0; b < len; b++) {
        r |= ((c >> b) & 1) << (len - 1 - b);
      }
      final entry = i | (len << 8);
      for (var x = r; x < table.length; x += 1 << len) {
        table[x] = entry;
      }
    }
    return _Tree(table, maxBits);
  }

  void _readHeader() {
    if (_literalTree) _litTree = _readTree(256);
    _lenTree = _readTree(64);
    _distTree = _readTree(64);
    _headerDone = true;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len > _remaining) len = _remaining;
    if (len <= 0) return 0;
    if (!_headerDone) _readHeader();
    final end = off + len;
    var pos = off;
    final win = _win;
    final inBuf = _inBuf;
    final lit = _litTree;
    final litTable = lit?.table;
    final litMask = lit == null ? 0 : (1 << lit.maxBits) - 1;
    final lenTable = _lenTree.table;
    final lenMask = (1 << _lenTree.maxBits) - 1;
    final distTable = _distTree.table;
    final distMask = (1 << _distTree.maxBits) - 1;
    final lowBits = _bigWindow ? 7 : 6;
    final minLen = _literalTree ? 3 : 2;
    var inPos = _inPos;
    var inLim = _inLim;
    var bitBuf = _bitBuf;
    var bitCnt = _bitCnt;
    var wp = _winPos;
    var matchLen = _matchLen;
    var dist = _matchDist;

    while (pos < end) {
      if (matchLen > 0) {
        var n = matchLen;
        if (n > end - pos) n = end - pos;
        matchLen -= n;
        var src = (wp - dist) & _kWinMask;
        while (n-- > 0) {
          final b = win[src];
          win[wp] = b;
          buf[pos++] = b;
          wp = (wp + 1) & _kWinMask;
          src = (src + 1) & _kWinMask;
        }
        continue;
      }

      // A token takes at most 1 + 16 (literal) or 1 + 7 + 16 + 16 + 8 bits.
      while (bitCnt < 48) {
        if (inPos == inLim) {
          inLim = _fill();
          inPos = 0;
        }
        bitBuf |= inBuf[inPos++] << bitCnt;
        bitCnt += 8;
      }
      if ((bitBuf & 1) != 0) {
        int c;
        if (litTable != null) {
          final e = litTable[(bitBuf >> 1) & litMask];
          if (e == 0) {
            throw _corrupt(
                'Bad Implode literal code', bitCnt + (inLim - inPos) * 8);
          }
          final n = (e >> 8) + 1;
          bitBuf >>= n;
          bitCnt -= n;
          c = e & 0xFF;
        } else {
          c = (bitBuf >> 1) & 0xFF;
          bitBuf >>= 9;
          bitCnt -= 9;
        }
        win[wp] = c;
        wp = (wp + 1) & _kWinMask;
        buf[pos++] = c;
        continue;
      }
      bitBuf >>= 1;
      final low = bitBuf & ((1 << lowBits) - 1);
      bitBuf >>= lowBits;
      final de = distTable[bitBuf & distMask];
      final le0 = de >> 8;
      if (de == 0) {
        throw _corrupt(
            'Bad Implode distance code', bitCnt + (inLim - inPos) * 8);
      }
      bitBuf >>= le0;
      final le = lenTable[bitBuf & lenMask];
      if (le == 0) {
        throw _corrupt('Bad Implode length code', bitCnt + (inLim - inPos) * 8);
      }
      final lb = le >> 8;
      bitBuf >>= lb;
      var ml = le & 0xFF;
      var used = 1 + lowBits + le0 + lb;
      if (ml == 63) {
        ml += bitBuf & 0xFF;
        bitBuf >>= 8;
        used += 8;
      }
      bitCnt -= used;
      dist = ((de & 0xFF) << lowBits | low) + 1;
      matchLen = ml + minLen;
    }

    _inPos = inPos;
    _inLim = inLim;
    _bitBuf = bitBuf;
    _bitCnt = bitCnt;
    _winPos = wp;
    _matchLen = matchLen;
    _matchDist = dist;
    if (bitCnt + (inLim - inPos) * 8 < _padBytes * 8) throw _endError();
    _remaining -= len;
    return len;
  }
}
