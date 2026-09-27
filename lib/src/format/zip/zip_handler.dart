// The zip archive handler: IInArchive (Open, OpenSeq, GetProperty, Extract,
// GetStream) over the structures of zip_in.dart, and IOutArchive
// (UpdateItems, SetProperties) over zip_update.dart.
//
// Written from the PKWARE APPNOTE and the WinZip AES specification, with
// libarchive's zip reader (BSD 2-clause, see LICENSE) as the model for the
// tolerant parts. The item properties, the error flags and the update
// rules follow what 7-Zip shows and writes for zip archives; the 7-Zip zip
// handler itself is LGPL and was not used (docs/architecture.md, section
// 10).

import 'dart:convert';
import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../crypto/hmac_sha1.dart';
import '../../crypto/winzip_aes.dart';
import '../../crypto/zip_crypto.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import 'zip_decode.dart';
import 'zip_header.dart';
import 'zip_in.dart';
import 'zip_update.dart';

/// k_PropVar_TimePrec_Base + 7 (100 ns, FILETIME).
const int _kTimePrec100ns = 16 + 7;

/// Gives the stream of another volume of a multi-volume archive by name,
/// or null when it can not be opened.
typedef ZipVolumeOpener = SeekableInStream? Function(String name);

/// IsArc_Zip: whether [p] (the first [size] bytes of a file) starts like a
/// zip archive: a local header with sane fields, an empty archive (an end
/// of central directory record), or the marker of a spanned archive
/// followed by a local header. 0 no, 1 yes, 2 more data needed
/// (k_IsArc_Res_*).
int isArcZip(Uint8List p, int size) {
  if (size < 4) return 2;
  if (p[0] != 0x50 || p[1] != 0x4B) return 0;
  var o = 0;
  var sig = getUint32LE(p, 0);
  if (sig == ZipSig.spanMarker || sig == ZipSig.tempSpanMarker) {
    if (size < 8) return 2;
    o = 4;
    sig = getUint32LE(p, 4);
  }
  if (sig == ZipSig.eocd) {
    if (size < o + kEocdSize) return 2;
    // an empty archive: no entries, no central directory
    for (var i = o + 4; i < o + 20; i++) {
      if (p[i] != 0) return 0;
    }
    return 1;
  }
  if (sig != ZipSig.local) return 0;
  if (size < o + kLocalHeaderSize) return 2;
  final nameLen = p[o + 26] | (p[o + 27] << 8);
  final method = p[o + 8] | (p[o + 9] << 8);
  final version = p[o + 4];
  if (nameLen == 0 && method > 0x100) return 0;
  if (version > 100) return 0;
  return 1;
}

/// The zip handler.
class ZipHandler {
  SeekableInStream? _stream;
  final List<SeekableInStream> _volumes = [];
  final List<ZipItem> items = [];

  bool _isArc = false;
  bool _headersError = false;
  bool _unexpectedEnd = false;
  bool _unavailable = false;
  bool _warning = false;
  int _phySize = 0;
  bool _phySizeDefined = false;
  int _offset = 0;
  int _stubSize = 0;
  Uint8List? _comment;
  bool _isZip64 = false;
  int _numVolumes = 1;
  int _totalPhySize = 0;
  bool _anyNtfsTime = false;

  // the items come from local headers only (no central directory)
  bool _local = false;

  // OpenSeq state
  ZipSeqReader? _seqReader;
  int _seqDataItem = -1;
  bool _seqEnd = false;

  /// Code page of names without the UTF-8 flag (-mcp), [ZipCodePage].
  int codePage = ZipCodePage.auto;

  /// The write options (-m switches).
  final ZipWriteOptions writeOptions = ZipWriteOptions();

  // IInArchive

  /// IInArchive::Open. false (S_FALSE) when [stream] is not a zip archive.
  /// [volumeName] and [openVolume] give the other volumes of a split
  /// archive (name.z01, name.z02... with name.zip the last one).
  bool open(SeekableInStream stream,
      {int maxCheckStartPosition = 0,
      String? volumeName,
      ZipVolumeOpener? openVolume}) {
    close();
    final len = stream.length;
    final first = Uint8List(4);
    stream.position = 0;
    final n0 = readFully(stream, first, 0, 4);
    final startSig = n0 == 4 ? getUint32LE(first, 0) : 0;
    final startsLikeZip = startSig == ZipSig.local ||
        startSig == ZipSig.spanMarker ||
        startSig == ZipSig.tempSpanMarker ||
        startSig == ZipSig.eocd;

    final eocd = findEocd(stream);
    if (eocd == null) {
      if (startSig != ZipSig.local &&
          startSig != ZipSig.spanMarker &&
          startSig != ZipSig.tempSpanMarker) {
        return false;
      }
      // no central directory (truncated): the local headers
      _stream = stream;
      _isArc = true;
      _scanLocalHeaders(stream);
      _unexpectedEnd = true;
      return true;
    }

    if (eocd.thisDisk != 0 || eocd.cdDisk != 0) {
      // a split or spanned archive: this is the last volume
      _numVolumes = eocd.thisDisk + 1;
      if (!_openVolumes(stream, eocd, volumeName, openVolume)) {
        _stream = stream;
        _isArc = true;
        _unavailable = true;
        _readCentralOfLastVolume(stream, eocd);
        return true;
      }
      _isArc = true;
      _comment = eocd.comment;
      _isZip64 = eocd.isZip64;
      _readCentral(_stream!, eocd, 0);
      // as 7-Zip: the size of the last volume, and the total; the span
      // marker of the first volume is shown as a stub
      _phySize = len;
      var minPos = _totalPhySize;
      for (final it in items) {
        if (it.localPos < minPos) minPos = it.localPos;
      }
      if (minPos > 0 && minPos < _totalPhySize) _stubSize = minPos;
      _phySizeDefined = true;
      return true;
    }

    // one volume: find the base of the offsets (data in front of the
    // archive moves everything)
    final cdEnd = eocd.isZip64 ? eocd.zip64Pos : eocd.pos;
    var base = cdEnd - eocd.cdSize - eocd.cdOffset;
    if (eocd.numEntries > 0 || eocd.cdSize > 0) {
      if (!_isCentralAt(stream, eocd.cdOffset + base)) {
        if (_isCentralAt(stream, eocd.cdOffset)) {
          base = 0;
        } else if (startSig == ZipSig.local) {
          // damaged central directory: the local headers
          _stream = stream;
          _isArc = true;
          _headersError = true;
          _scanLocalHeaders(stream);
          return true;
        } else {
          return false;
        }
      }
    }
    if (!startsLikeZip && maxCheckStartPosition == 0 && base > 0) {
      // not at the start of the stream: let the caller find the start
      if (eocd.pos - base < 0) return false;
    }
    _stream = stream;
    _isArc = true;
    _isZip64 = eocd.isZip64;
    _comment = eocd.comment;
    _readCentral(stream, eocd, base);
    if (base > 0) {
      _offset = base;
      _phySize = eocd.end - base;
    } else {
      _phySize = eocd.end;
      var minPos = eocd.cdOffset + base;
      for (final it in items) {
        if (it.localPos < minPos) minPos = it.localPos;
      }
      if (minPos > 0 && base == 0) _stubSize = minPos;
    }
    if (eocd.end > len) _unexpectedEnd = true;
    _phySizeDefined = true;
    return true;
  }

  static bool _isCentralAt(SeekableInStream s, int pos) {
    if (pos < 0 || pos + 4 > s.length) return false;
    final b = Uint8List(4);
    s.position = pos;
    if (readFully(s, b, 0, 4) != 4) return false;
    final sig = getUint32LE(b, 0);
    return sig == ZipSig.central ||
        sig == ZipSig.zip64Eocd ||
        sig == ZipSig.eocd;
  }

  // reads the central directory at eocd.cdOffset + base (single volume)
  // or on the volume eocd.cdDisk (multi-volume stream)
  void _readCentral(SeekableInStream s, ZipEocd eocd, int base) {
    final cdPos = _volumes.isEmpty
        ? eocd.cdOffset + base
        : _volStart(eocd.cdDisk) + eocd.cdOffset;
    var cdSize = eocd.cdSize;
    final avail = s.length - cdPos;
    if (cdSize > avail) {
      cdSize = avail < 0 ? 0 : avail;
      _unexpectedEnd = true;
    }
    final cd = Uint8List(cdSize);
    s.position = cdPos;
    readFully(s, cd, 0, cdSize);
    final list =
        parseCentralDirectory(cd, codePage, () => _headersError = true);
    for (final it in list) {
      if (_volumes.isEmpty) {
        it.localPos = it.localOffset + base;
      } else {
        it.localPos = _volStart(it.disk) + it.localOffset;
      }
      if (it.ntfsMTime != null) _anyNtfsTime = true;
      if (it.zip64) _isZip64 = true;
      items.add(it);
    }
    if (list.length != eocd.numEntries &&
        (eocd.numEntries & 0xFFFF) != (list.length & 0xFFFF)) {
      _headersError = true;
    }
  }

  // the central directory when the other volumes are missing: listed,
  // with no data available
  void _readCentralOfLastVolume(SeekableInStream s, ZipEocd eocd) {
    _comment = eocd.comment;
    if (eocd.cdDisk == eocd.thisDisk) {
      final cdPos = eocd.cdOffset;
      var cdSize = eocd.cdSize;
      if (cdPos + cdSize > s.length) cdSize = s.length - cdPos;
      if (cdSize > 0) {
        final cd = Uint8List(cdSize);
        s.position = cdPos;
        readFully(s, cd, 0, cdSize);
        items.addAll(
            parseCentralDirectory(cd, codePage, () => _headersError = true));
      }
    }
    for (final it in items) {
      it.localPos = -1;
    }
    _phySize = s.length;
    _phySizeDefined = true;
  }

  int _volStart(int disk) {
    var p = 0;
    for (var i = 0; i < disk && i < _volumes.length; i++) {
      p += _volumes[i].length;
    }
    return p;
  }

  bool _openVolumes(SeekableInStream last, ZipEocd eocd, String? name,
      ZipVolumeOpener? openVolume) {
    if (name == null || openVolume == null) return false;
    final dot = name.lastIndexOf('.');
    final baseName = dot >= 0 ? name.substring(0, dot) : name;
    final ext = dot >= 0 ? name.substring(dot + 1) : '';
    final upper = ext.isNotEmpty &&
        ext[0] == ext[0].toUpperCase() &&
        ext != ext.toLowerCase();
    final vols = <SeekableInStream>[];
    for (var i = 1; i <= eocd.thisDisk; i++) {
      final num = i.toString().padLeft(2, '0');
      final vn = '$baseName.${upper ? 'Z' : 'z'}$num';
      final v = openVolume(vn);
      if (v == null) {
        return false;
      }
      vols.add(v);
    }
    vols.add(last);
    _volumes.addAll(vols);
    _stream = _VolumesInStream(vols);
    _totalPhySize = _stream!.length;
    return true;
  }

  // reads the local headers from the start (no usable central directory)
  void _scanLocalHeaders(SeekableInStream s) {
    _local = true;
    s.position = 0;
    final input = ZipSeqInput(_PositionedInStream(s));
    final reader = ZipSeqReader(input, codePage);
    final buf = Uint8List(1 << 16);
    for (;;) {
      final (r, it) = reader.next();
      if (r == ZipSeqResult.centralDirectory) {
        _phySize = input.pos;
        break;
      }
      if (r != ZipSeqResult.item) {
        if (r == ZipSeqResult.headersError) _headersError = true;
        _unexpectedEnd = true;
        _phySize = input.pos;
        break;
      }
      final item = it!;
      items.add(item);
      if (!_seqSkipData(input, reader, item, buf, null)) {
        _unexpectedEnd = true;
        _phySize = input.pos;
        break;
      }
    }
    _phySizeDefined = true;
    for (final it in items) {
      if (it.ntfsMTime != null) _anyNtfsTime = true;
    }
  }

  /// IArchiveOpenSeq::OpenSeq: reads the first local header. false when
  /// the stream does not start with one.
  bool openSeq(InStream stream) {
    close();
    final input = ZipSeqInput(stream);
    final reader = ZipSeqReader(input, codePage);
    final (r, it) = reader.next();
    if (r == ZipSeqResult.headersError) return false;
    _seqReader = reader;
    _isArc = true;
    _local = true;
    if (r == ZipSeqResult.item) {
      items.add(it!);
      _seqDataItem = 0;
    } else {
      _seqEnd = true;
      _phySize = input.pos;
      _phySizeDefined = true;
      if (r != ZipSeqResult.centralDirectory) _unexpectedEnd = true;
    }
    return true;
  }

  // skips the data of [it] in sequential reading; false when the data or
  // its descriptor is incomplete (or can not be skipped: encrypted data of
  // unknown size without a password)
  bool _seqSkipData(ZipSeqInput input, ZipSeqReader reader, ZipItem it,
      Uint8List buf, String? password) {
    if (_packSizeKnown(it)) {
      if (input.skip(it.packSize) != it.packSize) {
        it.truncated = true;
        return false;
      }
      if (it.hasDescriptor) reader.readDescriptor(it);
      return !it.truncated;
    }
    // unknown size: decode to find the end
    final res = _decodeSeqItem(input, reader, it, null, buf, password);
    return res == OperationResult.ok || res == OperationResult.crcError;
  }

  // whether the packed size of an item read from its local header can be
  // used: with a data descriptor the header sizes are not reliable (Info-ZIP
  // writes the unpacked size there when it streams), so the decoder finds
  // the end of the data, or for stored data the descriptor is searched;
  // other methods have to trust the header
  static bool _packSizeKnown(ZipItem it) {
    if (!it.hasDescriptor) return true;
    switch (it.realMethod) {
      case ZipMethod.store:
      case ZipMethod.deflate:
      case ZipMethod.deflate64:
      case ZipMethod.bzip2:
      case ZipMethod.lzma:
        return false;
    }
    return it.packSize != 0;
  }

  // reads the next header in OpenSeq mode, skipping the data of the
  // current item; false at the end
  bool _seqNext() {
    final reader = _seqReader!;
    if (_seqEnd) return false;
    final input = reader.input;
    if (_seqDataItem >= 0) {
      final last = items[_seqDataItem];
      _seqDataItem = -1;
      if (!_seqSkipData(input, reader, last, Uint8List(1 << 16), null)) {
        _unexpectedEnd = true;
        _seqEnd = true;
        _phySize = input.pos;
        _phySizeDefined = true;
        return false;
      }
    }
    final (r, it) = reader.next();
    if (r == ZipSeqResult.item) {
      items.add(it!);
      _seqDataItem = items.length - 1;
      return true;
    }
    if (r != ZipSeqResult.centralDirectory) {
      _unexpectedEnd = true;
      if (r == ZipSeqResult.headersError) _headersError = true;
    }
    _seqEnd = true;
    _phySize = input.pos;
    _phySizeDefined = true;
    return false;
  }

  bool _seqEnsure(int index) {
    while (index >= items.length) {
      if (!_seqNext()) return false;
    }
    return true;
  }

  /// IInArchive::Close.
  void close() {
    _stream = null;
    for (final v in _volumes) {
      releaseStream(v);
    }
    _volumes.clear();
    items.clear();
    _isArc = false;
    _headersError = false;
    _unexpectedEnd = false;
    _unavailable = false;
    _warning = false;
    _phySize = 0;
    _phySizeDefined = false;
    _offset = 0;
    _stubSize = 0;
    _comment = null;
    _isZip64 = false;
    _numVolumes = 1;
    _totalPhySize = 0;
    _anyNtfsTime = false;
    _local = false;
    _seqReader = null;
    _seqDataItem = -1;
    _seqEnd = false;
  }

  /// The archive stream (for the update: kept items are copied from it).
  SeekableInStream? get stream => _stream;

  /// Whether the archive was read from a stream with OpenSeq.
  bool get isSeq => _seqReader != null;

  /// GetNumberOfItems. In OpenSeq mode this reads all the remaining
  /// headers (skipping the data).
  int get numberOfItems {
    if (_seqReader != null) {
      while (_seqNext()) {}
    }
    return items.length;
  }

  /// The item properties in 7-Zip's listing order.
  static const List<int> itemPropIds = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.aTime,
    Kpid.attrib,
    Kpid.encrypted,
    Kpid.comment,
    Kpid.crc,
    Kpid.method,
    Kpid.characts,
    Kpid.hostOS,
    Kpid.unpackVer,
    Kpid.volumeIndex,
    Kpid.offset,
  ];

  /// The archive properties.
  static const List<int> archivePropIds = [
    Kpid.embeddedStubSize,
    Kpid.bit64,
    Kpid.comment,
    Kpid.characts,
    Kpid.totalPhySize,
    Kpid.isVolume,
    Kpid.volumeIndex,
    Kpid.numVolumes,
  ];

  /// 100 ns when an item has NTFS times, else whole seconds.
  int get timePrec => _anyNtfsTime ? _kTimePrec100ns : FileTimeType.unix;

  int get errorFlags {
    var v = 0;
    if (!_isArc) v |= ErrorFlags.isNotArc;
    if (_headersError) v |= ErrorFlags.headersError;
    if (_unexpectedEnd) v |= ErrorFlags.unexpectedEnd;
    if (_unavailable) v |= ErrorFlags.unavailableStart;
    return v;
  }

  String _decodeComment(Uint8List b) => decodeZipString(b, codePage);

  // GetArchiveProperty
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.phySize:
        return _phySizeDefined ? _phySize : null;
      case Kpid.offset:
        return _offset > 0 ? _offset : null;
      case Kpid.embeddedStubSize:
        return _stubSize > 0 ? _stubSize : null;
      case Kpid.errorFlags:
        return errorFlags;
      case Kpid.warningFlags:
        return _warning ? ErrorFlags.headersError : null;
      case Kpid.comment:
        final c = _comment;
        return c == null || c.isEmpty ? null : _decodeComment(c);
      case Kpid.bit64:
        return _isZip64 ? true : null;
      case Kpid.characts:
        final t = [if (_isZip64) 'Zip64', if (_local) 'Local'];
        return t.isEmpty ? null : t.join(' ');
      case Kpid.isVolume:
        return _numVolumes > 1 ? true : null;
      case Kpid.volumeIndex:
        return _numVolumes > 1 ? _numVolumes - 1 : null;
      case Kpid.totalPhySize:
        return _numVolumes > 1 && _totalPhySize > 0 ? _totalPhySize : null;
      case Kpid.numVolumes:
        return _numVolumes > 1 ? _numVolumes : null;
      case Kpid.isNotArcType:
        return null;
    }
    return null;
  }

  /// The method string of 7-Zip's listing ("ZipCrypto Deflate",
  /// "AES-256 LZMA:eos", "Deflate:Fast").
  static String methodString(ZipItem it) {
    final sb = StringBuffer();
    if (it.isEncrypted) {
      if (it.method == ZipMethod.aes) {
        final bits = it.aesStrength >= 1 && it.aesStrength <= 3
            ? 64 + it.aesStrength * 64
            : 0;
        sb.write(bits != 0 ? 'AES-$bits ' : 'WzAES ');
      } else if ((it.flags & ZipFlags.strongEncryption) != 0) {
        sb.write('StrongCrypto ');
      } else {
        sb.write('ZipCrypto ');
      }
    }
    final m = it.realMethod;
    sb.write(zipMethodName(m));
    if (m == ZipMethod.deflate || m == ZipMethod.deflate64) {
      switch ((it.flags >> 1) & 3) {
        case 1:
          sb.write(':Maximum');
        case 2:
          sb.write(':Fast');
        case 3:
          sb.write(':SuperFast');
      }
    } else if (m == ZipMethod.lzma) {
      if ((it.flags & ZipFlags.bit1) != 0) sb.write(':eos');
    } else if (m == ZipMethod.store) {
      final v = (it.flags >> 1) & 3;
      if (v != 0) sb.write(':v$v');
    } else if (m == ZipMethod.implode) {
      sb.write((it.flags & ZipFlags.bit1) != 0 ? ':8K' : ':4K');
      if ((it.flags & ZipFlags.bit2) != 0) sb.write(':3');
    }
    return sb.toString();
  }

  /// The Windows attributes with the POSIX mode in the high 16 bits
  /// (FILE_ATTRIBUTE_UNIX_EXTENSION) for Unix hosts.
  static int attribOf(ZipItem it) {
    var a = it.externalAttr;
    final m = it.posixMode;
    if (m != null) {
      // as 7-Zip shows them: the mode and the directory bit
      a = (a & 0xFFFF0000) |
          FileAttrib.unixExtension |
          ((m & 0xF000) == 0x4000 ? FileAttrib.directory : 0);
    }
    if (it.isDir) a |= FileAttrib.directory;
    return a & 0xFFFFFFFF;
  }

  static String _stripSlash(String s) {
    var n = s.length;
    while (n > 1 && s.codeUnitAt(n - 1) == 0x2F) {
      n--;
    }
    return s.substring(0, n);
  }

  // GetProperty
  Object? getProperty(int index, int propId) {
    if (_seqReader != null && !_seqEnsure(index)) return null;
    if (index >= items.length) return null;
    final it = items[index];
    switch (propId) {
      case Kpid.path:
        return _stripSlash(it.path);
      case Kpid.isDir:
        return it.isDir;
      case Kpid.size:
        return it.isDir ? 0 : it.size;
      case Kpid.packSize:
        return it.packSize;
      case Kpid.mTime:
        return it.mTime;
      case Kpid.cTime:
        return it.cTime;
      case Kpid.aTime:
        return it.aTime;
      case Kpid.attrib:
        return attribOf(it);
      case Kpid.posixAttrib:
        return it.posixMode;
      case Kpid.encrypted:
        return it.isEncrypted;
      case Kpid.comment:
        return it.comment.isEmpty ? null : _decodeComment(it.comment);
      case Kpid.crc:
        if (it.isDir) return null;
        if (it.isAes && it.aesVendorVersion == 2 && it.crc == 0) return null;
        return it.crc;
      case Kpid.method:
        return methodString(it);
      case Kpid.characts:
        final c = it.characts();
        return c.isEmpty ? null : c;
      case Kpid.hostOS:
        return it.fromCentral ? zipHostName(it.hostOS) : null;
      case Kpid.unpackVer:
        return it.versionNeeded & 0xFF;
      case Kpid.volumeIndex:
        return it.disk;
      case Kpid.offset:
        return it.localOffset;
      case Kpid.userId:
        return it.uid;
      case Kpid.groupId:
        return it.gid;
    }
    return null;
  }

  /// IInArchiveGetStream::GetStream: random access to the data of a
  /// stored, not encrypted item.
  SeekableInStream? getStream(int index) {
    final s = _stream;
    if (s == null || _seqReader != null || index >= items.length) {
      return null;
    }
    final it = items[index];
    if (it.isDir || it.method != ZipMethod.store || it.isEncrypted) {
      return null;
    }
    if (!_ensureLocal(it) || it.packSize != it.size) return null;
    return _ItemInStream(s, it.dataPos, it.size);
  }

  // reads the local header of a central directory item; false when it is
  // missing or does not match
  bool _ensureLocal(ZipItem it) {
    if (it.dataPos >= 0) return !it.localError;
    final s = _stream;
    if (s == null || it.localPos < 0) {
      it.localError = true;
      return false;
    }
    final h = readLocalHeader(s, it.localPos);
    if (h == null) {
      it.localError = true;
      return false;
    }
    it.localExtra = Uint8List.fromList(h.extra);
    it.dataPos = it.localPos + h.headerSize;
    if (h.method != it.method && !(it.isAes && h.method == ZipMethod.aes)) {
      it.localError = true;
      return false;
    }
    if (it.dataPos + it.packSize > s.length) it.truncated = true;
    return true;
  }

  static int _unpackSize(ZipItem it) => it.isDir ? 0 : it.size;

  /// IInArchive::Extract. [indices] null means all items.
  void extract(List<int>? indices, bool testMode,
      ArchiveExtractCallback extractCallback) {
    final pw = _PasswordCache(extractCallback);
    if (_seqReader != null) {
      _extractSeq(indices, testMode, extractCallback, pw);
      return;
    }
    final ix = indices ?? [for (var i = 0; i < items.length; i++) i];
    var totalSize = 0;
    for (final i in ix) {
      totalSize += _unpackSize(items[i]);
    }
    extractCallback.setTotal(totalSize);
    var completed = 0;
    final buf = Uint8List(1 << 16);
    for (final index in ix) {
      extractCallback.setCompleted(completed);
      final it = items[index];
      var askMode = testMode ? AskMode.test : AskMode.extract;
      final realOut = extractCallback.getStream(index, askMode);
      if (!testMode && realOut == null && !it.isDir) askMode = AskMode.skip;
      extractCallback.prepareOperation(askMode);
      if (it.isDir || askMode == AskMode.skip) {
        extractCallback.setOperationResult(OperationResult.ok);
        completed += _unpackSize(it);
        continue;
      }
      final base = completed;
      final opRes = _extractItem(it, realOut, buf, pw,
          (done) => extractCallback.setCompleted(base + done));
      realOut?.flush();
      completed += _unpackSize(it);
      extractCallback.setOperationResult(opRes);
    }
    extractCallback.setCompleted(completed);
  }

  // the checks before decoding: an OperationResult, or -1 to go on
  int _preCheck(ZipItem it) {
    if (_unavailable || it.localPos < 0) return OperationResult.unavailable;
    if ((it.flags & ZipFlags.strongEncryption) != 0) {
      return OperationResult.unsupportedMethod;
    }
    if (it.method == ZipMethod.aes &&
        (!it.isEncrypted || it.aesStrength < 1 || it.aesStrength > 3)) {
      return OperationResult.unsupportedMethod;
    }
    if (!zipMethodIsSupported(it.realMethod)) {
      return OperationResult.unsupportedMethod;
    }
    return -1;
  }

  int _extractItem(ZipItem it, OutStream? out, Uint8List buf, _PasswordCache pw,
      void Function(int) progress) {
    final pre = _preCheck(it);
    if (pre >= 0) return pre;
    if (!_ensureLocal(it)) return OperationResult.headersError;
    final packed = WindowInStream(_stream!, it.dataPos, it.packSize);
    final crcOut = ZipCrcOutStream(out, progress: progress);
    try {
      final r = _decodeKnown(it, packed, crcOut, buf, pw);
      if (r != OperationResult.ok) return r;
    } on SevenZipException catch (e) {
      return _opResOf(e, it);
    }
    if (crcOut.count != it.size) {
      return it.truncated
          ? OperationResult.unexpectedEnd
          : OperationResult.dataError;
    }
    if (!_crcIsUnused(it) && crcOut.crc != it.crc) {
      return OperationResult.crcError;
    }
    if (it.truncated) return OperationResult.unexpectedEnd;
    return OperationResult.ok;
  }

  static bool _crcIsUnused(ZipItem it) =>
      it.isAes && it.aesVendorVersion == 2 && it.crc == 0;

  static int _opResOf(SevenZipException e, ZipItem it) {
    switch (e.kind) {
      case SevenZipError.unsupportedMethod:
      case SevenZipError.unsupported:
        return OperationResult.unsupportedMethod;
      case SevenZipError.crc:
        return OperationResult.crcError;
      case SevenZipError.unexpectedEnd:
        return OperationResult.unexpectedEnd;
      case SevenZipError.wrongPassword:
        return OperationResult.wrongPassword;
      case SevenZipError.cancelled:
      case SevenZipError.io:
        throw e;
      default:
        return OperationResult.dataError;
    }
  }

  // decrypts and decodes an item whose packed size is known
  int _decodeKnown(ZipItem it, InStream packed, ZipCrcOutStream out,
      Uint8List buf, _PasswordCache pw) {
    var src = packed;
    if (it.isEncrypted) {
      final password = pw.get();
      if (password == null) return OperationResult.wrongPassword;
      if (it.method == ZipMethod.aes) {
        final dataSize = it.packSize - wzAesOverhead(it.aesStrength);
        if (dataSize < 0) return OperationResult.unexpectedEnd;
        final dec = WzAesDecoder(packed, password, it.aesStrength, dataSize);
        if (!dec.readHeader()) return OperationResult.wrongPassword;
        src = dec;
        decodeZipItem(it.aesMethod, src, it.size, out, buf, flags: it.flags);
        // the whole data must be read for the authentication code
        if (dec.processed < dataSize) {
          final skip = Uint8List(1 << 12);
          while (dec.read(skip, 0, skip.length) != 0) {}
        }
        dec.finish();
        return OperationResult.ok;
      }
      if (it.packSize < kZipCryptoHeaderSize) {
        return OperationResult.unexpectedEnd;
      }
      final dec = ZipCryptoDecoder(packed, password);
      final check = dec.readHeader();
      if (!_zipCryptoCheckOk(it, check)) return OperationResult.wrongPassword;
      src = dec;
    }
    decodeZipItem(it.method, src, it.size, out, buf, flags: it.flags);
    return OperationResult.ok;
  }

  static bool _zipCryptoCheckOk(ZipItem it, int check) {
    if (check == (it.crc >> 24) & 0xFF) return true;
    if (it.hasDescriptor && check == (it.dosTime >> 8) & 0xFF) return true;
    return false;
  }

  // Extract in OpenSeq mode: the items in archive order, each once
  void _extractSeq(List<int>? indices, bool testMode, ArchiveExtractCallback cb,
      _PasswordCache pw) {
    final reader = _seqReader!;
    final buf = Uint8List(1 << 16);
    var k = 0;
    cb.setCompleted(0);
    for (var index = 0;; index++) {
      if (indices != null) {
        if (k >= indices.length) break;
        if (indices[k] != index) {
          if (!_seqEnsure(index)) break;
          continue;
        }
        k++;
      }
      if (!_seqEnsure(index)) break;
      final it = items[index];
      var askMode = testMode ? AskMode.test : AskMode.extract;
      final realOut = cb.getStream(index, askMode);
      if (!testMode && realOut == null && !it.isDir) askMode = AskMode.skip;
      cb.prepareOperation(askMode);
      if (_seqDataItem != index) {
        cb.setOperationResult(
            it.isDir ? OperationResult.ok : OperationResult.unavailable);
        continue;
      }
      _seqDataItem = -1;
      int opRes;
      final pre = _preCheck(it);
      if (pre >= 0) {
        opRes = pre;
        // the data can still be skipped when its size is known
        if (!_seqSkipKnown(reader, it)) {
          cb.setOperationResult(opRes);
          _seqEnd = true;
          _unexpectedEnd = true;
          break;
        }
      } else {
        opRes = _decodeSeqItem(reader.input, reader, it, realOut, buf,
            it.isEncrypted ? pw.getString() : null,
            passwordBytes: it.isEncrypted ? pw.get() : null);
      }
      realOut?.flush();
      cb.setOperationResult(opRes);
      cb.setCompleted(reader.input.pos);
      if (it.truncated) {
        _seqEnd = true;
        _unexpectedEnd = true;
        break;
      }
    }
  }

  bool _seqSkipKnown(ZipSeqReader reader, ZipItem it) {
    if (!_packSizeKnown(it)) return false;
    if (reader.input.skip(it.packSize) != it.packSize) {
      it.truncated = true;
      return false;
    }
    if (it.hasDescriptor) reader.readDescriptor(it);
    return true;
  }

  // decodes the item at the current position of [input] (sequential
  // reading), reading its data descriptor. [out] null decodes to nothing.
  int _decodeSeqItem(ZipSeqInput input, ZipSeqReader reader, ZipItem it,
      OutStream? out, Uint8List buf, String? passwordString,
      {Uint8List? passwordBytes}) {
    final pre = _preCheck(it);
    if (pre >= 0) return pre;
    final pwBytes = passwordBytes ??
        (passwordString == null
            ? null
            : Uint8List.fromList(utf8.encode(passwordString)));
    final crcOut = ZipCrcOutStream(out);
    final knownSize = _packSizeKnown(it);
    int opRes;
    try {
      if (knownSize) {
        final start = input.pos;
        final packed = LimitedInStream(input, it.packSize);
        opRes = _decodeKnown(
            it, packed, crcOut, buf, _PasswordCache.fixed(pwBytes));
        // skip what the decoder left
        final left = it.packSize - (input.pos - start);
        if (left > 0 && input.skip(left) != left) it.truncated = true;
        if (it.hasDescriptor) reader.readDescriptor(it);
      } else {
        opRes = _decodeUnknownSize(input, reader, it, crcOut, buf, pwBytes);
      }
    } on SevenZipException catch (e) {
      it.truncated = true;
      return _opResOf(e, it);
    }
    if (opRes != OperationResult.ok) {
      if (!knownSize) it.truncated = true;
      return opRes;
    }
    if (it.truncated) return OperationResult.unexpectedEnd;
    if (crcOut.count != it.size) return OperationResult.dataError;
    if (!_crcIsUnused(it) && crcOut.crc != it.crc) {
      return OperationResult.crcError;
    }
    return OperationResult.ok;
  }

  // the data of an item with a data descriptor and no sizes: the decoder
  // finds the end, the bytes it read ahead go back to the input
  int _decodeUnknownSize(ZipSeqInput input, ZipSeqReader reader, ZipItem it,
      ZipCrcOutStream out, Uint8List buf, Uint8List? password) {
    final start = input.pos;
    final m = it.realMethod;
    if (m == ZipMethod.store) {
      // stored: up to a matching descriptor signature
      final scan = StoredScanInStream(input, it.zip64);
      if (!it.isEncrypted) {
        decodeZipItem(ZipMethod.store, scan, null, out, buf);
      } else {
        // the raw data first, then its decryption
        final raw = readAll(scan);
        final copy = ZipItem()
          ..method = it.method
          ..flags = it.flags
          ..aesStrength = it.aesStrength
          ..aesMethod = it.aesMethod
          ..aesVendorVersion = it.aesVendorVersion
          ..dosTime = it.dosTime
          ..packSize = raw.length
          ..size = -1
          ..crc = it.crc;
        final r = _decodeRawEncryptedStored(
            copy, raw, out, buf, _PasswordCache.fixed(password));
        if (r != OperationResult.ok) return r;
      }
      if (scan.truncated) {
        it.truncated = true;
        return OperationResult.unexpectedEnd;
      }
      reader.readDescriptor(it, packSize: input.pos - start);
      return OperationResult.ok;
    }
    if (m == ZipMethod.xz ||
        !(m == ZipMethod.deflate ||
            m == ZipMethod.deflate64 ||
            m == ZipMethod.bzip2 ||
            m == ZipMethod.lzma)) {
      return OperationResult.unsupportedMethod;
    }
    InStream src = input;
    _SeqDecrypt? dec;
    if (it.isEncrypted) {
      if (password == null) return OperationResult.wrongPassword;
      dec = _SeqDecrypt(input);
      if (it.method == ZipMethod.aes) {
        if (!dec.initAes(password, it.aesStrength)) {
          return OperationResult.wrongPassword;
        }
      } else {
        final check = dec.initZipCrypto(password);
        if (!_zipCryptoCheckOk(it, check) &&
            check != (it.dosTime >> 8) & 0xFF) {
          return OperationResult.wrongPassword;
        }
      }
      src = dec;
    }
    final d = decodeZipItem(m, src, null, out, buf, flags: it.flags);
    final unused = d == null ? null : decoderUnusedInput(d);
    final nUnused = unused?.length ?? 0;
    if (dec != null) {
      dec.finish(nUnused);
    } else if (unused != null && nUnused > 0) {
      input.unread(Uint8List.fromList(unused), 0, nUnused);
    }
    reader.readDescriptor(it, packSize: input.pos - start);
    return OperationResult.ok;
  }

  int _decodeRawEncryptedStored(ZipItem it, Uint8List raw, ZipCrcOutStream out,
      Uint8List buf, _PasswordCache pw) {
    var src = MemoryInStream(raw) as InStream;
    final password = pw.get();
    if (password == null) return OperationResult.wrongPassword;
    if (it.method == ZipMethod.aes) {
      final dataSize = raw.length - wzAesOverhead(it.aesStrength);
      if (dataSize < 0) return OperationResult.unexpectedEnd;
      final dec = WzAesDecoder(src, password, it.aesStrength, dataSize);
      if (!dec.readHeader()) return OperationResult.wrongPassword;
      decodeZipItem(ZipMethod.store, dec, dataSize, out, buf);
      dec.finish();
      return OperationResult.ok;
    }
    final dec = ZipCryptoDecoder(src, password);
    final check = dec.readHeader();
    if (!_zipCryptoCheckOk(it, check) && check != (it.dosTime >> 8) & 0xFF) {
      return OperationResult.wrongPassword;
    }
    src = dec;
    decodeZipItem(ZipMethod.store, src, null, out, buf);
    return OperationResult.ok;
  }

  // IOutArchive

  /// IOutArchive::GetFileTimeType: FILETIME (the NTFS extra field), or the
  /// DOS time when -mtm- leaves the NTFS field out.
  int getFileTimeType() {
    final to = writeOptions.timeOptions;
    final p = to.prec;
    if (p != -1) return p;
    if (to.writeMTime.def && !to.writeMTime.val) return FileTimeType.dos;
    return FileTimeType.windows;
  }

  /// ISetProperties::SetProperties.
  void setProperties(List<MapEntry<String, PropVariant>> props) {
    writeOptions.setProperties(props);
    if (writeOptions.codePage != ZipCodePage.auto) {
      codePage = writeOptions.codePage;
    }
  }

  /// IOutArchive::UpdateItems: writes a new archive to [outStream]. Kept
  /// items are copied from the open archive without recompression.
  void updateItems(
      OutStream outStream, int numItems, ArchiveUpdateCallback updateCallback) {
    if (_seqReader != null) {
      throw const SevenZipException(
          'zip: an archive read as a stream can not be updated',
          SevenZipError.unsupported);
    }
    final kept = <ZipItem>[];
    for (final it in items) {
      if (!it.localError && _stream != null) _ensureLocal(it);
      kept.add(it);
    }
    ZipUpdater(
      options: writeOptions,
      oldStream: _stream,
      oldItems: kept,
      oldComment: writeOptions.newComment ?? _comment,
    ).update(outStream, numItems, updateCallback);
  }
}

/// The password of an extraction: asked once from the callback
/// (ICryptoGetTextPassword), UTF-8 encoded.
class _PasswordCache {
  final ArchiveExtractCallback? _cb;
  Uint8List? _pw;
  String? _pwString;
  bool _asked = false;

  _PasswordCache(ArchiveExtractCallback cb) : _cb = cb;
  _PasswordCache.fixed(Uint8List? pw)
      : _cb = null,
        _pw = pw,
        _asked = true;

  Uint8List? get() {
    if (!_asked) {
      _asked = true;
      final cb = _cb;
      if (cb is CryptoGetTextPassword) {
        _pwString = (cb as CryptoGetTextPassword).cryptoGetTextPassword();
        _pw = Uint8List.fromList(utf8.encode(_pwString!));
      }
    }
    return _pw;
  }

  String? getString() {
    get();
    return _pwString;
  }
}

/// Decryption in sequential reading when the size of the data is unknown:
/// the decoder reads ahead, so the last chunks of cipher text are kept
/// (and for AES, not yet authenticated) until [finish] tells how many
/// bytes the decoder did not use; those go back to the input.
class _SeqDecrypt implements InStream {
  final ZipSeqInput _in;
  ZipCryptoKeys? _zc;
  WzAesCtr? _ctr;
  HmacSha1? _mac;

  // the raw (encrypted) bytes of the last reads, oldest first
  final List<Uint8List> _recent = [];
  static const int _keep = 3;

  _SeqDecrypt(this._in);

  bool initAes(Uint8List password, int strength) {
    final salt = Uint8List(wzAesSaltSize(strength));
    readExactly(_in, salt, 0, salt.length);
    final pwv = Uint8List(kWzAesPwvSize);
    readExactly(_in, pwv, 0, kWzAesPwvSize);
    final keys = WzAesKeys.derive(password, salt, strength);
    if (keys.pwv[0] != pwv[0] || keys.pwv[1] != pwv[1]) return false;
    _ctr = WzAesCtr(keys.aesKey);
    _mac = HmacSha1(keys.macKey);
    return true;
  }

  int initZipCrypto(Uint8List password) {
    final keys = ZipCryptoKeys(password);
    final h = Uint8List(kZipCryptoHeaderSize);
    readExactly(_in, h, 0, kZipCryptoHeaderSize);
    keys.decrypt(h, 0, kZipCryptoHeaderSize);
    _zc = keys;
    return h[kZipCryptoHeaderSize - 1];
  }

  @override
  int read(Uint8List buf, int off, int len) {
    final n = _in.read(buf, off, len);
    if (n == 0) return 0;
    _recent.add(Uint8List.fromList(Uint8List.sublistView(buf, off, off + n)));
    if (_recent.length > _keep) {
      final old = _recent.removeAt(0);
      _mac?.update(old);
    }
    final ctr = _ctr;
    if (ctr != null) {
      ctr.process(buf, off, n);
    } else {
      _zc!.decrypt(buf, off, n);
    }
    return n;
  }

  /// The decoder left [unused] bytes of what it read: they go back to the
  /// input; for AES the authentication code that follows is checked.
  void finish(int unused) {
    var left = unused;
    final back = <Uint8List>[];
    while (left > 0 && _recent.isNotEmpty) {
      final last = _recent.removeLast();
      if (last.length <= left) {
        back.insert(0, last);
        left -= last.length;
      } else {
        final keep = last.length - left;
        back.insert(0, Uint8List.sublistView(last, keep));
        _recent.add(Uint8List.sublistView(last, 0, keep));
        left = 0;
      }
    }
    for (final r in _recent) {
      _mac?.update(r);
    }
    _recent.clear();
    for (var i = back.length - 1; i >= 0; i--) {
      _in.unread(back[i], 0, back[i].length);
    }
    final mac = _mac;
    if (mac != null) {
      final code = Uint8List(kWzAesMacSize);
      readExactly(_in, code, 0, kWzAesMacSize);
      final d = mac.digest();
      for (var i = 0; i < kWzAesMacSize; i++) {
        if (d[i] != code[i]) {
          throw const SevenZipException(
              'AES authentication code mismatch', SevenZipError.crc);
        }
      }
    }
  }
}

/// The volumes of a split archive as one stream.
class _VolumesInStream implements SeekableInStream {
  final List<SeekableInStream> _vols;
  final List<int> _starts = [];
  int _pos = 0;
  int _length = 0;

  _VolumesInStream(this._vols) {
    for (final v in _vols) {
      _starts.add(_length);
      _length += v.length;
    }
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (_pos >= _length || len <= 0) return 0;
    var i = _vols.length - 1;
    while (_starts[i] > _pos) {
      i--;
    }
    final v = _vols[i];
    final inVol = _pos - _starts[i];
    var n = v.length - inVol;
    if (n > len) n = len;
    v.position = inVol;
    final r = v.read(buf, off, n);
    _pos += r;
    return r;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => _length;
}

/// A seekable stream read from its current position (for the local header
/// scan of an archive without a central directory).
class _PositionedInStream implements InStream {
  final SeekableInStream _s;
  int _pos;
  _PositionedInStream(this._s) : _pos = _s.position;
  @override
  int read(Uint8List buf, int off, int len) {
    _s.position = _pos;
    final n = _s.read(buf, off, len);
    _pos += n;
    return n;
  }
}

/// The data of an item as a random access stream (GetStream).
class _ItemInStream implements SeekableInStream {
  final SeekableInStream _base;
  final int _start;
  final int _size;
  int _pos = 0;
  _ItemInStream(this._base, this._start, this._size);

  @override
  int read(Uint8List buf, int off, int len) {
    final left = _size - _pos;
    if (left <= 0 || len <= 0) return 0;
    if (len > left) len = left;
    _base.position = _start + _pos;
    final n = _base.read(buf, off, len);
    _pos += n;
    return n;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => _size;
}
