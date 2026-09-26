// The RAR archive handlers: IInArchive (Open, GetProperty, Extract) for
// RAR 1.5 to 4.x archives (the "Rar" format) and RAR5 archives ("Rar5"),
// and IOutArchive (UpdateItems) for RAR5 (rar5_out.dart).
//
// The headers are read as libarchive's RAR and RAR5 readers read them
// (BSD 2-clause, see LICENSE), completed from the RAR5 technote; the item
// properties follow what 7-Zip shows for rar archives. The 7-Zip rar
// handlers (LGPL) and the unRAR source were not used
// (docs/architecture.md, section 10).

import 'dart:convert';
import 'dart:typed_data';

import '../../codec/rar/rar3_decoder.dart';
import '../../codec/rar/rar5_decoder.dart';
import '../../common/method_props.dart';
import '../../crypto/blake2sp.dart';
import '../../crypto/rar5_kdf.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import 'rar4_in.dart';
import 'rar5_in.dart';
import 'rar5_out.dart';
import 'rar_archive.dart';
import 'rar_crypto.dart';
import 'rar_item.dart';

/// k_PropVar_TimePrec_Base + 7 (100 ns), k_PropVar_TimePrec_Base + 9 (1 ns).
const int _kTimePrec100ns = 16 + 7;
const int _kTimePrec1ns = 16 + 9;

/// The largest RAR5 window the decoder allocates (1 GiB, the largest
/// dictionary of RAR 5 and 6).
const int _maxWindow = 1 << 30;

/// A RAR or RAR5 archive handler.
class RarHandler {
  /// true for the Rar5 format (RAR5 archives only); false for the Rar
  /// format, which opens RAR 1.5 to 4.x archives and also RAR5 ones (so
  /// that an archive chosen by its "rar" extension can be updated).
  final bool rar5Only;
  RarHandler({required bool rar5}) : rar5Only = rar5;

  /// Whether the open archive (or the one to write) is a RAR5 archive.
  bool get rar5 => _a?.isRar5 ?? rar5Only;

  RarArchiveData? _a;
  Rar5Decoder? _dec5;
  Rar3Decoder? _dec3;

  // the index of the last item whose data went through the decoder, for
  // solid streams
  int _lastDecoded = -1;

  /// Options of new RAR5 archives (SetProperties).
  final Rar5WriteOptions writeOptions = Rar5WriteOptions();

  RarArchiveData? get archive => _a;
  List<RarItem> get items => _a?.items ?? const [];

  /// IInArchive::Open. false (S_FALSE) when [stream] is not an archive of
  /// this format. [name] is the file name of the volume, used to find the
  /// next volumes with [openVolume].
  bool open(SeekableInStream stream,
      {String? name,
      RarVolumeOpener? openVolume,
      RarPasswordGetter? getPassword}) {
    close();
    if (!rar5Only) {
      final a = RarArchiveData(false);
      if (Rar4Reader(a, openVolume, getPassword).open(stream, name)) {
        _a = a;
        return true;
      }
    }
    final a = RarArchiveData(true);
    if (!Rar5Reader(a, openVolume, getPassword).open(stream, name)) {
      return false;
    }
    _a = a;
    return true;
  }

  /// IInArchive::Close. The volumes after the first are not closed here:
  /// their owner (the open callback) closes them.
  void close() {
    _a = null;
    _dec5 = null;
    _dec3 = null;
    _lastDecoded = -1;
  }

  int get numberOfItems => items.length;

  static const List<int> itemPropIds5 = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.aTime,
    Kpid.attrib,
    Kpid.encrypted,
    Kpid.solid,
    Kpid.splitBefore,
    Kpid.splitAfter,
    Kpid.crc,
    Kpid.hostOS,
    Kpid.method,
    Kpid.characts,
    Kpid.symLink,
    Kpid.hardLink,
    Kpid.copyLink,
    Kpid.volumeIndex,
    Kpid.checksum,
  ];

  static const List<int> itemPropIds4 = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.aTime,
    Kpid.attrib,
    Kpid.encrypted,
    Kpid.solid,
    Kpid.commented,
    Kpid.splitBefore,
    Kpid.splitAfter,
    Kpid.crc,
    Kpid.hostOS,
    Kpid.method,
    Kpid.unpackVer,
    Kpid.symLink,
    Kpid.volumeIndex,
  ];

  static const List<int> archivePropIds = [
    Kpid.totalPhySize,
    Kpid.characts,
    Kpid.solid,
    Kpid.numBlocks,
    Kpid.encrypted,
    Kpid.isVolume,
    Kpid.volumeIndex,
    Kpid.numVolumes,
    Kpid.comment,
  ];

  List<int> get itemPropIds => rar5 ? itemPropIds5 : itemPropIds4;

  /// The precision of the times: 1 ns when a RAR5 item has nanoseconds,
  /// else 100 ns.
  int get timePrec {
    for (final it in items) {
      if (it.unixTimeNs) return _kTimePrec1ns;
    }
    return _kTimePrec100ns;
  }

  int get errorFlags {
    final a = _a;
    if (a == null) return ErrorFlags.isNotArc;
    var v = 0;
    if (a.unexpectedEnd) v |= ErrorFlags.unexpectedEnd;
    if (a.headersError) v |= ErrorFlags.headersError;
    if (a.unsupportedFeature) v |= ErrorFlags.unsupportedFeature;
    return v;
  }

  // GetArchiveProperty
  Object? getArchiveProperty(int propId) {
    final a = _a;
    if (a == null) return null;
    switch (propId) {
      case Kpid.phySize:
        return a.phySize - a.sfxSize;
      case Kpid.offset:
        return a.sfxSize == 0 ? null : a.sfxSize;
      case Kpid.totalPhySize:
        if (a.volumes.length < 2) return null;
        var t = 0;
        for (final s in a.volumeSizes) {
          t += s;
        }
        return t;
      case Kpid.solid:
        return a.solid;
      case Kpid.numBlocks:
        return a.items.length;
      case Kpid.encrypted:
        return rar5 ? a.encryptedHeaders : null;
      case Kpid.isVolume:
        return a.isVolume;
      case Kpid.volumeIndex:
        return a.isVolume && a.volumeNumber >= 0 ? a.volumeNumber : null;
      case Kpid.numVolumes:
        return a.volumes.length;
      case Kpid.comment:
        return a.comment;
      case Kpid.characts:
        return _archiveCharacts(a);
      case Kpid.errorFlags:
        return errorFlags;
    }
    return null;
  }

  String _archiveCharacts(RarArchiveData a) {
    final t = <String>[];
    if (a.isVolume) t.add('Volume');
    if (a.comment != null) t.add('Comment');
    if (a.locked) t.add('Lock');
    if (a.solid) t.add('Solid');
    if (a.newNumbering && !rar5 && a.isVolume) t.add('NewVolName');
    if (a.recovery) t.add('Recovery');
    if (a.encryptedHeaders) t.add('Encrypted');
    if (a.firstVolume) t.add('FirstVolume');
    return t.join(' ');
  }

  static String _hostOSName(RarItem it) {
    if (it.isRar5) {
      switch (it.hostOS) {
        case 0:
          return 'Windows';
        case 1:
          return 'Unix';
      }
      return '${it.hostOS}';
    }
    const names = ['MS DOS', 'OS/2', 'Win32', 'Unix', 'Mac OS', 'BeOS'];
    return it.hostOS < names.length ? names[it.hostOS] : '${it.hostOS}';
  }

  static int _dictBits(int dict) {
    var b = 0;
    while ((1 << (b + 1)) <= dict) {
      b++;
    }
    return b;
  }

  static String _method(RarItem it) {
    if (it.isDir) return 'm${it.method}';
    var s = 'm${it.method}:${_dictBits(it.dictSize)}';
    if (it.isRar5 && it.algoVersion != 0) s += ':v${it.algoVersion}';
    final c = it.crypt;
    if (c != null) s += ' AES:${c.kdfCount}:${c.flags}';
    return s;
  }

  static String _characts(RarItem it) {
    final t = <String>[];
    if (it.isDir) t.add('Dir');
    if (it.crc != null) t.add('CRC');
    if (it.blake2 != null) t.add('Hash');
    if (it.encrypted) t.add('Crypto');
    if (it.mTime != null || it.cTime != null || it.aTime != null) {
      final sb = StringBuffer('Time:');
      sb.write(it.unixTime ? 'u' : 'w');
      if (it.mTime != null) sb.write('M');
      if (it.cTime != null) sb.write('C');
      if (it.aTime != null) sb.write('A');
      if (it.unixTimeNs) sb.write('n');
      t.add(sb.toString());
    }
    const links = [
      '',
      'UnixSymLink',
      'WinSymLink',
      'WinJunction',
      'HardLink',
      'FileCopy'
    ];
    if (it.redirType != RarRedir.none) {
      t.add(it.redirType < links.length
          ? 'Link:${links[it.redirType]}'
          : 'Link:${it.redirType}');
    }
    if (it.user != null || it.group != null) t.add('UnixOwner');
    if (it.fileVersion >= 0) t.add('Version:${it.fileVersion}');
    return t.join(' ');
  }

  /// The attributes as 7-Zip shows them: Windows attributes, or the POSIX
  /// mode in the high 16 bits for Unix items.
  static int attribOf(RarItem it) {
    final mode = it.posixMode;
    if (mode == null) {
      return it.attrib | (it.isDir ? FileAttrib.directory : 0);
    }
    var m = mode;
    if (it.isSymLink && (m & 0xF000) == 0) m |= 0xA000;
    var v = (m << 16) | FileAttrib.unixExtension;
    if (it.isDir) v |= FileAttrib.directory;
    return v;
  }

  int _unpackSize(RarItem it) {
    if (it.isDir) return 0;
    if (it.isRar5 && it.isSymLink) {
      return utf8.encode(it.linkTarget ?? '').length;
    }
    return it.size;
  }

  // GetProperty
  Object? getProperty(int index, int propId) {
    if (index < 0 || index >= items.length) return null;
    final it = items[index];
    switch (propId) {
      case Kpid.path:
        // 7-Zip shows the older versions of -ver archives under [VER]
        if (it.fileVersion > 0) return '[VER]/${it.fileVersion}/${it.name}';
        return it.name;
      case Kpid.isDir:
        return it.isDir;
      case Kpid.size:
        return it.sizeUnknown ? null : _unpackSize(it);
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
        return it.encrypted;
      case Kpid.solid:
        return it.solid;
      case Kpid.commented:
        return it.commented;
      case Kpid.splitBefore:
        return it.splitBefore;
      case Kpid.splitAfter:
        return it.splitAfter;
      case Kpid.crc:
        if (it.isDir) return null;
        return it.crc;
      case Kpid.hostOS:
        return _hostOSName(it);
      case Kpid.method:
        return _method(it);
      case Kpid.unpackVer:
        return it.isRar5 ? null : it.algoVersion;
      case Kpid.characts:
        return _characts(it);
      case Kpid.symLink:
        return it.isSymLink ? it.linkTarget : null;
      case Kpid.hardLink:
        return it.redirType == RarRedir.hardLink ? it.linkTarget : null;
      case Kpid.copyLink:
        return it.redirType == RarRedir.fileCopy ? it.linkTarget : null;
      case Kpid.volumeIndex:
        final a = _a!;
        if (!a.isVolume || it.parts.isEmpty) return null;
        return (a.volumeNumber < 0 ? 0 : a.volumeNumber) +
            it.parts.first.volume;
      case Kpid.checksum:
        final b = it.blake2;
        if (b == null) return null;
        return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      case Kpid.user:
        return it.user;
      case Kpid.group:
        return it.group;
    }
    return null;
  }

  // the packed data of an item over its volumes
  InStream _packedStream(RarItem it) {
    final a = _a!;
    final parts = <InStream>[
      for (final p in it.parts)
        WindowInStream(a.volumes[p.volume], p.dataPos, p.packSize)
    ];
    return parts.length == 1 ? parts.first : ConcatInStream(parts);
  }

  // whether the item's data goes through the decoder (and so belongs to
  // the solid stream)
  static bool _isCompressed(RarItem it) =>
      !it.isDir &&
      it.method != 0 &&
      !(it.isRar5 && it.redirType != RarRedir.none && it.packSize == 0);

  /// IInArchive::Extract. [indices] null means all items.
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    final all = items;
    final ix = indices == null
        ? [for (var i = 0; i < all.length; i++) i]
        : (List<int>.of(indices)..sort());
    var total = 0;
    for (final i in ix) {
      total += _unpackSize(all[i]);
    }
    cb.setTotal(total);
    // the items that only have to be decoded to rebuild a solid state
    final needed = <int>{};
    final requested = ix.toSet();
    for (final i in ix) {
      if (!all[i].solid || !_isCompressed(all[i])) continue;
      if (_lastDecoded >= 0 && _lastDecoded < i && _chainOk(_lastDecoded, i)) {
        for (var j = _lastDecoded + 1; j < i; j++) {
          if (_isCompressed(all[j])) needed.add(j);
        }
        continue;
      }
      var j = i - 1;
      while (j >= 0) {
        final p = all[j];
        if (_isCompressed(p)) {
          needed.add(j);
          if (!p.solid) break;
        }
        j--;
      }
    }
    final order = {...ix, ...needed}.toList()..sort();
    var completed = 0;
    String? password;
    for (final index in order) {
      final it = all[index];
      if (!requested.contains(index)) {
        // decoded only for the solid state
        try {
          if (it.encrypted && it.isRar5) password ??= _dataPassword(cb);
          _decode(it, index, null, password);
        } on SevenZipException {
          _lastDecoded = -1;
        } on RangeError {
          _lastDecoded = -1;
        }
        continue;
      }
      cb.setCompleted(completed);
      var askMode = testMode ? AskMode.test : AskMode.extract;
      final out = cb.getStream(index, askMode);
      if (!testMode && out == null && !it.isDir) askMode = AskMode.skip;
      cb.prepareOperation(askMode);
      var opRes = OperationResult.ok;
      if (!it.isDir) {
        try {
          if (it.encrypted && it.isRar5) password ??= _dataPassword(cb);
          final base = completed;
          opRes = _extractItem(
              it, index, out, password, (n) => cb.setCompleted(base + n));
        } on SevenZipException catch (e) {
          opRes = _opResOf(e, it);
          _lastDecoded = -1;
        } on RangeError {
          // corrupt data that points outside of the decoder's tables
          opRes = OperationResult.dataError;
          _lastDecoded = -1;
        }
      }
      out?.flush();
      completed += _unpackSize(it);
      cb.setOperationResult(opRes);
    }
    cb.setCompleted(completed);
  }

  bool _chainOk(int from, int to) {
    final all = items;
    for (var j = from + 1; j <= to; j++) {
      if (_isCompressed(all[j]) && !all[j].solid) return false;
    }
    return true;
  }

  static int _opResOf(SevenZipException e, RarItem it) {
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
      case SevenZipError.unavailable:
        return OperationResult.unavailable;
      default:
        return OperationResult.dataError;
    }
  }

  String _dataPassword(ArchiveExtractCallback cb) {
    final a = _a!;
    if (a.password != null) return a.password!;
    if (cb is CryptoGetTextPassword) {
      final pw = (cb as CryptoGetTextPassword).cryptoGetTextPassword();
      a.password = pw;
      return pw;
    }
    throw const SevenZipException(
        'RAR: the item is encrypted and no password was given',
        SevenZipError.wrongPassword);
  }

  // the item of a file copy or hard link target
  RarItem? _linkTargetItem(RarItem it, int index) {
    final t = it.linkTarget;
    if (t == null) return null;
    for (var j = index - 1; j >= 0; j--) {
      final c = items[j];
      if (c.name == t && !c.isDir) return c;
    }
    return null;
  }

  int _extractItem(RarItem it, int index, OutStream? out, String? password,
      void Function(int) progress) {
    if (it.isRar5 && it.isSymLink) {
      final b = Uint8List.fromList(utf8.encode(it.linkTarget ?? ''));
      out?.write(b, 0, b.length);
      return OperationResult.ok;
    }
    if (it.splitBefore) {
      // the start of the data is in a volume before the opened one
      return OperationResult.unavailable;
    }
    if (!it.isRar5 && it.isSymLink) {
      // RAR4 Unix symbolic link: the target is the stored data
      final h = _HashOutStream(out, it, progress);
      final src = _packedStream(it);
      copyStream(src, h, limit: it.packSize);
      return OperationResult.ok;
    }
    if (it.isRar5 &&
        (it.redirType == RarRedir.fileCopy ||
            it.redirType == RarRedir.hardLink) &&
        it.packSize == 0) {
      final target = _linkTargetItem(it, index);
      if (target == null) return OperationResult.unavailable;
      if (target.solid && _isCompressed(target)) {
        // a solid target can not be decoded alone here
        return OperationResult.unavailable;
      }
      final h = _HashOutStream(out, target, progress);
      _decodeInto(target, h, password);
      return _checkResult(target, h, password);
    }
    final h = _HashOutStream(out, it, progress);
    _decode(it, index, h, password);
    return _checkResult(it, h, password);
  }

  int _checkResult(RarItem it, _HashOutStream h, String? password) {
    if (h.count != it.size && !it.sizeUnknown) {
      return OperationResult.dataError;
    }
    final keys = it.encrypted && it.isRar5 ? _fileKeys(it, password!) : null;
    final tweak = keys != null && it.crypt!.tweakedChecksums;
    if (it.crc != null) {
      var v = h.crc.value;
      if (tweak) v = keys.tweakCrc(v);
      if (v != it.crc) {
        return OperationResult.crcError;
      }
    }
    final b2 = it.blake2;
    if (b2 != null && h.blake != null) {
      var d = h.blake!.digest();
      if (tweak) d = keys.tweakHash(d);
      for (var i = 0; i < 32; i++) {
        if (d[i] != b2[i]) return OperationResult.crcError;
      }
    }
    return OperationResult.ok;
  }

  Rar5Keys _fileKeys(RarItem it, String password) {
    final c = it.crypt!;
    if (c.version != 0 || c.kdfCount > rar5MaxKdfCount) {
      throw const SevenZipException(
          'RAR5: unsupported encryption', SevenZipError.unsupportedMethod);
    }
    final keys = _a!.keysFor(password, c.salt, c.kdfCount);
    if (c.check != null && !rar5CheckPassword(keys, c.check!)) {
      throw const SevenZipException(
          'RAR5: wrong password', SevenZipError.wrongPassword);
    }
    return keys;
  }

  InStream _dataStream(RarItem it, String? password) {
    var src = _packedStream(it);
    if (it.encrypted) {
      if (!it.isRar5) {
        throw const SevenZipException('RAR 3.x encryption is not supported',
            SevenZipError.unsupportedMethod);
      }
      final keys = _fileKeys(it, password!);
      src = RarAesDecryptInStream(src, keys.key, it.crypt!.iv);
    }
    return src;
  }

  // decodes the data of [it] into [out] (null: only the solid state)
  void _decode(RarItem it, int index, OutStream? out, String? password) {
    if (!_isCompressed(it)) {
      if (out != null) _decodeInto(it, out, password);
      return;
    }
    if (it.solid && _lastDecoded < 0 && _hasCompressedBefore(index)) {
      throw const SevenZipException(
          'RAR: the solid stream state is missing', SevenZipError.data);
    }
    _lastDecoded = -1;
    _decodeInto(it, out ?? NullOutStream(), password);
    _lastDecoded = index;
  }

  bool _hasCompressedBefore(int index) {
    for (var j = index - 1; j >= 0; j--) {
      if (_isCompressed(items[j])) return true;
    }
    return false;
  }

  void _decodeInto(RarItem it, OutStream out, String? password) {
    final src = _dataStream(it, password);
    if (it.method == 0) {
      final n = copyStream(src, out, limit: it.size);
      if (n != it.size) {
        throw const SevenZipException(
            'RAR: unexpected end of data', SevenZipError.unexpectedEnd);
      }
      return;
    }
    if (it.isRar5) {
      if (it.algoVersion != 0) {
        throw const SevenZipException(
            'RAR5: compression algorithm version 1 (RAR 7) is not supported',
            SevenZipError.unsupportedMethod);
      }
      if (it.method > 5) {
        throw const SevenZipException(
            'RAR5: unsupported method', SevenZipError.unsupportedMethod);
      }
      final dec = _dec5 ??= Rar5Decoder();
      final win = Rar5Decoder.windowSizeFor(
          _solidDict(it), it.size, _a!.solid || it.solid);
      if (win > _maxWindow) {
        throw SevenZipException(
            'RAR5: the dictionary of ${win >> 20} MiB is too large',
            SevenZipError.unsupportedMethod);
      }
      dec.decodeFile(src, out, it.size, win, it.solid);
    } else {
      final dec = _dec3 ??= Rar3Decoder();
      dec.decodeFile(src, out, it.size, it.algoVersion, it.dictSize, it.solid);
    }
  }

  // the largest dictionary of the solid stream of [it]
  int _solidDict(RarItem it) {
    if (!_a!.solid && !it.solid) return it.dictSize;
    var d = it.dictSize;
    for (final x in items) {
      if (_isCompressed(x) && x.dictSize > d) d = x.dictSize;
    }
    return d;
  }

  /// Decodes item [index] into memory (for the update of solid archives).
  Uint8List decodeItem(int index) {
    final cb = _MemoryExtract();
    extract([index], false, cb);
    if (cb.result != OperationResult.ok) {
      throw SevenZipException(
          'RAR: the kept item ${items[index].name} can not be decoded',
          cb.result == OperationResult.wrongPassword
              ? SevenZipError.wrongPassword
              : SevenZipError.data);
    }
    return cb.out.toBytes();
  }

  // IOutArchive

  /// Both formats write RAR5 archives: the Rar format only creates new
  /// ones (a RAR 4.x archive can not be updated).
  bool get supportsUpdate => true;

  int getFileTimeType() => FileTimeType.windows;

  /// ISetProperties::SetProperties (see [Rar5WriteOptions.set]).
  void setProperties(List<MapEntry<String, PropVariant>> props) =>
      writeOptions.set(props);

  /// IOutArchive::UpdateItems: writes a RAR5 archive to [out].
  void updateItems(OutStream out, int numItems, ArchiveUpdateCallback cb) {
    if (!rar5) {
      for (var i = 0; i < numItems; i++) {
        if (cb.getUpdateItemInfo(i).indexInArchive >= 0) {
          throw const SevenZipException(
              'RAR 4.x archives can not be updated (only new RAR5 '
              'archives can be written)',
              SevenZipError.unsupported);
        }
      }
      Rar5Writer(out, writeOptions, null, null).update(numItems, cb);
      return;
    }
    Rar5Writer(out, writeOptions, _a, this).update(numItems, cb);
  }
}

/// Collects the data of one item.
final class _MemoryExtract extends ArchiveExtractCallback {
  final MemoryOutStream out = MemoryOutStream();
  int result = OperationResult.ok;
  @override
  OutStream? getStream(int index, int askMode) => out;
  @override
  void setOperationResult(int opRes) => result = opRes;
}

/// Counts, hashes and forwards the unpacked data.
final class _HashOutStream implements OutStream {
  final OutStream? base;
  final Crc32 crc = Crc32();
  final Blake2sp? blake;
  final void Function(int) progress;
  int count = 0;
  int _lastReport = 0;

  _HashOutStream(this.base, RarItem it, this.progress)
      : blake = it.blake2 != null ? Blake2sp() : null;

  @override
  void write(Uint8List buf, int off, int len) {
    if (len <= 0) return;
    crc.update(buf, off, off + len);
    blake?.update(buf, off, len);
    base?.write(buf, off, len);
    count += len;
    if (count - _lastReport >= (1 << 20)) {
      _lastReport = count;
      progress(count);
    }
  }

  @override
  void flush() => base?.flush();
}
