// ext2, ext3 and ext4 file systems (read only): the superblock, the group
// descriptors (32 and 64 byte, meta_bg, sparse_super and sparse_super2
// backups, flex_bg through the descriptors), inodes of 128 bytes and more
// (the extra times with nanoseconds and epoch bits, the creation time,
// the high bits of uid, gid, size and block count), the block maps
// (direct, indirect, double and triple indirect, holes), the extent tree
// (with uninitialized extents read as zeros), inline data (files and
// folders), fast and slow symlinks, hard links, devices, fifos and
// sockets. Hashed (htree) folders are read linearly, as their leaf blocks
// are ordinary directory blocks. The journal is not replayed: a file
// system that needs recovery is opened as it is on disk, with a warning.
// The journal inode is listed as "[SYS]/Journal", as 7-Zip lists it.
//
// Written for this package from the on-disk layout described in the Linux
// kernel's Documentation/filesystems/ext4 text ("ext4 Data Structures and
// Algorithms": superblock, block group descriptors, inode table, extent
// tree, directory entries, inline data, extended attributes) and the
// e2fsprogs documentation; no file system driver or e2fsprogs source was
// read. Checked black box with mke2fs -d, debugfs and 7-Zip's listing.

import 'dart:convert';
import 'dart:typed_data';

import '../../io/streams.dart';
import '../archive_types.dart';
import '../iso/disc_streams.dart' show RunList, RunsInStream, le16, le32;
import '../item_streams.dart';

/// Offset of the superblock.
const int kExtSuperOffset = 1024;

// feature flags
const int _compatHasJournal = 0x4;
const int _compatSparseSuper2 = 0x200;
const int _incompatFileType = 0x2;
const int _incompatRecover = 0x4;
const int _incompatJournalDev = 0x8;
const int _incompatMetaBg = 0x10;
const int _incompatExtents = 0x40;
const int _incompat64Bit = 0x80;
const int _incompatFlexBg = 0x200;
const int _incompatInlineData = 0x8000;
const int _roSparseSuper = 0x1;
const int _roHugeFile = 0x8;

// inode flags
const int _flHugeFile = 0x40000;
const int _flExtents = 0x80000;
const int _flInlineData = 0x10000000;

const List<(int, String)> _compatNames = [
  (0x1, 'DIR_PREALLOC'),
  (0x2, 'IMAGIC_INODES'),
  (0x4, 'HAS_JOURNAL'),
  (0x8, 'EXT_ATTR'),
  (0x10, 'RESIZE_INODE'),
  (0x20, 'DIR_INDEX'),
  (0x40, 'LAZY_BG'),
  (0x200, 'SPARSE_SUPER2'),
  (0x400, 'FAST_COMMIT'),
  (0x800, 'STABLE_INODES'),
  (0x1000, 'ORPHAN_FILE'),
];

const List<(int, String)> _incompatNames = [
  (0x1, 'COMPRESSION'),
  (0x2, 'FILETYPE'),
  (0x4, 'RECOVER'),
  (0x8, 'JOURNAL_DEV'),
  (0x10, 'META_BG'),
  (0x40, 'EXTENTS'),
  (0x80, '64BIT'),
  (0x100, 'MMP'),
  (0x200, 'FLEX_BG'),
  (0x400, 'EA_INODE'),
  (0x1000, 'DIRDATA'),
  (0x2000, 'CSUM_SEED'),
  (0x4000, 'LARGEDIR'),
  (0x8000, 'INLINE_DATA'),
  (0x10000, 'ENCRYPT'),
  (0x20000, 'CASEFOLD'),
];

const List<(int, String)> _roNames = [
  (0x1, 'SPARSE_SUPER'),
  (0x2, 'LARGE_FILE'),
  (0x8, 'HUGE_FILE'),
  (0x10, 'GDT_CSUM'),
  (0x20, 'DIR_NLINK'),
  (0x40, 'EXTRA_ISIZE'),
  (0x100, 'QUOTA'),
  (0x200, 'BIGALLOC'),
  (0x400, 'METADATA_CSUM'),
  (0x1000, 'READONLY'),
  (0x2000, 'PROJECT'),
  (0x8000, 'VERITY'),
  (0x10000, 'ORPHAN_PRESENT'),
];

const List<(int, String)> _inodeFlagNames = [
  (0x10, 'IMMUTABLE'),
  (0x20, 'APPEND'),
  (0x40, 'NODUMP'),
  (0x80, 'NOATIME'),
  (0x800, 'ENCRYPT'),
  (0x1000, 'INDEX'),
  (0x4000, 'JOURNAL_DATA'),
  (0x40000, 'HUGE_FILE'),
  (0x80000, 'EXTENTS'),
  (0x100000, 'VERITY'),
  (0x200000, 'EA_INODE'),
  (0x10000000, 'INLINE_DATA'),
  (0x20000000, 'PROJINHERIT'),
  (0x40000000, 'CASEFOLD'),
];

String _flagNames(int v, List<(int, String)> names) {
  final l = <String>[];
  var rest = v;
  for (final (bit, name) in names) {
    if ((v & bit) != 0) {
      l.add(name);
      rest &= ~bit;
    }
  }
  if (rest != 0) l.add('0x${rest.toRadixString(16)}');
  return l.join(' ');
}

/// The superblock checks of IsArc and Open on the 1024 bytes at [o].
bool _superValid(Uint8List b, int o) {
  if (b.length < o + 1024) return false;
  if (le16(b, o + 0x38) != 0xEF53) return false;
  final logBs = le32(b, o + 0x18);
  if (logBs > 6) return false;
  if (le32(b, o + 0x20) == 0 || le32(b, o + 0x28) == 0) return false;
  if (le32(b, o + 0x00) == 0 || le32(b, o + 0x04) == 0) return false;
  final rev = le32(b, o + 0x4C);
  if (rev > 1) return false;
  if (rev == 1) {
    final isz = le16(b, o + 0x58);
    if (isz < 128 || (isz & (isz - 1)) != 0 || isz > (1024 << logBs)) {
      return false;
    }
  }
  return true;
}

/// IsArc for the format table.
int isArcExt(Uint8List p, int size) {
  if (size < kExtSuperOffset + 1024) return 2;
  return _superValid(p, kExtSuperOffset) ? 1 : 0;
}

/// A file, folder or special file of the file system.
class ExtItem {
  String path = '';
  int ino = 0;
  int mode = 0;
  int uid = 0;
  int gid = 0;
  int size = 0;
  int links = 0;
  int flags = 0;
  int allocated = 0;
  int? mTime;
  int? aTime;
  int? cTime; // creation (crtime)
  int? changeTime; // inode change (ctime)
  String? symLink;
  String? hardLink;
  int devMajor = 0;
  int devMinor = 0;

  bool get isDir => (mode & 0xF000) == 0x4000;
  bool get isReg => (mode & 0xF000) == 0x8000;
  bool get isSymLink => (mode & 0xF000) == 0xA000;
  bool get isDevice => (mode & 0xF000) == 0x2000 || (mode & 0xF000) == 0x6000;
}

/// The ext2/3/4 handler.
class ExtHandler extends ReadOnlyHandler {
  SeekableInStream? _s;
  final List<ExtItem> items = [];
  Uint8List _sb = Uint8List(0);
  int blockSize = 0;
  int _blocksCount = 0;
  int _firstDataBlock = 0;
  int _blocksPerGroup = 0;
  int _inodesPerGroup = 0;
  int _inodesCount = 0;
  int _inodeSize = 128;
  int _descSize = 32;
  int _groups = 0;
  int compat = 0;
  int incompat = 0;
  int roCompat = 0;
  Int64List _inodeTable = Int64List(0);
  bool _headersError = false;
  bool _unexpectedEnd = false;

  // small cache of metadata blocks
  final Map<int, Uint8List> _blocks = {};

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.posixAttrib,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.aTime,
    Kpid.changeTime,
    Kpid.iNode,
    Kpid.links,
    Kpid.symLink,
    Kpid.hardLink,
    Kpid.characts,
    Kpid.userId,
    Kpid.groupId,
    Kpid.deviceMajor,
    Kpid.deviceMinor,
  ];

  static const List<int> _arcProps = [
    Kpid.fileSystem,
    Kpid.clusterSize,
    Kpid.freeSpace,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.hostOS,
    Kpid.volumeName,
    Kpid.id,
    Kpid.characts,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  @override
  int get timePrec => 16 + 7; // 100 ns

  /// Whether the journal needs to be replayed (it is not).
  bool get needsRecovery => (incompat & _incompatRecover) != 0;

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final sb = readAt(stream, kExtSuperOffset, 1024);
    if (!_superValid(sb, 0)) return false;
    _s = stream;
    _sb = sb;
    blockSize = 1024 << le32(sb, 0x18);
    compat = le32(sb, 0x5C);
    incompat = le32(sb, 0x60);
    roCompat = le32(sb, 0x64);
    if ((incompat & _incompatJournalDev) != 0) {
      // an external journal device holds no files
      _s = null;
      return false;
    }
    _inodesCount = le32(sb, 0x00);
    _blocksCount = le32(sb, 0x04);
    if ((incompat & _incompat64Bit) != 0) {
      _blocksCount |= le32(sb, 0x150) << 32;
      _descSize = le16(sb, 0xFE);
      if (_descSize < 32 || (_descSize & (_descSize - 1)) != 0) {
        _s = null;
        return false;
      }
    }
    _firstDataBlock = le32(sb, 0x14);
    _blocksPerGroup = le32(sb, 0x20);
    _inodesPerGroup = le32(sb, 0x28);
    if (le32(sb, 0x4C) >= 1) _inodeSize = le16(sb, 0x58);
    if (_blocksCount <= _firstDataBlock) {
      _s = null;
      return false;
    }
    _groups = (_blocksCount - _firstDataBlock + _blocksPerGroup - 1) ~/
        _blocksPerGroup;
    if (_groups * _inodesPerGroup < _inodesCount ||
        _groups > (1 << 24) ||
        _inodesPerGroup > blockSize * 8) {
      _s = null;
      return false;
    }
    if (!_readGroupDescriptors()) {
      _s = null;
      return false;
    }
    if (stream.length < _blocksCount * blockSize) _unexpectedEnd = true;
    _readTree();
    _blocks.clear();
    return true;
  }

  @override
  void close() {
    _s = null;
    items.clear();
    _sb = Uint8List(0);
    blockSize = 0;
    _inodeSize = 128;
    _descSize = 32;
    _inodeTable = Int64List(0);
    _headersError = false;
    _unexpectedEnd = false;
    _blocks.clear();
    compat = incompat = roCompat = 0;
  }

  Uint8List _block(int blk) {
    var b = _blocks[blk];
    if (b != null) return b;
    if (_blocks.length >= 32) _blocks.clear();
    b = readAt(_s!, blk * blockSize, blockSize);
    if (b.length < blockSize) {
      _unexpectedEnd = true;
      b = Uint8List(blockSize)..setRange(0, b.length, b);
    }
    _blocks[blk] = b;
    return b;
  }

  static bool _isPowerOf(int g, int base) {
    var v = base;
    while (v < g) {
      v *= base;
    }
    return v == g;
  }

  // whether group [g] holds a superblock backup
  bool _hasSuper(int g) {
    if (g == 0) return true;
    if ((compat & _compatSparseSuper2) != 0) {
      return g == le32(_sb, 0x24C) || g == le32(_sb, 0x250);
    }
    if ((roCompat & _roSparseSuper) == 0) return true;
    if (g == 1) return true;
    return _isPowerOf(g, 3) || _isPowerOf(g, 5) || _isPowerOf(g, 7);
  }

  int _groupFirstBlock(int g) => _firstDataBlock + g * _blocksPerGroup;

  bool _readGroupDescriptors() {
    final perBlock = blockSize ~/ _descSize;
    final metaBg = (incompat & _incompatMetaBg) != 0;
    final firstMeta = le32(_sb, 0x104);
    final t = Int64List(_groups);
    for (var g = 0; g < _groups; g++) {
      final m = g ~/ perBlock;
      int blk;
      if (!metaBg || m < firstMeta) {
        blk = _firstDataBlock + 1 + m;
      } else {
        final g0 = m * perBlock;
        blk = _groupFirstBlock(g0) + (_hasSuper(g0) ? 1 : 0);
      }
      if (blk >= _blocksCount) return false;
      final b = _block(blk);
      final o = (g % perBlock) * _descSize;
      var it = le32(b, o + 8);
      if (_descSize >= 64) it |= le32(b, o + 0x28) << 32;
      t[g] = it;
    }
    _inodeTable = t;
    return true;
  }

  /// The raw inode [ino], or null when out of range.
  Uint8List? readInode(int ino) {
    if (ino < 1 || ino > _inodesCount) return null;
    final g = (ino - 1) ~/ _inodesPerGroup;
    final idx = (ino - 1) % _inodesPerGroup;
    final pos = _inodeTable[g] * blockSize + idx * _inodeSize;
    final blk = pos ~/ blockSize;
    if (blk <= 0 || blk >= _blocksCount) return null;
    final b = _block(blk);
    final o = pos - blk * blockSize;
    return Uint8List.fromList(Uint8List.sublistView(b, o, o + _inodeSize));
  }

  // the field at [off] of the large inode is present
  bool _hasField(Uint8List ind, int off) {
    if (_inodeSize <= 128) return false;
    final extra = le16(ind, 0x80);
    return 128 + extra >= off + 4 && off + 4 <= _inodeSize;
  }

  int? _time(Uint8List ind, int off, int extraOff) {
    var secs = le32(ind, off);
    if (secs >= 0x80000000) secs -= 0x100000000;
    var ns = 0;
    if (extraOff != 0 && _hasField(ind, extraOff)) {
      final e = le32(ind, extraOff);
      secs += (e & 3) << 32;
      ns = e >> 2;
      if (ns > 999999999) ns = 0;
    }
    return (secs + 11644473600) * 10000000 + ns ~/ 100;
  }

  int _sizeOf(Uint8List ind) {
    final mode = le16(ind, 0);
    var size = le32(ind, 4);
    if ((mode & 0xF000) != 0x4000 || (incompat & 0x4000) != 0) {
      size |= le32(ind, 0x6C) << 32;
    }
    return size;
  }

  ExtItem _itemOf(int ino, Uint8List ind, String path) {
    final it = ExtItem()
      ..path = path
      ..ino = ino
      ..mode = le16(ind, 0)
      ..uid = le16(ind, 2) | (le16(ind, 0x78) << 16)
      ..gid = le16(ind, 0x18) | (le16(ind, 0x7A) << 16)
      ..links = le16(ind, 0x1A)
      ..flags = le32(ind, 0x20)
      ..size = _sizeOf(ind);
    var blocks = le32(ind, 0x1C);
    if ((roCompat & _roHugeFile) != 0) {
      blocks |= le16(ind, 0x74) << 32;
      if ((it.flags & _flHugeFile) != 0) {
        blocks *= blockSize ~/ 512;
      }
    }
    it.allocated = blocks * 512;
    it.aTime = _time(ind, 0x08, 0x8C);
    it.changeTime = _time(ind, 0x0C, 0x84);
    it.mTime = _time(ind, 0x10, 0x88);
    if (_hasField(ind, 0x90)) it.cTime = _time(ind, 0x90, 0x94);
    if (it.isDevice) {
      final b0 = le32(ind, 0x28);
      if (b0 != 0) {
        it.devMajor = (b0 >> 8) & 0xFF;
        it.devMinor = b0 & 0xFF;
      } else {
        final b1 = le32(ind, 0x2C);
        it.devMajor = (b1 & 0xFFF00) >> 8;
        it.devMinor = (b1 & 0xFF) | ((b1 >> 12) & 0xFFF00);
      }
    }
    if (it.isSymLink) it.symLink = _readSymlink(ind, it);
    return it;
  }

  String? _readSymlink(Uint8List ind, ExtItem it) {
    final size = it.size;
    if (size <= 0 || size > 65536) return null;
    Uint8List t;
    final xattrBlocks = le32(ind, 0x68) != 0 ? blockSize ~/ 512 : 0;
    final dataBlocks = le32(ind, 0x1C) - xattrBlocks;
    if ((it.flags & _flInlineData) == 0 &&
        (it.flags & _flExtents) == 0 &&
        size < 60 &&
        dataBlocks <= 0) {
      t = Uint8List.sublistView(ind, 0x28, 0x28 + size);
    } else {
      final st = _dataStream(ind, size);
      t = Uint8List(size);
      final n = readFully(st, t, 0, size);
      if (n < size) {
        _unexpectedEnd = true;
        t = Uint8List.sublistView(t, 0, n);
      }
    }
    return bytesToName(t);
  }

  // the value of the in-inode extended attribute "system.data" (the rest
  // of the inline data)
  Uint8List? _inlineXattr(Uint8List ind) {
    if (_inodeSize <= 128) return null;
    final start = 128 + le16(ind, 0x80);
    if (start + 4 > _inodeSize || le32(ind, start) != 0xEA020000) return null;
    final base = start + 4;
    var p = base;
    while (p + 16 <= _inodeSize) {
      if (le32(ind, p) == 0) break;
      final nameLen = ind[p];
      final index = ind[p + 1];
      final vOff = le16(ind, p + 2);
      final vSize = le32(ind, p + 8);
      if (p + 16 + nameLen > _inodeSize) break;
      if (index == 7 &&
          nameLen == 4 &&
          ind[p + 16] == 0x64 &&
          ind[p + 17] == 0x61 &&
          ind[p + 18] == 0x74 &&
          ind[p + 19] == 0x61) {
        if (base + vOff + vSize > _inodeSize) return null;
        return Uint8List.sublistView(ind, base + vOff, base + vOff + vSize);
      }
      p += (16 + nameLen + 3) & ~3;
    }
    return null;
  }

  Uint8List _inlineData(Uint8List ind, int size) {
    final x = _inlineXattr(ind);
    final out = Uint8List(size);
    var n = size < 60 ? size : 60;
    out.setRange(0, n, ind, 0x28);
    if (x != null && size > 60) {
      var m = size - 60;
      if (m > x.length) m = x.length;
      out.setRange(60, 60 + m, x);
      n += m;
    }
    return out;
  }

  /// The data of the inode as a stream of [size] bytes.
  SeekableInStream _dataStream(Uint8List ind, int size) {
    final flags = le32(ind, 0x20);
    if ((flags & _flInlineData) != 0) {
      return MemoryInStream(_inlineData(ind, size));
    }
    final runs = RunList();
    final nBlocks = (size + blockSize - 1) ~/ blockSize;
    if ((flags & _flExtents) != 0) {
      _extentRuns(ind, nBlocks, runs);
    } else {
      _blockMapRuns(ind, nBlocks, runs);
    }
    if (runs.total < size) runs.add(-1, size - runs.total);
    return RunsInStream(_s!, runs, size);
  }

  void _extentRuns(Uint8List ind, int nBlocks, RunList runs) {
    final ext = <int>[]; // triples: logical, length, physical (-1: zeros)
    _walkExtents(Uint8List.sublistView(ind, 0x28, 0x28 + 60), 0, 0, ext);
    var cur = 0;
    final bs = blockSize;
    for (var i = 0; i + 2 < ext.length; i += 3) {
      if (cur >= nBlocks) break;
      var l = ext[i];
      var len = ext[i + 1];
      var p = ext[i + 2];
      if (l + len <= cur) continue;
      if (l < cur) {
        // overlapping extents: keep the first mapping
        final d = cur - l;
        l = cur;
        len -= d;
        if (p >= 0) p += d;
      }
      if (l > cur) {
        final gap = (l > nBlocks ? nBlocks : l) - cur;
        runs.add(-1, gap * bs);
        cur += gap;
        if (cur >= nBlocks) break;
      }
      if (cur + len > nBlocks) len = nBlocks - cur;
      runs.add(p < 0 ? -1 : p * bs, len * bs);
      cur += len;
    }
  }

  void _walkExtents(Uint8List node, int off, int level, List<int> out) {
    if (level > 5 || le16(node, off) != 0xF30A) {
      _headersError = true;
      return;
    }
    final entries = le16(node, off + 2);
    final depth = le16(node, off + 6);
    if (12 + entries * 12 > node.length - off) {
      _headersError = true;
      return;
    }
    for (var i = 0; i < entries; i++) {
      final e = off + 12 + i * 12;
      if (depth == 0) {
        final l = le32(node, e);
        var len = le16(node, e + 4);
        final start = (le16(node, e + 6) << 32) | le32(node, e + 8);
        var uninit = false;
        if (len > 32768) {
          len -= 32768;
          uninit = true;
        }
        out
          ..add(l)
          ..add(len)
          ..add(uninit ? -1 : start);
      } else {
        final leaf = le32(node, e + 4) | (le16(node, e + 8) << 32);
        if (leaf <= 0 || leaf >= _blocksCount) {
          _headersError = true;
          continue;
        }
        final b = readAt(_s!, leaf * blockSize, blockSize);
        if (b.length < blockSize) {
          _unexpectedEnd = true;
          continue;
        }
        _walkExtents(b, 0, level + 1, out);
      }
    }
  }

  void _blockMapRuns(Uint8List ind, int nBlocks, RunList runs) {
    final bs = blockSize;
    var left = nBlocks;
    for (var i = 0; i < 12 && left > 0; i++) {
      final p = le32(ind, 0x28 + i * 4);
      runs.add(p == 0 ? -1 : p * bs, bs);
      left--;
    }
    for (var level = 1; level <= 3 && left > 0; level++) {
      left -= _indirect(le32(ind, 0x28 + (11 + level) * 4), level, left, runs);
    }
  }

  // maps the blocks of an indirect block of [level]; returns how many
  // logical blocks it covered (at most [left])
  int _indirect(int blk, int level, int left, RunList runs) {
    final bs = blockSize;
    final per = bs ~/ 4;
    var cover = per;
    for (var i = 1; i < level; i++) {
      cover *= per;
    }
    if (cover > left) cover = left;
    if (blk == 0 || blk >= _blocksCount) {
      if (blk != 0) _headersError = true;
      runs.add(-1, cover * bs);
      return cover;
    }
    final b = readAt(_s!, blk * bs, bs);
    if (b.length < bs) {
      _unexpectedEnd = true;
      runs.add(-1, cover * bs);
      return cover;
    }
    var done = 0;
    for (var i = 0; i < per && done < cover; i++) {
      final p = le32(b, i * 4);
      if (level == 1) {
        runs.add(p == 0 ? -1 : p * bs, bs);
        done++;
      } else {
        done += _indirect(p, level - 1, cover - done, runs);
      }
    }
    return done;
  }

  // the entries of a directory: (inode, name) pairs
  void _dirEntries(Uint8List ind, int size, List<(int, Uint8List)> f) {
    final flags = le32(ind, 0x20);
    if ((flags & _flInlineData) != 0) {
      _parseDirRegion(ind, 0x28 + 4, 56, f);
      final x = _inlineXattr(ind);
      if (x != null && x.isNotEmpty) _parseDirRegion(x, 0, x.length, f);
      return;
    }
    final st = _dataStream(ind, size);
    final buf = Uint8List(blockSize);
    for (var pos = 0; pos < size; pos += blockSize) {
      var n = size - pos;
      if (n > blockSize) n = blockSize;
      st.position = pos;
      final got = readFully(st, buf, 0, n);
      if (got < n) {
        _unexpectedEnd = true;
        break;
      }
      _parseDirRegion(buf, 0, n, f);
    }
  }

  void _parseDirRegion(
      Uint8List d, int off, int len, List<(int, Uint8List)> f) {
    final fileType = (incompat & _incompatFileType) != 0;
    var p = off;
    final end = off + len;
    while (p + 8 <= end) {
      final ino = le32(d, p);
      var recLen = le16(d, p + 4);
      if (blockSize >= 65536 && (recLen == 0 || recLen == 65535)) {
        recLen = 65536;
      }
      final nameLen = fileType ? d[p + 6] : le16(d, p + 6);
      if (recLen < 8 || p + recLen > end) {
        if (recLen != 0 || ino != 0) _headersError = true;
        break;
      }
      if (ino != 0 && nameLen > 0 && 8 + nameLen <= recLen) {
        f.add((
          ino,
          Uint8List.fromList(Uint8List.sublistView(d, p + 8, p + 8 + nameLen))
        ));
      }
      p += recLen;
    }
  }

  void _readTree() {
    final root = readInode(2);
    if (root == null) {
      _headersError = true;
      return;
    }
    final firstPath = <int, String>{};
    final visited = <int>{2};
    void walk(Uint8List dirInode, String prefix, int depth) {
      if (depth > 256) {
        _headersError = true;
        return;
      }
      final raw = <(int, Uint8List)>[];
      _dirEntries(dirInode, _sizeOf(dirInode), raw);
      final entries = <(int, String)>[];
      for (final (ino, name) in raw) {
        if (name.length == 1 && name[0] == 0x2E) continue;
        if (name.length == 2 && name[0] == 0x2E && name[1] == 0x2E) continue;
        entries.add((ino, bytesToName(name).replaceAll('/', '_')));
      }
      for (final (ino, name) in entries) {
        final ind = readInode(ino);
        if (ind == null) {
          _headersError = true;
          continue;
        }
        final path = prefix.isEmpty ? name : '$prefix/$name';
        final it = _itemOf(ino, ind, path);
        if (it.isDir) {
          items.add(it);
          if (visited.add(ino)) {
            walk(ind, path, depth + 1);
          } else {
            _headersError = true;
          }
          continue;
        }
        final first = firstPath[ino];
        if (first == null) {
          firstPath[ino] = path;
        } else {
          it.hardLink = first;
        }
        items.add(it);
      }
    }

    walk(root, '', 0);
    // the journal, as 7-Zip lists it
    final jIno = le32(_sb, 0xE0);
    if ((compat & _compatHasJournal) != 0 && jIno != 0) {
      final ind = readInode(jIno);
      if (ind != null) items.add(_itemOf(jIno, ind, '[SYS]/Journal'));
    }
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
        return it.isDir ? null : it.allocated;
      case Kpid.posixAttrib:
        return it.mode;
      case Kpid.mTime:
        return it.mTime;
      case Kpid.cTime:
        return it.cTime;
      case Kpid.aTime:
        return it.aTime;
      case Kpid.changeTime:
        return it.changeTime;
      case Kpid.iNode:
        return it.ino;
      case Kpid.links:
        return it.links;
      case Kpid.symLink:
        return it.symLink;
      case Kpid.hardLink:
        return it.hardLink;
      case Kpid.characts:
        return _flagNames(it.flags, _inodeFlagNames);
      case Kpid.userId:
        return it.uid;
      case Kpid.groupId:
        return it.gid;
      case Kpid.deviceMajor:
        return it.isDevice ? it.devMajor : null;
      case Kpid.deviceMinor:
        return it.isDevice ? it.devMinor : null;
    }
    return null;
  }

  String _fsName() {
    if ((incompat &
                (_incompatExtents |
                    _incompat64Bit |
                    _incompatFlexBg |
                    _incompatInlineData)) !=
            0 ||
        (roCompat & _roHugeFile) != 0) {
      return 'ext4';
    }
    if ((compat & _compatHasJournal) != 0) return 'ext3';
    return 'ext2';
  }

  int? _sbTime(int off) {
    final t = le32(_sb, off);
    return t == 0 ? null : unixSecondsToFileTime(t);
  }

  @override
  Object? getArchiveProperty(int propId) {
    if (_s == null) return null;
    final sb = _sb;
    switch (propId) {
      case Kpid.phySize:
        return _blocksCount * blockSize;
      case Kpid.fileSystem:
        return _fsName();
      case Kpid.clusterSize:
        return blockSize;
      case Kpid.freeSpace:
        var free = le32(sb, 0x0C);
        if ((incompat & _incompat64Bit) != 0) free |= le32(sb, 0x158) << 32;
        return free * blockSize;
      case Kpid.mTime:
        return _sbTime(0x30);
      case Kpid.cTime:
        return _sbTime(0x108);
      case Kpid.hostOS:
        const os = ['Linux', 'Hurd', 'Masix', 'FreeBSD', 'Lites'];
        final v = le32(sb, 0x48);
        return v < os.length ? os[v] : '$v';
      case Kpid.volumeName:
        final l = cString(sb, 0x78, 16);
        return l.isEmpty ? null : l;
      case Kpid.id:
        final sbuf = StringBuffer();
        for (var i = 0; i < 16; i++) {
          sbuf.write(sb[0x68 + i].toRadixString(16).padLeft(2, '0'));
        }
        return sbuf.toString().toUpperCase();
      case Kpid.characts:
        return [
          _flagNames(compat, _compatNames),
          _flagNames(incompat, _incompatNames),
          _flagNames(roCompat, _roNames),
        ].where((s) => s.isNotEmpty).join(' ');
      case Kpid.errorFlags:
        var f = 0;
        if (_headersError) f |= ErrorFlags.headersError;
        if (_unexpectedEnd) f |= ErrorFlags.unexpectedEnd;
        return f;
      case Kpid.warning:
        return needsRecovery
            ? 'The journal needs recovery: it was not replayed'
            : null;
    }
    return null;
  }

  ExtItem? _dataItem(int index) {
    if (index < 0 || index >= items.length) return null;
    final it = items[index];
    if (it.isDir) return null;
    return it;
  }

  @override
  SeekableInStream? getStream(int index) {
    final it = _dataItem(index);
    if (it == null) return null;
    if (it.isSymLink) {
      return MemoryInStream(Uint8List.fromList(utf8.encode(it.symLink ?? '')));
    }
    if (!it.isReg) return MemoryInStream(Uint8List(0));
    final ind = readInode(it.ino);
    if (ind == null) throw const SevenZipException('bad inode');
    return _dataStream(ind, it.size);
  }

  int _dataSize(ExtItem it) {
    if (it.isDir) return 0;
    if (it.isSymLink) return utf8.encode(it.symLink ?? '').length;
    if (!it.isReg) return 0;
    return it.size;
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(items.length, indices, testMode, cb,
        (i) => items[i].isDir, (i) => _dataSize(items[i]), (i) => getStream(i)!,
        expectedSize: (i) => _dataSize(items[i]));
  }
}
