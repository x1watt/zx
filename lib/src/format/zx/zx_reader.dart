// Reading .zx files (docs/zx-format.md, section 13): the Header with its
// compatibility check, the last valid Footer (crash safety), the Index of
// the current or of a chosen generation, the volumes of a multi-volume set
// (found by their Header in the folder of the file and in search folders),
// and the blocks.

import 'dart:io';
import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/xxhash.dart';
import 'zx_blocks.dart';
import 'zx_codecs.dart';
import 'zx_crypto.dart';
import 'zx_format.dart';

/// A volume that is needed and not found.
class ZxMissingVolumeException extends SevenZipException {
  final int volume;
  final String expectedName;
  ZxMissingVolumeException(this.volume, this.expectedName)
      : super(
            'zx: volume ${volume + 1} is missing ($expectedName; the '
            'folders of the volumes can be given with -mvsearch)',
            SevenZipError.unavailable);
}

/// Thrown when a password is needed and none was given.
class ZxNeedPasswordException extends SevenZipException {
  const ZxNeedPasswordException()
      : super('zx: a password is needed', SevenZipError.wrongPassword);
}

/// Where one volume is.
class _Vol {
  final String? path;
  SeekableInStream? stream;
  final bool owned;
  _Vol(this.path, this.stream, {this.owned = true});
}

/// The volumes of a file or set, opened on demand.
class ZxVolumes {
  final Map<int, _Vol> _vols = {};
  final Uint8List archiveId;
  final bool multi;

  /// Folders searched for volumes (the folder of the opened file first).
  final List<String> dirs;

  /// Names by number from the volume table.
  Map<int, String> expectedNames = {};
  String baseName;

  ZxVolumes._(this.archiveId, this.multi, this.dirs, this.baseName);

  /// A single file.
  factory ZxVolumes.single(SeekableInStream s, Uint8List id) =>
      ZxVolumes._(id, false, const [], '')
        .._vols[0] = _Vol(null, s, owned: false);

  int get count => _vols.length;

  /// The numbers of the volumes found.
  List<int> get numbers => _vols.keys.toList()..sort();

  String? pathOf(int v) => _vols[v]?.path;

  /// Paths of the volumes found, by number.
  List<String> get paths => [
        for (final n in numbers)
          if (_vols[n]!.path != null) _vols[n]!.path!
      ];

  void _add(int n, String? path, SeekableInStream? s, {bool owned = true}) {
    _vols[n] = _Vol(path, s, owned: owned);
  }

  /// The expected file name of volume [v].
  String nameOf(int v) =>
      expectedNames[v] ?? '$baseName.${'${v + 1}'.padLeft(3, '0')}';

  SeekableInStream stream(int v) {
    final vol = _vols[v] ?? _find(v);
    if (vol == null) throw ZxMissingVolumeException(v, nameOf(v));
    return vol.stream ??= FileInStream.open(vol.path!);
  }

  _Vol? _find(int v) {
    if (!multi) return null;
    // the name from the volume table, then any file of the folders
    final names = <String>{nameOf(v)};
    for (final d in dirs) {
      for (final n in names) {
        final p = '$d${Platform.pathSeparator}$n';
        if (_isVolume(p, v)) return _vols[v] = _Vol(p, null);
      }
    }
    for (final d in dirs) {
      for (final (p, num) in _scanDir(d, archiveId)) {
        if (!_vols.containsKey(num)) _vols[num] = _Vol(p, null);
      }
    }
    return _vols[v];
  }

  bool _isVolume(String path, int v) {
    final h = zxPeekVolumeHeader(path);
    return h != null && _sameId(h.$1, archiveId) && h.$2 == v;
  }

  Uint8List readAt(int v, int pos, int len) {
    final s = stream(v);
    if (pos < 0 || len < 0 || pos + len > s.length) {
      throw const SevenZipException(
          'zx: data beyond the end of the file', SevenZipError.unexpectedEnd);
    }
    final b = Uint8List(len);
    s.position = pos;
    if (readFully(s, b, 0, len) != len) {
      throw const SevenZipException(
          'zx: unexpected end of the file', SevenZipError.unexpectedEnd);
    }
    return b;
  }

  int lengthOf(int v) => stream(v).length;

  void close() {
    for (final v in _vols.values) {
      final s = v.stream;
      if (v.owned && s is FileInStream) {
        try {
          s.close();
        } on FileSystemException {
          // ignore
        }
      }
      if (v.owned) v.stream = null;
    }
  }
}

bool _sameId(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The archive id and volume number of the zx volume at [path] (a file
/// whose Header is valid and has the multi_volume flag), or null.
(Uint8List, int)? zxPeekVolumeHeader(String path) {
  RandomAccessFile? f;
  try {
    f = File(path).openSync();
    final len = f.lengthSync();
    if (len < zxHeaderFixedSize) return null;
    final fixed = Uint8List(zxHeaderFixedSize);
    if (f.readIntoSync(fixed) != zxHeaderFixedSize) return null;
    if (!ZxHeader.hasMagic(fixed)) return null;
    final rs = getUint32LE(fixed, 56);
    if (rs > 1 << 20 || zxHeaderFixedSize + rs > len) return null;
    final rec = Uint8List(rs);
    if (f.readIntoSync(rec) != rs) return null;
    final h = ZxHeader.decode(fixed, rec);
    if (!h.multiVolume || h.volumeNumber == null) return null;
    return (h.archiveId, h.volumeNumber!);
  } on Object {
    return null;
  } finally {
    try {
      f?.closeSync();
    } on Object {
      // ignore
    }
  }
}

List<(String, int)> _scanDir(String dir, Uint8List id) {
  final out = <(String, int)>[];
  try {
    for (final e in Directory(dir).listSync(followLinks: false)) {
      if (e is! File) continue;
      final h = zxPeekVolumeHeader(e.path);
      if (h != null && _sameId(h.$1, id)) out.add((e.path, h.$2));
    }
  } on FileSystemException {
    // not readable
  }
  return out;
}

/// Parses a generation date "YYYY-MM-DD", "YYYY-MM-DD HH:MM" or
/// "YYYY-MM-DD HH:MM:SS" (local time, a 'T' may separate date and time)
/// and returns the end of that day, minute or second in nanoseconds since
/// 1970 UTC (exclusive), or null when [s] is not such a date.
int? zxParseGenerationDate(String s) {
  final m = RegExp(
          r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$')
      .firstMatch(s.trim());
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  DateTime end;
  if (m[4] == null) {
    end = DateTime(y, mo, d + 1);
  } else {
    final h = int.parse(m[4]!), mi = int.parse(m[5]!);
    if (h > 23 || mi > 59) return null;
    if (m[6] == null) {
      end = DateTime(y, mo, d, h, mi + 1);
    } else {
      final sec = int.parse(m[6]!);
      if (sec > 59) return null;
      end = DateTime(y, mo, d, h, mi, sec + 1);
    }
  }
  return end.microsecondsSinceEpoch * 1000;
}

/// The generation to show: a number, a date (see [zxParseGenerationDate])
/// or null for the last one.
class ZxGenerationSelector {
  final int? number;
  final String? date;
  const ZxGenerationSelector({this.number, this.date});

  /// From the text of -mversion: a number or a date.
  static ZxGenerationSelector? parse(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n != null) return n == 0 ? null : ZxGenerationSelector(number: n);
    if (zxParseGenerationDate(t) == null) {
      throw SevenZipException(
          'zx: bad generation "$s" (a number or YYYY-MM-DD[ HH:MM[:SS]])',
          SevenZipError.unsupported);
    }
    return ZxGenerationSelector(date: t);
  }
}

/// What [ZxArchiveReader.open] needs besides the stream.
class ZxOpenParams {
  /// The full path of the opened file (for volumes; null for a stream
  /// that is not a file).
  final String? path;
  final List<String> searchDirs;

  /// Gives the password when the Index is encrypted (null: none).
  final String? Function()? password;
  final ZxGenerationSelector? generation;
  const ZxOpenParams(
      {this.path, this.searchDirs = const [], this.password, this.generation});
}

/// An opened .zx file.
class ZxArchiveReader {
  final ZxHeader header;
  final ZxVolumes volumes;

  /// The Index of the last generation (the current state).
  final ZxIndex lastIndex;

  /// The Index shown (of the chosen generation).
  ZxIndex index;

  /// The volume that holds the last Footer and where it ends (the next
  /// update writes from there).
  final int lastVolume;
  final int validEnd;

  /// Where the last Index is.
  final ZxIndexLoc lastIndexLoc;

  /// Messages about damage that was worked around (an interrupted update).
  final List<String> warnings;

  ZxKeys? keys;

  ZxArchiveReader._(
      this.header,
      this.volumes,
      this.lastIndex,
      this.index,
      this.lastVolume,
      this.validEnd,
      this.lastIndexLoc,
      this.warnings,
      this.keys);

  /// Every generation, oldest first.
  List<ZxGeneration> get generations {
    final l = lastIndex.generations;
    if (l.isNotEmpty) return l;
    final g = lastIndex.generation;
    return g == null ? const [] : [g];
  }

  /// The number of the generation shown.
  int get shownGeneration => index.generation?.number ?? generations.length;

  bool get isLatest => identical(index, lastIndex);

  /// Reads the Header at the start of [s]; null when [s] is not a zx file
  /// (wrong magic). Throws [SevenZipException] for a damaged header or a
  /// file this zx can not read (section 3.1).
  static ZxHeader? readHeader(SeekableInStream s) {
    if (s.length < zxHeaderFixedSize) return null;
    final fixed = Uint8List(zxHeaderFixedSize);
    s.position = 0;
    if (readFully(s, fixed, 0, zxHeaderFixedSize) != zxHeaderFixedSize) {
      return null;
    }
    if (!ZxHeader.hasMagic(fixed)) return null;
    final rs = getUint32LE(fixed, 56);
    if (zxHeaderFixedSize + rs > s.length) {
      throw const SevenZipException(
          'zx: the header is damaged (bad size)', SevenZipError.headers);
    }
    final rec = Uint8List(rs);
    readExactly(s, rec, 0, rs);
    return ZxHeader.decode(fixed, rec);
  }

  /// Opens [s] (a file or the volume of a set). Returns null when it is
  /// not a zx file.
  static ZxArchiveReader? open(SeekableInStream s, ZxOpenParams p) {
    final header = readHeader(s);
    if (header == null) return null;
    ZxVolumes vols;
    var lastVol = 0;
    if (header.multiVolume) {
      vols = _findVolumes(s, header, p);
      lastVol = -1;
    } else {
      vols = ZxVolumes.single(s, header.archiveId);
    }

    ZxKeys? keys;
    final kdf = header.kdf;
    ZxKeys? getKeys() {
      if (keys != null) return keys;
      if (kdf == null) return null;
      final pw = p.password?.call();
      if (pw == null) throw const ZxNeedPasswordException();
      final k = zxCheckPassword(pw, kdf);
      if (k == null) {
        throw const SevenZipException(
            'zx: wrong password', SevenZipError.wrongPassword);
      }
      return keys = k;
    }

    if (header.encryptedMetadata) getKeys();

    // the last volume with a valid Footer
    final warnings = <String>[];
    (int, int, ZxFooter, ZxIndex)? found;
    final candidates =
        header.multiVolume ? (vols.numbers.reversed.toList()) : const [0];
    for (final v in candidates) {
      found = _lastFooter(vols, v, header, keys, warnings);
      if (found != null) {
        lastVol = v;
        break;
      }
      if (header.multiVolume) {
        warnings.add('volume ${v + 1} has no valid Footer (an interrupted '
            'update?): it is ignored');
      }
    }
    if (found == null) {
      if (header.multiVolume && vols.numbers.isNotEmpty) {
        // the last volume found ends with a trailer: the set goes on
        final last = vols.numbers.last;
        try {
          final len = vols.lengthOf(last);
          final t = ZxVolumeTrailer.tryParse(
              vols.readAt(last, len - zxFooterSize, zxFooterSize), 0);
          if (t != null) {
            throw ZxMissingVolumeException(last + 1, vols.nameOf(last + 1));
          }
        } on ZxMissingVolumeException {
          rethrow;
        } on SevenZipException {
          // not readable
        }
      }
      throw const SevenZipException(
          'zx: no valid Footer or Index (the archive is damaged or '
          'incomplete)',
          SevenZipError.headers);
    }
    final (_, end, footer, last) = found;
    final loc = ZxIndexLoc(lastVol, footer.indexOffset, footer.indexSize);
    final vt = last.volumes;
    if (vt != null) {
      for (final v in vt) {
        vols.expectedNames[v.number] = v.name;
      }
    }
    final r = ZxArchiveReader._(
        header, vols, last, last, lastVol, end, loc, warnings, keys);
    final sel = p.generation;
    if (sel != null) r.selectGeneration(sel);
    return r;
  }

  static ZxVolumes _findVolumes(
      SeekableInStream s, ZxHeader header, ZxOpenParams p) {
    final path = p.path;
    final dirs = <String>[];
    var base = 'archive.zx';
    if (path != null) {
      final f = File(path);
      dirs.add(f.parent.path);
      final name = f.uri.pathSegments.last;
      final m = RegExp(r'^(.*)\.(\d{3,})$').firstMatch(name);
      base = m != null ? m[1]! : name;
    }
    for (final d in p.searchDirs) {
      if (!dirs.contains(d)) dirs.add(d);
    }
    final vols = ZxVolumes._(header.archiveId, true, dirs, base);
    vols._add(header.volumeNumber ?? 0, path, s, owned: false);
    for (final d in dirs) {
      for (final (vp, num) in _scanDir(d, header.archiveId)) {
        if (!vols._vols.containsKey(num)) vols._add(num, vp, null);
      }
    }
    return vols;
  }

  // The last Footer of volume [v] whose CRC is valid and whose Index
  // decodes: (volume, end of the Footer, Footer, Index).
  static (int, int, ZxFooter, ZxIndex)? _lastFooter(ZxVolumes vols, int v,
      ZxHeader header, ZxKeys? keys, List<String> warnings) {
    final SeekableInStream s;
    try {
      s = vols.stream(v);
    } on SevenZipException {
      return null;
    }
    final len = s.length;
    ZxIndex? tryAt(int pos) {
      if (pos < header.size || pos + zxFooterSize > len) return null;
      final b = vols.readAt(v, pos, zxFooterSize);
      final f = ZxFooter.tryParse(b, 0);
      if (f == null) return null;
      if (f.indexOffset + f.indexSize != pos) return null;
      try {
        final idx = readIndex(
            vols, header, keys, ZxIndexLoc(v, f.indexOffset, f.indexSize));
        return idx;
      } on ZxNeedPasswordException {
        rethrow;
      } on SevenZipException catch (e) {
        if (e.kind == SevenZipError.unsupported ||
            e.kind == SevenZipError.unsupportedMethod ||
            e.kind == SevenZipError.wrongPassword) {
          rethrow;
        }
        return null;
      }
    }

    final tail = len - zxFooterSize;
    final idx = tryAt(tail);
    if (idx != null) {
      final b = vols.readAt(v, tail, zxFooterSize);
      return (v, len, ZxFooter.tryParse(b, 0)!, idx);
    }
    // scan backwards for the magic of an earlier Footer
    const chunk = 1 << 16;
    var hi = len;
    while (hi > header.size) {
      final lo = hi - chunk < header.size ? header.size : hi - chunk;
      final n = hi - lo + 3 > len - lo ? len - lo : hi - lo + 3;
      final b = vols.readAt(v, lo, n);
      for (var i = n - 4; i >= 0; i--) {
        if (b[i] == 0x58 &&
            b[i + 1] == 0x5A &&
            b[i + 2] == 0x45 &&
            b[i + 3] == 0x1A) {
          final pos = lo + i - 28;
          final idx2 = tryAt(pos);
          if (idx2 != null) {
            final fb = vols.readAt(v, pos, zxFooterSize);
            warnings.add('zx: ${len - pos - zxFooterSize} bytes after the '
                'last valid Footer are ignored (an interrupted update)');
            return (v, pos + zxFooterSize, ZxFooter.tryParse(fb, 0)!, idx2);
          }
        }
      }
      hi = lo;
    }
    return null;
  }

  /// Reads and decodes the Index at [loc].
  static ZxIndex readIndex(
      ZxVolumes vols, ZxHeader header, ZxKeys? keys, ZxIndexLoc loc) {
    final raw = vols.readAt(loc.volume, loc.offset, loc.size);
    final parts = <Uint8List>[];
    var pos = 0;
    var total = 0;
    while (pos < raw.length) {
      final h = ZxBlockHeader.tryParse(raw, pos, raw.length);
      if (h == null) zxDamaged('damaged Index block');
      if (h.type != ZxBlockType.index) zxDamaged('not an Index block');
      final end = pos + h.headerSize + h.packedSize;
      if (end > raw.length) zxDamaged('truncated Index block');
      final chain = metaChainOf(header, h.chainId);
      final encrypted = header.encryptedMetadata;
      if (encrypted && keys == null) throw const ZxNeedPasswordException();
      final data = zxDecodeBlock(ZxDecodeArg(
          Uint8List.sublistView(raw, pos, end),
          chain,
          encrypted ? keys!.aesKey : null,
          encrypted ? keys!.macKey : null));
      parts.add(data);
      total += data.length;
      pos = end;
    }
    final all = Uint8List(total);
    var o = 0;
    for (final p in parts) {
      all.setRange(o, o + p.length, p);
      o += p.length;
    }
    return ZxIndex.decode(all, multiVolume: header.multiVolume);
  }

  /// The chain of a metadata block: 0 (store) or the Header's record 0x0B.
  static ZxChain metaChainOf(ZxHeader header, int id) {
    if (id == 0) return const ZxChain(0, []);
    final mc = header.metaChain;
    if (mc != null && mc.id == id) return mc;
    zxDamaged('unknown chain $id of a metadata block');
  }

  /// Shows the archive as of generation [sel].
  void selectGeneration(ZxGenerationSelector sel) {
    final gens = generations;
    ZxGeneration? g;
    if (sel.number != null) {
      for (final x in gens) {
        if (x.number == sel.number) g = x;
      }
      if (g == null) {
        throw SevenZipException(
            'zx: there is no generation ${sel.number} '
            '(the archive has ${gens.isEmpty ? 0 : gens.last.number})',
            SevenZipError.unsupported);
      }
    } else {
      final end = zxParseGenerationDate(sel.date!)!;
      for (final x in gens) {
        if (x.time < end) g = x;
      }
      if (g == null) {
        throw SevenZipException(
            'zx: the archive has no generation as of ${sel.date}',
            SevenZipError.unsupported);
      }
    }
    index = indexOf(g);
  }

  /// The Index of generation [g].
  ZxIndex indexOf(ZxGeneration g) {
    if (g.number == lastIndex.generation?.number) return lastIndex;
    final loc = g.index;
    if (loc != null) return readIndex(volumes, header, keys, loc);
    // follow the previous Index records
    var idx = lastIndex;
    while (idx.generation != null && idx.generation!.number > g.number) {
      final p = idx.previous;
      if (p == null) break;
      idx = readIndex(volumes, header, keys, p);
    }
    if (idx.generation?.number != g.number) {
      throw SevenZipException(
          'zx: the Index of generation ${g.number} is not found',
          SevenZipError.headers);
    }
    return idx;
  }

  /// The keys for data blocks; [password] is asked when needed.
  ZxKeys? keysFor(String? Function()? password) {
    if (keys != null) return keys;
    final kdf = header.kdf;
    if (kdf == null) return null;
    final pw = password?.call();
    if (pw == null) throw const ZxNeedPasswordException();
    final k = zxCheckPassword(pw, kdf);
    if (k == null) {
      throw const SevenZipException(
          'zx: wrong password', SevenZipError.wrongPassword);
    }
    return keys = k;
  }

  /// The raw bytes (header and payload) of block [n] of [idx].
  Uint8List rawBlock(ZxIndex idx, int n) {
    if (n < 0 || n >= idx.blocks.length) {
      throw const SevenZipException('zx: bad block number');
    }
    final b = idx.blocks[n];
    if (b.unpackedSize > zxMaxBlockSize) {
      throw const SevenZipException(
          'zx: block too large', SevenZipError.unsupported);
    }
    return volumes.readAt(b.volume, b.offset, b.totalSize);
  }

  /// The chain of block [n] of [idx].
  ZxChain chainOf(ZxIndex idx, int n) {
    final id = idx.blocks[n].chainId;
    if (id == 0) return const ZxChain(0, []);
    final c = idx.chains[id];
    if (c == null) zxDamaged('undeclared chain $id');
    return c;
  }

  /// The decode job argument of block [n] of [idx] (reads it).
  ZxDecodeArg decodeArg(ZxIndex idx, int n) {
    final k = header.kdf != null ? keys : null;
    if (header.kdf != null && k == null) throw const ZxNeedPasswordException();
    return ZxDecodeArg(rawBlock(idx, n), chainOf(idx, n), k?.aesKey, k?.macKey);
  }

  /// Decodes block [n] of [idx] here.
  Uint8List readBlock(ZxIndex idx, int n) => zxDecodeBlock(decodeArg(idx, n));

  /// The Method column of the blocks of [idx] (distinct chains).
  String methodOf(ZxIndex idx, Iterable<int> blocks) {
    final names = <String>{};
    for (final b in blocks) {
      if (b < 0 || b >= idx.blocks.length) continue;
      final id = idx.blocks[b].chainId;
      final c = id == 0 ? const ZxChain(0, []) : idx.chains[id];
      names.add(c == null ? '?' : zxChainName(c));
    }
    return names.join(' ');
  }

  /// The space a compaction to the last generation frees, about: the
  /// blocks no entry uses, and the share of the unused bytes of the blocks
  /// used in part (a compaction repacks them).
  int wastedBytes() {
    // per block: the (start, end) ranges the entries use
    final used = <int, List<int>>{};
    for (final e in lastIndex.entries) {
      final x = e.extents;
      for (var i = 0; i < x.length; i += 3) {
        if (x[i + 2] == 0) continue;
        (used[x[i]] ??= <int>[])
          ..add(x[i + 1])
          ..add(x[i + 1] + x[i + 2]);
      }
    }
    var w = 0.0;
    for (var i = 0; i < lastIndex.blocks.length; i++) {
      final ref = lastIndex.blocks[i];
      final l = used[i];
      if (l == null) {
        w += ref.totalSize;
        continue;
      }
      final n = l.length ~/ 2;
      final order = List<int>.generate(n, (k) => k)
        ..sort((a, b) => l[2 * a] - l[2 * b]);
      var covered = 0, end = 0;
      for (final k in order) {
        var s = l[2 * k];
        final e = l[2 * k + 1];
        if (s < end) s = end;
        if (e > s) {
          covered += e - s;
          end = e;
        }
      }
      if (covered < ref.unpackedSize && ref.unpackedSize > 0) {
        w += ref.totalSize * (ref.unpackedSize - covered) / ref.unpackedSize;
      }
    }
    return w.round();
  }

  void close() => volumes.close();
}

/// The xxHash64 of a whole file (volume table).
int zxFileXxh64(String path) {
  final f = File(path).openSync();
  try {
    final h = Xxh64();
    final buf = Uint8List(1 << 20);
    for (;;) {
      final n = f.readIntoSync(buf);
      if (n <= 0) break;
      h.update(buf, 0, n);
    }
    return h.digest;
  } finally {
    f.closeSync();
  }
}
