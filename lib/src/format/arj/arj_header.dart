// ARJ headers: the main header and the local file headers, read and
// written from the ARJ technote (ARJ TECHNICAL INFORMATION, April 1993) and
// the fields ARJ 3.x adds to the local header (the extended file position,
// access and creation times and the original size of a volume part, which
// make first_hdr_size 46).
//
// Every header is: 0x60 0xEA, the basic header size (0 at the end of the
// archive, at most 2600), the basic header, its CRC-32, then extended
// headers (size, data, CRC-32) up to a zero size.

import 'dart:convert';
import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc.dart';
import '../lha/dos_time.dart';

/// The header id.
const int kArjHeaderId0 = 0x60;
const int kArjHeaderId1 = 0xEA;

/// The largest basic header.
const int kArjMaxHeaderSize = 2600;

/// Host OS numbers.
abstract final class ArjHostOs {
  static const msdos = 0;
  static const unix = 2;
  static const next = 8;
  static const names = [
    'MS-DOS', 'PRIMOS', 'UNIX', 'AMIGA', 'MAC-OS', 'OS/2', 'APPLE GS', //
    'ATARI ST', 'NEXT', 'VAX VMS', 'WIN95', 'WIN32',
  ];
}

/// arj flags.
abstract final class ArjFlags {
  static const garbled = 0x01;
  static const oldSecured = 0x02;
  static const volume = 0x04;
  static const extFile = 0x08;
  static const pathSym = 0x10;
  static const backup = 0x20;
  static const secured = 0x40;
}

/// File types.
abstract final class ArjFileType {
  static const binary = 0;
  static const text = 1;
  static const comment = 2;
  static const directory = 3;
  static const volumeLabel = 4;
  static const chapter = 5;
  static const unixSpecial = 6;
}

/// One header as read: its position, basic header bytes and extended
/// headers.
class ArjRawHeader {
  int pos = 0;

  /// The basic header (first_hdr_size to the comment).
  Uint8List basic = Uint8List(0);

  /// Extended headers (data only).
  final List<Uint8List> ext = [];

  /// The position after the header and its extended headers.
  int end = 0;
}

/// The result of [readArjHeader].
enum ArjHeaderResult { header, end, unexpectedEnd, bad }

/// Reads the header at [pos].
ArjHeaderResult readArjHeader(SeekableInStream s, int pos, ArjRawHeader h) {
  h.pos = pos;
  h.ext.clear();
  final len = s.length;
  final b4 = Uint8List(4);
  if (pos + 4 > len) return ArjHeaderResult.unexpectedEnd;
  s.position = pos;
  readExactly(s, b4, 0, 4);
  if (b4[0] != kArjHeaderId0 || b4[1] != kArjHeaderId1) {
    return ArjHeaderResult.bad;
  }
  final size = b4[2] | (b4[3] << 8);
  if (size == 0) {
    h.end = pos + 4;
    return ArjHeaderResult.end;
  }
  if (size > kArjMaxHeaderSize) return ArjHeaderResult.bad;
  if (pos + 4 + size + 4 > len) return ArjHeaderResult.unexpectedEnd;
  final basic = Uint8List(size);
  readExactly(s, basic, 0, size);
  readExactly(s, b4, 0, 4);
  if (Crc32.of(basic) != getUint32LE(b4, 0)) return ArjHeaderResult.bad;
  h.basic = basic;
  var p = pos + 4 + size + 4;
  for (;;) {
    if (p + 2 > len) return ArjHeaderResult.unexpectedEnd;
    final b2 = Uint8List(2);
    s.position = p;
    readExactly(s, b2, 0, 2);
    final extSize = b2[0] | (b2[1] << 8);
    p += 2;
    if (extSize == 0) break;
    if (p + extSize + 4 > len) return ArjHeaderResult.unexpectedEnd;
    final e = Uint8List(extSize);
    readExactly(s, e, 0, extSize);
    readExactly(s, b4, 0, 4);
    if (Crc32.of(e) != getUint32LE(b4, 0)) return ArjHeaderResult.bad;
    h.ext.add(e);
    p += extSize + 4;
  }
  h.end = p;
  return ArjHeaderResult.header;
}

/// The null terminated string at [off] of [b] and the offset after it.
(Uint8List, int) _cString(Uint8List b, int off) {
  var e = off;
  while (e < b.length && b[e] != 0) {
    e++;
  }
  return (Uint8List.sublistView(b, off, e), e < b.length ? e + 1 : e);
}

/// Names are UTF-8 when valid, else Latin-1 (the code page is not known).
String decodeArjName(Uint8List b) {
  try {
    return utf8.decode(b);
  } on FormatException {
    return latin1.decode(b);
  }
}

/// The fields shared by the main and the local headers.
class ArjHeaderBase {
  int firstHdrSize = 0;
  int version = 0;
  int minVersion = 0;
  int hostOs = 0;
  int flags = 0;
  Uint8List nameBytes = Uint8List(0);
  Uint8List commentBytes = Uint8List(0);

  String get name {
    var s = decodeArjName(nameBytes);
    if ((flags & ArjFlags.pathSym) == 0) s = s.replaceAll('\\', '/');
    return s;
  }

  String get comment => decodeArjName(commentBytes);

  /// Times are Unix seconds in archives of ARJ 3.x (version 11) for UNIX,
  /// MS-DOS times otherwise.
  bool get unixTimes =>
      version >= 11 && (hostOs == ArjHostOs.unix || hostOs == ArjHostOs.next);

  int? timeToFileTime(int t) {
    if (unixTimes) return unixTimeToFileTime(t);
    return dosTimeToFileTime(t);
  }

  String get hostOsName =>
      hostOs < ArjHostOs.names.length ? ArjHostOs.names[hostOs] : '$hostOs';
}

/// The main header.
class ArjMainHeader extends ArjHeaderBase {
  int securityVersion = 0;
  int fileType = 2;
  int cTimeRaw = 0;
  int mTimeRaw = 0;
  int archiveSize = 0;

  /// Parses the basic header of the main header; false when too short.
  bool parse(Uint8List b) {
    if (b.length < 30 || b[0] < 30 || b[0] > b.length) return false;
    firstHdrSize = b[0];
    version = b[1];
    minVersion = b[2];
    hostOs = b[3];
    flags = b[4];
    securityVersion = b[5];
    fileType = b[6];
    cTimeRaw = getUint32LE(b, 8);
    mTimeRaw = getUint32LE(b, 12);
    archiveSize = getUint32LE(b, 16);
    final (n, p) = _cString(b, firstHdrSize);
    nameBytes = Uint8List.fromList(n);
    commentBytes = Uint8List.fromList(_cString(b, p).$1);
    return true;
  }
}

/// A local file header and the position of its data.
class ArjItem extends ArjHeaderBase {
  int headerPos = 0;
  int dataPos = 0;
  int method = 0;
  int fileType = 0;
  int passwordModifier = 0;
  int mTimeRaw = 0;
  int packSize = 0;
  int size = 0;
  int crc = 0;
  int filespecPos = 0;
  int fileMode = 0;
  int hostData = 0;
  int extFilePos = 0;
  int aTimeRaw = 0;
  int cTimeRaw = 0;
  bool hasATime = false;
  bool hasCTime = false;
  List<Uint8List> ext = const [];
  bool truncated = false;

  int get endPos => dataPos + packSize;

  bool get isDir => fileType == ArjFileType.directory;
  bool get isEncrypted => (flags & ArjFlags.garbled) != 0;
  bool get splitAfter => (flags & ArjFlags.volume) != 0;
  bool get splitBefore => (flags & ArjFlags.extFile) != 0;

  /// Parses a local basic header; false when too short.
  bool parse(Uint8List b) {
    if (b.length < 30 || b[0] < 30 || b[0] > b.length) return false;
    firstHdrSize = b[0];
    version = b[1];
    minVersion = b[2];
    hostOs = b[3];
    flags = b[4];
    method = b[5];
    fileType = b[6];
    passwordModifier = b[7];
    mTimeRaw = getUint32LE(b, 8);
    packSize = getUint32LE(b, 12);
    size = getUint32LE(b, 16);
    crc = getUint32LE(b, 20);
    filespecPos = b[24] | (b[25] << 8);
    fileMode = b[26] | (b[27] << 8);
    hostData = b[28] | (b[29] << 8);
    if (firstHdrSize >= 34) extFilePos = getUint32LE(b, 30);
    if (firstHdrSize >= 42) {
      aTimeRaw = getUint32LE(b, 34);
      cTimeRaw = getUint32LE(b, 38);
      hasATime = aTimeRaw != 0;
      hasCTime = cTimeRaw != 0;
    }
    final (n, p) = _cString(b, firstHdrSize);
    nameBytes = Uint8List.fromList(n);
    commentBytes = Uint8List.fromList(_cString(b, p).$1);
    return true;
  }
}

// ---------------------------------------------------------------------------
// Writing

void _p16(Uint8List b, int o, int v) {
  b[o] = v & 0xFF;
  b[o + 1] = (v >> 8) & 0xFF;
}

/// A complete header: id, size, [basic], its CRC-32 and no extended
/// headers.
Uint8List frameArjHeader(Uint8List basic) {
  final h = Uint8List(4 + basic.length + 4 + 2);
  h[0] = kArjHeaderId0;
  h[1] = kArjHeaderId1;
  _p16(h, 2, basic.length);
  h.setRange(4, 4 + basic.length, basic);
  setUint32LE(h, 4 + basic.length, Crc32.of(basic));
  return h;
}

/// The end of archive header.
Uint8List arjEndHeader() =>
    Uint8List.fromList(const [kArjHeaderId0, kArjHeaderId1, 0, 0]);

Uint8List _withStrings(Uint8List fixed, List<int> name, List<int> comment) {
  final b = Uint8List(fixed.length + name.length + 1 + comment.length + 1);
  b.setRange(0, fixed.length, fixed);
  b.setRange(fixed.length, fixed.length + name.length, name);
  final c = fixed.length + name.length + 1;
  b.setRange(c, c + comment.length, comment);
  if (b.length > kArjMaxHeaderSize) {
    throw const SevenZipException('arj: the name is too long');
  }
  return b;
}

/// The main header ARJ 3.x writes in its MS-DOS compatible mode: version
/// 11, host [hostOs], PATHSYM, file type 2.
Uint8List buildArjMainHeader(
    {required int cTime,
    required int mTime,
    List<int> name = const [],
    List<int> comment = const [],
    int hostOs = ArjHostOs.msdos}) {
  final f = Uint8List(34);
  f[0] = 34; // first_hdr_size
  f[1] = 11; // archiver version
  f[2] = 1; // minimum version to extract
  f[3] = hostOs;
  f[4] = ArjFlags.pathSym;
  f[5] = 0; // security version
  f[6] = ArjFileType.comment;
  setUint32LE(f, 8, cTime);
  setUint32LE(f, 12, mTime);
  return frameArjHeader(_withStrings(f, name, comment));
}

/// The fields of a local header to write.
class ArjOutItem {
  /// '/' separated path.
  String path;
  bool isDir;
  int method = 1;
  int hostOs = ArjHostOs.msdos;
  int mTime = 0;
  int aTime = 0;
  int cTime = 0;
  int packSize = 0;
  int size = 0;
  int crc = 0;
  int fileMode = 0x20;
  int fileType = ArjFileType.binary;
  List<int> comment = const [];
  ArjOutItem(this.path, {this.isDir = false});
}

/// A local header as ARJ 3.x writes it (first_hdr_size 46).
Uint8List buildArjLocalHeader(ArjOutItem it) {
  final name = utf8.encode(it.path);
  final f = Uint8List(46);
  f[0] = 46;
  f[1] = 11;
  f[2] = it.isDir ? 3 : 1;
  f[3] = it.hostOs;
  f[4] = ArjFlags.pathSym;
  f[5] = it.isDir ? 0 : it.method;
  f[6] = it.isDir ? ArjFileType.directory : it.fileType;
  f[7] = 0;
  setUint32LE(f, 8, it.mTime);
  setUint32LE(f, 12, it.packSize);
  setUint32LE(f, 16, it.size);
  setUint32LE(f, 20, it.crc);
  _p16(f, 24, name.lastIndexOf(0x2F) + 1); // filespec position
  _p16(f, 26, it.fileMode);
  _p16(f, 28, 0);
  setUint32LE(f, 30, 0);
  setUint32LE(f, 34, it.aTime);
  setUint32LE(f, 38, it.cTime);
  setUint32LE(f, 42, 0);
  return frameArjHeader(_withStrings(f, name, it.comment));
}
