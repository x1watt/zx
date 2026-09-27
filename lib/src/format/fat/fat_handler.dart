// FAT12, FAT16 and FAT32 volumes (read only): the BIOS parameter block,
// the file allocation table, the fixed root directory of FAT12/16 and the
// cluster chains of files and folders, VFAT long names (with their
// checksum), 8.3 names with the Windows NT case flags, the creation,
// access and write times, the attributes and the volume label.
//
// Written for this package from the Microsoft FAT specification
// ("Microsoft Extensible Firmware Initiative FAT32 File System
// Specification", fatgen103, version 1.03): the BPB fields, the FAT type
// rule (count of clusters), the FAT entry layout of each type, the
// directory entry and long name entry layouts and the long name checksum.
// The case flags of byte 12 (NTRes: 0x08 lower case base name, 0x10 lower
// case extension) are the documented Windows NT behavior. Checked black
// box with mkfs.vfat, mtools and 7-Zip's listing; no FAT driver or tool
// source was read.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../archive_types.dart';
import '../iso/disc_streams.dart' show RunList, RunsInStream, le16, le32;
import '../item_streams.dart';
import '../zip/zip_header.dart' show dosTimeToFileTime;

// directory entry attributes
const int _attrReadOnly = 0x01;
const int _attrVolumeId = 0x08;
const int _attrDirectory = 0x10;
const int _attrLongName = 0x0F;

/// The parsed BIOS parameter block of a FAT volume.
class FatBpb {
  int bytesPerSector = 0;
  int secPerClus = 0;
  int reserved = 0;
  int numFats = 0;
  int rootEntCnt = 0;
  int totSec = 0;
  int media = 0;
  int fatSz = 0;
  int rootClus = 0;
  int extFlags = 0;
  int fatBits = 0; // 12, 16 or 32
  int rootDirSectors = 0;
  int firstDataSector = 0;
  int clusterCount = 0;
  int volId = 0;
  String bpbLabel = '';
  bool hasVolId = false;

  int get clusterSize => bytesPerSector * secPerClus;
}

bool _isPow2(int v) => v > 0 && (v & (v - 1)) == 0;

/// The BPB at b[off, off+512), or null when it is not a valid FAT boot
/// sector (fatgen103 section 3 and the FAT type determination).
FatBpb? parseFatBpb(Uint8List b, int off) {
  if (b.length < off + 512) return null;
  final j = b[off];
  if (!(j == 0xE9 || (j == 0xEB && b[off + 2] == 0x90))) return null;
  final bps = le16(b, off + 11);
  if (bps != 512 && bps != 1024 && bps != 2048 && bps != 4096) return null;
  final spc = b[off + 13];
  if (!_isPow2(spc) || spc > 128) return null;
  final rsvd = le16(b, off + 14);
  if (rsvd == 0) return null;
  final nFats = b[off + 16];
  if (nFats == 0 || nFats > 4) return null;
  final rootEnt = le16(b, off + 17);
  final tot16 = le16(b, off + 19);
  final media = b[off + 21];
  if (media != 0xF0 && media < 0xF8) return null;
  final fatSz16 = le16(b, off + 22);
  final tot32 = le32(b, off + 32);
  final p = FatBpb()
    ..bytesPerSector = bps
    ..secPerClus = spc
    ..reserved = rsvd
    ..numFats = nFats
    ..rootEntCnt = rootEnt
    ..media = media
    ..totSec = tot16 != 0 ? tot16 : tot32;
  final fat32Shape = fatSz16 == 0 && rootEnt == 0;
  p.fatSz = fatSz16 != 0 ? fatSz16 : le32(b, off + 36);
  if (p.fatSz == 0 || p.totSec == 0) return null;
  if (!fat32Shape && fatSz16 == 0) return null;
  p.rootDirSectors = (rootEnt * 32 + bps - 1) ~/ bps;
  p.firstDataSector = rsvd + nFats * p.fatSz + p.rootDirSectors;
  if (p.firstDataSector >= p.totSec) return null;
  p.clusterCount = (p.totSec - p.firstDataSector) ~/ spc;
  if (p.clusterCount == 0) return null;
  if (fat32Shape) {
    // the count rule of fatgen103 names this FAT32; volumes made with
    // mkfs.fat -F 32 below 65525 clusters keep the FAT32 layout
    p.fatBits = 32;
  } else if (p.clusterCount < 4085) {
    p.fatBits = 12;
  } else if (p.clusterCount < 65525) {
    p.fatBits = 16;
  } else {
    return null; // a FAT16 layout with a FAT32 cluster count
  }
  // the FAT must hold an entry for every cluster
  final entries = (p.fatSz * bps * 8) ~/ p.fatBits;
  if (entries < p.clusterCount + 2) return null;
  int sigOff;
  if (p.fatBits == 32) {
    p.extFlags = le16(b, off + 40);
    if (le16(b, off + 42) != 0) return null; // FSVer 0:0
    p.rootClus = le32(b, off + 44);
    if (p.rootClus < 2 || p.rootClus >= p.clusterCount + 2) return null;
    sigOff = off + 66;
  } else {
    sigOff = off + 38;
  }
  if (b[sigOff] == 0x29) {
    p.hasVolId = true;
    p.volId = le32(b, sigOff + 1);
    p.bpbLabel = _trimRight(_oemString(b, sigOff + 5, 11));
  }
  return p;
}

/// IsArc for the format table.
int isArcFat(Uint8List p, int size) {
  if (size < 512) return 2;
  return parseFatBpb(p, 0) != null ? 1 : 0;
}

// the upper half of code page 437, for 8.3 names
const List<int> _cp437 = [
  0xC7, 0xFC, 0xE9, 0xE2, 0xE4, 0xE0, 0xE5, 0xE7, //
  0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xEC, 0xC4, 0xC5,
  0xC9, 0xE6, 0xC6, 0xF4, 0xF6, 0xF2, 0xFB, 0xF9,
  0xFF, 0xD6, 0xDC, 0xA2, 0xA3, 0xA5, 0x20A7, 0x192,
  0xE1, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xAA, 0xBA,
  0xBF, 0x2310, 0xAC, 0xBD, 0xBC, 0xA1, 0xAB, 0xBB,
  0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
  0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
  0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
  0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
  0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
  0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
  0x3B1, 0xDF, 0x393, 0x3C0, 0x3A3, 0x3C3, 0xB5, 0x3C4,
  0x3A6, 0x398, 0x3A9, 0x3B4, 0x221E, 0x3C6, 0x3B5, 0x2229,
  0x2261, 0xB1, 0x2265, 0x2264, 0x2320, 0x2321, 0xF7, 0x2248,
  0xB0, 0x2219, 0xB7, 0x221A, 0x207F, 0xB2, 0x25A0, 0xA0,
];

String _oemString(Uint8List b, int off, int len) {
  final c = List<int>.filled(len, 0);
  for (var i = 0; i < len; i++) {
    final v = b[off + i];
    c[i] = v < 0x80 ? v : _cp437[v - 0x80];
  }
  return String.fromCharCodes(c);
}

String _trimRight(String s) {
  var n = s.length;
  while (n > 0 && (s.codeUnitAt(n - 1) == 0x20 || s.codeUnitAt(n - 1) == 0)) {
    n--;
  }
  return s.substring(0, n);
}

/// A file or folder of the volume.
class FatItem {
  String path = '';
  String shortName = '';
  bool isDir = false;
  int attrib = 0;
  int size = 0;
  int cluster = 0;
  int? mTime;
  int? cTime;
  int? aTime;
}

/// The FAT handler.
class FatHandler extends ReadOnlyHandler {
  SeekableInStream? _s;
  FatBpb? _bpb;
  final List<FatItem> items = [];
  String label = '';
  bool _headersError = false;
  bool _unexpectedEnd = false;
  int? _freeClusters;
  int _dirBytesTotal = 0; // the clusters of the folders
  int? _labelTime;

  // page cache of the FAT (64 KiB pages)
  static const int _pageBits = 16;
  final Map<int, Uint8List> _pages = {};
  int _fatStart = 0;
  int _fatBytes = 0;
  int _curPageNo = -1;
  Uint8List? _curPage;

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.aTime,
    Kpid.attrib,
    Kpid.shortName,
  ];

  static const List<int> _arcProps = [
    Kpid.fileSystem,
    Kpid.clusterSize,
    Kpid.freeSpace,
    Kpid.headersSize,
    Kpid.mTime,
    Kpid.volumeName,
    Kpid.sectorSize,
    Kpid.id,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  @override
  int get timePrec => FileTimeType.dos;

  /// The FAT type: 12, 16 or 32 (0 before open).
  int get fatBits => _bpb?.fatBits ?? 0;

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final head = readAt(stream, 0, 512);
    final bpb = parseFatBpb(head, 0);
    if (bpb == null) return false;
    _s = stream;
    _bpb = bpb;
    var active = 0;
    if (bpb.fatBits == 32 && (bpb.extFlags & 0x80) != 0) {
      active = bpb.extFlags & 0x0F;
      if (active >= bpb.numFats) active = 0;
    }
    _fatStart = (bpb.reserved + active * bpb.fatSz) * bpb.bytesPerSector;
    _fatBytes = bpb.fatSz * bpb.bytesPerSector;
    if (stream.length < bpb.firstDataSector * bpb.bytesPerSector) {
      _unexpectedEnd = true;
    }
    label = bpb.bpbLabel == 'NO NAME' ? '' : bpb.bpbLabel;
    _readTree();
    return true;
  }

  @override
  void close() {
    _s = null;
    _bpb = null;
    items.clear();
    _pages.clear();
    _curPage = null;
    _curPageNo = -1;
    label = '';
    _headersError = false;
    _unexpectedEnd = false;
    _freeClusters = null;
    _dirBytesTotal = 0;
    _labelTime = null;
  }

  // one byte of the active FAT
  int _fatByte(int off) {
    final page = off >> _pageBits;
    var p = _curPage;
    if (page != _curPageNo || p == null) {
      p = _pages[page];
      if (p == null) {
        if (_pages.length >= 64) _pages.clear();
        final start = page << _pageBits;
        var len = 1 << _pageBits;
        if (start + len > _fatBytes) len = _fatBytes - start;
        p = len > 0 ? readAt(_s!, _fatStart + start, len) : Uint8List(0);
        _pages[page] = p;
      }
      _curPage = p;
      _curPageNo = page;
    }
    final i = off & ((1 << _pageBits) - 1);
    return i < p.length ? p[i] : 0;
  }

  /// The FAT entry of [cluster] (fatgen103 section 4).
  int fatEntry(int cluster) {
    final bits = _bpb!.fatBits;
    if (bits == 12) {
      final off = cluster + (cluster >> 1);
      final v = _fatByte(off) | (_fatByte(off + 1) << 8);
      return (cluster & 1) != 0 ? v >> 4 : v & 0xFFF;
    }
    if (bits == 16) {
      final off = cluster * 2;
      return _fatByte(off) | (_fatByte(off + 1) << 8);
    }
    final off = cluster * 4;
    return (_fatByte(off) |
            (_fatByte(off + 1) << 8) |
            (_fatByte(off + 2) << 16) |
            (_fatByte(off + 3) << 24)) &
        0x0FFFFFFF;
  }

  bool _isValidCluster(int c) => c >= 2 && c < _bpb!.clusterCount + 2;

  int _clusterPos(int c) {
    final b = _bpb!;
    return (b.firstDataSector + (c - 2) * b.secPerClus) * b.bytesPerSector;
  }

  /// The runs of the chain starting at [first], at most [maxBytes] long
  /// (the whole chain when null). A broken chain sets [_headersError].
  RunList _chainRuns(int first, int? maxBytes) {
    final runs = RunList();
    final b = _bpb!;
    final cs = b.clusterSize;
    var c = first;
    var n = 0;
    final limit = b.clusterCount;
    final want = maxBytes == null ? -1 : (maxBytes + cs - 1) ~/ cs;
    while (_isValidCluster(c)) {
      if (want >= 0 && n >= want) break;
      runs.add(_clusterPos(c), cs);
      n++;
      if (n > limit) {
        _headersError = true; // a loop
        break;
      }
      c = fatEntry(c);
    }
    return runs;
  }

  // the bytes of a directory: the fixed root of FAT12/16 or a chain
  Uint8List _dirBytes(int cluster, bool root) {
    final b = _bpb!;
    if (root && b.fatBits != 32) {
      final pos = (b.reserved + b.numFats * b.fatSz) * b.bytesPerSector;
      final len = b.rootEntCnt * 32;
      final d = readAt(_s!, pos, len);
      if (d.length < len) _unexpectedEnd = true;
      return d;
    }
    // at most 65536 entries (2 MiB) per folder
    final runs = _chainRuns(cluster, 65536 * 32);
    final total = runs.total;
    _dirBytesTotal += total;
    final d = Uint8List(total);
    final st = RunsInStream(_s!, runs, total);
    final n = readFully(st, d, 0, total);
    if (n < total) _unexpectedEnd = true;
    return n < total ? Uint8List.sublistView(d, 0, n) : d;
  }

  void _readTree() {
    final b = _bpb!;
    final visited = <int>{};
    // (cluster, prefix) of the folders to read, depth first
    final stack = <(int, String, bool)>[(b.rootClus, '', true)];
    while (stack.isNotEmpty) {
      final (cl, prefix, root) = stack.removeLast();
      if (!root) {
        if (!_isValidCluster(cl) || !visited.add(cl)) {
          _headersError = true;
          continue;
        }
      } else if (b.fatBits == 32) {
        visited.add(cl);
      }
      final d = _dirBytes(cl, root);
      final subdirs = <(int, String, bool)>[];
      _parseDir(d, prefix, root, subdirs);
      // keep the order of the folder: the first sub folder on top
      for (var i = subdirs.length - 1; i >= 0; i--) {
        stack.add(subdirs[i]);
      }
    }
    _orderDepthFirst();
  }

  // items were appended folder by folder; list each folder's content right
  // after the folder (pre-order, as 7-Zip lists)
  void _orderDepthFirst() {
    final byParent = <String, List<FatItem>>{};
    for (final it in items) {
      final k = it.path.lastIndexOf('/');
      final parent = k < 0 ? '' : it.path.substring(0, k);
      (byParent[parent] ??= []).add(it);
    }
    final out = <FatItem>[];
    void walk(String p) {
      final l = byParent[p];
      if (l == null) return;
      for (final it in l) {
        out.add(it);
        if (it.isDir) walk(it.path);
      }
    }

    walk('');
    if (out.length == items.length) {
      items
        ..clear()
        ..addAll(out);
    }
  }

  static int _lfnChecksum(Uint8List d, int o) {
    var sum = 0;
    for (var i = 0; i < 11; i++) {
      sum = (((sum & 1) != 0 ? 0x80 : 0) + (sum >> 1) + d[o + i]) & 0xFF;
    }
    return sum;
  }

  static String _shortName(Uint8List d, int o) {
    final nt = d[o + 12];
    final base = List<int>.generate(8, (i) => d[o + i]);
    if (base[0] == 0x05) base[0] = 0xE5;
    var bs = _trimRight(_oemString(Uint8List.fromList(base), 0, 8));
    var ext = _trimRight(_oemString(d, o + 8, 3));
    if ((nt & 0x08) != 0) bs = bs.toLowerCase();
    if ((nt & 0x10) != 0) ext = ext.toLowerCase();
    return ext.isEmpty ? bs : '$bs.$ext';
  }

  static int? _dosTime(int date, int time) {
    if (date == 0) return null;
    return dosTimeToFileTime((date << 16) | time);
  }

  void _parseDir(Uint8List d, String prefix, bool root,
      List<(int, String, bool)> subdirs) {
    final b = _bpb!;
    Uint16List? lfn;
    var lfnNext = 0; // the order number expected next, 0 when complete
    var lfnSum = -1;
    for (var o = 0; o + 32 <= d.length; o += 32) {
      final first = d[o];
      if (first == 0) break;
      if (first == 0xE5) {
        lfn = null;
        continue;
      }
      final attr = d[o + 11];
      if ((attr & 0x3F) == _attrLongName) {
        final ord = first & 0x3F;
        if ((first & 0x40) != 0) {
          if (ord == 0 || ord > 20) {
            lfn = null;
            continue;
          }
          lfn = Uint16List(ord * 13);
          lfnNext = ord;
          lfnSum = d[o + 13];
        } else if (lfn == null || ord != lfnNext || d[o + 13] != lfnSum) {
          lfn = null;
          continue;
        }
        final base = (ord - 1) * 13;
        final l = lfn;
        for (var i = 0; i < 5; i++) {
          l[base + i] = le16(d, o + 1 + i * 2);
        }
        for (var i = 0; i < 6; i++) {
          l[base + 5 + i] = le16(d, o + 14 + i * 2);
        }
        for (var i = 0; i < 2; i++) {
          l[base + 11 + i] = le16(d, o + 28 + i * 2);
        }
        lfnNext = ord - 1;
        continue;
      }
      final curLfn = lfn;
      lfn = null;
      if ((attr & _attrVolumeId) != 0) {
        if (root && (attr & _attrDirectory) == 0) {
          label = _trimRight(_oemString(d, o, 11));
          _labelTime = _dosTime(le16(d, o + 24), le16(d, o + 22));
        }
        continue;
      }
      if (first == 0x2E) {
        // "." and ".."
        continue;
      }
      var name = _shortName(d, o);
      final short = name;
      if (curLfn != null && lfnNext == 0 && _lfnChecksum(d, o) == lfnSum) {
        var n = 0;
        while (n < curLfn.length && curLfn[n] != 0) {
          n++;
        }
        if (n > 0) name = String.fromCharCodes(curLfn, 0, n);
      }
      // a name must not climb out of its folder
      name = name.replaceAll('/', '_').replaceAll('\\', '_');
      if (name == '.' || name == '..' || name.isEmpty) continue;
      final it = FatItem()
        ..path = prefix.isEmpty ? name : '$prefix/$name'
        ..shortName = short
        ..isDir = (attr & _attrDirectory) != 0
        ..attrib = attr & 0x37
        ..size = le32(d, o + 28);
      var cl = le16(d, o + 26);
      if (b.fatBits == 32) cl |= le16(d, o + 20) << 16;
      it.cluster = cl;
      final wt = _dosTime(le16(d, o + 24), le16(d, o + 22));
      it.mTime = wt;
      final ct = _dosTime(le16(d, o + 16), le16(d, o + 14));
      final tenth = d[o + 13];
      it.cTime = ct == null ? null : ct + (tenth <= 199 ? tenth : 0) * 100000;
      it.aTime = _dosTime(le16(d, o + 18), 0);
      if (it.isDir) {
        it.size = 0;
        if (cl != 0) subdirs.add((cl, it.path, false));
      }
      items.add(it);
    }
  }

  @override
  int get numberOfItems => items.length;

  int _packSize(FatItem it) {
    if (it.isDir) return 0;
    final cs = _bpb!.clusterSize;
    return (it.size + cs - 1) ~/ cs * cs;
  }

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
        return it.isDir ? null : _packSize(it);
      case Kpid.mTime:
        return it.mTime;
      case Kpid.cTime:
        return it.cTime;
      case Kpid.aTime:
        return it.aTime;
      case Kpid.attrib:
        return it.attrib;
      case Kpid.shortName:
        return it.shortName;
      case Kpid.readOnly:
        return (it.attrib & _attrReadOnly) != 0 ? true : null;
    }
    return null;
  }

  int _countFree() {
    final f = _freeClusters;
    if (f != null) return f;
    final n = _bpb!.clusterCount;
    var free = 0;
    for (var c = 2; c < n + 2; c++) {
      if (fatEntry(c) == 0) free++;
    }
    _freeClusters = free;
    return free;
  }

  @override
  Object? getArchiveProperty(int propId) {
    final b = _bpb;
    if (b == null) return null;
    switch (propId) {
      case Kpid.phySize:
        return b.totSec * b.bytesPerSector;
      case Kpid.fileSystem:
        return 'FAT${b.fatBits}';
      case Kpid.clusterSize:
        return b.clusterSize;
      case Kpid.freeSpace:
        return _countFree() * b.clusterSize;
      case Kpid.headersSize:
        // the metadata: reserved sectors, FATs, root and folder clusters
        return b.firstDataSector * b.bytesPerSector + _dirBytesTotal;
      case Kpid.mTime:
        return _labelTime;
      case Kpid.sectorSize:
        return b.bytesPerSector;
      case Kpid.id:
        return b.hasVolId ? b.volId : null;
      case Kpid.volumeName:
        return label.isEmpty ? null : label;
      case Kpid.errorFlags:
        var f = 0;
        if (_headersError) f |= ErrorFlags.headersError;
        if (_unexpectedEnd) f |= ErrorFlags.unexpectedEnd;
        return f;
    }
    return null;
  }

  @override
  SeekableInStream? getStream(int index) {
    if (index < 0 || index >= items.length) return null;
    final it = items[index];
    if (it.isDir) return null;
    if (it.size == 0) return MemoryInStream(Uint8List(0));
    final runs = _chainRuns(it.cluster, it.size);
    return RunsInStream(_s!, runs, it.size);
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
        (i) => getStream(i)!,
        expectedSize: (i) => items[i].isDir ? null : items[i].size);
  }
}
