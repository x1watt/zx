// UDF reader (UDF 1.02 to 2.60 on ECMA-167): the volume recognition
// sequence, the anchor volume descriptor pointer (sector 256, the last
// sector or 256 before it, for 512 to 4096 byte sectors), the volume
// descriptor sequence (primary, partition and logical volume descriptors),
// partition maps (type 1, virtual with a VAT, sparable, metadata), the file
// set descriptor and the directory tree: file entries and extended file
// entries (ICB strategy 4, indirect entries followed), short, long and
// extended allocation descriptors with allocation extent descriptors,
// data embedded in the ICB, file identifier descriptors with OSTA CS0 names
// and symbolic links made of path components. Named streams are ignored.
//
// Written from ECMA-167 3rd edition and the OSTA UDF 2.60 specification
// (documents only; no UDF source code was read).

import 'dart:typed_data';

import '../../io/streams.dart';
import '../iso/disc_streams.dart';

/// One file or directory of the volume.
class UdfItem {
  String path = '';
  bool isDir = false;
  final RunList runs = RunList();

  /// The data when it is embedded in the ICB.
  Uint8List? inline;
  int size = 0;
  int packSize = 0;
  int fileType = 0;
  int? mode;
  int? uid;
  int? gid;
  int? nlink;
  String? symlink;
  int? mTime;
  int? aTime;
  int? cTime;
  int? changeTime;
  bool hidden = false;

  /// The data can not be read (a partition map this reader does not know).
  bool unsupported = false;

  bool get isSymLink => symlink != null;
}

// a partition map of the logical volume
class _Map {
  static const physical = 1;
  static const virtual = 2;
  static const sparable = 3;
  static const metadata = 4;
  static const unknown = 0;

  int type = unknown;
  int partNum = 0;
  int start = 0; // sector of the partition
  int length = 0; // sectors

  // sparable
  int packetLen = 32;
  final Map<int, int> sparing = {};
  final List<int> sparingTables = [];

  // virtual: VAT entries (partition relative blocks of the physical map)
  Uint32List? vat;

  // metadata: the metadata file as runs of the physical partition
  int metaLoc = -1;
  int mirrorLoc = -1;
  List<int> metaLbn = []; // first metadata block of each run
  List<int> metaSector = []; // its sector
  List<int> metaCount = []; // blocks
  int physMap = -1; // the type 1 map of the same partition
}

// a file identifier descriptor waiting to be listed
class _Entry {
  final String name;
  final int partRef;
  final int lbn;
  final bool isDir;
  final bool hidden;
  _Entry(this.name, this.partRef, this.lbn, this.isDir, this.hidden);
}

class _Frame {
  final String prefix;
  final List<_Entry> entries;
  int i = 0;
  _Frame(this.prefix, this.entries);
}

/// The parsed volume.
class UdfReader {
  final SeekableInStream s;
  final List<UdfItem> items = [];

  int sectorSize = 2048;
  int blockSize = 2048;
  int udfRevision = 0;
  bool headersError = false;
  bool unexpectedEnd = false;
  bool unsupportedFeature = false;

  String volumeId = '';
  String volumeSetId = '';
  String logicalVolumeId = '';
  String fileSetId = '';
  String implementationId = '';
  String domainId = '';
  int? created;
  int? modified;
  final List<String> mapNames = [];

  final List<_Map> _maps = [];
  final Map<int, (int, int)> _partitions = {}; // number: (start, length)
  int _phyEnd = 0;
  int _fsdLbn = -1;
  int _fsdRef = 0;

  UdfReader(this.s);

  int get phySize {
    final len = s.length;
    return _phyEnd > len ? len : _phyEnd;
  }

  /// IsArc: a volume recognition sequence with NSR02 or NSR03 at 32 KiB.
  /// 1 yes, 0 no, 2 more data needed.
  static int isArc(Uint8List p, int size) {
    if (size < 32768 + 2048 * 3) return 2;
    for (final step in const [2048, 4096, 8192]) {
      var seenBea = false;
      for (var i = 0; i < 16; i++) {
        final o = 32768 + i * step;
        if (o + 7 > size) {
          if (seenBea) return 2;
          break;
        }
        if (p[o] != 0 || p[o + 6] != 1) break;
        final id = String.fromCharCodes(p, o + 1, o + 6);
        if (id == 'BEA01') {
          seenBea = true;
        } else if (id == 'NSR02' || id == 'NSR03') {
          if (seenBea) return 1;
        } else if (id == 'TEA01') {
          break;
        } else if (id != 'CD001' && id != 'CDW02' && id != 'BOOT2') {
          break;
        }
      }
    }
    return 0;
  }

  // ---------- descriptors ----------

  // the descriptor tag at b[o]: its identifier, or -1 when the checksum or
  // the location is wrong
  static int _tag(Uint8List b, int o, [int loc = -1]) {
    if (o + 16 > b.length) return -1;
    var sum = 0;
    for (var i = 0; i < 16; i++) {
      if (i != 4) sum += b[o + i];
    }
    if ((sum & 0xFF) != b[o + 4]) return -1;
    if (loc >= 0 && le32(b, o + 12) != loc) return -1;
    return le16(b, o);
  }

  Uint8List _readSectors(int sector, int count) {
    final b = readAt(s, sector * sectorSize, count * sectorSize);
    if (b.length < count * sectorSize) unexpectedEnd = true;
    return b;
  }

  /// Finds the anchor and reads the volume. false when the stream is not a
  /// UDF volume.
  bool open() {
    final len = s.length;
    int? mainLoc, mainLen, resLoc, resLen;
    for (final ss in const [2048, 512, 4096, 1024]) {
      final n = len ~/ ss;
      for (final loc in [256, n - 1, n - 257, 512]) {
        if (loc < 0) continue;
        final b = readAt(s, loc * ss, 32);
        if (b.length < 32 || _tag(b, 0, loc) != 2) continue;
        sectorSize = ss;
        mainLen = le32(b, 16);
        mainLoc = le32(b, 20);
        resLen = le32(b, 24);
        resLoc = le32(b, 28);
        final end = (loc + 1) * ss;
        if (end > _phyEnd) _phyEnd = end;
        break;
      }
      if (mainLoc != null) break;
    }
    if (mainLoc == null) return false;
    // a second anchor at the end makes the physical size the whole volume
    {
      final n = len ~/ sectorSize;
      final b = readAt(s, (n - 1) * sectorSize, 32);
      if (b.length == 32 && _tag(b, 0, n - 1) == 2) _phyEnd = n * sectorSize;
    }
    if (!_readVds(mainLoc, mainLen!) && !_readVds(resLoc!, resLen!)) {
      return false;
    }
    if (!_setupMaps()) return false;
    _readFileSet();
    return true;
  }

  // the volume descriptor sequence at [loc], [len] bytes
  bool _readVds(int loc, int len) {
    Uint8List? pvd;
    Uint8List? lvd;
    var pvdSeq = -1, lvdSeq = -1;
    final pds = <int, (int, Uint8List)>{};
    var sec = loc;
    var end = loc + len ~/ sectorSize;
    var guard = 0;
    while (sec < end && guard < 4096) {
      guard++;
      final b = _readSectors(sec, 1);
      if (b.length < sectorSize) break;
      final id = _tag(b, 0, sec);
      sec++;
      if (id < 0) continue;
      if (id == 8) break; // terminating descriptor
      final seq = le32(b, 16);
      switch (id) {
        case 1:
          if (seq >= pvdSeq) {
            pvd = b;
            pvdSeq = seq;
          }
        case 3:
          // volume descriptor pointer: the sequence goes on elsewhere
          sec = le32(b, 24);
          end = sec + le32(b, 20) ~/ sectorSize;
        case 5:
          final num = le16(b, 22);
          final old = pds[num];
          if (old == null || seq >= old.$1) pds[num] = (seq, b);
        case 6:
          if (seq >= lvdSeq) {
            lvd = b;
            lvdSeq = seq;
          }
      }
    }
    if (lvd == null || pds.isEmpty) return false;
    if (pvd != null) {
      volumeId = _dstring(pvd, 24, 32);
      volumeSetId = _dstring(pvd, 72, 128);
      created = _timestamp(pvd, 376);
      implementationId = _regid(pvd, 388);
    }
    for (final e in pds.entries) {
      final b = e.value.$2;
      final start = le32(b, 188);
      final plen = le32(b, 192);
      _partitions[e.key] = (start, plen);
      final end = (start + plen) * sectorSize;
      if (end > _phyEnd) _phyEnd = end;
    }
    final l = lvd;
    blockSize = le32(l, 212);
    // UDF requires the logical block size to be the sector size
    if (blockSize != sectorSize) return false;
    logicalVolumeId = _dstring(l, 84, 128);
    domainId = _regid(l, 216);
    udfRevision = le16(l, 216 + 24);
    _fsdLbn = le32(l, 248 + 4);
    _fsdRef = le16(l, 248 + 8);
    final numMaps = le32(l, 268);
    var p = 440;
    for (var i = 0; i < numMaps && i < 64; i++) {
      if (p + 2 > l.length) break;
      final type = l[p];
      final mlen = l[p + 1];
      if (mlen < 6 || p + mlen > l.length) break;
      final m = _Map();
      if (type == 1) {
        m.type = _Map.physical;
        m.partNum = le16(l, p + 4);
        mapNames.add('Type1');
      } else if (type == 2 && mlen >= 40) {
        final ident = _regidIdent(l, p + 4);
        m.partNum = le16(l, p + 38);
        if (ident == '*UDF Virtual Partition') {
          m.type = _Map.virtual;
          mapNames.add('Virtual');
        } else if (ident == '*UDF Sparable Partition') {
          m.type = _Map.sparable;
          m.packetLen = le16(l, p + 40);
          final n = l[p + 42];
          for (var k = 0; k < n && p + 48 + k * 4 + 4 <= p + mlen; k++) {
            m.sparingTables.add(le32(l, p + 48 + k * 4));
          }
          mapNames.add('Sparable');
        } else if (ident == '*UDF Metadata Partition') {
          m.type = _Map.metadata;
          m.metaLoc = le32(l, p + 40);
          m.mirrorLoc = le32(l, p + 44);
          mapNames.add('Metadata');
        } else {
          mapNames.add(ident);
        }
      } else {
        mapNames.add('Type$type');
      }
      final part = _partitions[m.partNum];
      if (part != null) {
        m.start = part.$1;
        m.length = part.$2;
      } else if (m.type != _Map.unknown) {
        headersError = true;
      }
      _maps.add(m);
      p += mlen;
    }
    // the logical volume integrity descriptor: the time of the last change
    final isLen = le32(l, 432);
    final isLoc = le32(l, 436);
    if (isLen > 0) {
      final b = readAt(s, isLoc * sectorSize, sectorSize);
      if (b.length == sectorSize && _tag(b, 0, isLoc) == 9) {
        modified = _timestamp(b, 16);
      }
    }
    return _maps.isNotEmpty;
  }

  bool _setupMaps() {
    for (var i = 0; i < _maps.length; i++) {
      final m = _maps[i];
      if (m.type == _Map.sparable) {
        _readSparingTable(m);
      }
    }
    for (var i = 0; i < _maps.length; i++) {
      final m = _maps[i];
      if (m.type == _Map.virtual || m.type == _Map.metadata) {
        m.physMap = _physicalMapOf(m.partNum);
      }
      if (m.type == _Map.virtual) _readVat(m);
      if (m.type == _Map.metadata) _readMetadataFile(m);
    }
    return true;
  }

  // the type 1 (or sparable) map of partition [num]; one is added when the
  // volume has none
  int _physicalMapOf(int num) {
    for (var i = 0; i < _maps.length; i++) {
      final m = _maps[i];
      if ((m.type == _Map.physical || m.type == _Map.sparable) &&
          m.partNum == num) {
        return i;
      }
    }
    final part = _partitions[num];
    final m = _Map()
      ..type = _Map.physical
      ..partNum = num;
    if (part != null) {
      m.start = part.$1;
      m.length = part.$2;
    }
    _maps.add(m);
    return _maps.length - 1;
  }

  void _readSparingTable(_Map m) {
    for (final loc in m.sparingTables) {
      final b = readAt(s, loc * sectorSize, sectorSize * 4);
      if (b.length < 56 || _tag(b, 0) != 0) continue;
      if (_regidIdent(b, 16) != '*UDF Sparing Table') continue;
      final n = le16(b, 48);
      for (var k = 0; k < n && 56 + k * 8 + 8 <= b.length; k++) {
        final orig = le32(b, 56 + k * 8);
        final mapped = le32(b, 56 + k * 8 + 4);
        if (orig < 0xFFFFFFF0) m.sparing[orig] = mapped;
      }
      return;
    }
  }

  // The VAT: the last file entry recorded on the medium (file type 248, or
  // file type 0 with the "*UDF Virtual Alloc Tbl" identifier at the end in
  // UDF 1.50).
  void _readVat(_Map m) {
    final phys = _maps[m.physMap];
    final n = _lastWrittenSector() + 1;
    for (var sec = n - 1; sec >= 0 && sec >= n - 64; sec--) {
      final b = readAt(s, sec * sectorSize, sectorSize);
      if (b.length < sectorSize) continue;
      final id = _tag(b, 0);
      if (id != 261 && id != 266) continue;
      final ft = b[16 + 11];
      if (ft != 248 && ft != 0) continue;
      final fe = _FileEntry.parse(b, id);
      if (fe == null) continue;
      final item = UdfItem();
      _loadData(fe, b, m.physMap, item);
      Uint8List data;
      try {
        data = _readItemData(item, 1 << 26);
      } on SevenZipException {
        continue;
      }
      if (ft == 248) {
        if (data.length < 152) continue;
        final lhd = le16(data, 0);
        if (lhd > data.length) continue;
        final cnt = (data.length - lhd) ~/ 4;
        final vat = Uint32List(cnt);
        for (var k = 0; k < cnt; k++) {
          vat[k] = le32(data, lhd + k * 4);
        }
        m.vat = vat;
      } else {
        if (data.length < 36) continue;
        if (_regidIdent(data, data.length - 36) != '*UDF Virtual Alloc Tbl') {
          continue;
        }
        final cnt = (data.length - 36) ~/ 4;
        final vat = Uint32List(cnt);
        for (var k = 0; k < cnt; k++) {
          vat[k] = le32(data, k * 4);
        }
        m.vat = vat;
      }
      m.start = phys.start;
      m.length = phys.length;
      return;
    }
    unsupportedFeature = true;
  }

  // the last sector that is not all zeros (an image of a recordable disc
  // can be longer than what was written), searched over at most 256 MiB
  int _lastWrittenSector() {
    final ss = sectorSize;
    final n = s.length ~/ ss;
    const chunk = 32;
    final buf = Uint8List(chunk * ss);
    var hi = n;
    var scanned = 0;
    while (hi > 0 && scanned < (256 << 20)) {
      final lo = hi > chunk ? hi - chunk : 0;
      s.position = lo * ss;
      final got = readFully(s, buf, 0, (hi - lo) * ss);
      for (var i = got - 1; i >= 0; i--) {
        if (buf[i] != 0) return lo + i ~/ ss;
      }
      scanned += got;
      hi = lo;
    }
    return n - 1;
  }

  // the metadata file (or its mirror) of a metadata partition map
  void _readMetadataFile(_Map m) {
    for (final loc in [m.metaLoc, m.mirrorLoc]) {
      if (loc < 0 || loc == 0xFFFFFFFF) continue;
      final sec = _sectorOf(m.physMap, loc);
      if (sec < 0) continue;
      final b = readAt(s, sec * sectorSize, blockSize);
      if (b.length < blockSize) continue;
      final id = _tag(b, 0);
      if (id != 261 && id != 266) continue;
      final fe = _FileEntry.parse(b, id);
      if (fe == null || (fe.fileType != 250 && fe.fileType != 251)) continue;
      final item = UdfItem();
      _loadData(fe, b, m.physMap, item);
      var lbn = 0;
      final r = item.runs;
      for (var k = 0; k < r.pos.length; k++) {
        final cnt = r.len[k] ~/ blockSize;
        if (r.pos[k] >= 0) {
          m.metaLbn.add(lbn);
          m.metaSector.add(r.pos[k] ~/ sectorSize);
          m.metaCount.add(cnt);
        }
        lbn += cnt;
      }
      if (m.metaLbn.isNotEmpty) return;
    }
    unsupportedFeature = true;
  }

  /// The sector of logical block [lbn] of partition map [ref], -1 when it
  /// is not mapped.
  int _sectorOf(int ref, int lbn) {
    if (ref < 0 || ref >= _maps.length) return -1;
    final m = _maps[ref];
    switch (m.type) {
      case _Map.physical:
        return m.start + lbn;
      case _Map.sparable:
        final pl = m.packetLen <= 0 ? 32 : m.packetLen;
        final packet = lbn - lbn % pl;
        final mapped = m.sparing[packet];
        if (mapped != null) return mapped + lbn - packet;
        return m.start + lbn;
      case _Map.virtual:
        final vat = m.vat;
        if (vat == null || lbn >= vat.length) return -1;
        final v = vat[lbn];
        if (v == 0xFFFFFFFF) return -1;
        return _sectorOf(m.physMap, v);
      case _Map.metadata:
        final lb = m.metaLbn;
        for (var k = 0; k < lb.length; k++) {
          if (lbn >= lb[k] && lbn < lb[k] + m.metaCount[k]) {
            return m.metaSector[k] + lbn - lb[k];
          }
        }
        return -1;
    }
    return -1;
  }

  // appends [len] bytes of logical blocks from [lbn] of map [ref] to [out];
  // false when a block is not mapped
  bool _mapExtent(int ref, int lbn, int len, RunList out) {
    if (ref < 0 || ref >= _maps.length) return false;
    final m = _maps[ref];
    final bs = blockSize;
    if (m.type == _Map.physical) {
      out.add((m.start + lbn) * sectorSize, len);
      final end = (m.start + lbn) * sectorSize + len;
      if (end > _phyEnd && end <= s.length) _phyEnd = end;
      return true;
    }
    // block by block (sparable packets, VAT entries, metadata runs)
    var rem = len;
    var b = lbn;
    while (rem > 0) {
      final sec = _sectorOf(ref, b);
      if (sec < 0) return false;
      final n = rem < bs ? rem : bs;
      out.add(sec * sectorSize, n);
      rem -= n;
      b++;
    }
    return true;
  }

  // the runs (or embedded data) of a file entry read from block [b]
  void _loadData(_FileEntry fe, Uint8List b, int icbRef, UdfItem item) {
    item.size = fe.infoLen;
    final adType = fe.flags & 7;
    var adPos = fe.adStart;
    var adLen = fe.lad;
    if (adPos + adLen > b.length) {
      headersError = true;
      adLen = b.length - adPos;
      if (adLen < 0) adLen = 0;
    }
    if (adType == 3) {
      item.inline =
          Uint8List.fromList(Uint8List.sublistView(b, adPos, adPos + adLen));
      if (item.size > adLen) item.size = adLen;
      return;
    }
    var buf = b;
    var guard = 0;
    var remInfo = fe.infoLen;
    for (;;) {
      var next = -1, nextRef = 0;
      var p = adPos;
      final end = adPos + adLen;
      while (p < end) {
        int extLen, type, lbn, ref, recLen;
        if (adType == 0) {
          if (p + 8 > end) break;
          final l = le32(buf, p);
          extLen = l & 0x3FFFFFFF;
          type = l >> 30;
          lbn = le32(buf, p + 4);
          ref = icbRef;
          recLen = extLen;
          p += 8;
        } else if (adType == 1) {
          if (p + 16 > end) break;
          final l = le32(buf, p);
          extLen = l & 0x3FFFFFFF;
          type = l >> 30;
          lbn = le32(buf, p + 4);
          ref = le16(buf, p + 8);
          recLen = extLen;
          p += 16;
        } else if (adType == 2) {
          if (p + 20 > end) break;
          final l = le32(buf, p);
          extLen = l & 0x3FFFFFFF;
          type = l >> 30;
          recLen = le32(buf, p + 4);
          final infoLen = le32(buf, p + 8);
          lbn = le32(buf, p + 12);
          ref = le16(buf, p + 16);
          p += 20;
          if (type != 3) {
            if (recLen > infoLen) recLen = infoLen;
            extLen = infoLen;
          }
        } else {
          headersError = true;
          return;
        }
        if (extLen == 0) break;
        if (type == 3) {
          next = lbn;
          nextRef = ref;
          break;
        }
        var n = extLen;
        if (n > remInfo) n = remInfo;
        if (n <= 0) continue;
        if (type == 0) {
          var rec = recLen < n ? recLen : n;
          if (!_mapExtent(ref, lbn, rec, item.runs)) {
            item.unsupported = true;
          }
          if (n > rec) item.runs.add(-1, n - rec);
        } else {
          item.runs.add(-1, n);
        }
        remInfo -= n;
      }
      if (next < 0) break;
      // allocation extent descriptor: 24 byte header, then descriptors
      if (++guard > 4096) {
        headersError = true;
        break;
      }
      final sec = _sectorOf(nextRef, next);
      if (sec < 0) {
        item.unsupported = true;
        break;
      }
      final ab = readAt(s, sec * sectorSize, blockSize);
      if (ab.length < 24 || _tag(ab, 0) != 258) {
        headersError = true;
        break;
      }
      buf = ab;
      adPos = 24;
      adLen = le32(ab, 20);
      if (adPos + adLen > ab.length) adLen = ab.length - adPos;
    }
    if (item.runs.total < item.size) {
      // the descriptors end before the information length: zeros
      item.runs.add(-1, item.size - item.runs.total);
    }
  }

  Uint8List _readItemData(UdfItem item, int limit) {
    final inl = item.inline;
    if (inl != null) return Uint8List.sublistView(inl, 0, item.size);
    var size = item.size;
    if (size > limit) {
      headersError = true;
      size = limit;
    }
    final st = RunsInStream(s, item.runs, size);
    final b = Uint8List(size);
    final n = readFully(st, b, 0, size);
    if (n < size) unexpectedEnd = true;
    return n < size ? Uint8List.sublistView(b, 0, n) : b;
  }

  // ---------- the file set and the tree ----------

  // reads the ICB at (ref, lbn), following indirect entries; null when it
  // is not a file entry
  (_FileEntry, Uint8List)? _readIcb(int ref, int lbn) {
    for (var guard = 0; guard < 16; guard++) {
      final sec = _sectorOf(ref, lbn);
      if (sec < 0) return null;
      final b = readAt(s, sec * sectorSize, blockSize);
      if (b.length < blockSize) {
        unexpectedEnd = true;
        return null;
      }
      final id = _tag(b, 0);
      if (id == 259) {
        // indirect entry: ICB tag, then the long_ad of the next ICB
        lbn = le32(b, 36 + 4);
        ref = le16(b, 36 + 8);
        continue;
      }
      if (id != 261 && id != 266) return null;
      final fe = _FileEntry.parse(b, id);
      if (fe == null) return null;
      return (fe, b);
    }
    return null;
  }

  void _readFileSet() {
    final sec = _sectorOf(_fsdRef, _fsdLbn);
    if (sec < 0) {
      headersError = true;
      return;
    }
    final b = readAt(s, sec * sectorSize, blockSize);
    if (b.length < 512 || _tag(b, 0) != 256) {
      headersError = true;
      return;
    }
    fileSetId = _dstring(b, 304, 32);
    modified ??= _timestamp(b, 16);
    final rootLbn = le32(b, 400 + 4);
    final rootRef = le16(b, 400 + 8);
    final root = _readIcb(rootRef, rootLbn);
    if (root == null) {
      headersError = true;
      return;
    }
    final visited = <int>{(rootRef << 32) | rootLbn};
    final rootItem = UdfItem();
    _loadData(root.$1, root.$2, rootRef, rootItem);
    final stack = <_Frame>[_Frame('', _listDir(rootItem, rootRef))];
    while (stack.isNotEmpty) {
      final f = stack.last;
      if (f.i >= f.entries.length) {
        stack.removeLast();
        continue;
      }
      final e = f.entries[f.i++];
      final icb = _readIcb(e.partRef, e.lbn);
      if (icb == null) {
        headersError = true;
        continue;
      }
      final fe = icb.$1;
      final item = UdfItem();
      item.path = f.prefix.isEmpty ? e.name : '${f.prefix}/${e.name}';
      item.hidden = e.hidden;
      _fill(item, fe);
      _loadData(fe, icb.$2, e.partRef, item);
      if (fe.fileType == 12) {
        item.symlink = _symlinkOf(_readItemData(item, 1 << 16));
        item.size = _utf8Length(item.symlink!);
      }
      if (item.unsupported) unsupportedFeature = true;
      items.add(item);
      if (item.isDir) {
        final key = (e.partRef << 32) | e.lbn;
        if (!visited.add(key) || stack.length > 1024) {
          headersError = true;
          continue;
        }
        stack.add(_Frame(item.path, _listDir(item, e.partRef)));
      }
    }
  }

  static int _utf8Length(String s) {
    var n = 0;
    for (final r in s.runes) {
      n += r < 0x80
          ? 1
          : r < 0x800
              ? 2
              : r < 0x10000
                  ? 3
                  : 4;
    }
    return n;
  }

  void _fill(UdfItem item, _FileEntry fe) {
    item.fileType = fe.fileType;
    item.isDir = fe.fileType == 4;
    var type = 0x8000;
    switch (fe.fileType) {
      case 4:
        type = 0x4000;
      case 6:
        type = 0x6000;
      case 7:
        type = 0x2000;
      case 9:
        type = 0x1000;
      case 10:
        type = 0xC000;
      case 12:
        type = 0xA000;
    }
    final p = fe.perms;
    var mode = (p & 7) | (((p >> 5) & 7) << 3) | (((p >> 10) & 7) << 6);
    if ((fe.flags & 0x40) != 0) mode |= 0x800;
    if ((fe.flags & 0x80) != 0) mode |= 0x400;
    if ((fe.flags & 0x100) != 0) mode |= 0x200;
    item.mode = type | mode;
    item.uid = fe.uid == 0xFFFFFFFF ? null : fe.uid;
    item.gid = fe.gid == 0xFFFFFFFF ? null : fe.gid;
    item.nlink = fe.links;
    item.mTime = fe.mTime;
    item.aTime = fe.aTime;
    item.cTime = fe.cTime;
    item.changeTime = fe.attrTime;
    item.packSize = fe.lbRecorded * blockSize;
  }

  // the file identifier descriptors of a directory
  List<_Entry> _listDir(UdfItem dir, int icbRef) {
    final out = <_Entry>[];
    final b = _readItemData(dir, 1 << 26);
    var p = 0;
    while (p + 38 <= b.length) {
      final id = _tag(b, p);
      if (id != 257) {
        headersError = true;
        break;
      }
      final chars = b[p + 18];
      final lfi = b[p + 19];
      final lbn = le32(b, p + 24);
      final ref = le16(b, p + 28);
      final liu = le16(b, p + 36);
      final total = (38 + liu + lfi + 3) & ~3;
      if (p + 38 + liu + lfi > b.length) {
        headersError = true;
        break;
      }
      if ((chars & 0x0C) == 0) {
        var name = _cs0(b, p + 38 + liu, lfi);
        if (name.isEmpty || name == '.' || name == '..') name = '_';
        if (name.contains('/')) name = name.replaceAll('/', '_');
        if (name.contains('\u0000')) name = name.replaceAll('\u0000', '_');
        out.add(_Entry(name, ref, lbn, (chars & 2) != 0, (chars & 1) != 0));
      }
      p += total;
    }
    return out;
  }

  // ECMA-167 4/14.16: the path components of a symbolic link
  static String _symlinkOf(Uint8List b) {
    final sb = StringBuffer();
    var p = 0;
    var first = true;
    while (p + 4 <= b.length) {
      final type = b[p];
      final n = b[p + 1];
      if (p + 4 + n > b.length) break;
      String comp;
      switch (type) {
        case 1:
        case 2:
          sb.clear();
          sb.write('/');
          first = true;
          p += 4 + n;
          continue;
        case 3:
          comp = '..';
        case 4:
          comp = '.';
        default:
          comp = _cs0(b, p + 4, n);
      }
      if (!first) sb.write('/');
      sb.write(comp);
      first = false;
      p += 4 + n;
    }
    return sb.toString();
  }

  // ---------- strings and times ----------

  /// OSTA CS0: compression id 8 (one byte per character) or 16 (UCS-2 big
  /// endian); 254 and 255 are the same encodings in UDF 2.50 and later.
  static String _cs0(Uint8List b, int o, int n) {
    if (n <= 0) return '';
    final c = b[o];
    if (c == 8 || c == 254) {
      return String.fromCharCodes(b, o + 1, o + n);
    }
    if (c == 16 || c == 255) {
      final units = <int>[];
      for (var i = o + 1; i + 1 < o + n; i += 2) {
        units.add((b[i] << 8) | b[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    return '';
  }

  /// dstring: CS0 with the used length in the last byte.
  static String _dstring(Uint8List b, int o, int n) {
    final used = b[o + n - 1];
    if (used == 0 || used > n - 1) return '';
    return _cs0(b, o, used);
  }

  static String _regidIdent(Uint8List b, int o) {
    var e = o + 1;
    while (e < o + 24 && b[e] != 0) {
      e++;
    }
    return String.fromCharCodes(b, o + 1, e);
  }

  static String _regid(Uint8List b, int o) => _regidIdent(b, o).trimRight();

  /// ECMA-167 1/7.3 timestamp.
  static int? _timestamp(Uint8List b, int o) {
    final tt = le16(b, o);
    final type = tt >> 12;
    var tz = tt & 0xFFF;
    if (tz >= 0x800) tz -= 0x1000;
    if (type != 1 || tz == -2047) tz = 0;
    var year = le16(b, o + 2);
    if (year >= 0x8000) year -= 0x10000;
    final ticks = b[o + 9] * 100000 + b[o + 10] * 1000 + b[o + 11] * 10;
    if (year == 0 && b[o + 4] == 0) return null;
    return fileTimeOf(
        year, b[o + 4], b[o + 5], b[o + 6], b[o + 7], b[o + 8], ticks, tz);
  }

  /// "x.yy" of the UDF revision in the domain identifier.
  String get revisionString {
    final r = udfRevision;
    if (r == 0) return '';
    final minor = r & 0xFF;
    return '${(r >> 8).toRadixString(16)}.${minor.toRadixString(16).padLeft(2, '0')}';
  }
}

// a file entry (tag 261) or an extended file entry (tag 266)
class _FileEntry {
  int fileType = 0;
  int flags = 0;
  int uid = 0;
  int gid = 0;
  int perms = 0;
  int links = 0;
  int infoLen = 0;
  int lbRecorded = 0;
  int? aTime;
  int? mTime;
  int? cTime;
  int? attrTime;
  int adStart = 0;
  int lad = 0;

  static _FileEntry? parse(Uint8List b, int id) {
    final fe = _FileEntry();
    fe.fileType = b[16 + 11];
    fe.flags = le16(b, 16 + 18);
    fe.uid = le32(b, 36);
    fe.gid = le32(b, 40);
    fe.perms = le32(b, 44);
    fe.links = le16(b, 48);
    fe.infoLen = le64(b, 56);
    int lea;
    if (id == 261) {
      fe.lbRecorded = le64(b, 64);
      fe.aTime = UdfReader._timestamp(b, 72);
      fe.mTime = UdfReader._timestamp(b, 84);
      fe.attrTime = UdfReader._timestamp(b, 96);
      lea = le32(b, 168);
      fe.lad = le32(b, 172);
      fe.adStart = 176 + lea;
    } else {
      fe.lbRecorded = le64(b, 72);
      fe.aTime = UdfReader._timestamp(b, 80);
      fe.mTime = UdfReader._timestamp(b, 92);
      fe.cTime = UdfReader._timestamp(b, 104);
      fe.attrTime = UdfReader._timestamp(b, 116);
      lea = le32(b, 208);
      fe.lad = le32(b, 212);
      fe.adStart = 216 + lea;
    }
    if (lea < 0 || fe.adStart > b.length || fe.infoLen < 0) return null;
    return fe;
  }
}
