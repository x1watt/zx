// Writing RAR5 archives (IOutArchive::UpdateItems of the Rar5 format),
// from the RAR 5.0 archive format technote
// (https://www.rarlab.com/technote.htm): the signature, the main, file,
// service and end of archive headers with their extra records (file
// encryption, hash, time, redirection), the archive encryption header and
// the encrypted headers. The data is compressed by rar5_encoder.dart.
//
// Headers are written before their data with fixed size fields (the data
// size is a vint padded to 8 bytes, as the technote allows) and rewritten
// in place when the data is complete; an output that can not seek gets
// the packed data of each file buffered in memory instead.
//
// Kept items of a non solid archive are copied with their packed data;
// kept items whose data is part of a solid stream are decoded and
// compressed again.
//
// Volumes: when the output is a MultiOutStream (the -v switch), each
// volume starts with the signature, the encryption header of encrypted
// headers and a main header with the volume flags and number, and ends
// with an end of archive header whose flag says that the archive
// continues. The data of a file that does not fit is split into parts,
// each with a copy of the file header flagged "split before" or "split
// after"; the checksum of a part that is not the last one is the CRC32 (or
// BLAKE2sp) of its packed data, the last part has the checksum of the
// whole file (technote, "Data CRC32" and the hash record). A volume is
// padded with zeros after its end header up to the volume size, as rar
// does, so that every volume but the last has the requested size. A set
// that ends in one volume gets the flags of a plain archive.
//
// The -m properties (SetProperties):
//   x=0..9     level: 0 store, 1 method 1 (fastest), 2..3 method 2,
//              4..5 method 3 (default), 6..7 method 4, 8..9 method 5
//   d=<size>   dictionary size (128k to 1g, rounded up to a power of two);
//              the default depends on the level (1m to 16m) and is
//              reduced to the size of the input
//   s=on|off   solid archive (off by default)
//   he=on|off  encrypt the headers too (with a password, like rar -hp)
//   crc=crc32|blake2   the file checksum (CRC32 by default)
//   tm, tc, ta store the modification (default), creation, access times
//   rr=<n>[%]  add a recovery record of n percent (1 to 1000; "rr" alone
//              is 3%, as rar -rr), to each volume with -v (see
//              rar5_recovery.dart); the archive is read back to compute it
//   algo=0|1   compression algorithm version of the file headers: 0
//              (default, RAR 5.0 and later) or 1 (the RAR 7.0 format,
//              extracted by RAR 7.0 and later only; this writer uses the
//              same dictionaries, up to 1 GB, in both)
//   mt, memuse accepted and ignored

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../codec/rar/rar5_encoder.dart';
import '../../common/method_props.dart';
import '../../crypto/blake2sp.dart';
import '../../crypto/rar5_kdf.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../handler_out.dart';
import '../split.dart';
import 'rar5_in.dart';
import 'rar5_recovery.dart';
import 'rar_archive.dart';
import 'rar_crypto.dart';
import 'rar_handler.dart';
import 'rar_item.dart';

/// The KDF count (binary logarithm of the PBKDF2 iterations) of new
/// encrypted archives, as rar uses by default.
const int rar5WriteKdfCount = 15;

/// Options of new RAR5 archives, set with the -m switches.
final class Rar5WriteOptions {
  int level = 5;
  int? dictSize;
  bool solid = false;
  bool encryptHeaders = false;
  bool blake2 = false;

  /// The compression algorithm version (0, or 1 for RAR 7.0).
  int algoVersion = 0;

  /// The size of the recovery record in percent (0: none).
  int recoveryPercent = 0;

  /// Not a rar switch: the archive comment to write instead of the one of
  /// the old archive (an empty string removes it). Null keeps the old one.
  String? newComment;
  final HandlerTimeOptions timeOptions = HandlerTimeOptions();

  /// The RAR compression method of the level (0 store ... 5 best).
  int get method {
    if (level <= 0) return 0;
    if (level == 1) return 1;
    if (level <= 3) return 2;
    if (level <= 5) return 3;
    if (level <= 7) return 4;
    return 5;
  }

  int get defaultDict {
    switch (method) {
      case 1:
        return 1 << 20;
      case 2:
        return 2 << 20;
      case 3:
        return 4 << 20;
      case 4:
        return 8 << 20;
      default:
        return 16 << 20;
    }
  }

  /// ISetProperties::SetProperties.
  void set(List<MapEntry<String, PropVariant>> props) {
    level = 5;
    dictSize = null;
    solid = false;
    encryptHeaders = false;
    blake2 = false;
    algoVersion = 0;
    recoveryPercent = 0;
    timeOptions.init();
    for (final p in props) {
      final name = p.key.toLowerCase();
      final value = p.value;
      if (name.isEmpty) invalidArg();
      if (name.startsWith('x')) {
        level = parsePropToUInt32(name.substring(1), value, 5);
        if (level > 9) invalidArg('Bad level');
        continue;
      }
      if (name == 'd' || (name.startsWith('d') && _isDigits(name, 1))) {
        final mp = MethodProps();
        if (name == 'd') {
          mp.parseParamsFromPropVariant('d', value);
        } else {
          mp.setParam('d', name.substring(1));
        }
        dictSize = mp.props.single.value.intValue;
        continue;
      }
      if (name == 's') {
        solid = _bool(value);
        continue;
      }
      if (name == 'he') {
        encryptHeaders = _bool(value);
        continue;
      }
      if (name == 'crc') {
        if (value.vt != VarType.bstr) invalidArg();
        switch (value.stringValue.toLowerCase()) {
          case 'blake2':
          case 'blake2sp':
            blake2 = true;
          case 'crc32':
          case 'crc':
            blake2 = false;
          default:
            invalidArg('Unsupported checksum: ${value.stringValue}');
        }
        continue;
      }
      if (name == 'rr') {
        recoveryPercent = _percent(value);
        continue;
      }
      if (name == 'algo') {
        algoVersion = parsePropToUInt32('', value, 0);
        if (algoVersion > 1) invalidArg('Bad algorithm version');
        continue;
      }
      if (timeOptions.parse(name, value)) continue;
      if (name.startsWith('mt') || name.startsWith('memuse')) continue;
      invalidArg('Unsupported property: ${p.key}');
    }
  }

  static int _percent(PropVariant v) {
    int n;
    if (v.vt == VarType.ui4) {
      n = v.intValue;
    } else if (v.vt == VarType.bstr) {
      var t = v.stringValue.trim();
      if (t.endsWith('%')) t = t.substring(0, t.length - 1);
      if (t.isEmpty) return 3;
      final p = int.tryParse(t);
      if (p == null) invalidArg('Bad recovery record size');
      n = p;
    } else if (v.vt == VarType.empty) {
      return 3;
    } else {
      invalidArg('Bad recovery record size');
    }
    if (n < 0 || n > 1000) invalidArg('Bad recovery record size');
    return n;
  }

  static bool _isDigits(String s, int from) {
    if (from >= s.length) return false;
    for (var i = from; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return false;
    }
    return true;
  }

  static bool _bool(PropVariant v) {
    if (v.vt == VarType.ui4) return v.intValue != 0;
    return propVariantToBool(v);
  }
}

/// Builds a header body (from the header type to the end of the extra
/// area).
final class _Body {
  final BytesBuilder b = BytesBuilder(copy: false);
  void vint(int v) => writeVint(b, v);
  void vintFixed(int v, int n) {
    for (var i = 0; i < n - 1; i++) {
      b.addByte(((v >> (7 * i)) & 0x7F) | 0x80);
    }
    b.addByte((v >> (7 * (n - 1))) & 0x7F);
  }

  void u32(int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 24) & 0xFF);
  }

  void u64(int v) {
    u32(v & 0xFFFFFFFF);
    u32((v >> 32) & 0xFFFFFFFF);
  }

  void bytes(List<int> x) => b.add(x);
  Uint8List take() => b.takeBytes();
}

/// The fields of a file or service header.
final class _FileHeader {
  int type = Rar5HeaderType.file;
  String name = '';
  bool isDir = false;
  int unpSize = 0;
  int attrib = 0;
  int hostOS = 1;
  int compInfo = 0;
  int? mTimeUnix; // file flag 0x0002
  int? crc;
  bool splitBefore = false;
  bool splitAfter = false;
  int dataSize = 0;
  bool hasData = false;

  // extra records
  int? mTime;
  int? cTime;
  int? aTime;
  Uint8List? blake2;
  Rar5CryptInfo? crypt;
  String? symlink;
  int redirType = RarRedir.none;
  int redirFlags = 0;

  /// Service data record (EXTRA type 7), and the "skip if unknown" flag.
  Uint8List? subdata;
  bool skipIfUnknown = false;

  /// Extra area kept from an old header (for copied items), with the hash
  /// record replaced by [blake2] when that is set.
  Uint8List? keptExtra;

  Uint8List extraArea() {
    final kept = keptExtra;
    if (kept != null) return _rewriteKeptExtra(kept);
    final e = _Body();
    final c = crypt;
    if (c != null) {
      final r = _Body();
      r.vint(Rar5Extra.crypt);
      r.vint(c.version);
      r.vint(c.flags);
      r.bytes([c.kdfCount]);
      r.bytes(c.salt);
      r.bytes(c.iv);
      if (c.check != null) r.bytes(c.check!);
      _record(e, r.take());
    }
    final b2 = blake2;
    if (b2 != null) {
      final r = _Body();
      r.vint(Rar5Extra.hash);
      r.vint(0);
      r.bytes(b2);
      _record(e, r.take());
    }
    if (mTime != null || cTime != null || aTime != null) {
      final r = _Body();
      r.vint(Rar5Extra.htime);
      var f = 0;
      if (mTime != null) f |= 2;
      if (cTime != null) f |= 4;
      if (aTime != null) f |= 8;
      r.vint(f);
      if (mTime != null) r.u64(mTime!);
      if (cTime != null) r.u64(cTime!);
      if (aTime != null) r.u64(aTime!);
      _record(e, r.take());
    }
    final t = symlink;
    if (t != null) {
      final r = _Body();
      r.vint(Rar5Extra.redir);
      r.vint(redirType);
      r.vint(redirFlags);
      final nb = utf8.encode(t);
      r.vint(nb.length);
      r.bytes(nb);
      _record(e, r.take());
    }
    final sd = subdata;
    if (sd != null) {
      final r = _Body();
      r.vint(Rar5Extra.subdata);
      r.bytes(sd);
      _record(e, r.take());
    }
    return e.take();
  }

  static void _record(_Body e, Uint8List data) {
    e.vint(data.length);
    e.bytes(data);
  }

  Uint8List _rewriteKeptExtra(Uint8List kept) {
    final b2 = blake2;
    if (b2 == null) return kept;
    final e = _Body();
    var p = 0;
    while (p < kept.length) {
      final r = RarHeaderReader(kept, p, kept.length);
      final size = r.vint();
      final start = r.pos;
      final end = start + size;
      final type = RarHeaderReader(kept, start, end).vint();
      if (type == Rar5Extra.hash) {
        final h = _Body();
        h.vint(Rar5Extra.hash);
        h.vint(0);
        h.bytes(b2);
        _record(e, h.take());
      } else {
        e.vint(size);
        e.bytes(Uint8List.sublistView(kept, start, end));
      }
      p = end;
    }
    return e.take();
  }

  /// The header body; the data size is a vint of 8 bytes so that it can be
  /// rewritten in place.
  Uint8List body() {
    final extra = extraArea();
    final h = _Body();
    h.vint(type);
    var flags = 0;
    if (extra.isNotEmpty) flags |= Rar5HeaderFlags.extra;
    if (hasData) flags |= Rar5HeaderFlags.data;
    if (splitBefore) flags |= Rar5HeaderFlags.splitBefore;
    if (splitAfter) flags |= Rar5HeaderFlags.splitAfter;
    if (skipIfUnknown) flags |= Rar5HeaderFlags.skipIfUnknown;
    h.vint(flags);
    if (extra.isNotEmpty) h.vint(extra.length);
    if (hasData) h.vintFixed(dataSize, 8);
    var fileFlags = 0;
    if (isDir) fileFlags |= 1;
    if (mTimeUnix != null) fileFlags |= 2;
    if (crc != null) fileFlags |= 4;
    h.vint(fileFlags);
    h.vint(unpSize);
    h.vint(attrib);
    if (mTimeUnix != null) h.u32(mTimeUnix!);
    if (crc != null) h.u32(crc!);
    h.vint(compInfo);
    h.vint(hostOS);
    final nb = utf8.encode(name);
    h.vint(nb.length);
    h.bytes(nb);
    h.bytes(extra);
    return h.take();
  }
}

/// Reads exactly [size] bytes of [base] (zeros after its end), hashing
/// them.
final class _HashingInStream implements InStream {
  final InStream base;
  int left;
  final Crc32 crc = Crc32();
  final Blake2sp? blake;
  bool short = false;
  _HashingInStream(this.base, int size, bool blake2)
      : left = size,
        blake = blake2 ? Blake2sp() : null;

  @override
  int read(Uint8List buf, int off, int len) {
    if (left <= 0) return 0;
    if (len > left) len = left;
    var n = short ? 0 : base.read(buf, off, len);
    if (n == 0) {
      short = true;
      buf.fillRange(off, off + len, 0);
      n = len;
    }
    crc.update(buf, off, off + n);
    blake?.update(buf, off, n);
    left -= n;
    return n;
  }
}

/// Concatenates the streams of the files of a solid run, opening each one
/// when it is first read.
final class _SolidFeed implements InStream {
  final List<_HashingInStream Function()> openers;
  final List<_HashingInStream?> streams;
  int _cur = 0;
  _SolidFeed(this.openers) : streams = List.filled(openers.length, null);

  _HashingInStream stream(int i) => streams[i] ??= openers[i]();

  @override
  int read(Uint8List buf, int off, int len) {
    while (_cur < openers.length) {
      final n = stream(_cur).read(buf, off, len);
      if (n > 0) return n;
      _cur++;
    }
    return 0;
  }
}

/// Counts the bytes written to [base].
final class _CountOut implements OutStream {
  final OutStream base;
  int count = 0;
  _CountOut(this.base);
  @override
  void write(Uint8List buf, int off, int len) {
    base.write(buf, off, len);
    count += len;
  }

  @override
  void flush() => base.flush();
}

/// The packed data of a file: counts it and, with volumes, splits it
/// into parts at the end of each volume ([room] gives the bytes left in
/// the volume, [split] ends the part and starts the next volume). The
/// checksum of each part is kept for its header.
final class _PartOut implements OutStream {
  final OutStream base;
  final bool blake2;
  int count = 0;
  int partCount = 0;
  Crc32 partCrc = Crc32();
  Blake2sp? partBlake;
  int Function()? room;
  void Function()? split;

  _PartOut(this.base, this.blake2) : partBlake = blake2 ? Blake2sp() : null;

  @override
  void write(Uint8List buf, int off, int len) {
    final room = this.room;
    if (room == null) {
      base.write(buf, off, len);
      count += len;
      return;
    }
    while (len > 0) {
      var n = room();
      if (n <= 0) {
        split!();
        partCount = 0;
        partCrc = Crc32();
        partBlake = blake2 ? Blake2sp() : null;
        continue;
      }
      if (n > len) n = len;
      base.write(buf, off, n);
      partCrc.update(buf, off, off + n);
      partBlake?.update(buf, off, n);
      count += n;
      partCount += n;
      off += n;
      len -= n;
    }
  }

  @override
  void flush() => base.flush();
}

/// A new item as the update callback describes it.
final class _NewItem {
  final int index;
  String name = '';
  bool isDir = false;
  int size = 0;
  int attrib = 0;
  int hostOS = 1;
  int? mTime;
  int? cTime;
  int? aTime;
  bool isSymLinkByMode = false;
  String? symLink;
  _NewItem(this.index);
}

/// Writes a RAR5 archive.
final class Rar5Writer {
  final OutStream _out0;
  final Rar5WriteOptions opt;
  final RarArchiveData? old;
  final RarHandler? oldHandler;

  late final _CountOut _out = _CountOut(_out0);
  final Random _rnd = Random.secure();

  Rar5Keys? _keys;
  Uint8List? _salt;
  Uint8List? _check;
  bool _encryptHeaders = false;
  Rar5Keys? _headerKeys;

  Rar5Encoder? _encoder;

  // volumes (null sizes: one archive)
  List<int>? _volSizes;
  int _vol = 0;
  int _volStart = 0; // absolute start of the current volume
  int _volLimit = 0; // absolute end of the current volume
  int _endSize = 0; // size of the end of archive header
  int _tailSize = 0; // what a volume keeps after its files
  bool _startingVolume = false;
  int _mainPos = 0;
  int _mainSize = 0;

  Rar5Writer(this._out0, this.opt, this.old, [this.oldHandler]);

  int _volSize(int i) {
    final v = _volSizes!;
    return v[i < v.length ? i : v.length - 1];
  }

  Uint8List _random(int n) {
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = _rnd.nextInt(256);
    }
    return b;
  }

  /// IOutArchive::UpdateItems.
  void update(int numItems, ArchiveUpdateCallback cb) {
    final infos = <UpdateItemInfo>[];
    var total = 0;
    for (var i = 0; i < numItems; i++) {
      final info = cb.getUpdateItemInfo(i);
      infos.add(info);
      if (info.indexInArchive >= 0 &&
          (old == null || info.indexInArchive >= old!.items.length)) {
        invalidArg('Bad index in archive');
      }
      if (info.newData) {
        final s = cb.getProperty(i, Kpid.size);
        if (s is int) total += s;
      } else if (info.indexInArchive >= 0) {
        total += old!.items[info.indexInArchive].packSize;
      }
    }
    cb.setTotal(total);

    // the password for new data
    String? password;
    if (cb is CryptoGetTextPassword2) {
      password = (cb as CryptoGetTextPassword2).cryptoGetTextPassword2();
      if (password != null && password.isEmpty) password = null;
    }
    if (password != null) {
      _salt = _random(16);
      _keys = Rar5Keys.derive(password, _salt!, rar5WriteKdfCount);
      final c = Uint8List(12);
      c.setRange(0, 8, _keys!.pswCheck);
      c.setRange(8, 12, Rar5Keys.checkSum(_keys!.pswCheck));
      _check = c;
      _encryptHeaders = opt.encryptHeaders;
    }

    final out0 = _out0;
    if (out0 is MultiOutStream && out0.volumeSizes.isNotEmpty) {
      _volSizes = out0.volumeSizes;
      _volLimit = _volSize(0);
    }
    if (opt.recoveryPercent > 0 && _out0 is! ReadBackOutStream) {
      throw const SevenZipException(
          'RAR5: the recovery record needs an output that can be read back',
          SevenZipError.unsupported);
    }
    _writeVolumeStart();
    _endSize = _headerBytes(_endBody(false)).length;
    _tailSize = _volSizes != null ? _tailFor(_volSize(0)) : _endSize;
    final comment = opt.newComment ?? old?.comment;
    if (comment != null && comment.isNotEmpty) _writeComment(comment);

    var completed = 0;
    final opCb = cb is ArchiveUpdateCallbackFile
        ? cb as ArchiveUpdateCallbackFile
        : null;
    var i = 0;
    while (i < numItems) {
      cb.setCompleted(completed);
      final info = infos[i];
      if (!info.newData) {
        if (_volSizes != null) {
          throw const SevenZipException(
              'RAR5: updating multivolume archives is not supported',
              SevenZipError.unsupported);
        }
        final it = old!.items[info.indexInArchive];
        if (it.splitBefore || it.splitAfter) {
          throw SevenZipException(
              'RAR5: ${it.name} continues in a volume that is missing',
              SevenZipError.unexpectedEnd);
        }
        opCb?.reportOperation(EventIndexType.inArcIndex, info.indexInArchive,
            UpdateNotifyOp.replicate);
        String? newName;
        if (info.newProps) {
          final p = cb.getProperty(i, Kpid.path);
          if (p is String) newName = p.replaceAll('\\', '/');
        }
        if (it.solid && it.method != 0 && !it.isDir) {
          _recompressKept(it, info.indexInArchive, newName);
        } else {
          _copyKept(it, newName);
        }
        completed += it.packSize;
        i++;
        continue;
      }
      final ni = _newItem(cb, i);
      if (ni == null) {
        i++;
        continue;
      }
      if (ni.isDir) {
        opCb?.reportOperation(
            EventIndexType.outArcIndex, i, UpdateNotifyOp.add);
        _writeDir(ni);
        i++;
        continue;
      }
      if (ni.isSymLinkByMode || ni.symLink != null) {
        final ok = _writeSymlink(cb, ni);
        if (ok) cb.setOperationResult(0);
        i++;
        continue;
      }
      // a run of new regular files (one file unless solid)
      final run = <_NewItem>[ni];
      if (opt.solid && opt.method != 0) {
        var j = i + 1;
        while (j < numItems && infos[j].newData) {
          final nj = _peekRegular(cb, j);
          if (nj == null) break;
          run.add(nj);
          j++;
        }
      }
      completed = _writeFiles(cb, run, completed);
      i = run.last.index + 1;
    }
    // end of archive
    if (_volSizes != null && _vol == 0) {
      // a single volume: the flags of a plain archive
      _rewriteHeader(_mainPos, _mainSize, _mainBody(volume: false));
    }
    _writeRecovery();
    _writeHeader(_endBody(false), end: true);
    _encoder?.free();
    _out.flush();
    cb.setCompleted(completed);
  }

  // the signature, the encryption header and the main header of a volume
  void _writeVolumeStart() {
    _startingVolume = true;
    _out.write(Uint8List.fromList(rar5Signature), 0, 8);
    _headerKeys = null;
    if (_encryptHeaders) {
      final h = _Body();
      h.vint(Rar5HeaderType.crypt);
      h.vint(0);
      h.vint(0); // version
      h.vint(1); // password check present
      h.bytes([rar5WriteKdfCount]);
      h.bytes(_salt!);
      h.bytes(_check!);
      _writeHeader(h.take(), plain: true);
      _headerKeys = _keys;
    }
    final (pos, size) = _writeHeader(_mainBody());
    if (_vol == 0) {
      _mainPos = pos;
      _mainSize = size;
    }
    _startingVolume = false;
  }

  Uint8List _mainBody({bool volume = true}) {
    final h = _Body();
    h.vint(Rar5HeaderType.main);
    h.vint(0);
    var flags = opt.solid ? 4 : 0;
    if (volume && _volSizes != null) flags |= 1;
    if (opt.recoveryPercent > 0) flags |= 8;
    if (_vol > 0) flags |= 2;
    h.vint(flags);
    if (_vol > 0) h.vint(_vol);
    return h.take();
  }

  static Uint8List _endBody(bool more) {
    final h = _Body();
    h.vint(Rar5HeaderType.endArc);
    h.vint(Rar5HeaderFlags.skipIfUnknown);
    h.vint(more ? 1 : 0);
    return h.take();
  }

  // the room a volume of [volSize] bytes keeps for its recovery record
  // and end header
  int _tailFor(int volSize) {
    final pct = opt.recoveryPercent;
    if (pct <= 0) return _endSize;
    final rr = Rar5RecoveryLayout.maxSize(volSize, pct);
    return _headerBytes(_rrHeader(rr, pct).body()).length + rr + _endSize;
  }

  _FileHeader _rrHeader(int size, int pct) {
    final sd = BytesBuilder();
    writeVint(sd, pct);
    return _FileHeader()
      ..type = Rar5HeaderType.service
      ..name = 'RR'
      ..hostOS = 1
      ..unpSize = size
      ..hasData = true
      ..dataSize = size
      ..skipIfUnknown = true
      ..subdata = sd.takeBytes();
  }

  // the recovery record of the archive or of the current volume, from
  // its start to here
  void _writeRecovery() {
    final pct = opt.recoveryPercent;
    if (pct <= 0) return;
    final rb = _out0 as ReadBackOutStream;
    final start = _volStart;
    final l = Rar5RecoveryLayout(_out.count - start, pct);
    final data = rar5BuildRecovery(l, (pos, buf, off, len) {
      if (rb.readBack(start + pos, buf, off, len) != len) {
        throw const SevenZipException(
            'RAR5: can not read the archive back', SevenZipError.io);
      }
    });
    _writeHeader(_rrHeader(data.length, pct).body(), end: true);
    _out.write(data, 0, data.length);
  }

  // ends the current volume and starts the next one
  void _nextVolume() {
    _writeRecovery();
    _writeHeader(_endBody(true), end: true);
    final pad = _volLimit - _out.count;
    if (pad < 0) {
      throw const SevenZipException(
          'RAR5: volume overflow', SevenZipError.unsupported);
    }
    if (pad > 0) _out.write(Uint8List(pad), 0, pad);
    _vol++;
    _volStart = _volLimit;
    _volLimit += _volSize(_vol);
    _tailSize = _tailFor(_volSize(_vol));
    _writeVolumeStart();
  }

  /// The bytes of file data that still fit in the current volume.
  int _dataRoom() => _volLimit - _tailSize - _out.count;

  // a new regular file that can join a solid run, or null
  _NewItem? _peekRegular(ArchiveUpdateCallback cb, int i) {
    final ni = _newItem(cb, i);
    if (ni == null || ni.isDir || ni.isSymLinkByMode || ni.symLink != null) {
      return null;
    }
    return ni;
  }

  _NewItem? _newItem(ArchiveUpdateCallback cb, int i) {
    if (cb.getProperty(i, Kpid.isAnti) == true) return null;
    final path = cb.getProperty(i, Kpid.path);
    if (path is! String) invalidArg('Bad path property');
    final ni = _NewItem(i);
    ni.name = path.replaceAll('\\', '/');
    final d = cb.getProperty(i, Kpid.isDir);
    ni.isDir = d == true;
    final s = cb.getProperty(i, Kpid.size);
    if (s is int && !ni.isDir) ni.size = s;
    int? posix;
    final pa = cb.getProperty(i, Kpid.posixAttrib);
    if (pa is int) posix = pa & 0xFFFF;
    final a = cb.getProperty(i, Kpid.attrib);
    if (posix == null && a is int && (a & FileAttrib.unixExtension) != 0) {
      posix = (a >> 16) & 0xFFFF;
    }
    if (posix != null) {
      ni.hostOS = 1;
      if ((posix & 0xF000) == 0) posix |= ni.isDir ? 0x4000 : 0x8000;
      ni.attrib = posix;
      if ((posix & 0xF000) == 0xA000) ni.isSymLinkByMode = true;
    } else {
      ni.hostOS = 0;
      var w = a is int ? a & 0xFFFF & ~FileAttrib.unixExtension : 0;
      if (ni.isDir) w |= FileAttrib.directory;
      if (!ni.isDir && w == 0) w = FileAttrib.archive;
      ni.attrib = w;
    }
    final sl = cb.getProperty(i, Kpid.symLink);
    if (sl is String && sl.isNotEmpty && !ni.isDir) ni.symLink = sl;
    final to = opt.timeOptions;
    final m = cb.getProperty(i, Kpid.mTime);
    if (m is int && (!to.writeMTime.def || to.writeMTime.val)) ni.mTime = m;
    final c = cb.getProperty(i, Kpid.cTime);
    if (c is int && to.writeCTime.def && to.writeCTime.val) ni.cTime = c;
    final at = cb.getProperty(i, Kpid.aTime);
    if (at is int && to.writeATime.def && to.writeATime.val) ni.aTime = at;
    return ni;
  }

  // writes a header: plain, or as IV + encrypted padded header
  // (returns the position and the size it took). With volumes a header
  // that does not fit in the current volume, with [minData] bytes of its
  // data and the end header, goes to the next volume.
  (int, int) _writeHeader(Uint8List body,
      {bool plain = false, int minData = 0, bool end = false}) {
    var bytes = _headerBytes(body, plain: plain);
    if (_volSizes != null && !end) {
      final need = bytes.length + minData + _tailSize;
      if (!_startingVolume && _out.count + need > _volLimit) {
        _nextVolume();
        // the encryption keys of the new volume
        bytes = _headerBytes(body, plain: plain);
      }
      if (_out.count + need > _volLimit) {
        throw const SevenZipException(
            'RAR5: the volume size is too small', SevenZipError.unsupported);
      }
    }
    final pos = _out.count;
    _out.write(bytes, 0, bytes.length);
    return (pos, bytes.length);
  }

  Uint8List _headerBytes(Uint8List body, {bool plain = false, Uint8List? iv}) {
    final sizeLen = vintSize(body.length);
    final total = 4 + sizeLen + body.length;
    final keys = _headerKeys;
    final enc = !plain && keys != null;
    final padded = enc ? (total + 15) & ~15 : total;
    final b = Uint8List(padded);
    final bb = BytesBuilder();
    writeVint(bb, body.length);
    b.setRange(4, 4 + sizeLen, bb.takeBytes());
    b.setRange(4 + sizeLen, total, body);
    setUint32LE(b, 0, Crc32.of(b, 4, total));
    if (!enc) return b;
    final v = iv ?? _random(16);
    rarAesEncrypt(keys.key, v, b, 0, padded);
    final r = Uint8List(16 + padded);
    r.setRange(0, 16, v);
    r.setRange(16, 16 + padded, b);
    return r;
  }

  // rewrites the header at [pos] (same size) when the output can seek
  void _rewriteHeader(int pos, int size, Uint8List body) {
    final out = _out0 as SeekableOutStream;
    final keep = out.position;
    Uint8List? iv;
    if (_headerKeys != null) {
      // keep the IV so that the size does not change
      iv = _random(16);
    }
    final bytes = _headerBytes(body, iv: iv);
    if (bytes.length != size) {
      throw const SevenZipException(
          'RAR5: header size changed', SevenZipError.unsupported);
    }
    out.position = pos;
    out.write(bytes, 0, bytes.length);
    out.position = keep;
  }

  Rar5CryptInfo _newCrypt() {
    final c = Rar5CryptInfo();
    c.version = 0;
    c.flags = 3; // password check, tweaked checksums
    c.kdfCount = rar5WriteKdfCount;
    c.salt.setAll(0, _salt!);
    c.iv.setAll(0, _random(16));
    c.check = _check;
    return c;
  }

  void _writeDir(_NewItem ni) {
    final h = _FileHeader()
      ..name = ni.name
      ..isDir = true
      ..attrib = ni.attrib
      ..hostOS = ni.hostOS
      ..mTime = ni.mTime
      ..cTime = ni.cTime
      ..aTime = ni.aTime;
    _writeHeader(h.body());
  }

  bool _writeSymlink(ArchiveUpdateCallback cb, _NewItem ni) {
    var target = ni.symLink;
    if (target == null) {
      final s = cb.getStream(ni.index);
      if (s == null) return false;
      try {
        target = utf8.decode(readAll(s), allowMalformed: true);
      } finally {
        releaseStream(s);
      }
    }
    final h = _FileHeader()
      ..name = ni.name
      ..attrib = ni.hostOS == 1 ? (ni.attrib & 0xFFF) | 0xA000 : ni.attrib
      ..hostOS = ni.hostOS
      ..unpSize = utf8.encode(target).length
      ..crc = 0
      ..hasData = true
      ..dataSize = 0
      ..mTime = ni.mTime
      ..cTime = ni.cTime
      ..aTime = ni.aTime
      ..symlink = target
      ..redirType = ni.hostOS == 1 ? RarRedir.unixSymlink : RarRedir.winSymlink;
    _writeHeader(h.body());
    return true;
  }

  // the dictionary for [size] bytes of input
  int _dictFor(int size) {
    var want = opt.dictSize ?? opt.defaultDict;
    if (want < 0x20000) want = 0x20000;
    if (want > (1 << 30)) want = 1 << 30;
    var d = 0x20000;
    while (d < want) {
      d <<= 1;
    }
    // reduced to the input, as rar does
    var r = 0x20000;
    while (r < size && r < d) {
      r <<= 1;
    }
    return r < d ? r : d;
  }

  static int _dictBits(int dict) {
    var n = 0;
    while ((0x20000 << n) < dict) {
      n++;
    }
    return n;
  }

  // writes the files of [run] (a solid run, or one file)
  int _writeFiles(ArchiveUpdateCallback cb, List<_NewItem> run, int completed) {
    final method = opt.method;
    var runSize = 0;
    for (final ni in run) {
      runSize += ni.size;
    }
    final dict = _dictFor(runSize);
    final opCb = cb is ArchiveUpdateCallbackFile
        ? cb as ArchiveUpdateCallbackFile
        : null;
    // the streams, opened when the encoder first reads them
    final released = <InStream>[];
    _HashingInStream open(_NewItem ni) {
      final s = cb.getStream(ni.index);
      if (s != null) released.add(s);
      return _HashingInStream(
          s ?? MemoryInStream(Uint8List(0)), ni.size, opt.blake2);
    }

    final feed = _SolidFeed([for (final ni in run) () => open(ni)]);
    var solidCont = false;
    try {
      for (var k = 0; k < run.length; k++) {
        final ni = run[k];
        opCb?.reportOperation(
            EventIndexType.outArcIndex, ni.index, UpdateNotifyOp.add);
        final crypt = _keys != null ? _newCrypt() : null;
        final h = _FileHeader()
          ..name = ni.name
          ..attrib = ni.attrib
          ..hostOS = ni.hostOS
          ..unpSize = ni.size
          ..mTime = ni.mTime
          ..cTime = ni.cTime
          ..aTime = ni.aTime
          ..crypt = crypt
          ..hasData = true;
        final useMethod = ni.size == 0 ? 0 : method;
        h.compInfo = (useMethod << 7) |
            (_dictBits(useMethod == 0 ? 0x20000 : dict) << 10) |
            (solidCont && useMethod != 0 ? 0x40 : 0) |
            (useMethod != 0 ? opt.algoVersion : 0);
        if (opt.blake2) {
          h.blake2 = Uint8List(32);
        } else {
          h.crc = 0;
        }
        // the header with placeholders, the data, then the header again
        final seekable = _out0 is SeekableOutStream;
        var (hPos, hSize) = seekable
            ? _writeHeader(h.body(), minData: ni.size > 0 ? 1 : 0)
            : (0, 0);
        final dataOut = seekable ? _out : MemoryOutStream();
        final counted = _PartOut(dataOut, opt.blake2);
        if (_volSizes != null) {
          counted.room = _dataRoom;
          counted.split = () {
            // this part ends here: its header gets the part checksum
            h.splitAfter = true;
            h.dataSize = counted.partCount;
            if (opt.blake2) {
              h.blake2 = counted.partBlake!.digest();
            } else {
              h.crc = counted.partCrc.value;
            }
            _rewriteHeader(hPos, hSize, h.body());
            _nextVolume();
            h.splitBefore = true;
            h.splitAfter = false;
            h.dataSize = 0;
            (hPos, hSize) = _writeHeader(h.body(), minData: 1);
          };
        }
        OutStream sink = counted;
        RarAesEncryptOutStream? encOut;
        if (crypt != null) {
          encOut = RarAesEncryptOutStream(counted, _keys!.key, crypt.iv);
          sink = encOut;
        }
        final src = feed.stream(k);
        if (useMethod == 0 || ni.size == 0) {
          copyStream(src, sink, limit: ni.size);
        } else {
          if (!solidCont) {
            final algo = opt.algoVersion;
            final enc =
                _encoder ??= Rar5Encoder(method, dict, algoVersion: algo);
            if (enc.method != method ||
                enc.dictSize != dict ||
                enc.algoVersion != algo) {
              enc.free();
              _encoder = Rar5Encoder(method, dict, algoVersion: algo);
            }
            _encoder!.start(opt.solid ? feed : src,
                expectedSize: runSize,
                fileSizes:
                    opt.solid ? [for (final x in run) x.size] : [ni.size]);
          }
          _encoder!.encodeFile(ni.size, sink);
          solidCont = opt.solid;
        }
        encOut?.finish();
        // the checksums of the data read
        var crc = src.crc.value;
        Uint8List? b2 = src.blake?.digest();
        if (crypt != null) {
          crc = _keys!.tweakCrc(crc);
          if (b2 != null) b2 = _keys!.tweakHash(b2);
        }
        if (opt.blake2) {
          h.blake2 = b2;
        } else {
          h.crc = crc;
        }
        h.dataSize = _volSizes != null ? counted.partCount : counted.count;
        if (seekable) {
          _rewriteHeader(hPos, hSize, h.body());
        } else {
          _writeHeader(h.body());
          final m = (dataOut as MemoryOutStream).toBytes();
          _out.write(m, 0, m.length);
        }
        completed += ni.size;
        cb.setCompleted(completed);
        cb.setOperationResult(0);
      }
    } finally {
      for (final s in released) {
        releaseStream(s);
      }
    }
    return completed;
  }

  // the header of a kept item (from its fields and its extra area)
  _FileHeader _keptHeader(RarItem it, String? newName) {
    final h = _FileHeader()
      ..name = newName ?? it.name
      ..isDir = it.isDir
      ..unpSize = it.size
      ..attrib = it.attrib
      ..hostOS = it.hostOS
      ..compInfo = it.compInfo
      ..mTimeUnix = it.mTimeUnix
      ..crc = it.crc
      ..keptExtra = it.extra ?? Uint8List(0);
    if (it.parts.length > 1 && it.blake2 != null) h.blake2 = it.blake2;
    return h;
  }

  // copies a kept item with its packed data
  void _copyKept(RarItem it, String? newName) {
    final h = _keptHeader(it, newName);
    h.hasData = !it.isDir || it.packSize > 0;
    h.dataSize = it.packSize;
    _writeHeader(h.body());
    final buf = Uint8List(1 << 16);
    for (final p in it.parts) {
      final s = old!.volumes[p.volume];
      s.position = p.dataPos;
      var left = p.packSize;
      while (left > 0) {
        final n = s.read(buf, 0, left < buf.length ? left : buf.length);
        if (n == 0) {
          throw const SevenZipException(
              'RAR5: unexpected end of the old archive',
              SevenZipError.unexpectedEnd);
        }
        _out.write(buf, 0, n);
        left -= n;
      }
    }
  }

  // a kept item of a solid stream: decoded and compressed again
  void _recompressKept(RarItem it, int oldIndex, String? newName) {
    final handler = oldHandler;
    if (handler == null) {
      throw const SevenZipException(
          'RAR5: kept items of solid archives need the old handler',
          SevenZipError.unsupported);
    }
    final data = handler.decodeItem(oldIndex);
    final method = opt.method;
    final dict = _dictFor(data.length);
    final crypt = _keys != null ? _newCrypt() : null;
    final h = _FileHeader()
      ..name = newName ?? it.name
      ..attrib = it.attrib
      ..hostOS = it.hostOS
      ..unpSize = data.length
      ..mTime = it.mTime
      ..cTime = it.cTime
      ..aTime = it.aTime
      ..crypt = crypt
      ..hasData = true;
    final useMethod = data.isEmpty ? 0 : method;
    h.compInfo = (useMethod << 7) |
        (_dictBits(dict) << 10) |
        (useMethod != 0 ? opt.algoVersion : 0);
    final packed = MemoryOutStream();
    OutStream sink = packed;
    RarAesEncryptOutStream? encOut;
    if (crypt != null) {
      encOut = RarAesEncryptOutStream(packed, _keys!.key, crypt.iv);
      sink = encOut;
    }
    if (useMethod == 0) {
      sink.write(data, 0, data.length);
    } else {
      final enc = Rar5Encoder(method, dict, algoVersion: opt.algoVersion);
      enc.start(MemoryInStream(data),
          expectedSize: data.length, fileSizes: [data.length]);
      enc.encodeFile(data.length, sink);
      enc.free();
    }
    encOut?.finish();
    var crc = Crc32.of(data);
    Uint8List? b2 = opt.blake2 ? Blake2sp.hash(data) : null;
    if (crypt != null) {
      crc = _keys!.tweakCrc(crc);
      if (b2 != null) b2 = _keys!.tweakHash(b2);
    }
    if (b2 != null) {
      h.blake2 = b2;
    } else {
      h.crc = crc;
    }
    final p = packed.toBytes();
    h.dataSize = p.length;
    _writeHeader(h.body());
    _out.write(p, 0, p.length);
  }

  // the archive comment as a CMT service header (stored)
  void _writeComment(String comment) {
    final data = Uint8List.fromList(utf8.encode(comment));
    final crypt = _encryptHeaders ? _newCrypt() : null;
    final h = _FileHeader()
      ..type = Rar5HeaderType.service
      ..name = 'CMT'
      ..unpSize = data.length
      ..hostOS = 0
      ..crypt = crypt
      ..hasData = true;
    var crc = Crc32.of(data);
    Uint8List payload = data;
    if (crypt != null) {
      crc = _keys!.tweakCrc(crc);
      final n = (data.length + 15) & ~15;
      payload = Uint8List(n)..setRange(0, data.length, data);
      rarAesEncrypt(_keys!.key, crypt.iv, payload, 0, n);
    }
    h.crc = crc;
    h.dataSize = payload.length;
    _writeHeader(h.body());
    _out.write(payload, 0, payload.length);
  }
}
