// The xz container: port of C/Xz.h, C/Xz.c, C/XzIn.c and the header
// parsing part of C/XzDec.c (Xz_ReadVarInt, Xz_ParseHeader, XzBlock_Parse)
// of the LZMA SDK 26.01.
//
// UInt64 values are Dart ints. The "undefined" value (UInt64)(Int64)-1 of
// the C code is -1 here (XZ_SIZE_OVERFLOW too); every real size is below
// 2^63.

import 'dart:typed_data';

import '../../crypto/sha256.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';

// ---------------------------------------------------------------------------
// SRes codes (7zTypes.h) used by the xz code. The LZMA codes of
// lzma_dec.dart have the same values.

const int szOk = 0; // SZ_OK
const int szErrorData = 1; // SZ_ERROR_DATA
const int szErrorMem = 2; // SZ_ERROR_MEM
const int szErrorCrc = 3; // SZ_ERROR_CRC
const int szErrorUnsupported = 4; // SZ_ERROR_UNSUPPORTED
const int szErrorParam = 5; // SZ_ERROR_PARAM
const int szErrorInputEof = 6; // SZ_ERROR_INPUT_EOF
const int szErrorOutputEof = 7; // SZ_ERROR_OUTPUT_EOF
const int szErrorRead = 8; // SZ_ERROR_READ
const int szErrorWrite = 9; // SZ_ERROR_WRITE
const int szErrorProgress = 10; // SZ_ERROR_PROGRESS
const int szErrorFail = 11; // SZ_ERROR_FAIL
const int szErrorArchive = 16; // SZ_ERROR_ARCHIVE
const int szErrorNoArchive = 17; // SZ_ERROR_NO_ARCHIVE

// ---------------------------------------------------------------------------
// Xz.h

const int xzIdSubblock = 1;
const int xzIdDelta = 3;
const int xzIdX86 = 4;
const int xzIdPpc = 5;
const int xzIdIa64 = 6;
const int xzIdArm = 7;
const int xzIdArmt = 8;
const int xzIdSparc = 9;
const int xzIdArm64 = 0xa;
const int xzIdRiscv = 0xb;
const int xzIdLzma2 = 0x21;

const int xzBlockHeaderSizeMax = 1024;
const int xzNumFiltersMax = 4;
const int xzBfNumFiltersMask = 3;
const int xzBfPackSize = 1 << 6;
const int xzBfUnpackSize = 1 << 7;
const int xzFilterPropsSizeMax = 20;

const int xzSigSize = 6;
const int xzFooterSigSize = 2;

/// XZ_SIG
final Uint8List xzSig =
    Uint8List.fromList(const [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0]);

const int xzFooterSig0 = 0x59; // 'Y'
const int xzFooterSig1 = 0x5A; // 'Z'

const int xzStreamFlagsSize = 2;
const int xzStreamCrcSize = 4;
const int xzStreamHeaderSize = xzSigSize + xzStreamFlagsSize + xzStreamCrcSize;
const int xzStreamFooterSize =
    xzFooterSigSize + xzStreamFlagsSize + xzStreamCrcSize + 4;

const int xzCheckMask = 0xF;
const int xzCheckNo = 0;
const int xzCheckCrc32 = 1;
const int xzCheckCrc64 = 4;
const int xzCheckSha256 = 10;

/// XZ_SIZE_OVERFLOW
const int xzSizeOverflow = -1;

/// XZ_CHECK_SIZE_MAX (XzDec.c, XzEnc.c)
const int xzCheckSizeMax = 64;

/// CXzFilter
class XzFilter {
  int id = 0;
  int propsSize = 0;
  final Uint8List props = Uint8List(xzFilterPropsSizeMax);

  void copyFrom(XzFilter f) {
    id = f.id;
    propsSize = f.propsSize;
    props.setAll(0, f.props);
  }
}

/// CXzBlock
class XzBlock {
  int packSize = -1;
  int unpackSize = -1;
  int flags = 0;
  final List<XzFilter> filters =
      List.generate(xzNumFiltersMax, (_) => XzFilter(), growable: false);

  // XzBlock_GetNumFilters
  int get numFilters => (flags & xzBfNumFiltersMask) + 1;
  // XzBlock_HasPackSize
  bool get hasPackSize => (flags & xzBfPackSize) != 0;
  // XzBlock_HasUnpackSize
  bool get hasUnpackSize => (flags & xzBfUnpackSize) != 0;
  // XzBlock_HasUnsupportedFlags
  bool get hasUnsupportedFlags =>
      (flags & ~(xzBfNumFiltersMask | xzBfPackSize | xzBfUnpackSize)) != 0;

  void copyFrom(XzBlock b) {
    packSize = b.packSize;
    unpackSize = b.unpackSize;
    flags = b.flags;
    for (var i = 0; i < xzNumFiltersMax; i++) {
      filters[i].copyFrom(b.filters[i]);
    }
  }
}

// XzFlags_IsSupported
bool xzFlagsIsSupported(int f) => f <= xzCheckMask;

// XzFlags_GetCheckType
int xzFlagsGetCheckType(int f) => f & xzCheckMask;

// XzFlags_GetCheckSize
int xzFlagsGetCheckSize(int f) {
  final t = xzFlagsGetCheckType(f);
  return (t == 0) ? 0 : (4 << ((t - 1) ~/ 3));
}

// ---------------------------------------------------------------------------
// Xz.c

/// Xz_ReadVarInt. Returns the number of bytes read (0 for an error) and
/// the value.
(int, int) xzReadVarInt(Uint8List p, int off, int maxSize) {
  var value = 0;
  final limit = (maxSize > 9) ? 9 : maxSize;
  for (var i = 0; i < limit;) {
    final b = p[off + i];
    value |= (b & 0x7F) << (7 * i++);
    if ((b & 0x80) == 0) return ((b == 0 && i != 1) ? 0 : i, value);
  }
  return (0, value);
}

// Xz_WriteVarInt
int xzWriteVarInt(Uint8List buf, int off, int v) {
  var i = 0;
  do {
    buf[off + i++] = (v & 0x7F) | 0x80;
    v >>= 7;
  } while (v != 0);
  buf[off + i - 1] &= 0x7F;
  return i;
}

/// CXzCheck
class XzCheck {
  int mode = 0;
  int _crc = 0;
  Crc64 _crc64 = Crc64();
  final Sha256 _sha = Sha256();

  // XzCheck_Init
  void init(int mode) {
    this.mode = mode;
    switch (mode) {
      case xzCheckCrc32:
        _crc = 0xFFFFFFFF; // CRC_INIT_VAL
      case xzCheckCrc64:
        _crc64 = Crc64();
      case xzCheckSha256:
        _sha.init();
    }
  }

  // XzCheck_Update
  void update(Uint8List data, int off, int size) {
    switch (mode) {
      case xzCheckCrc32:
        _crc = crc32Update(_crc, data, off, off + size);
      case xzCheckCrc64:
        _crc64.update(data, off, off + size);
      case xzCheckSha256:
        _sha.update(data, off, size);
    }
  }

  // XzCheck_Final. Returns false for the modes without a digest.
  bool finalTo(Uint8List digest, int off) {
    switch (mode) {
      case xzCheckCrc32:
        setUint32LE(digest, off, _crc ^ 0xFFFFFFFF); // CRC_GET_DIGEST
        return true;
      case xzCheckCrc64:
        digest.setAll(off, _crc64.bytes);
        return true;
      case xzCheckSha256:
        _sha.finalTo(digest, off);
        return true;
      default:
        return false;
    }
  }
}

// ---------------------------------------------------------------------------
// XzDec.c: header parsing

// CrcCalc
int _crcCalc(Uint8List b, int off, int size) =>
    crc32Update(0xFFFFFFFF, b, off, off + size) ^ 0xFFFFFFFF;

int _getBe16(Uint8List b, int off) => (b[off] << 8) | b[off + 1];

/// Xz_ParseHeader: parses the 12 byte stream header at [buf][off].
/// Returns the SRes code and the stream flags.
(int, int) xzParseHeader(Uint8List buf, int off) {
  final flags = _getBe16(buf, off + xzSigSize);
  if (_crcCalc(buf, off + xzSigSize, xzStreamFlagsSize) !=
      getUint32LE(buf, off + xzSigSize + xzStreamFlagsSize)) {
    return (szErrorNoArchive, flags);
  }
  return (xzFlagsIsSupported(flags) ? szOk : szErrorUnsupported, flags);
}

// Xz_CheckFooter
bool xzCheckFooter(int flags, int indexSize, Uint8List buf, int off) {
  return indexSize == ((getUint32LE(buf, off + 4) + 1) << 2) &&
      getUint32LE(buf, off) == _crcCalc(buf, off + 4, 6) &&
      flags == _getBe16(buf, off + 8) &&
      (buf[off + 10] | (buf[off + 11] << 8)) ==
          (xzFooterSig0 | (xzFooterSig1 << 8));
}

// XZ_IS_SUPPORTED_FILTER_ID
bool xzIsSupportedFilterId(int id) => id >= xzIdDelta && id <= xzIdRiscv;

// XzBlock_AreSupportedFilters
bool xzBlockAreSupportedFilters(XzBlock p) {
  final numFilters = p.numFilters - 1;
  {
    final f = p.filters[numFilters];
    if (f.id != xzIdLzma2 || f.propsSize != 1 || f.props[0] > 40) {
      return false;
    }
  }
  for (var i = 0; i < numFilters; i++) {
    final f = p.filters[i];
    if (f.id == xzIdDelta) {
      if (f.propsSize != 1) return false;
    } else if (!xzIsSupportedFilterId(f.id) ||
        (f.propsSize != 0 && f.propsSize != 4)) {
      return false;
    }
  }
  return true;
}

// XzBlock_Parse: [header] holds the whole block header (with its CRC).
int xzBlockParse(XzBlock p, Uint8List header) {
  final headerSize = header[0] << 2;

  // (headerSize != 0) : another code checks

  if (_crcCalc(header, 0, headerSize) != getUint32LE(header, headerSize)) {
    return szErrorArchive;
  }

  var pos = 1;
  p.flags = header[pos++];

  p.packSize = -1;
  if (p.hasPackSize) {
    // READ_VARINT_AND_CHECK
    final (s, v) = xzReadVarInt(header, pos, headerSize - pos);
    if (s == 0) return szErrorArchive;
    pos += s;
    p.packSize = v;
    if (p.packSize == 0 || p.packSize > 0x7FFFFFFFFFFFFFFF - headerSize) {
      return szErrorArchive;
    }
  }

  p.unpackSize = -1;
  if (p.hasUnpackSize) {
    final (s, v) = xzReadVarInt(header, pos, headerSize - pos);
    if (s == 0) return szErrorArchive;
    pos += s;
    p.unpackSize = v;
  }

  final numFilters = p.numFilters;
  for (var i = 0; i < numFilters; i++) {
    final filter = p.filters[i];
    final (s, v) = xzReadVarInt(header, pos, headerSize - pos);
    if (s == 0) return szErrorArchive;
    pos += s;
    filter.id = v;
    final (s2, size) = xzReadVarInt(header, pos, headerSize - pos);
    if (s2 == 0) return szErrorArchive;
    pos += s2;
    if (size > headerSize - pos || size > xzFilterPropsSizeMax) {
      return szErrorArchive;
    }
    filter.propsSize = size;
    filter.props.setRange(0, size, header, pos);
    pos += size;
  }

  if (p.hasUnsupportedFlags) return szErrorUnsupported;

  while (pos < headerSize) {
    if (header[pos++] != 0) return szErrorArchive;
  }
  return szOk;
}

// ---------------------------------------------------------------------------
// XzIn.c

/// Xz_ReadHeader: reads and parses the stream header. Returns the SRes
/// code and the stream flags.
(int, int) xzReadHeader(InStream inStream) {
  final data = Uint8List(xzStreamHeaderSize);
  final processedSize = readFully(inStream, data, 0, xzStreamHeaderSize);
  if (processedSize != xzStreamHeaderSize) return (szErrorNoArchive, 0);
  for (var i = 0; i < xzSigSize; i++) {
    if (data[i] != xzSig[i]) return (szErrorNoArchive, 0);
  }
  return xzParseHeader(data, 0);
}

/// Output of [xzBlockReadHeader].
class XzBlockHeaderInfo {
  bool isIndex = false;
  int headerSize = 0;
}

/// XzBlock_ReadHeader
int xzBlockReadHeader(XzBlock p, InStream inStream, XzBlockHeaderInfo info) {
  final header = Uint8List(xzBlockHeaderSizeMax);
  info.headerSize = 0;
  // SeqInStream_ReadByte
  if (inStream.read(header, 0, 1) != 1) return szErrorInputEof;
  var headerSize = header[0];
  if (headerSize == 0) {
    info.headerSize = 1;
    info.isIndex = true;
    return szOk;
  }

  info.isIndex = false;
  headerSize = (headerSize << 2) + 4;
  info.headerSize = headerSize;
  {
    final processedSize = readFully(inStream, header, 1, headerSize - 1);
    if (processedSize != headerSize - 1) return szErrorInputEof;
  }
  return xzBlockParse(p, header);
}

/// CXzBlockSizes
class XzBlockSizes {
  int unpackSize = 0;
  int totalSize = 0;
}

/// CXzStream
class XzStream {
  int flags = 0;
  List<XzBlockSizes> blocks = const [];
  int startOffset = 0;

  int get numBlocks => blocks.length;

  // Xz_GetUnpackSize
  int getUnpackSize() {
    var size = 0;
    for (final b in blocks) {
      // ADD_SIZE_CHECK
      final newSize = size + b.unpackSize;
      if (newSize < size) return xzSizeOverflow;
      size = newSize;
    }
    return size;
  }

  // Xz_GetPackSize
  int getPackSize() {
    var size = 0;
    for (final b in blocks) {
      final newSize = size + ((b.totalSize + 3) & ~3);
      if (newSize < size) return xzSizeOverflow;
      size = newSize;
    }
    return size;
  }
}

// Xz_ParseIndex: [buf] holds the whole index (size is a multiple of 4).
int _xzParseIndex(XzStream p, Uint8List buf, int size) {
  if (size < 5 || buf[0] != 0) return szErrorArchive;
  size -= 4;
  {
    final crc = _crcCalc(buf, 0, size);
    if (crc != getUint32LE(buf, size)) return szErrorArchive;
  }
  var pos = 1;
  size--;
  int numBlocks;
  {
    final (s, v) = xzReadVarInt(buf, pos, size);
    if (s == 0) return szErrorArchive;
    size -= s;
    pos += s;
    final numBlocks64 = v;
    // (numBlocks64) is 63-bit value, so we can calculate (numBlocks64 * 2):
    if (numBlocks64 * 2 > size) return szErrorArchive;
    numBlocks = numBlocks64;
  }
  if (numBlocks != 0) {
    final blocks = List.generate(numBlocks, (_) => XzBlockSizes());
    p.blocks = blocks;
    for (final b in blocks) {
      final (s, v) = xzReadVarInt(buf, pos, size);
      if (s == 0) return szErrorArchive;
      size -= s;
      pos += s;
      b.totalSize = v;
      final (s2, v2) = xzReadVarInt(buf, pos, size);
      if (s2 == 0) return szErrorArchive;
      size -= s2;
      pos += s2;
      b.unpackSize = v2;
      if (b.totalSize == 0) return szErrorArchive;
    }
  }
  if (size >= 4) return szErrorArchive;
  while (size != 0) {
    if (buf[pos + --size] != 0) return szErrorArchive;
  }
  return szOk;
}

// LookInStream_SeekRead_ForArc (LookInStream_Read: SZ_ERROR_INPUT_EOF on a
// short read).
int _seekReadForArc(
    SeekableInStream stream, int offset, Uint8List buf, int size) {
  stream.position = offset;
  if (readFully(stream, buf, 0, size) != size) return szErrorInputEof;
  return szOk;
}

const int _tempBufSize = 1 << 10;

// XZ_STREAM_BACKWARD_READING_PAD_MAX
const int _xzStreamBackwardReadingPadMax = 1 << 16;

// Xz_ReadBackward. [startOffset] is the position where the xz stream must
// end; on success it is set to the start of the stream.
int _xzReadBackward(
    XzStream p, SeekableInStream stream, List<int> startOffset) {
  final buf = Uint8List(_tempBufSize);
  var pos = startOffset[0];

  if ((pos & 3) != 0 || pos < xzStreamFooterSize) return szErrorNoArchive;
  pos -= xzStreamFooterSize;
  var r = _seekReadForArc(stream, pos, buf, xzStreamFooterSize);
  if (r != szOk) return r;

  // XZ_FOOTER_12B_ALIGNED16_SIG_CHECK
  bool footerSigCheck() =>
      (buf[10] | (buf[11] << 8)) == (xzFooterSig0 | (xzFooterSig1 << 8));

  if (!footerSigCheck()) {
    pos += xzStreamFooterSize;
    for (;;) {
      // pos != 0
      // (pos & 3) == 0
      var i = pos >= _tempBufSize ? _tempBufSize : pos;
      pos -= i;
      r = _seekReadForArc(stream, pos, buf, i);
      if (r != szOk) return r;
      i ~/= 4;
      do {
        if (getUint32LE(buf, (i - 1) * 4) != 0) break;
      } while (--i != 0);

      pos += i * 4;
      // here we don't support rare case with big padding for xz stream.
      // so we have padding limit for backward reading.
      if (startOffset[0] - pos > _xzStreamBackwardReadingPadMax) {
        return szErrorNoArchive;
      }
      if (i != 0) break;
    }
    // we try to open xz stream after skipping zero padding.
    // (startOffset == pos) is possible here!
    if (pos < xzStreamFooterSize) return szErrorNoArchive;
    pos -= xzStreamFooterSize;
    r = _seekReadForArc(stream, pos, buf, xzStreamFooterSize);
    if (r != szOk) return r;
    if (!footerSigCheck()) return szErrorNoArchive;
  }

  p.flags = _getBe16(buf, 8);
  if (!xzFlagsIsSupported(p.flags)) return szErrorUnsupported;
  if (getUint32LE(buf, 0) != _crcCalc(buf, 4, 6)) return szErrorArchive;
  {
    final indexSize = (getUint32LE(buf, 4) + 1) << 2;
    if (pos < indexSize) return szErrorArchive;
    pos -= indexSize;
    stream.position = pos;
    {
      final size = indexSize;
      final ibuf = Uint8List(size);
      // LookInStream_Read2(stream, buf, size, SZ_ERROR_UNSUPPORTED)
      var res =
          readFully(stream, ibuf, 0, size) == size ? szOk : szErrorUnsupported;
      if (res == szOk) res = _xzParseIndex(p, ibuf, size);
      if (res != szOk) return res;
    }
  }
  {
    var total = p.getPackSize();
    if (total == xzSizeOverflow || total < 0) return szErrorArchive;
    total += xzStreamHeaderSize;
    if (pos < total) return szErrorArchive;
    pos -= total;
    stream.position = pos;
    startOffset[0] = pos;
  }
  {
    // CSecToRead: Xz_ReadHeader over the stream
    final (r2, headerFlags) = xzReadHeader(stream);
    if (r2 != szOk) return r2;
    return (p.flags == headerFlags) ? szOk : szErrorArchive;
  }
}

/// CXzs: the streams of an xz file, last stream first (as
/// Xzs_ReadBackward finds them).
class Xzs {
  final List<XzStream> streams = [];

  int get num => streams.length;

  // Xzs_GetNumBlocks
  int getNumBlocks() {
    var num = 0;
    for (final s in streams) {
      num += s.numBlocks;
    }
    return num;
  }

  // Xzs_GetUnpackSize
  int getUnpackSize() {
    var size = 0;
    for (final s in streams) {
      final u = s.getUnpackSize();
      if (u == xzSizeOverflow) return xzSizeOverflow;
      final newSize = size + u;
      if (newSize < size) return xzSizeOverflow;
      size = newSize;
    }
    return size;
  }

  /// Xzs_ReadBackward: reads the stream footers and indexes from the end
  /// of [stream]. [startOffset] receives the start of the first stream
  /// found (0 when the whole file is xz). [progress] is called with the
  /// number of bytes parsed so far. May leave streams in the list even
  /// when it returns an error.
  int readBackward(SeekableInStream stream, List<int> startOffset,
      {void Function(int parsed)? progress}) {
    final endOffset = stream.length;
    startOffset[0] = endOffset;
    for (;;) {
      final st = XzStream();
      final res = _xzReadBackward(st, stream, startOffset);
      st.startOffset = startOffset[0];
      if (res != szOk) return res;
      streams.add(st);
      if (startOffset[0] == 0) return szOk;
      if (progress != null) progress(endOffset - startOffset[0]);
    }
  }
}
