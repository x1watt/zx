// The ARJ archive handler: IInArchive (Open, GetProperty, Extract,
// GetStream) and IOutArchive (UpdateItems, SetProperties).
//
// Written from the ARJ technote (see arj_header.dart). Methods 1 to 3 are
// the static Huffman block format of LHA -lh6- with a 26624 byte
// dictionary (decoded by lh_new_decoder.dart), method 4 is decoded by
// arj4_decoder.dart. Garbled (password protected, "-g") files are read and
// written with the XOR garbling described in arj_header.dart, found by
// black box experiments with ARJ32 3.10; the ARJCRYPT ciphers ("-hg") are
// not supported. Multi-volume archives ("-v": x.arj, x.a01, x.a02...,
// x.100...) are read: the parts of a file are joined into one item. UNIX
// symbolic links (file type 6) are read and, with -snl, written. New
// archives get the headers ARJ 3.x writes in its MS-DOS compatible mode
// ("-2d": MS-DOS host, MS-DOS times and attributes; links get the UNIX
// host); kept items are copied byte for byte. The 7-Zip ARJ handler is LGPL
// and the ARJ source is GPL: neither was used (docs/architecture.md,
// section 10).

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

/// The name of volume [n] (1 and up) of the multi-volume archive whose
/// first volume is [name]: x.arj gives x.a01 to x.a99, then x.100.
String arjVolumeName(String name, int n) {
  final slash = name.lastIndexOf(RegExp(r'[/\\]')) + 1;
  final dot = name.lastIndexOf('.');
  final hasExt = dot > slash;
  final base = hasExt ? name.substring(0, dot) : name;
  final c = hasExt && dot + 1 < name.length ? name[dot + 1] : 'a';
  return n < 100 ? '$base.$c${n.toString().padLeft(2, '0')}' : '$base.$n';
}

/// The volume number [arjVolumeName] gives [name] (x.a01 is 1, x.100 is
/// 100), 0 for the first volume (x.arj).
int arjVolumeIndex(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || name.length - dot != 4) return 0;
  final ext = name.substring(dot + 1);
  final digits = int.tryParse(ext) ?? int.tryParse(ext.substring(1));
  if (digits == null || digits < 1) return 0;
  if (int.tryParse(ext[0]) == null && digits >= 100) return 0;
  return digits;
}

/// The ARJ handler.
class ArjHandler {
  SeekableInStream? _stream;

  // the volumes: [_stream] and the next ones
  final List<SeekableInStream> _volumes = [];
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
  /// When the archive is the first volume of a multi-volume archive and
  /// [name] (its file name) and [openVolume] (IArchiveOpenVolumeCallback)
  /// are given, the next volumes are opened and the parts of split files
  /// joined.
  bool open(SeekableInStream stream,
      {String? name, SeekableInStream? Function(String name)? openVolume}) {
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
        it.volume = 0;
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
    _volumes.add(stream);
    if ((mainHeader.flags & ArjFlags.volume) != 0 &&
        name != null &&
        openVolume != null &&
        !_unexpectedEnd &&
        !_headersError) {
      _openVolumes(name, openVolume);
    }
    _joinParts();
    return true;
  }

  // the items of the next volumes, while the volume flag is set in the
  // main header of the last one read
  void _openVolumes(
      String name, SeekableInStream? Function(String name) openVolume) {
    final head = Uint8List(4 + kArjMaxHeaderSize + 4);
    final h = ArjRawHeader();
    // the next volumes after this one (opened as x.a01, it has no x.arj)
    final first = arjVolumeIndex(name);
    for (var n = first + 1; n < 1000; n++) {
      final s = openVolume(arjVolumeName(name, n));
      if (s == null) return;
      s.position = 0;
      final got = readFully(s, head, 0, head.length);
      final main = ArjMainHeader();
      if (isArcArj(head, got) != 1 ||
          readArjHeader(s, 0, h) != ArjHeaderResult.header ||
          !main.parse(h.basic)) {
        _headersError = true;
        return;
      }
      _volumes.add(s);
      var pos = h.end;
      for (;;) {
        final r = readArjHeader(s, pos, h);
        if (r == ArjHeaderResult.end) break;
        final it = ArjItem();
        if (r != ArjHeaderResult.header || !it.parse(h.basic)) {
          if (r == ArjHeaderResult.unexpectedEnd) {
            _unexpectedEnd = true;
          } else {
            _headersError = true;
          }
          return;
        }
        it.headerPos = pos;
        it.dataPos = h.end;
        it.ext = List.of(h.ext);
        it.volume = _volumes.length - 1;
        items.add(it);
        if (it.endPos > s.length) {
          it.truncated = true;
          _unexpectedEnd = true;
          return;
        }
        pos = it.endPos;
      }
      if ((main.flags & ArjFlags.volume) == 0) return;
    }
  }

  // joins the parts of the files split over volumes: a part with EXTFILE
  // continues the previous item of the same name when that one has VOLUME
  void _joinParts() {
    if (_volumes.length < 2) return;
    final all = List.of(items);
    items.clear();
    ArjItem? open;
    for (final it in all) {
      if (open != null &&
          it.splitBefore &&
          it.volume == open.lastPart.volume + 1 &&
          _sameBytes(it.nameBytes, open.nameBytes)) {
        if (open.nextParts.isEmpty) open.nextParts = [];
        open.nextParts.add(it);
        if (!it.splitAfter) open = null;
        continue;
      }
      items.add(it);
      open = it.splitAfter ? it : null;
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The number of volumes read.
  int get numVolumes => _volumes.length;

  void close() {
    _stream = null;
    _volumes.clear();
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
      case Kpid.numVolumes:
        return _volumes.length > 1 ? _volumes.length : null;
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
    final u = it.unixSpecial;
    if (u != null) {
      switch (u.$1) {
        case ArjUnixSpecial.symLink:
          return 0xA000 | perm;
        case ArjUnixSpecial.fifo:
          return 0x1000 | perm;
        case ArjUnixSpecial.hardLink:
          return 0x8000 | perm;
      }
      return perm;
    }
    if (it.fileType == ArjFileType.unixSpecial) return perm;
    return 0x8000 | perm;
  }

  // the unpacked size: the parts of a split file, a link target
  static int _sizeOf(ArjItem it) {
    final t = it.symLinkTarget;
    if (t != null) return t.length;
    var n = it.size;
    for (final p in it.nextParts) {
      n += p.size;
    }
    return n;
  }

  static int _packSizeOf(ArjItem it) {
    var n = it.packSize;
    for (final p in it.nextParts) {
      n += p.packSize;
    }
    return n;
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
        return _sizeOf(it);
      case Kpid.position:
        return it.splitBefore ? it.extFilePos : null;
      case Kpid.packSize:
        return _packSizeOf(it);
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
        // a split file has one CRC for each part
        return it.isDir || it.nextParts.isNotEmpty || it.unixSpecial != null
            ? null
            : it.crc;
      case Kpid.method:
        return '${it.method}';
      case Kpid.hostOS:
        return it.hostOsName;
      case Kpid.comment:
        return it.commentBytes.isEmpty ? null : it.comment;
      case Kpid.splitBefore:
        return it.splitBefore;
      case Kpid.splitAfter:
        return it.lastPart.splitAfter;
      case Kpid.symLink:
        final t = it.symLinkTarget;
        return t == null ? null : decodeArjName(t);
      case Kpid.hardLink:
        final u = it.unixSpecial;
        return u == null || u.$1 != ArjUnixSpecial.hardLink
            ? null
            : decodeArjName(u.$2);
    }
    return null;
  }

  bool _isPlain(ArjItem it) =>
      !it.isEncrypted &&
      !it.splitBefore &&
      !it.splitAfter &&
      it.nextParts.isEmpty &&
      it.fileType != ArjFileType.unixSpecial;

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
      total += _sizeOf(items[i]);
    }
    cb.setTotal(total);
    var completed = 0;
    final buf = Uint8List(1 << 16);
    final pw = _ExtractPassword(cb);
    for (final index in ix) {
      cb.setCompleted(completed);
      final it = items[index];
      var askMode = testMode ? AskMode.test : AskMode.extract;
      final out = cb.getStream(index, askMode);
      if (!testMode && out == null && !it.isDir) askMode = AskMode.skip;
      cb.prepareOperation(askMode);
      final base = completed;
      final res =
          _extractItem(it, out, buf, (n) => cb.setCompleted(base + n), pw);
      completed += _sizeOf(it);
      cb.setOperationResult(res);
    }
    cb.setCompleted(completed);
  }

  int _extractItem(ArjItem it, OutStream? out, Uint8List buf,
      void Function(int) progress, _ExtractPassword pw) {
    if (it.isDir ||
        it.fileType == ArjFileType.volumeLabel ||
        it.fileType == ArjFileType.chapter) {
      return OperationResult.ok;
    }
    final link = it.symLinkTarget;
    if (link != null) {
      out?.write(link, 0, link.length);
      out?.flush();
      return OperationResult.ok;
    }
    if (it.unixSpecial != null) return OperationResult.ok; // FIFO, hard link
    if (it.splitBefore || it.lastPart.splitAfter) {
      return OperationResult.unavailable;
    }
    List<int>? password;
    if (it.isEncrypted) {
      if (mainHeader.encryptionVersion > kArjOldGarble) {
        return OperationResult.unsupportedMethod; // ARJCRYPT
      }
      password = pw.get();
      if (password == null || password.isEmpty) {
        return OperationResult.wrongPassword;
      }
    }
    var done = 0;
    for (var part = 0; part <= it.nextParts.length; part++) {
      final p = part == 0 ? it : it.nextParts[part - 1];
      final base = done;
      final res =
          _extractPart(p, out, buf, (n) => progress(base + n), password);
      if (res != OperationResult.ok) return res;
      done += p.size;
    }
    return OperationResult.ok;
  }

  // the data of one item (or one part of a split file)
  int _extractPart(ArjItem it, OutStream? out, Uint8List buf,
      void Function(int) progress, List<int>? password) {
    InStream packed =
        WindowInStream(_volumes[it.volume], it.dataPos, it.packSize);
    if (password != null) {
      packed =
          ArjGarbleInStream(packed, ArjGarble(password, it.passwordModifier));
    }
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
    try {
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
    } on SevenZipException catch (e) {
      // bad data (or a wrong password) in the decoder
      if (e.kind != SevenZipError.data &&
          e.kind != SevenZipError.unexpectedEnd) {
        rethrow;
      }
      out?.flush();
      return it.truncated
          ? OperationResult.unexpectedEnd
          : OperationResult.dataError;
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

  // the password of new items (null: not garbled) and their modifier
  List<int>? _password;
  int _modifier = 0;

  void updateItems(
      OutStream outStream, int numItems, ArchiveUpdateCallback callback) {
    if (_volumes.length > 1) {
      throw const SevenZipException(
          'arj: multi-volume archives can not be updated',
          SevenZipError.unsupported);
    }
    final opCallback = callback is ArchiveUpdateCallbackFile
        ? callback as ArchiveUpdateCallbackFile
        : null;
    _password = null;
    if (callback is CryptoGetTextPassword2) {
      final pw = (callback as CryptoGetTextPassword2).cryptoGetTextPassword2();
      if (pw != null && pw.isNotEmpty) _password = utf8.encode(pw);
    }
    var garbled = _password != null;
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
        if (it.isEncrypted) garbled = true;
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
    final cTime = fileTimeToDosTime(created);
    // ARJ uses the low byte of the creation time as the password modifier
    _modifier = cTime & 0xFF;
    final mh = buildArjMainHeader(
        cTime: cTime,
        mTime: fileTimeToDosTime(now),
        name: _isArc ? mainHeader.nameBytes : const [],
        comment: _isArc ? mainHeader.commentBytes : const [],
        garbled: garbled);
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
        var link = oi.ext.isEmpty ? null : oi.path;
        if (link == null && _isLinkMode(callback, i)) {
          // the link target is the data (POSIX links stored by 7-Zip)
          link = utf8.decode(readAll(stream), allowMalformed: true);
          _makeSymLink(oi, link);
        }
        if (link != null) {
          opCallback?.reportOperation(
              EventIndexType.outArcIndex, i, UpdateNotifyOp.add);
          final h = buildArjLocalHeader(oi);
          outStream.write(h, 0, h.length);
        } else {
          final base = completed;
          _writeFile(
              outStream, oi, stream, (n) => callback.setCompleted(base + n));
          completed += oi.size;
        }
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

  // true when item [i] is a POSIX symbolic link whose data is the target
  static bool _isLinkMode(ArchiveUpdateCallback cb, int i) {
    final pa = cb.getProperty(i, Kpid.posixAttrib);
    if (pa is int) return (pa & 0xF000) == 0xA000;
    final a = cb.getProperty(i, Kpid.attrib);
    return a is int &&
        (a & FileAttrib.unixExtension) != 0 &&
        ((a >> 16) & 0xF000) == 0xA000;
  }

  // [oi] as the UNIX symbolic link ARJ writes with -a1: file type 6, host
  // UNIX (so Unix times), the 'U' header with the target, no data
  void _makeSymLink(ArjOutItem oi, String target) {
    oi.hostOs = ArjHostOs.unix;
    oi.fileType = ArjFileType.unixSpecial;
    oi.fileMode = ArjUnixMode.special | 0x1FF;
    oi.method = 0;
    oi.size = 0;
    oi.packSize = 0;
    oi.crc = 0;
    oi.garbled = false;
    oi.mTime = _dosToUnix(oi.mTime);
    oi.aTime = _dosToUnix(oi.aTime);
    oi.cTime = _dosToUnix(oi.cTime);
    oi.ext = [arjUnixSpecialExt(ArjUnixSpecial.symLink, utf8.encode(target))];
  }

  static int _dosToUnix(int dos) {
    final ft = dosTimeToFileTime(dos);
    return ft == null ? 0 : fileTimeToUnixTime(ft);
  }

  // the output of the packed data of an item: garbled with a new key
  // stream when a password is set
  OutStream _dataOut(OutStream out) {
    final pw = _password;
    return pw == null ? out : ArjGarbleOutStream(out, ArjGarble(pw, _modifier));
  }

  void _writeFile(
      OutStream out, ArjOutItem oi, InStream src, void Function(int) progress) {
    final input = _CrcTeeInStream(src, 4 << 20);
    final m = method;
    oi.method = m;
    oi.garbled = _password != null;
    oi.passwordModifier = _modifier;
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
      final packed = encode(_dataOut(out));
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
    _dataOut(out).write(d, 0, d.length);
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
      _dataOut(out).write(d, 0, d.length);
      return;
    }
    final tee = input as _CrcTeeInStream;
    if (out is SeekableOutStream) {
      final start = out.position;
      var h = buildArjLocalHeader(oi);
      out.write(h, 0, h.length);
      final n = copyStream(tee, _dataOut(out));
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
      final sl = cb.getProperty(i, Kpid.symLink);
      if (sl is String && sl.isNotEmpty) _makeSymLink(oi, sl);
    }
    return oi;
  }
}

/// The password of an extraction (ICryptoGetTextPassword), asked once when
/// the first garbled file is met; UTF-8 bytes, as ARJ takes the bytes of
/// its command line.
class _ExtractPassword {
  final ArchiveExtractCallback _cb;
  List<int>? _pw;
  bool _asked = false;
  _ExtractPassword(this._cb);

  List<int>? get() {
    if (!_asked) {
      _asked = true;
      final cb = _cb;
      if (cb is CryptoGetTextPassword) {
        _pw =
            utf8.encode((cb as CryptoGetTextPassword).cryptoGetTextPassword());
      }
    }
    return _pw;
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
