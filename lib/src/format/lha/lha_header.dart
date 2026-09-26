// LHA file headers: reading levels 0 to 3 with their extended headers, and
// writing level 2 headers with Unix extensions.
//
// The reader is a port of lha_file_header.c and ext_header.c of lhasa (ISC
// license, see LICENSE), reading from a random access stream; the comment
// (0x3F) and MS-DOS attribute (0x40) extended headers follow libarchive's
// archive_read_support_format_lha.c (BSD 2-clause, see LICENSE). The
// writer produces what those readers accept, in the layout of the LHa for
// UNIX level 2 header documentation.

import 'dart:convert';
import 'dart:typed_data';

import '../../codec/lzh/crc16.dart';
import '../../io/streams.dart';
import 'dos_time.dart';

// LHA_OS_TYPE_*
abstract final class LhaOsType {
  static const unknown = 0x00;
  static const msdos = 0x4D; // 'M'
  static const unix = 0x55; // 'U'
  static const os9 = 0x39; // '9'
  static const os968k = 0x4B; // 'K'
  static const amiga = 0x41; // 'A'
  static const lhark = 0x20; // ' '
}

/// LHA_COMPRESS_TYPE_DIR
const String kLhaDirMethod = '-lhd-';

// LHA_FILE_* extra flags
const int _unixPerms = 0x01;
const int _unixUidGid = 0x02;
const int _commonCrc = 0x04;
const int _windowsTimestamps = 0x08;
const int _os9Perms = 0x10;
const int _bit64Sizes = 0x20;
const int _fakeName = 0x40;

// COMMON_HEADER_LEN, LEVEL_*_MIN_HEADER_LEN...
const int _commonHeaderLen = 22;
const int _level0MinHeaderLen = 22;
const int _level1MinHeaderLen = 25;
const int _level2HeaderLen = 26;
const int _level3HeaderLen = 32;
const int _level3MaxHeaderLen = 1024 * 1024;
const int _level0UnixExtendedLen = 12;
const int _level0Os9ExtendedLen = 22;

/// LHAFileHeader: one member of an LHA archive, with its position.
class LhaItem {
  int headerPos = 0;

  /// The header bytes (including level 1 extended headers).
  Uint8List raw = Uint8List(0);
  int get dataPos => headerPos + raw.length;
  int get endPos => dataPos + packSize;

  String method = '';
  int level = 0;
  int osType = 0;
  int crc = 0;
  int packSize = 0;
  int size = 0;

  /// Unix time, or the raw MS-DOS time of level 0 and 1 headers.
  int timestamp = 0;
  bool dosTime = false;

  /// The MS-DOS attribute byte.
  int attr = 0;

  int extraFlags = 0;
  int unixPerms = 0;
  int unixUid = 0;
  int unixGid = 0;
  int os9Perms = 0;
  String? unixUser;
  String? unixGroup;
  int commonCrc = 0;
  int winCTime = 0;
  int winMTime = 0;
  int winATime = 0;

  // path and file name bytes ('/' separators), null when absent
  Uint8List? path;
  Uint8List? filename;
  Uint8List? symlinkTarget;
  Uint8List? comment;

  bool truncated = false;

  bool get hasUnixPerms => (extraFlags & _unixPerms) != 0;
  bool get hasUidGid => (extraFlags & _unixUidGid) != 0;
  bool get hasWindowsTimes => (extraFlags & _windowsTimestamps) != 0;
  bool get fakeName => (extraFlags & _fakeName) != 0;

  bool get isDirMethod => method == kLhaDirMethod;
  bool get isSymLink => symlinkTarget != null;
  bool get isDir => isDirMethod && !isSymLink;

  /// The full path (lha_file_header_full_path), '/' separated, without a
  /// trailing '/'.
  String get fullPath {
    final b = BytesBuilder(copy: false);
    if (path != null) b.add(path!);
    if (filename != null) b.add(filename!);
    var s = decodeLhaName(b.takeBytes());
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  String? get symlinkTargetString =>
      symlinkTarget == null ? null : decodeLhaName(symlinkTarget!);

  /// The modification time as FILETIME.
  int? get mTime {
    if (hasWindowsTimes && winMTime != 0) return winMTime;
    if (dosTime) return dosTimeToFileTime(timestamp);
    return unixTimeToFileTime(timestamp);
  }

  int? get cTime => hasWindowsTimes && winCTime != 0 ? winCTime : null;
  int? get aTime => hasWindowsTimes && winATime != 0 ? winATime : null;
}

/// Names are UTF-8 when valid, else Latin-1 (the code page is not known).
String decodeLhaName(Uint8List b) {
  try {
    return utf8.decode(b);
  } on FormatException {
    return latin1.decode(b);
  }
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) => getUint32LE(b, o);
int _u64(Uint8List b, int o) => getUint64LE(b, o);

/// The result of [readLhaHeader].
enum LhaHeaderResult { item, end, eof, unexpectedEnd, bad }

/// Reads headers from a random access stream.
class LhaHeaderReader {
  final SeekableInStream s;
  LhaHeaderReader(this.s);

  // lha_input_stream_read at a position
  Uint8List? _read(int pos, int n) {
    if (pos + n > s.length) return null;
    final b = Uint8List(n);
    s.position = pos;
    if (readFully(s, b, 0, n) != n) return null;
    return b;
  }

  // extend_raw_data
  bool _extend(LhaItem h, int nbytes) {
    if (nbytes < 0 || nbytes > _level3MaxHeaderLen) return false;
    final more = _read(h.headerPos + h.raw.length, nbytes);
    if (more == null) {
      _short = true;
      return false;
    }
    final n = Uint8List(h.raw.length + nbytes);
    n.setRange(0, h.raw.length, h.raw);
    n.setRange(h.raw.length, n.length, more);
    h.raw = n;
    return true;
  }

  bool _short = false;

  // lha_file_header_read
  /// Reads the header at [pos] into [h].
  LhaHeaderResult read(int pos, LhaItem h) {
    _short = false;
    h.headerPos = pos;
    if (pos >= s.length) return LhaHeaderResult.eof;
    final first = _read(pos, 1)!;
    // a zero byte ends the archive
    if (first[0] == 0) return LhaHeaderResult.end;
    final r = _read(pos, _commonHeaderLen);
    if (r == null) return LhaHeaderResult.unexpectedEnd;
    h.raw = r;
    h.level = r[20];
    bool ok;
    switch (h.level) {
      case 0:
        ok = _decodeLevel0(h);
      case 1:
        ok = _decodeLevel1(h);
      case 2:
        ok = _decodeLevel2(h);
      case 3:
        ok = _decodeLevel3(h);
      default:
        ok = false;
    }
    if (!ok) {
      return _short ? LhaHeaderResult.unexpectedEnd : LhaHeaderResult.bad;
    }
    // Amiga directories stored as -lh0-
    if (h.osType == LhaOsType.amiga &&
        h.method == '-lh0-' &&
        h.size == 0 &&
        h.filename == null) {
      h.method = kLhaDirMethod;
    }
    if (h.method != kLhaDirMethod) {
      if (h.filename == null) {
        h.extraFlags |= _fakeName;
        h.filename = Uint8List.fromList(latin1.encode('__unknown'));
      }
    } else if (h.hasUnixPerms &&
        (h.path != null || h.filename != null) &&
        (h.unixPerms & 0xF000) == 0xA000) {
      if (!_parseSymlink(h)) return LhaHeaderResult.bad;
    }
    // a directory without a path is kept with an empty name (lhasa stops
    // the archive there, 7-Zip lists it)
    if (h.osType == LhaOsType.os968k && h.hasUnixPerms) {
      h.os9Perms = h.unixPerms;
      h.extraFlags |= _os9Perms;
    }
    if ((h.extraFlags & _os9Perms) != 0) _os9ToUnixPermissions(h);
    if ((h.extraFlags & _commonCrc) != 0 &&
        lhaCrc16(0, h.raw, 0, h.raw.length) != h.commonCrc) {
      return LhaHeaderResult.bad;
    }
    if (h.level == 1 && h.osType == LhaOsType.lhark && h.method == '-lh7-') {
      h.method = '-lk7-';
    }
    return LhaHeaderResult.item;
  }

  // os9_to_unix_permissions
  void _os9ToUnixPermissions(LhaItem h) {
    final p = h.os9Perms;
    final or = p & 1, ow = (p >> 1) & 1, oe = (p >> 2) & 1;
    final pr = (p >> 3) & 1, pw = (p >> 4) & 1, pe = (p >> 5) & 1;
    final d = (p >> 7) & 1;
    h.extraFlags |= _unixPerms;
    h.unixPerms = (d << 14) |
        (or << 8) |
        (ow << 7) |
        (oe << 6) |
        (pr << 5) |
        (pw << 4) |
        (pe << 3) |
        (pr << 2) |
        (pw << 1) |
        pe;
  }

  // split_header_filename
  static void _splitFilename(LhaItem h) {
    final f = h.filename!;
    final sep = f.lastIndexOf(0x2F);
    if (sep >= 0) {
      h.path = Uint8List.fromList(f.sublist(0, sep + 1));
      h.filename = Uint8List.fromList(f.sublist(sep + 1));
    }
  }

  // parse_symlink
  bool _parseSymlink(LhaItem h) {
    final full = <int>[...?h.path, ...?h.filename];
    final p = full.indexOf(0x7C); // '|'
    if (p < 0) return false;
    h.symlinkTarget = Uint8List.fromList(full.sublist(p + 1));
    h.path = null;
    h.filename = Uint8List.fromList(full.sublist(0, p));
    _splitFilename(h);
    return true;
  }

  // process_level0_path
  void _processLevel0Path(LhaItem h, int off, int len) {
    if (len == 0) return;
    final f = Uint8List.fromList(h.raw.sublist(off, off + len));
    for (var i = 0; i < len; i++) {
      if (f[i] == 0x5C) f[i] = 0x2F;
    }
    h.filename = f;
    _splitFilename(h);
  }

  // process_level0_unix_area
  void _level0UnixArea(LhaItem h, int off, int len) {
    final d = h.raw;
    if (len < _level0UnixExtendedLen || d[off + 1] != 0) return;
    h.osType = d[off];
    h.timestamp = _u32(d, off + 2);
    h.dosTime = false;
    h.unixPerms = _u16(d, off + len - 6);
    h.unixUid = _u16(d, off + len - 4);
    h.unixGid = _u16(d, off + len - 2);
    h.extraFlags |= _unixPerms | _unixUidGid;
  }

  // process_level0_os9_area
  void _level0Os9Area(LhaItem h, int off, int len) {
    final d = h.raw;
    if (len < _level0Os9ExtendedLen ||
        d[off + 9] != 0xCC ||
        d[off + 1] != d[off + 17] ||
        d[off + 2] != d[off + 18]) {
      return;
    }
    h.osType = LhaOsType.os9;
    h.os9Perms = _u16(d, off + 1);
    h.extraFlags |= _os9Perms;
  }

  // process_level0_extended_area
  void _level0ExtendedArea(LhaItem h, int off, int len) {
    if (h.method.startsWith('-pm')) return;
    switch (h.raw[off]) {
      case LhaOsType.unix:
      case LhaOsType.os968k:
        _level0UnixArea(h, off, len);
      case LhaOsType.os9:
        _level0Os9Area(h, off, len);
    }
  }

  // decode_level0_header
  bool _decodeLevel0(LhaItem h) {
    final headerLen = h.raw[0];
    final headerCsum = h.raw[1];
    final minLen = h.level == 0 ? _level0MinHeaderLen : _level1MinHeaderLen;
    if (headerLen < minLen) return false;
    if (!_extend(h, headerLen + 2 - h.raw.length)) return false;
    final r = h.raw;
    // check_l0_checksum
    var sum = 0;
    for (var i = 2; i < r.length; i++) {
      sum += r[i];
    }
    if ((sum & 0xFF) != headerCsum) return false;
    h.method = latin1.decode(r.sublist(2, 7));
    h.packSize = _u32(r, 7);
    h.size = _u32(r, 11);
    h.timestamp = _u32(r, 15);
    h.dosTime = true;
    h.attr = r[19];
    final pathLen = r[21];
    if (minLen + pathLen > headerLen) return false;
    h.osType = h.level == 0 ? LhaOsType.unknown : r[24 + pathLen];
    _processLevel0Path(h, 22, pathLen);
    h.crc = _u16(r, 22 + pathLen);
    if (h.level == 0 && headerLen > _level0MinHeaderLen + pathLen) {
      _level0ExtendedArea(h, _level0MinHeaderLen + 2 + pathLen,
          headerLen - _level0MinHeaderLen - pathLen);
    }
    return true;
  }

  // decode_level1_header (with read_l1_extended_headers)
  bool _decodeLevel1(LhaItem h) {
    if (!_decodeLevel0(h)) return false;
    final extStart = h.raw.length - 2;
    for (;;) {
      final extLen = _u16(h.raw, h.raw.length - 2);
      if (extLen == 0) break;
      if (!_extend(h, extLen)) return false;
      if (h.packSize < extLen) return false;
      h.packSize -= extLen;
      if (extLen < 3) return false;
    }
    return _decodeExtendedHeaders(h, extStart);
  }

  // decode_level2_header
  bool _decodeLevel2(LhaItem h) {
    final headerLen = _u16(h.raw, 0);
    if (headerLen < _level2HeaderLen) return false;
    if (!_extend(h, headerLen - h.raw.length)) return false;
    final r = h.raw;
    h.method = latin1.decode(r.sublist(2, 7));
    h.packSize = _u32(r, 7);
    h.size = _u32(r, 11);
    h.timestamp = _u32(r, 15);
    h.attr = r[19];
    h.crc = _u16(r, 21);
    h.osType = r[23];
    if (h.osType == LhaOsType.os968k && !_extend(h, 2)) return false;
    return _decodeExtendedHeaders(h, 24);
  }

  // decode_level3_header
  bool _decodeLevel3(LhaItem h) {
    if (_u16(h.raw, 0) != 4) return false;
    if (!_extend(h, _level3HeaderLen - h.raw.length)) return false;
    final headerLen = _u32(h.raw, 24);
    if (headerLen > _level3MaxHeaderLen || headerLen < h.raw.length) {
      return false;
    }
    if (!_extend(h, headerLen - h.raw.length)) return false;
    final r = h.raw;
    h.method = latin1.decode(r.sublist(2, 7));
    h.packSize = _u32(r, 7);
    h.size = _u32(r, 11);
    h.timestamp = _u32(r, 15);
    h.attr = r[19];
    h.crc = _u16(r, 21);
    h.osType = r[23];
    return _decodeExtendedHeaders(h, 28);
  }

  // decode_extended_headers
  bool _decodeExtendedHeaders(LhaItem h, int offset) {
    final fieldSize = h.level == 3 ? 4 : 2;
    final r = h.raw;
    var available = r.length - offset - fieldSize;
    while (offset <= r.length - fieldSize) {
      final extLen = fieldSize == 4 ? _u32(r, offset) : _u16(r, offset);
      if (extLen == 0) break;
      if (extLen < fieldSize + 1 || extLen > available) return false;
      final at = offset + fieldSize;
      _decodeExtHeader(h, r[at], at + 1, extLen - fieldSize - 1);
      offset += extLen;
      available -= extLen;
    }
    return true;
  }

  // lha_ext_header_decode and the decoders of ext_header.c
  void _decodeExtHeader(LhaItem h, int num, int off, int len) {
    final d = h.raw;
    switch (num) {
      case 0x00: // common: CRC-16 of the header, computed with it as 0
        if (len < 2) return;
        h.extraFlags |= _commonCrc;
        h.commonCrc = _u16(d, off);
        d[off] = 0;
        d[off + 1] = 0;
      case 0x01: // file name
        if (len < 1) return;
        final f = Uint8List.fromList(d.sublist(off, off + len));
        for (var i = 0; i < f.length; i++) {
          if (f[i] == 0x2F) f[i] = 0x5F; // '/' to '_'
        }
        // a terminating zero is not part of the name
        final z = f.indexOf(0);
        h.filename = z >= 0 ? Uint8List.sublistView(f, 0, z) : f;
      case 0x02: // directory, 0xFF separated
        if (len < 1) return;
        final b = BytesBuilder(copy: false);
        for (var i = 0; i < len; i++) {
          final c = d[off + i];
          if (c == 0) break;
          b.addByte(c == 0xFF ? 0x2F : c);
        }
        var p = b.takeBytes();
        if (p.isEmpty || p[p.length - 1] != 0x2F) {
          p = Uint8List.fromList([...p, 0x2F]);
        }
        h.path = p;
      case 0x3F: // comment (libarchive)
        h.comment = Uint8List.fromList(d.sublist(off, off + len));
      case 0x40: // MS-DOS attribute (libarchive)
        if (len == 2) h.attr = _u16(d, off) & 0xFF;
      case 0x41: // Windows timestamps
        if (len < 24) return;
        h.extraFlags |= _windowsTimestamps;
        h.winCTime = _u64(d, off);
        h.winMTime = _u64(d, off + 8);
        h.winATime = _u64(d, off + 16);
      case 0x42: // 64-bit file sizes
        if (len < 16) return;
        h.extraFlags |= _bit64Sizes;
        h.packSize = _u64(d, off);
        h.size = _u64(d, off + 8);
      case 0x50: // Unix permissions
        if (len < 2) return;
        h.extraFlags |= _unixPerms;
        h.unixPerms = _u16(d, off);
      case 0x51: // Unix gid, uid
        if (len < 4) return;
        h.extraFlags |= _unixUidGid;
        h.unixGid = _u16(d, off);
        h.unixUid = _u16(d, off + 2);
      case 0x52: // Unix group name
        if (len < 1) return;
        h.unixGroup =
            decodeLhaName(Uint8List.fromList(d.sublist(off, off + len)));
      case 0x53: // Unix user name
        if (len < 1) return;
        h.unixUser =
            decodeLhaName(Uint8List.fromList(d.sublist(off, off + len)));
      case 0x54: // Unix time
        if (len < 4) return;
        h.timestamp = _u32(d, off);
        h.dosTime = false;
      case 0xCC: // OS-9
        if (len < 12) return;
        h.os9Perms = _u16(d, off + 7);
        h.extraFlags |= _os9Perms;
    }
  }
}

/// Is [p] (at least 22 bytes) the start of an LHA file header?
/// (file_header_match of lha_input_stream.c, and the header level.)
bool lhaHeaderMatch(Uint8List p, int off) {
  if (p[off + 2] != 0x2D || p[off + 6] != 0x2D) return false;
  final a = p[off + 3], b = p[off + 4], c = p[off + 5];
  var ok = false;
  if (a == 0x6C && b == 0x68) ok = true; // lh?
  if (a == 0x6C && b == 0x7A && (c == 0x34 || c == 0x35 || c == 0x73)) {
    ok = true; // lz4, lz5, lzs
  }
  if (a == 0x70 && b == 0x6D && c != 0x73) ok = true; // pm?
  return ok && p[off + 20] <= 3;
}

// ---------------------------------------------------------------------------
// Writing

/// The fields of a level 2 header to write.
class LhaOutItem {
  /// '/' separated path; a directory without a trailing '/'.
  String path;
  bool isDir;
  String? symlinkTarget;
  String method;
  int packSize = 0;
  int size = 0;
  int crc = 0;

  /// Unix time of the modification.
  int mTime = 0;

  /// Unix mode with the file type bits, or null.
  int? unixMode;
  int uid = 0;
  int gid = 0;
  bool hasUidGid = false;
  String? user;
  String? group;
  int attr = 0x20;
  Uint8List? comment;

  LhaOutItem(this.path,
      {this.isDir = false, this.symlinkTarget, this.method = '-lh5-'});
}

void _put16(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
}

void _put32(BytesBuilder b, int v) {
  _put16(b, v & 0xFFFF);
  _put16(b, (v >> 16) & 0xFFFF);
}

void _ext(BytesBuilder b, int type, List<int> data) {
  _put16(b, data.length + 3);
  b.addByte(type);
  b.add(data);
}

/// A level 2 header for [it], as LHa for UNIX writes them: the common
/// header CRC, file name, directory (0xFF separated), Unix permission,
/// gid/uid and user/group name extended headers.
Uint8List buildLhaLevel2Header(LhaOutItem it) {
  var full = it.path;
  if (it.symlinkTarget != null) full = '$full|${it.symlinkTarget}';
  final fullBytes = utf8.encode(full);
  List<int> dir;
  List<int> name;
  if (it.isDir) {
    dir = fullBytes.isEmpty ? const [] : [...fullBytes, 0x2F];
    name = const [];
  } else {
    final sep = fullBytes.lastIndexOf(0x2F);
    dir = sep >= 0 ? fullBytes.sublist(0, sep + 1) : const [];
    name = sep >= 0 ? fullBytes.sublist(sep + 1) : fullBytes;
  }
  final big = it.size > 0xFFFFFFFF || it.packSize > 0xFFFFFFFF;

  final e = BytesBuilder();
  _ext(e, 0x00, const [0, 0]);
  if (!it.isDir) _ext(e, 0x01, name);
  if (dir.isNotEmpty) {
    _ext(e, 0x02, [for (final c in dir) c == 0x2F ? 0xFF : c]);
  }
  if (it.comment != null) _ext(e, 0x3F, it.comment!);
  if (big) {
    final s = BytesBuilder();
    _put32(s, it.packSize & 0xFFFFFFFF);
    _put32(s, it.packSize >> 32);
    _put32(s, it.size & 0xFFFFFFFF);
    _put32(s, it.size >> 32);
    _ext(e, 0x42, s.takeBytes());
  }
  if (it.unixMode != null) {
    _ext(e, 0x50, [it.unixMode! & 0xFF, (it.unixMode! >> 8) & 0xFF]);
  }
  if (it.hasUidGid) {
    final g = BytesBuilder();
    _put16(g, it.gid);
    _put16(g, it.uid);
    _ext(e, 0x51, g.takeBytes());
  }
  if (it.group != null && it.group!.isNotEmpty) {
    _ext(e, 0x52, utf8.encode(it.group!));
  }
  if (it.user != null && it.user!.isNotEmpty) {
    _ext(e, 0x53, utf8.encode(it.user!));
  }
  _put16(e, 0);
  final ext = e.takeBytes();

  var total = 24 + ext.length;
  // a header whose size ends in a zero byte would read as the end mark
  final pad = (total & 0xFF) == 0 ? 1 : 0;
  total += pad;
  final b = BytesBuilder();
  _put16(b, total);
  b.add(latin1.encode(it.method));
  _put32(b, big ? 0 : it.packSize);
  _put32(b, big ? 0 : it.size);
  _put32(b, it.mTime < 0 ? 0 : (it.mTime > 0xFFFFFFFF ? 0xFFFFFFFF : it.mTime));
  b.addByte(it.attr);
  b.addByte(2);
  _put16(b, it.crc);
  b.addByte(LhaOsType.unix);
  b.add(ext);
  if (pad != 0) b.addByte(0);
  final h = b.takeBytes();
  // the common header CRC (at 24: size 2, type 1, then the value)
  final crc = lhaCrc16(0, h, 0, h.length);
  h[27] = crc & 0xFF;
  h[28] = (crc >> 8) & 0xFF;
  return h;
}
