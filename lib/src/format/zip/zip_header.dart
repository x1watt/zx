// Zip archive structures, written from the PKWARE APPNOTE (6.3.10): the
// signatures, general purpose flags, method numbers and host systems, the
// item record read from the central directory and the local header, the
// extra fields the handler understands (Zip64 0x0001, NTFS 0x000a, the
// Info-ZIP extended timestamp 0x5455, Unix 0x7875 and 0x5855, Unicode path
// 0x7075, WinZip AES 0x9901), and the time conversions (DOS, Unix,
// FILETIME).

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import '../../io/streams.dart';

/// Header signatures (APPNOTE 4.3).
abstract final class ZipSig {
  static const local = 0x04034b50;
  static const central = 0x02014b50;
  static const eocd = 0x06054b50;
  static const zip64Eocd = 0x06064b50;
  static const zip64Locator = 0x07064b50;
  static const descriptor = 0x08074b50;

  /// The marker at the start of the first volume of a spanned archive
  /// (the same value as the data descriptor signature).
  static const spanMarker = 0x08074b50;

  /// "PK00": the marker of a spanned archive that fitted on one volume.
  static const tempSpanMarker = 0x30304b50;
}

/// General purpose bit flags (APPNOTE 4.4.4).
abstract final class ZipFlags {
  static const encrypted = 1 << 0;

  /// Implode: 8K sliding dictionary. LZMA: an end of stream marker is
  /// present. Deflate: bits 1 and 2 are the compression option.
  static const bit1 = 1 << 1;
  static const bit2 = 1 << 2;
  static const descriptor = 1 << 3;
  static const enhancedDeflate = 1 << 4;
  static const patched = 1 << 5;
  static const strongEncryption = 1 << 6;
  static const utf8 = 1 << 11;
  static const maskedHeaders = 1 << 13;
}

/// Compression methods (APPNOTE 4.4.5).
abstract final class ZipMethod {
  static const store = 0;
  static const shrink = 1;
  static const reduce1 = 2;
  static const reduce4 = 5;
  static const implode = 6;
  static const tokenize = 7;
  static const deflate = 8;
  static const deflate64 = 9;
  static const pkImplode = 10;
  static const bzip2 = 12;
  static const lzma = 14;
  static const terse = 18;
  static const lz77 = 19;
  static const zstdOld = 20;
  static const zstd = 93;
  static const mp3 = 94;
  static const xz = 95;
  static const jpeg = 96;
  static const wavPack = 97;
  static const ppmd = 98;
  static const aes = 99;
}

/// Host systems of "version made by" (the Info-ZIP numbering).
abstract final class ZipHost {
  static const fat = 0;
  static const unix = 3;
  static const hpfs = 6;
  static const ntfs = 11;
  static const vfat = 14;
  static const osx = 19;
}

const List<String> _kHostNames = [
  'FAT', 'AMIGA', 'VMS', 'Unix', 'VM/CMS', 'Atari', 'HPFS', 'Macintosh', //
  'Z-System', 'CP/M', 'TOPS-20', 'NTFS', 'SMS/QDOS', 'Acorn', 'VFAT', 'MVS',
  'BeOS', 'Tandem', 'OS/400', 'OS/X',
];

/// The name of host system [h] as 7-Zip lists it.
String zipHostName(int h) => h < _kHostNames.length ? _kHostNames[h] : '$h';

/// Extra field ids (APPNOTE 4.5 and 4.6).
abstract final class ZipExtraId {
  static const zip64 = 0x0001;
  static const ntfs = 0x000a;
  static const pkwareUnix = 0x000d;
  static const strongEncryption = 0x0017;
  static const extTime = 0x5455; // "UT"
  static const unixOld = 0x5855; // "UX"
  static const unicodeComment = 0x6375; // "uc"
  static const unicodePath = 0x7075; // "up"
  static const unixIds = 0x7875; // "ux"
  static const aes = 0x9901;
}

/// FILETIME of 1970-01-01 (100 ns units since 1601).
const int kUnixEpochFileTime = 116444736000000000;

/// Unix seconds to FILETIME.
int unixToFileTime(int seconds) => seconds * 10000000 + kUnixEpochFileTime;

/// FILETIME to Unix seconds (rounded down).
int fileTimeToUnix(int ft) {
  final d = ft - kUnixEpochFileTime;
  return d >= 0 ? d ~/ 10000000 : -((-d + 9999999) ~/ 10000000);
}

/// The current difference between local time and UTC in FILETIME units.
/// DOS times are converted with it (not with the offset of their own date),
/// as 7-Zip does with LocalFileTimeToFileTime.
int get localBiasTicks => DateTime.now().timeZoneOffset.inSeconds * 10000000;

/// A DOS date and time (date in the high 16 bits), local time, to FILETIME.
/// null for an invalid value.
int? dosTimeToFileTime(int dosTime) {
  final time = dosTime & 0xFFFF;
  final date = (dosTime >> 16) & 0xFFFF;
  final sec = (time & 0x1F) * 2;
  final min = (time >> 5) & 0x3F;
  final hour = time >> 11;
  final day = date & 0x1F;
  final month = (date >> 5) & 0xF;
  final year = 1980 + (date >> 9);
  if (month < 1 || month > 12 || day < 1 || hour > 23 || min > 59) {
    return null;
  }
  final dt = DateTime.utc(year, month, day, hour, min, sec);
  return dt.microsecondsSinceEpoch * 10 + kUnixEpochFileTime - localBiasTicks;
}

/// FILETIME to a DOS date and time in local time. The seconds are rounded
/// up to an even value when [roundUp] (as 7-Zip writes them), else down.
/// Times before 1980 give 1980-01-01 00:00:00, after 2107 the last value.
int fileTimeToDosTime(int ft, {bool roundUp = true}) {
  var t = ft + localBiasTicks;
  if (roundUp) {
    // up to the next even second
    const twoSec = 20000000;
    final r = (t - kUnixEpochFileTime) % twoSec;
    if (r != 0) t += twoSec - r;
  }
  final d = DateTime.fromMicrosecondsSinceEpoch((t - kUnixEpochFileTime) ~/ 10,
      isUtc: true);
  if (d.year < 1980) return (1 << 21) | (1 << 16);
  if (d.year > 2107) return 0xFF9FBF7D;
  return ((d.year - 1980) << 25) |
      (d.month << 21) |
      (d.day << 16) |
      (d.hour << 11) |
      (d.minute << 5) |
      (d.second >> 1);
}

// Code page 437, bytes 0x80 to 0xFF.
const String _kCp437High =
    '\u00C7\u00FC\u00E9\u00E2\u00E4\u00E0\u00E5\u00E7\u00EA\u00EB\u00E8'
    '\u00EF\u00EE\u00EC\u00C4\u00C5\u00C9\u00E6\u00C6\u00F4\u00F6\u00F2'
    '\u00FB\u00F9\u00FF\u00D6\u00DC\u00A2\u00A3\u00A5\u20A7\u0192\u00E1'
    '\u00ED\u00F3\u00FA\u00F1\u00D1\u00AA\u00BA\u00BF\u2310\u00AC\u00BD'
    '\u00BC\u00A1\u00AB\u00BB\u2591\u2592\u2593\u2502\u2524\u2561\u2562'
    '\u2556\u2555\u2563\u2551\u2557\u255D\u255C\u255B\u2510\u2514\u2534'
    '\u252C\u251C\u2500\u253C\u255E\u255F\u255A\u2554\u2569\u2566\u2560'
    '\u2550\u256C\u2567\u2568\u2564\u2565\u2559\u2558\u2552\u2553\u256B'
    '\u256A\u2518\u250C\u2588\u2584\u258C\u2590\u2580\u03B1\u00DF\u0393'
    '\u03C0\u03A3\u03C3\u00B5\u03C4\u03A6\u0398\u03A9\u03B4\u221E\u03C6'
    '\u03B5\u2229\u2261\u00B1\u2265\u2264\u2320\u2321\u00F7\u2248\u00B0'
    '\u2219\u00B7\u221A\u207F\u00B2\u25A0\u00A0';

/// Name code pages of -mcp and the decoding of names without the UTF-8
/// flag.
abstract final class ZipCodePage {
  /// Not set: names are read as UTF-8 (as 7-Zip does with a UTF-8
  /// locale), on Windows as code page 437 (the OEM code page).
  static const auto = -1;
  static const oem437 = 437;
  static const latin1 = 28591;
  static const ansi1252 = 1252;
  static const utf8 = 65001;
}

/// Decodes a name or comment stored without the UTF-8 flag.
String decodeZipString(Uint8List b, int codePage) {
  var ascii = true;
  for (final c in b) {
    if (c >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) return String.fromCharCodes(b);
  switch (codePage) {
    case ZipCodePage.utf8:
      return utf8.decode(b, allowMalformed: true);
    case ZipCodePage.latin1:
    case ZipCodePage.ansi1252:
      return latin1.decode(b);
    case ZipCodePage.oem437:
      return _cp437(b);
  }
  if (Platform.isWindows) return _cp437(b);
  return utf8.decode(b, allowMalformed: true);
}

String _cp437(Uint8List b) {
  final sb = StringBuffer();
  for (final c in b) {
    sb.writeCharCode(c < 0x80 ? c : _kCp437High.codeUnitAt(c - 0x80));
  }
  return sb.toString();
}

/// Encodes [s] in code page 437; null when a character has no mapping.
Uint8List? encodeCp437(String s) {
  final out = Uint8List(s.length);
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x80) {
      out[i] = c;
      continue;
    }
    final k = _kCp437High.indexOf(String.fromCharCode(c));
    if (k < 0) return null;
    out[i] = 0x80 + k;
  }
  return out;
}

/// A zip item: the fields of a central directory record (or of a local
/// header when the archive is read without its central directory) and
/// what the handler takes from the extra fields.
class ZipItem {
  int versionMadeBy = 0;
  int versionNeeded = 0;
  int flags = 0;
  int method = 0;

  /// DOS date (high 16 bits) and time (low 16 bits).
  int dosTime = 0;
  int crc = 0;
  int packSize = 0;
  int size = 0;
  Uint8List nameBytes = Uint8List(0);
  String name = '';
  Uint8List centralExtra = Uint8List(0);
  Uint8List localExtra = Uint8List(0);
  Uint8List comment = Uint8List(0);
  int disk = 0;
  int internalAttr = 0;
  int externalAttr = 0;

  /// Offset of the local header on its volume, as stored.
  int localOffset = 0;

  /// Position of the local header in the handler's stream.
  int localPos = 0;

  /// Position of the item data in the handler's stream, -1 until the local
  /// header was read.
  int dataPos = -1;

  /// Set when the item comes from the central directory.
  bool fromCentral = true;

  /// Local header problems: its signature or fields do not match.
  bool localError = false;

  /// Set when the item data ends before its declared size.
  bool truncated = false;

  /// The data descriptor that follows the data (size in bytes, 0 if none).
  int descriptorSize = 0;

  // from the extra fields
  bool zip64 = false;
  int? ntfsMTime;
  int? ntfsATime;
  int? ntfsCTime;
  int? utMTime;
  int? utATime;
  int? utCTime;
  int utFlags = 0;
  int utNumTimes = 0;
  int? uid;
  int? gid;
  String? unicodePath;
  bool unicodePathBad = false;
  int aesStrength = 0;
  int aesVendorVersion = 0;
  int aesMethod = 0;
  bool extraError = false;

  int get hostOS => versionMadeBy >> 8;
  bool get isEncrypted => (flags & ZipFlags.encrypted) != 0;
  bool get hasDescriptor => (flags & ZipFlags.descriptor) != 0;
  bool get isUtf8 => (flags & ZipFlags.utf8) != 0;
  bool get isAes => method == ZipMethod.aes && aesStrength != 0;

  /// The method of the data under the encryption.
  int get realMethod => method == ZipMethod.aes ? aesMethod : method;

  /// The POSIX mode from the external attributes (Unix like hosts), or
  /// null.
  int? get posixMode {
    final h = hostOS;
    final hi = externalAttr >> 16;
    if ((hi & 0xF000) == 0) return null;
    if (h == ZipHost.unix || h == ZipHost.osx || h == 1 || h == 16) {
      return hi;
    }
    // other hosts with the Unix extension bit (7-Zip on Windows)
    if ((externalAttr & 0x8000) != 0) return hi;
    return null;
  }

  bool get _isFatLike {
    final h = hostOS;
    return h == ZipHost.fat ||
        h == ZipHost.ntfs ||
        h == ZipHost.vfat ||
        h == ZipHost.hpfs;
  }

  /// The name with '/' separators.
  String get path {
    var s = unicodePath ?? name;
    if (_isFatLike) s = s.replaceAll('\\', '/');
    return s;
  }

  bool get isDir {
    final n = nameBytes;
    if (n.isNotEmpty) {
      final c = n[n.length - 1];
      if (c == 0x2F) return true;
      if (c == 0x5C && _isFatLike) return true;
    }
    final m = posixMode;
    if (m != null) return (m & 0xF000) == 0x4000;
    if (_isFatLike || (externalAttr & 0x8000) != 0) {
      return (externalAttr & 0x10) != 0;
    }
    return false;
  }

  bool get isSymLink {
    final m = posixMode;
    return m != null && (m & 0xF000) == 0xA000;
  }

  /// Parses the extra fields of [extra] (central or local). Unknown ids
  /// are skipped; a malformed block sets [extraError].
  void parseExtra(Uint8List extra, bool isLocal) {
    var p = 0;
    while (p + 4 <= extra.length) {
      final id = extra[p] | (extra[p + 1] << 8);
      final sz = extra[p + 2] | (extra[p + 3] << 8);
      p += 4;
      if (p + sz > extra.length) {
        extraError = true;
        return;
      }
      _parseBlock(id, extra, p, sz, isLocal);
      p += sz;
    }
    if (p != extra.length) {
      // trailing bytes shorter than a block header (padding)
      for (var i = p; i < extra.length; i++) {
        if (extra[i] != 0) {
          extraError = true;
          break;
        }
      }
    }
  }

  void _parseBlock(int id, Uint8List b, int p, int sz, bool isLocal) {
    final end = p + sz;
    switch (id) {
      case ZipExtraId.zip64:
        zip64 = true;
        // the fields are present only for the header values that are
        // 0xFFFFFFFF (0xFFFF for the disk), in this order; a local header
        // has both sizes
        if (isLocal) {
          if ((size == 0xFFFFFFFF || packSize == 0xFFFFFFFF) && sz >= 16) {
            size = getUint64LE(b, p);
            packSize = getUint64LE(b, p + 8);
          }
          return;
        }
        if (size == 0xFFFFFFFF) {
          if (p + 8 > end) return;
          size = getUint64LE(b, p);
          p += 8;
        }
        if (packSize == 0xFFFFFFFF) {
          if (p + 8 > end) return;
          packSize = getUint64LE(b, p);
          p += 8;
        }
        if (localOffset == 0xFFFFFFFF) {
          if (p + 8 > end) return;
          localOffset = getUint64LE(b, p);
          p += 8;
        }
        if (disk == 0xFFFF) {
          if (p + 4 > end) return;
          disk = getUint32LE(b, p);
        }
      case ZipExtraId.ntfs:
        p += 4; // reserved
        while (p + 4 <= end) {
          final tag = b[p] | (b[p + 1] << 8);
          final tsz = b[p + 2] | (b[p + 3] << 8);
          p += 4;
          if (p + tsz > end) {
            extraError = true;
            return;
          }
          if (tag == 1 && tsz >= 24) {
            ntfsMTime = _ft(getUint64LE(b, p));
            ntfsATime = _ft(getUint64LE(b, p + 8));
            ntfsCTime = _ft(getUint64LE(b, p + 16));
          }
          p += tsz;
        }
      case ZipExtraId.extTime:
        if (sz < 1) return;
        final f = b[p++];
        utFlags = f;
        var n = 0;
        if ((f & 1) != 0 && p + 4 <= end) {
          utMTime = _s32(b, p);
          p += 4;
          n++;
        }
        if ((f & 2) != 0 && p + 4 <= end) {
          utATime = _s32(b, p);
          p += 4;
          n++;
        }
        if ((f & 4) != 0 && p + 4 <= end) {
          utCTime = _s32(b, p);
          p += 4;
          n++;
        }
        utNumTimes = n;
      case ZipExtraId.pkwareUnix:
        // atime, mtime, uid, gid, then link data
        if (sz >= 8) {
          utATime ??= _s32(b, p);
          utMTime ??= _s32(b, p + 4);
        }
        if (sz >= 12) {
          uid ??= b[p + 8] | (b[p + 9] << 8);
          gid ??= b[p + 10] | (b[p + 11] << 8);
        }
      case ZipExtraId.unixOld:
        if (sz >= 8) {
          utATime ??= _s32(b, p);
          utMTime ??= _s32(b, p + 4);
        }
        if (sz >= 12) {
          uid ??= b[p + 8] | (b[p + 9] << 8);
          gid ??= b[p + 10] | (b[p + 11] << 8);
        }
      case ZipExtraId.unixIds:
        if (sz < 1 || b[p] != 1) return;
        p++;
        if (p >= end) return;
        final us = b[p++];
        if (p + us > end) return;
        uid = _le(b, p, us);
        p += us;
        if (p >= end) return;
        final gs = b[p++];
        if (p + gs > end) return;
        gid = _le(b, p, gs);
      case ZipExtraId.unicodePath:
        if (sz < 5 || b[p] != 1) return;
        final crc = getUint32LE(b, p + 1);
        if (crc != _crc32(nameBytes)) {
          unicodePathBad = true;
          extraError = true;
          return;
        }
        try {
          unicodePath = utf8.decode(Uint8List.sublistView(b, p + 5, end));
        } on FormatException {
          unicodePathBad = true;
        }
      case ZipExtraId.aes:
        if (sz < 7) return;
        aesVendorVersion = b[p] | (b[p + 1] << 8);
        if (b[p + 2] != 0x41 || b[p + 3] != 0x45) return;
        aesStrength = b[p + 4];
        aesMethod = b[p + 5] | (b[p + 6] << 8);
    }
  }

  static int? _ft(int v) => v == 0 ? null : v;

  static int _s32(Uint8List b, int p) {
    final v = getUint32LE(b, p);
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  static int _le(Uint8List b, int p, int n) {
    var v = 0;
    for (var i = n - 1; i >= 0; i--) {
      v = (v << 8) | b[p + i];
    }
    return v;
  }

  /// The modification time as FILETIME: NTFS, then the extended
  /// timestamp, then the DOS time.
  int? get mTime {
    if (ntfsMTime != null) return ntfsMTime;
    if (utMTime != null) return unixToFileTime(utMTime!);
    return dosTimeToFileTime(dosTime);
  }

  int? get aTime {
    if (ntfsATime != null) return ntfsATime;
    if (utATime != null) return unixToFileTime(utATime!);
    return null;
  }

  int? get cTime {
    if (ntfsCTime != null) return ntfsCTime;
    if (utCTime != null) return unixToFileTime(utCTime!);
    return null;
  }

  /// The characteristics string of 7-Zip's listing: the extra fields,
  /// then the flags.
  String characts() {
    final t = <String>[];
    if (!fromCentral) t.add('Local');
    if (extraError) t.add('Extra_ERROR');
    final ex = fromCentral ? centralExtra : localExtra;
    var p = 0;
    while (p + 4 <= ex.length) {
      final id = ex[p] | (ex[p + 1] << 8);
      final sz = ex[p + 2] | (ex[p + 3] << 8);
      if (p + 4 + sz > ex.length) break;
      switch (id) {
        case ZipExtraId.zip64:
          t.insert(0, 'Zip64');
        case ZipExtraId.ntfs:
          t.add('NTFS');
        case ZipExtraId.pkwareUnix:
          t.add('UNIX');
        case ZipExtraId.extTime:
          var s = 'UT';
          if (sz >= 1) {
            final f = ex[p + 4];
            s += ':';
            if ((f & 1) != 0) s += 'M';
            if ((f & 2) != 0) s += 'A';
            if ((f & 4) != 0) s += 'C';
            s += ':${(sz - 1) ~/ 4}';
          }
          t.add(s);
        case ZipExtraId.unixIds:
          t.add('ux');
        case ZipExtraId.unixOld:
          t.add('UX');
        case ZipExtraId.unicodePath:
          t.add('up');
        case ZipExtraId.unicodeComment:
          t.add('uc');
        case ZipExtraId.aes:
          t.add('WzAES');
        case ZipExtraId.strongEncryption:
          t.add('StrongCrypto');
        default:
          t.add('0x${id.toRadixString(16).toUpperCase().padLeft(4, '0')}');
      }
      p += 4 + sz;
    }
    final f = <String>[];
    if ((flags & ZipFlags.encrypted) != 0) f.add('Encrypt');
    if ((flags & ZipFlags.descriptor) != 0) f.add('Descriptor');
    if ((flags & ZipFlags.strongEncryption) != 0) f.add('StrongCrypto');
    if ((flags & ZipFlags.utf8) != 0) f.add('UTF8');
    if ((flags & ZipFlags.maskedHeaders) != 0) f.add('MaskedHeaders');
    if (f.isNotEmpty) {
      if (t.isNotEmpty) t.add(':');
      t.addAll(f);
    }
    return t.join(' ');
  }
}

int _crc32(Uint8List b) {
  var c = 0xFFFFFFFF;
  for (final x in b) {
    c ^= x;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

/// The method name of 7-Zip's listing for [m] (without properties).
String zipMethodName(int m) {
  switch (m) {
    case ZipMethod.store:
      return 'Store';
    case ZipMethod.shrink:
      return 'Shrink';
    case 2:
    case 3:
    case 4:
    case 5:
      return 'Reduce${m - 1}';
    case ZipMethod.implode:
      return 'Implode';
    case ZipMethod.tokenize:
      return 'Tokenize';
    case ZipMethod.deflate:
      return 'Deflate';
    case ZipMethod.deflate64:
      return 'Deflate64';
    case ZipMethod.pkImplode:
      return 'PKImploding';
    case ZipMethod.bzip2:
      return 'BZip2';
    case ZipMethod.lzma:
      return 'LZMA';
    case ZipMethod.terse:
      return 'Terse';
    case ZipMethod.lz77:
      return 'LZ77';
    case ZipMethod.zstdOld:
    case ZipMethod.zstd:
      return 'ZSTD';
    case ZipMethod.mp3:
      return 'MP3';
    case ZipMethod.xz:
      return 'xz';
    case ZipMethod.jpeg:
      return 'Jpeg';
    case ZipMethod.wavPack:
      return 'WavPack';
    case ZipMethod.ppmd:
      return 'PPMd';
    case ZipMethod.aes:
      return 'WzAES';
  }
  return '$m';
}
