// cpio archives (read only): the "new" ASCII format (070701), the same
// with a checksum (070702), the portable ASCII (odc, 070707), the afio
// large ASCII variant (070727) and the old binary format in both byte
// orders.
//
// Ported from libarchive's archive_read_support_format_cpio.c (BSD
// 2-clause, Copyright (c) 2003-2007 Tim Kientzle, 2010-2012 Michihiro
// NAKAJIMA; see LICENSE): the header layouts, the bid, the search for the
// next header after garbage (find_newc_header, find_odc_header), the name
// and data padding rules and the hard link detection (record_hardlink).
//
// Differences from libarchive, for random access listing:
// - all headers are read at open; directories take no part in the hard
//   link detection (libarchive tests every entry with nlink > 1);
// - a hard link group whose data is stored with a later entry (newc, as
//   GNU cpio writes it) gives that data to the first entry of the group,
//   the entry the others link to, so that extracting the links works;
// - the 070702 checksum (the sum of the data bytes) is checked when the
//   item is extracted.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../archive_types.dart';
import '../item_streams.dart';

// header sizes
const int _binHeaderSize = 26;
const int _odcHeaderSize = 76;
const int _newcHeaderSize = 110;
const int _afiolHeaderSize = 116;

// CPIO_PATHNAME_MAX
const int _kPathnameMax = 1024 * 1024;

/// cpio sub-formats.
enum CpioFormat { newc, crc, odc, afioLarge, binLE, binBE }

String cpioFormatName(CpioFormat f) {
  switch (f) {
    case CpioFormat.newc:
      return 'New ASCII';
    case CpioFormat.crc:
      return 'New CRC';
    case CpioFormat.odc:
      return 'Portable ASCII';
    case CpioFormat.afioLarge:
      return 'afio large ASCII';
    case CpioFormat.binLE:
      return 'Binary LE';
    case CpioFormat.binBE:
      return 'Binary BE';
  }
}

/// A cpio entry.
class CpioItem {
  String name = '';
  int mode = 0;
  int uid = 0;
  int gid = 0;
  int nlink = 0;
  int ino = 0;
  int dev = 0;
  int devMajor = 0;
  int devMinor = 0;
  int rdevMajor = 0;
  int rdevMinor = 0;
  int mtime = 0;
  int size = 0; // stored data size
  int check = 0; // 070702 checksum
  int headerPos = 0;
  int dataPos = 0;
  String? symLink;
  String? hardLink;

  // the data given to this entry (the group data for hard links)
  int dataFrom = 0;
  int dataSize = 0;

  bool get isDir => (mode & 0xF000) == 0x4000;
  bool get isSymLink => (mode & 0xF000) == 0xA000;
  bool get isReg => (mode & 0xF000) == 0x8000;
  bool get isDevice => (mode & 0xF000) == 0x2000 || (mode & 0xF000) == 0x6000;
}

bool _isHex(Uint8List p, int off, int len) {
  for (var i = off; i < off + len; i++) {
    final c = p[i];
    if (!((c >= 0x30 && c <= 0x39) ||
        (c >= 0x61 && c <= 0x66) ||
        (c >= 0x41 && c <= 0x46))) {
      return false;
    }
  }
  return true;
}

bool _isOctal(Uint8List p, int off, int len) {
  for (var i = off; i < off + len; i++) {
    final c = p[i];
    if (c < 0x30 || c > 0x37) return false;
  }
  return true;
}

// atol8
int _atol8(Uint8List p, int off, int cnt) {
  var l = 0;
  for (var i = off; i < off + cnt; i++) {
    final c = p[i];
    if (c < 0x30 || c > 0x37) return l;
    l = (l << 3) | (c - 0x30);
  }
  return l;
}

// atol16
int _atol16(Uint8List p, int off, int cnt) {
  var l = 0;
  for (var i = off; i < off + cnt; i++) {
    final c = p[i];
    int d;
    if (c >= 0x61 && c <= 0x66) {
      d = c - 0x61 + 10;
    } else if (c >= 0x41 && c <= 0x46) {
      d = c - 0x41 + 10;
    } else if (c >= 0x30 && c <= 0x39) {
      d = c - 0x30;
    } else {
      return l;
    }
    l = (l << 4) | d;
  }
  return l;
}

bool _magicAt(Uint8List p, int off, String m) {
  for (var i = 0; i < m.length; i++) {
    if (p[off + i] != m.codeUnitAt(i)) return false;
  }
  return true;
}

// is_afio_large
bool _isAfioLarge(Uint8List h, int off, int len) {
  if (len < _afiolHeaderSize) return false;
  if (h[off + 30] != 0x6D || // 'm' after ino
      h[off + 85] != 0x6E || // 'n' after mtime
      h[off + 98] != 0x73 || // 's' after xsize
      h[off + 115] != 0x3A) {
    return false;
  }
  if (!_isHex(h, off + 6, 30 - 6)) return false;
  if (!_isHex(h, off + 31, 85 - 31)) return false;
  if (!_isHex(h, off + 86, 98 - 86)) return false;
  if (!_isHex(h, off + 99, 16)) return false;
  return true;
}

/// archive_read_format_cpio_bid as an IsArc function: which sub-format
/// the first bytes are, or null.
CpioFormat? cpioBid(Uint8List h, int size) {
  if (size < 6) return null;
  if (_magicAt(h, 0, '070707')) return CpioFormat.odc;
  if (_magicAt(h, 0, '070727')) return CpioFormat.afioLarge;
  if (_magicAt(h, 0, '070701')) return CpioFormat.newc;
  if (_magicAt(h, 0, '070702')) return CpioFormat.crc;
  if (((h[0] << 8) | h[1]) == 0x71C7) return CpioFormat.binBE;
  if (((h[1] << 8) | h[0]) == 0x71C7) return CpioFormat.binLE;
  return null;
}

/// IsArc for the format table: the bid plus a check of the first header
/// (hex or octal digits, a sane binary name size).
int isArcCpio(Uint8List p, int size) {
  final f = cpioBid(p, size);
  if (f == null) return 0;
  switch (f) {
    case CpioFormat.newc:
    case CpioFormat.crc:
      if (size < _newcHeaderSize) return 2;
      return _isHex(p, 0, _newcHeaderSize) ? 1 : 0;
    case CpioFormat.odc:
      if (size < _odcHeaderSize) return 2;
      return _isOctal(p, 0, _odcHeaderSize) ? 1 : 0;
    case CpioFormat.afioLarge:
      if (size < _afiolHeaderSize) return 2;
      return _isAfioLarge(p, 0, size) ? 1 : 0;
    case CpioFormat.binLE:
    case CpioFormat.binBE:
      if (size < _binHeaderSize) return 2;
      final be = f == CpioFormat.binBE;
      final nameSize = be ? (p[20] << 8) | p[21] : (p[21] << 8) | p[20];
      if (nameSize == 0 || nameSize > 4096) return 0;
      final end = _binHeaderSize + nameSize;
      if (end <= size && p[end - 1] != 0) return 0;
      return 1;
  }
}

/// The cpio handler.
class CpioHandler extends ReadOnlyHandler {
  SeekableInStream? _stream;
  final List<CpioItem> items = [];
  CpioFormat format = CpioFormat.newc;
  int _phySize = 0;
  bool _unexpectedEnd = false;
  bool _headersError = false;
  bool _skippedGarbage = false;
  _SumInStream? _lastSum;

  // reader state
  int _pos = 0;
  int _len = 0;
  final Uint8List _win = Uint8List(1 << 16);
  int _winStart = 0;
  int _winLen = 0;

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.posixAttrib,
    Kpid.links,
    Kpid.iNode,
    Kpid.userId,
    Kpid.groupId,
    Kpid.devMajor,
    Kpid.devMinor,
    Kpid.deviceMajor,
    Kpid.deviceMinor,
    Kpid.checksum,
    Kpid.symLink,
    Kpid.hardLink,
    Kpid.offset,
  ];

  static const List<int> _arcProps = [Kpid.subType];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  @override
  int get timePrec => FileTimeType.unix;

  // __archive_read_ahead: [n] bytes at [_pos] in _win, or -1 at the end.
  // Returns the offset of the bytes in _win.
  int _ahead(int n) {
    if (_pos >= _winStart && _pos + n <= _winStart + _winLen) {
      return _pos - _winStart;
    }
    if (_pos + n > _len) return -1;
    final s = _stream!;
    s.position = _pos;
    _winStart = _pos;
    _winLen = readFully(s, _win, 0, _win.length);
    if (_winLen < n) return -1;
    return 0;
  }

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final first = readAt(stream, 0, _afiolHeaderSize);
    final f = cpioBid(first, first.length);
    if (f == null) return false;
    if (isArcCpio(first, first.length) != 1) return false;
    _stream = stream;
    _len = stream.length;
    _pos = 0;
    _winLen = 0;
    format = f;
    var sawTrailer = false;
    for (;;) {
      final it = CpioItem();
      final r = _readHeader(it);
      if (r < 0) {
        break;
      }
      if (r == 0) {
        sawTrailer = true;
        break;
      }
      items.add(it);
    }
    if (!sawTrailer) _unexpectedEnd = true;
    _phySize = _pos > _len ? _len : _pos;
    if (sawTrailer) _extendOverZeros();
    _resolveLinks();
    return true;
  }

  // the zero padding after the trailer (cpio writes whole blocks) is part
  // of the archive
  void _extendOverZeros() {
    final s = _stream!;
    final rest = _len - _phySize;
    if (rest <= 0 || rest > 1 << 20) return;
    final b = readAt(s, _phySize, rest);
    for (var i = 0; i < b.length; i++) {
      if (b[i] != 0) return;
    }
    _phySize = _len;
  }

  // archive_read_format_cpio_read_header. 1: an entry, 0: the trailer,
  // -1: the end or a fatal error (flags set).
  int _readHeader(CpioItem it) {
    int nameLen;
    int namePad;
    int padding;
    switch (format) {
      case CpioFormat.newc:
      case CpioFormat.crc:
        if (!_findNewcHeader()) return -1;
        final o = _ahead(_newcHeaderSize);
        if (o < 0) return _eof();
        final h = _win;
        it.headerPos = _pos;
        if (_magicAt(h, o, '070702')) format = CpioFormat.crc;
        it.ino = _atol16(h, o + 6, 8);
        it.mode = _atol16(h, o + 14, 8);
        it.uid = _atol16(h, o + 22, 8);
        it.gid = _atol16(h, o + 30, 8);
        it.nlink = _atol16(h, o + 38, 8);
        it.mtime = _atol16(h, o + 46, 8);
        it.size = _atol16(h, o + 54, 8);
        it.devMajor = _atol16(h, o + 62, 8);
        it.devMinor = _atol16(h, o + 70, 8);
        it.rdevMajor = _atol16(h, o + 78, 8);
        it.rdevMinor = _atol16(h, o + 86, 8);
        nameLen = _atol16(h, o + 94, 8);
        it.check = _atol16(h, o + 102, 8);
        it.dev = (it.devMajor << 32) | it.devMinor;
        // pad name to 2 more than a multiple of 4
        namePad = (2 - nameLen) & 3;
        padding = (-it.size) & 3;
        _pos += _newcHeaderSize;
      case CpioFormat.odc:
      case CpioFormat.afioLarge:
        if (!_findOdcHeader()) return -1;
        if (format == CpioFormat.afioLarge) {
          final o = _ahead(_afiolHeaderSize);
          if (o < 0) return _eof();
          final h = _win;
          it.headerPos = _pos;
          it.dev = _atol16(h, o + 6, 8);
          it.ino = _atol16(h, o + 14, 16);
          it.mode = _atol8(h, o + 31, 6);
          it.uid = _atol16(h, o + 37, 8);
          it.gid = _atol16(h, o + 45, 8);
          it.nlink = _atol16(h, o + 53, 8);
          _setRdev(it, _atol16(h, o + 61, 8));
          it.mtime = _atol16(h, o + 69, 16);
          nameLen = _atol16(h, o + 86, 4);
          it.size = _atol16(h, o + 99, 16);
          if (it.size < 0) {
            _headersError = true;
            return -1;
          }
          _pos += _afiolHeaderSize;
        } else {
          final o = _ahead(_odcHeaderSize);
          if (o < 0) return _eof();
          final h = _win;
          it.headerPos = _pos;
          it.dev = _atol8(h, o + 6, 6);
          it.ino = _atol8(h, o + 12, 6);
          it.mode = _atol8(h, o + 18, 6);
          it.uid = _atol8(h, o + 24, 6);
          it.gid = _atol8(h, o + 30, 6);
          it.nlink = _atol8(h, o + 36, 6);
          _setRdev(it, _atol8(h, o + 42, 6));
          it.mtime = _atol8(h, o + 48, 11);
          nameLen = _atol8(h, o + 59, 6);
          it.size = _atol8(h, o + 65, 11);
          _pos += _odcHeaderSize;
        }
        namePad = 0;
        padding = 0;
      case CpioFormat.binLE:
      case CpioFormat.binBE:
        final o = _ahead(_binHeaderSize);
        if (o < 0) return _eof();
        final h = _win;
        final be = format == CpioFormat.binBE;
        int u16(int k) => be
            ? (h[o + k] << 8) | h[o + k + 1]
            : (h[o + k + 1] << 8) | h[o + k];
        if (u16(0) != 0x71C7) {
          _headersError = true;
          return -1;
        }
        it.headerPos = _pos;
        it.dev = u16(2);
        it.ino = u16(4);
        it.mode = u16(6);
        it.uid = u16(8);
        it.gid = u16(10);
        it.nlink = u16(12);
        _setRdev(it, u16(14));
        // cpio_le32dec / cpio_be32dec: the high 16 bits come first
        it.mtime = (u16(16) << 16) | u16(18);
        nameLen = u16(20);
        it.size = (u16(22) << 16) | u16(24);
        namePad = nameLen & 1;
        padding = it.size & 1;
        _pos += _binHeaderSize;
    }
    if (nameLen > _kPathnameMax) {
      _headersError = true;
      return -1;
    }
    if (_pos + nameLen > _len) return _eof();
    final nameBytes = readAt(_stream!, _pos, nameLen);
    final isTrailer = nameLen == 11 &&
        nameBytes.length == 11 &&
        _magicAt(nameBytes, 0, 'TRAILER!!!');
    it.name = cString(nameBytes, 0, nameBytes.length);
    _pos += nameLen + namePad;
    it.dataPos = _pos;
    if ((it.mode & 0xF000) == 0xA000) {
      if (it.size > 1024 * 1024) {
        _headersError = true;
        return -1;
      }
      if (_pos + it.size > _len) return _eof();
      final t = readAt(_stream!, _pos, it.size);
      it.symLink = bytesToName(t);
    }
    if (isTrailer) {
      _pos += it.size + padding;
      return 0;
    }
    if (_pos + it.size > _len) {
      _unexpectedEnd = true;
      it.size = _len - _pos;
      if (it.size < 0) it.size = 0;
      _pos = _len;
      items.add(it);
      return -1;
    }
    _pos += it.size + padding;
    return 1;
  }

  int _eof() {
    _unexpectedEnd = true;
    return -1;
  }

  // dev_t of a 16 or 18 bit field, as Linux encodes it
  static void _setRdev(CpioItem it, int rdev) {
    it.rdevMajor = (rdev >> 8) & 0xFFF;
    it.rdevMinor = (rdev & 0xFF) | ((rdev >> 12) & 0xFFF00);
  }

  // find_newc_header
  bool _findNewcHeader() {
    for (;;) {
      var o = _ahead(_newcHeaderSize);
      if (o < 0) {
        _eof();
        return false;
      }
      final h = _win;
      if (_magicAt(h, o, '07070') &&
          (h[o + 5] == 0x31 || h[o + 5] == 0x32) &&
          _isHex(h, o, _newcHeaderSize)) {
        return true;
      }
      // scan the window for something that looks like a newc header
      final q = _winLen;
      var p = o;
      while (p + _newcHeaderSize <= q) {
        final c = h[p + 5];
        if (c == 0x31 || c == 0x32) {
          if (_magicAt(h, p, '07070') && _isHex(h, p, _newcHeaderSize)) {
            _pos += p - o;
            _skippedGarbage = true;
            return true;
          }
          p += 2;
        } else if (c == 0x30) {
          p++;
        } else {
          p += 6;
        }
      }
      _pos += p - o;
      _skippedGarbage = true;
      o = 0;
    }
  }

  // find_odc_header
  bool _findOdcHeader() {
    for (;;) {
      var headerSize = _afiolHeaderSize;
      var o = _ahead(_afiolHeaderSize);
      if (o < 0) {
        headerSize = _odcHeaderSize;
        o = _ahead(_odcHeaderSize);
        if (o < 0) {
          _eof();
          return false;
        }
      }
      final h = _win;
      final q = _winLen;
      if (_magicAt(h, o, '070707') && _isOctal(h, o, _odcHeaderSize)) {
        format = CpioFormat.odc;
        return true;
      }
      if (_magicAt(h, o, '070727') && _isAfioLarge(h, o, q - o)) {
        format = CpioFormat.afioLarge;
        return true;
      }
      var p = o;
      while (p + headerSize <= q) {
        final c = h[p + 5];
        if (c == 0x37) {
          final odc =
              _magicAt(h, p, '070707') && _isOctal(h, p, _odcHeaderSize);
          if (odc || (_magicAt(h, p, '070727') && _isAfioLarge(h, p, q - p))) {
            _pos += p - o;
            _skippedGarbage = true;
            format = odc ? CpioFormat.odc : CpioFormat.afioLarge;
            return true;
          }
          p += 2;
        } else if (c == 0x30) {
          p++;
        } else {
          p += 6;
        }
      }
      _pos += p - o;
      _skippedGarbage = true;
    }
  }

  // record_hardlink for every entry, then the data of each group
  void _resolveLinks() {
    final groups = <(int, int), List<CpioItem>>{};
    for (final it in items) {
      it.dataFrom = it.dataPos;
      it.dataSize = it.size;
      if (it.nlink <= 1 || it.isDir) continue;
      (groups[(it.dev, it.ino)] ??= []).add(it);
    }
    for (final g in groups.values) {
      if (g.length < 2) continue;
      final first = g[0];
      // the entry that holds the data: the first one with any
      var holder = first;
      for (final it in g) {
        if (it.size > 0) {
          holder = it;
          break;
        }
      }
      for (final it in g) {
        it.dataFrom = holder.dataPos;
        it.dataSize = holder.size;
        if (!identical(it, first)) it.hardLink = first.name;
      }
    }
  }

  @override
  void close() {
    _stream = null;
    items.clear();
    _phySize = 0;
    _unexpectedEnd = false;
    _headersError = false;
    _skippedGarbage = false;
    _winLen = 0;
    _lastSum = null;
  }

  @override
  int get numberOfItems => items.length;

  static String _stripSlash(String s) {
    var n = s.length;
    while (n > 1 && s.codeUnitAt(n - 1) == 0x2F) {
      n--;
    }
    return s.substring(0, n);
  }

  @override
  Object? getProperty(int index, int propId) {
    if (index < 0 || index >= items.length) return null;
    final it = items[index];
    switch (propId) {
      case Kpid.path:
        return _stripSlash(it.name);
      case Kpid.isDir:
        return it.isDir;
      case Kpid.size:
        return it.isDir ? 0 : it.dataSize;
      case Kpid.packSize:
        return it.size;
      case Kpid.mTime:
        return unixSecondsToFileTime(it.mtime);
      case Kpid.posixAttrib:
        return it.mode & 0xFFFF;
      case Kpid.links:
        return it.nlink;
      case Kpid.iNode:
        return it.ino;
      case Kpid.userId:
        return it.uid;
      case Kpid.groupId:
        return it.gid;
      case Kpid.devMajor:
        return format == CpioFormat.newc || format == CpioFormat.crc
            ? it.devMajor
            : null;
      case Kpid.devMinor:
        return format == CpioFormat.newc || format == CpioFormat.crc
            ? it.devMinor
            : null;
      case Kpid.deviceMajor:
        return it.isDevice ? it.rdevMajor : null;
      case Kpid.deviceMinor:
        return it.isDevice ? it.rdevMinor : null;
      case Kpid.checksum:
        return format == CpioFormat.crc ? it.check : null;
      case Kpid.symLink:
        return it.symLink;
      case Kpid.hardLink:
        return it.hardLink;
      case Kpid.offset:
        return it.headerPos;
    }
    return null;
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.phySize:
        return _phySize;
      case Kpid.subType:
        return cpioFormatName(format);
      case Kpid.errorFlags:
        var f = 0;
        if (_unexpectedEnd) f |= ErrorFlags.unexpectedEnd;
        if (_headersError) f |= ErrorFlags.headersError;
        return f;
      case Kpid.warningFlags:
        return _skippedGarbage ? ErrorFlags.headersError : null;
      case Kpid.warning:
        return _skippedGarbage
            ? 'Skipped bytes before finding a valid header'
            : null;
    }
    return null;
  }

  InStream _open(int index) {
    final it = items[index];
    final s = SubInStream(_stream!, it.dataFrom, it.dataSize);
    if (format == CpioFormat.crc && it.isReg) {
      final sum = _SumInStream(s);
      _lastSum = sum;
      return sum;
    }
    _lastSum = null;
    return s;
  }

  // the checksum of the group data: the one of the entry that stores it
  int _expectedCheck(CpioItem it) {
    if (it.dataFrom == it.dataPos) return it.check;
    for (final o in items) {
      if (o.dataPos == it.dataFrom && o.size == it.dataSize) return o.check;
    }
    return it.check;
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(
        items.length,
        indices,
        testMode,
        cb,
        (i) => items[i].isDir,
        (i) => items[i].isDir ? 0 : items[i].dataSize,
        _open,
        expectedSize: (i) => items[i].isDir ? null : items[i].dataSize,
        verify: (i) {
          final sum = _lastSum;
          if (sum == null) return OperationResult.ok;
          return sum.sum == _expectedCheck(items[i])
              ? OperationResult.ok
              : OperationResult.crcError;
        });
  }

  @override
  SeekableInStream? getStream(int index) {
    if (_stream == null || index < 0 || index >= items.length) return null;
    final it = items[index];
    if (it.isDir) return null;
    return SubInStream(_stream!, it.dataFrom, it.dataSize);
  }
}

/// Sums the bytes read (the 070702 checksum).
class _SumInStream implements InStream {
  final InStream _base;
  int sum = 0;
  _SumInStream(this._base);

  @override
  int read(Uint8List buf, int off, int len) {
    final n = _base.read(buf, off, len);
    var s = sum;
    for (var i = off; i < off + n; i++) {
      s += buf[i];
    }
    sum = s & 0xFFFFFFFF;
    return n;
  }
}
