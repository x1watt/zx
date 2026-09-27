// UBI images (read only): the raw content of an MTD partition managed by
// UBI, as ubinize writes it or as a flash dump holds it.
//
// Written from the UBI design document (linux-mtd.infradead.org,
// doc/ubi.html) and the on-flash layout facts it describes, checked black
// box against images made by mtd-utils' ubinize. No code was taken from
// the Linux driver or from mtd-utils.
//
// The image is a sequence of physical eraseblocks (PEBs) of one size.
// Each used PEB starts with an erase counter header (big endian):
//
//   0  magic "UBI#"          24  image_seq u32
//   4  version u8 (1)        28  padding (32)
//   8  ec u64                60  hdr_crc u32 over bytes 0..59
//   16 vid_hdr_offset u32
//   20 data_offset u32
//
// and, when it holds data, a volume identifier header at vid_hdr_offset:
//
//   0  magic "UBI!"          20 data_size u32   (static volumes, copies)
//   4  version u8            24 used_ebs u32    (static volumes)
//   5  vol_type u8 (1 dyn,   28 data_pad u32
//      2 static)             32 data_crc u32
//   6  copy_flag u8          40 sqnum u64
//   7  compat u8             60 hdr_crc u32 over bytes 0..59
//   8  vol_id u32
//   12 lnum u32
//
// The data of logical eraseblock (LEB) lnum of volume vol_id starts at
// data_offset. The CRCs are the CRC-32 of zlib without the final
// inversion (register seeded with 0xFFFFFFFF).
//
// The layout volume (vol_id 0x7FFFEFFF, two LEBs holding the same copy)
// is the volume table: records of 172 bytes,
//
//   0 reserved_pebs u32   12 vol_type u8     144 flags u8 (1 autoresize)
//   4 alignment u32       13 upd_marker u8   168 crc u32 over 0..167
//   8 data_pad u32        14 name_len u16
//                         16 name (128)
//
// Several PEBs may claim the same LEB (wear levelling interrupted by a
// power cut): the one with the highest sqnum wins, unless it has
// copy_flag set and its data CRC fails, then the older one is used.
//
// The PEB size is not stored: it is the spacing of the EC headers,
// found by scanning for them at multiples of the smallest power of two
// above data_offset. The image may end inside a PEB (dumps with the
// trailing erased bytes cut): the missing bytes read as 0xFF.
//
// Items are the volumes, named after the volume table ("<name>.ubifs"
// when the volume holds UBIFS, "<name>.bin" otherwise). Their data is a
// random access stream over the LEB map; unmapped LEBs of dynamic
// volumes read as 0xFF.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../item_streams.dart';

const int kUbiEcMagic = 0x55424923; // "UBI#"
const int kUbiVidMagic = 0x55424921; // "UBI!"
const int kUbiLayoutVolId = 0x7FFFEFFF;
const int _kHdrSize = 64;
const int _kVtblRecordSize = 172;
const int _kMaxVolumes = 128;
const int _kUbifsMagic = 0x06101831;

/// The UBI CRC-32: zlib's CRC register seeded with 0xFFFFFFFF, without
/// the final inversion.
int ubiCrc32(Uint8List b, int off, int end) =>
    crc32Update(0xFFFFFFFF, b, off, end) & 0xFFFFFFFF;

/// True when b[off, off + 64) is an EC header with a valid CRC.
bool isUbiEcHeader(Uint8List b, int off) {
  if (b.length - off < _kHdrSize) return false;
  if (getUint32BE(b, off) != kUbiEcMagic) return false;
  return ubiCrc32(b, off, off + 60) == getUint32BE(b, off + 60);
}

/// IsArc_Ubi: the EC header of the first PEB.
int isArcUbi(Uint8List p, int size) {
  if (size < 4) return 2; // need more
  if (getUint32BE(p, 0) != kUbiEcMagic) return 0;
  if (size < _kHdrSize) return 2;
  if (p[4] != 1) return 0;
  return isUbiEcHeader(p, 0) ? 1 : 0;
}

/// A volume of the image.
class UbiVolume {
  final int id;
  String name = '';
  bool inTable = false;
  int volType = 1; // 1 dynamic, 2 static
  int reservedPebs = 0;
  int alignment = 1;
  int dataPad = 0;
  int flags = 0;
  bool updMarker = false;

  /// PEB index of each LEB (-1 unmapped).
  Int32List pebOf = Int32List(0);

  /// Bytes of LEB data (static volumes: data_size; dynamic: LEB size).
  Int32List lebLen = Int32List(0);

  /// data_crc of each LEB (static volumes).
  Uint32List lebCrc = Uint32List(0);
  int usedEbs = 0;
  int size = 0;
  int mappedLebs = 0;
  bool isUbifs = false;
  String path = '';
  UbiVolume(this.id);

  bool get isStatic => volType == 2;
}

// one scanned PEB that holds a LEB
class _Leb {
  final int peb;
  final int volId;
  final int lnum;
  final int volType;
  final int copyFlag;
  final int dataSize;
  final int usedEbs;
  final int dataPad;
  final int dataCrc;
  final int sqnum;
  final int dataOffset;
  _Leb(this.peb, this.volId, this.lnum, this.volType, this.copyFlag,
      this.dataSize, this.usedEbs, this.dataPad, this.dataCrc, this.sqnum,
      this.dataOffset);
}

/// The UBI handler.
class UbiHandler extends ReadOnlyHandler {
  SeekableInStream? _stream;
  int pebSize = 0;
  int vidHdrOffset = 0;
  int dataOffset = 0;
  int imageSeq = 0;
  int numPebs = 0;
  int minIo = 0;
  bool minIoFromUbifs = false;
  int usedPebs = 0;
  int freePebs = 0;
  int badPebs = 0;
  int _length = 0;
  bool _truncated = false;
  bool _vtblMissing = false;
  bool _vtblError = false;
  bool _lebError = false;

  /// Data offset of every PEB (from its own EC header when valid).
  Int32List _pebDataOff = Int32List(0);
  final List<UbiVolume> volumes = [];

  int get lebSize => pebSize - dataOffset;

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.size,
    Kpid.packSize,
    Kpid.id,
    Kpid.type,
    Kpid.comment,
  ];

  static const List<int> _arcProps = [
    Kpid.clusterSize,
    Kpid.numVolumes,
    Kpid.comment,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  // finds the PEB size: the gcd of the positions of the first EC headers
  int _findPebSize(SeekableInStream s, int len) {
    var step = 1;
    while (step <= dataOffset) {
      step <<= 1;
    }
    if (step < 512) step = 512;
    const maxPeb = 1 << 24;
    var g = 0;
    var found = 0;
    final h = Uint8List(_kHdrSize);
    for (var pos = step; pos + _kHdrSize <= len; pos += step) {
      s.position = pos;
      if (readFully(s, h, 0, _kHdrSize) != _kHdrSize) break;
      if (isUbiEcHeader(h, 0)) {
        g = g == 0 ? pos : _gcd(g, pos);
        if (++found >= 4) break;
      }
      if (g == 0 && pos >= 2 * maxPeb) break;
      if (g != 0 && pos >= g * 8) break;
    }
    if (g == 0) {
      // one PEB: the smallest power of two that holds the whole image
      var p = step;
      while (p < len && p < maxPeb) {
        p <<= 1;
      }
      return p;
    }
    return g;
  }

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return a;
  }

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final len = stream.length;
    final h0 = readAt(stream, 0, _kHdrSize);
    if (h0.length < _kHdrSize || !isUbiEcHeader(h0, 0) || h0[4] != 1) {
      return false;
    }
    vidHdrOffset = getUint32BE(h0, 16);
    dataOffset = getUint32BE(h0, 20);
    imageSeq = getUint32BE(h0, 24);
    if (vidHdrOffset < _kHdrSize ||
        dataOffset < vidHdrOffset + _kHdrSize ||
        dataOffset > (1 << 22)) {
      return false;
    }
    _length = len;
    pebSize = _findPebSize(stream, len);
    if (pebSize <= dataOffset) return false;
    numPebs = (len + pebSize - 1) ~/ pebSize;
    if (len % pebSize != 0) _truncated = true;
    _pebDataOff = Int32List(numPebs);

    // scan the PEBs
    final lebs = <_Leb>[];
    final ec = Uint8List(_kHdrSize);
    final vid = Uint8List(_kHdrSize);
    for (var i = 0; i < numPebs; i++) {
      final base = i * pebSize;
      stream.position = base;
      final n = readFully(stream, ec, 0, _kHdrSize);
      var vidOff = vidHdrOffset;
      var dOff = dataOffset;
      _pebDataOff[i] = dOff;
      if (n == _kHdrSize && isUbiEcHeader(ec, 0)) {
        final v = getUint32BE(ec, 16);
        final d = getUint32BE(ec, 20);
        if (v >= _kHdrSize && d >= v + _kHdrSize && d < pebSize) {
          vidOff = v;
          dOff = d;
          _pebDataOff[i] = d;
        }
      } else if (n == _kHdrSize && getUint32BE(ec, 0) != kUbiEcMagic) {
        if (_allFF(ec, n)) {
          freePebs++;
        } else {
          badPebs++;
        }
        continue;
      }
      stream.position = base + vidOff;
      final m = readFully(stream, vid, 0, _kHdrSize);
      if (m != _kHdrSize ||
          getUint32BE(vid, 0) != kUbiVidMagic ||
          ubiCrc32(vid, 0, 60) != getUint32BE(vid, 60)) {
        freePebs++;
        continue;
      }
      usedPebs++;
      lebs.add(_Leb(
          i,
          getUint32BE(vid, 8),
          getUint32BE(vid, 12),
          vid[5],
          vid[6],
          getUint32BE(vid, 20),
          getUint32BE(vid, 24),
          getUint32BE(vid, 28),
          getUint32BE(vid, 32),
          getUint64BE(vid, 40),
          dOff));
    }
    _stream = stream;

    // group by volume and LEB, newest copy first
    final byVol = <int, Map<int, List<_Leb>>>{};
    for (final l in lebs) {
      ((byVol[l.volId] ??= {})[l.lnum] ??= []).add(l);
    }
    final best = <int, Map<int, _Leb>>{};
    for (final e in byVol.entries) {
      final m = best[e.key] = <int, _Leb>{};
      for (final c in e.value.entries) {
        final list = c.value;
        list.sort((a, b) => b.sqnum.compareTo(a.sqnum));
        var pick = list.first;
        if (list.length > 1) {
          for (final l in list) {
            if (l.copyFlag == 0 || _dataCrcOk(l)) {
              pick = l;
              break;
            }
          }
        }
        m[c.key] = pick;
      }
    }

    // the volume table
    final vols = <int, UbiVolume>{};
    final layout = best[kUbiLayoutVolId];
    if (layout == null) {
      _vtblMissing = true;
    } else {
      var ok = false;
      for (final lnum in const [0, 1]) {
        final l = layout[lnum];
        if (l == null) continue;
        if (_readVtbl(l, vols)) {
          ok = true;
          break;
        }
        vols.clear();
      }
      if (!ok) _vtblError = true;
    }

    // volumes seen in the VID headers
    for (final e in best.entries) {
      if (e.key == kUbiLayoutVolId) continue;
      final v = vols[e.key] ??= UbiVolume(e.key);
      if (!v.inTable) {
        v.name = 'volume_${e.key}';
        final any = e.value.values.first;
        v.volType = any.volType;
        v.dataPad = any.dataPad;
      }
    }
    final ids = vols.keys.toList()..sort();
    final used = <String>{};
    for (final id in ids) {
      final v = vols[id]!;
      _buildVolume(v, best[id] ?? const {});
      var base = _safeName(v.name);
      if (base.isEmpty) base = 'volume_$id';
      var path = '$base.${v.isUbifs ? 'ubifs' : 'bin'}';
      if (!used.add(path)) {
        path = '${base}_$id.${v.isUbifs ? 'ubifs' : 'bin'}';
        used.add(path);
      }
      v.path = path;
      volumes.add(v);
    }
    _findMinIo();
    return true;
  }

  static bool _allFF(Uint8List b, int n) {
    for (var i = 0; i < n; i++) {
      if (b[i] != 0xFF) return false;
    }
    return true;
  }

  static String _safeName(String s) {
    final sb = StringBuffer();
    for (final c in s.runes) {
      sb.writeCharCode(c == 0x2F || c == 0x5C || c < 0x20 ? 0x5F : c);
    }
    var r = sb.toString();
    if (r == '.' || r == '..') r = '_';
    return r;
  }

  // reads the data of LEB [l] (up to [n] bytes; missing bytes read 0xFF)
  Uint8List _readLeb(_Leb l, int n) {
    final s = _stream!;
    final b = Uint8List(n);
    final pos = l.peb * pebSize + l.dataOffset;
    s.position = pos;
    final got = readFully(s, b, 0, n);
    if (got < n) b.fillRange(got, n, 0xFF);
    return b;
  }

  bool _dataCrcOk(_Leb l) {
    final lim = pebSize - l.dataOffset;
    if (l.dataSize > lim) return false;
    final b = _readLeb(l, l.dataSize);
    return ubiCrc32(b, 0, b.length) == l.dataCrc;
  }

  bool _readVtbl(_Leb l, Map<int, UbiVolume> vols) {
    var count = (pebSize - l.dataOffset) ~/ _kVtblRecordSize;
    if (count > _kMaxVolumes) count = _kMaxVolumes;
    final b = _readLeb(l, count * _kVtblRecordSize);
    for (var i = 0; i < count; i++) {
      final o = i * _kVtblRecordSize;
      if (ubiCrc32(b, o, o + 168) != getUint32BE(b, o + 168)) return false;
      final reserved = getUint32BE(b, o);
      if (reserved == 0) continue;
      final v = UbiVolume(i)
        ..inTable = true
        ..reservedPebs = reserved
        ..alignment = getUint32BE(b, o + 4)
        ..dataPad = getUint32BE(b, o + 8)
        ..volType = b[o + 12]
        ..updMarker = b[o + 13] != 0
        ..flags = b[o + 144];
      var nl = getUint16BE(b, o + 14);
      if (nl > 127) nl = 127;
      v.name = cString(b, o + 16, nl);
      vols[i] = v;
    }
    return true;
  }

  void _buildVolume(UbiVolume v, Map<int, _Leb> m) {
    final usable = lebSize - v.dataPad;
    var maxL = -1;
    var usedEbs = 0;
    for (final l in m.values) {
      if (l.lnum > maxL && l.lnum < (1 << 24)) maxL = l.lnum;
      if (l.volType == 2 && l.usedEbs > usedEbs) usedEbs = l.usedEbs;
    }
    var n = maxL + 1;
    if (v.isStatic && usedEbs > 0) n = usedEbs;
    v.usedEbs = usedEbs;
    v.pebOf = Int32List(n)..fillRange(0, n, -1);
    v.lebLen = Int32List(n);
    v.lebCrc = Uint32List(n);
    var size = 0;
    for (var i = 0; i < n; i++) {
      final l = m[i];
      var ln = usable;
      if (l != null) {
        v.pebOf[i] = l.peb;
        v.mappedLebs++;
        if (v.isStatic) {
          ln = l.dataSize;
          if (ln > usable) {
            ln = usable;
            _lebError = true;
          }
          v.lebCrc[i] = l.dataCrc;
        }
      } else if (v.isStatic) {
        _lebError = true;
      }
      v.lebLen[i] = ln;
      size += ln;
    }
    v.size = size;
    if (n > 0 && v.pebOf[0] >= 0) {
      final b = _readLeb(m[0]!, 4);
      v.isUbifs = b.length == 4 &&
          (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) == _kUbifsMagic;
    }
  }

  // min I/O: the superblock of the first UBIFS volume, else an estimate
  void _findMinIo() {
    for (final v in volumes) {
      if (!v.isUbifs) continue;
      final s = UbiVolumeStream(this, v);
      final b = Uint8List(40);
      if (readFully(s, b, 0, 40) == 40 && b[20] == 6) {
        final m = getUint32LE(b, 32);
        if (m > 0 && m <= dataOffset) {
          minIo = m;
          minIoFromUbifs = true;
          return;
        }
      }
    }
    var p = 1;
    while (p * 2 <= vidHdrOffset) {
      p *= 2;
    }
    minIo = ((vidHdrOffset + _kHdrSize + p - 1) ~/ p) * p == dataOffset
        ? p
        : dataOffset;
  }

  @override
  void close() {
    _stream = null;
    volumes.clear();
    pebSize = 0;
    numPebs = usedPebs = freePebs = badPebs = 0;
    _truncated = false;
    _vtblMissing = false;
    _vtblError = false;
    _lebError = false;
    minIoFromUbifs = false;
  }

  @override
  int get numberOfItems => volumes.length;

  String _volComment(UbiVolume v) {
    final sb = StringBuffer('vol_id ${v.id}, ')
      ..write(v.isStatic ? 'static' : 'dynamic')
      ..write(', name "${v.name}"');
    if (v.inTable) {
      sb.write(', reserved PEBs ${v.reservedPebs}');
      if (v.alignment > 1) sb.write(', alignment ${v.alignment}');
      if (v.dataPad != 0) sb.write(', data pad ${v.dataPad}');
      if ((v.flags & 1) != 0) sb.write(', autoresize');
      if (v.updMarker) sb.write(', update marker set');
    } else {
      sb.write(', not in the volume table');
    }
    sb.write(', mapped LEBs ${v.mappedLebs}');
    if (v.isStatic) sb.write(', used_ebs ${v.usedEbs}');
    return sb.toString();
  }

  @override
  Object? getProperty(int index, int propId) {
    if (index < 0 || index >= volumes.length) return null;
    final v = volumes[index];
    switch (propId) {
      case Kpid.path:
        return v.path;
      case Kpid.isDir:
        return false;
      case Kpid.size:
        return v.size;
      case Kpid.packSize:
        return v.mappedLebs * pebSize;
      case Kpid.id:
        return v.id;
      case Kpid.type:
        return v.isStatic ? 'static' : 'dynamic';
      case Kpid.comment:
        return _volComment(v);
    }
    return null;
  }

  String _archiveComment() {
    final sb = StringBuffer()
      ..write('PEB size $pebSize, LEB size $lebSize, ')
      ..write('min I/O $minIo${minIoFromUbifs ? '' : ' (estimated)'}\n')
      ..write('VID header offset $vidHdrOffset, data offset $dataOffset, ')
      ..write('image seq 0x${imageSeq.toRadixString(16).padLeft(8, '0')}\n')
      ..write('PEBs $numPebs: used $usedPebs, free $freePebs, bad $badPebs\n');
    for (final v in volumes) {
      sb.write('volume ${v.id} "${v.name}": '
          '${v.isStatic ? 'static' : 'dynamic'}\n');
    }
    return sb.toString();
  }

  String? _warning() {
    final w = <String>[];
    if (_truncated) w.add('The image ends inside a PEB');
    if (_vtblMissing) w.add('No volume table');
    if (_vtblError) w.add('Volume table CRC error');
    if (_lebError) w.add('Static volume with missing or bad LEBs');
    return w.isEmpty ? null : w.join('; ');
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.phySize:
        return _length;
      case Kpid.clusterSize:
        return pebSize;
      case Kpid.numVolumes:
        return volumes.length;
      case Kpid.comment:
        return _archiveComment();
      case Kpid.warningFlags:
        return _warning() == null ? null : ErrorFlags.headersError;
      case Kpid.warning:
        return _warning();
    }
    return null;
  }

  _CrcCheckStream? _lastCheck;

  InStream _openForExtract(int index) {
    final v = volumes[index];
    final s = UbiVolumeStream(this, v);
    if (!v.isStatic) {
      _lastCheck = null;
      return s;
    }
    final c = _CrcCheckStream(s, v);
    _lastCheck = c;
    return c;
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(volumes.length, indices, testMode, cb, (_) => false,
        (i) => volumes[i].size, _openForExtract,
        expectedSize: (i) => volumes[i].size, verify: (i) {
      final c = _lastCheck;
      if (c == null) return OperationResult.ok;
      return c.ok ? OperationResult.ok : OperationResult.crcError;
    });
  }

  @override
  SeekableInStream? getStream(int index) {
    if (_stream == null || index < 0 || index >= volumes.length) return null;
    return UbiVolumeStream(this, volumes[index]);
  }
}

/// Random access to the data of a UBI volume, read from the PEBs that
/// hold its LEBs (nothing is copied).
class UbiVolumeStream implements SeekableInStream {
  final SeekableInStream _base;
  final int _pebSize;
  final int _leb; // usable LEB size
  final Int32List _pebOf;
  final Int32List _lebLen;
  final Int32List _dataOff;
  final int _size;
  int _pos = 0;

  UbiVolumeStream(UbiHandler h, UbiVolume v)
      : _base = h._stream!,
        _pebSize = h.pebSize,
        _leb = h.lebSize - v.dataPad,
        _pebOf = v.pebOf,
        _lebLen = v.lebLen,
        _dataOff = h._pebDataOff,
        _size = v.size;

  @override
  int read(Uint8List buf, int off, int len) {
    final left = _size - _pos;
    if (left <= 0 || len <= 0) return 0;
    if (len > left) len = left;
    final lnum = _pos ~/ _leb;
    final o = _pos - lnum * _leb;
    var n = _lebLen[lnum] - o;
    if (n <= 0) {
      // a short static LEB before the last one: nothing more to read
      return 0;
    }
    if (n > len) n = len;
    final peb = _pebOf[lnum];
    if (peb < 0) {
      buf.fillRange(off, off + n, 0xFF);
    } else {
      _base.position = peb * _pebSize + _dataOff[peb] + o;
      final got = readFully(_base, buf, off, n);
      if (got < n) buf.fillRange(off + got, off + n, 0xFF);
    }
    _pos += n;
    return n;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => _size;
}

/// Checks the data_crc of each LEB of a static volume read in order.
class _CrcCheckStream implements InStream {
  final InStream _s;
  final UbiVolume _v;
  int _lnum = 0;
  int _inLeb = 0;
  int _crc = 0xFFFFFFFF;
  bool ok = true;
  _CrcCheckStream(this._s, this._v);

  @override
  int read(Uint8List buf, int off, int len) {
    final n = _s.read(buf, off, len);
    var p = off;
    final end = off + n;
    final lens = _v.lebLen;
    while (p < end && _lnum < lens.length) {
      var k = lens[_lnum] - _inLeb;
      if (k > end - p) k = end - p;
      _crc = crc32Update(_crc, buf, p, p + k);
      p += k;
      _inLeb += k;
      if (_inLeb == lens[_lnum]) {
        if (_v.pebOf[_lnum] < 0 ||
            (_crc & 0xFFFFFFFF) != _v.lebCrc[_lnum]) {
          ok = false;
        }
        _lnum++;
        _inLeb = 0;
        _crc = 0xFFFFFFFF;
      }
    }
    return n;
  }
}
