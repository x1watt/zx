// SquashFS images (read only), version 4.0: the superblock, the metadata
// blocks (inode, directory, fragment and id tables), the data blocks and
// the fragment blocks, with the gzip (zlib), lzma (lzma-alone header),
// xz, lzo, lz4 and zstd compressors. Extended attributes and the export
// table are ignored.
//
// Written from the format description "SquashFS binary format"
// (dr-emann.github.io/squashfs, format facts only) and checked black box
// against mksquashfs/unsquashfs 4.6 and 7-Zip. No squashfs-tools or Linux
// code was used. Versions before 4.0 (the "sqsh" big endian magic and the
// 1.x to 3.x layouts) are not supported: their open fails.

import 'dart:typed_data';

import '../../codec/deflate/zlib.dart';
import '../../codec/lz4/lz4.dart';
import '../../codec/lzma/lzma_dec.dart';
import '../../codec/lzo/lzo1x.dart';
import '../../codec/zstd/zstd.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import '../item_streams.dart';
import '../xz/xz_dec.dart' show XzDecoder, XzDecodeResult;

/// "hsqs" read as a little endian u32.
const int kSquashfsMagic = 0x73717368;

const int _kSuperSize = 96;
const int _kMetaSize = 8192;

// inode types (basic; the extended ones are +7; 6 fifo, 7 socket)
const int _tDir = 1;
const int _tFile = 2;
const int _tSymlink = 3;
const int _tBlk = 4;
const int _tChr = 5;

const List<String> _compNames = [
  '',
  'gzip',
  'lzma',
  'lzo',
  'xz',
  'lz4',
  'zstd',
];

int _le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
int _le64(Uint8List b, int o) => _le32(b, o) | (_le32(b, o + 4) << 32);

/// IsArc check of a SquashFS 4.0 superblock: 1 yes, 0 no, 2 need more.
int isArcSquashfs(Uint8List p, int size) {
  if (size < 4) return 2;
  if (_le32(p, 0) != kSquashfsMagic) return 0;
  if (size < _kSuperSize) return 2;
  return _superOk(p) ? 1 : 0;
}

bool _superOk(Uint8List p) {
  if (_le32(p, 0) != kSquashfsMagic) return false;
  if (_le16(p, 28) != 4) return false;
  final bs = _le32(p, 12);
  final log = _le16(p, 22);
  if (log < 12 || log > 20 || bs != 1 << log) return false;
  final comp = _le16(p, 20);
  return comp >= 1 && comp <= 6;
}

/// A SquashFS item (a directory entry).
class SquashfsItem {
  String path = '';
  int type = 0; // basic inode type 1..7
  int mode = 0; // st_mode
  int uid = 0;
  int gid = 0;
  int mtime = 0;
  int ino = 0;
  int nlink = 1;
  int size = 0;
  int rdev = 0;
  // file data
  int blocksStart = 0;
  Uint32List? blockSizes;
  int frag = -1;
  int fragOffset = 0;
  String? symLink;
  Uint8List? linkBytes;
  String? hardLink;
  // directory listing
  int dirBlock = 0;
  int dirOffset = 0;
  int dirSize = 0;

  bool get isDir => type == _tDir;
  bool get isDevice => type == _tBlk || type == _tChr;

  int get packSize {
    final bl = blockSizes;
    if (bl == null) return 0;
    var s = 0;
    for (var i = 0; i < bl.length; i++) {
      s += bl[i] & 0xFFFFFF;
    }
    return s;
  }
}

class _Meta {
  final Uint8List data;
  final int next;
  _Meta(this.data, this.next);
}

/// A cursor in a chain of metadata blocks.
class _MetaCursor {
  final SquashfsHandler _h;
  int _block;
  int _off;
  Uint8List _data;
  int _next;

  _MetaCursor._(this._h, this._block, this._off, _Meta m)
      : _data = m.data,
        _next = m.next;

  factory _MetaCursor(SquashfsHandler h, int block, int off) =>
      _MetaCursor._(h, block, off, h._meta(block));

  void _advance() {
    _block = _next;
    final m = _h._meta(_block);
    _data = m.data;
    _next = m.next;
    _off = 0;
  }

  Uint8List bytes(int n) {
    if (_off + n <= _data.length) {
      final r = Uint8List.sublistView(_data, _off, _off + n);
      _off += n;
      return r;
    }
    final out = Uint8List(n);
    var done = 0;
    while (done < n) {
      if (_off >= _data.length) _advance();
      var k = _data.length - _off;
      if (k > n - done) k = n - done;
      out.setRange(done, done + k, _data, _off);
      _off += k;
      done += k;
    }
    return out;
  }

  int u16() {
    if (_off + 2 <= _data.length) {
      final v = _le16(_data, _off);
      _off += 2;
      return v;
    }
    return _le16(bytes(2), 0);
  }

  int u32() {
    if (_off + 4 <= _data.length) {
      final v = _le32(_data, _off);
      _off += 4;
      return v;
    }
    return _le32(bytes(4), 0);
  }

  int u64() {
    final lo = u32();
    return lo | (u32() << 32);
  }
}

Never _bad(String what) => throw SevenZipException('SquashFS: $what');

/// The SquashFS handler.
class SquashfsHandler extends ReadOnlyHandler {
  SeekableInStream? _stream;
  final List<SquashfsItem> items = [];
  int _len = 0;

  int blockSize = 0;
  int compression = 0;
  int flags = 0;
  int _mtime = 0;
  int _bytesUsed = 0;
  int _inodeTable = 0;
  int _dirTable = 0;
  bool _headersError = false;
  bool _unexpectedEnd = false;

  Uint32List _ids = Uint32List(0);
  Int64List _fragStart = Int64List(0);
  Uint32List _fragSize = Uint32List(0);

  // metadata block cache (open only)
  final Map<int, _Meta> _metaCache = {};

  // last fragment block
  int _cachedFrag = -1;
  Uint8List? _cachedFragData;

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
    Kpid.deviceMajor,
    Kpid.deviceMinor,
    Kpid.symLink,
    Kpid.hardLink,
  ];

  static const List<int> _arcProps = [
    Kpid.method,
    Kpid.clusterSize,
    Kpid.mTime,
    Kpid.subType,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;
  @override
  int get timePrec => FileTimeType.unix;

  String get methodName => _compNames[compression];

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final sb = readAt(stream, 0, _kSuperSize);
    if (sb.length < _kSuperSize || !_superOk(sb)) return false;
    _stream = stream;
    _len = stream.length;
    blockSize = _le32(sb, 12);
    compression = _le16(sb, 20);
    flags = _le16(sb, 24);
    _mtime = _le32(sb, 8);
    final fragCount = _le32(sb, 16);
    final idCount = _le16(sb, 26);
    final rootRef = _le64(sb, 32);
    _bytesUsed = _le64(sb, 40);
    final idStart = _le64(sb, 48);
    _inodeTable = _le64(sb, 64);
    _dirTable = _le64(sb, 72);
    final fragTable = _le64(sb, 80);
    if (_bytesUsed > _len) _unexpectedEnd = true;
    if (_inodeTable >= _len || _dirTable >= _len) {
      close();
      return false;
    }
    try {
      _ids = Uint32List(idCount);
      if (idCount > 0) {
        final raw = _readTable(idStart, idCount * 4);
        for (var i = 0; i < idCount; i++) {
          _ids[i] = _le32(raw, i * 4);
        }
      }
      if (fragCount > 0 && fragTable != -1 && (flags & 0x10) == 0) {
        final raw = _readTable(fragTable, fragCount * 16);
        _fragStart = Int64List(fragCount);
        _fragSize = Uint32List(fragCount);
        for (var i = 0; i < fragCount; i++) {
          _fragStart[i] = _le64(raw, i * 16);
          _fragSize[i] = _le32(raw, i * 16 + 8);
        }
      }
      final root = _readInode(rootRef);
      if (!root.isDir) _bad('root is not a directory');
      _walk(root);
    } on SevenZipException catch (e) {
      if (items.isEmpty) {
        close();
        return false;
      }
      if (e.kind == SevenZipError.unexpectedEnd) {
        _unexpectedEnd = true;
      } else {
        _headersError = true;
      }
    } finally {
      _metaCache.clear();
    }
    return true;
  }

  @override
  void close() {
    _stream = null;
    items.clear();
    _metaCache.clear();
    _cachedFrag = -1;
    _cachedFragData = null;
    _headersError = false;
    _unexpectedEnd = false;
    _ids = Uint32List(0);
    _fragStart = Int64List(0);
    _fragSize = Uint32List(0);
  }

  // A lookup table (ids, fragments): a list of u64 positions of metadata
  // blocks at [start], holding [size] bytes in all.
  Uint8List _readTable(int start, int size) {
    final nBlocks = (size + _kMetaSize - 1) ~/ _kMetaSize;
    final ptrs = readAt(_stream!, start, nBlocks * 8);
    if (ptrs.length < nBlocks * 8) {
      throw const SevenZipException(
          'SquashFS: truncated table', SevenZipError.unexpectedEnd);
    }
    final out = Uint8List(size);
    var done = 0;
    for (var i = 0; i < nBlocks && done < size; i++) {
      final m = _readMeta(_le64(ptrs, i * 8));
      var k = m.data.length;
      if (k > size - done) k = size - done;
      out.setRange(done, done + k, m.data);
      done += k;
    }
    if (done < size) _bad('short table');
    return out;
  }

  _Meta _meta(int pos) => _metaCache[pos] ??= _readMeta(pos);

  _Meta _readMeta(int pos) {
    final s = _stream!;
    final h = readAt(s, pos, 2);
    if (h.length < 2) {
      throw const SevenZipException(
          'SquashFS: metadata beyond the end', SevenZipError.unexpectedEnd);
    }
    final hv = _le16(h, 0);
    final size = hv & 0x7FFF;
    if (size == 0 || size > _kMetaSize) _bad('bad metadata block');
    final raw = readAt(s, pos + 2, size);
    if (raw.length < size) {
      throw const SevenZipException(
          'SquashFS: truncated metadata', SevenZipError.unexpectedEnd);
    }
    final data = (hv & 0x8000) != 0 ? raw : _decompress(raw, _kMetaSize);
    return _Meta(data, pos + 2 + size);
  }

  /// Decompresses one block of the image's compressor ([maxOut] is the
  /// largest possible output).
  Uint8List _decompress(Uint8List src, int maxOut) {
    switch (compression) {
      case 1:
        final r = zlibInflateBytes(src);
        if (r.length > maxOut) _bad('block too large');
        return r;
      case 2:
        // lzma-alone header: 5 property bytes and a u64 size
        if (src.length < 13) _bad('bad lzma block');
        final out = Uint8List(maxOut);
        final r = lzmaDecode(out, Uint8List.sublistView(src, 13),
            Uint8List.sublistView(src, 0, 5), lzmaFinishAny);
        if (r.res != szOk) {
          if (r.res == szErrorInputEof) {
            throw const SevenZipException(
                'SquashFS: truncated lzma block', SevenZipError.unexpectedEnd);
          }
          _bad('lzma data error');
        }
        return Uint8List.sublistView(out, 0, r.destLen);
      case 3:
        return lzo1xDecompress(src, outSize: maxOut);
      case 4:
        final out = MemoryOutStream(maxOut);
        final dec = XzDecoder();
        final r = dec.decode(MemoryInStream(src), out);
        if (r == XzDecodeResult.notImplemented) {
          throw const SevenZipException('SquashFS: unsupported xz filter',
              SevenZipError.unsupportedMethod);
        }
        if (r != XzDecodeResult.ok) _bad('xz data error');
        final b = out.toBytes();
        if (b.length > maxOut) _bad('block too large');
        return b;
      case 5:
        return lz4BlockDecompress(src, outSize: maxOut);
      case 6:
        return zstdDecompress(src, maxOutput: maxOut);
    }
    throw const SevenZipException(
        'SquashFS: unknown compressor', SevenZipError.unsupportedMethod);
  }

  int _id(int i) {
    if (i >= _ids.length) {
      _headersError = true;
      return 0;
    }
    return _ids[i];
  }

  SquashfsItem _readInode(int ref) {
    final c = _MetaCursor(this, _inodeTable + (ref >> 16), ref & 0xFFFF);
    final it = SquashfsItem();
    final t = c.u16();
    final perm = c.u16();
    it.uid = _id(c.u16());
    it.gid = _id(c.u16());
    it.mtime = c.u32();
    it.ino = c.u32();
    if (t < 1 || t > 14) _bad('bad inode type $t');
    final ext = t > 7;
    final bt = ext ? t - 7 : t;
    it.type = bt;
    const fmt = [0, 0x4000, 0x8000, 0xA000, 0x6000, 0x2000, 0x1000, 0xC000];
    it.mode = fmt[bt] | (perm & 0xFFF);
    switch (bt) {
      case _tDir:
        if (!ext) {
          it.dirBlock = c.u32();
          it.nlink = c.u32();
          it.dirSize = c.u16();
          it.dirOffset = c.u16();
          c.u32(); // parent
        } else {
          it.nlink = c.u32();
          it.dirSize = c.u32();
          it.dirBlock = c.u32();
          c.u32(); // parent
          c.u16(); // index count (the index is not needed)
          it.dirOffset = c.u16();
          c.u32(); // xattr
        }
      case _tFile:
        if (!ext) {
          it.blocksStart = c.u32();
          it.frag = c.u32();
          it.fragOffset = c.u32();
          it.size = c.u32();
        } else {
          it.blocksStart = c.u64();
          it.size = c.u64();
          c.u64(); // sparse
          it.nlink = c.u32();
          it.frag = c.u32();
          it.fragOffset = c.u32();
          c.u32(); // xattr
        }
        if (it.frag == 0xFFFFFFFF) it.frag = -1;
        final bs = blockSize;
        final n = it.frag >= 0 ? it.size ~/ bs : (it.size + bs - 1) ~/ bs;
        if (n > (_len ~/ 2) + 1) _bad('bad file size');
        final bl = Uint32List(n);
        final raw = c.bytes(n * 4);
        for (var i = 0; i < n; i++) {
          bl[i] = _le32(raw, i * 4);
        }
        it.blockSizes = bl;
      case _tSymlink:
        it.nlink = c.u32();
        final n = c.u32();
        if (n > 65536) _bad('bad symlink');
        final target = Uint8List.fromList(c.bytes(n));
        it.linkBytes = target;
        it.symLink = bytesToName(target);
        it.size = n;
      case _tBlk:
      case _tChr:
        it.nlink = c.u32();
        it.rdev = c.u32();
      default:
        it.nlink = c.u32();
    }
    return it;
  }

  // Reads the directory tree in depth first order (as unsquashfs lists
  // it), parents before their children.
  void _walk(SquashfsItem root) {
    final stack = _listDir(root, '').reversed.toList();
    final firstOfIno = <int, int>{};
    final seenDirs = <int>{root.ino};
    while (stack.isNotEmpty) {
      final it = stack.removeLast();
      if (!it.isDir) {
        final first = firstOfIno[it.ino];
        if (first == null) {
          firstOfIno[it.ino] = items.length;
        } else {
          it.hardLink = items[first].path;
        }
      }
      items.add(it);
      if (it.isDir) {
        if (seenDirs.add(it.ino)) {
          stack.addAll(_listDir(it, it.path).reversed);
        } else {
          _headersError = true;
        }
      }
    }
  }

  // The entries of directory [dir], with their inodes.
  List<SquashfsItem> _listDir(SquashfsItem dir, String prefix) {
    final list = <SquashfsItem>[];
    var left = dir.dirSize - 3;
    if (left <= 0) return list;
    final c = _MetaCursor(this, _dirTable + dir.dirBlock, dir.dirOffset);
    while (left >= 12) {
      final count = c.u32() + 1;
      final start = c.u32();
      c.u32(); // base inode number
      left -= 12;
      if (count > 256) _bad('bad directory header');
      for (var i = 0; i < count; i++) {
        if (left < 8) _bad('bad directory');
        final off = c.u16();
        c.u16(); // inode offset (the inode has its own number)
        c.u16(); // type
        final nameSize = c.u16() + 1;
        left -= 8 + nameSize;
        if (left < 0) _bad('bad directory entry');
        final name = bytesToName(c.bytes(nameSize));
        if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
          _headersError = true;
          continue;
        }
        final it = _readInode((start << 16) | off);
        it.path = prefix.isEmpty ? name : '$prefix/$name';
        list.add(it);
      }
    }
    return list;
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
      case Kpid.packSize:
        return it.type == _tFile ? it.packSize : null;
      case Kpid.mTime:
        return unixSecondsToFileTime(it.mtime);
      case Kpid.posixAttrib:
        return it.mode;
      case Kpid.links:
        return it.nlink;
      case Kpid.iNode:
        return it.ino;
      case Kpid.userId:
        return it.uid;
      case Kpid.groupId:
        return it.gid;
      case Kpid.deviceMajor:
        return it.isDevice ? (it.rdev & 0xFFF00) >> 8 : null;
      case Kpid.deviceMinor:
        return it.isDevice
            ? (it.rdev & 0xFF) | ((it.rdev >> 12) & 0xFFF00)
            : null;
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
      case Kpid.method:
        return methodName;
      case Kpid.clusterSize:
        return blockSize;
      case Kpid.mTime:
        return unixSecondsToFileTime(_mtime);
      case Kpid.subType:
        return 'SquashFS 4.0';
      case Kpid.phySize:
        // images are padded to 4 KiB (mksquashfs, 7-Zip counts the pad)
        final p = (_bytesUsed + 4095) & ~4095;
        return p <= _len ? p : _bytesUsed;
      case Kpid.errorFlags:
        var f = 0;
        if (_unexpectedEnd) f |= ErrorFlags.unexpectedEnd;
        if (_headersError) f |= ErrorFlags.headersError;
        return f;
    }
    return null;
  }

  /// Data block [idx] of file [it] (the fragment tail for the last one).
  Uint8List _fileBlock(SquashfsItem it, Int64List offsets, int idx) {
    final bs = blockSize;
    final bl = it.blockSizes!;
    var outSize = it.size - idx * bs;
    if (outSize > bs) outSize = bs;
    if (idx < bl.length) {
      final sf = bl[idx];
      final size = sf & 0xFFFFFF;
      if (size == 0) return Uint8List(outSize); // sparse
      final raw = readAt(_stream!, offsets[idx], size);
      if (raw.length < size) {
        throw const SevenZipException(
            'SquashFS: truncated data block', SevenZipError.unexpectedEnd);
      }
      final data = (sf & 0x1000000) != 0 ? raw : _decompress(raw, bs);
      if (data.length != outSize) _bad('bad data block size');
      return data;
    }
    final f = it.frag;
    if (f < 0 || f >= _fragStart.length) _bad('bad fragment index');
    var fd = _cachedFragData;
    if (_cachedFrag != f || fd == null) {
      final sf = _fragSize[f];
      final size = sf & 0xFFFFFF;
      final raw = readAt(_stream!, _fragStart[f], size);
      if (raw.length < size) {
        throw const SevenZipException(
            'SquashFS: truncated fragment', SevenZipError.unexpectedEnd);
      }
      fd = (sf & 0x1000000) != 0 ? raw : _decompress(raw, bs);
      _cachedFrag = f;
      _cachedFragData = fd;
    }
    final end = it.fragOffset + outSize;
    if (end > fd.length) _bad('bad fragment offset');
    return Uint8List.sublistView(fd, it.fragOffset, end);
  }

  SeekableInStream _open(int index) {
    final it = items[index];
    if (it.type == _tSymlink) return MemoryInStream(it.linkBytes!);
    if (it.type != _tFile) return MemoryInStream(Uint8List(0));
    return _SqFileStream(this, it);
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(items.length, indices, testMode, cb,
        (i) => items[i].isDir, (i) => items[i].isDir ? 0 : items[i].size, _open,
        expectedSize: (i) => items[i].type == _tFile ? items[i].size : null);
  }

  @override
  SeekableInStream? getStream(int index) {
    if (_stream == null || index < 0 || index >= items.length) return null;
    if (items[index].isDir) return null;
    return _open(index);
  }
}

/// The data of a regular file, decoded block by block.
class _SqFileStream implements SeekableInStream {
  final SquashfsHandler _h;
  final SquashfsItem _it;
  final Int64List _offsets;
  int _pos = 0;
  int _blk = -1;
  Uint8List? _data;

  _SqFileStream(this._h, this._it) : _offsets = _blockOffsets(_it);

  static Int64List _blockOffsets(SquashfsItem it) {
    final bl = it.blockSizes!;
    final o = Int64List(bl.length);
    var p = it.blocksStart;
    for (var i = 0; i < bl.length; i++) {
      o[i] = p;
      p += bl[i] & 0xFFFFFF;
    }
    return o;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    final size = _it.size;
    if (len <= 0 || _pos >= size) return 0;
    final bs = _h.blockSize;
    final idx = _pos ~/ bs;
    var d = _data;
    if (idx != _blk || d == null) {
      d = _h._fileBlock(_it, _offsets, idx);
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
