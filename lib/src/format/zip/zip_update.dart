// Writing and updating zip archives (IOutArchive::UpdateItems and the -m
// switches of the zip format), written from the PKWARE APPNOTE and the
// WinZip AES specification. The choices follow what 7-Zip writes for zip
// archives: Deflate at level 5 by default, the NTFS extra field (0x000a)
// with the modification time in the central directory, POSIX modes in the
// high 16 bits of the external attributes, Store when compression does not
// make an item smaller, Zip64 only when a value needs it, and data
// descriptors when the output can not be seeked.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../codec/bzip2/bzip2_coder.dart';
import '../../codec/codec.dart';
import '../../codec/copy.dart';
import '../../codec/deflate/deflate_coder.dart';
import '../../codec/lzma/lzma_coder.dart';
import '../../codec/ppmd8/ppmd8_coder.dart';
import '../../common/method_props.dart';
import '../../crypto/winzip_aes.dart';
import '../../crypto/zip_crypto.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../handler_out.dart';
import '../xz/xz_enc.dart';
import 'zip_header.dart';
import 'zip_out.dart';

/// Encryption methods of -mem.
enum ZipEncryption { zipCrypto, aes128, aes192, aes256 }

/// The write options of the zip format: the -m switches.
class ZipWriteOptions {
  MultiMethodProps methodProps = MultiMethodProps();
  final HandlerTimeOptions timeOptions = HandlerTimeOptions();

  /// -mem: the encryption method used with a password.
  ZipEncryption encryption = ZipEncryption.zipCrypto;

  /// -mcu: names are always written as UTF-8 with the UTF-8 flag.
  bool? forceUtf8;

  /// -mcl: names are written in the local code page (no UTF-8 flag).
  bool useLocalCodePage = false;

  /// -mcp: the code page of names without the UTF-8 flag.
  int codePage = ZipCodePage.auto;

  /// For tests: the random source of salts and encryption headers.
  Random? random;

  ZipWriteOptions() {
    init();
  }

  void init() {
    methodProps = MultiMethodProps();
    timeOptions.init();
    encryption = ZipEncryption.zipCrypto;
    forceUtf8 = null;
    useLocalCodePage = false;
    codePage = ZipCodePage.auto;
  }

  /// ISetProperties::SetProperties of the zip handler: m (method), x
  /// (level), em (encryption), cu, cl, cp, tm, ta, tc, tp, mt, memuse and
  /// the coder properties (d, fb, pass, mc, o, mem, a, eos...).
  void setProperties(List<MapEntry<String, PropVariant>> props) {
    init();
    for (final p in props) {
      final name = p.key.toLowerCase();
      final value = p.value;
      if (name.isEmpty) invalidArg();
      if (name == 'em') {
        if (value.vt != VarType.bstr) invalidArg('Bad em value');
        switch (value.stringValue.toLowerCase()) {
          case 'zipcrypto':
            encryption = ZipEncryption.zipCrypto;
          case 'aes128':
            encryption = ZipEncryption.aes128;
          case 'aes192':
            encryption = ZipEncryption.aes192;
          case 'aes256':
            encryption = ZipEncryption.aes256;
          default:
            invalidArg('Unsupported encryption method: ${value.stringValue}');
        }
        continue;
      }
      if (name == 'cu') {
        forceUtf8 = propVariantToBool(value);
        continue;
      }
      if (name == 'cl') {
        useLocalCodePage = propVariantToBool(value);
        continue;
      }
      if (name == 'cp') {
        codePage = parsePropToUInt32('', value, ZipCodePage.oem437);
        continue;
      }
      if (timeOptions.parse(name, value)) continue;
      methodProps.setProperty(name, value);
    }
    // the method name is checked now (E_INVALIDARG like 7-Zip)
    _methodId();
  }

  /// The method of new items from -mm (Deflate by default, Store at -mx0).
  int _methodId() {
    final methods = methodProps.methods;
    final name = methods.isNotEmpty ? methods[0].methodName : '';
    if (name.isEmpty) {
      return methodProps.getLevel() == 0 ? ZipMethod.store : ZipMethod.deflate;
    }
    switch (name.toLowerCase()) {
      case 'copy':
      case 'store':
        return ZipMethod.store;
      case 'deflate':
        return ZipMethod.deflate;
      case 'bzip2':
        return ZipMethod.bzip2;
      case 'lzma':
        return ZipMethod.lzma;
      case 'ppmd':
        return ZipMethod.ppmd;
      case 'xz':
        return ZipMethod.xz;
      case 'deflate64':
        return ZipMethod.deflate64;
    }
    // a numeric method id
    final (v, n) = convertStringToUInt32(name, 0);
    if (n == name.length && n > 0) {
      if (v == ZipMethod.store ||
          v == ZipMethod.deflate ||
          v == ZipMethod.deflate64 ||
          v == ZipMethod.bzip2 ||
          v == ZipMethod.lzma ||
          v == ZipMethod.ppmd ||
          v == ZipMethod.xz) {
        return v;
      }
    }
    invalidArg('Unsupported zip method: $name');
  }

  int get methodId => _methodId();

  int get level => methodProps.getLevel();

  /// The coder properties of the method, with the level, for an item of
  /// [size] bytes.
  List<CoderProp> coderProps(int? size) {
    final m = methodProps.methods.isNotEmpty
        ? methodProps.methods[0].copy()
        : OneMethodInfo();
    methodProps.setGlobalLevelTo(m);
    return m.toCoderProperties(dataSizeReduce: size);
  }
}

/// The part of an old item needed to copy it.
class _OldRange {
  final int start;
  final int end;
  _OldRange(this.start, this.end);
}

/// IOutArchive::UpdateItems of the zip handler.
class ZipUpdater {
  final ZipWriteOptions options;
  final SeekableInStream? oldStream;
  final List<ZipItem> oldItems;
  final Uint8List? oldComment;

  late OutStream _out;
  SeekableOutStream? _seekOut;
  int _pos = 0;
  final Uint8List _buf = Uint8List(1 << 16);
  final List<ZipOutItem> _written = [];
  Uint8List? _password;
  bool _passwordAsked = false;

  ZipUpdater(
      {required this.options,
      required this.oldStream,
      required this.oldItems,
      this.oldComment});

  void _write(Uint8List b, [int off = 0, int? len]) {
    final n = len ?? b.length - off;
    _out.write(b, off, n);
    _pos += n;
  }

  static int get _hostMadeBy =>
      Platform.isWindows ? (ZipHost.fat << 8) | 63 : (ZipHost.unix << 8) | 63;

  Uint8List? _getPassword(ArchiveUpdateCallback cb) {
    if (!_passwordAsked) {
      _passwordAsked = true;
      if (cb is CryptoGetTextPassword2) {
        final s = (cb as CryptoGetTextPassword2).cryptoGetTextPassword2();
        if (s != null) _password = Uint8List.fromList(utf8.encode(s));
      }
    }
    return _password;
  }

  /// Writes the new archive to [outStream].
  void update(OutStream outStream, int numItems, ArchiveUpdateCallback cb) {
    _out = outStream;
    _seekOut = outStream is SeekableOutStream ? outStream : null;
    _pos = _seekOut?.position ?? 0;
    final startPos = _pos;
    final opCallback = cb is ArchiveUpdateCallbackFile
        ? cb as ArchiveUpdateCallbackFile
        : null;

    final infos = <UpdateItemInfo>[];
    var total = 0;
    for (var i = 0; i < numItems; i++) {
      final info = cb.getUpdateItemInfo(i);
      infos.add(info);
      if (info.indexInArchive >= 0 &&
          (oldStream == null || info.indexInArchive >= oldItems.length)) {
        invalidArg('Bad index in archive');
      }
      if (info.newData) {
        final s = cb.getProperty(i, Kpid.size);
        if (s is int) total += s;
      } else {
        total += oldItems[info.indexInArchive].packSize;
      }
    }
    cb.setTotal(total);

    var completed = 0;
    for (var i = 0; i < numItems; i++) {
      cb.setCompleted(completed);
      final info = infos[i];
      if (!info.newData) {
        final old = oldItems[info.indexInArchive];
        opCallback?.reportOperation(EventIndexType.inArcIndex,
            info.indexInArchive, UpdateNotifyOp.replicate);
        _copyOld(old, info.newProps ? cb : null, i);
        completed += old.packSize;
        continue;
      }
      final r = _addNew(cb, i, opCallback, completed);
      if (r != null) completed += r;
    }

    // the central directory
    final cdOffset = _pos - startPos;
    var cdSize = 0;
    var anyZip64 = false;
    for (final it in _written) {
      final rec = buildCentralRecord(it);
      if (it.needsCentralZip64 || it.localZip64) anyZip64 = true;
      _write(rec);
      cdSize += rec.length;
    }
    final comment = oldComment ?? Uint8List(0);
    writeEndRecords(
        _out, _written.length, cdOffset, cdSize, _pos - startPos, comment,
        forceZip64: false, versionMadeBy: _hostMadeBy);
    if (anyZip64) {
      // nothing more: the Zip64 end records are needed only for values
      // that do not fit (checked by writeEndRecords)
    }
    _out.flush();
    cb.setCompleted(completed);
  }

  // copies an old item: its local header and data as they are (or a new
  // local header when [cb] gives new properties), a new data descriptor
  // when it had one
  void _copyOld(ZipItem old, ArchiveUpdateCallback? cb, int index) {
    final s = oldStream!;
    final oi = ZipOutItem()
      ..versionMadeBy = old.versionMadeBy
      ..versionNeeded = old.versionNeeded
      ..flags = old.flags
      ..method = old.method
      ..dosTime = old.dosTime
      ..crc = old.crc
      ..packSize = old.packSize
      ..size = old.size
      ..nameBytes = old.nameBytes
      ..comment = old.comment
      ..internalAttr = old.internalAttr
      ..externalAttr = old.externalAttr
      ..centralExtra = removeExtraBlock(old.centralExtra, ZipExtraId.zip64)
      ..localExtra = removeExtraBlock(old.localExtra, ZipExtraId.zip64);
    oi.localOffset = _pos;
    final localHadZip64 = _hasBlock(old.localExtra, ZipExtraId.zip64);
    oi.localZip64 =
        localHadZip64 || old.size >= 0xFFFFFFFF || old.packSize >= 0xFFFFFFFF;
    if (old.dataPos < 0) {
      throw const SevenZipException(
          'zip: the local header of an item is missing', SevenZipError.headers);
    }
    if (cb != null) _applyNewProps(oi, old, cb, index);
    // a new local header with the central values (the old one may have
    // zeros and a descriptor)
    final hasDescriptor = (oi.flags & ZipFlags.descriptor) != 0;
    _write(buildLocalHeader(oi));
    final range = _OldRange(old.dataPos, old.dataPos + old.packSize);
    _copyRange(s, range);
    if (hasDescriptor) _write(buildDescriptor(oi));
    _written.add(oi);
  }

  static bool _hasBlock(Uint8List extra, int id) {
    var p = 0;
    while (p + 4 <= extra.length) {
      final bid = extra[p] | (extra[p + 1] << 8);
      final sz = extra[p + 2] | (extra[p + 3] << 8);
      if (bid == id) return true;
      p += 4 + sz;
    }
    return false;
  }

  // new name, attributes and times of a kept item
  void _applyNewProps(
      ZipOutItem oi, ZipItem old, ArchiveUpdateCallback cb, int i) {
    final p = cb.getProperty(i, Kpid.path);
    if (p is String) {
      var name = p.replaceAll('\\', '/');
      if (old.isDir && !name.endsWith('/')) name += '/';
      final (bytes, utf8Flag) = _encodeName(name);
      oi.nameBytes = bytes;
      oi.flags = (oi.flags & ~ZipFlags.utf8) | (utf8Flag ? ZipFlags.utf8 : 0);
      // the Unicode path extra field would name the old path
      oi.centralExtra =
          removeExtraBlock(oi.centralExtra, ZipExtraId.unicodePath);
      oi.localExtra = removeExtraBlock(oi.localExtra, ZipExtraId.unicodePath);
    }
    // the time is the password check of ZipCrypto items with a descriptor
    final timeIsCheck =
        old.isEncrypted && old.method != ZipMethod.aes && old.hasDescriptor;
    final mt = cb.getProperty(i, Kpid.mTime);
    if (mt is int && !timeIsCheck) {
      oi.dosTime = fileTimeToDosTime(mt);
      oi.centralExtra = removeExtraBlock(oi.centralExtra, ZipExtraId.extTime);
      oi.localExtra = removeExtraBlock(oi.localExtra, ZipExtraId.extTime);
      oi.centralExtra = _replaceNtfs(oi.centralExtra, mt, cb, i);
    }
  }

  Uint8List _replaceNtfs(
      Uint8List extra, int mTime, ArchiveUpdateCallback cb, int i) {
    final e = removeExtraBlock(extra, ZipExtraId.ntfs);
    final to = options.timeOptions;
    final writeM = !to.writeMTime.def || to.writeMTime.val;
    if (!writeM) return e;
    final at = to.writeATime.def && to.writeATime.val
        ? cb.getProperty(i, Kpid.aTime)
        : null;
    final ct = to.writeCTime.def && to.writeCTime.val
        ? cb.getProperty(i, Kpid.cTime)
        : null;
    final ntfs = buildNtfsExtra(mTime, at is int ? at : 0, ct is int ? ct : 0);
    return Uint8List.fromList([...ntfs, ...e]);
  }

  void _copyRange(SeekableInStream s, _OldRange r) {
    var left = r.end - r.start;
    var p = r.start;
    while (left > 0) {
      final want = left < _buf.length ? left : _buf.length;
      s.position = p;
      final n = s.read(_buf, 0, want);
      if (n == 0) {
        throw const SevenZipException(
            'Unexpected end of the old archive', SevenZipError.unexpectedEnd);
      }
      _write(_buf, 0, n);
      p += n;
      left -= n;
    }
  }

  // the name bytes and whether the UTF-8 flag is set
  (Uint8List, bool) _encodeName(String name) {
    final o = options;
    var ascii = true;
    for (var k = 0; k < name.length; k++) {
      if (name.codeUnitAt(k) >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (o.forceUtf8 == true) {
      return (Uint8List.fromList(utf8.encode(name)), !ascii);
    }
    if (ascii) return (Uint8List.fromList(name.codeUnits), false);
    if (o.useLocalCodePage || o.codePage != ZipCodePage.auto) {
      switch (o.codePage) {
        case ZipCodePage.latin1:
        case ZipCodePage.ansi1252:
          var ok = true;
          for (var k = 0; k < name.length; k++) {
            if (name.codeUnitAt(k) > 0xFF) ok = false;
          }
          if (ok) return (Uint8List.fromList(latin1.encode(name)), false);
        case ZipCodePage.utf8:
          return (Uint8List.fromList(utf8.encode(name)), false);
        default:
          final b = encodeCp437(name);
          if (b != null) return (b, false);
      }
      if (o.forceUtf8 == false) {
        return (Uint8List.fromList(utf8.encode(name)), false);
      }
    }
    return (Uint8List.fromList(utf8.encode(name)), true);
  }

  // adds a new item; returns its size for the progress, null when the
  // item was left out
  int? _addNew(ArchiveUpdateCallback cb, int i,
      ArchiveUpdateCallbackFile? opCallback, int completed) {
    if (cb.getProperty(i, Kpid.isAnti) == true) return null;
    final pathProp = cb.getProperty(i, Kpid.path);
    if (pathProp is! String) invalidArg('Bad path property');
    var isDir = cb.getProperty(i, Kpid.isDir) == true;
    final attribProp = cb.getProperty(i, Kpid.attrib);
    final posixProp = cb.getProperty(i, Kpid.posixAttrib);
    int? posix;
    if (posixProp is int) {
      posix = posixProp & 0xFFFF;
    } else if (attribProp is int &&
        (attribProp & FileAttrib.unixExtension) != 0) {
      posix = (attribProp >> 16) & 0xFFFF;
    }
    if (attribProp is int && (attribProp & FileAttrib.directory) != 0) {
      isDir = true;
    }
    final symLinkProp = cb.getProperty(i, Kpid.symLink);
    final isLink = !isDir &&
        ((symLinkProp is String && symLinkProp.isNotEmpty) ||
            (posix != null && (posix & 0xF000) == 0xA000));

    var name = pathProp.replaceAll('\\', '/');
    while (name.startsWith('/')) {
      name = name.substring(1);
    }
    if (isDir && !name.endsWith('/')) name += '/';

    final oi = ZipOutItem()
      ..versionMadeBy = _hostMadeBy
      ..localOffset = _pos;
    final (nameBytes, utf8Flag) = _encodeName(name);
    oi.nameBytes = nameBytes;
    if (utf8Flag) oi.flags |= ZipFlags.utf8;

    // attributes
    var low = attribProp is int ? attribProp & 0x7FFF : 0;
    if (isDir) {
      low |= FileAttrib.directory;
    } else if (attribProp is! int) {
      low |= FileAttrib.archive;
    }
    posix ??= isDir ? 0x41ED : 0x81A4; // 040755, 0100644
    if (isLink) posix = (posix & 0xFFF) | 0xA000;
    if (isDir) posix = (posix & 0xFFF) | 0x4000;
    oi.externalAttr =
        ((posix << 16) | FileAttrib.unixExtension | low) & 0xFFFFFFFF;

    // times
    final to = options.timeOptions;
    final mt = cb.getProperty(i, Kpid.mTime);
    final mTime = mt is int
        ? mt
        : DateTime.now().microsecondsSinceEpoch * 10 + kUnixEpochFileTime;
    oi.dosTime = fileTimeToDosTime(mTime);
    final writeM = !to.writeMTime.def || to.writeMTime.val;
    final writeA = to.writeATime.def && to.writeATime.val;
    final writeC = to.writeCTime.def && to.writeCTime.val;
    final extra = BytesBuilder(copy: false);
    if (writeM || writeA || writeC) {
      final at = writeA ? cb.getProperty(i, Kpid.aTime) : null;
      final ct = writeC ? cb.getProperty(i, Kpid.cTime) : null;
      extra.add(buildNtfsExtra(
          writeM ? mTime : 0, at is int ? at : 0, ct is int ? ct : 0));
    }

    if (isDir) {
      opCallback?.reportOperation(
          EventIndexType.outArcIndex, i, UpdateNotifyOp.add);
      oi.versionNeeded = 20;
      oi.centralExtra = extra.takeBytes();
      _write(buildLocalHeader(oi));
      _written.add(oi);
      return 0;
    }

    InStream? stream;
    Uint8List? linkData;
    if (isLink && symLinkProp is String && symLinkProp.isNotEmpty) {
      linkData = Uint8List.fromList(utf8.encode(symLinkProp));
    } else {
      stream = cb.getStream(i);
      if (stream == null) return null; // S_FALSE: the item is left out
    }
    opCallback?.reportOperation(
        EventIndexType.outArcIndex, i, UpdateNotifyOp.add);
    try {
      int? size;
      final sp = cb.getProperty(i, Kpid.size);
      if (sp is int) size = sp;
      if (stream is StreamGetSize) {
        final sz = (stream as StreamGetSize).streamSize;
        if (sz != null) size = sz;
      }
      InStream input;
      if (linkData != null) {
        input = MemoryInStream(linkData);
        size = linkData.length;
      } else {
        input = stream!;
      }
      final base = completed;
      _writeData(oi, extra.takeBytes(), input, size, cb,
          (n) => cb.setCompleted(base + n));
      cb.setOperationResult(0); // NUpdate::NOperationResult::kOK
      return oi.size;
    } finally {
      releaseStream(stream);
    }
  }

  static int _versionFor(int method) {
    switch (method) {
      case ZipMethod.deflate:
        return 20;
      case ZipMethod.deflate64:
        return 21;
      case ZipMethod.bzip2:
        return 46;
      case ZipMethod.lzma:
      case ZipMethod.ppmd:
        return 63;
      case ZipMethod.xz:
        return 20;
    }
    return 10;
  }

  // compresses (and encrypts) the data of a new item
  void _writeData(ZipOutItem oi, Uint8List centralExtra, InStream input,
      int? size, ArchiveUpdateCallback cb, void Function(int) progress) {
    final password = _getPassword(cb);
    var method = options.methodId;
    if (size == 0) method = ZipMethod.store;
    final seekOut = _seekOut;
    final seekIn = input is SeekableInStream ? input : null;
    final inStart = seekIn?.position ?? 0;
    // a copy of a small input, to write it again as stored data when the
    // compression does not make it smaller (the input may not be seekable)
    final rec = seekIn == null &&
            seekOut != null &&
            method != ZipMethod.store &&
            (size == null || size <= _kReplayMax)
        ? _RecordingInStream(input, _kReplayMax)
        : null;
    InStream src = rec ?? input;
    bool canReplay() => seekIn != null || (rec != null && rec.complete);
    void replay() {
      if (seekIn != null) {
        seekIn.position = inStart;
        src = seekIn;
      } else {
        src = MemoryInStream(rec!.bytes);
      }
    }

    // Zip64 in the local header when a size may not fit
    oi.localZip64 = size == null
        ? seekOut == null
        : size + (size >> 3) + (1 << 16) >= 0xFFFFFFFF;

    final encryption = password == null ? null : options.encryption;
    final aesStrength = switch (encryption) {
      ZipEncryption.aes128 => 1,
      ZipEncryption.aes192 => 2,
      ZipEncryption.aes256 => 3,
      _ => 0,
    };

    for (var attempt = 0;; attempt++) {
      final headerPos = _pos;
      oi.method = method;
      oi.flags &= ZipFlags.utf8;
      var versionNeeded = _versionFor(method);
      if (method == ZipMethod.lzma) oi.flags |= ZipFlags.bit1; // EOS marker
      var local = BytesBuilder(copy: false);
      var central = BytesBuilder(copy: false)..add(centralExtra);
      if (password != null) oi.flags |= ZipFlags.encrypted;
      var aesVendor = 0;
      if (aesStrength != 0) {
        // AE-1 (with the CRC) as WinZip writes it, AE-2 for tiny items and
        // BZip2, where the CRC is not stored
        aesVendor =
            (size != null && size < 20) || method == ZipMethod.bzip2 ? 2 : 1;
        final ex = buildAesExtra(aesVendor, aesStrength, method);
        local.add(ex);
        central.add(ex);
        oi.method = ZipMethod.aes;
        versionNeeded = 51;
      } else if (password != null) {
        // ZipCrypto: the check byte is the high byte of the DOS time, the
        // CRC and the sizes follow in a data descriptor
        oi.flags |= ZipFlags.descriptor;
        if (versionNeeded < 20) versionNeeded = 20;
      }
      if (seekOut == null) oi.flags |= ZipFlags.descriptor;
      if (oi.localZip64 && versionNeeded < 45) versionNeeded = 45;
      oi.versionNeeded = versionNeeded;
      oi.localExtra = local.takeBytes();
      oi.centralExtra = central.takeBytes();
      oi.crc = 0;
      oi.packSize = 0;
      oi.size = 0;
      final descriptor = (oi.flags & ZipFlags.descriptor) != 0;
      _write(buildLocalHeader(oi, zeroSizes: true));
      final dataStart = _pos;

      // the chain: crc of the input, compressor, encryption, output
      final crcIn = _CrcInStream(src, progress);
      final counter = _CountOut(this);
      OutStream encOut = counter;
      WzAesEncoder? aes;
      if (aesStrength != 0) {
        aes = WzAesEncoder(counter, password!, aesStrength);
        aes.writeHeader(options.random);
        encOut = aes;
      } else if (password != null) {
        final zc = ZipCryptoEncoder(counter, password);
        zc.writeHeader((oi.dosTime >> 8) & 0xFF, options.random);
        encOut = zc;
      }
      final coder = _makeCompressor(method, size);
      if (method == ZipMethod.lzma) {
        final h = Uint8List(4 + 5);
        h[0] = 26; // LZMA SDK version 26.01
        h[1] = 1;
        h[2] = 5;
        h[3] = 0;
        h.setRange(4, 9, coder.props);
        encOut.write(h, 0, 9);
      }
      coder.encode(crcIn, _NoFlushOut(encOut));
      aes?.close();
      oi.crc = crcIn.crc;
      oi.size = crcIn.count;
      oi.packSize = _pos - dataStart;
      if (aesVendor == 2) oi.crc = 0;

      // Store instead when the data did not get smaller
      if (method != ZipMethod.store &&
          oi.size > 0 &&
          oi.packSize -
                  (aes != null ? wzAesOverhead(aesStrength) : 0) -
                  (password != null && aes == null
                      ? kZipCryptoHeaderSize
                      : 0) >=
              oi.size &&
          seekOut != null &&
          canReplay() &&
          attempt == 0) {
        seekOut.position = headerPos;
        seekOut.truncate(headerPos);
        _pos = headerPos;
        replay();
        method = ZipMethod.store;
        size = oi.size;
        continue;
      }

      if (!oi.localZip64 &&
          (oi.size >= 0xFFFFFFFF || oi.packSize >= 0xFFFFFFFF)) {
        if (seekOut != null && canReplay() && attempt < 2) {
          // write it again with a Zip64 local header
          seekOut.position = headerPos;
          seekOut.truncate(headerPos);
          _pos = headerPos;
          replay();
          oi.localZip64 = true;
          size = oi.size;
          continue;
        }
        if (!descriptor) {
          throw const SevenZipException(
              'zip: the item needs Zip64 but its size was not known',
              SevenZipError.unsupported);
        }
      }

      if (descriptor) _write(buildDescriptor(oi));
      if (seekOut != null) {
        // the local header with the real values
        final end = _pos;
        seekOut.position = headerPos;
        seekOut.write(buildLocalHeader(oi), 0, oi.localHeaderSize);
        seekOut.position = end;
      }
      _written.add(oi);
      return;
    }
  }

  Compressor _makeCompressor(int method, int? size) {
    final props = options.coderProps(size);
    switch (method) {
      case ZipMethod.store:
        return CopyCompressor();
      case ZipMethod.deflate:
        return DeflateCompressor.fromCoderProps(props);
      case ZipMethod.deflate64:
        return Deflate64Compressor.fromCoderProps(props);
      case ZipMethod.bzip2:
        return Bzip2Compressor.fromCoderProps(props);
      case ZipMethod.lzma:
        final p = [
          ...props,
          CoderProp(CoderPropId.endMarker, const PropVariant.boolean(true))
        ];
        final c = LzmaCompressor.fromCoderProps(
            p.where((e) => e.id != CoderPropId.numThreads));
        if (size != null) c.expectedDataSize = size;
        return c;
      case ZipMethod.ppmd:
        return Ppmd8ZipCompressor.fromCoderProps(props);
      case ZipMethod.xz:
        final x = XzEncoder();
        x.setCoderProperties(props);
        if (size != null) x.setExpectedDataSize(size);
        return x;
    }
    invalidArg('Unsupported zip method $method');
  }
}

/// Largest input kept in memory for writing it again as stored data.
const int _kReplayMax = 8 << 20;

/// Keeps a copy of what is read, up to [_max] bytes.
class _RecordingInStream implements InStream {
  final InStream _in;
  final int _max;
  final MemoryOutStream _copy = MemoryOutStream(1 << 16);
  bool _overflow = false;
  bool _end = false;
  _RecordingInStream(this._in, this._max);

  /// Whether the whole input was read and kept.
  bool get complete => _end && !_overflow;

  Uint8List get bytes => _copy.toBytes();

  @override
  int read(Uint8List buf, int off, int len) {
    final n = _in.read(buf, off, len);
    if (n == 0) {
      _end = true;
    } else if (!_overflow) {
      if (_copy.length + n > _max) {
        _overflow = true;
      } else {
        _copy.write(buf, off, n);
      }
    }
    return n;
  }
}

/// Counts and checksums the input of a compressor.
class _CrcInStream implements InStream {
  final InStream _in;
  final void Function(int) _progress;
  int _crc = 0xFFFFFFFF;
  int count = 0;
  int _next = 1 << 20;
  _CrcInStream(this._in, this._progress);

  int get crc => _crc ^ 0xFFFFFFFF;

  @override
  int read(Uint8List buf, int off, int len) {
    final n = _in.read(buf, off, len);
    if (n > 0) {
      _crc = crc32Update(_crc, buf, off, off + n);
      count += n;
      if (count >= _next) {
        _next = count + (1 << 20);
        _progress(count);
      }
    }
    return n;
  }
}

/// The output of an item's data: counts into the updater's position.
class _CountOut implements OutStream {
  final ZipUpdater _u;
  _CountOut(this._u);
  @override
  void write(Uint8List buf, int off, int len) => _u._write(buf, off, len);
  @override
  void flush() {}
}

/// Keeps the compressors from flushing the archive output per item.
class _NoFlushOut implements OutStream {
  final OutStream _o;
  _NoFlushOut(this._o);
  @override
  void write(Uint8List buf, int off, int len) => _o.write(buf, off, len);
  @override
  void flush() {}
}
