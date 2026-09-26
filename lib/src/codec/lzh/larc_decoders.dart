// Decoders of the LArc methods -lz5- and -lzs-: ports of lz5_decoder.c and
// lzs_decoder.c of lhasa (ISC license, see LICENSE).

import 'dart:typed_data';

import 'lha_decoder.dart';
import 'lzh_bits.dart';

/// LHALZ5Decoder: runs of eight commands after a flag byte, 4 KiB window.
class Lz5Decoder extends LhaDecoder {
  static const int _ringBufferSize = 4096;
  static const int _startOffset = 18;
  static const int _threshold = 3;

  final LzhBitReader r;
  final Uint8List ringbuf = Uint8List(_ringBufferSize);
  int ringbufPos = 0;
  final Uint8List _cmd = Uint8List(2);

  // lha_lz5_init
  Lz5Decoder(this.r) {
    _fillInitial();
    ringbufPos = _ringBufferSize - _startOffset;
  }

  @override
  int get maxRead => (15 + _threshold) * 8;

  // fill_initial
  void _fillInitial() {
    var p = 0;
    for (var i = 0; i < 256; i++) {
      for (var j = 0; j < 13; j++) {
        ringbuf[p++] = i;
      }
    }
    for (var i = 0; i < 256; i++) {
      ringbuf[p++] = i;
    }
    for (var i = 0; i < 256; i++) {
      ringbuf[p++] = 255 - i;
    }
    for (var i = 0; i < 128; i++) {
      ringbuf[p++] = 0;
    }
    for (var i = 0; i < 110; i++) {
      ringbuf[p++] = 0x20;
    }
    for (var i = 0; i < 18; i++) {
      ringbuf[p++] = 0;
    }
  }

  // output_byte
  int _outputByte(Uint8List buf, int pos, int b) {
    buf[pos] = b;
    ringbuf[ringbufPos] = b;
    ringbufPos = (ringbufPos + 1) & (_ringBufferSize - 1);
    return pos + 1;
  }

  // lha_lz5_read
  @override
  int read(Uint8List buf, int off) {
    final bitmap = r.readByte();
    if (bitmap < 0) return 0;
    var pos = off;
    for (var bit = 0; bit < 8; bit++) {
      if ((bitmap & (1 << bit)) != 0) {
        final b = r.readByte();
        if (b < 0) break;
        pos = _outputByte(buf, pos, b);
      } else {
        if (!r.readBytes(_cmd, 0, 2)) break;
        final seqstart = ((_cmd[1] & 0xF0) << 4) | _cmd[0];
        final seqlen = (_cmd[1] & 0x0F) + _threshold;
        // output_block
        for (var i = 0; i < seqlen; i++) {
          pos = _outputByte(
              buf, pos, ringbuf[(seqstart + i) & (_ringBufferSize - 1)]);
        }
      }
    }
    return pos - off;
  }
}

/// LHALZSDecoder: a flag bit per command, 2 KiB window.
class LzsDecoder extends LhaDecoder {
  static const int _ringBufferSize = 2048;
  static const int _startOffset = 17;
  static const int _threshold = 2;

  final LzhBitReader r;
  final Uint8List ringbuf = Uint8List(_ringBufferSize);
  int ringbufPos = 0;

  // lha_lzs_init
  LzsDecoder(this.r) {
    ringbuf.fillRange(0, _ringBufferSize, 0x20);
    ringbufPos = _ringBufferSize - _startOffset;
  }

  @override
  int get maxRead => 15 + _threshold;

  // lha_lzs_read
  @override
  int read(Uint8List buf, int off) {
    const mask = _ringBufferSize - 1;
    final bit = r.readBit();
    if (bit < 0) return 0;
    if (bit != 0) {
      final b = r.readBits(8);
      if (b < 0) return 0;
      buf[off] = b;
      ringbuf[ringbufPos] = b;
      ringbufPos = (ringbufPos + 1) & mask;
      return 1;
    }
    final pos = r.readBits(11);
    final len = r.readBits(4);
    if (pos < 0 || len < 0) return 0;
    final n = len + _threshold;
    for (var i = 0; i < n; i++) {
      final b = ringbuf[(pos + i) & mask];
      buf[off + i] = b;
      ringbuf[ringbufPos] = b;
      ringbufPos = (ringbufPos + 1) & mask;
    }
    return n;
  }
}
