// Reading the headers of RAR 1.5 to 4.x archives: port of the header code
// of libarchive's archive_read_support_format_rar.c
// (archive_read_format_rar_read_header, read_header, read_exttime; Tim
// Kientzle and Andres Mejia, BSD 2-clause, see LICENSE), extended to whole
// archives: every volume is read up front, split files become one item,
// solid files are kept (libarchive stops at them), and the archive comment
// of the CMT sub block is read. The encrypted headers of -hp archives
// (RAR 3.x AES), the CRC range of old style comment blocks and the old
// main header comment compressed with the RAR 2.0 method follow rardecode
// (archive15.go, Nicholas Waples, BSD 2-clause, see LICENSE); a comment
// compressed with the RAR 1.5 method goes to rar15_decoder.dart. RAR 1.5
// had no solid flag per file: in its solid archives every compressed file
// after the first continues the stream.

import 'dart:convert';
import 'dart:typed_data';

import '../../codec/rar/rar15_decoder.dart';
import '../../codec/rar/rar2_decoder.dart';
import '../../codec/rar/rar3_decoder.dart';
import '../../crypto/rar3_kdf.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import 'rar_archive.dart';
import 'rar_crypto.dart';
import 'rar_item.dart';
import 'rar_volumes.dart';

/// Header types (MARK_HEAD ... ENDARC_HEAD).
abstract final class Rar4HeaderType {
  static const mark = 0x72;
  static const main = 0x73;
  static const file = 0x74;
  static const comment = 0x75;
  static const av = 0x76;
  static const sub = 0x77;
  static const protect = 0x78;
  static const sign = 0x79;
  static const newSub = 0x7A;
  static const endArc = 0x7B;
}

/// Main header flags (MHD_*).
abstract final class Rar4MainFlags {
  static const volume = 0x0001;
  static const comment = 0x0002;
  static const lock = 0x0004;
  static const solid = 0x0008;
  static const newNumbering = 0x0010;
  static const av = 0x0020;
  static const protect = 0x0040;
  static const password = 0x0080;
  static const firstVolume = 0x0100;
  static const encryptVer = 0x0200;
}

/// File header flags (FHD_*).
abstract final class Rar4FileFlags {
  static const splitBefore = 0x0001;
  static const splitAfter = 0x0002;
  static const password = 0x0004;
  static const comment = 0x0008;
  static const solid = 0x0010;
  static const dictMask = 0x00E0;
  static const large = 0x0100;
  static const unicode = 0x0200;
  static const salt = 0x0400;
  static const version = 0x0800;
  static const extTime = 0x1000;
  static const extFlags = 0x2000;
}

const int _addSizePresent = 0x8000;

/// Converts a DOS date and time (local time) to FILETIME.
int rarDosTimeToFileTime(int t) {
  final sec = 2 * (t & 0x1F);
  final min = (t >> 5) & 0x3F;
  final hour = (t >> 11) & 0x1F;
  final day = (t >> 16) & 0x1F;
  final month = (t >> 21) & 0x0F;
  final year = ((t >> 25) & 0x7F) + 1980;
  final d = DateTime(year, month, day, hour, min, sec);
  return (d.toUtc().microsecondsSinceEpoch + 11644473600000000) * 10;
}

/// Reads the headers of a RAR 1.5 to 4.x archive into [a].
final class Rar4Reader {
  final RarArchiveData a;
  final RarVolumeOpener? openVolume;
  final RarPasswordGetter? getPassword;
  Rar4Reader(this.a, this.openVolume, this.getPassword);

  bool _nextVolume = false;
  RarItem? _commentItem;

  /// Opens [s] (named [name] for the next volumes). false when it is not a
  /// RAR 1.5 to 4.x archive.
  bool open(SeekableInStream s, String? name) {
    var off = _signatureAt(s) ? 0 : -1;
    if (off < 0 && rarLooksLikeExe(s)) {
      off = rarFindSignature(s, rar4Signature, rarMaxSfxSize);
    }
    if (off < 0) return false;
    a.sfxSize = off;
    a.volumes.add(s);
    a.volumeNames.add(name ?? '');
    _parseVolume(0, off);
    var volName = name;
    while (_wantsNextVolume() && volName != null && openVolume != null) {
      final n = rarNextVolumeName(volName, a.newNumbering);
      if (n == null) break;
      final vs = openVolume!(n);
      if (vs == null) break;
      if (!_signatureAt(vs)) break;
      a.volumes.add(vs);
      a.volumeNames.add(n);
      volName = n;
      _parseVolume(a.volumes.length - 1, 0);
    }
    if (a.items.isNotEmpty && a.items.last.splitAfter) a.unexpectedEnd = true;
    _readComment();
    return true;
  }

  bool _wantsNextVolume() {
    if (!a.isVolume) return false;
    if (_nextVolume) return true;
    return a.items.isNotEmpty && a.items.last.splitAfter;
  }

  static bool _signatureAt(SeekableInStream s) {
    final b = Uint8List(7);
    s.position = 0;
    if (readFully(s, b, 0, 7) != 7) return false;
    for (var i = 0; i < 7; i++) {
      if (b[i] != rar4Signature[i]) return false;
    }
    return true;
  }

  void _setPhy(int vi, int pos) {
    while (a.volumeSizes.length <= vi) {
      a.volumeSizes.add(0);
    }
    a.volumeSizes[vi] = pos;
    if (vi == 0) a.phySize = pos;
  }

  // archive_read_format_rar_read_header, for a whole volume
  void _parseVolume(int vi, int pos) {
    final s = a.volumes[vi];
    final len = s.length;
    _nextVolume = false;
    // the headers after the main header of a -hp archive are encrypted
    // (readBlockHeader of rardecode's archive15.go)
    var encrypted = false;
    final base = Uint8List(7);
    for (;;) {
      Uint8List h;
      int size;
      int hdrLen;
      if (encrypted) {
        final Uint8List? eh;
        try {
          eh = _readEncryptedHeader(s, pos, len);
        } on SevenZipException catch (e) {
          if (e.kind == SevenZipError.wrongPassword) rethrow;
          a.headersError = true;
          _setPhy(vi, pos);
          return;
        }
        if (eh == null) {
          if (pos < len) a.unexpectedEnd = true;
          _setPhy(vi, pos < len ? pos : len);
          return;
        }
        h = eh;
        size = h.length;
        hdrLen = _encHeaderLen;
      } else {
        if (pos + 7 > len) {
          // RAR files can be written without an end of archive header
          if (pos < len) a.unexpectedEnd = true;
          _setPhy(vi, pos < len ? pos : len);
          return;
        }
        s.position = pos;
        readExactly(s, base, 0, 7);
        size = base[5] | (base[6] << 8);
        if (base[2] == Rar4HeaderType.mark) {
          if (size != 7 || !_isMark(base)) {
            a.headersError = true;
            _setPhy(vi, pos);
            return;
          }
          pos += 7;
          continue;
        }
        if (size < 7 || pos + size > len) {
          a.headersError = size < 7;
          a.unexpectedEnd = pos + size > len;
          _setPhy(vi, pos);
          return;
        }
        h = Uint8List(size);
        s.position = pos;
        readExactly(s, h, 0, size);
        hdrLen = size;
      }
      final type = h[2];
      final flags = h[3] | (h[4] << 8);
      // the CRC of an old style comment block, and of a main header with
      // such a block inside (MHD_COMMENT), covers the first 13 bytes only
      // (readBlockHeader of rardecode's archive15.go)
      final crcEnd = (type == Rar4HeaderType.comment ||
                  (type == Rar4HeaderType.main &&
                      (flags & Rar4MainFlags.comment) != 0)) &&
              size > 13
          ? 13
          : size;
      var crcOk = (Crc32.of(h, 2, crcEnd) & 0xFFFF) == (h[0] | (h[1] << 8));
      if (!crcOk &&
          type == Rar4HeaderType.file &&
          (flags & Rar4FileFlags.comment) != 0 &&
          size >= 32) {
        // a RAR 2.x file header with an old style comment block inside:
        // the CRC covers the header up to the end of the name (as the
        // archives of RAR 2.x show)
        var end = 32 + (h[26] | (h[27] << 8));
        if ((flags & Rar4FileFlags.large) != 0) end += 8;
        crcOk = end <= size &&
            (Crc32.of(h, 2, end) & 0xFFFF) == (h[0] | (h[1] << 8));
      }
      if (encrypted && !crcOk) {
        // no password check in RAR 3.x: a wrong password gives headers
        // with bad CRCs
        throw const SevenZipException(
            'RAR: encrypted header CRC error, wrong password?',
            SevenZipError.wrongPassword);
      }
      if (encrypted) _encHeaderOk = true;
      var addSize = 0;
      if ((flags & _addSizePresent) != 0 &&
          type != Rar4HeaderType.file &&
          type != Rar4HeaderType.newSub) {
        if (size < 11) {
          a.headersError = true;
          _setPhy(vi, pos);
          return;
        }
        addSize = getUint32LE(h, 7);
      }
      switch (type) {
        case Rar4HeaderType.mark:
          // only valid unencrypted, at the start (handled above)
          a.headersError = true;
          _setPhy(vi, pos);
          return;
        case Rar4HeaderType.main:
          if (!crcOk) {
            a.headersError = true;
            _setPhy(vi, pos);
            return;
          }
          _parseMain(vi, h, flags);
          if ((flags & Rar4MainFlags.password) != 0) {
            a.encryptedHeaders = true;
            encrypted = true;
          }
          pos += hdrLen;
        case Rar4HeaderType.file:
        case Rar4HeaderType.newSub:
          if (!crcOk) {
            a.headersError = true;
            _setPhy(vi, pos);
            return;
          }
          final it = RarItem()..isRar5 = false;
          int dataSize;
          try {
            dataSize = _parseFile(it, h, flags);
          } on RarHeaderError {
            a.headersError = true;
            _setPhy(vi, pos);
            return;
          }
          final part = RarPart(vi, pos, hdrLen, pos + hdrLen, dataSize);
          if (type == Rar4HeaderType.file) {
            a.numBlocks++;
            _addFile(it, part);
          } else if (it.name == 'CMT' && _commentItem == null) {
            it.parts.add(part);
            _commentItem = it;
          }
          pos += hdrLen + dataSize;
          if (pos > len) {
            a.unexpectedEnd = true;
            _setPhy(vi, len);
            return;
          }
        case Rar4HeaderType.endArc:
          final r = RarHeaderReader(h, 7, size);
          try {
            if ((flags & 0x0002) != 0) r.u32(); // EARC_DATACRC
            if ((flags & 0x0008) != 0) {
              final vn = r.u16(); // EARC_VOLNUMBER
              if (vi == 0) a.volumeNumber = vn;
            }
          } on RarHeaderError {
            // ignored
          }
          _nextVolume = (flags & 0x0001) != 0;
          _setPhy(vi, pos + hdrLen);
          return;
        case Rar4HeaderType.comment:
        case Rar4HeaderType.av:
        case Rar4HeaderType.sub:
        case Rar4HeaderType.protect:
        case Rar4HeaderType.sign:
          pos += hdrLen + addSize;
        default:
          a.headersError = true;
          _setPhy(vi, pos);
          return;
      }
    }
  }

  // the size on disk of the last header read by _readEncryptedHeader
  int _encHeaderLen = 0;

  // an encrypted header had a good CRC (the password is right)
  bool _encHeaderOk = false;

  // readBlockHeader of rardecode (archive15.go) for encrypted headers: an
  // 8 byte salt, then the header encrypted with AES-128-CBC and padded to
  // whole blocks. Returns the decrypted header (without the padding), or
  // null at the end of the volume.
  Uint8List? _readEncryptedHeader(SeekableInStream s, int pos, int len) {
    if (pos + rar3SaltSize + 16 > len) return null;
    final salt = Uint8List(rar3SaltSize);
    s.position = pos;
    readExactly(s, salt, 0, rar3SaltSize);
    final keys = a.rar3KeysFor(_password(), salt);
    final first = Uint8List(16);
    readExactly(s, first, 0, 16);
    rarAesDecrypt(keys.key, keys.iv, first, 0, 16);
    final size = first[5] | (first[6] << 8);
    if (size < 7) {
      throw const SevenZipException(
          'RAR: bad encrypted header, wrong password?',
          SevenZipError.wrongPassword);
    }
    final enc = (size + 15) & ~15;
    if (pos + rar3SaltSize + enc > len) {
      // a truncated volume, or a size from a wrong key
      if (!_encHeaderOk) {
        throw const SevenZipException(
            'RAR: bad encrypted header, wrong password?',
            SevenZipError.wrongPassword);
      }
      return null;
    }
    final buf = Uint8List(enc);
    s.position = pos + rar3SaltSize;
    readExactly(s, buf, 0, enc);
    rarAesDecrypt(keys.key, keys.iv, buf, 0, enc);
    _encHeaderLen = rar3SaltSize + enc;
    return Uint8List.sublistView(buf, 0, size);
  }

  String _password() {
    if (a.password != null) return a.password!;
    final g = getPassword;
    final pw = g == null ? null : g();
    a.passwordAsked = true;
    if (pw == null) {
      throw const SevenZipException(
          'RAR: the headers are encrypted and no password was given',
          SevenZipError.wrongPassword);
    }
    a.password = pw;
    return pw;
  }

  static bool _isMark(Uint8List b) {
    for (var i = 0; i < 7; i++) {
      if (b[i] != rar4Signature[i]) return false;
    }
    return true;
  }

  void _parseMain(int vi, Uint8List h, int flags) {
    if (vi != 0) return;
    a.mainFlags = flags;
    a.isVolume = (flags & Rar4MainFlags.volume) != 0;
    a.solid = (flags & Rar4MainFlags.solid) != 0;
    a.locked = (flags & Rar4MainFlags.lock) != 0;
    a.recovery = (flags & Rar4MainFlags.protect) != 0;
    a.newNumbering = (flags & Rar4MainFlags.newNumbering) != 0;
    a.firstVolume = (flags & Rar4MainFlags.firstVolume) != 0;
    if (a.firstVolume) a.volumeNumber = 0;
    if ((flags & Rar4MainFlags.encryptVer) != 0 && h.length > 13) {
      a.encryptVer = h[13];
    }
    if ((flags & Rar4MainFlags.comment) != 0 && h.length > 13 + 13) {
      // an old style comment block inside the main header (RAR 2.x)
      _parseOldComment(h, 13);
    }
  }

  void _parseOldComment(Uint8List h, int p) {
    try {
      final r = RarHeaderReader(h, p, h.length);
      r.u16(); // crc
      final type = r.byte();
      if (type != Rar4HeaderType.comment) return;
      r.u16(); // flags
      final size = r.u16();
      final unpSize = r.u16();
      final unpVer = r.byte();
      final method = r.byte();
      final crc = r.u16();
      final n = size - 13;
      if (n < 0) return;
      if (method == 0x30) {
        if (n > unpSize + 16) return;
        a.comment = _decodeText(r.bytes(n < unpSize ? n : unpSize));
        return;
      }
      final out = MemoryOutStream();
      if (unpVer == 15) {
        // compressed with the RAR 1.5 method
        Rar15Decoder()
            .decodeFile(MemoryInStream(r.bytes(n)), out, unpSize, false);
      } else if (unpVer == 20 || unpVer == 26) {
        // compressed with the RAR 2.0 method
        Rar2Decoder()
            .decodeFile(MemoryInStream(r.bytes(n)), out, unpSize, 0, false);
      } else {
        return;
      }
      final b = out.toBytes();
      if ((Crc32.of(b) & 0xFFFF) != crc) return;
      a.comment = _decodeText(b);
    } on RarHeaderError {
      // ignored
    } on SevenZipException {
      // ignored
    } on RangeError {
      // ignored
    }
  }

  // read_header: the fields of a file header; returns the packed size
  int _parseFile(RarItem it, Uint8List h, int flags) {
    final r = RarHeaderReader(h, 7, h.length);
    it.flags = flags;
    var packSize = r.u32();
    var unpSize = r.u32();
    it.hostOS = r.byte();
    it.crc = r.u32();
    final ftime = r.u32();
    it.algoVersion = r.byte();
    final method = r.byte();
    final nameSize = r.u16();
    it.attrib = r.u32();
    if ((flags & Rar4FileFlags.large) != 0) {
      packSize |= r.u32() << 32;
      unpSize |= r.u32() << 32;
    }
    it.size = unpSize;
    it.method = method >= 0x30 && method <= 0x35 ? method - 0x30 : method;
    final nameBytes = r.bytes(nameSize);
    it.unicodeName = (flags & Rar4FileFlags.unicode) != 0;
    it.name = _decodeName(nameBytes, it.unicodeName).replaceAll('\\', '/');
    if ((flags & Rar4FileFlags.salt) != 0) it.salt = r.bytes(8);
    it.mTime = rarDosTimeToFileTime(ftime);
    if ((flags & Rar4FileFlags.extTime) != 0) _readExtTime(it, r, ftime);
    final dictFlags = flags & Rar4FileFlags.dictMask;
    it.isDir = dictFlags == Rar4FileFlags.dictMask;
    it.dictSize = it.isDir ? 0 : 0x10000 << (dictFlags >> 5);
    it.splitBefore = (flags & Rar4FileFlags.splitBefore) != 0;
    it.splitAfter = (flags & Rar4FileFlags.splitAfter) != 0;
    it.encrypted = (flags & Rar4FileFlags.password) != 0;
    it.commented = (flags & Rar4FileFlags.comment) != 0;
    it.solid = (flags & Rar4FileFlags.solid) != 0;
    if (it.isDir) it.crc = null;
    return packSize;
  }

  // read_exttime: the times with their extra precision
  void _readExtTime(RarItem it, RarHeaderReader r, int ftime) {
    final flags = r.u16();
    final times = <int?>[null, null, null, null];
    for (var i = 3; i >= 0; i--) {
      final rmode = flags >> (i * 4);
      if ((rmode & 8) == 0) continue;
      var dos = ftime;
      if (i != 3) dos = r.u32();
      var t = rarDosTimeToFileTime(dos);
      final count = rmode & 3;
      var rem = 0;
      for (var j = 0; j < count; j++) {
        rem = (r.byte() << 16) | (rem >> 8);
      }
      t += rem;
      if ((rmode & 4) != 0) t += 10000000;
      times[i] = t;
    }
    if (times[3] != null) it.mTime = times[3];
    it.cTime = times[2];
    it.aTime = times[1];
  }

  // the file name: OEM or UTF-8 bytes, or the RAR unicode encoding
  static String _decodeName(Uint8List p, bool unicode) {
    var zero = p.indexOf(0);
    if (!unicode || zero < 0) {
      if (zero >= 0) p = Uint8List.sublistView(p, 0, zero);
      return _decodeText(p);
    }
    // the encoded UTF-16 form after the zero byte (read_header)
    final end = p.length;
    final out = <int>[];
    var offset = zero + 1;
    final highByte = offset >= end ? 0 : p[offset++];
    var flagBits = 0;
    var flagByte = 0;
    final maxChars = end;
    while (offset < end && out.length < maxChars) {
      if (flagBits == 0) {
        flagByte = p[offset++];
        flagBits = 8;
      }
      flagBits -= 2;
      switch ((flagByte >> flagBits) & 3) {
        case 0:
          if (offset >= end) continue;
          out.add(p[offset++]);
        case 1:
          if (offset >= end) continue;
          out.add((highByte << 8) | p[offset++]);
        case 2:
          if (offset >= end - 1) {
            offset = end;
            continue;
          }
          out.add(p[offset] | (p[offset + 1] << 8));
          offset += 2;
        case 3:
          if (offset >= end) continue;
          var length = p[offset++];
          var extra = 0;
          var high = 0;
          if ((length & 0x80) != 0) {
            if (offset >= end) continue;
            extra = p[offset++];
            high = highByte;
          }
          length = (length & 0x7F) + 2;
          while (length > 0 && out.length < maxChars) {
            final cp = out.length;
            final low = cp < zero ? (p[cp] + extra) & 0xFF : 0;
            out.add((high << 8) | low);
            length--;
          }
      }
    }
    return String.fromCharCodes(out);
  }

  static String _decodeText(Uint8List b) {
    try {
      return utf8.decode(b);
    } on FormatException {
      return latin1.decode(b);
    }
  }

  void _addFile(RarItem it, RarPart part) {
    if (it.splitBefore && a.items.isNotEmpty) {
      final last = a.items.last;
      if (last.splitAfter && last.name == it.name) {
        last.parts.add(part);
        last.splitAfter = it.splitAfter;
        if (!it.splitAfter) last.crc = it.crc;
        return;
      }
    }
    if (a.solid && it.algoVersion < 20 && !it.isDir && it.method != 0) {
      // RAR 1.5 had no solid flag per file: in a solid archive every
      // compressed file after the first continues the stream
      for (final x in a.items) {
        if (!x.isDir && x.method != 0) {
          it.solid = true;
          break;
        }
      }
    }
    it.parts.add(part);
    a.items.add(it);
    if (it.isSymLink &&
        it.method == 0 &&
        !it.encrypted &&
        part.packSize <= 0x10000 &&
        !it.splitAfter) {
      // a Unix symbolic link: the target is the stored data
      try {
        final s = a.volumes[part.volume];
        final b = Uint8List(part.packSize);
        s.position = part.dataPos;
        readExactly(s, b, 0, b.length);
        it.linkTarget = _decodeText(b);
      } on SevenZipException {
        // left without a target
      }
    }
  }

  // the archive comment of RAR 3.x: the data of the CMT sub block,
  // stored or compressed
  void _readComment() {
    final it = _commentItem;
    if (it == null || a.comment != null || it.encrypted) return;
    try {
      final p = it.parts.first;
      final src = WindowInStream(a.volumes[p.volume], p.dataPos, p.packSize);
      final out = MemoryOutStream();
      if (it.method == 0) {
        copyStream(src, out, limit: it.size);
      } else {
        Rar3Decoder()
            .decodeFile(src, out, it.size, it.algoVersion, it.dictSize, false);
      }
      var bytes = out.toBytes();
      var n = bytes.length;
      while (n > 0 && bytes[n - 1] == 0) {
        n--;
      }
      bytes = Uint8List.sublistView(bytes, 0, n);
      a.comment = _decodeText(bytes);
    } on SevenZipException {
      // the comment is left out
    }
  }
}
