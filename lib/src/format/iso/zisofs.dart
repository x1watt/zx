// zisofs ("paged zlib", Rock Ridge ZF entry "pz"): a file compressed in
// blocks of 2^15 to 2^17 bytes. The stored file starts with a 16 byte
// header (magic 37 E4 53 96 C9 DB D6 07, uncompressed size LE32, header
// size / 4, log2 of the block size), then n + 1 LE32 block pointers (file
// offsets); block i is the zlib stream between pointers i and i + 1, and an
// empty block is all zeros. Layout as libarchive's
// archive_read_support_format_iso9660.c reads it (BSD 2-clause, see
// LICENSE); the blocks are inflated with the port of zlib in
// lib/src/codec/deflate.

import 'dart:typed_data';

import '../../codec/deflate/inflate.dart';
import '../../codec/deflate/zutil.dart';
import '../../io/streams.dart';

const List<int> _kMagic = [0x37, 0xE4, 0x53, 0x96, 0xC9, 0xDB, 0xD6, 0x07];

/// Random access to the uncompressed data of a zisofs file whose stored
/// bytes are [raw].
class ZisofsInStream implements SeekableInStream {
  final SeekableInStream raw;
  @override
  final int length;
  final int log2Block;
  final int _blockSize;
  final int _numBlocks;
  final Uint8List _block;
  final Uint8List _ptr = Uint8List(8);
  final InflateState _z = InflateState();
  Uint8List _in = Uint8List(0);
  int _cached = -1;
  int _p = 0;
  int _headerSize = 16;
  bool _checked = false;

  ZisofsInStream(this.raw, this.length, this.log2Block)
      : _blockSize = 1 << log2Block,
        _numBlocks = (length + (1 << log2Block) - 1) >> log2Block,
        _block = Uint8List(1 << log2Block);

  @override
  int get position => _p;

  @override
  set position(int v) => _p = v;

  void _checkHeader() {
    if (_checked) return;
    final h = Uint8List(16);
    raw.position = 0;
    if (readFully(raw, h, 0, 16) != 16) {
      throw const SevenZipException(
          'Unexpected end of zisofs data', SevenZipError.unexpectedEnd);
    }
    for (var i = 0; i < 8; i++) {
      if (h[i] != _kMagic[i]) {
        throw const SevenZipException('Bad zisofs header');
      }
    }
    final size = h[8] | (h[9] << 8) | (h[10] << 16) | (h[11] << 24);
    if (size != length || h[13] != log2Block || h[12] < 4) {
      throw const SevenZipException('Bad zisofs header');
    }
    _headerSize = h[12] * 4;
    _checked = true;
  }

  // decodes block [i] into _block
  void _load(int i) {
    if (_cached == i) return;
    _checkHeader();
    raw.position = _headerSize + i * 4;
    if (readFully(raw, _ptr, 0, 8) != 8) {
      throw const SevenZipException(
          'Unexpected end of zisofs data', SevenZipError.unexpectedEnd);
    }
    final bst = _ptr[0] | (_ptr[1] << 8) | (_ptr[2] << 16) | (_ptr[3] << 24);
    final bed = _ptr[4] | (_ptr[5] << 8) | (_ptr[6] << 16) | (_ptr[7] << 24);
    var want = _blockSize;
    if (i == _numBlocks - 1) want = length - i * _blockSize;
    _cached = -1;
    if (bed < bst || bed - bst > _blockSize * 2 + 1024) {
      throw const SevenZipException('Bad zisofs block pointers');
    }
    if (bed == bst) {
      _block.fillRange(0, want, 0);
      _cached = i;
      return;
    }
    final n = bed - bst;
    if (_in.length < n) _in = Uint8List(n);
    raw.position = bst;
    if (readFully(raw, _in, 0, n) != n) {
      throw const SevenZipException(
          'Unexpected end of zisofs data', SevenZipError.unexpectedEnd);
    }
    // zlib header: deflate method, no preset dictionary, check bits
    final cmf = _in[0];
    final flg = n > 1 ? _in[1] : 0;
    if (n < 2 ||
        (cmf & 0x0F) != 8 ||
        ((cmf << 8) | flg) % 31 != 0 ||
        (flg & 0x20) != 0) {
      throw const SevenZipException('Bad zisofs block');
    }
    final z = _z;
    z.inflateReset();
    z.nextIn = _in;
    z.nextInPos = 2;
    z.availIn = n - 2;
    z.nextOut = _block;
    z.nextOutPos = 0;
    z.availOut = want;
    final ret = z.inflate(ZFlush.finish);
    final got = want - z.availOut;
    if (ret == ZResult.dataError) {
      throw SevenZipException('zisofs data error: ${z.msg}');
    }
    if (got != want) {
      throw const SevenZipException('zisofs block is too short');
    }
    _cached = i;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    var done = 0;
    while (done < len && _p < length) {
      final bi = _p >> log2Block;
      _load(bi);
      final inBlock = _p - (bi << log2Block);
      var n = _blockSize - inBlock;
      if (n > length - _p) n = length - _p;
      if (n > len - done) n = len - done;
      buf.setRange(off + done, off + done + n, _block, inBlock);
      done += n;
      _p += n;
    }
    return done;
  }
}
