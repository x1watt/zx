// The gzip archive handler, written from RFC 1952 (GZIP file format
// specification 4.3) with the IInArchive / IOutArchive shape of the other
// handlers (see xz/xz_handler.dart). The deflate data goes through the
// zlib ports of lib/src/codec/deflate. No code of 7-Zip's gzip handler is
// used (it is LGPL): what is taken from 7-Zip is its observable behavior
// (the listed properties, the header 7z 23.01 writes, which trailing data
// is an error), checked against /usr/bin/7z.
//
// Reading: several members (concatenated gzip streams), FTEXT, FHCRC,
// FEXTRA, FNAME, FCOMMENT, the CRC-32 and ISIZE of every member. After the
// last member, data that does not start a complete, valid member header is
// "data after the end" (so are trailing zeros), as 7-Zip reports it; a
// valid header followed by bad data is a data error of that member.
//
// Listing (open with a seekable stream) reads the first header and the
// last 8 bytes of the file, the CRC-32 and ISIZE of the last member, as
// 7-Zip does; after a full decode (extract or test) the size is the real
// total of all members.
//
// Writing: one member, FNAME with the file name when there is one, MTIME
// from the file (0 before 1970 or after 2106, or with -mtm-), XFL 2 at
// levels 7 to 9 and 4 below (as 7z a -tgzip writes it), OS 3 (Unix); the
// deflate data is zlib's at the level (-mx, default 5 as in 7-Zip).

import 'dart:convert';
import '../../host/io.dart' show Platform;
import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../codec/deflate/deflate_coder.dart';
import '../../codec/deflate/inflate.dart';
import '../../codec/deflate/zutil.dart';
import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../handler_out.dart';

/// RFC 1952 header constants.
abstract final class GzipFlags {
  static const text = 0x01; // FTEXT
  static const hcrc = 0x02; // FHCRC
  static const extra = 0x04; // FEXTRA
  static const name = 0x08; // FNAME
  static const comment = 0x10; // FCOMMENT
  static const reserved = 0xE0;
}

const int _kSignature0 = 0x1F;
const int _kSignature1 = 0x8B;
const int _kMethodDeflate = 8;

/// XFL values (RFC 1952).
const int _kXflMaximum = 2;
const int _kXflFastest = 4;

/// OS values (RFC 1952).
const int gzipHostOsFat = 0;
const int gzipHostOsUnix = 3;

/// Host OS names as 7-Zip lists them (kpidHostOS); other values are listed
/// as the number.
const List<String> gzipHostOsNames = [
  'FAT', 'AMIGA', 'VMS', 'Unix', 'VM/CMS', 'Atari', 'HPFS', 'Macintosh', //
  'Z-System', 'CP/M', 'TOPS-20', 'NTFS', 'SMS/QDOS', 'Acorn', 'VFAT', 'MVS',
  'BeOS', 'Tandem', 'OS/400', 'OS/X',
];

/// 100 ns ticks between 1601-01-01 and 1970-01-01.
const int _kUnixEpochFileTime = 116444736000000000;

/// A member header (RFC 1952 section 2.3).
class GzipHeader {
  int flags = 0;
  int mTime = 0; // MTIME, Unix seconds, 0 when not stored
  int extraFlags = 0; // XFL
  int hostOs = gzipHostOsUnix; // OS
  Uint8List? extra; // FEXTRA data
  Uint8List? name; // FNAME bytes without the zero
  Uint8List? comment; // FCOMMENT bytes without the zero
  int headerSize = 0;

  /// True when FHCRC is set and does not match the header.
  bool hcrcMismatch = false;

  /// FNAME as text: UTF-8 when valid, else ISO 8859-1 (the RFC charset).
  String? get nameString => _decodeText(name);

  /// FCOMMENT as text (LF line ends in the RFC).
  String? get commentString => _decodeText(comment);

  static String? _decodeText(Uint8List? b) {
    if (b == null) return null;
    try {
      return utf8.decode(b);
    } on FormatException {
      return latin1.decode(b);
    }
  }

  /// The header bytes for writing (FHCRC when [withHcrc]).
  Uint8List toBytes({bool withHcrc = false}) {
    final out = MemoryOutStream(64);
    var flg = 0;
    if (extra != null) flg |= GzipFlags.extra;
    if (name != null) flg |= GzipFlags.name;
    if (comment != null) flg |= GzipFlags.comment;
    if (withHcrc) flg |= GzipFlags.hcrc;
    out.writeByte(_kSignature0);
    out.writeByte(_kSignature1);
    out.writeByte(_kMethodDeflate);
    out.writeByte(flg);
    for (var i = 0; i < 4; i++) {
      out.writeByte((mTime >> (8 * i)) & 0xFF);
    }
    out.writeByte(extraFlags);
    out.writeByte(hostOs);
    final x = extra;
    if (x != null) {
      out.writeByte(x.length & 0xFF);
      out.writeByte((x.length >> 8) & 0xFF);
      out.write(x, 0, x.length);
    }
    for (final s in [name, comment]) {
      if (s == null) continue;
      out.write(s, 0, s.length);
      out.writeByte(0);
    }
    if (withHcrc) {
      final crc = Crc32.of(out.toBytes());
      out.writeByte(crc & 0xFF);
      out.writeByte((crc >> 8) & 0xFF);
    }
    return Uint8List.fromList(out.toBytes());
  }
}

/// Results of [_InBuffer.readHeader].
const int _hdrOk = 0;
const int _hdrNotGzip = 1; // wrong signature, method or flags
const int _hdrEnd = 2; // the input ended inside the header

/// Buffered input shared by the header parser and the inflater.
class _InBuffer {
  final InStream _s;
  final Uint8List data;
  int pos = 0;
  int lim = 0;
  bool eof = false;

  /// Bytes consumed before data[0].
  int base = 0;

  _InBuffer(this._s, [int size = 1 << 16]) : data = Uint8List(size);

  /// Total bytes consumed.
  int get processed => base + pos;

  /// Refills when empty. Returns false at the end of the input.
  bool fill() {
    if (pos < lim) return true;
    if (eof) return false;
    base += lim;
    pos = 0;
    lim = _s.read(data, 0, data.length);
    if (lim == 0) {
      eof = true;
      return false;
    }
    return true;
  }

  /// The next byte, or -1 at the end.
  int readByte() {
    if (pos == lim && !fill()) return -1;
    return data[pos++];
  }

  /// True at the end of the input.
  bool get atEnd => pos == lim && !fill();

  /// Parses a member header (RFC 1952 2.3.1) into [h].
  int readHeader(GzipHeader h) {
    final start = processed;
    final crc = Crc32();
    final one = Uint8List(1);
    int b() {
      final v = readByte();
      if (v >= 0) {
        one[0] = v;
        crc.update(one);
      }
      return v;
    }

    final fixed = List<int>.filled(10, 0);
    for (var i = 0; i < 10; i++) {
      final v = b();
      if (v < 0) {
        // not even the signature: not a gzip member
        if (i < 2) return _hdrNotGzip;
        return _hdrEnd;
      }
      fixed[i] = v;
      if (i == 0 && v != _kSignature0) return _hdrNotGzip;
      if (i == 1 && v != _kSignature1) return _hdrNotGzip;
      if (i == 2 && v != _kMethodDeflate) return _hdrNotGzip;
      if (i == 3 && (v & GzipFlags.reserved) != 0) return _hdrNotGzip;
    }
    h.flags = fixed[3];
    h.mTime = fixed[4] | (fixed[5] << 8) | (fixed[6] << 16) | (fixed[7] << 24);
    h.extraFlags = fixed[8];
    h.hostOs = fixed[9];
    h.extra = null;
    h.name = null;
    h.comment = null;
    h.hcrcMismatch = false;

    if ((h.flags & GzipFlags.extra) != 0) {
      final lo = b();
      final hi = b();
      if (hi < 0) return _hdrEnd;
      final xlen = lo | (hi << 8);
      final x = Uint8List(xlen);
      for (var i = 0; i < xlen; i++) {
        final v = b();
        if (v < 0) return _hdrEnd;
        x[i] = v;
      }
      h.extra = x;
    }
    for (final flag in [GzipFlags.name, GzipFlags.comment]) {
      if ((h.flags & flag) == 0) continue;
      final bb = BytesBuilder(copy: false);
      for (;;) {
        final v = b();
        if (v < 0) return _hdrEnd;
        if (v == 0) break;
        bb.addByte(v);
      }
      final s = bb.toBytes();
      if (flag == GzipFlags.name) {
        h.name = s;
      } else {
        h.comment = s;
      }
    }
    if ((h.flags & GzipFlags.hcrc) != 0) {
      final expected = crc.value & 0xFFFF;
      final lo = readByte();
      final hi = readByte();
      if (hi < 0) return _hdrEnd;
      // 7-Zip does not check the header CRC (gzip does): the member is
      // read, the mismatch is only recorded
      h.hcrcMismatch = (lo | (hi << 8)) != expected;
    }
    h.headerSize = processed - start;
    return _hdrOk;
  }
}

/// Computes the CRC-32 and size of the data read through it.
class _CrcInStream implements InStream {
  final InStream base;
  int crc = 0xFFFFFFFF;
  int size = 0;
  _CrcInStream(this.base);
  @override
  int read(Uint8List buf, int off, int len) {
    final n = base.read(buf, off, len);
    if (n > 0) {
      crc = crc32Update(crc, buf, off, off + n);
      size += n;
    }
    return n;
  }

  int get crcValue => crc ^ 0xFFFFFFFF;
}

/// The result of decoding the members of a gzip stream.
class _DecodeResult {
  int opRes = OperationResult.ok;
  int numMembers = 0;
  int unpackSize = 0;
  int packSize = 0; // up to the end of the last good member
}

/// The gzip handler (IInArchive, IArchiveOpenSeq, ISetProperties,
/// IOutArchive).
class GzipHandler {
  SeekableInStream? _stream;
  InStream? _seqStream;
  bool _isArc = false;
  bool _needSeekToStart = false;

  final GzipHeader _header = GzipHeader();
  bool _headerDefined = false;

  // from the end of the file (open with a seekable stream)
  int? _packSize;
  int? _tailCrc;
  int? _tailSize;

  // from a full decode
  bool _decoded = false;
  final _DecodeResult _dec = _DecodeResult();

  // ---- IOutArchive side ----
  /// CMultiMethodProps (level, threads) and the time options.
  final MultiMethodProps props = MultiMethodProps();
  final HandlerTimeOptions timeOptions = HandlerTimeOptions();

  /// kProps: what 7-Zip lists for a gzip item.
  static const List<int> itemPropIds = [
    Kpid.path,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.hostOS,
    Kpid.crc,
  ];

  /// kArcProps
  static const List<int> archivePropIds = [Kpid.headersSize];

  /// IInArchive::GetNumberOfItems
  int get numberOfItems => 1;

  /// The first member header (null when not read).
  GzipHeader? get header => _headerDefined ? _header : null;

  /// Number of members found by the last extract or test (null before).
  int? get numMembers => _decoded ? _dec.numMembers : null;

  /// IInArchive::GetArchiveProperty
  Object? getArchiveProperty(int propID) {
    switch (propID) {
      case Kpid.headersSize:
        return _headerDefined ? _header.headerSize : null;
      case Kpid.phySize:
        return _decoded ? _dec.packSize : null;
      case Kpid.errorFlags:
        return _isArc ? null : ErrorFlags.isNotArc;
    }
    return null;
  }

  /// IInArchive::GetProperty
  Object? getProperty(int index, int propID) {
    switch (propID) {
      case Kpid.path:
        return _headerDefined ? _header.nameString : null;
      case Kpid.size:
        if (_decoded && _dec.opRes == OperationResult.ok) {
          return _dec.unpackSize;
        }
        return _tailSize;
      case Kpid.packSize:
        return _packSize ?? (_decoded ? _dec.packSize : null);
      case Kpid.mTime:
        if (!_headerDefined || _header.mTime == 0) return null;
        return _header.mTime * 10000000 + _kUnixEpochFileTime;
      case Kpid.hostOS:
        if (!_headerDefined) return null;
        final os = _header.hostOs;
        return os < gzipHostOsNames.length ? gzipHostOsNames[os] : '$os';
      case Kpid.crc:
        return _tailCrc;
      case Kpid.comment:
        return _headerDefined ? _header.commentString : null;
    }
    return null;
  }

  /// IInArchive::Open. Returns false when [inStream] is not a gzip file
  /// (S_FALSE).
  bool open(SeekableInStream inStream, {ArchiveProgress? callback}) {
    close();
    inStream.position = 0;
    final buf = _InBuffer(inStream, 1 << 12);
    if (buf.readHeader(_header) != _hdrOk) return false;
    _headerDefined = true;
    final len = inStream.length;
    _packSize = len;
    callback?.setTotal(len);
    if (len >= _header.headerSize + 8) {
      final t = Uint8List(8);
      inStream.position = len - 8;
      readExactly(inStream, t, 0, 8);
      _tailCrc = getUint32LE(t, 0);
      _tailSize = getUint32LE(t, 4);
    }
    inStream.position = 0;
    _stream = inStream;
    _seqStream = inStream;
    _isArc = true;
    _needSeekToStart = true;
    return true;
  }

  /// IArchiveOpenSeq::OpenSeq: the header and sizes are known after
  /// [extract].
  void openSeq(InStream stream) {
    close();
    _seqStream = stream;
    _isArc = true;
    _needSeekToStart = false;
  }

  /// The decoded data of every member as a sequential stream
  /// (IInArchiveGetStream::GetStream for item 0), for a tar inside the
  /// gzip file read without a temporary file. The archive stream is
  /// rewound when it was read before; a stream opened with [openSeq] can
  /// be read once.
  InStream? getSeqStream() {
    final s = _seqStream;
    if (s == null) return null;
    if (_needSeekToStart) {
      final st = _stream;
      if (st == null) return null;
      st.position = 0;
    } else {
      _needSeekToStart = true;
    }
    return GzipDecoderInStream(s);
  }

  /// IInArchive::Close
  void close() {
    _stream = null;
    _seqStream = null;
    _isArc = false;
    _needSeekToStart = false;
    _headerDefined = false;
    _packSize = null;
    _tailCrc = null;
    _tailSize = null;
    _decoded = false;
  }

  // Decodes every member of [input] to [out]; fills [_dec].
  void _decode(InStream input, OutStream out, ArchiveProgress progress) {
    final r = _dec
      ..opRes = OperationResult.ok
      ..numMembers = 0
      ..unpackSize = 0
      ..packSize = 0;
    final buf = _InBuffer(input);
    final z = InflateState();
    final outBuf = Uint8List(1 << 17);
    final h = GzipHeader();
    var nextProgress = 0;

    for (;;) {
      final first = r.numMembers == 0;
      final hres = buf.readHeader(first ? _header : h);
      if (hres != _hdrOk) {
        if (first) {
          r.opRes = hres == _hdrEnd
              ? OperationResult.unexpectedEnd
              : OperationResult.isNotArc;
        } else {
          // anything after the last member that is not a complete, valid
          // member header (zeros, garbage, a truncated header)
          r.opRes = OperationResult.dataAfterEnd;
        }
        break;
      }
      if (first) _headerDefined = true;

      // the deflate data
      z.inflateReset();
      var crc = 0xFFFFFFFF;
      var size = 0;
      var memberOpRes = OperationResult.ok;
      for (;;) {
        if (buf.pos == buf.lim) buf.fill();
        z.nextIn = buf.data;
        z.nextInPos = buf.pos;
        z.availIn = buf.lim - buf.pos;
        z.nextOut = outBuf;
        z.nextOutPos = 0;
        z.availOut = outBuf.length;
        final ret = z.inflate(ZFlush.noFlush);
        buf.pos = z.nextInPos;
        final produced = outBuf.length - z.availOut;
        if (produced != 0) {
          crc = crc32Update(crc, outBuf, 0, produced);
          size += produced;
          out.write(outBuf, 0, produced);
        }
        if (ret == ZResult.streamEnd) break;
        if (ret == ZResult.dataError) {
          memberOpRes = OperationResult.dataError;
          break;
        }
        if (ret == ZResult.bufError && buf.eof && buf.pos == buf.lim) {
          memberOpRes = OperationResult.unexpectedEnd;
          break;
        }
        if (buf.processed >= nextProgress) {
          nextProgress = buf.processed + (1 << 20);
          progress.setCompleted(buf.processed);
        }
      }
      r.unpackSize += size;
      if (memberOpRes != OperationResult.ok) {
        r.opRes = memberOpRes;
        break;
      }

      // the trailer: CRC32 and ISIZE
      final t = Uint8List(8);
      var got = 0;
      for (; got < 8; got++) {
        final v = buf.readByte();
        if (v < 0) break;
        t[got] = v;
      }
      if (got < 8) {
        r.opRes = OperationResult.unexpectedEnd;
        break;
      }
      r.numMembers++;
      r.packSize = buf.processed;
      if (getUint32LE(t, 0) != (crc ^ 0xFFFFFFFF) ||
          getUint32LE(t, 4) != (size & 0xFFFFFFFF)) {
        r.opRes = OperationResult.crcError;
        break;
      }
      if (buf.atEnd) break;
    }
    out.flush();
    progress.setCompleted(buf.processed);
  }

  /// IInArchive::Extract. [indices] null means all items. Calls
  /// [extractCallback].setOperationResult with an [OperationResult].
  void extract(List<int>? indices, bool testMode,
      ArchiveExtractCallback extractCallback) {
    if (indices != null) {
      if (indices.isEmpty) return;
      if (indices.length != 1 || indices[0] != 0) {
        throw const SevenZipException(
            'gzip: E_INVALIDARG', SevenZipError.unsupported);
      }
    }
    final pack = _packSize;
    if (pack != null) extractCallback.setTotal(pack);
    extractCallback.setCompleted(0);

    final askMode = testMode ? AskMode.test : AskMode.extract;
    final realOutStream = extractCallback.getStream(0, askMode);
    if (!testMode && realOutStream == null) return;
    extractCallback.prepareOperation(askMode);

    if (_needSeekToStart) {
      final s = _stream;
      if (s == null) throw const SevenZipException('gzip: E_FAIL');
      s.position = 0;
    } else {
      _needSeekToStart = true;
    }

    _decode(_seqStream!, realOutStream ?? NullOutStream(), extractCallback);
    _decoded = true;
    if (_dec.numMembers > 0 && _dec.opRes == OperationResult.ok) {
      // a stream opened with OpenSeq gets its sizes here
      _packSize ??= _dec.packSize;
    }
    extractCallback.setOperationResult(_dec.opRes);
  }

  /// IOutArchive::GetFileTimeType
  int getFileTimeType() => FileTimeType.unix;

  // CHandler::SetProperty
  void _setProperty(String name, PropVariant value) {
    final lower = name.toLowerCase();
    if (lower.isEmpty) invalidArg();
    if (timeOptions.parse(lower, value)) return;
    if (lower[0] == 'x') {
      props.setProperty(lower, value); // the level
      return;
    }
    if (props.setCommonProperty(lower, value)) return; // mt, memuse
    // 7-Zip's deflate encoder tuning (fast bytes, passes, match finder
    // cycles, algorithm): accepted, not used by the zlib encoder.
    if (lower == 'fb' || lower == 'pass' || lower == 'mc' || lower == 'a') {
      parsePropToUInt32('', value, 0);
      return;
    }
    // the method: only Deflate
    if (lower == 'm' || lower == '0') {
      if (value.vt == VarType.bstr &&
          value.stringValue.toLowerCase() == 'deflate') {
        return;
      }
      invalidArg('gzip supports only the Deflate method');
    }
    invalidArg('Unsupported gzip property: $name');
  }

  /// ISetProperties::SetProperties: the -m switch pairs, for example
  /// ("x", "9"), ("tm", false). Throws [InvalidArgException] for invalid
  /// properties.
  void setProperties(List<MapEntry<String, PropVariant>> properties) {
    props.init();
    timeOptions.init();
    for (final p in properties) {
      _setProperty(p.key, p.value);
    }
  }

  /// [setProperties] from string pairs as the command line gives them.
  void setPropertiesFromStrings(List<MapEntry<String, String>> properties) {
    setProperties([
      for (final p in properties) convertCliProperty(p.key, p.value),
    ]);
  }

  /// The compression level used by [updateItems] (-mx, 5 by default).
  int get level {
    final l = props.getLevel();
    return l > 9 ? 9 : l;
  }

  // The header for new data from the item properties.
  GzipHeader _newHeader(ArchiveUpdateCallback cb, int lvl) {
    final h = GzipHeader()
      ..extraFlags = lvl >= 7 ? _kXflMaximum : _kXflFastest
      ..hostOs = Platform.isWindows ? gzipHostOsFat : gzipHostOsUnix;
    final path = cb.getProperty(0, Kpid.path);
    if (path is String && path.isNotEmpty) {
      var i = path.lastIndexOf('/');
      if (Platform.isWindows) {
        final j = path.lastIndexOf('\\');
        if (j > i) i = j;
      }
      final name = path.substring(i + 1);
      if (name.isNotEmpty) h.name = Uint8List.fromList(utf8.encode(name));
    }
    if (timeOptions.writeMTime.val) {
      final mt = cb.getProperty(0, Kpid.mTime);
      if (mt is int) {
        final sec = (mt - _kUnixEpochFileTime) ~/ 10000000;
        if (mt >= _kUnixEpochFileTime && sec <= 0xFFFFFFFF) h.mTime = sec;
      }
    }
    return h;
  }

  /// IOutArchive::UpdateItems: writes a new gzip file to [outStream] from
  /// item 0 of [updateCallback]: the new data, or the data of the open
  /// archive (copied, with a new first header when only the properties
  /// changed).
  void updateItems(
      OutStream outStream, int numItems, ArchiveUpdateCallback updateCallback) {
    if (numItems != 1) {
      throw const SevenZipException(
          'gzip: only one file can be compressed', SevenZipError.unsupported);
    }
    final info = updateCallback.getUpdateItemInfo(0);

    if (info.newProps) {
      final prop = updateCallback.getProperty(0, Kpid.isDir);
      if (prop != null && (prop is! bool || prop != false)) {
        throw const SevenZipException(
            'gzip: directories are not supported', SevenZipError.unsupported);
      }
    }

    if (info.newData) {
      final prop = updateCallback.getProperty(0, Kpid.size);
      var dataSize = prop is int ? prop : 0;
      final lvl = level;
      final h = _newHeader(updateCallback, lvl);
      final fileInStream = updateCallback.getStream(0);
      if (fileInStream == null) return; // S_FALSE
      if (fileInStream is StreamGetSize) {
        final size = (fileInStream as StreamGetSize).streamSize;
        if (size != null) dataSize = size;
      }
      updateCallback.setTotal(dataSize);
      final hb = h.toBytes();
      outStream.write(hb, 0, hb.length);
      final crcIn = _CrcInStream(fileInStream);
      DeflateCompressor(level: lvl).encode(crcIn, outStream,
          progress: (inSize, outSize) => updateCallback.setCompleted(inSize));
      final t = Uint8List(8);
      setUint32LE(t, 0, crcIn.crcValue);
      setUint32LE(t, 4, crcIn.size & 0xFFFFFFFF);
      outStream.write(t, 0, 8);
      outStream.flush();
      updateCallback.setOperationResult(0); // NUpdate::NOperationResult::kOK
      return;
    }

    if (info.indexInArchive != 0) {
      throw const SevenZipException(
          'gzip: E_INVALIDARG', SevenZipError.unsupported);
    }
    final stream = _stream;
    if (stream == null || !_headerDefined) {
      throw const SevenZipException('gzip: E_FAIL');
    }
    if (updateCallback is ArchiveUpdateCallbackFile) {
      (updateCallback as ArchiveUpdateCallbackFile).reportOperation(
          EventIndexType.inArcIndex, 0, UpdateNotifyOp.replicate);
    }
    updateCallback.setTotal(stream.length);
    var skip = 0;
    if (info.newProps) {
      // a new first header (name and time), the rest is copied
      final h = GzipHeader()
        ..extraFlags = _header.extraFlags
        ..hostOs = _header.hostOs
        ..extra = _header.extra
        ..comment = _header.comment
        ..mTime = _header.mTime;
      final nh = _newHeader(updateCallback, level);
      h.name = nh.name;
      if (updateCallback.getProperty(0, Kpid.mTime) != null) h.mTime = nh.mTime;
      final hb = h.toBytes(
          withHcrc: (_header.flags & GzipFlags.hcrc) != 0);
      outStream.write(hb, 0, hb.length);
      skip = _header.headerSize;
    }
    stream.position = skip;
    copyStream(stream, outStream);
    outStream.flush();
  }
}

/// The members of a gzip stream decoded as a pull stream: the loop of
/// [GzipHandler._decode] turned inside out. Throws [SevenZipException]
/// (data, crc, unexpectedEnd, isNotArc) for bad data; data after the last
/// member ends the stream and sets [dataAfterEnd].
class GzipDecoderInStream implements InStream {
  final _InBuffer _in;
  final InflateState _z = InflateState();
  final GzipHeader _h = GzipHeader();

  // 0: at a member header, 1: in the deflate data, 2: at the end
  int _state = 0;
  int _crc = 0xFFFFFFFF;
  int _size = 0;

  /// Members decoded to their trailer.
  int numMembers = 0;

  /// Bytes after the last member that are not a member.
  bool dataAfterEnd = false;

  GzipDecoderInStream(InStream input) : _in = _InBuffer(input);

  /// Bytes of the input consumed so far.
  int get inProcessed => _in.processed;

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    for (;;) {
      if (_state == 2) return 0;
      if (_state == 0) {
        final r = _in.readHeader(_h);
        if (r != _hdrOk) {
          if (numMembers == 0) {
            throw SevenZipException(
                'gzip: bad header',
                r == _hdrEnd
                    ? SevenZipError.unexpectedEnd
                    : SevenZipError.isNotArc);
          }
          dataAfterEnd = true;
          _state = 2;
          return 0;
        }
        _z.inflateReset();
        _crc = 0xFFFFFFFF;
        _size = 0;
        _state = 1;
      }
      if (_in.pos == _in.lim) _in.fill();
      _z.nextIn = _in.data;
      _z.nextInPos = _in.pos;
      _z.availIn = _in.lim - _in.pos;
      _z.nextOut = buf;
      _z.nextOutPos = off;
      _z.availOut = len;
      final ret = _z.inflate(ZFlush.noFlush);
      _in.pos = _z.nextInPos;
      final produced = len - _z.availOut;
      if (produced != 0) {
        _crc = crc32Update(_crc, buf, off, off + produced);
        _size += produced;
      }
      if (ret == ZResult.streamEnd) {
        _readTrailer();
        if (produced != 0) return produced;
        continue;
      }
      if (ret == ZResult.dataError) {
        throw const SevenZipException('gzip: data error', SevenZipError.data);
      }
      if (ret == ZResult.bufError && _in.eof && _in.pos == _in.lim) {
        throw const SevenZipException(
            'gzip: unexpected end of data', SevenZipError.unexpectedEnd);
      }
      if (produced != 0) return produced;
    }
  }

  // the CRC-32 and ISIZE of the member (RFC 1952 2.3.1)
  void _readTrailer() {
    final t = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      final v = _in.readByte();
      if (v < 0) {
        throw const SevenZipException(
            'gzip: unexpected end of data', SevenZipError.unexpectedEnd);
      }
      t[i] = v;
    }
    if (getUint32LE(t, 0) != (_crc ^ 0xFFFFFFFF) ||
        getUint32LE(t, 4) != (_size & 0xFFFFFFFF)) {
      throw const SevenZipException('gzip: CRC error', SevenZipError.crc);
    }
    numMembers++;
    _state = _in.atEnd ? 2 : 0;
  }
}

// ---------------------------------------------------------------------------
// Convenience API

class _SingleExtractCallback extends ArchiveExtractCallback {
  final OutStream? out;
  final ProgressCallback? progress;
  int result = OperationResult.ok;
  _SingleExtractCallback(this.out, this.progress);

  @override
  OutStream? getStream(int index, int askMode) => out;

  @override
  void setCompleted(int completeValue) => progress?.call(completeValue, 0);

  @override
  void setOperationResult(int opRes) => result = opRes;
}

class _SingleUpdateCallback extends ArchiveUpdateCallback
    implements StreamGetSize {
  final InStream input;
  final int size;
  final String? name;
  final int? mTime;
  final ProgressCallback? progress;
  _SingleUpdateCallback(
      this.input, this.size, this.name, this.mTime, this.progress);

  @override
  UpdateItemInfo getUpdateItemInfo(int index) =>
      const UpdateItemInfo(true, true, -1);

  @override
  Object? getProperty(int index, int propId) {
    switch (propId) {
      case Kpid.size:
        return size;
      case Kpid.isDir:
        return false;
      case Kpid.path:
        return name;
      case Kpid.mTime:
        return mTime;
    }
    return null;
  }

  @override
  InStream? getStream(int index) => input;

  @override
  int? get streamSize => size;

  @override
  void setCompleted(int completeValue) => progress?.call(completeValue, 0);
}

/// A convenience view of a gzip file: open, list, extract and test, and
/// [create].
class GzipArchive {
  final GzipHandler handler = GzipHandler();

  GzipArchive._();

  /// Opens [stream]. Returns null when it is not a gzip file.
  static GzipArchive? open(SeekableInStream stream) {
    final a = GzipArchive._();
    if (!a.handler.open(stream)) return null;
    return a;
  }

  /// Opens a sequential stream: the header and sizes are known only after
  /// [extract] or [test].
  static GzipArchive openSeq(InStream stream) =>
      GzipArchive._()..handler.openSeq(stream);

  /// The stored file name (FNAME), or null.
  String? get name => handler.getProperty(0, Kpid.path) as String?;

  /// The comment (FCOMMENT), or null.
  String? get comment => handler.getProperty(0, Kpid.comment) as String?;

  /// MTIME of the first member, null when not stored.
  DateTime? get mTime {
    final h = handler.header;
    if (h == null || h.mTime == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(h.mTime * 1000, isUtc: true);
  }

  /// Unpacked size: ISIZE of the last member (modulo 2^32) after open,
  /// the real total after [extract] or [test].
  int? get size => handler.getProperty(0, Kpid.size) as int?;

  /// Size of the gzip file.
  int? get packSize => handler.getProperty(0, Kpid.packSize) as int?;

  /// Number of members found by [extract] or [test].
  int? get numMembers => handler.numMembers;

  /// Decodes to [out]; returns an [OperationResult] value.
  int extract(OutStream out, {ProgressCallback? progress}) {
    final cb = _SingleExtractCallback(out, progress);
    handler.extract(null, false, cb);
    return cb.result;
  }

  /// Decodes without output; returns an [OperationResult] value.
  int test({ProgressCallback? progress}) {
    final cb = _SingleExtractCallback(null, progress);
    handler.extract(null, true, cb);
    return cb.result;
  }

  /// Creates a gzip file from [input] ([size] bytes) with the file [name]
  /// and modification time [mTime] in the header, and the -m properties of
  /// the handler, for example `[MapEntry('x', '9')]`.
  static void create(InStream input, OutStream output, int size,
      {String? name,
      DateTime? mTime,
      List<MapEntry<String, String>> properties = const [],
      ProgressCallback? progress}) {
    final h = GzipHandler();
    h.setPropertiesFromStrings(properties);
    final ft = mTime == null
        ? null
        : mTime.toUtc().microsecondsSinceEpoch * 10 + _kUnixEpochFileTime;
    h.updateItems(
        output, 1, _SingleUpdateCallback(input, size, name, ft, progress));
  }
}
