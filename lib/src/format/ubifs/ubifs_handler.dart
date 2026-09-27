// UBIFS images (read only): the content of a UBI volume holding UBIFS, as
// mkfs.ubifs writes it or as a UBI volume stream gives it.
//
// Written from the UBIFS design documents (linux-mtd.infradead.org,
// doc/ubifs.html and the white paper "UBIFS - A UBI File System") and the
// on-flash layout facts (node headers, magic numbers, key formats, field
// offsets), checked black box against images made by mtd-utils'
// mkfs.ubifs. No code was taken from the Linux driver or mtd-utils.
//
// LEB n of the file system is at n * leb_size. Every node starts with a
// common header (little endian): magic 0x06101831, crc u32 (over bytes 8
// to len, zlib's CRC register seeded with 0xFFFFFFFF, not inverted),
// sqnum u64, len u32, node_type u8, group_type u8, 2 bytes of padding.
// Nodes are 8-byte aligned. Node types used here: 0 inode, 1 data,
// 2 directory entry, 3 extended attribute entry, 5 padding, 6 superblock,
// 7 master, 8 log reference, 9 index, 10 commit start.
//
// LEB 0 holds the superblock (min_io_size at 32, leb_size at 36,
// leb_cnt at 40, log_lebs at 56, fanout at 72, fmt_version at 80,
// default_compr at 84, key_hash at 26, key_fmt at 27, flags at 28).
// LEBs 1 and 2 hold copies of the master node, rewritten at increasing
// offsets: the valid one with the highest sqnum is current. The master
// node gives the root of the index (root_lnum at 48, root_offs at 52,
// root_len at 56), the log head (log_lnum at 44) and the flags at 40.
//
// The index is a B+tree of index nodes (child_cnt u16 at 24, level u16
// at 26, then branches of lnum u32, offs u32, len u32 and an 8-byte key).
// Level 0 branches point at the leaf nodes: inodes, data nodes, directory
// and xattr entries. A key is two little endian words: the inode number,
// then the key type in the top 3 bits and a name hash or the block
// number in the low 29 bits. The index is in key order, so the data
// nodes of a file come block by block.
//
// Inode node: size u64 at 48, atime, ctime, mtime seconds u64 at 56,
// 64, 72 and nanoseconds u32 at 80, 84, 88, nlink at 92, uid at 96, gid
// at 100, mode at 104, flags at 108, data_len at 112, compr_type u16 at
// 132, inline data (symlink target, device number) at 160. Directory
// entry: inum u64 at 40, type u8 at 49, nlen u16 at 50, name at 56. Data
// node: uncompressed size u32 at 40, compr_type u16 at 44, data at 48,
// one 4096-byte block each. Compressors: 0 none, 1 LZO1X, 2 zlib (raw
// deflate, no zlib header), 3 zstd. Missing blocks are holes (zeros);
// the inode size truncates the last block.
//
// Only what the index holds is read: the journal (buds referenced from
// the log after the commit start node) is not replayed. Images written by
// mkfs.ubifs have an empty journal; when the log references buds a
// warning says so.

import 'dart:typed_data';

import '../../codec/deflate/inflate.dart';
import '../../codec/deflate/zutil.dart';
import '../../codec/lzo/lzo1x.dart';
import '../../codec/zstd/zstd.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../item_streams.dart';

const int kUbifsNodeMagic = 0x06101831;
const int _kChSize = 24;
const int _kBlockSize = 4096;
const int _kInoNodeSize = 160;
const int _kDentNodeSize = 56;
const int _kDataNodeSize = 48;
const int _kSbNodeSize = 4096;
const int _kMstNodeSize = 512;

// node types
const int _kInoNode = 0;
const int _kDataNode = 1;
const int _kDentNode = 2;
const int _kPadNode = 5;
const int _kSbNode = 6;
const int _kMstNode = 7;
const int _kRefNode = 8;
const int _kIdxNode = 9;
const int _kCsNode = 10;

// key types
const int _kKeyIno = 0;
const int _kKeyData = 1;
const int _kKeyDent = 2;

const int _kRootInum = 1;
const int _kMaxDepth = 64;

const List<String> _comprNames = ['none', 'LZO', 'zlib', 'zstd'];

int _getUint16LE(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

/// The UBIFS CRC: zlib's CRC register seeded with 0xFFFFFFFF, without the
/// final inversion.
int ubifsCrc32(Uint8List b, int off, int end) =>
    crc32Update(0xFFFFFFFF, b, off, end) & 0xFFFFFFFF;

/// IsArc_UbiFs: the common header of the superblock node.
int isArcUbifs(Uint8List p, int size) {
  if (size < 4) return 2;
  if (getUint32LE(p, 0) != kUbifsNodeMagic) return 0;
  if (size < _kChSize) return 2;
  if (p[20] != _kSbNode) return 0;
  return getUint32LE(p, 16) == _kSbNodeSize ? 1 : 0;
}

/// An inode read from the index.
class UbifsInode {
  final int inum;
  int size = 0;
  int atime = 0, ctime = 0, mtime = 0;
  int atimeNs = 0, ctimeNs = 0, mtimeNs = 0;
  int nlink = 0;
  int uid = 0, gid = 0;
  int mode = 0;
  int flags = 0;
  int comprType = 0;
  Uint8List data = Uint8List(0);
  int sqnum = 0;

  // the data nodes: index of the first and count in the handler's arrays
  int firstData = 0;
  int numData = 0;
  int packSize = 0;
  UbifsInode(this.inum);

  int get type => mode & 0xF000;
  bool get isDir => type == 0x4000;
  bool get isReg => type == 0x8000;
  bool get isLink => type == 0xA000;
  bool get isDevice => type == 0x2000 || type == 0x6000;
}

/// A listed entry (a directory entry reachable from the root).
class UbifsItem {
  final String path;
  final UbifsInode ino;
  String? hardLink;
  UbifsItem(this.path, this.ino);
}

class _Dent {
  final int parent;
  final Uint8List name;
  final int inum;
  final int type;
  _Dent(this.parent, this.name, this.inum, this.type);
}

/// The UBIFS handler.
class UbifsHandler extends ReadOnlyHandler {
  SeekableInStream? _stream;
  int _length = 0;

  // superblock
  int minIoSize = 0;
  int lebSize = 0;
  int lebCnt = 0;
  int maxLebCnt = 0;
  int logLebs = 0;
  int fanout = 0;
  int fmtVersion = 0;
  int defaultCompr = 0;
  int keyHash = 0;
  int keyFmt = 0;
  int sbFlags = 0;

  // master node
  int highestInum = 0;
  int cmtNo = 0;
  int mstFlags = 0;
  int logLnum = 0;
  int rootLnum = 0;
  int rootOffs = 0;
  int rootLen = 0;

  bool journalNotReplayed = false;
  bool _indexError = false;
  bool _anyNs = false;
  int numXattrs = 0;

  final Map<int, UbifsInode> inodes = {};
  final List<UbifsItem> items = [];
  final List<_Dent> _dents = [];

  // data node locations, in index (key) order
  int _nData = 0;
  Int64List _dKey = Int64List(0); // inum << 29 | block
  Int32List _dLnum = Int32List(0);
  Int32List _dOffs = Int32List(0);
  Int32List _dLen = Int32List(0);

  Uint8List _nodeBuf = Uint8List(_kBlockSize + 512);

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.aTime,
    Kpid.posixAttrib,
    Kpid.userId,
    Kpid.groupId,
    Kpid.links,
    Kpid.iNode,
    Kpid.deviceMajor,
    Kpid.deviceMinor,
    Kpid.symLink,
    Kpid.hardLink,
    Kpid.method,
  ];

  static const List<int> _arcProps = [
    Kpid.clusterSize,
    Kpid.method,
    Kpid.comment,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  @override
  int get timePrec => _anyNs ? 16 + 7 : FileTimeType.unix;

  // reads the node at lnum:offs of [len] bytes into _nodeBuf; checks the
  // magic, the length and the CRC. Returns false when invalid.
  bool _readNode(int lnum, int offs, int len) {
    if (len < _kChSize || len > (1 << 20) || offs < 0 || offs + len > lebSize) {
      return false;
    }
    if (_nodeBuf.length < len) _nodeBuf = Uint8List(len + 512);
    final s = _stream!;
    s.position = lnum * lebSize + offs;
    final b = _nodeBuf;
    if (readFully(s, b, 0, len) != len) return false;
    if (getUint32LE(b, 0) != kUbifsNodeMagic) return false;
    if (getUint32LE(b, 16) != len) return false;
    return ubifsCrc32(b, 8, len) == getUint32LE(b, 4);
  }

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    _length = stream.length;
    final sb = readAt(stream, 0, _kSbNodeSize);
    if (sb.length < _kSbNodeSize ||
        getUint32LE(sb, 0) != kUbifsNodeMagic ||
        sb[20] != _kSbNode ||
        getUint32LE(sb, 16) != _kSbNodeSize ||
        ubifsCrc32(sb, 8, _kSbNodeSize) != getUint32LE(sb, 4)) {
      return false;
    }
    keyHash = sb[26];
    keyFmt = sb[27];
    sbFlags = getUint32LE(sb, 28);
    minIoSize = getUint32LE(sb, 32);
    lebSize = getUint32LE(sb, 36);
    lebCnt = getUint32LE(sb, 40);
    maxLebCnt = getUint32LE(sb, 44);
    logLebs = getUint32LE(sb, 56);
    fanout = getUint32LE(sb, 72);
    fmtVersion = getUint32LE(sb, 80);
    defaultCompr = _getUint16LE(sb, 84);
    if (lebSize < 4096 || lebSize > (1 << 26) || lebSize % 8 != 0) {
      return false;
    }
    _stream = stream;
    if (!_readMaster()) {
      _stream = null;
      return false;
    }
    _checkLog();
    _walkIndex(rootLnum, rootOffs, rootLen, 0);
    _buildTree();
    return true;
  }

  // the newest valid master node of LEBs 1 and 2
  bool _readMaster() {
    var bestSq = -1;
    Uint8List? best;
    for (final lnum in const [1, 2]) {
      var offs = 0;
      while (offs + _kChSize <= lebSize) {
        final h = readAt(_stream!, lnum * lebSize + offs, _kChSize);
        if (h.length < _kChSize || getUint32LE(h, 0) != kUbifsNodeMagic) {
          break;
        }
        final len = getUint32LE(h, 16);
        final type = h[20];
        if (len < _kChSize || offs + len > lebSize) break;
        var next = offs + len;
        if (type == _kPadNode) {
          final p = readAt(_stream!, lnum * lebSize + offs, 28);
          if (p.length == 28) next += getUint32LE(p, 24);
        } else if (type == _kMstNode &&
            len == _kMstNodeSize &&
            _readNode(lnum, offs, len)) {
          final sq = getUint64LE(_nodeBuf, 8);
          if (sq > bestSq) {
            bestSq = sq;
            best = Uint8List.fromList(Uint8List.sublistView(_nodeBuf, 0, len));
          }
        }
        offs = (next + 7) & ~7;
      }
    }
    final m = best;
    if (m == null) return false;
    highestInum = getUint64LE(m, 24);
    cmtNo = getUint64LE(m, 32);
    mstFlags = getUint32LE(m, 40);
    logLnum = getUint32LE(m, 44);
    rootLnum = getUint32LE(m, 48);
    rootOffs = getUint32LE(m, 52);
    rootLen = getUint32LE(m, 56);
    return true;
  }

  // the log head: a commit start node, then reference nodes when the
  // journal holds uncommitted buds
  void _checkLog() {
    if (logLnum <= 2 || logLnum >= 3 + logLebs + 1) return;
    var offs = 0;
    var seenCs = false;
    while (offs + _kChSize <= lebSize) {
      final h = readAt(_stream!, logLnum * lebSize + offs, _kChSize);
      if (h.length < _kChSize || getUint32LE(h, 0) != kUbifsNodeMagic) break;
      final len = getUint32LE(h, 16);
      final type = h[20];
      if (len < _kChSize || offs + len > lebSize) break;
      var next = offs + len;
      if (type == _kCsNode) {
        seenCs = true;
      } else if (type == _kRefNode && seenCs) {
        journalNotReplayed = true;
        return;
      } else if (type == _kPadNode) {
        final p = readAt(_stream!, logLnum * lebSize + offs, 28);
        if (p.length == 28) next += getUint32LE(p, 24);
      }
      offs = (next + 7) & ~7;
    }
  }

  void _addData(int key, int lnum, int offs, int len) {
    if (_nData == _dKey.length) {
      final cap = _nData < 256 ? 512 : _nData * 2;
      _dKey = Int64List(cap)..setRange(0, _nData, _dKey);
      _dLnum = Int32List(cap)..setRange(0, _nData, _dLnum);
      _dOffs = Int32List(cap)..setRange(0, _nData, _dOffs);
      _dLen = Int32List(cap)..setRange(0, _nData, _dLen);
    }
    final i = _nData++;
    _dKey[i] = key;
    _dLnum[i] = lnum;
    _dOffs[i] = offs;
    _dLen[i] = len;
  }

  // walks the index from the node at lnum:offs
  void _walkIndex(int lnum, int offs, int len, int depth) {
    if (depth > _kMaxDepth || lnum >= lebCnt + 0x100000) {
      _indexError = true;
      return;
    }
    if (!_readNode(lnum, offs, len) || _nodeBuf[20] != _kIdxNode) {
      _indexError = true;
      return;
    }
    final b = _nodeBuf;
    final childCnt = _getUint16LE(b, 24);
    final level = _getUint16LE(b, 26);
    const brSize = 12 + 8;
    if (28 + childCnt * brSize > len) {
      _indexError = true;
      return;
    }
    // copy the branches: _nodeBuf is reused below
    final br = Uint8List.fromList(
        Uint8List.sublistView(b, 28, 28 + childCnt * brSize));
    for (var i = 0; i < childCnt; i++) {
      final o = i * brSize;
      final cl = getUint32LE(br, o);
      final co = getUint32LE(br, o + 4);
      final cn = getUint32LE(br, o + 8);
      if (level > 0) {
        _walkIndex(cl, co, cn, depth + 1);
        continue;
      }
      final inum = getUint32LE(br, o + 12);
      final k2 = getUint32LE(br, o + 16);
      final ktype = k2 >> 29;
      switch (ktype) {
        case _kKeyData:
          _addData((inum << 29) | (k2 & 0x1FFFFFFF), cl, co, cn);
        case _kKeyIno:
          _readInode(cl, co, cn);
        case _kKeyDent:
          _readDent(cl, co, cn);
        default:
          numXattrs++;
      }
    }
  }

  void _readInode(int lnum, int offs, int len) {
    if (!_readNode(lnum, offs, len) ||
        _nodeBuf[20] != _kInoNode ||
        len < _kInoNodeSize) {
      _indexError = true;
      return;
    }
    final b = _nodeBuf;
    final inum = getUint32LE(b, 24);
    final sq = getUint64LE(b, 8);
    final old = inodes[inum];
    if (old != null && old.sqnum >= sq) return;
    final dataLen = getUint32LE(b, 112);
    final ino = UbifsInode(inum)
      ..sqnum = sq
      ..size = getUint64LE(b, 48)
      ..atime = getUint64LE(b, 56)
      ..ctime = getUint64LE(b, 64)
      ..mtime = getUint64LE(b, 72)
      ..atimeNs = getUint32LE(b, 80)
      ..ctimeNs = getUint32LE(b, 84)
      ..mtimeNs = getUint32LE(b, 88)
      ..nlink = getUint32LE(b, 92)
      ..uid = getUint32LE(b, 96)
      ..gid = getUint32LE(b, 100)
      ..mode = getUint32LE(b, 104)
      ..flags = getUint32LE(b, 108)
      ..comprType = _getUint16LE(b, 132);
    if (dataLen > 0 && _kInoNodeSize + dataLen <= len) {
      ino.data = Uint8List.fromList(Uint8List.sublistView(
          b, _kInoNodeSize, _kInoNodeSize + dataLen));
    }
    if (ino.atimeNs != 0 || ino.ctimeNs != 0 || ino.mtimeNs != 0) {
      _anyNs = true;
    }
    inodes[inum] = ino;
  }

  void _readDent(int lnum, int offs, int len) {
    if (!_readNode(lnum, offs, len) ||
        _nodeBuf[20] != _kDentNode ||
        len < _kDentNodeSize) {
      _indexError = true;
      return;
    }
    final b = _nodeBuf;
    final parent = getUint32LE(b, 24);
    final inum = getUint64LE(b, 40);
    final type = b[49];
    final nlen = _getUint16LE(b, 50);
    if (_kDentNodeSize + nlen > len || nlen == 0) {
      _indexError = true;
      return;
    }
    if (inum == 0) return; // a deletion entry
    _dents.add(_Dent(
        parent,
        Uint8List.fromList(
            Uint8List.sublistView(b, _kDentNodeSize, _kDentNodeSize + nlen)),
        inum,
        type));
  }

  static int _cmpBytes(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }

  void _buildTree() {
    // the data nodes of each inode (the index gives them in key order)
    var sorted = true;
    for (var i = 1; i < _nData; i++) {
      if (_dKey[i] < _dKey[i - 1]) {
        sorted = false;
        break;
      }
    }
    if (!sorted) _sortData();
    var i = 0;
    while (i < _nData) {
      final inum = _dKey[i] >> 29;
      var j = i;
      var pack = 0;
      while (j < _nData && (_dKey[j] >> 29) == inum) {
        pack += _dLen[j];
        j++;
      }
      final ino = inodes[inum];
      if (ino != null) {
        ino.firstData = i;
        ino.numData = j - i;
        ino.packSize = pack;
      }
      i = j;
    }

    // children of each directory, sorted by name
    final children = <int, List<_Dent>>{};
    for (final d in _dents) {
      (children[d.parent] ??= []).add(d);
    }
    for (final l in children.values) {
      l.sort((a, b) => _cmpBytes(a.name, b.name));
    }
    final firstPath = <int, String>{};
    final visited = <int>{_kRootInum};
    // depth first, directories before their content
    void walk(int dir, String prefix, int depth) {
      final list = children[dir];
      if (list == null) return;
      if (depth > 4096) {
        _indexError = true;
        return;
      }
      for (final d in list) {
        final name = bytesToName(d.name);
        if (name == '.' || name == '..' || name.contains('/')) {
          _indexError = true;
          continue;
        }
        final path = prefix.isEmpty ? name : '$prefix/$name';
        final ino = inodes[d.inum];
        if (ino == null) {
          _indexError = true;
          continue;
        }
        final it = UbifsItem(path, ino);
        if (!ino.isDir) {
          final first = firstPath[d.inum];
          if (first == null) {
            firstPath[d.inum] = path;
          } else {
            it.hardLink = first;
          }
        }
        items.add(it);
        if (ino.isDir) {
          if (!visited.add(d.inum)) {
            _indexError = true;
            continue;
          }
          walk(d.inum, path, depth + 1);
        }
      }
    }

    walk(_kRootInum, '', 0);
  }

  void _sortData() {
    final idx = List<int>.generate(_nData, (i) => i);
    idx.sort((a, b) => _dKey[a].compareTo(_dKey[b]));
    final k = Int64List(_nData);
    final l = Int32List(_nData);
    final o = Int32List(_nData);
    final n = Int32List(_nData);
    for (var i = 0; i < _nData; i++) {
      final j = idx[i];
      k[i] = _dKey[j];
      l[i] = _dLnum[j];
      o[i] = _dOffs[j];
      n[i] = _dLen[j];
    }
    _dKey = k;
    _dLnum = l;
    _dOffs = o;
    _dLen = n;
  }

  @override
  void close() {
    _stream = null;
    inodes.clear();
    items.clear();
    _dents.clear();
    _nData = 0;
    _dKey = Int64List(0);
    _dLnum = Int32List(0);
    _dOffs = Int32List(0);
    _dLen = Int32List(0);
    journalNotReplayed = false;
    _indexError = false;
    _anyNs = false;
    numXattrs = 0;
  }

  @override
  int get numberOfItems => items.length;

  static String _comprName(int t) =>
      t >= 0 && t < _comprNames.length ? _comprNames[t] : 'compr$t';

  // (major, minor) of a device inode: the Linux new_encode_dev layout
  static (int, int) _devNumbers(Uint8List d) {
    int v;
    if (d.length >= 8) {
      v = getUint64LE(d, 0);
    } else if (d.length >= 4) {
      v = getUint32LE(d, 0);
    } else {
      return (0, 0);
    }
    final major = (v >> 8) & 0xFFF;
    final minor = (v & 0xFF) | ((v >> 12) & 0xFFF00);
    return (major, minor);
  }

  static int _time(int sec, int ns) =>
      unixSecondsToFileTime(sec) + ns ~/ 100;

  int _itemSize(UbifsItem it) {
    final ino = it.ino;
    if (ino.isReg) return ino.size;
    if (ino.isLink) return ino.data.length;
    return 0;
  }

  @override
  Object? getProperty(int index, int propId) {
    if (index < 0 || index >= items.length) return null;
    final it = items[index];
    final ino = it.ino;
    switch (propId) {
      case Kpid.path:
        return it.path;
      case Kpid.isDir:
        return ino.isDir;
      case Kpid.size:
        return _itemSize(it);
      case Kpid.packSize:
        return ino.isReg ? ino.packSize : _itemSize(it);
      case Kpid.mTime:
        return _time(ino.mtime, ino.mtimeNs);
      case Kpid.cTime:
        return _time(ino.ctime, ino.ctimeNs);
      case Kpid.aTime:
        return _time(ino.atime, ino.atimeNs);
      case Kpid.posixAttrib:
        return ino.mode & 0xFFFF;
      case Kpid.userId:
        return ino.uid;
      case Kpid.groupId:
        return ino.gid;
      case Kpid.links:
        return ino.nlink;
      case Kpid.iNode:
        return ino.inum;
      case Kpid.deviceMajor:
        return ino.isDevice ? _devNumbers(ino.data).$1 : null;
      case Kpid.deviceMinor:
        return ino.isDevice ? _devNumbers(ino.data).$2 : null;
      case Kpid.symLink:
        return ino.isLink ? bytesToName(ino.data) : null;
      case Kpid.hardLink:
        return it.hardLink;
      case Kpid.method:
        return ino.isReg ? _comprName(ino.comprType) : null;
    }
    return null;
  }

  String _archiveComment() {
    final sb = StringBuffer()
      ..write('LEB size $lebSize, min I/O $minIoSize, ')
      ..write('LEB count $lebCnt (max $maxLebCnt)\n')
      ..write('format version $fmtVersion, fanout $fanout, ')
      ..write('key hash ${keyHash == 0 ? 'r5' : keyHash == 1 ? 'test' : '$keyHash'}, ')
      ..write('default compressor ${_comprName(defaultCompr)}\n')
      ..write('commit $cmtNo, highest inode $highestInum, ')
      ..write('master flags 0x${mstFlags.toRadixString(16)}\n');
    if (numXattrs > 0) sb.write('extended attributes: $numXattrs (not listed)\n');
    return sb.toString();
  }

  String? _warning() {
    final w = <String>[];
    if (journalNotReplayed) {
      w.add('The journal holds uncommitted changes (not replayed)');
    }
    if (_indexError) w.add('Index errors');
    if ((sbFlags & 0x08) != 0) w.add('Encrypted file names (not supported)');
    return w.isEmpty ? null : w.join('; ');
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.phySize:
        return _length;
      case Kpid.clusterSize:
        return lebSize;
      case Kpid.method:
        return _comprName(defaultCompr);
      case Kpid.comment:
        return _archiveComment();
      case Kpid.warningFlags:
        return _warning() == null ? null : ErrorFlags.headersError;
      case Kpid.warning:
        return _warning();
    }
    return null;
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(
        items.length,
        indices,
        testMode,
        cb,
        (i) => items[i].ino.isDir,
        (i) => _itemSize(items[i]),
        (i) => getStream(i) ?? MemoryInStream(Uint8List(0)),
        expectedSize: (i) =>
            items[i].ino.isDir ? null : _itemSize(items[i]));
  }

  @override
  SeekableInStream? getStream(int index) {
    if (_stream == null || index < 0 || index >= items.length) return null;
    final ino = items[index].ino;
    if (ino.isDir) return null;
    if (ino.isLink) return MemoryInStream(ino.data);
    if (!ino.isReg) return MemoryInStream(Uint8List(0));
    return UbifsFileStream._(this, ino);
  }
}

/// The data of a regular file, decoded block by block.
class UbifsFileStream implements SeekableInStream {
  final UbifsHandler _h;
  final UbifsInode _ino;
  final Uint8List _block = Uint8List(_kBlockSize);
  int _cached = -1;
  int _pos = 0;
  InflateState? _inflate;

  UbifsFileStream._(this._h, this._ino);

  // index of the data node of [block], -1 for a hole
  int _find(int block) {
    final key = (_ino.inum << 29) | block;
    final keys = _h._dKey;
    var lo = _ino.firstData;
    var hi = lo + _ino.numData - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final k = keys[mid];
      if (k == key) return mid;
      if (k < key) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }

  void _load(int block) {
    final out = _block;
    final i = _find(block);
    if (i < 0) {
      out.fillRange(0, _kBlockSize, 0);
      _cached = block;
      return;
    }
    final h = _h;
    final len = h._dLen[i];
    if (!h._readNode(h._dLnum[i], h._dOffs[i], len) ||
        h._nodeBuf[20] != _kDataNode ||
        len < _kDataNodeSize) {
      _cached = -1;
      throw SevenZipException('UBIFS data node error (inode ${_ino.inum}, '
          'block $block)');
    }
    final b = h._nodeBuf;
    final size = getUint32LE(b, 40);
    final compr = _getUint16LE(b, 44);
    final n = len - _kDataNodeSize;
    if (size > _kBlockSize) {
      throw const SevenZipException('UBIFS data node too large');
    }
    int got;
    switch (compr) {
      case 0:
        got = n < size ? n : size;
        out.setRange(0, got, b, _kDataNodeSize);
      case 1:
        got = lzo1xDecompressInto(b, _kDataNodeSize, n, out, 0, size);
      case 2:
        got = _inflateInto(b, _kDataNodeSize, n, out, size);
      case 3:
        final d = zstdDecompress(
            Uint8List.sublistView(b, _kDataNodeSize, len),
            maxOutput: _kBlockSize);
        got = d.length < size ? d.length : size;
        out.setRange(0, got, d);
      default:
        throw SevenZipException(
            'UBIFS compressor $compr', SevenZipError.unsupportedMethod);
    }
    if (got != size) {
      throw const SevenZipException('UBIFS data node size mismatch');
    }
    if (got < _kBlockSize) out.fillRange(got, _kBlockSize, 0);
    _cached = block;
  }

  // raw deflate of src[off, off + n) into out[0, size)
  int _inflateInto(Uint8List src, int off, int n, Uint8List out, int size) {
    final z = _inflate ??= InflateState();
    z.inflateReset();
    z.nextIn = src;
    z.nextInPos = off;
    z.availIn = n;
    z.nextOut = out;
    z.nextOutPos = 0;
    z.availOut = size;
    final ret = z.inflate(ZFlush.finish);
    if (ret != ZResult.streamEnd && z.availOut != 0) {
      throw SevenZipException('UBIFS zlib data error: ${z.msg ?? ret}');
    }
    return size - z.availOut;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    final size = _ino.size;
    if (_pos >= size || len <= 0) return 0;
    final block = _pos >> 12;
    if (block != _cached) _load(block);
    final o = _pos & (_kBlockSize - 1);
    var n = _kBlockSize - o;
    if (n > len) n = len;
    if (n > size - _pos) n = size - _pos;
    buf.setRange(off, off + n, _block, o);
    _pos += n;
    return n;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => _ino.size;
}
