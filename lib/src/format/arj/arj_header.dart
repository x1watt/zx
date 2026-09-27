// ARJ headers: the main header and the local file headers, read and
// written from the ARJ technote (ARJ TECHNICAL INFORMATION, April 1993) and
// the fields ARJ 3.x adds to the local header (the extended file position,
// access and creation times and the original size of a volume part, which
// make first_hdr_size 46).
//
// Every header is: 0x60 0xEA, the basic header size (0 at the end of the
// archive, at most 2600), the basic header, its CRC-32, then extended
// headers (size, data, CRC-32) up to a zero size.
//
// Two things the technote does not describe were found by black box
// experiments with ARJ32 3.10 (archives of chosen inputs, compared field by
// field; no ARJ source was read):
//
// - Garbling (-g<password>, GARBLED_FLAG): the packed data of each file (of
//   each volume part) is XORed with the key stream
//   (password[i % length] + password modifier) & 0xFF, i counting from 0 at
//   the first data byte. The password is the bytes given on the command
//   line, whole and case kept; the password modifier is byte 7 of the local
//   header (ARJ writes the low byte of the archive creation time there, in
//   every archive). The main header gets GARBLED_FLAG and 1 in byte 28
//   (the encryption version; 2 is the 40 bit GOST cipher of -hg!, which
//   needs ARJCRYPT and is not supported). No check value is stored: a wrong
//   password shows as a CRC (or data) error.
// - UNIX special files (-a1: file type 6, host UNIX): the mode has 0x4000
//   in its type bits (0x1000 is a regular file, 0x2000 a directory) and an
//   extended header 'U', 0, then one byte (type << 5 | length), where
//   length 31 means that a 16-bit length follows, then the data. Types seen:
//   0 a FIFO (no data), 1 a hard link (the archived path of the file it
//   links to), 2 a symbolic link (the target).

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

/// The encryption version of garbled archives in the main header (byte 28):
/// the XOR garbling; 2 and above are the ARJCRYPT ciphers.
const int kArjOldGarble = 1;

/// The type bits of the UNIX file mode ARJ stores.
abstract final class ArjUnixMode {
  static const regular = 0x1000;
  static const directory = 0x2000;
  static const special = 0x4000;
}

/// The types of UNIX special files ('U' extended header).
abstract final class ArjUnixSpecial {
  static const fifo = 0;
  static const hardLink = 1;
  static const symLink = 2;
}

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

  /// Byte 28: the encryption version of garbled files ([kArjOldGarble]).
  int encryptionVersion = 0;

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
    encryptionVersion = firstHdrSize > 28 ? b[28] : 0;
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

  /// The volume that holds this header and its data (0 is the first).
  int volume = 0;

  /// The next parts of a file split over volumes (joined by the handler).
  List<ArjItem> nextParts = const [];

  int get endPos => dataPos + packSize;

  bool get isDir => fileType == ArjFileType.directory;
  bool get isEncrypted => (flags & ArjFlags.garbled) != 0;
  bool get splitAfter => (flags & ArjFlags.volume) != 0;
  bool get splitBefore => (flags & ArjFlags.extFile) != 0;

  /// The last part of the file (this item when it is not split).
  ArjItem get lastPart => nextParts.isEmpty ? this : nextParts.last;

  /// The UNIX special file of a type 6 item: its type ([ArjUnixSpecial])
  /// and data, or null.
  (int, Uint8List)? get unixSpecial {
    if (fileType != ArjFileType.unixSpecial) return null;
    for (final e in ext) {
      if (e.length < 3 || e[0] != 0x55) continue; // 'U'
      final type = e[2] >> 5;
      var len = e[2] & 0x1F;
      var off = 3;
      if (len == 0x1F) {
        if (e.length < 5) return null;
        len = e[3] | (e[4] << 8);
        off = 5;
      }
      if (off + len > e.length) return null;
      return (type, Uint8List.sublistView(e, off, off + len));
    }
    return null;
  }

  /// The target of a symbolic link item, or null.
  Uint8List? get symLinkTarget {
    final u = unixSpecial;
    return u != null && u.$1 == ArjUnixSpecial.symLink ? u.$2 : null;
  }

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

/// A complete header: id, size, [basic], its CRC-32 and the extended
/// headers [ext] (each with its size and CRC-32), then the zero size.
Uint8List frameArjHeader(Uint8List basic, [List<Uint8List> ext = const []]) {
  var extSize = 0;
  for (final e in ext) {
    extSize += 2 + e.length + 4;
  }
  final h = Uint8List(4 + basic.length + 4 + extSize + 2);
  h[0] = kArjHeaderId0;
  h[1] = kArjHeaderId1;
  _p16(h, 2, basic.length);
  h.setRange(4, 4 + basic.length, basic);
  setUint32LE(h, 4 + basic.length, Crc32.of(basic));
  var p = 4 + basic.length + 4;
  for (final e in ext) {
    _p16(h, p, e.length);
    h.setRange(p + 2, p + 2 + e.length, e);
    setUint32LE(h, p + 2 + e.length, Crc32.of(e));
    p += 2 + e.length + 4;
  }
  return h;
}

/// The 'U' extended header of a UNIX special file of [type]
/// ([ArjUnixSpecial]) with [data].
Uint8List arjUnixSpecialExt(int type, List<int> data) {
  final long = data.length >= 0x1F;
  final e = Uint8List(3 + (long ? 2 : 0) + data.length);
  e[0] = 0x55; // 'U'
  e[1] = 0;
  e[2] = (type << 5) | (long ? 0x1F : data.length);
  var off = 3;
  if (long) {
    _p16(e, 3, data.length);
    off = 5;
  }
  e.setRange(off, off + data.length, data);
  return e;
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
/// 11, host [hostOs], PATHSYM, file type 2; with [garbled], GARBLED_FLAG
/// and the encryption version of the XOR garbling.
Uint8List buildArjMainHeader(
    {required int cTime,
    required int mTime,
    List<int> name = const [],
    List<int> comment = const [],
    int hostOs = ArjHostOs.msdos,
    bool garbled = false}) {
  final f = Uint8List(34);
  f[0] = 34; // first_hdr_size
  f[1] = 11; // archiver version
  f[2] = 1; // minimum version to extract
  f[3] = hostOs;
  f[4] = ArjFlags.pathSym | (garbled ? ArjFlags.garbled : 0);
  f[28] = garbled ? kArjOldGarble : 0; // encryption version
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

  /// GARBLED_FLAG and the password modifier (byte 7).
  bool garbled = false;
  int passwordModifier = 0;

  /// Extended headers (the 'U' header of a UNIX special file).
  List<Uint8List> ext = const [];
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
  f[4] = ArjFlags.pathSym | (it.garbled ? ArjFlags.garbled : 0);
  f[5] = it.isDir ? 0 : it.method;
  f[6] = it.isDir ? ArjFileType.directory : it.fileType;
  f[7] = it.garbled ? it.passwordModifier & 0xFF : 0;
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
  return frameArjHeader(_withStrings(f, name, it.comment), it.ext);
}

/// The XOR garbling of ARJ (see the top of this file): [apply] garbles or
/// ungarbles the next bytes of one file's packed data.
class ArjGarble {
  final Uint8List _key;
  int _pos = 0;

  /// [password] as bytes; [modifier] is the password modifier of the item.
  ArjGarble(List<int> password, int modifier)
      : _key = Uint8List.fromList(
            [for (final c in password) (c + modifier) & 0xFF]) {
    if (_key.isEmpty) throw const SevenZipException('arj: empty password');
  }

  /// XORs [buf] from [off] to [end] with the key stream.
  void apply(Uint8List buf, int off, int end) {
    final key = _key;
    final n = key.length;
    var k = _pos;
    for (var i = off; i < end; i++) {
      buf[i] ^= key[k];
      if (++k == n) k = 0;
    }
    _pos = k;
  }
}

/// Ungarbles what is read from [_base].
class ArjGarbleInStream implements InStream {
  final InStream _base;
  final ArjGarble _g;
  ArjGarbleInStream(this._base, this._g);

  @override
  int read(Uint8List buf, int off, int len) {
    final n = _base.read(buf, off, len);
    if (n > 0) _g.apply(buf, off, off + n);
    return n;
  }
}

/// Garbles what is written to [_base] (the caller's buffer is not changed).
class ArjGarbleOutStream implements OutStream {
  final OutStream _base;
  final ArjGarble _g;
  final Uint8List _buf = Uint8List(1 << 16);
  ArjGarbleOutStream(this._base, this._g);

  @override
  void write(Uint8List buf, int off, int len) {
    while (len > 0) {
      final n = len < _buf.length ? len : _buf.length;
      _buf.setRange(0, n, buf, off);
      _g.apply(_buf, 0, n);
      _base.write(_buf, 0, n);
      off += n;
      len -= n;
    }
  }

  @override
  void flush() => _base.flush();
}
