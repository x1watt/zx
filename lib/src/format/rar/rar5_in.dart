// Reading the headers of RAR5 archives, from the RAR 5.0 archive format
// technote (https://www.rarlab.com/technote.htm) and libarchive's
// archive_read_support_format_rar5.c (process_base_block, process_head_main,
// process_head_file, process_head_file_extra and the parse_file_extra_*
// functions; BSD 2-clause, see LICENSE).

import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/rar5_kdf.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import 'rar_archive.dart';
import 'rar_crypto.dart';
import 'rar_item.dart';
import 'rar_volumes.dart';

/// HEADER_TYPE
abstract final class Rar5HeaderType {
  static const mark = 0;
  static const main = 1;
  static const file = 2;
  static const service = 3;
  static const crypt = 4;
  static const endArc = 5;
}

/// HEADER_FLAGS
abstract final class Rar5HeaderFlags {
  static const extra = 0x0001;
  static const data = 0x0002;
  static const skipIfUnknown = 0x0004;
  static const splitBefore = 0x0008;
  static const splitAfter = 0x0010;
  static const child = 0x0020;
  static const inherited = 0x0040;
}

/// EXTRA
abstract final class Rar5Extra {
  static const crypt = 1;
  static const hash = 2;
  static const htime = 3;
  static const version = 4;
  static const redir = 5;
  static const owner = 6;
  static const subdata = 7;
}

/// A header read from a volume.
final class Rar5RawHeader {
  /// The header bytes from the header type to the end of the extra area.
  final Uint8List body;

  /// Offset of the header in its volume and its size there (with the IV
  /// and the padding of an encrypted header).
  final int pos;
  final int diskSize;
  Rar5RawHeader(this.body, this.pos, this.diskSize);
}

SevenZipException _headersError(String m) =>
    SevenZipException('RAR5: $m', SevenZipError.headers);

/// Reads the headers of a RAR5 archive into [a].
final class Rar5Reader {
  final RarArchiveData a;
  final RarVolumeOpener? openVolume;
  final RarPasswordGetter? getPassword;
  Rar5Reader(this.a, this.openVolume, this.getPassword);

  /// Opens [s] (named [name] for the next volumes). false when it is not a
  /// RAR5 archive.
  bool open(SeekableInStream s, String? name) {
    var off = _signatureAt(s, 0) ? 0 : -1;
    if (off < 0 && rarLooksLikeExe(s)) {
      off = rarFindSignature(s, rar5Signature, rarMaxSfxSize);
    }
    if (off < 0) return false;
    a.sfxSize = off;
    a.volumes.add(s);
    a.volumeNames.add(name ?? '');
    var next = _parseVolume(0, off + 8);
    var volName = name;
    while (next && volName != null && openVolume != null) {
      final n = rarNextVolumeName(volName, true);
      if (n == null) break;
      final vs = openVolume!(n);
      if (vs == null) break;
      if (!_signatureAt(vs, 0)) break;
      a.volumes.add(vs);
      a.volumeNames.add(n);
      volName = n;
      next = _parseVolume(a.volumes.length - 1, 8);
    }
    if (next && a.items.isNotEmpty && a.items.last.splitAfter) {
      a.unexpectedEnd = true;
    }
    return true;
  }

  static bool _signatureAt(SeekableInStream s, int pos) {
    final b = Uint8List(8);
    s.position = pos;
    if (readFully(s, b, 0, 8) != 8) return false;
    for (var i = 0; i < 8; i++) {
      if (b[i] != rar5Signature[i]) return false;
    }
    return true;
  }

  Rar5Keys? _volHeaderKeys;

  /// Reads the header at [pos]: null at the end of the volume or on a
  /// truncated header.
  Rar5RawHeader? readHeader(SeekableInStream s, int pos) {
    final len = s.length;
    final keys = _volHeaderKeys;
    if (keys == null) {
      if (pos + 5 > len) return null;
      final head = Uint8List(7);
      s.position = pos;
      final n = readFully(s, head, 0, 7);
      final r = RarHeaderReader(head, 4, n);
      int size;
      try {
        size = r.vint();
      } on RarHeaderError {
        throw _headersError('bad header size');
      }
      final sizeLen = r.pos - 4;
      if (sizeLen > 3 || size == 0 || size > (2 << 20)) {
        throw _headersError('bad header size');
      }
      final total = 4 + sizeLen + size;
      if (pos + total > len) return null;
      final buf = Uint8List(total);
      s.position = pos;
      readExactly(s, buf, 0, total);
      final crc = Crc32.of(buf, 4, total);
      if (crc != getUint32LE(buf, 0)) throw _headersError('header CRC error');
      return Rar5RawHeader(Uint8List.sublistView(buf, 4 + sizeLen), pos, total);
    }
    // an encrypted header: IV, then the header encrypted and padded
    if (pos + 32 > len) return null;
    final iv = Uint8List(16);
    s.position = pos;
    readExactly(s, iv, 0, 16);
    final first = Uint8List(16);
    readExactly(s, first, 0, 16);
    final dec = Uint8List.fromList(first);
    rarAesDecrypt(keys.key, iv, dec, 0, 16);
    final r = RarHeaderReader(dec, 4, 16);
    int size;
    try {
      size = r.vint();
    } on RarHeaderError {
      throw const SevenZipException(
          'RAR5: bad encrypted header, wrong password?',
          SevenZipError.wrongPassword);
    }
    final sizeLen = r.pos - 4;
    if (sizeLen > 3 || size == 0 || size > (2 << 20)) {
      throw const SevenZipException(
          'RAR5: bad encrypted header, wrong password?',
          SevenZipError.wrongPassword);
    }
    final total = 4 + sizeLen + size;
    final enc = (total + 15) & ~15;
    if (pos + 16 + enc > len) return null;
    final buf = Uint8List(enc);
    s.position = pos + 16;
    readExactly(s, buf, 0, enc);
    rarAesDecrypt(keys.key, iv, buf, 0, enc);
    final crc = Crc32.of(buf, 4, total);
    if (crc != getUint32LE(buf, 0)) {
      throw const SevenZipException(
          'RAR5: encrypted header CRC error, wrong password?',
          SevenZipError.wrongPassword);
    }
    return Rar5RawHeader(
        Uint8List.sublistView(buf, 4 + sizeLen, total), pos, 16 + enc);
  }

  // Parses the headers of volume [vi] from [pos]. true when the archive
  // continues in the next volume.
  bool _parseVolume(int vi, int pos) {
    final s = a.volumes[vi];
    _volHeaderKeys = null;
    final len = s.length;
    for (;;) {
      Rar5RawHeader? h;
      try {
        h = readHeader(s, pos);
      } on SevenZipException catch (e) {
        if (e.kind == SevenZipError.wrongPassword) rethrow;
        a.headersError = true;
        _setPhy(vi, pos);
        return false;
      }
      if (h == null) {
        a.unexpectedEnd = true;
        _setPhy(vi, pos);
        return false;
      }
      final r = RarHeaderReader(h.body, 0, h.body.length);
      int type, hflags, extraSize = 0, dataSize = 0;
      try {
        type = r.vint();
        hflags = r.vint();
        if ((hflags & Rar5HeaderFlags.extra) != 0) extraSize = r.vint();
        if ((hflags & Rar5HeaderFlags.data) != 0) dataSize = r.vint();
      } on RarHeaderError {
        a.headersError = true;
        _setPhy(vi, pos);
        return false;
      }
      final extraStart = h.body.length - extraSize;
      final dataPos = pos + h.diskSize;
      if (extraStart < r.pos || dataSize < 0) {
        a.headersError = true;
        _setPhy(vi, pos);
        return false;
      }
      if (dataPos + dataSize > len) a.unexpectedEnd = true;
      try {
        switch (type) {
          case Rar5HeaderType.main:
            _parseMain(r, extraStart, vi);
          case Rar5HeaderType.crypt:
            _parseCrypt(r);
          case Rar5HeaderType.file:
          case Rar5HeaderType.service:
            final it = RarItem()..isRar5 = true;
            _parseFile(it, r, extraStart, h.body);
            it.splitBefore = (hflags & Rar5HeaderFlags.splitBefore) != 0;
            it.splitAfter = (hflags & Rar5HeaderFlags.splitAfter) != 0;
            final part = RarPart(vi, pos, h.diskSize, dataPos, dataSize);
            if (type == Rar5HeaderType.file) {
              a.numBlocks++;
              _addFile(it, part);
            } else {
              _service(it, part);
            }
          case Rar5HeaderType.endArc:
            final flags = r.atEnd ? 0 : r.vint();
            _setPhy(vi, pos + h.diskSize);
            return (flags & 1) != 0;
          default:
            break;
        }
      } on RarHeaderError {
        a.headersError = true;
        _setPhy(vi, pos);
        return false;
      }
      pos = dataPos + dataSize;
      if (pos > len) {
        _setPhy(vi, len);
        return false;
      }
    }
  }

  void _setPhy(int vi, int pos) {
    while (a.volumeSizes.length <= vi) {
      a.volumeSizes.add(0);
    }
    a.volumeSizes[vi] = pos;
    if (vi == 0) a.phySize = pos;
  }

  // process_head_main
  void _parseMain(RarHeaderReader r, int extraStart, int vi) {
    final flags = r.vint();
    if (vi == 0) {
      a.mainFlags = flags;
      a.isVolume = (flags & 1) != 0;
      a.solid = (flags & 4) != 0;
      a.recovery = (flags & 8) != 0;
      a.locked = (flags & 0x10) != 0;
      a.newNumbering = true;
      if ((flags & 2) != 0) {
        a.volumeNumber = r.vint();
      } else {
        a.volumeNumber = 0;
        a.firstVolume = a.isVolume;
      }
    }
  }

  // the archive encryption header
  void _parseCrypt(RarHeaderReader r) {
    final c = Rar5CryptInfo();
    c.version = r.vint();
    c.flags = r.vint();
    c.kdfCount = r.byte();
    c.salt.setAll(0, r.bytes(16));
    if (c.hasCheck) c.check = r.bytes(12);
    if (c.version != 0 || c.kdfCount > rar5MaxKdfCount) {
      throw const SevenZipException(
          'RAR5: unsupported encryption', SevenZipError.unsupportedMethod);
    }
    a.encryptedHeaders = true;
    a.headerCrypt = c;
    final pw = _password();
    final keys = a.keysFor(pw, c.salt, c.kdfCount);
    if (c.check != null && !rar5CheckPassword(keys, c.check!)) {
      throw const SevenZipException(
          'RAR5: wrong password', SevenZipError.wrongPassword);
    }
    a.headerKeys = keys;
    _volHeaderKeys = keys;
  }

  String _password() {
    if (a.password != null) return a.password!;
    final g = getPassword;
    final pw = g == null ? null : g();
    a.passwordAsked = true;
    if (pw == null) {
      throw const SevenZipException(
          'RAR5: the headers are encrypted and no password was given',
          SevenZipError.wrongPassword);
    }
    a.password = pw;
    return pw;
  }

  void _addFile(RarItem it, RarPart part) {
    if (it.splitBefore && a.items.isNotEmpty) {
      final last = a.items.last;
      if (last.splitAfter && last.name == it.name) {
        last.parts.add(part);
        last.splitAfter = it.splitAfter;
        if (!it.splitAfter) {
          // the last part holds the checksums of the whole file
          last.crc = it.crc;
          last.blake2 = it.blake2;
        }
        return;
      }
    }
    it.parts.add(part);
    a.items.add(it);
  }

  void _service(RarItem it, RarPart part) {
    if (it.name == 'CMT' && a.comment == null && it.method == 0) {
      try {
        final s = a.volumes[part.volume];
        final data = Uint8List(part.packSize);
        s.position = part.dataPos;
        readExactly(s, data, 0, data.length);
        var text = data;
        final c = it.crypt;
        if (c != null) {
          final keys = a.keysFor(_password(), c.salt, c.kdfCount);
          final n = data.length & ~15;
          rarAesDecrypt(keys.key, c.iv, data, 0, n);
          text = Uint8List.sublistView(data, 0, it.size < n ? it.size : n);
        } else if (it.size < data.length) {
          text = Uint8List.sublistView(data, 0, it.size);
        }
        a.comment = utf8.decode(text, allowMalformed: true);
      } on SevenZipException catch (e) {
        if (e.kind == SevenZipError.wrongPassword) rethrow;
      }
    }
  }

  // process_head_file and process_head_file_extra
  void _parseFile(
      RarItem it, RarHeaderReader r, int extraStart, Uint8List body) {
    final fileFlags = r.vint();
    it.flags = fileFlags;
    it.size = r.vint();
    it.sizeUnknown = (fileFlags & 8) != 0;
    it.attrib = r.vint();
    it.isDir = (fileFlags & 1) != 0;
    if ((fileFlags & 2) != 0) {
      final t = r.u32();
      it.mTimeUnix = t;
      it.mTime = unixToFileTime(t);
      it.unixTime = true;
    }
    if ((fileFlags & 4) != 0) it.crc = r.u32();
    final ci = r.vint();
    it.compInfo = ci;
    it.algoVersion = ci & 0x3F;
    it.solid = (ci & 0x40) != 0;
    it.method = (ci >> 7) & 7;
    final dictBits = (ci >> 10) & 0x1F;
    var dict = 0x20000 << dictBits;
    if (it.algoVersion == 1) {
      final frac = (ci >> 15) & 0x1F;
      dict += (dict >> 5) * frac;
      if ((ci & 0x100000) != 0) it.algoVersion = 0;
    }
    it.dictSize = dict;
    it.hostOS = r.vint();
    final nameLen = r.vint();
    it.name = utf8.decode(r.bytes(nameLen), allowMalformed: true);
    if (extraStart < body.length) {
      it.extra = Uint8List.fromList(
          Uint8List.sublistView(body, extraStart, body.length));
    }
    var p = extraStart;
    while (p < body.length) {
      final er = RarHeaderReader(body, p, body.length);
      final size = er.vint();
      final recEnd = er.pos + size;
      if (size <= 0 || recEnd > body.length) throw const RarHeaderError();
      final x = RarHeaderReader(body, er.pos, recEnd);
      final type = x.vint();
      switch (type) {
        case Rar5Extra.crypt:
          final c = Rar5CryptInfo();
          c.version = x.vint();
          c.flags = x.vint();
          c.kdfCount = x.byte();
          c.salt.setAll(0, x.bytes(16));
          c.iv.setAll(0, x.bytes(16));
          if (c.hasCheck) c.check = x.bytes(12);
          it.crypt = c;
          it.encrypted = true;
        case Rar5Extra.hash:
          final ht = x.vint();
          if (ht == 0) it.blake2 = x.bytes(32);
        case Rar5Extra.htime:
          final f = x.vint();
          final unix = (f & 1) != 0;
          final ns = unix && (f & 0x10) != 0;
          int readT() => unix ? unixToFileTime(x.u32()) : x.u64();
          int? m, c, at;
          if ((f & 2) != 0) m = readT();
          if ((f & 4) != 0) c = readT();
          if ((f & 8) != 0) at = readT();
          if (ns) {
            if (m != null) m += (x.u32() & 0x3FFFFFFF) ~/ 100;
            if (c != null) c += (x.u32() & 0x3FFFFFFF) ~/ 100;
            if (at != null) at += (x.u32() & 0x3FFFFFFF) ~/ 100;
          }
          if (m != null) it.mTime = m;
          it.cTime = c;
          it.aTime = at;
          it.unixTime = unix;
          it.unixTimeNs = ns;
        case Rar5Extra.version:
          x.vint();
          it.fileVersion = x.vint();
        case Rar5Extra.redir:
          it.redirType = x.vint();
          it.redirFlags = x.vint();
          final n = x.vint();
          it.linkTarget = utf8.decode(x.bytes(n), allowMalformed: true);
        case Rar5Extra.owner:
          final f = x.vint();
          if ((f & 1) != 0) {
            it.user = utf8.decode(x.bytes(x.vint()), allowMalformed: true);
          }
          if ((f & 2) != 0) {
            it.group = utf8.decode(x.bytes(x.vint()), allowMalformed: true);
          }
          if ((f & 4) != 0) it.uid = x.vint();
          if ((f & 8) != 0) it.gid = x.vint();
        default:
          break;
      }
      p = recEnd;
    }
  }
}

/// Checks the 12 byte check value of a RAR5 encryption record against
/// [keys]. A value whose checksum does not match is ignored (true), as
/// the technote describes it as damaged data rather than a wrong password.
bool rar5CheckPassword(Rar5Keys keys, Uint8List check) {
  final sum = Rar5Keys.checkSum(Uint8List.sublistView(check, 0, 8));
  for (var i = 0; i < 4; i++) {
    if (sum[i] != check[8 + i]) return true;
  }
  for (var i = 0; i < 8; i++) {
    if (keys.pswCheck[i] != check[i]) return false;
  }
  return true;
}
