// cramfs images (read only), both byte orders, with or without the 512
// byte pad before the superblock: the superblock, the inode tree, the
// block pointer tables and the zlib compressed blocks, holes (blocks of
// zero length) and the extended block pointers of Linux 4.15 (the
// uncompressed and direct pointer flags).
//
// Written from the layout facts of the Linux documentation text
// (Documentation/filesystems/cramfs.rst and fs/cramfs/README: the
// superblock, the 12 byte inode, the width first directory order, the
// block pointers that store the end of each block, the pointer flags)
// and checked black box against mkfs.cramfs (util-linux) and 7-Zip. No
// Linux or cramfs tools code was used.
//
// The block size is not stored in the image. It is 4096 in practice
// (PAGE_SIZE); other sizes (mkfs.cramfs -b) are found by checking the
// block pointer tables of the first files.

import 'dart:typed_data';

import '../../codec/deflate/zlib.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import '../item_streams.dart';

/// The cramfs magic as a u32 in the image's byte order.
const int kCramfsMagic = 0x28CD3D45;

const int _kSuperSize = 76;
const String _kSignature = 'Compressed ROMFS';

// superblock flags
const int _flagExtBlockPointers = 0x800;
// block pointer flags (with _flagExtBlockPointers)
const int _blkUncompressed = 0x80000000;
const int _blkDirect = 0x40000000;

/// IsArc check: 1 yes, 0 no, 2 need more.
int isArcCramfs(Uint8List p, int size) {
  if (size < 4) return 2;
  if (_magicAt(p, 0) != 0) {
    if (size < 32) return 2;
    return _sigAt(p, 0) ? 1 : 0;
  }
  // the 512 byte pad (boot code room) before the superblock
  if (size < 512 + 32) return 2;
  return _magicAt(p, 512) != 0 && _sigAt(p, 512) ? 1 : 0;
}

// 1 little endian, 2 big endian, 0 none
int _magicAt(Uint8List p, int o) {
  if (p[o] == 0x45 &&
      p[o + 1] == 0x3D &&
      p[o + 2] == 0xCD &&
      p[o + 3] == 0x28) {
    return 1;
  }
  if (p[o] == 0x28 &&
      p[o + 1] == 0xCD &&
      p[o + 2] == 0x3D &&
      p[o + 3] == 0x45) {
    return 2;
  }
  return 0;
}

bool _sigAt(Uint8List p, int o) {
  for (var i = 0; i < 16; i++) {
    if (p[o + 16 + i] != _kSignature.codeUnitAt(i)) return false;
  }
  return true;
}

/// A cramfs item.
class CramfsItem {
  String path = '';
  int mode = 0;
  int uid = 0;
  int gid = 0;
  int size = 0; // the size field (rdev for devices)
  int offset = 0; // byte offset of the data or of the first child
  String? symLink;

  int get fmt => mode & 0xF000;
  bool get isDir => fmt == 0x4000;
  bool get isReg => fmt == 0x8000;
  bool get isLink => fmt == 0xA000;
  bool get isDevice => fmt == 0x2000 || fmt == 0x6000;
  bool get hasData => (isReg || isLink) && offset != 0;
  int get dataSize => (isReg || isLink) ? size : 0;
}

Never _bad(String what) => throw SevenZipException('cramfs: $what');

/// The cramfs handler.
class CramfsHandler extends ReadOnlyHandler {
  SeekableInStream? _stream;
  final List<CramfsItem> items = [];
  int _len = 0;
  bool bigEndian = false;
  int base = 0;
  int flags = 0;
  int blockSize = 4096;
  int _fsSize = 0;
  String volumeName = '';
  bool _headersError = false;

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.posixAttrib,
    Kpid.userId,
    Kpid.groupId,
    Kpid.deviceMajor,
    Kpid.deviceMinor,
    Kpid.symLink,
  ];

  static const List<int> _arcProps = [
    Kpid.volumeName,
    Kpid.clusterSize,
    Kpid.bigEndian,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  int _u32(Uint8List b, int o) => bigEndian
      ? getUint32BE(b, o)
      : b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  // struct cramfs_inode: mode:16 uid:16, size:24 gid:8, namelen:6
  // offset:26; the bit fields start at the low bits of each little endian
  // word and at the high bits of each big endian word.
  CramfsItem _inode(Uint8List b, int o) {
    final w0 = _u32(b, o);
    final w1 = _u32(b, o + 4);
    final w2 = _u32(b, o + 8);
    final it = CramfsItem();
    if (bigEndian) {
      it.mode = w0 >> 16;
      it.uid = w0 & 0xFFFF;
      it.size = w1 >> 8;
      it.gid = w1 & 0xFF;
      it.offset = (w2 & 0x3FFFFFF) << 2;
    } else {
      it.mode = w0 & 0xFFFF;
      it.uid = w0 >> 16;
      it.size = w1 & 0xFFFFFF;
      it.gid = w1 >> 24;
      it.offset = (w2 >> 6) << 2;
    }
    return it;
  }

  int _nameLen(Uint8List b, int o) {
    final w2 = _u32(b, o + 8);
    return (bigEndian ? w2 >> 26 : w2 & 0x3F) << 2;
  }

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final head = readAt(stream, 0, 512 + _kSuperSize);
    int e = 0;
    for (final b in const [0, 512]) {
      if (head.length >= b + _kSuperSize) {
        e = _magicAt(head, b);
        if (e != 0 && _sigAt(head, b)) {
          base = b;
          break;
        }
        e = 0;
      }
    }
    if (e == 0) return false;
    bigEndian = e == 2;
    _stream = stream;
    _len = stream.length;
    final sb = Uint8List.sublistView(head, base, base + _kSuperSize);
    _fsSize = _u32(sb, 4);
    flags = _u32(sb, 8);
    volumeName = cString(sb, 48, 16);
    final root = _inode(sb, 64);
    if (!root.isDir) {
      close();
      return false;
    }
    try {
      _walk(root);
      _findBlockSize();
      for (final it in items) {
        if (it.isLink) {
          final b = readAll(_open(it));
          it.symLink = bytesToName(b);
        }
      }
    } on SevenZipException {
      if (items.isEmpty) {
        close();
        return false;
      }
      _headersError = true;
    }
    return true;
  }

  // Directories in width first order, as the image stores them.
  void _walk(CramfsItem root) {
    final queue = <(CramfsItem, String)>[(root, '')];
    final seen = <int>{};
    for (var q = 0; q < queue.length; q++) {
      final (dir, prefix) = queue[q];
      if (dir.size == 0 || dir.offset == 0) continue;
      if (!seen.add(dir.offset)) _bad('directory loop');
      if (dir.offset + dir.size > _len) _bad('directory beyond the end');
      final b = readAt(_stream!, dir.offset, dir.size);
      var p = 0;
      while (p + 12 <= b.length) {
        final it = _inode(b, p);
        final nl = _nameLen(b, p);
        if (nl == 0 || p + 12 + nl > b.length) _bad('bad directory entry');
        final name = cString(b, p + 12, nl);
        p += 12 + nl;
        if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
          _headersError = true;
          continue;
        }
        it.path = prefix.isEmpty ? name : '$prefix/$name';
        items.add(it);
        if (it.isDir) queue.add((it, it.path));
      }
    }
  }

  // The block size: 4096 unless the pointer tables of the files say
  // otherwise.
  void _findBlockSize() {
    const candidates = [4096, 8192, 16384, 32768, 65536, 131072, 2048, 1024];
    final files = <CramfsItem>[];
    for (final it in items) {
      if (it.hasData && it.size > 1024) {
        files.add(it);
        if (files.length == 8) break;
      }
    }
    for (final bs in candidates) {
      var ok = true;
      for (final it in files) {
        if (!_tableFits(it, bs)) {
          ok = false;
          break;
        }
      }
      if (ok) {
        blockSize = bs;
        return;
      }
    }
  }

  bool _tableFits(CramfsItem it, int bs) {
    final n = (it.size + bs - 1) ~/ bs;
    final tableEnd = it.offset + n * 4;
    if (tableEnd > _len) return false;
    final t = readAt(_stream!, it.offset, n * 4);
    final ext = (flags & _flagExtBlockPointers) != 0;
    var prev = tableEnd;
    for (var i = 0; i < n; i++) {
      var p = _u32(t, i * 4);
      if (ext) {
        if ((p & _blkDirect) != 0) {
          final start = (p & 0x3FFFFFFF) << 2;
          if (start >= _len) return false;
          continue;
        }
        p &= 0x3FFFFFFF;
      }
      if (p < prev || p > _len) return false;
      if (i == 0 && p > prev && !ext) {
        // a zlib header starts the first block
        final h = readAt(_stream!, prev, 2);
        if (h.length < 2 ||
            (h[0] & 0x0F) != 8 ||
            ((h[0] << 8) | h[1]) % 31 != 0) {
          return false;
        }
      }
      prev = p;
    }
    return true;
  }

  @override
  void close() {
    _stream = null;
    items.clear();
    _headersError = false;
    blockSize = 4096;
    base = 0;
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
        return it.isDir ? null : it.dataSize;
      case Kpid.posixAttrib:
        return it.mode;
      case Kpid.userId:
        return it.uid;
      case Kpid.groupId:
        return it.gid;
      case Kpid.deviceMajor:
        return it.isDevice ? (it.size >> 8) & 0xFF : null;
      case Kpid.deviceMinor:
        return it.isDevice ? it.size & 0xFF : null;
      case Kpid.symLink:
        return it.symLink;
    }
    return null;
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.volumeName:
        return volumeName;
      case Kpid.clusterSize:
        return blockSize;
      case Kpid.bigEndian:
        return bigEndian;
      case Kpid.phySize:
        // the size field counts the pad before the superblock too
        return _fsSize != 0 ? _fsSize : null;
      case Kpid.errorFlags:
        return _headersError ? ErrorFlags.headersError : 0;
    }
    return null;
  }

  SeekableInStream _open(CramfsItem it) {
    if (!it.hasData || it.size == 0) return MemoryInStream(Uint8List(0));
    return _CrFileStream(this, it);
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(items.length, indices, testMode, cb,
        (i) => items[i].isDir, (i) => items[i].dataSize, (i) => _open(items[i]),
        expectedSize: (i) => items[i].isDir ? null : items[i].dataSize);
  }

  @override
  SeekableInStream? getStream(int index) {
    if (_stream == null || index < 0 || index >= items.length) return null;
    final it = items[index];
    if (it.isDir) return null;
    return _open(it);
  }
}

/// The data of a file, decoded block by block.
class _CrFileStream implements SeekableInStream {
  final CramfsHandler _h;
  final CramfsItem _it;
  final Uint32List _ptrs;
  final int _tableEnd;
  int _pos = 0;
  int _blk = -1;
  Uint8List? _data;

  _CrFileStream._(this._h, this._it, this._ptrs, this._tableEnd);

  factory _CrFileStream(CramfsHandler h, CramfsItem it) {
    final bs = h.blockSize;
    final n = (it.size + bs - 1) ~/ bs;
    final t = readAt(h._stream!, it.offset, n * 4);
    if (t.length < n * 4) {
      throw const SevenZipException(
          'cramfs: truncated block table', SevenZipError.unexpectedEnd);
    }
    final p = Uint32List(n);
    for (var i = 0; i < n; i++) {
      p[i] = h._u32(t, i * 4);
    }
    return _CrFileStream._(h, it, p, it.offset + n * 4);
  }

  bool get _ext => (_h.flags & _flagExtBlockPointers) != 0;

  // the byte offset where block [i] ends (the start of block i + 1 when
  // that one is not a direct pointer)
  int _endOf(int i) {
    if (i < 0) return _tableEnd;
    final p = _ptrs[i];
    if (_ext && (p & _blkDirect) != 0) {
      final start = (p & 0x3FFFFFFF) << 2;
      if ((p & _blkUncompressed) != 0) return start + _outSize(i);
      final l = readAt(_h._stream!, start, 2);
      if (l.length < 2) return start;
      final len = _h.bigEndian ? (l[0] << 8) | l[1] : l[0] | (l[1] << 8);
      return start + 2 + len;
    }
    return _ext ? p & 0x3FFFFFFF : p;
  }

  int _outSize(int i) {
    final bs = _h.blockSize;
    final left = _it.size - i * bs;
    return left < bs ? left : bs;
  }

  Uint8List _block(int i) {
    final outSize = _outSize(i);
    final p = _ptrs[i];
    final s = _h._stream!;
    int start;
    int len;
    var uncompressed = false;
    if (_ext && (p & _blkDirect) != 0) {
      start = (p & 0x3FFFFFFF) << 2;
      if ((p & _blkUncompressed) != 0) {
        uncompressed = true;
        len = outSize;
      } else {
        final l = readAt(s, start, 2);
        if (l.length < 2) _bad('bad block');
        len = _h.bigEndian ? (l[0] << 8) | l[1] : l[0] | (l[1] << 8);
        start += 2;
      }
    } else {
      start = _endOf(i - 1);
      len = (_ext ? p & 0x3FFFFFFF : p) - start;
      uncompressed = _ext && (p & _blkUncompressed) != 0;
    }
    if (len == 0) return Uint8List(outSize); // a hole
    if (len < 0 || len > 2 * _h.blockSize + 64) _bad('bad block pointer');
    final raw = readAt(s, start, len);
    if (raw.length < len) {
      throw const SevenZipException(
          'cramfs: truncated block', SevenZipError.unexpectedEnd);
    }
    final d = uncompressed ? raw : zlibInflateBytes(raw);
    if (d.length != outSize) _bad('bad block size');
    return d;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    final size = _it.size;
    if (len <= 0 || _pos >= size) return 0;
    final bs = _h.blockSize;
    final idx = _pos ~/ bs;
    var d = _data;
    if (idx != _blk || d == null) {
      d = _block(idx);
      _data = d;
      _blk = idx;
    }
    final inBlk = _pos - idx * bs;
    var n = d.length - inBlk;
    if (n > len) n = len;
    buf.setRange(off, off + n, d, inBlk);
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
