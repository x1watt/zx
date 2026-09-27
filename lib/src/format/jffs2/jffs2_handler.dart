// JFFS2 images (read only), both byte orders: every node of the image is
// found by a scan at 4 byte steps (erase blocks, cleanmarkers, padding
// nodes and erased 0xFF areas need no special handling), checked with its
// header, node and data CRCs, and the file system is rebuilt as the
// kernel's mount scan does: per directory and name the directory entry of
// the highest version wins (an entry with inode 0 is an unlink), and the
// data of a file is its inode nodes applied in version order (a newer
// node overwrites the ranges it covers, its size field truncates).
// Compressors: none, zero, rtime, zlib, lzo and lzma; rubin is reported
// as an unsupported method. Extended attributes and summary nodes are
// skipped.
//
// Written from the node layout facts of the JFFS2 design paper ("JFFS:
// The Journalling Flash File System", David Woodhouse) and of the Linux
// documentation, and checked black box against mkfs.jffs2 (mtd-utils) and
// hand edited images. No Linux, mtd-utils or jefferson code was used.

import 'dart:typed_data';

import '../../codec/deflate/zlib.dart';
import '../../codec/lzma/lzma_dec.dart';
import '../../codec/lzo/lzo1x.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../item_streams.dart';

const int kJffs2Magic = 0x1985;

// node types
const int _ntDirent = 0xE001;
const int _ntInode = 0xE002;
const int _ntCleanmarker = 0x2003;

const int _kDirentSize = 40;
const int _kInodeSize = 68;

// compressors
const List<String> _comprNames = [
  'none',
  'zero',
  'rtime',
  'rubinmips',
  'copy',
  'dynrubin',
  'zlib',
  'lzo',
  'lzma',
];

// JFFS2 checks: crc32 with a zero seed and no final inversion
int _crc(Uint8List b, int off, int len) => crc32Update(0, b, off, off + len);

int _rd16(Uint8List b, int o, bool be) =>
    be ? (b[o] << 8) | b[o + 1] : b[o] | (b[o + 1] << 8);
int _rd32(Uint8List b, int o, bool be) => be
    ? getUint32BE(b, o)
    : b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

// 1 little endian, 2 big endian, 0 no node header at [o]
int _nodeAt(Uint8List p, int o) {
  final le = p[o] == 0x85 && p[o + 1] == 0x19;
  final be = p[o] == 0x19 && p[o + 1] == 0x85;
  if (!le && !be) return 0;
  if (_crc(p, o, 8) != _rd32(p, o + 8, be)) return 0;
  final totlen = _rd32(p, o + 4, be);
  if (totlen < 12) return 0;
  return be ? 2 : 1;
}

/// IsArc check: a valid node header at the start, possibly after erased
/// (0xFF) words. 1 yes, 0 no, 2 need more.
int isArcJffs2(Uint8List p, int size) {
  var o = 0;
  while (o + 4 <= size &&
      p[o] == 0xFF &&
      p[o + 1] == 0xFF &&
      p[o + 2] == 0xFF &&
      p[o + 3] == 0xFF) {
    o += 4;
  }
  if (o + 12 > size) return 2;
  return _nodeAt(p, o) != 0 ? 1 : 0;
}

class _Dirent {
  final int pino;
  final int version;
  final int ino;
  final int mctime;
  final int type;
  final String name;
  _Dirent(this.pino, this.version, this.ino, this.mctime, this.type, this.name);
}

class _INode {
  int pos = 0; // data start
  int version = 0;
  int mode = 0;
  int uid = 0;
  int gid = 0;
  int isize = 0;
  int atime = 0;
  int mtime = 0;
  int ctime = 0;
  int offset = 0;
  int csize = 0;
  int dsize = 0;
  int compr = 0;
  int order = 0; // scan order, for equal versions
}

/// A JFFS2 item (a live directory entry).
class Jffs2Item {
  String path = '';
  int ino = 0;
  int mode = 0;
  int uid = 0;
  int gid = 0;
  int size = 0;
  int atime = 0;
  int mtime = 0;
  int ctime = 0;
  int rdev = -1;
  int nlink = 1;
  String? symLink;
  String? hardLink;
  String method = '';

  int get fmt => mode & 0xF000;
  bool get isDir => fmt == 0x4000;
  bool get isReg => fmt == 0x8000;
  bool get isLink => fmt == 0xA000;
  bool get isDevice => fmt == 0x2000 || fmt == 0x6000;
}

/// A piece of a file: bytes [start, end) come from [node] at
/// start - node.offset.
class _Piece {
  int start;
  int end;
  final _INode node;
  _Piece(this.start, this.end, this.node);
}

Never _bad(String what) => throw SevenZipException('JFFS2: $what');

/// The JFFS2 handler.
class Jffs2Handler extends ReadOnlyHandler {
  SeekableInStream? _stream;
  final List<Jffs2Item> items = [];
  bool bigEndian = false;
  int eraseBlockSize = 0;
  int _phySize = 0;
  int crcErrors = 0;
  final Map<int, List<_INode>> _nodes = {};
  final Map<int, List<_Piece>> _pieces = {};

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.mTime,
    Kpid.aTime,
    Kpid.cTime,
    Kpid.posixAttrib,
    Kpid.links,
    Kpid.iNode,
    Kpid.userId,
    Kpid.groupId,
    Kpid.deviceMajor,
    Kpid.deviceMinor,
    Kpid.method,
    Kpid.symLink,
    Kpid.hardLink,
  ];

  static const List<int> _arcProps = [
    Kpid.bigEndian,
    Kpid.clusterSize,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;
  @override
  int get timePrec => FileTimeType.unix;

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final head = readAt(stream, 0, 1 << 16);
    if (isArcJffs2(head, head.length) != 1) return false;
    _stream = stream;
    final dirents = _scan(stream);
    try {
      _build(dirents);
    } on SevenZipException {
      _headersError = true;
    }
    return true;
  }

  bool _headersError = false;

  // Reads every node of the image.
  List<_Dirent> _scan(SeekableInStream s) {
    final len = s.length;
    const winSize = 1 << 18;
    var win = Uint8List(winSize);
    var winStart = 0;
    var winLen = 0;
    var endian = 0;
    var be = false;
    var order = 0;
    var lastClean = -1;
    var minClean = 0;
    final dirents = <_Dirent>[];

    var pos = 0;
    while (pos + 12 <= len) {
      if (pos < winStart || pos + 12 > winStart + winLen) {
        s.position = pos;
        winStart = pos;
        winLen = readFully(s, win, 0, win.length);
        if (winLen < 12) break;
      }
      var o = pos - winStart;
      // skip erased space quickly
      if (win[o] == 0xFF &&
          win[o + 1] == 0xFF &&
          win[o + 2] == 0xFF &&
          win[o + 3] == 0xFF) {
        pos += 4;
        continue;
      }
      final e = _nodeAt(win, o);
      if (e == 0 || (endian != 0 && e != endian)) {
        pos += 4;
        continue;
      }
      if (endian == 0) {
        endian = e;
        be = e == 2;
        bigEndian = be;
      }
      final type = _rd16(win, o + 2, be);
      final totlen = _rd32(win, o + 4, be);
      if (pos + totlen > len) {
        pos += 4;
        continue;
      }
      if (o + totlen > winLen) {
        if (totlen > win.length) win = Uint8List(totlen + 4096);
        s.position = pos;
        winStart = pos;
        winLen = readFully(s, win, 0, win.length);
        o = 0;
        if (winLen < totlen) break;
      }
      if (type == _ntDirent && totlen >= _kDirentSize) {
        final nsize = win[o + 28];
        if (_crc(win, o, 32) != _rd32(win, o + 32, be) ||
            _kDirentSize + nsize > totlen ||
            _crc(win, o + _kDirentSize, nsize) != _rd32(win, o + 36, be)) {
          crcErrors++;
        } else {
          dirents.add(_Dirent(
              _rd32(win, o + 12, be),
              _rd32(win, o + 16, be),
              _rd32(win, o + 20, be),
              _rd32(win, o + 24, be),
              win[o + 29],
              bytesToName(Uint8List.fromList(Uint8List.sublistView(
                  win, o + _kDirentSize, o + _kDirentSize + nsize)))));
        }
      } else if (type == _ntInode && totlen >= _kInodeSize) {
        final csize = _rd32(win, o + 48, be);
        if (_crc(win, o, 60) != _rd32(win, o + 64, be) ||
            _kInodeSize + csize > totlen ||
            _crc(win, o + _kInodeSize, csize) != _rd32(win, o + 60, be)) {
          crcErrors++;
        } else {
          final n = _INode()
            ..pos = pos + _kInodeSize
            ..version = _rd32(win, o + 16, be)
            ..mode = _rd32(win, o + 20, be)
            ..uid = _rd16(win, o + 24, be)
            ..gid = _rd16(win, o + 26, be)
            ..isize = _rd32(win, o + 28, be)
            ..atime = _rd32(win, o + 32, be)
            ..mtime = _rd32(win, o + 36, be)
            ..ctime = _rd32(win, o + 40, be)
            ..offset = _rd32(win, o + 44, be)
            ..csize = csize
            ..dsize = _rd32(win, o + 52, be)
            ..compr = win[o + 56]
            ..order = order++;
          (_nodes[_rd32(win, o + 12, be)] ??= []).add(n);
        }
      } else if (type == _ntCleanmarker) {
        if (lastClean >= 0) {
          final d = pos - lastClean;
          if (minClean == 0 || d < minClean) minClean = d;
        }
        lastClean = pos;
      }
      pos += (totlen + 3) & ~3;
    }
    // the scan passes over erased space and garbage to the end
    _phySize = len;
    eraseBlockSize = minClean;
    return dirents;
  }

  void _build(List<_Dirent> all) {
    // newest entry per (parent, name)
    final newest = <String, _Dirent>{};
    for (final d in all) {
      final key = '${d.pino}/${d.name}';
      final o = newest[key];
      if (o == null || d.version >= o.version) newest[key] = d;
    }
    final children = <int, List<_Dirent>>{};
    for (final d in newest.values) {
      if (d.ino == 0) continue;
      (children[d.pino] ??= []).add(d);
    }
    for (final l in children.values) {
      l.sort((a, b) => a.name.compareTo(b.name));
    }
    // sort the nodes of each inode by version
    for (final l in _nodes.values) {
      l.sort((a, b) =>
          a.version != b.version ? a.version - b.version : a.order - b.order);
    }
    // depth first, parents before their children
    final firstOfIno = <int, int>{};
    final seenDirs = <int>{1};
    final stack = <(_Dirent, String)>[
      for (final d in (children[1] ?? const <_Dirent>[]).reversed) (d, '')
    ];
    while (stack.isNotEmpty) {
      final (d, prefix) = stack.removeLast();
      if (d.name.isEmpty ||
          d.name == '.' ||
          d.name == '..' ||
          d.name.contains('/')) {
        _headersError = true;
        continue;
      }
      final it = _item(d);
      it.path = prefix.isEmpty ? d.name : '$prefix/${d.name}';
      if (!it.isDir) {
        final first = firstOfIno[d.ino];
        if (first == null) {
          firstOfIno[d.ino] = items.length;
        } else {
          it.hardLink = items[first].path;
        }
      }
      items.add(it);
      if (it.isDir) {
        if (seenDirs.add(d.ino)) {
          for (final c in (children[d.ino] ?? const <_Dirent>[]).reversed) {
            stack.add((c, it.path));
          }
        } else {
          _headersError = true;
        }
      }
    }
    final links = <int, int>{};
    for (final it in items) {
      if (!it.isDir) links[it.ino] = (links[it.ino] ?? 0) + 1;
    }
    for (final it in items) {
      if (!it.isDir) it.nlink = links[it.ino]!;
      if (it.hardLink != null) continue;
      if (it.isLink) {
        try {
          it.symLink = bytesToName(readAll(_FileStream(this, it)));
        } on SevenZipException {
          _headersError = true;
          it.symLink = '';
        }
      } else if (it.isDevice) {
        final l = _nodes[it.ino];
        if (l != null && l.isNotEmpty) {
          final n = l.last;
          final b = readAt(_stream!, n.pos, n.csize);
          if (b.length == 2) {
            // the old 16 bit number: major << 8 | minor
            it.rdev = _rd16(b, 0, bigEndian);
          } else if (b.length == 4) {
            it.rdev = _rd32(b, 0, bigEndian);
          }
        }
      }
    }
  }

  static const List<int> _dtFmt = [
    0,
    0x1000,
    0x2000,
    0,
    0x4000,
    0,
    0x6000,
    0,
    0x8000,
    0,
    0xA000,
    0,
    0xC000,
  ];

  Jffs2Item _item(_Dirent d) {
    final it = Jffs2Item()..ino = d.ino;
    final l = _nodes[d.ino];
    if (l == null || l.isEmpty) {
      it.mode = (d.type < _dtFmt.length ? _dtFmt[d.type] : 0) | 0x1A4;
      it.mtime = it.ctime = it.atime = d.mctime;
      return it;
    }
    final n = l.last;
    it
      ..mode = n.mode
      ..uid = n.uid
      ..gid = n.gid
      ..size = n.isize
      ..atime = n.atime
      ..mtime = n.mtime
      ..ctime = n.ctime;
    if (it.isReg || it.isLink) {
      var mask = 0;
      for (final x in l) {
        if (x.dsize > 0 && x.compr < 32) mask |= 1 << x.compr;
      }
      final names = <String>[];
      for (var c = 0; c < _comprNames.length; c++) {
        if ((mask & (1 << c)) != 0) names.add(_comprNames[c]);
      }
      it.method = names.join(' ');
    }
    if (!it.isReg && !it.isLink) it.size = 0;
    return it;
  }

  /// The pieces of the data of inode [ino], in file order.
  List<_Piece> _piecesOf(int ino) {
    final cached = _pieces[ino];
    if (cached != null) return cached;
    var ps = <_Piece>[];
    for (final n in _nodes[ino] ?? const <_INode>[]) {
      final s = n.offset;
      final e = n.offset + n.dsize;
      if (n.dsize > 0) {
        final out = <_Piece>[];
        var inserted = false;
        for (final p in ps) {
          if (p.end <= s || p.start >= e) {
            if (!inserted && p.start >= e) {
              out.add(_Piece(s, e, n));
              inserted = true;
            }
            out.add(p);
            continue;
          }
          if (p.start < s) out.add(_Piece(p.start, s, p.node));
          if (!inserted) {
            out.add(_Piece(s, e, n));
            inserted = true;
          }
          if (p.end > e) out.add(_Piece(e, p.end, p.node));
        }
        if (!inserted) out.add(_Piece(s, e, n));
        ps = out;
      }
      // the size of this version truncates the data
      final size = n.isize;
      while (ps.isNotEmpty && ps.last.start >= size) {
        ps.removeLast();
      }
      if (ps.isNotEmpty && ps.last.end > size) ps.last.end = size;
    }
    _pieces[ino] = ps;
    return ps;
  }

  /// The decoded data of node [n].
  Uint8List _nodeData(_INode n) {
    if (n.compr == 1) return Uint8List(n.dsize);
    final raw = readAt(_stream!, n.pos, n.csize);
    if (raw.length < n.csize) {
      throw const SevenZipException(
          'JFFS2: truncated node', SevenZipError.unexpectedEnd);
    }
    Uint8List d;
    switch (n.compr) {
      case 0:
      case 4:
        d = raw;
      case 2:
        d = _rtimeDecompress(raw, n.dsize);
      case 6:
        d = zlibInflateBytes(raw);
      case 7:
        d = lzo1xDecompress(raw, outSize: n.dsize);
      case 8:
        // raw LZMA, lc 0, lp 0, pb 0, 8 KiB dictionary
        final out = Uint8List(n.dsize);
        final r = lzmaDecode(out, raw,
            Uint8List.fromList(const [0, 0x00, 0x20, 0, 0]), lzmaFinishAny);
        if (r.res != szOk) _bad('lzma data error');
        d = Uint8List.sublistView(out, 0, r.destLen);
      default:
        throw SevenZipException(
            'JFFS2: unsupported compressor '
            '${n.compr < _comprNames.length ? _comprNames[n.compr] : n.compr}',
            SevenZipError.unsupportedMethod);
    }
    if (d.length != n.dsize) _bad('bad node data size');
    return d;
  }

  @override
  void close() {
    _stream = null;
    items.clear();
    _nodes.clear();
    _pieces.clear();
    crcErrors = 0;
    eraseBlockSize = 0;
    _phySize = 0;
    _headersError = false;
    bigEndian = false;
  }

  @override
  int get numberOfItems => items.length;

  @override
  Object? getProperty(int index, int propId) {
    if (index < 0 || index >= items.length) return null;
    final it = items[index];
    switch (propId) {
      case Kpid.path:
        return it.path;
      case Kpid.isDir:
        return it.isDir;
      case Kpid.size:
        return it.isDir ? null : it.size;
      case Kpid.mTime:
        return unixSecondsToFileTime(it.mtime);
      case Kpid.aTime:
        return unixSecondsToFileTime(it.atime);
      case Kpid.cTime:
        return unixSecondsToFileTime(it.ctime);
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
      case Kpid.deviceMajor:
        return it.isDevice && it.rdev >= 0 ? (it.rdev & 0xFFF00) >> 8 : null;
      case Kpid.deviceMinor:
        return it.isDevice && it.rdev >= 0
            ? (it.rdev & 0xFF) | ((it.rdev >> 12) & 0xFFF00)
            : null;
      case Kpid.method:
        return it.method.isEmpty ? null : it.method;
      case Kpid.symLink:
        return it.symLink;
      case Kpid.hardLink:
        return it.hardLink;
    }
    return null;
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.bigEndian:
        return bigEndian;
      case Kpid.clusterSize:
        return eraseBlockSize == 0 ? null : eraseBlockSize;
      case Kpid.phySize:
        return _phySize;
      case Kpid.errorFlags:
        return _headersError ? ErrorFlags.headersError : 0;
      case Kpid.warning:
        return crcErrors == 0
            ? null
            : '$crcErrors nodes with CRC errors were skipped';
    }
    return null;
  }

  SeekableInStream _open(Jffs2Item it) {
    if (!it.isReg && !it.isLink) return MemoryInStream(Uint8List(0));
    return _FileStream(this, it);
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(
        items.length,
        indices,
        testMode,
        cb,
        (i) => items[i].isDir,
        (i) => items[i].isDir ? 0 : items[i].size,
        (i) => _open(items[i]),
        expectedSize: (i) => items[i].isDir ? null : items[i].size);
  }

  @override
  SeekableInStream? getStream(int index) {
    if (_stream == null || index < 0 || index >= items.length) return null;
    final it = items[index];
    if (it.isDir) return null;
    return _open(it);
  }
}

// The rtime decompressor of JFFS2: pairs of (byte, repeat count), where
// the count copies that many bytes from just after the previous place the
// same byte value was written.
Uint8List _rtimeDecompress(Uint8List src, int outSize) {
  final out = Uint8List(outSize);
  final positions = Int32List(256);
  var ip = 0;
  var op = 0;
  final ipEnd = src.length;
  while (op < outSize) {
    if (ip + 2 > ipEnd) _bad('truncated rtime data');
    final value = src[ip++];
    out[op++] = value;
    var repeat = src[ip++];
    var back = positions[value];
    positions[value] = op;
    if (repeat > outSize - op) _bad('rtime data error');
    while (repeat > 0) {
      out[op++] = out[back++];
      repeat--;
    }
  }
  return out;
}

/// The data of a file: its pieces, zeros in the holes.
class _FileStream implements SeekableInStream {
  final Jffs2Handler _h;
  final Jffs2Item _it;
  final List<_Piece> _ps;
  int _pos = 0;
  _INode? _node;
  Uint8List? _data;

  _FileStream(this._h, this._it) : _ps = _h._piecesOf(_it.ino);

  @override
  int read(Uint8List buf, int off, int len) {
    final size = _it.size;
    if (len <= 0 || _pos >= size) return 0;
    if (len > size - _pos) len = size - _pos;
    final ps = _ps;
    // the first piece that ends after _pos
    var lo = 0;
    var hi = ps.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (ps[m].end <= _pos) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    final i = lo;
    if (i >= ps.length || ps[i].start > _pos) {
      // a hole
      var n = (i >= ps.length ? size : ps[i].start) - _pos;
      if (n > len) n = len;
      buf.fillRange(off, off + n, 0);
      _pos += n;
      return n;
    }
    final p = ps[i];
    var d = _data;
    if (!identical(_node, p.node) || d == null) {
      d = _h._nodeData(p.node);
      _data = d;
      _node = p.node;
    }
    var n = p.end - _pos;
    if (n > len) n = len;
    final from = _pos - p.node.offset;
    buf.setRange(off, off + n, d, from);
    _pos += n;
    return n;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => _it.size;
}
