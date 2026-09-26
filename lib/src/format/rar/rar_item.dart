// The items of RAR archives (RAR 1.5 to 4.x and RAR5), shared by the two
// header readers (rar4_in.dart, rar5_in.dart) and the handler.

import 'dart:typed_data';

/// One piece of an item's packed data in one volume.
final class RarPart {
  /// Index of the volume ([RarArchiveData.volumes]).
  final int volume;

  /// Offset of the header of this piece in its volume.
  final int headerPos;

  /// Size of the header (and, for encrypted RAR5 headers, its padding).
  final int headerSize;

  /// Offset of the packed data in its volume.
  final int dataPos;
  final int packSize;

  RarPart(this.volume, this.headerPos, this.headerSize, this.dataPos,
      this.packSize);
}

/// RAR5 encryption parameters of a file (the file encryption record) or of
/// the headers (the archive encryption header).
final class Rar5CryptInfo {
  int version = 0;
  int flags = 0;
  int kdfCount = 0;
  final Uint8List salt = Uint8List(16);
  final Uint8List iv = Uint8List(16);

  /// The 12 byte check value, or null.
  Uint8List? check;

  bool get hasCheck => (flags & 1) != 0;
  bool get tweakedChecksums => (flags & 2) != 0;
}

/// Redirection types of the RAR5 file system redirection record.
abstract final class RarRedir {
  static const none = 0;
  static const unixSymlink = 1;
  static const winSymlink = 2;
  static const junction = 3;
  static const hardLink = 4;
  static const fileCopy = 5;
}

/// A file or directory of the archive.
final class RarItem {
  bool isRar5 = true;
  String name = '';
  bool isDir = false;

  /// The unpacked size (for links of RAR4 the target length).
  int size = 0;
  bool sizeUnknown = false;

  /// The raw attributes field.
  int attrib = 0;

  /// RAR4: 0 MS DOS, 1 OS/2, 2 Win32, 3 Unix, 4 Mac OS, 5 BeOS.
  /// RAR5: 0 Windows, 1 Unix.
  int hostOS = 0;

  /// FILETIME values (100 ns since 1601), null when missing.
  int? mTime;
  int? cTime;
  int? aTime;

  /// True when the times are stored as Unix times (RAR5), for the
  /// precision.
  bool unixTime = false;
  bool unixTimeNs = false;

  int? crc;

  /// BLAKE2sp digest (RAR5 hash record).
  Uint8List? blake2;

  /// Compression method: 0 store ... 5 best.
  int method = 0;

  /// RAR5: compression algorithm version (0 or 1). RAR4: the unpack
  /// version (15, 20, 26, 29, 36).
  int algoVersion = 0;

  /// Dictionary size in bytes.
  int dictSize = 0;

  /// The data continues the solid stream of the preceding file.
  bool solid = false;

  bool encrypted = false;
  Rar5CryptInfo? crypt;

  /// RAR4 salt (FHD_SALT).
  Uint8List? salt;

  /// Redirection (RAR5), [RarRedir].
  int redirType = RarRedir.none;
  int redirFlags = 0;
  String? linkTarget;

  bool splitBefore = false;
  bool splitAfter = false;
  final List<RarPart> parts = [];

  /// RAR4: FHD_COMMENT; RAR5 file version (-ver).
  bool commented = false;
  int fileVersion = -1;

  String? user;
  String? group;
  int? uid;
  int? gid;

  /// RAR4 FHD_UNICODE.
  bool unicodeName = false;

  /// RAR4 header flags, RAR5 file flags (for Characteristics).
  int flags = 0;

  /// Raw extra area of the RAR5 header (copied on update).
  Uint8List? extra;

  /// RAR5: the raw compression information field.
  int compInfo = 0;

  /// RAR5: the Unix mtime field of the file header (file flag 0x0002).
  int? mTimeUnix;

  int get packSize {
    var n = 0;
    for (final p in parts) {
      n += p.packSize;
    }
    return n;
  }

  bool get isSymLink =>
      redirType == RarRedir.unixSymlink ||
      redirType == RarRedir.winSymlink ||
      redirType == RarRedir.junction ||
      (!isRar5 && hostOS == 3 && (attrib & 0xF000) == 0xA000);

  /// The POSIX mode for Unix items, or null.
  int? get posixMode {
    if (isRar5 ? hostOS == 1 : hostOS == 3) return attrib & 0xFFFF;
    return null;
  }
}

/// Converts Unix seconds and nanoseconds to FILETIME.
int unixToFileTime(int sec, [int ns = 0]) =>
    (sec + 11644473600) * 10000000 + ns ~/ 100;

/// Converts FILETIME to (Unix seconds, nanoseconds).
(int, int) fileTimeToUnix(int ft) {
  final t = ft - 116444736000000000;
  final sec = t ~/ 10000000;
  var rem = t - sec * 10000000;
  var s = sec;
  if (rem < 0) {
    rem += 10000000;
    s -= 1;
  }
  return (s, rem * 100);
}

/// A little endian reader over a header buffer with RAR5 vints.
final class RarHeaderReader {
  final Uint8List b;
  int pos;
  final int end;
  RarHeaderReader(this.b, this.pos, this.end);

  bool get atEnd => pos >= end;
  int get left => end - pos;

  Never _bad() => throw const RarHeaderError();

  int byte() {
    if (pos >= end) _bad();
    return b[pos++];
  }

  int u16() {
    if (pos + 2 > end) _bad();
    final v = b[pos] | (b[pos + 1] << 8);
    pos += 2;
    return v;
  }

  int u32() {
    if (pos + 4 > end) _bad();
    final v =
        b[pos] | (b[pos + 1] << 8) | (b[pos + 2] << 16) | (b[pos + 3] << 24);
    pos += 4;
    return v;
  }

  int u64() {
    final lo = u32();
    final hi = u32();
    return lo | (hi << 32);
  }

  /// A RAR5 vint (up to 10 bytes, 64 bits).
  int vint() {
    var r = 0;
    for (var i = 0; i < 10; i++) {
      final c = byte();
      if (i < 9) {
        r |= (c & 0x7F) << (7 * i);
      } else {
        r |= (c & 1) << 63;
      }
      if ((c & 0x80) == 0) return r;
    }
    _bad();
  }

  Uint8List bytes(int n) {
    if (n < 0 || pos + n > end) _bad();
    final r = Uint8List.fromList(Uint8List.sublistView(b, pos, pos + n));
    pos += n;
    return r;
  }

  void skip(int n) {
    if (n < 0 || pos + n > end) _bad();
    pos += n;
  }
}

/// A malformed header field.
final class RarHeaderError implements Exception {
  const RarHeaderError();
}

/// Writes a RAR5 vint into [out].
void writeVint(BytesBuilder out, int v) {
  while (true) {
    final c = v & 0x7F;
    v = (v >> 7) & 0x01FFFFFFFFFFFFFF;
    if (v == 0) {
      out.addByte(c);
      return;
    }
    out.addByte(c | 0x80);
  }
}

/// The number of bytes of the vint of [v].
int vintSize(int v) {
  var n = 1;
  v = (v >> 7) & 0x01FFFFFFFFFFFFFF;
  while (v != 0) {
    n++;
    v >>= 7;
  }
  return n;
}
