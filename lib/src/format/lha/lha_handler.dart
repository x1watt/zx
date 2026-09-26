// The LHA (.lzh, .lha) archive handler: IInArchive (Open, GetProperty,
// Extract, GetStream) and IOutArchive (UpdateItems, SetProperties).
//
// Reading follows lha_reader.c and lha_basic_reader.c of lhasa (ISC license,
// see LICENSE): headers in sequence, the packed data after each one, the
// CRC-16 of the unpacked data checked after decoding; every method lhasa
// decodes is supported. Writing uses level 2 headers with Unix extended
// headers as LHa for UNIX writes them, and the -lh5- (default), -lh6-,
// -lh7- encoders of lzh_encoder.dart or -lh0- (stored); kept items are
// copied byte for byte. The 7-Zip LZH handler is LGPL and was not used
// (docs/architecture.md, section 10).

import 'dart:convert';
import 'dart:typed_data';

import '../../codec/lzh/crc16.dart';
import '../../codec/lzh/lha_decoder.dart';
import '../../codec/lzh/lzh_encoder.dart';
import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import 'dos_time.dart';
import 'lha_header.dart';

// POSIX file type bits
const int _sIfMt = 0xF000;
const int _sIfDir = 0x4000;
const int _sIfReg = 0x8000;
const int _sIfLnk = 0xA000;

/// IsArc_Lzh: [IsArcRes] values (0 no, 1 yes, 2 need more).
int isArcLzh(Uint8List p, int size) {
  if (size < 22) return 2;
  if (!lhaHeaderMatch(p, 0)) return 0;
  final level = p[20];
  if (level <= 1) {
    // level 0 and 1: the header length and checksum
    final len = p[0];
    if (len < 22) return 0;
    // the checksum when the whole header is there
    if (size < len + 2) return 1;
    var sum = 0;
    for (var i = 2; i < len + 2; i++) {
      sum += p[i];
    }
    return (sum & 0xFF) == p[1] ? 1 : 0;
  }
  if (level == 2) return (p[0] | (p[1] << 8)) >= 26 ? 1 : 0;
  return (p[0] | (p[1] << 8)) == 4 ? 1 : 0;
}

/// The LHA handler.
class LhaHandler {
  SeekableInStream? _stream;
  final List<LhaItem> items = [];
  bool _isArc = false;
  bool _unexpectedEnd = false;
  bool _headersError = false;
  bool _dataAfterEnd = false;
  int _phySize = 0;

  /// The method of new items: 0 (-lh0-), 5, 6 or 7.
  int method = 5;

  /// -mx: 0 stores, 1..9 set the match search effort.
  int level = 5;

  /// IInArchive::Open. false (S_FALSE) when [stream] is not an LHA archive.
  bool open(SeekableInStream stream) {
    close();
    stream.position = 0;
    final head = Uint8List(512);
    final n = readFully(stream, head, 0, head.length);
    if (isArcLzh(head, n) != 1) return false;
    _stream = stream;
    _isArc = true;
    final reader = LhaHeaderReader(stream);
    final length = stream.length;
    var pos = 0;
    for (;;) {
      final it = LhaItem();
      final r = reader.read(pos, it);
      if (r == LhaHeaderResult.item) {
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
        case LhaHeaderResult.end:
          _phySize = pos + 1;
        case LhaHeaderResult.eof:
          _phySize = pos;
        case LhaHeaderResult.unexpectedEnd:
          _unexpectedEnd = true;
          _phySize = pos;
        case LhaHeaderResult.bad:
          if (items.isEmpty) {
            close();
            return false;
          }
          _headersError = true;
          _phySize = pos;
        case LhaHeaderResult.item:
          break;
      }
      break;
    }
    // bytes after the end mark that are not zeros
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

  /// IInArchive::Close.
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
  /// attributes, times, owner and link properties are given too).
  static const List<int> itemPropIds = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.crc,
    Kpid.method,
    Kpid.hostOS,
  ];

  static const List<int> archivePropIds = [];

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
    switch (propId) {
      case Kpid.phySize:
        return _isArc ? _phySize : null;
      case Kpid.errorFlags:
        return errorFlags;
      case Kpid.warningFlags:
        return warningFlags == 0 ? null : warningFlags;
    }
    return null;
  }

  /// The host OS name of an LHA OS type byte.
  static String hostOsName(int os) {
    switch (os) {
      case 0:
      case 0x4D:
        return 'MS-DOS';
      case 0x32:
        return 'OS/2';
      case 0x39:
        return 'OS9';
      case 0x4B:
        return 'OS/68K';
      case 0x33:
        return 'OS/386';
      case 0x48:
        return 'HUMAN';
      case 0x55:
        return 'UNIX';
      case 0x43:
        return 'CP/M';
      case 0x46:
        return 'FLEX';
      case 0x6D:
        return 'Mac';
      case 0x52:
        return 'Runser';
      case 0x54:
        return 'TownsOS';
      case 0x58:
        return 'XOSK';
      case 0x77:
        return 'Windows 95';
      case 0x57:
        return 'Windows NT';
      case 0x41:
        return 'Amiga';
      case 0x61:
        return 'Atari';
      case 0x4A:
        return 'Java';
      case 0x20:
        return 'LHARK';
    }
    if (os > 0x20 && os < 0x7F) return String.fromCharCode(os);
    return '$os';
  }

  /// The mode with the file type bits, when the header has Unix
  /// permissions.
  static int? posixAttribOf(LhaItem it) {
    if (!it.hasUnixPerms) return null;
    var m = it.unixPerms & 0xFFFF;
    if ((m & _sIfMt) == 0) m |= it.isDir ? _sIfDir : _sIfReg;
    return m;
  }

  static int attribOf(LhaItem it) {
    var a = it.attr & 0x3F;
    if (it.isDir) a |= FileAttrib.directory;
    final p = posixAttribOf(it);
    if (p != null) a |= FileAttrib.unixExtension | (p << 16);
    return a;
  }

  int _unpackSize(LhaItem it) {
    if (it.isSymLink) return it.symlinkTarget!.length;
    if (it.isDirMethod) return 0;
    return it.size;
  }

  Object? getProperty(int index, int propId) {
    if (index >= items.length) return null;
    final it = items[index];
    switch (propId) {
      case Kpid.path:
        return it.fullPath;
      case Kpid.isDir:
        return it.isDir;
      case Kpid.size:
        return _unpackSize(it);
      case Kpid.packSize:
        return it.isDirMethod ? 0 : it.packSize;
      case Kpid.mTime:
        return it.mTime;
      case Kpid.cTime:
        return it.cTime;
      case Kpid.aTime:
        return it.aTime;
      case Kpid.crc:
        return it.isDirMethod ? null : it.crc;
      case Kpid.method:
        return it.method;
      case Kpid.hostOS:
        return hostOsName(it.osType);
      case Kpid.attrib:
        return attribOf(it);
      case Kpid.posixAttrib:
        return posixAttribOf(it);
      case Kpid.userId:
        return it.hasUidGid ? it.unixUid : null;
      case Kpid.groupId:
        return it.hasUidGid ? it.unixGid : null;
      case Kpid.user:
        return it.unixUser;
      case Kpid.group:
        return it.unixGroup;
      case Kpid.symLink:
        return it.symlinkTargetString;
      case Kpid.comment:
        return it.comment == null ? null : decodeLhaName(it.comment!);
    }
    return null;
  }

  static bool _isStored(String m) =>
      m == '-lh0-' || m == '-lz4-' || m == '-pm0-';

  /// IInArchiveGetStream::GetStream: the data of a stored item.
  SeekableInStream? getStream(int index) {
    final s = _stream;
    if (s == null || index >= items.length) return null;
    final it = items[index];
    if (it.isDirMethod || it.truncated || !_isStored(it.method)) return null;
    if (it.packSize != it.size) return null;
    return _ItemInStream(s, it.dataPos, it.size);
  }

  /// IInArchive::Extract. [indices] null means all items.
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    final ix = indices ?? [for (var i = 0; i < items.length; i++) i];
    var total = 0;
    for (final i in ix) {
      total += _unpackSize(items[i]);
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
      completed += _unpackSize(it);
      cb.setOperationResult(res);
    }
    cb.setCompleted(completed);
  }

  int _extractItem(
      LhaItem it, OutStream? out, Uint8List buf, void Function(int) progress) {
    if (it.isDir) return OperationResult.ok;
    if (it.isSymLink) {
      final t = it.symlinkTarget!;
      out?.write(t, 0, t.length);
      out?.flush();
      return OperationResult.ok;
    }
    if (it.isDirMethod) return OperationResult.ok;
    final packed = WindowInStream(_stream!, it.dataPos, it.packSize);
    final dec = lhaDecoderForName(it.method, packed);
    if (dec == null) return OperationResult.unsupportedMethod;
    final s = LhaDecoderInStream(dec, it.size);
    var done = 0;
    while (done < it.size) {
      var want = it.size - done;
      if (want > buf.length) want = buf.length;
      final n = s.read(buf, 0, want);
      if (n == 0) break;
      out?.write(buf, 0, n);
      done += n;
      if ((done & 0xFFFFF) < n) progress(done);
    }
    out?.flush();
    if (it.truncated && done < it.size) return OperationResult.unexpectedEnd;
    if (done < it.size) return OperationResult.dataError;
    if (s.crc != it.crc) return OperationResult.crcError;
    return OperationResult.ok;
  }

  // IOutArchive

  int getFileTimeType() => FileTimeType.unix;

  static int _methodFromName(String s) {
    var v = s.toLowerCase();
    if (v.startsWith('-') && v.endsWith('-') && v.length == 5) {
      v = v.substring(1, 4);
    }
    switch (v) {
      case 'lh0':
      case 'copy':
        return 0;
      case 'lh5':
        return 5;
      case 'lh6':
        return 6;
      case 'lh7':
        return 7;
    }
    invalidArg('lzh: unsupported method: $s');
  }

  /// ISetProperties::SetProperties: m (or 0) = lh0, lh5, lh6, lh7 and x
  /// (0 stores); mt, memuse and cp are accepted and have no effect.
  void setProperties(List<MapEntry<String, PropVariant>> props) {
    method = 5;
    level = 5;
    var methodSet = false;
    for (final p in props) {
      final name = p.key.toLowerCase();
      final value = p.value;
      if (name.isEmpty) invalidArg();
      if (name == 'm' || name == '0') {
        if (value.vt != VarType.bstr) invalidArg();
        method = _methodFromName(value.stringValue);
        methodSet = true;
        continue;
      }
      if (name.startsWith('x')) {
        level = parsePropToUInt32(name.substring(1), value, 9);
        if (level > 9) level = 9;
        continue;
      }
      if (name == 'cp' || name.startsWith('mt') || name.startsWith('memuse')) {
        continue;
      }
      if (name.startsWith('t')) continue; // time options: whole seconds
      invalidArg('lzh: unknown property ${p.key}');
    }
    if (level == 0 && !methodSet) method = 0;
  }

  /// IOutArchive::UpdateItems. Kept items are copied byte for byte,
  /// renamed ones get a new level 2 header over their old data, new items
  /// are compressed with [method].
  void updateItems(
      OutStream outStream, int numItems, ArchiveUpdateCallback callback) {
    final opCallback = callback is ArchiveUpdateCallbackFile
        ? callback as ArchiveUpdateCallbackFile
        : null;
    final infos = <UpdateItemInfo>[];
    var total = 0;
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
    }
    callback.setTotal(total);
    final out = CountingOutStream(outStream);
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
          _copyRange(out, buf, it.headerPos, it.endPos);
        } else {
          final oi = _outItemFromOld(it);
          final p = callback.getProperty(i, Kpid.path);
          if (p is String) oi.path = _toUnixSlashes(p);
          final h = buildLhaLevel2Header(oi);
          out.write(h, 0, h.length);
          if (!it.isDirMethod) _copyRange(out, buf, it.dataPos, it.endPos);
        }
        completed += it.endPos - it.headerPos;
        continue;
      }
      final oi = _outItemFromCallback(callback, i);
      if (oi == null) continue;
      if (oi.isDir) {
        opCallback?.reportOperation(
            EventIndexType.outArcIndex, i, UpdateNotifyOp.add);
        oi.method = kLhaDirMethod;
        final h = buildLhaLevel2Header(oi);
        out.write(h, 0, h.length);
        continue;
      }
      final stream = callback.getStream(i);
      if (stream == null) continue;
      try {
        if (oi.symlinkTarget == null &&
            oi.unixMode != null &&
            (oi.unixMode! & _sIfMt) == _sIfLnk) {
          // the link target is the data (POSIX links stored by 7-Zip)
          oi.symlinkTarget = utf8.decode(readAll(stream), allowMalformed: true);
        }
        if (oi.symlinkTarget != null) {
          oi.method = kLhaDirMethod;
          oi.size = 0;
          oi.unixMode = _sIfLnk | ((oi.unixMode ?? 0x1FF) & 0xFFF);
          final h = buildLhaLevel2Header(oi);
          out.write(h, 0, h.length);
        } else {
          final base = completed;
          _writeFile(out, oi, stream, (n) => callback.setCompleted(base + n));
          completed += oi.size;
        }
      } finally {
        releaseStream(stream);
      }
      callback.setOperationResult(0);
    }
    // the end mark
    out.write(Uint8List(1), 0, 1);
    out.flush();
    callback.setCompleted(completed);
  }

  // compresses one file: the header before the data, its sizes and CRC
  // known only after the data; -lh0- when compression does not help
  void _writeFile(CountingOutStream out, LhaOutItem oi, InStream src,
      void Function(int) progress) {
    final input = _CrcTeeInStream(src, 4 << 20);
    final m = method;
    if (m == 0) {
      oi.method = '-lh0-';
      _writeStored(out, oi, input, progress);
      return;
    }
    oi.method = '-lh$m-';
    final base = out.base;
    if (base is SeekableOutStream) {
      final start = base.position;
      oi.packSize = 0;
      var h = buildLhaLevel2Header(oi);
      out.write(h, 0, h.length);
      final dataStart = base.position;
      final enc = LzhHuffEncoder.lha(m, out, level: level);
      final packed = enc.encode(input, progress);
      oi.size = input.count;
      oi.crc = input.crc;
      if (packed >= oi.size && input.complete) {
        // stored is smaller: rewrite from the kept copy
        base.position = start;
        base.truncate(start);
        oi.method = '-lh0-';
        _writeStored(out, oi, MemoryInStream(input.copy), null);
        return;
      }
      oi.packSize = packed;
      final end = base.position;
      h = buildLhaLevel2Header(oi);
      if (start + h.length != dataStart) {
        throw const SevenZipException('lzh: header size changed');
      }
      base.position = start;
      base.write(h, 0, h.length);
      base.position = end;
      return;
    }
    // not seekable: the packed data in memory first
    final mem = MemoryOutStream();
    final enc = LzhHuffEncoder.lha(m, mem, level: level);
    final packed = enc.encode(input, progress);
    oi.size = input.count;
    oi.crc = input.crc;
    if (packed >= oi.size && input.complete) {
      oi.method = '-lh0-';
      _writeStored(out, oi, MemoryInStream(input.copy), null);
      return;
    }
    oi.packSize = packed;
    final h = buildLhaLevel2Header(oi);
    out.write(h, 0, h.length);
    final d = mem.toBytes();
    out.write(d, 0, d.length);
  }

  void _writeStored(CountingOutStream out, LhaOutItem oi, InStream input,
      void Function(int)? progress) {
    final base = out.base;
    if (input is MemoryInStream) {
      final d = input.data;
      oi.size = d.length;
      oi.packSize = d.length;
      oi.crc = lhaCrc16(0, d, 0, d.length);
      final h = buildLhaLevel2Header(oi);
      out.write(h, 0, h.length);
      out.write(d, 0, d.length);
      return;
    }
    final tee = input as _CrcTeeInStream;
    if (base is SeekableOutStream) {
      final start = base.position;
      oi.packSize = oi.size;
      var h = buildLhaLevel2Header(oi);
      out.write(h, 0, h.length);
      final n = copyStream(tee, out);
      progress?.call(n);
      oi.size = n;
      oi.packSize = n;
      oi.crc = tee.crc;
      final end = base.position;
      final h2 = buildLhaLevel2Header(oi);
      if (h2.length != h.length) {
        throw const SevenZipException('lzh: header size changed');
      }
      h = h2;
      base.position = start;
      base.write(h, 0, h.length);
      base.position = end;
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

  static LhaOutItem _outItemFromOld(LhaItem it) {
    final oi = LhaOutItem(it.fullPath,
        isDir: it.isDir,
        symlinkTarget: it.symlinkTargetString,
        method: it.method)
      ..packSize = it.isDirMethod ? 0 : it.packSize
      ..size = it.isDirMethod ? 0 : it.size
      ..crc = it.isDirMethod ? 0 : it.crc
      ..attr = it.attr
      ..comment = it.comment;
    final ft = it.mTime;
    if (ft != null) oi.mTime = fileTimeToUnixTime(ft);
    oi.unixMode = posixAttribOf(it);
    if (it.isSymLink) oi.unixMode = _sIfLnk | ((oi.unixMode ?? 0x1FF) & 0xFFF);
    if (it.hasUidGid) {
      oi.hasUidGid = true;
      oi.uid = it.unixUid;
      oi.gid = it.unixGid;
    }
    oi.user = it.unixUser;
    oi.group = it.unixGroup;
    return oi;
  }

  // the header fields of a new item; null for anti items
  LhaOutItem? _outItemFromCallback(ArchiveUpdateCallback cb, int i) {
    if (cb.getProperty(i, Kpid.isAnti) == true) return null;
    final pathProp = cb.getProperty(i, Kpid.path);
    if (pathProp is! String) invalidArg('Bad path property');
    var isDir = cb.getProperty(i, Kpid.isDir) == true;
    int? posix;
    var dosAttr = 0x20;
    final pa = cb.getProperty(i, Kpid.posixAttrib);
    final a = cb.getProperty(i, Kpid.attrib);
    if (pa is int) {
      posix = pa & 0xFFFF;
    } else if (a is int && (a & FileAttrib.unixExtension) != 0) {
      posix = (a >> 16) & 0xFFFF;
    }
    if (a is int) {
      dosAttr = a & 0x27;
      if ((a & FileAttrib.directory) != 0) isDir = true;
    }
    if (posix == null) {
      // from the Windows attributes, like the tar handler
      posix = (dosAttr & FileAttrib.readOnly) != 0 ? 0x124 : 0x1A4;
      if (isDir) posix |= 0x49;
    }
    var type = posix & _sIfMt;
    if (isDir) {
      type = _sIfDir;
    } else if (type != _sIfLnk) {
      type = _sIfReg;
    }
    final path = _toUnixSlashes(pathProp);
    final oi = LhaOutItem(path, isDir: isDir);
    oi.unixMode = type | (posix & 0xFFF);
    oi.attr = isDir ? FileAttrib.directory : (dosAttr | FileAttrib.archive);
    oi.attr &= 0x3F;
    final sl = cb.getProperty(i, Kpid.symLink);
    if (sl is String && sl.isNotEmpty && !isDir) oi.symlinkTarget = sl;
    if (!isDir) {
      final s = cb.getProperty(i, Kpid.size);
      if (s is int) oi.size = s;
    }
    final mt = cb.getProperty(i, Kpid.mTime);
    if (mt is int) oi.mTime = fileTimeToUnixTime(mt);
    final uid = cb.getProperty(i, Kpid.userId);
    final gid = cb.getProperty(i, Kpid.groupId);
    if (uid is int && gid is int) {
      oi.hasUidGid = true;
      oi.uid = uid & 0xFFFF;
      oi.gid = gid & 0xFFFF;
    }
    final user = cb.getProperty(i, Kpid.user);
    if (user is String) oi.user = user;
    final group = cb.getProperty(i, Kpid.group);
    if (group is String) oi.group = group;
    return oi;
  }
}

/// Counts and CRCs the bytes read, keeping a copy of the first [keep]
/// bytes (for the stored fallback).
class _CrcTeeInStream implements InStream {
  final InStream _base;
  final int _keep;
  final MemoryOutStream _copy = MemoryOutStream();
  int count = 0;
  int crc = 0;
  _CrcTeeInStream(this._base, this._keep);

  bool get complete => count <= _keep;
  Uint8List get copy => _copy.toBytes();

  @override
  int read(Uint8List buf, int off, int len) {
    final n = _base.read(buf, off, len);
    if (n > 0) {
      crc = lhaCrc16(crc, buf, off, off + n);
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
