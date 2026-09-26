// The ARJ archive handler: IInArchive (Open, GetProperty, Extract,
// GetStream) and IOutArchive (UpdateItems, SetProperties).
//
// Written from the ARJ technote (see arj_header.dart). Methods 1 to 3 are
// the static Huffman block format of LHA -lh6- with a 26624 byte
// dictionary (decoded by lh_new_decoder.dart), method 4 is decoded by
// arj4_decoder.dart. Garbled (password protected) files and the parts of
// multi-volume archives are listed and reported as not supported. New
// archives get the headers ARJ 3.x writes in its MS-DOS compatible mode
// ("-2d": MS-DOS host, MS-DOS times and attributes); kept items are copied
// byte for byte. The 7-Zip ARJ handler is LGPL and the ARJ source is GPL:
// neither was used (docs/architecture.md, section 10).

import 'dart:convert';
import 'dart:typed_data';

import '../../codec/lzh/arj4_decoder.dart';
import '../../codec/lzh/lh_new_decoder.dart';
import '../../codec/lzh/lha_decoder.dart';
import '../../codec/lzh/lzh_bits.dart';
import '../../codec/lzh/lzh_encoder.dart';
import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../lha/dos_time.dart';
import 'arj_header.dart';

/// IsArc_Arj: [IsArcRes] values (0 no, 1 yes, 2 need more).
int isArcArj(Uint8List p, int size) {
  if (size < 4) return 2;
  if (p[0] != kArjHeaderId0 || p[1] != kArjHeaderId1) return 0;
  final len = p[2] | (p[3] << 8);
  if (len < 30 || len > kArjMaxHeaderSize) return 0;
  if (size < 5) return 2;
  final first = p[4];
  if (first < 30 || first > len) return 0;
  if (size < 4 + len + 4) return 1;
  final crc = Crc32.of(p, 4, 4 + len);
  return crc == getUint32LE(p, 4 + len) ? 1 : 0;
}

/// The ARJ handler.
class ArjHandler {
  SeekableInStream? _stream;
  final ArjMainHeader mainHeader = ArjMainHeader();
  final List<ArjItem> items = [];
  bool _isArc = false;
  bool _unexpectedEnd = false;
  bool _headersError = false;
  bool _dataAfterEnd = false;
  int _phySize = 0;

  /// The method of new items: 0 (stored), 1 to 3 (LZH), 4 (fastest).
  int method = 1;

  /// -mx: sets the match search effort (0 stores).
  int level = 5;

  /// IInArchive::Open. false (S_FALSE) when [stream] is not an ARJ archive.
  bool open(SeekableInStream stream) {
    close();
    final head = Uint8List(4 + kArjMaxHeaderSize + 4);
    stream.position = 0;
    final n = readFully(stream, head, 0, head.length);
    if (isArcArj(head, n) != 1) return false;
    final h = ArjRawHeader();
    if (readArjHeader(stream, 0, h) != ArjHeaderResult.header ||
        !mainHeader.parse(h.basic)) {
      return false;
    }
    _stream = stream;
    _isArc = true;
    final length = stream.length;
    var pos = h.end;
    for (;;) {
      final r = readArjHeader(stream, pos, h);
      if (r == ArjHeaderResult.header) {
        final it = ArjItem();
        if (!it.parse(h.basic)) {
          _headersError = true;
          _phySize = pos;
          break;
        }
        it.headerPos = pos;
        it.dataPos = h.end;
        it.ext = List.of(h.ext);
        items.add(it);
        if (it.endPos > length) {
          it.truncated = true;
          _unexpectedEnd = true;
          _phySize = length;
          break;
        }
        pos = it.endPos;
        continue;
      }
      switch (r) {
        case ArjHeaderResult.end:
          _phySize = h.end;
        case ArjHeaderResult.unexpectedEnd:
          _unexpectedEnd = true;
          _phySize = pos;
        case ArjHeaderResult.bad:
          _headersError = true;
          _phySize = pos;
        case ArjHeaderResult.header:
          break;
      }
      break;
    }
    if (!_unexpectedEnd && !_headersError && _phySize < length) {
      final rest = length - _phySize;
      final buf = Uint8List(rest < 4096 ? rest : 4096);
      stream.position = _phySize;
      final got = readFully(stream, buf, 0, buf.length);
      for (var i = 0; i < got; i++) {
        if (buf[i] != 0 && buf[i] != 0x1A) {
          _dataAfterEnd = true;
          break;
        }
      }
    }
    return true;
  }

  void close() {
    _stream = null;
    items.clear();
    _isArc = false;
    _unexpectedEnd = false;
    _headersError = false;
    _dataAfterEnd = false;
    _phySize = 0;
  }

  int get numberOfItems => items.length;

  /// The item properties in listing order (as 7-Zip lists them; the
  /// other times, the POSIX mode and the split flags are given too).
  static const List<int> itemPropIds = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.position,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.attrib,
    Kpid.encrypted,
    Kpid.crc,
    Kpid.method,
    Kpid.hostOS,
    Kpid.comment,
  ];

  static const List<int> archivePropIds = [
    Kpid.name,
    Kpid.hostOS,
    Kpid.comment,
  ];

  int get errorFlags {
    var v = 0;
    if (!_isArc) v |= ErrorFlags.isNotArc;
    if (_unexpectedEnd) v |= ErrorFlags.unexpectedEnd;
    if (_headersError) v |= ErrorFlags.headersError;
    return v;
  }

  /// Data after the end of the archive is a warning, as in 7-Zip.
  int get warningFlags => _dataAfterEnd ? ErrorFlags.dataAfterEnd : 0;

  Object? getArchiveProperty(int propId) {
    if (!_isArc) return propId == Kpid.errorFlags ? errorFlags : null;
    if (propId == Kpid.warningFlags) {
      return warningFlags == 0 ? null : warningFlags;
    }
    final m = mainHeader;
    switch (propId) {
      case Kpid.name:
        return m.nameBytes.isEmpty ? null : m.name;
      case Kpid.cTime:
        return m.timeToFileTime(m.cTimeRaw);
      case Kpid.mTime:
        return m.timeToFileTime(m.mTimeRaw);
      case Kpid.hostOS:
        return m.hostOsName;
      case Kpid.comment:
        return m.commentBytes.isEmpty ? null : m.comment;
      case Kpid.phySize:
        return _phySize;
      case Kpid.errorFlags:
        return errorFlags;
      case Kpid.warningFlags:
        return warningFlags == 0 ? null : warningFlags;
      case Kpid.isVolume:
        return (m.flags & ArjFlags.volume) != 0;
    }
    return null;
  }

  // the Unix mode of a UNIX host item: the permissions and the file type
  static int? posixAttribOf(ArjItem it) {
    if (it.hostOs != ArjHostOs.unix && it.hostOs != ArjHostOs.next) {
      return null;
    }
    final perm = it.fileMode & 0xFFF;
    if (it.isDir) return 0x4000 | perm;
    if (it.fileType == ArjFileType.unixSpecial) return perm;
    return 0x8000 | perm;
  }

  static int attribOf(ArjItem it) {
    final p = posixAttribOf(it);
    if (p != null) {
      var a = FileAttrib.unixExtension | (p << 16);
      if (it.isDir) a |= FileAttrib.directory;
      return a;
    }
    var a = it.fileMode & 0xFF;
    if (it.isDir) a |= FileAttrib.directory;
    return a;
  }

  Object? getProperty(int index, int propId) {
    if (index >= items.length) return null;
    final it = items[index];
    switch (propId) {
      case Kpid.path:
        var s = it.name;
        while (s.length > 1 && s.endsWith('/')) {
          s = s.substring(0, s.length - 1);
        }
        return s;
      case Kpid.isDir:
        return it.isDir;
      case Kpid.size:
        return it.size;
      case Kpid.position:
        return it.splitBefore ? it.extFilePos : null;
      case Kpid.packSize:
        return it.packSize;
      case Kpid.mTime:
        return it.timeToFileTime(it.mTimeRaw);
      case Kpid.aTime:
        return it.hasATime ? it.timeToFileTime(it.aTimeRaw) : null;
      case Kpid.cTime:
        return it.hasCTime ? it.timeToFileTime(it.cTimeRaw) : null;
      case Kpid.attrib:
        return attribOf(it);
      case Kpid.posixAttrib:
        return posixAttribOf(it);
      case Kpid.encrypted:
        return it.isEncrypted;
      case Kpid.crc:
        return it.isDir ? null : it.crc;
      case Kpid.method:
        return '${it.method}';
      case Kpid.hostOS:
        return it.hostOsName;
      case Kpid.comment:
        return it.commentBytes.isEmpty ? null : it.comment;
      case Kpid.splitBefore:
        return it.splitBefore;
      case Kpid.splitAfter:
        return it.splitAfter;
    }
    return null;
  }

  bool _isPlain(ArjItem it) =>
      !it.isEncrypted && !it.splitBefore && !it.splitAfter;

  /// IInArchiveGetStream::GetStream: the data of a stored item.
  SeekableInStream? getStream(int index) {
    final s = _stream;
    if (s == null || index >= items.length) return null;
    final it = items[index];
    if (it.isDir || it.method != 0 || it.truncated || !_isPlain(it)) {
      return null;
    }
    if (it.packSize != it.size) return null;
    return _ItemInStream(s, it.dataPos, it.size);
  }

  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    final ix = indices ?? [for (var i = 0; i < items.length; i++) i];
    var total = 0;
    for (final i in ix) {
      total += items[i].size;
    }
    cb.setTotal(total);
    var completed = 0;
    final buf = Uint8List(1 << 16);
    for (final index in ix) {
      cb.setCompleted(completed);
      final it = items[index];
      var askMode = testMode ? AskMode.test : AskMode.extract;
      final out = cb.getStream(index, askMode);
      if (!testMode && out == null && !it.isDir) askMode = AskMode.skip;
      cb.prepareOperation(askMode);
      final base = completed;
      final res = _extractItem(it, out, buf, (n) => cb.setCompleted(base + n));
      completed += it.size;
      cb.setOperationResult(res);
    }
    cb.setCompleted(completed);
  }

  int _extractItem(
      ArjItem it, OutStream? out, Uint8List buf, void Function(int) progress) {
    if (it.isDir ||
        it.fileType == ArjFileType.volumeLabel ||
        it.fileType == ArjFileType.chapter) {
      return OperationResult.ok;
    }
    if (it.isEncrypted) return OperationResult.unsupportedMethod;
    if (it.splitBefore || it.splitAfter) return OperationResult.unavailable;
    final packed = WindowInStream(_stream!, it.dataPos, it.packSize);
    InStream src;
    switch (it.method) {
      case 0:
        src = LimitedInStream(packed, it.size);
      case 1:
      case 2:
      case 3:
        src = LhaDecoderInStream(
            LhNewDecoder(LzhBitReader(packed), LhNewParams.arj), it.size,
            computeCrc16: false);
      case 4:
        src = LhaDecoderInStream(Arj4Decoder(LzhBitReader(packed)), it.size,
            computeCrc16: false);
      default:
        return OperationResult.unsupportedMethod;
    }
    var crc = 0xFFFFFFFF;
    var done = 0;
    while (done < it.size) {
      var want = it.size - done;
      if (want > buf.length) want = buf.length;
      final n = src.read(buf, 0, want);
      if (n == 0) break;
      crc = crc32Update(crc, buf, 0, n);
      out?.write(buf, 0, n);
      done += n;
      if ((done & 0xFFFFF) < n) progress(done);
    }
    out?.flush();
    if (it.truncated && done < it.size) return OperationResult.unexpectedEnd;
    if (done < it.size) return OperationResult.dataError;
    if ((crc ^ 0xFFFFFFFF) != it.crc) return OperationResult.crcError;
    return OperationResult.ok;
  }

  // IOutArchive

  int getFileTimeType() => FileTimeType.dos;

  /// ISetProperties::SetProperties: m (or 0) = 0..4 (the ARJ method), x
  /// (0 stores, 1 method 4, 2 method 3, 3 and 4 method 2, 5 to 9 method
  /// 1); mt, memuse, cp and the time options are accepted and ignored.
  void setProperties(List<MapEntry<String, PropVariant>> props) {
    method = 1;
    level = 5;
    var methodSet = false;
    for (final p in props) {
      final name = p.key.toLowerCase();
      final value = p.value;
      if (name.isEmpty) invalidArg();
      if (name == 'm' || name == '0') {
        int? m;
        if (value.vt == VarType.ui4) {
          m = value.intValue;
        } else if (value.vt == VarType.bstr) {
          var s = value.stringValue.toLowerCase();
          if (s.startsWith('m')) s = s.substring(1);
          if (s == 'copy') s = '0';
          m = int.tryParse(s);
        }
        if (m == null || m < 0 || m > 4) invalidArg('arj: unsupported method');
        method = m;
        methodSet = true;
        continue;
      }
      if (name.startsWith('x')) {
        level = parsePropToUInt32(name.substring(1), value, 9);
        if (level > 9) level = 9;
        continue;
      }
      if (name == 'cp' ||
          name.startsWith('mt') ||
          name.startsWith('memuse') ||
          name.startsWith('t')) {
        continue;
      }
      invalidArg('arj: unknown property ${p.key}');
    }
    if (!methodSet) {
      if (level == 0) {
        method = 0;
      } else if (level == 1) {
        method = 4;
      } else if (level == 2) {
        method = 3;
      } else if (level <= 4) {
        method = 2;
      } else {
        method = 1;
      }
    }
  }

  // the effort of the LZH methods
  int get _lzhLevel {
    switch (method) {
      case 1:
        return level < 7 ? 7 : level;
      case 2:
        return 5;
      default:
        return 3;
    }
  }

  void updateItems(
      OutStream outStream, int numItems, ArchiveUpdateCallback callback) {
    final opCallback = callback is ArchiveUpdateCallbackFile
        ? callback as ArchiveUpdateCallbackFile
        : null;
    final infos = <UpdateItemInfo>[];
    var total = 0;
    var latest = 0;
    for (var i = 0; i < numItems; i++) {
      final info = callback.getUpdateItemInfo(i);
      infos.add(info);
      if (info.indexInArchive >= 0 &&
          (_stream == null || info.indexInArchive >= items.length)) {
        invalidArg('Bad index in archive');
      }
      if (info.newData) {
        final s = callback.getProperty(i, Kpid.size);
        if (s is int) total += s;
      } else {
        final it = items[info.indexInArchive];
        total += it.endPos - it.headerPos;
      }
      final mt = info.newProps || info.indexInArchive < 0
          ? callback.getProperty(i, Kpid.mTime)
          : items[info.indexInArchive]
              .timeToFileTime(items[info.indexInArchive].mTimeRaw);
      if (mt is int && mt > latest) latest = mt;
    }
    callback.setTotal(total);
    final now = DateTime.now().microsecondsSinceEpoch * 10 + kFileTimeUnixEpoch;
    final created =
        _isArc ? (mainHeader.timeToFileTime(mainHeader.cTimeRaw) ?? now) : now;
    final mh = buildArjMainHeader(
        cTime: fileTimeToDosTime(created),
        mTime: fileTimeToDosTime(now),
        name: _isArc ? mainHeader.nameBytes : const [],
        comment: _isArc ? mainHeader.commentBytes : const []);
    outStream.write(mh, 0, mh.length);

    var completed = 0;
    final buf = Uint8List(1 << 16);
    for (var i = 0; i < numItems; i++) {
      callback.setCompleted(completed);
      final info = infos[i];
      if (!info.newData) {
        final it = items[info.indexInArchive];
        opCallback?.reportOperation(EventIndexType.inArcIndex,
            info.indexInArchive, UpdateNotifyOp.replicate);
        if (!info.newProps) {
          _copyRange(outStream, buf, it.headerPos, it.endPos);
        } else {
          final p = callback.getProperty(i, Kpid.path);
          final h =
              _renamedHeader(it, p is String ? _toUnixSlashes(p) : it.name);
          outStream.write(h, 0, h.length);
          _copyRange(outStream, buf, it.dataPos, it.endPos);
        }
        completed += it.endPos - it.headerPos;
        continue;
      }
      final oi = _outItemFromCallback(callback, i);
      if (oi == null) continue;
      if (oi.isDir) {
        opCallback?.reportOperation(
            EventIndexType.outArcIndex, i, UpdateNotifyOp.add);
        final h = buildArjLocalHeader(oi);
        outStream.write(h, 0, h.length);
        continue;
      }
      final stream = callback.getStream(i);
      if (stream == null) continue;
      try {
        final base = completed;
        _writeFile(
            outStream, oi, stream, (n) => callback.setCompleted(base + n));
        completed += oi.size;
      } finally {
        releaseStream(stream);
      }
      callback.setOperationResult(0);
    }
    final end = arjEndHeader();
    outStream.write(end, 0, end.length);
    outStream.flush();
    callback.setCompleted(completed);
  }

  // the local header of [it] with a new name, other fields kept
  Uint8List _renamedHeader(ArjItem it, String name) {
    final h = ArjRawHeader();
    readArjHeader(_stream!, it.headerPos, h);
    final b = h.basic;
    final fixed = Uint8List.fromList(b.sublist(0, it.firstHdrSize));
    fixed[4] |= ArjFlags.pathSym;
    final nb = utf8.encode(name);
    // the filespec position
    final fp = nb.lastIndexOf(0x2F) + 1;
    fixed[24] = fp & 0xFF;
    fixed[25] = (fp >> 8) & 0xFF;
    final basic =
        Uint8List(fixed.length + nb.length + 1 + it.commentBytes.length + 1);
    basic.setRange(0, fixed.length, fixed);
    basic.setRange(fixed.length, fixed.length + nb.length, nb);
    final c = fixed.length + nb.length + 1;
    basic.setRange(c, c + it.commentBytes.length, it.commentBytes);
    if (basic.length > kArjMaxHeaderSize) {
      throw const SevenZipException('arj: the name is too long');
    }
    final framed = frameArjHeader(basic);
    if (h.ext.isEmpty) return framed;
    // keep the extended headers
    final bb = BytesBuilder(copy: false);
    bb.add(Uint8List.sublistView(framed, 0, framed.length - 2));
    for (final e in h.ext) {
      bb.add([e.length & 0xFF, (e.length >> 8) & 0xFF]);
      bb.add(e);
      final c4 = Uint8List(4);
      setUint32LE(c4, 0, Crc32.of(e));
      bb.add(c4);
    }
    bb.add(const [0, 0]);
    return bb.takeBytes();
  }

  void _writeFile(
      OutStream out, ArjOutItem oi, InStream src, void Function(int) progress) {
    final input = _CrcTeeInStream(src, 4 << 20);
    final m = method;
    oi.method = m;
    if (m == 0) {
      _writeStored(out, oi, input, progress);
      return;
    }
    int encode(OutStream o) {
      if (m == 4) return Arj4Encoder(o, level: level).encode(input, progress);
      return LzhHuffEncoder.arj(o, level: _lzhLevel).encode(input, progress);
    }

    if (out is SeekableOutStream) {
      final start = out.position;
      var h = buildArjLocalHeader(oi);
      out.write(h, 0, h.length);
      final packed = encode(out);
      oi.size = input.count;
      oi.crc = input.crc;
      _checkSize(oi.size);
      if (packed >= oi.size && input.complete) {
        out.position = start;
        out.truncate(start);
        oi.method = 0;
        _writeStored(out, oi, MemoryInStream(input.copy), null);
        return;
      }
      oi.packSize = packed;
      final end = out.position;
      h = buildArjLocalHeader(oi);
      out.position = start;
      out.write(h, 0, h.length);
      out.position = end;
      return;
    }
    final mem = MemoryOutStream();
    final packed = encode(mem);
    oi.size = input.count;
    oi.crc = input.crc;
    _checkSize(oi.size);
    if (packed >= oi.size && input.complete) {
      oi.method = 0;
      _writeStored(out, oi, MemoryInStream(input.copy), null);
      return;
    }
    oi.packSize = packed;
    final h = buildArjLocalHeader(oi);
    out.write(h, 0, h.length);
    final d = mem.toBytes();
    out.write(d, 0, d.length);
  }

  static void _checkSize(int n) {
    if (n > 0xFFFFFFFF) {
      throw const SevenZipException(
          'arj: files of 4 GiB or more are not supported',
          SevenZipError.unsupported);
    }
  }

  void _writeStored(OutStream out, ArjOutItem oi, InStream input,
      void Function(int)? progress) {
    oi.method = 0;
    if (input is MemoryInStream) {
      final d = input.data;
      oi.size = d.length;
      oi.packSize = d.length;
      oi.crc = Crc32.of(d);
      final h = buildArjLocalHeader(oi);
      out.write(h, 0, h.length);
      out.write(d, 0, d.length);
      return;
    }
    final tee = input as _CrcTeeInStream;
    if (out is SeekableOutStream) {
      final start = out.position;
      var h = buildArjLocalHeader(oi);
      out.write(h, 0, h.length);
      final n = copyStream(tee, out);
      progress?.call(n);
      _checkSize(n);
      oi.size = n;
      oi.packSize = n;
      oi.crc = tee.crc;
      final end = out.position;
      h = buildArjLocalHeader(oi);
      out.position = start;
      out.write(h, 0, h.length);
      out.position = end;
      return;
    }
    final mem = MemoryOutStream();
    copyStream(tee, mem);
    _writeStored(out, oi, MemoryInStream(mem.toBytes()), null);
  }

  static String _toUnixSlashes(String s) => s.replaceAll('\\', '/');

  void _copyRange(OutStream w, Uint8List buf, int from, int to) {
    final s = _stream!;
    s.position = from;
    var left = to - from;
    while (left > 0) {
      final want = left < buf.length ? left : buf.length;
      final n = s.read(buf, 0, want);
      if (n == 0) {
        throw const SevenZipException(
            'Unexpected end of archive', SevenZipError.unexpectedEnd);
      }
      w.write(buf, 0, n);
      left -= n;
    }
  }

  ArjOutItem? _outItemFromCallback(ArchiveUpdateCallback cb, int i) {
    if (cb.getProperty(i, Kpid.isAnti) == true) return null;
    final pathProp = cb.getProperty(i, Kpid.path);
    if (pathProp is! String) invalidArg('Bad path property');
    var isDir = cb.getProperty(i, Kpid.isDir) == true;
    var attr = FileAttrib.archive;
    final a = cb.getProperty(i, Kpid.attrib);
    if (a is int) {
      if ((a & FileAttrib.directory) != 0) isDir = true;
      attr = a & 0x27;
      if ((a & FileAttrib.unixExtension) != 0) {
        // read-only when the owner can not write
        final mode = (a >> 16) & 0xFFFF;
        if ((mode & 0x80) == 0) attr |= FileAttrib.readOnly;
      }
    } else {
      final pa = cb.getProperty(i, Kpid.posixAttrib);
      if (pa is int && (pa & 0x80) == 0) attr |= FileAttrib.readOnly;
    }
    final oi = ArjOutItem(_toUnixSlashes(pathProp), isDir: isDir);
    oi.fileMode = isDir ? FileAttrib.directory | (attr & 0x07) : attr | 0x20;
    final mt = cb.getProperty(i, Kpid.mTime);
    final now = DateTime.now().microsecondsSinceEpoch * 10 + kFileTimeUnixEpoch;
    final mft = mt is int ? mt : now;
    oi.mTime = fileTimeToDosTime(mft);
    final at = cb.getProperty(i, Kpid.aTime);
    final ct = cb.getProperty(i, Kpid.cTime);
    oi.aTime = fileTimeToDosTime(at is int ? at : mft);
    oi.cTime = fileTimeToDosTime(ct is int ? ct : mft);
    if (!isDir) {
      final s = cb.getProperty(i, Kpid.size);
      if (s is int) oi.size = s;
    }
    return oi;
  }
}

/// Counts and CRC-32s the bytes read, keeping a copy of the first [keep]
/// bytes (for the stored fallback).
class _CrcTeeInStream implements InStream {
  final InStream _base;
  final int _keep;
  final MemoryOutStream _copy = MemoryOutStream();
  int count = 0;
  int _crc = 0xFFFFFFFF;
  _CrcTeeInStream(this._base, this._keep);

  bool get complete => count <= _keep;
  Uint8List get copy => _copy.toBytes();
  int get crc => _crc ^ 0xFFFFFFFF;

  @override
  int read(Uint8List buf, int off, int len) {
    final n = _base.read(buf, off, len);
    if (n > 0) {
      _crc = crc32Update(_crc, buf, off, off + n);
      if (count + n <= _keep) _copy.write(buf, off, n);
      count += n;
    }
    return n;
  }
}

/// The data of a stored item as a random access stream.
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
