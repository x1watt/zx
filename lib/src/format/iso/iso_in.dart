// ISO 9660 (ECMA-119) reader: volume descriptors, the directory tree walked
// from the root directory record (path tables are not used), multi-extent
// and interleaved files, Joliet names (UCS-2), Rock Ridge (SUSP and RRIP:
// NM, PX, PN, SL, TF, CL, PL, RE, CE continuation areas, ZF zisofs), the El
// Torito boot catalog and the last session of a multi-session image.
//
// Written from ECMA-119, the Joliet specification, IEEE P1281 (SUSP) and
// P1282 (RRIP) and the El Torito specification; the checks of the volume
// descriptors, the Rock Ridge parsing and the choice between Rock Ridge and
// Joliet follow libarchive's archive_read_support_format_iso9660.c
// (BSD 2-clause, see LICENSE).

import 'dart:convert';
import 'dart:typed_data';

import '../../io/streams.dart';
import 'disc_streams.dart';

/// S_IFMT and the file types of st_mode.
const int kIfMt = 0xF000;
const int kIfDir = 0x4000;
const int kIfReg = 0x8000;
const int kIfLnk = 0xA000;

/// One file or directory of the image, or an El Torito boot image.
class IsoItem {
  String path = '';
  bool isDir = false;
  final RunList runs = RunList();

  /// Size of the data (the uncompressed size of a zisofs file).
  int size = 0;
  int? mode;
  int? uid;
  int? gid;
  int? nlink;
  int? ino;
  int? rdevHigh;
  int? rdevLow;
  String? symlink;
  int? mTime;
  int? aTime;
  int? cTime; // creation (RRIP TF "creation")
  int? changeTime; // RRIP TF "attributes"
  bool hidden = false;

  /// log2 of the zisofs block size, 0 when the file is not compressed.
  int zfLog2 = 0;

  /// Index of the El Torito boot entry (0 based), -1 for a file.
  int bootIndex = -1;

  bool get isSymLink => symlink != null;
}

// the System Use fields of one directory record (SUSP / RRIP)
class _Susp {
  bool any = false; // any RRIP field
  List<int>? name;
  bool nameContinues = false;
  List<int>? link;
  bool linkContinues = false; // SL record continues
  bool compContinues = false; // last component continues
  bool lastWasRoot = false;
  int? mode;
  int? nlink;
  int? uid;
  int? gid;
  int? ino;
  int? rdevHigh;
  int? rdevLow;
  int? cTime;
  int? mTime;
  int? aTime;
  int? attrTime;
  bool re = false;
  int cl = -1;
  int zfLog2 = 0;
  int zfSize = 0;
  bool sp = false;
  int spSkip = 0;
  int ceLba = -1;
  int ceOff = 0;
  int ceLen = 0;
}

// a directory entry before it gets its path
class _Entry {
  final String name;
  final IsoItem item;
  final int dirLba;
  final int dirSize;
  _Entry(this.name, this.item, this.dirLba, this.dirSize);
}

class _Frame {
  final String prefix;
  final List<_Entry> entries;
  int i = 0;
  _Frame(this.prefix, this.entries);
}

/// Which names the tree was read with.
enum IsoNames { plain, joliet, rockRidge }

/// The parsed image.
class IsoReader {
  final SeekableInStream s;
  final List<IsoItem> items = [];

  int blockSize = 2048;
  int volumeBlocks = 0;

  /// First sector of the session that was read (0 for a single session).
  int sessionLba = 0;
  int numSessions = 1;
  IsoNames names = IsoNames.plain;
  bool hasJoliet = false;
  bool hasRockRidge = false;
  bool hasZisofs = false;
  bool hasBoot = false;
  bool headersError = false;
  bool unexpectedEnd = false;

  String volumeId = '';
  String systemId = '';
  String volumeSetId = '';
  String publisherId = '';
  String preparerId = '';
  String applicationId = '';
  int? created;
  int? modified;

  int _maxEnd = 0;

  // primary and Joliet root records
  int _pRootLba = -1;
  int _pRootSize = 0;
  int _jRootLba = -1;
  int _jRootSize = 0;
  int _bootCatalogLba = -1;

  // Rock Ridge state
  int _suspSkip = 0;
  bool _useRr = false;
  bool _joliet = false;

  IsoReader(this.s);

  /// The end of the used part of the image (volume space and extents).
  int get phySize {
    var v = volumeBlocks * blockSize;
    if (v <= sessionLba * 2048) v += sessionLba * 2048;
    return v > _maxEnd ? v : _maxEnd;
  }

  /// true when the stream holds a primary volume descriptor at sector 16.
  static bool hasPvdAt(Uint8List b, int off) =>
      b.length >= off + 7 &&
      b[off] == 1 &&
      b[off + 1] == 0x43 &&
      b[off + 2] == 0x44 &&
      b[off + 3] == 0x30 &&
      b[off + 4] == 0x30 &&
      b[off + 5] == 0x31 &&
      b[off + 6] == 1;

  /// Reads the volume descriptors and the tree. false when the stream is
  /// not an ISO 9660 image.
  bool open() {
    if (!_readVolumeDescriptors(16)) return false;
    // multi-session: a later session starts after the volume space of the
    // previous one (and a lead-out/lead-in gap on CD) and repeats the
    // descriptors 16 sectors in
    for (var guard = 0; guard < 64; guard++) {
      if (!_nextSession()) break;
    }
    _chooseTree();
    _readTree();
    _readBootCatalog();
    return true;
  }

  // Volume descriptors of the session whose descriptors start at [lba].
  bool _readVolumeDescriptors(int lba) {
    var seenPvd = false;
    int pRootLba = -1, pRootSize = 0, jRootLba = -1, jRootSize = 0;
    var bootLba = -1;
    var joliet = false;
    int bs = 2048, vb = 0;
    String? jVolumeId;
    final pvd = Uint8List(2048);
    for (var i = 0; i < 256; i++) {
      final h = readAt(s, (lba + i) * 2048, 2048);
      if (h.length < 2048) break;
      if (h[1] != 0x43 ||
          h[2] != 0x44 ||
          h[3] != 0x30 ||
          h[4] != 0x30 ||
          h[5] != 0x31) {
        break;
      }
      final type = h[0];
      if (type == 255) break;
      if (type == 1 && !seenPvd) {
        if (!_isPvd(h)) {
          if (i == 0) return false;
          continue;
        }
        seenPvd = true;
        pvd.setRange(0, 2048, h);
        bs = le16(h, 128);
        vb = le32(h, 80);
        pRootLba = le32(h, 156 + 2);
        pRootSize = le32(h, 156 + 10);
      } else if (type == 2 && h[6] == 1) {
        // Joliet: escape sequence %/@, %/C or %/E
        if (h[88] == 0x25 &&
            h[89] == 0x2F &&
            (h[90] == 0x40 || h[90] == 0x43 || h[90] == 0x45) &&
            h[156] >= 34) {
          joliet = true;
          jRootLba = le32(h, 156 + 2);
          jRootSize = le32(h, 156 + 10);
          jVolumeId = _ucs2(h, 40, 32).trimRight();
        }
      } else if (type == 0 && h[6] == 1) {
        if (_startsWith(h, 7, 'EL TORITO SPECIFICATION')) {
          bootLba = le32(h, 0x47);
        }
      }
    }
    if (!seenPvd) return false;
    if (bs != 512 && bs != 1024 && bs != 2048) return false;
    blockSize = bs;
    volumeBlocks = vb;
    sessionLba = lba - 16;
    _pRootLba = pRootLba;
    _pRootSize = pRootSize;
    _jRootLba = jRootLba;
    _jRootSize = jRootSize;
    hasJoliet = joliet;
    _bootCatalogLba = bootLba;
    systemId = _ascii(pvd, 8, 32);
    volumeId = _ascii(pvd, 40, 32);
    volumeSetId = _ascii(pvd, 190, 128);
    publisherId = _ascii(pvd, 318, 128);
    preparerId = _ascii(pvd, 446, 128);
    applicationId = _ascii(pvd, 574, 128);
    created = _date17(pvd, 813);
    modified = _date17(pvd, 830);
    if (joliet && jVolumeId != null && jVolumeId.isNotEmpty) {
      _jolietVolumeId = jVolumeId;
    } else {
      _jolietVolumeId = null;
    }
    return true;
  }

  String? _jolietVolumeId;

  // isPVD of libarchive: the reserved fields, both-endian sizes and the
  // root directory record
  static bool _isPvd(Uint8List h) {
    if (h[0] != 1 || h[6] != 1 || h[7] != 0) return false;
    for (var i = 72; i < 80; i++) {
      if (h[i] != 0) return false;
    }
    if (le32(h, 80) != be32(h, 84)) return false;
    final vb = le32(h, 80);
    if (vb <= 16 + 4) return false;
    if (le16(h, 128) != be16(h, 130) || le16(h, 128) == 0) return false;
    if (h[881] != 1) return false;
    final lpt = le32(h, 140);
    if (lpt < 16 + 2 || lpt >= vb) {
      // some writers leave the path tables out; the tree does not need them
    }
    final r = 156;
    if (h[r] < 34 || h[r] > 68) return false;
    if (le32(h, r + 2) != be32(h, r + 6)) return false;
    if (le32(h, r + 10) != be32(h, r + 14)) return false;
    if ((h[r + 25] & 0x8E) != 0x02) return false;
    if (h[r + 32] != 1 || h[r + 33] != 0) return false;
    return true;
  }

  bool _nextSession() {
    final cur = sessionLba;
    final size = volumeBlocks * blockSize ~/ 2048;
    // the volume space size counts from the start of the disc, or (as
    // genisoimage -C writes it) from the start of the session
    final ends = <int>{size, cur + size};
    for (final end in ends) {
      if (end <= cur) continue;
      for (final gap in const [0, 150, 6900, 6900 + 150, 11400, 11400 + 150]) {
        final lba = end + gap;
        final h = readAt(s, (lba + 16) * 2048, 2048);
        if (h.length < 2048 || !hasPvdAt(h, 0) || !_isPvd(h)) continue;
        // the root directory of a later session is in that session
        if (le32(h, 156 + 2) * le16(h, 128) ~/ 2048 < lba) continue;
        final saved = _State.save(this);
        if (_readVolumeDescriptors(lba + 16) && sessionLba > cur) {
          numSessions++;
          return true;
        }
        saved.restore(this);
      }
    }
    return false;
  }

  // Rock Ridge (from the primary tree) wins over Joliet, Joliet over the
  // plain names, as in libarchive
  void _chooseTree() {
    _useRr = false;
    final root = _readDirData(
        _pRootLba, _pRootSize > blockSize ? blockSize : _pRootSize);
    if (root.length >= 34) {
      final len = root[0];
      if (len >= 34 && len <= root.length && root[32] == 1) {
        final su = 34;
        if (su + 7 <= len &&
            root[su] == 0x53 &&
            root[su + 1] == 0x50 &&
            root[su + 2] == 7 &&
            root[su + 4] == 0xBE &&
            root[su + 5] == 0xEF) {
          _suspSkip = root[su + 6];
          final r = _Susp();
          _parseSystemUse(root, su + 7, len, r);
          if (r.any) hasRockRidge = true;
        }
      }
    }
    if (hasRockRidge) {
      _useRr = true;
      names = IsoNames.rockRidge;
    } else if (hasJoliet && _jRootLba >= 0) {
      _joliet = true;
      names = IsoNames.joliet;
    }
  }

  Uint8List _readDirData(int lba, int size) {
    if (lba < 0 || size <= 0) return Uint8List(0);
    if (size > (1 << 26)) {
      headersError = true;
      size = 1 << 26;
    }
    final b = readAt(s, lba * blockSize, size);
    if (b.length < size) unexpectedEnd = true;
    if (lba * blockSize + b.length > _maxEnd) {
      _maxEnd = lba * blockSize + b.length;
    }
    return b;
  }

  void _readTree() {
    final rootLba = _joliet ? _jRootLba : _pRootLba;
    final rootSize = _joliet ? _jRootSize : _pRootSize;
    final visited = <int>{rootLba};
    final stack = <_Frame>[_Frame('', _listDir(rootLba, rootSize, true))];
    while (stack.isNotEmpty) {
      final f = stack.last;
      if (f.i >= f.entries.length) {
        stack.removeLast();
        continue;
      }
      final e = f.entries[f.i++];
      final item = e.item;
      item.path = f.prefix.isEmpty ? e.name : '${f.prefix}/${e.name}';
      items.add(item);
      if (item.isDir && e.dirLba >= 0) {
        if (!visited.add(e.dirLba) || stack.length > 1024) {
          headersError = true;
          continue;
        }
        stack.add(_Frame(item.path, _listDir(e.dirLba, e.dirSize, false)));
      }
    }
  }

  // The entries of a directory: multi-extent records joined, "." and ".."
  // and associated files left out, Rock Ridge relocations resolved.
  List<_Entry> _listDir(int lba, int size, bool isRoot) {
    final out = <_Entry>[];
    final b = _readDirData(lba, size);
    final bs = blockSize;
    var p = 0;
    IsoItem? pending;
    String? pendingName;
    _Susp? pendingSusp;
    var pendingFlags = 0;
    var recIndex = 0;
    while (p < b.length) {
      final len = b[p];
      if (len == 0) {
        // the rest of the sector is padding
        p = (p ~/ bs + 1) * bs;
        continue;
      }
      if (len < 34 ||
          p + len > b.length ||
          b[p + 32] == 0 ||
          33 + b[p + 32] > len) {
        headersError = true;
        break;
      }
      final r = p;
      p += len;
      final nameLen = b[r + 32];
      final isDot = nameLen == 1 && (b[r + 33] == 0 || b[r + 33] == 1);
      recIndex++;
      if (isDot && recIndex <= 2) continue;
      final flags = b[r + 25];
      if ((flags & 0x04) != 0) continue; // associated file
      final extLba = le32(b, r + 2) + b[r + 1];
      final dataLen = le32(b, r + 10);
      final unit = b[r + 26];
      final gap = b[r + 27];

      final name = _recordName(b, r + 33, nameLen);
      if (pending != null) {
        if (name == pendingName) {
          _addExtent(pending, extLba, dataLen, unit, gap);
          if ((flags & 0x80) == 0) {
            _finish(
                out, pending, pendingName!, pendingSusp, pendingFlags, isRoot);
            pending = null;
          }
          continue;
        }
        headersError = true;
        _finish(out, pending, pendingName!, pendingSusp, pendingFlags, isRoot);
        pending = null;
      }

      final item = IsoItem();
      item.isDir = (flags & 0x02) != 0;
      item.hidden = (flags & 0x01) != 0;
      item.mTime = _date7(b, r + 18);
      _Susp? su;
      if (_useRr) {
        su = _Susp();
        var q = r + 33 + nameLen + ((nameLen & 1) == 0 ? 1 : 0);
        q += _suspSkip;
        if (q < r + len) _parseSystemUse(b, q, r + len, su);
        _followContinuation(su);
        if (su.re) continue; // the relocated directory, listed at its CL
      }
      if (!item.isDir) _addExtent(item, extLba, dataLen, unit, gap);
      if ((flags & 0x80) != 0 && !item.isDir) {
        pending = item;
        pendingName = name;
        pendingSusp = su;
        pendingFlags = flags;
        continue;
      }
      if (item.isDir) {
        _finishDir(out, item, name, su, extLba, dataLen, isRoot);
      } else {
        _finish(out, item, name, su, flags, isRoot);
      }
    }
    if (pending != null) {
      _finish(out, pending, pendingName!, pendingSusp, pendingFlags, isRoot);
    }
    return out;
  }

  void _addExtent(IsoItem item, int lba, int len, int unit, int gap) {
    final bs = blockSize;
    if (len == 0) return;
    if (unit == 0) {
      item.runs.add(lba * bs, len);
    } else {
      // interleaved: unit blocks of data, then gap blocks
      var rem = len;
      var blk = lba;
      while (rem > 0) {
        var n = unit * bs;
        if (n > rem) n = rem;
        item.runs.add(blk * bs, n);
        rem -= n;
        blk += unit + gap;
      }
    }
    final end = item.runs.maxEnd;
    if (end > _maxEnd) _maxEnd = end;
  }

  void _applySusp(IsoItem item, _Susp su) {
    if (su.mode != null) item.mode = su.mode;
    item.nlink = su.nlink;
    item.uid = su.uid;
    item.gid = su.gid;
    item.ino = su.ino;
    item.rdevHigh = su.rdevHigh;
    item.rdevLow = su.rdevLow;
    if (su.mTime != null) item.mTime = su.mTime;
    item.aTime = su.aTime;
    item.cTime = su.cTime;
    item.changeTime = su.attrTime;
  }

  String _nameOf(String isoName, _Susp? su) {
    final n = su?.name;
    if (n != null && n.isNotEmpty) return _safeName(_decodeUtf8(n));
    return _safeName(isoName);
  }

  static String _safeName(String n) {
    if (n.isEmpty || n == '.' || n == '..') return '_';
    if (n.contains('/')) n = n.replaceAll('/', '_');
    if (n.contains('\u0000')) n = n.replaceAll('\u0000', '_');
    return n;
  }

  void _finish(List<_Entry> out, IsoItem item, String isoName, _Susp? su,
      int flags, bool isRoot) {
    final name = _nameOf(isoName, su);
    item.size = item.runs.total;
    if (su != null) {
      _applySusp(item, su);
      if (su.cl >= 0) {
        // a relocated directory: the placeholder file points at it
        item.isDir = true;
        item.runs.pos.clear();
        item.runs.len.clear();
        item.runs.total = 0;
        item.size = 0;
        final m = item.mode;
        if (m != null) item.mode = (m & 0xFFF) | kIfDir;
        final dot = _readDirData(su.cl, 34);
        var dirSize = 0;
        if (dot.length >= 34) dirSize = le32(dot, 10);
        out.add(_Entry(name, item, su.cl, dirSize));
        return;
      }
      final link = su.link;
      final m = item.mode;
      if (m != null && (m & kIfMt) == kIfLnk) {
        item.symlink = link == null ? '' : _decodeUtf8(link);
        item.runs.pos.clear();
        item.runs.len.clear();
        item.runs.total = 0;
        item.size = utf8.encode(item.symlink!).length;
      } else if (m != null && (m & kIfMt) != kIfReg && (m & kIfMt) != 0) {
        // device, fifo or socket: no data
        item.runs.pos.clear();
        item.runs.len.clear();
        item.runs.total = 0;
        item.size = 0;
      } else if (su.zfLog2 != 0) {
        item.zfLog2 = su.zfLog2;
        item.size = su.zfSize;
        hasZisofs = true;
      }
    }
    out.add(_Entry(name, item, -1, 0));
  }

  void _finishDir(List<_Entry> out, IsoItem item, String isoName, _Susp? su,
      int lba, int size, bool isRoot) {
    final name = _nameOf(isoName, su);
    if (su != null) _applySusp(item, su);
    if (isRoot && _useRr && (name == 'rr_moved' || name == '.rr_moved')) {
      // the directory that holds relocated directories: left out when it
      // holds nothing else
      if (_listDir(lba, size, false).isEmpty) return;
    }
    out.add(_Entry(name, item, lba, size));
  }

  String _recordName(Uint8List b, int o, int n) {
    if (_joliet) {
      var len = n & ~1;
      var str = _ucs2(b, o, len);
      final semi = str.lastIndexOf(';');
      if (semi >= 0 && _allDigits(str, semi + 1)) str = str.substring(0, semi);
      return str;
    }
    var str = latin1.decode(Uint8List.sublistView(b, o, o + n));
    final semi = str.lastIndexOf(';');
    if (semi >= 0 && _allDigits(str, semi + 1)) str = str.substring(0, semi);
    if (str.length > 1 && str.endsWith('.')) {
      str = str.substring(0, str.length - 1);
    }
    return str;
  }

  static bool _allDigits(String s, int from) {
    for (var i = from; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return false;
    }
    return true;
  }

  // CE: continuation areas, followed up to a fixed depth
  void _followContinuation(_Susp su) {
    for (var guard = 0; guard < 32 && su.ceLba >= 0; guard++) {
      final lba = su.ceLba;
      final off = su.ceOff;
      final len = su.ceLen;
      su.ceLba = -1;
      if (len <= 0 || len > 65536) {
        headersError = true;
        return;
      }
      final b = readAt(s, lba * blockSize + off, len);
      if (b.length < len) {
        headersError = true;
        return;
      }
      _parseSystemUse(b, 0, len, su);
    }
  }

  // parse_rockridge: the SUSP entries of p[q..end)
  void _parseSystemUse(Uint8List b, int q, int end, _Susp r) {
    while (q + 4 <= end) {
      final c0 = b[q];
      final c1 = b[q + 1];
      final len = b[q + 2];
      final ver = b[q + 3];
      if (len < 4 || q + len > end) break;
      final d = q + 4;
      final dl = len - 4;
      q += len;
      if (c0 < 0x41 || c0 > 0x5A || c1 < 0x41 || c1 > 0x5A) break;
      final sig = (c0 << 8) | c1;
      switch (sig) {
        case 0x4345: // CE
          if (dl >= 24) {
            r.ceLba = le32(b, d);
            r.ceOff = le32(b, d + 8);
            r.ceLen = le32(b, d + 16);
          }
        case 0x5354: // ST
          if (dl == 0) return;
        case 0x5350: // SP
          break;
        case 0x5252: // RR
          r.any = true;
        case 0x4552: // ER
          r.any = true;
        case 0x4E4D: // NM
          if (ver == 1 && dl >= 1) {
            r.any = true;
            final f = b[d];
            if (!r.nameContinues) r.name = [];
            r.nameContinues = (f & 1) != 0;
            if ((f & 6) == 0) {
              r.name!.addAll(Uint8List.sublistView(b, d + 1, d + dl));
            }
          }
        case 0x5058: // PX
          if (ver == 1) {
            r.any = true;
            if (dl >= 8) r.mode = le32(b, d);
            if (dl >= 16) r.nlink = le32(b, d + 8);
            if (dl >= 24) r.uid = le32(b, d + 16);
            if (dl >= 32) r.gid = le32(b, d + 24);
            if (dl >= 40) r.ino = le32(b, d + 32);
          }
        case 0x504E: // PN
          if (ver == 1 && dl >= 16) {
            r.any = true;
            r.rdevHigh = le32(b, d);
            r.rdevLow = le32(b, d + 8);
          }
        case 0x534C: // SL
          if (ver == 1 && dl >= 1) {
            r.any = true;
            _parseSl(b, d, dl, r);
          }
        case 0x5446: // TF
          if (ver == 1 && dl >= 1) {
            r.any = true;
            _parseTf(b, d, dl, r);
          }
        case 0x434C: // CL
          if (dl >= 8) {
            r.any = true;
            r.cl = le32(b, d);
          }
        case 0x5245: // RE
          r.any = true;
          r.re = true;
        case 0x5A46: // ZF
          if (ver == 1 && dl >= 12 && b[d] == 0x70 && b[d + 1] == 0x7A) {
            final lg = b[d + 3];
            if (lg >= 15 && lg <= 17) {
              r.zfLog2 = lg;
              r.zfSize = le32(b, d + 4);
            }
          }
      }
    }
  }

  // parse_rockridge_SL1, with the separator kept across SL entries
  static void _parseSl(Uint8List b, int d, int dl, _Susp r) {
    if (!r.linkContinues || r.link == null) {
      r.link = [];
      r.compContinues = false;
      r.lastWasRoot = false;
    }
    final link = r.link!;
    r.linkContinues = (b[d] & 1) != 0;
    var q = d + 1;
    final end = d + dl;
    while (q + 2 <= end) {
      final f = b[q];
      final n = b[q + 1];
      q += 2;
      if (q + n > end) break;
      if (link.isNotEmpty && !r.compContinues && !r.lastWasRoot) {
        link.add(0x2F);
      }
      r.lastWasRoot = false;
      if ((f & 0x02) != 0) {
        link.add(0x2E);
      } else if ((f & 0x04) != 0) {
        link.addAll(const [0x2E, 0x2E]);
      } else if ((f & 0x08) != 0) {
        link.clear();
        link.add(0x2F);
        r.lastWasRoot = true;
      } else {
        link.addAll(Uint8List.sublistView(b, q, q + n));
      }
      r.compContinues = (f & 0x01) != 0;
      q += n;
    }
  }

  // parse_rockridge_TF1
  static void _parseTf(Uint8List b, int d, int dl, _Susp r) {
    final f = b[d];
    final longForm = (f & 0x80) != 0;
    final step = longForm ? 17 : 7;
    var q = d + 1;
    final end = d + dl;
    for (var bit = 0; bit < 4; bit++) {
      if ((f & (1 << bit)) == 0) continue;
      if (q + step > end) return;
      final t = longForm ? _date17(b, q) : _date7(b, q);
      switch (bit) {
        case 0:
          r.cTime = t;
        case 1:
          r.mTime = t;
        case 2:
          r.aTime = t;
        case 3:
          r.attrTime = t;
      }
      q += step;
    }
  }

  // ---------- El Torito ----------

  void _readBootCatalog() {
    final lba = _bootCatalogLba;
    if (lba <= 0) return;
    final b = readAt(s, lba * 2048, 2048 * 4);
    if (b.length < 64) return;
    // validation entry: header id 1, key bytes 55 AA, checksum of words 0
    if (b[0] != 1 || b[30] != 0x55 || b[31] != 0xAA) return;
    var sum = 0;
    for (var i = 0; i < 32; i += 2) {
      sum = (sum + le16(b, i)) & 0xFFFF;
    }
    if (sum != 0) return;
    final entries = <int>[32];
    var q = 64;
    var more = true;
    while (more && q + 32 <= b.length) {
      final h = b[q];
      if (h != 0x90 && h != 0x91) break;
      more = h == 0x90;
      final n = le16(b, q + 2);
      q += 32;
      for (var k = 0; k < n && q + 32 <= b.length; k++) {
        // extension entries (0x44) follow an entry whose bit 5 of the
        // selection criteria type says so
        if (b[q] == 0x88 || b[q] == 0x00) entries.add(q);
        q += 32;
        while (q + 32 <= b.length && b[q] == 0x44) {
          q += 32;
        }
      }
    }
    final boots = <IsoItem>[];
    for (final e in entries) {
      if (b[e] != 0x88 && b[e] != 0x00) continue;
      final media = b[e + 1] & 0x0F;
      final count = le16(b, e + 6);
      final rba = le32(b, e + 8);
      if (rba == 0 && count == 0) continue;
      if (e != 32 && b[e] != 0x88 && rba == 0) continue;
      final start = rba * 2048;
      int size;
      String kind;
      switch (media) {
        case 1:
          size = 1228800;
          kind = '1.2M';
        case 2:
          size = 1474560;
          kind = '1.44M';
        case 3:
          size = 2949120;
          kind = '2.88M';
        case 4:
          kind = 'HardDisk';
          size = _hardDiskSize(start, count);
        default:
          kind = 'NoEmul';
          size = count * 512;
          if (count <= 1) {
            // the loader is often recorded as a file of the tree
            for (final it in items) {
              if (!it.isDir &&
                  it.runs.pos.isNotEmpty &&
                  it.runs.pos[0] == start &&
                  it.zfLog2 == 0) {
                size = it.size;
                break;
              }
            }
            if (size == 0) size = 512;
          }
      }
      final avail = s.length - start;
      if (avail <= 0) continue;
      if (size > avail) {
        size = avail;
      }
      final it = IsoItem()
        ..bootIndex = boots.length
        ..size = size
        ..path = kind;
      it.runs.add(start, size);
      boots.add(it);
    }
    if (boots.isEmpty) return;
    hasBoot = true;
    for (var i = 0; i < boots.length; i++) {
      final it = boots[i];
      final prefix = boots.length > 1 ? '${i + 1}-' : '';
      it.path = '[BOOT]/${prefix}Boot-${it.path}.img';
      items.add(it);
    }
  }

  // the size of a hard disk boot image: the end of its first partition
  int _hardDiskSize(int start, int count) {
    final mbr = readAt(s, start, 512);
    var size = count * 512;
    if (mbr.length == 512 && mbr[510] == 0x55 && mbr[511] == 0xAA) {
      for (var i = 0; i < 4; i++) {
        final p = 446 + i * 16;
        if (mbr[p + 4] == 0) continue;
        final end = (le32(mbr, p + 8) + le32(mbr, p + 12)) * 512;
        if (end > size) size = end;
      }
    }
    return size;
  }

  // ---------- strings and dates ----------

  /// The volume label: the Joliet one when the Joliet tree was read.
  String get label =>
      (_joliet && _jolietVolumeId != null) ? _jolietVolumeId! : volumeId;

  static bool _startsWith(Uint8List b, int o, String s) {
    for (var i = 0; i < s.length; i++) {
      if (b[o + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  static String _ascii(Uint8List b, int o, int n) =>
      latin1.decode(Uint8List.sublistView(b, o, o + n)).trimRight();

  static String _ucs2(Uint8List b, int o, int n) {
    final sb = StringBuffer();
    for (var i = 0; i + 1 < n; i += 2) {
      final c = (b[o + i] << 8) | b[o + i + 1];
      sb.writeCharCode(c);
    }
    return sb.toString();
  }

  static String _decodeUtf8(List<int> b) {
    try {
      return utf8.decode(b);
    } on FormatException {
      return latin1.decode(b);
    }
  }

  // 7 byte recording date (ECMA-119 9.1.5)
  static int? _date7(Uint8List b, int o) {
    if (b[o] == 0 && b[o + 1] == 0 && b[o + 2] == 0) return null;
    final off = b[o + 6] >= 128 ? b[o + 6] - 256 : b[o + 6];
    return fileTimeOf(1900 + b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4],
        b[o + 5], 0, off * 15);
  }

  // 17 byte date and time (ECMA-119 8.4.26.1)
  static int? _date17(Uint8List b, int o) {
    int num(int p, int n) {
      var v = 0;
      for (var i = 0; i < n; i++) {
        final c = b[o + p + i] - 0x30;
        if (c < 0 || c > 9) return -1;
        v = v * 10 + c;
      }
      return v;
    }

    final year = num(0, 4);
    if (year <= 0) return null;
    final month = num(4, 2), day = num(6, 2), hour = num(8, 2);
    final minute = num(10, 2), second = num(12, 2), cs = num(14, 2);
    if (month < 0 ||
        day < 0 ||
        hour < 0 ||
        minute < 0 ||
        second < 0 ||
        cs < 0) {
      return null;
    }
    final off = b[o + 16] >= 128 ? b[o + 16] - 256 : b[o + 16];
    return fileTimeOf(
        year, month, day, hour, minute, second, cs * 100000, off * 15);
  }
}

// the fields that _readVolumeDescriptors sets, to undo a failed session
class _State {
  final int blockSize, volumeBlocks, sessionLba, pRootLba, pRootSize;
  final int jRootLba, jRootSize, bootLba;
  final bool hasJoliet;
  final String volumeId, systemId, volumeSetId, publisherId, preparerId;
  final String applicationId;
  final String? jVolumeId;
  final int? created, modified;
  _State(
      this.blockSize,
      this.volumeBlocks,
      this.sessionLba,
      this.pRootLba,
      this.pRootSize,
      this.jRootLba,
      this.jRootSize,
      this.bootLba,
      this.hasJoliet,
      this.volumeId,
      this.systemId,
      this.volumeSetId,
      this.publisherId,
      this.preparerId,
      this.applicationId,
      this.jVolumeId,
      this.created,
      this.modified);

  static _State save(IsoReader r) => _State(
      r.blockSize,
      r.volumeBlocks,
      r.sessionLba,
      r._pRootLba,
      r._pRootSize,
      r._jRootLba,
      r._jRootSize,
      r._bootCatalogLba,
      r.hasJoliet,
      r.volumeId,
      r.systemId,
      r.volumeSetId,
      r.publisherId,
      r.preparerId,
      r.applicationId,
      r._jolietVolumeId,
      r.created,
      r.modified);

  void restore(IsoReader r) {
    r.blockSize = blockSize;
    r.volumeBlocks = volumeBlocks;
    r.sessionLba = sessionLba;
    r._pRootLba = pRootLba;
    r._pRootSize = pRootSize;
    r._jRootLba = jRootLba;
    r._jRootSize = jRootSize;
    r._bootCatalogLba = bootLba;
    r.hasJoliet = hasJoliet;
    r.volumeId = volumeId;
    r.systemId = systemId;
    r.volumeSetId = volumeSetId;
    r.publisherId = publisherId;
    r.preparerId = preparerId;
    r.applicationId = applicationId;
    r._jolietVolumeId = jVolumeId;
    r.created = created;
    r.modified = modified;
  }
}
