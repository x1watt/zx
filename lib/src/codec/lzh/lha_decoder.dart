// The decoder frame of LHA methods: lha_decoder.c of lhasa (ISC license, see
// LICENSE). Each method decodes one command per call into a buffer;
// [LhaDecoderInStream] turns that into an InStream of exactly the unpacked
// size, with the running CRC-16 (lha_decoder_read).

import 'dart:typed_data';

import '../../io/streams.dart';
import 'crc16.dart';
import 'lh1_decoder.dart';
import 'lh_new_decoder.dart';
import 'larc_decoders.dart';
import 'lzh_bits.dart';
import 'pma_decoders.dart';

/// LHADecoderType: one method.
abstract class LhaDecoder {
  /// max_read: the most bytes one [read] call can store.
  int get maxRead;

  /// read: decodes the next command to buf[off...] and returns the byte
  /// count, 0 at the end of the input or on an error.
  int read(Uint8List buf, int off);
}

/// null_decoder.c: stored data (-lh0-, -lz4-, -pm0-).
class LhaNullDecoder extends LhaDecoder {
  final LzhBitReader r;
  LhaNullDecoder(this.r);

  // BLOCK_READ_SIZE
  @override
  int get maxRead => 1024;

  // lha_null_read
  @override
  int read(Uint8List buf, int off) {
    var n = 0;
    while (n < 1024) {
      final c = r.readByte();
      if (c < 0) break;
      buf[off + n++] = c;
    }
    return n;
  }
}

/// The method names lhasa decodes (lha_decoder_for_name).
const List<String> lhaDecoderNames = [
  '-lz4-',
  '-lz5-',
  '-lzs-',
  '-lh0-',
  '-lh1-',
  '-lh4-',
  '-lh5-',
  '-lh6-',
  '-lh7-',
  '-lhx-',
  '-lk7-',
  '-pm0-',
  '-pm1-',
  '-pm2-',
];

// lha_decoder_for_name and the init function of each type
/// The decoder for [method] reading packed data from [packed], or null
/// when the method is not supported.
LhaDecoder? lhaDecoderForName(String method, InStream packed) {
  switch (method) {
    case '-lz4-':
    case '-lh0-':
    case '-pm0-':
      return LhaNullDecoder(LzhBitReader(packed));
    case '-lz5-':
      return Lz5Decoder(LzhBitReader(packed));
    case '-lzs-':
      return LzsDecoder(LzhBitReader(packed));
    case '-lh1-':
      return Lh1Decoder(LzhBitReader(packed));
    case '-lh4-':
    case '-lh5-':
      return LhNewDecoder(LzhBitReader(packed), LhNewParams.lh5);
    case '-lh6-':
      return LhNewDecoder(LzhBitReader(packed), LhNewParams.lh6);
    case '-lh7-':
      return LhNewDecoder(LzhBitReader(packed), LhNewParams.lh7);
    case '-lhx-':
      return LhNewDecoder(LzhBitReader(packed), LhNewParams.lhx);
    case '-lk7-':
      return LhNewDecoder(LzhBitReader(packed), LhNewParams.lk7);
    case '-pm1-':
      return Pm1Decoder(LzhBitReader(packed, zeroFillAtEnd: true));
    case '-pm2-':
      return Pm2Decoder(LzhBitReader(packed));
  }
  return null;
}

/// LHADecoder with lha_decoder_read: at most [streamLength] bytes of the
/// decoded output, and their CRC-16 in [crc]. [failed] is set when the
/// decoder stopped before the end (decoder_failed).
class LhaDecoderInStream implements InStream {
  final LhaDecoder decoder;
  final int streamLength;
  final Uint8List _out;
  int _outPos = 0;
  int _outLen = 0;
  int streamPos = 0;
  bool failed = false;
  int crc = 0;
  int _decoded = 0;

  /// false for ARJ, whose check is a CRC-32 computed by the caller.
  final bool computeCrc16;

  // lha_decoder_new64. The output buffer holds several commands, so that
  // the decoder is called in a loop (the output is the same).
  LhaDecoderInStream(this.decoder, this.streamLength,
      {this.computeCrc16 = true})
      : _out = Uint8List((1 << 16) + decoder.maxRead);

  void _fill() {
    _outPos = 0;
    _outLen = 0;
    final limit = _out.length - decoder.maxRead;
    final d = decoder;
    final out = _out;
    while (_outLen <= limit && _decoded < streamLength) {
      final n = d.read(out, _outLen);
      if (n == 0) {
        failed = true;
        break;
      }
      _outLen += n;
      _decoded += n;
    }
  }

  // lha_decoder_read
  @override
  int read(Uint8List buf, int off, int len) {
    if (streamPos + len > streamLength) len = streamLength - streamPos;
    var filled = 0;
    while (filled < len) {
      var bytes = _outLen - _outPos;
      if (len - filled < bytes) bytes = len - filled;
      if (bytes > 0) {
        buf.setRange(off + filled, off + filled + bytes, _out, _outPos);
        _outPos += bytes;
        filled += bytes;
      }
      if (filled >= len) break;
      if (failed) break;
      _fill();
      if (_outLen == 0) {
        failed = true;
        break;
      }
    }
    if (computeCrc16) crc = lhaCrc16(crc, buf, off, off + filled);
    streamPos += filled;
    return filled;
  }
}
