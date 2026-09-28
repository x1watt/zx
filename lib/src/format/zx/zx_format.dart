// The structures of the .zx format (docs/zx-format.md): integers and
// records, the Header with its compatibility check, block headers, coder
// chains, entries, the Index, the Footer and the volume trailer. Encoding
// and decoding only; reading and writing files is in zx_reader.dart and
// zx_writer.dart.

import 'dart:convert';
import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc32c.dart';
import '../../util/xxhash.dart';
import '../../version.dart';

/// The magic bytes at the start of every .zx file (and volume).
final Uint8List zxMagic =
    Uint8List.fromList(const [0x89, 0x5A, 0x58, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]);

/// The format_version this implementation reads and writes.
const int zxFormatVersion = 1;

/// Size of the fixed part of the Header.
const int zxHeaderFixedSize = 64;

/// Size of the Footer and of the volume trailer.
const int zxFooterSize = 32;

/// "ZXB" 0x01, the marker of a block header.
const int zxBlockMarker = 0x01425A58; // little endian of 5A 58 42 01

/// "ZXE" 0x1A, the magic at the end of a Footer.
const int zxFooterMagic = 0x1A455A58;

/// "ZXV" 0x1A, the magic at the end of a volume trailer.
const int zxTrailerMagic = 0x1A565A58;

/// The largest unpacked block a reader accepts (2^40).
const int zxMaxBlockSize = 1 << 40;

/// A zx version (major, minor, patch).
typedef ZxVer = (int, int, int);

int zxCompareVersions(ZxVer a, ZxVer b) {
  if (a.$1 != b.$1) return a.$1 - b.$1;
  if (a.$2 != b.$2) return a.$2 - b.$2;
  return a.$3 - b.$3;
}

String zxVersionText(ZxVer v) => '${v.$1}.${v.$2}.${v.$3}';

/// header_flags.
abstract final class ZxHeaderFlag {
  static const streamed = 1;
  static const encryptedMetadata = 2;
  static const multiVolume = 4;
}

/// required_features bits.
abstract final class ZxFeature {
  static const solid = 1 << 0;
  static const encryption = 1 << 1;
  static const dedup = 1 << 2;
  static const appendable = 1 << 3;
  static const multiVolume = 1 << 4;

  /// A database (zxdb) lives in the archive: Index record 0x49 and
  /// database page blocks (type 7), section 16.
  static const database = 1 << 5;

  /// The required features this reader implements.
  static const known =
      solid | encryption | dedup | appendable | multiVolume | database;

  static const names = {
    0: 'solid',
    1: 'encryption',
    2: 'dedup',
    3: 'appendable',
    4: 'multi_volume',
    5: 'database',
  };
}

/// optional_features bits.
abstract final class ZxOptFeature {
  static const hashTable = 1 << 0;
  static const similarity = 1 << 1;
  static const recovery = 1 << 2;
}

/// block_type values.
abstract final class ZxBlockType {
  static const data = 0;
  static const solid = 1;
  static const meta = 2;
  static const chunks = 3;
  static const padding = 4;
  static const index = 5;

  /// A chunk run of the dedup writer (section 6.4.1): not a data block,
  /// not in the block table; readers skip it.
  static const chunkRun = 6;

  /// Database pages (section 16): not a data block, not in the block
  /// table; located through the page map of Index record 0x49.
  static const dbPages = 7;
}

/// check_type values.
abstract final class ZxCheck {
  static const none = 0;
  static const crc32c = 1;
  static const xxh64 = 2;
  static const sha256 = 3;
  static const blake2sp = 4;

  static int size(int type) => switch (type) {
        none => 0,
        crc32c => 4,
        xxh64 => 8,
        sha256 || blake2sp => 32,
        _ => -1,
      };

  static String name(int type) => switch (type) {
        none => 'none',
        crc32c => 'CRC32C',
        xxh64 => 'XXH64',
        sha256 => 'SHA256',
        blake2sp => 'BLAKE2sp',
        _ => '$type',
      };
}

/// Record types (the critical flag is bit 0).
abstract final class ZxRec {
  // header records
  static const writerName = 0x02;
  static const creationTime = 0x04;
  static const kdf = 0x05;
  static const volume = 0x07;
  static const comment = 0x08;
  static const metaChain = 0x0B;

  // Index records
  static const chain = 0x10;
  static const blockTable = 0x12;
  static const entry = 0x21;
  static const shaTable = 0x30;
  static const tlshList = 0x32;
  static const chunkTable = 0x34;
  static const chunkRuns = 0x36;
  static const prevIndex = 0x40;
  static const generation = 0x42;
  static const generationList = 0x44;
  static const volumeTable = 0x45;
  static const requirements = 0x46;
  static const database = 0x49;
  static const indexBase = 0x4B;

  // entry attributes
  static const path = 0x51;
  static const kind = 0x53;
  static const size = 0x55;
  static const extents = 0x57;
  static const linkTarget = 0x59;
  static const device = 0x5B;
  static const mode = 0x5C;
  static const owner = 0x5E;
  static const winAttrib = 0x60;
  static const mTime = 0x62;
  static const aTime = 0x64;
  static const cTime = 0x66;
  static const birthTime = 0x68;
  static const sha256 = 0x6A;
  static const tlsh = 0x6C;
  static const xattr = 0x6E;
  static const entryComment = 0x70;
  static const sparse = 0x72;
  static const nestedHint = 0x74;
  static const since = 0x76;
}

/// Entry kinds (attribute 0x53).
abstract final class ZxKind {
  static const file = 0;
  static const directory = 1;
  static const symlink = 2;
  static const hardlink = 3;
  static const charDevice = 4;
  static const blockDevice = 5;
  static const fifo = 6;
  static const socket = 7;
}

Never zxDamaged(String what) =>
    throw SevenZipException('zx: $what', SevenZipError.headers);

// ---------------------------------------------------------------------------
// Byte writer and reader

/// A growable little endian byte writer.
class ZxBytes {
  Uint8List _b;
  int _n = 0;
  ZxBytes([int capacity = 256]) : _b = Uint8List(capacity);

  int get length => _n;

  void _need(int k) {
    if (_n + k <= _b.length) return;
    var c = _b.length * 2;
    if (c < _n + k) c = _n + k;
    final nb = Uint8List(c);
    nb.setRange(0, _n, _b);
    _b = nb;
  }

  void u8(int v) {
    _need(1);
    _b[_n++] = v & 0xFF;
  }

  void u16(int v) {
    _need(2);
    _b[_n++] = v & 0xFF;
    _b[_n++] = (v >> 8) & 0xFF;
  }

  void u32(int v) {
    _need(4);
    setUint32LE(_b, _n, v);
    _n += 4;
  }

  void u64(int v) {
    _need(8);
    setUint64LE(_b, _n, v);
    _n += 8;
  }

  /// Unsigned LEB128 of the 64 bit pattern of [v] (shortest form).
  void vint(int v) {
    _need(10);
    var x = v;
    for (;;) {
      final low = x & 0x7F;
      x = x >>> 7;
      if (x == 0) {
        _b[_n++] = low;
        return;
      }
      _b[_n++] = low | 0x80;
    }
  }

  /// A signed value, zigzag encoded.
  void svint(int v) => vint((v << 1) ^ (v >> 63));

  void bytes(Uint8List b, [int off = 0, int? end]) {
    final e = end ?? b.length;
    _need(e - off);
    _b.setRange(_n, _n + e - off, b, off);
    _n += e - off;
  }

  void string(String s) {
    final b = utf8.encode(s);
    vint(b.length);
    bytes(b);
  }

  void version(ZxVer v) {
    u16(v.$1);
    u16(v.$2);
    u16(v.$3);
  }

  /// A record: type, length, payload.
  void record(int type, Uint8List payload) {
    vint(type);
    vint(payload.length);
    bytes(payload);
  }

  /// A record whose payload is built by [build].
  void rec(int type, void Function(ZxBytes w) build) {
    final w = ZxBytes(64);
    build(w);
    vint(type);
    vint(w.length);
    bytes(w._b, 0, w._n);
  }

  /// A copy of the bytes written.
  Uint8List toBytes() => Uint8List.fromList(Uint8List.sublistView(_b, 0, _n));

  /// A view of the bytes written (valid until the next write).
  Uint8List view() => Uint8List.sublistView(_b, 0, _n);
}

/// Encodes [v] as a vint on its own.
Uint8List zxVint(int v) => (ZxBytes(10)..vint(v)).toBytes();

/// A bounds checked reader over bytes. Errors are damaged headers.
class ZxRead {
  final Uint8List b;
  int pos;
  final int end;
  ZxRead(this.b, [this.pos = 0, int? end]) : end = end ?? b.length;

  int get remaining => end - pos;
  bool get atEnd => pos >= end;

  void _need(int k) {
    if (k < 0 || pos + k > end) zxDamaged('truncated structure');
  }

  int u8() {
    _need(1);
    return b[pos++];
  }

  int u16() {
    _need(2);
    final v = b[pos] | (b[pos + 1] << 8);
    pos += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v = getUint32LE(b, pos);
    pos += 4;
    return v;
  }

  int u64() {
    _need(8);
    final v = getUint64LE(b, pos);
    pos += 8;
    return v;
  }

  /// A vint as a 64 bit pattern: at most 10 bytes, the 10th with one bit.
  int vintBits() {
    var v = 0;
    var shift = 0;
    for (var i = 0; i < 10; i++) {
      if (pos >= end) zxDamaged('truncated number');
      final c = b[pos++];
      if (i == 9 && c > 1) zxDamaged('number larger than 64 bits');
      v |= (c & 0x7F) << shift;
      if ((c & 0x80) == 0) return v;
      shift += 7;
    }
    zxDamaged('number longer than 10 bytes');
  }

  /// An unsigned vint that fits in a non negative Dart int (below 2^63).
  int vint() {
    final v = vintBits();
    if (v < 0) zxDamaged('number too large');
    return v;
  }

  /// A zigzag encoded signed vint.
  int svint() {
    final v = vintBits();
    return (v >>> 1) ^ -(v & 1);
  }

  /// A count of items each at least [minItemSize] bytes long.
  int count([int minItemSize = 1]) {
    final n = vint();
    if (n > remaining ~/ (minItemSize < 1 ? 1 : minItemSize)) {
      zxDamaged('count larger than the data');
    }
    return n;
  }

  Uint8List bytes(int n) {
    _need(n);
    final v = Uint8List.sublistView(b, pos, pos + n);
    pos += n;
    return v;
  }

  String string() {
    final n = vint();
    _need(n);
    try {
      final s = utf8.decode(Uint8List.sublistView(b, pos, pos + n));
      pos += n;
      return s;
    } on FormatException {
      zxDamaged('invalid UTF-8');
    }
  }

  ZxVer version() => (u16(), u16(), u16());
}

/// One record: its type and payload.
class ZxRecord {
  final int type;
  final Uint8List payload;
  const ZxRecord(this.type, this.payload);

  bool get critical => (type & 1) != 0;

  String get hexType => '0x${type.toRadixString(16).toUpperCase()}';
}

/// Iterates the records of b[off, end).
Iterable<ZxRecord> zxRecords(Uint8List b, [int off = 0, int? end]) sync* {
  final r = ZxRead(b, off, end);
  while (!r.atEnd) {
    final type = r.vint();
    final len = r.vint();
    yield ZxRecord(type, r.bytes(len));
  }
}

// ---------------------------------------------------------------------------
// Coder chains

/// One coder of a chain: codec id and properties.
class ZxCoder {
  final int codecId;
  final Uint8List props;
  const ZxCoder(this.codecId, this.props);

  bool sameAs(ZxCoder o) {
    if (codecId != o.codecId || props.length != o.props.length) return false;
    for (var i = 0; i < props.length; i++) {
      if (props[i] != o.props[i]) return false;
    }
    return true;
  }
}

/// A coder chain (section 4.2): coders in writing order.
class ZxChain {
  final int id;
  final List<ZxCoder> coders;
  const ZxChain(this.id, this.coders);

  bool sameCoders(List<ZxCoder> o) {
    if (o.length != coders.length) return false;
    for (var i = 0; i < o.length; i++) {
      if (!coders[i].sameAs(o[i])) return false;
    }
    return true;
  }

  void write(ZxBytes w) {
    w.vint(id);
    w.vint(coders.length);
    for (final c in coders) {
      w.vint(c.codecId);
      w.vint(c.props.length);
      w.bytes(c.props);
    }
  }

  static ZxChain read(ZxRead r) {
    final id = r.vint();
    final n = r.count(2);
    final coders = <ZxCoder>[];
    for (var i = 0; i < n; i++) {
      final codec = r.vint();
      final ps = r.vint();
      coders.add(ZxCoder(codec, Uint8List.fromList(r.bytes(ps))));
    }
    return ZxChain(id, coders);
  }
}

// ---------------------------------------------------------------------------
// Header

/// KDF and cipher parameters (header record 0x05, section 7).
class ZxKdfParams {
  /// 1: scrypt.
  final int kdfId;
  final int log2N;
  final int r;
  final int p;
  final Uint8List salt;

  /// 1: AES-256-CTR with HMAC-SHA-256.
  final int cipherId;
  final Uint8List passwordCheck;

  /// The KDF params bytes of an unknown kdf (kept as they are).
  final Uint8List? rawParams;

  const ZxKdfParams(this.kdfId, this.log2N, this.r, this.p, this.salt,
      this.cipherId, this.passwordCheck,
      [this.rawParams]);

  Uint8List encode() {
    final w = ZxBytes(96);
    w.vint(kdfId);
    final pw = ZxBytes(48);
    if (kdfId == 1) {
      pw.vint(log2N);
      pw.vint(r);
      pw.vint(p);
      pw.bytes(salt);
    } else if (rawParams != null) {
      pw.bytes(rawParams!);
    }
    w.vint(pw.length);
    w.bytes(pw.view());
    w.vint(cipherId);
    w.bytes(passwordCheck);
    return w.toBytes();
  }

  static ZxKdfParams decode(Uint8List b) {
    final r = ZxRead(b);
    final kdf = r.vint();
    final ps = r.vint();
    final params = r.bytes(ps);
    final cipher = r.vint();
    final check = Uint8List.fromList(r.bytes(16));
    if (kdf == 1) {
      final pr = ZxRead(params);
      final n = pr.vint(), rr = pr.vint(), p = pr.vint();
      final salt = Uint8List.fromList(pr.bytes(32));
      return ZxKdfParams(1, n, rr, p, salt, cipher, check);
    }
    return ZxKdfParams(
        kdf, 0, 0, 0, Uint8List(0), cipher, check, Uint8List.fromList(params));
  }
}

/// The Header (section 3).
class ZxHeader {
  int formatVersion = zxFormatVersion;
  ZxVer minReaderVersion = zxVersion;
  ZxVer writerVersion = zxVersion;
  int flags = 0;
  int required = 0;
  int optional = 0;
  Uint8List archiveId = Uint8List(16);

  String? writerName;

  /// Nanoseconds since 1970-01-01 UTC.
  int? creationTime;
  ZxKdfParams? kdf;
  int? volumeNumber;
  int? volumeCount;
  String? comment;

  /// The chain of the metadata blocks (record 0x0B), besides chain 0.
  ZxChain? metaChain;

  /// Non-critical records this writer does not know (kept for copies).
  final List<ZxRecord> otherRecords = [];

  /// The size of the Header in the file (fixed part and records).
  int size = zxHeaderFixedSize;

  bool get streamed => (flags & ZxHeaderFlag.streamed) != 0;
  bool get encryptedMetadata => (flags & ZxHeaderFlag.encryptedMetadata) != 0;
  bool get multiVolume => (flags & ZxHeaderFlag.multiVolume) != 0;

  Uint8List encode() {
    final rec = ZxBytes(128);
    final wn = writerName;
    if (wn != null) rec.rec(ZxRec.writerName, (w) => w.string(wn));
    final ct = creationTime;
    if (ct != null) rec.rec(ZxRec.creationTime, (w) => w.vint(ct));
    final k = kdf;
    if (k != null) rec.record(ZxRec.kdf, k.encode());
    final vn = volumeNumber;
    if (vn != null) {
      rec.rec(ZxRec.volume, (w) {
        w.vint(vn);
        w.vint(volumeCount ?? 0);
      });
    }
    final c = comment;
    if (c != null) rec.rec(ZxRec.comment, (w) => w.string(c));
    final mc = metaChain;
    if (mc != null) rec.rec(ZxRec.metaChain, mc.write);
    for (final o in otherRecords) {
      rec.record(o.type, o.payload);
    }
    final w = ZxBytes(zxHeaderFixedSize + rec.length);
    w.bytes(zxMagic);
    w.u16(formatVersion);
    w.version(minReaderVersion);
    w.version(writerVersion);
    w.u16(flags);
    w.u64(required);
    w.u64(optional);
    w.bytes(archiveId);
    w.u32(rec.length);
    final crc = Crc32c();
    crc.update(w.view());
    crc.update(rec.view());
    w.u32(crc.value);
    w.bytes(rec.view());
    final out = w.toBytes();
    size = out.length;
    return out;
  }

  /// True when [b] starts with the magic.
  static bool hasMagic(Uint8List b, [int off = 0]) {
    if (b.length - off < 8) return false;
    for (var i = 0; i < 8; i++) {
      if (b[off + i] != zxMagic[i]) return false;
    }
    return true;
  }

  /// Parses the fixed part [fixed] (64 bytes) and the records that
  /// follow ([records], records_size bytes), with the checks of section
  /// 3.1 steps 2 to 5 (the magic is checked by the caller).
  static ZxHeader decode(Uint8List fixed, Uint8List records) {
    final r = ZxRead(fixed, 0, zxHeaderFixedSize);
    r.pos = 8;
    final h = ZxHeader();
    h.formatVersion = r.u16();
    h.minReaderVersion = r.version();
    h.writerVersion = r.version();
    h.flags = r.u16();
    h.required = r.u64();
    h.optional = r.u64();
    h.archiveId = Uint8List.fromList(r.bytes(16));
    final recSize = r.u32();
    final storedCrc = r.u32();
    if (recSize != records.length) zxDamaged('bad header size');
    final crc = Crc32c();
    crc.update(fixed, 0, 60);
    crc.update(records);
    if (crc.value != storedCrc) {
      throw const SevenZipException(
          'zx: the header is damaged (CRC mismatch)', SevenZipError.headers);
    }
    zxCheckCompat(h.formatVersion, h.minReaderVersion, h.required);
    h.size = zxHeaderFixedSize + recSize;
    for (final rec in zxRecords(records)) {
      final pr = ZxRead(rec.payload);
      switch (rec.type) {
        case ZxRec.writerName:
          h.writerName = pr.string();
        case ZxRec.creationTime:
          h.creationTime = pr.vint();
        case ZxRec.kdf:
          h.kdf = ZxKdfParams.decode(rec.payload);
        case ZxRec.volume:
          h.volumeNumber = pr.vint();
          final c = pr.vint();
          h.volumeCount = c == 0 ? null : c;
        case ZxRec.comment:
          h.comment = pr.string();
        case ZxRec.metaChain:
          h.metaChain = ZxChain.read(pr);
        default:
          if (rec.critical) {
            throw SevenZipException(
                'zx: unsupported critical header record ${rec.hexType} '
                '(written by a newer zx?)',
                SevenZipError.unsupported);
          }
          h.otherRecords.add(rec);
      }
    }
    return h;
  }
}

/// The compatibility check of section 3.1 (steps 3 to 5), also run on the
/// requirements of each generation (Index record 0x46).
void zxCheckCompat(int formatVersion, ZxVer minReader, int required) {
  if (formatVersion > zxFormatVersion) {
    throw SevenZipException(
        'zx: format version $formatVersion is newer than this zx supports '
        '(up to $zxFormatVersion); upgrade zx',
        SevenZipError.unsupported);
  }
  if (zxCompareVersions(minReader, zxVersion) > 0) {
    throw SevenZipException(
        'zx: this archive needs zx ${zxVersionText(minReader)} or later '
        '(this is zx $zxVersionString)',
        SevenZipError.unsupported);
  }
  final unknown = required & ~ZxFeature.known;
  if (unknown != 0) {
    final bits = [
      for (var i = 0; i < 64; i++)
        if ((unknown >>> i) & 1 != 0) i
    ];
    throw SevenZipException(
        'zx: this archive needs features this zx does not have '
        '(required feature bit${bits.length > 1 ? 's' : ''} '
        '${bits.join(', ')}); upgrade zx',
        SevenZipError.unsupported);
  }
}

// ---------------------------------------------------------------------------
// Blocks

/// A parsed block header.
class ZxBlockHeader {
  final int type;
  final int chainId;
  final int unpackedSize;
  final int packedSize;
  final int checkType;
  final Uint8List check;

  /// Bytes of the whole header (marker to CRC).
  final int headerSize;

  /// The header bytes before the CRC (marker to check), which the MAC of
  /// an encrypted block covers.
  final Uint8List macBytes;

  const ZxBlockHeader(
      this.type,
      this.chainId,
      this.unpackedSize,
      this.packedSize,
      this.checkType,
      this.check,
      this.headerSize,
      this.macBytes);

  /// The header of a block, marker to CRC.
  static Uint8List encode(int type, int chainId, int unpacked, int packed,
      int checkType, Uint8List check) {
    final f = ZxBytes(64);
    f.vint(type);
    f.vint(chainId);
    f.vint(unpacked);
    f.vint(packed);
    f.u8(checkType);
    f.bytes(check);
    final w = ZxBytes(f.length + 20);
    w.u32(zxBlockMarker);
    w.vint(f.length);
    w.bytes(f.view());
    w.u32(Crc32c.of(w.view()));
    return w.toBytes();
  }

  /// The bytes of [encode] before the CRC.
  static Uint8List macPart(Uint8List header) =>
      Uint8List.sublistView(header, 0, header.length - 4);

  /// Parses a block header at b[off, end). Returns null when there is no
  /// marker or the header CRC does not match (or the header is cut).
  static ZxBlockHeader? tryParse(Uint8List b, int off, int end) {
    if (end - off < 10 || getUint32LE(b, off) != zxBlockMarker) return null;
    try {
      final r = ZxRead(b, off + 4, end);
      final hs = r.vint();
      if (hs > 256) return null;
      final start = r.pos;
      if (start + hs + 4 > end) return null;
      final crcPos = start + hs;
      if (Crc32c.of(b, off, crcPos) != getUint32LE(b, crcPos)) return null;
      final f = ZxRead(b, start, crcPos);
      final type = f.vint();
      final chain = f.vint();
      final unpacked = f.vint();
      final packed = f.vint();
      final ct = f.u8();
      final cs = ZxCheck.size(ct);
      Uint8List check;
      if (cs < 0) {
        // an unknown check: the rest of the fields is its value
        check = Uint8List(0);
      } else {
        check = Uint8List.fromList(f.bytes(cs));
      }
      return ZxBlockHeader(
          type,
          chain,
          unpacked,
          packed,
          ct,
          check,
          crcPos + 4 - off,
          Uint8List.fromList(Uint8List.sublistView(b, off, crcPos)));
    } on SevenZipException {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Entries

/// One entry of the Index (section 6.2).
class ZxEntry {
  String path;
  int kind;
  int size;

  /// Extents as flat triples: block, offset in block, length.
  Int64List extents;
  String? linkTarget;
  int? devMajor;
  int? devMinor;

  /// POSIX permission and special bits, without the type.
  int? mode;
  int? uid;
  int? gid;
  String? user;
  String? group;
  int? winAttrib;

  /// Times in nanoseconds since 1970-01-01 UTC.
  int? mTime;
  int? aTime;
  int? cTime;
  int? birthTime;
  Uint8List? sha256;
  String? tlsh;
  List<(String, Uint8List)> xattrs = const [];
  String? comment;

  /// Sparse data ranges as flat pairs: offset, length.
  Int64List? sparse;
  String? nestedHint;

  /// The generation that wrote this content (0x76).
  int? since;

  /// Attribute records this reader does not know (non-critical: kept when
  /// the entry is copied to a new generation).
  List<ZxRecord> other = const [];

  /// Not null when the entry has an unknown critical attribute: it can not
  /// be extracted (the message says why).
  String? unsupported;

  ZxEntry(this.path, this.kind, {this.size = 0, Int64List? extents})
      : extents = extents ?? Int64List(0);

  int get numExtents => extents.length ~/ 3;

  bool get isDir => kind == ZxKind.directory;

  ZxEntry copy() => ZxEntry(path, kind, size: size, extents: extents)
    ..linkTarget = linkTarget
    ..devMajor = devMajor
    ..devMinor = devMinor
    ..mode = mode
    ..uid = uid
    ..gid = gid
    ..user = user
    ..group = group
    ..winAttrib = winAttrib
    ..mTime = mTime
    ..aTime = aTime
    ..cTime = cTime
    ..birthTime = birthTime
    ..sha256 = sha256
    ..tlsh = tlsh
    ..xattrs = xattrs
    ..comment = comment
    ..sparse = sparse
    ..nestedHint = nestedHint
    ..since = since
    ..other = other
    ..unsupported = unsupported;

  /// The attribute records of the entry (the payload of record 0x21).
  Uint8List encode({bool withSize = true}) {
    final w = ZxBytes(64 + path.length);
    w.rec(ZxRec.path, (x) => x.string(path));
    w.rec(ZxRec.kind, (x) => x.vint(kind));
    if (withSize && (kind == ZxKind.file || size != 0)) {
      w.rec(ZxRec.size, (x) => x.vint(size));
    }
    if (kind == ZxKind.file || extents.isNotEmpty) {
      w.rec(ZxRec.extents, (x) {
        x.vint(numExtents);
        for (var i = 0; i < extents.length; i++) {
          x.vint(extents[i]);
        }
      });
    }
    final lt = linkTarget;
    if (lt != null) w.rec(ZxRec.linkTarget, (x) => x.string(lt));
    if (devMajor != null || devMinor != null) {
      w.rec(ZxRec.device, (x) {
        x.vint(devMajor ?? 0);
        x.vint(devMinor ?? 0);
      });
    }
    final m = mode;
    if (m != null) w.rec(ZxRec.mode, (x) => x.vint(m));
    if (uid != null || gid != null || user != null || group != null) {
      w.rec(ZxRec.owner, (x) {
        x.vint(uid ?? 0);
        x.vint(gid ?? 0);
        x.string(user ?? '');
        x.string(group ?? '');
      });
    }
    final wa = winAttrib;
    if (wa != null) w.rec(ZxRec.winAttrib, (x) => x.vint(wa));
    void time(int type, int? t) {
      if (t != null) w.rec(type, (x) => x.svint(t));
    }

    time(ZxRec.mTime, mTime);
    time(ZxRec.aTime, aTime);
    time(ZxRec.cTime, cTime);
    time(ZxRec.birthTime, birthTime);
    final sh = sha256;
    if (sh != null) w.record(ZxRec.sha256, sh);
    final tl = tlsh;
    if (tl != null) w.rec(ZxRec.tlsh, (x) => x.string(tl));
    for (final (name, value) in xattrs) {
      w.rec(ZxRec.xattr, (x) {
        x.string(name);
        x.vint(value.length);
        x.bytes(value);
      });
    }
    final c = comment;
    if (c != null) w.rec(ZxRec.entryComment, (x) => x.string(c));
    final sp = sparse;
    if (sp != null) {
      w.rec(ZxRec.sparse, (x) {
        x.vint(sp.length ~/ 2);
        for (var i = 0; i < sp.length; i++) {
          x.vint(sp[i]);
        }
      });
    }
    final nh = nestedHint;
    if (nh != null) w.rec(ZxRec.nestedHint, (x) => x.string(nh));
    final s = since;
    if (s != null) w.rec(ZxRec.since, (x) => x.vint(s));
    for (final o in other) {
      w.record(o.type, o.payload);
    }
    return w.toBytes();
  }

  /// Parses the attribute records of an entry. An [inline] record (of a
  /// streamed file) has no extents, and no size when the size was not
  /// known (size -1).
  static ZxEntry decode(Uint8List b, {bool inline = false}) {
    String? path;
    int? kind;
    final e = ZxEntry('', 0);
    var hasSize = false;
    List<(String, Uint8List)>? xattrs;
    List<ZxRecord>? other;
    for (final rec in zxRecords(b)) {
      final r = ZxRead(rec.payload);
      switch (rec.type) {
        case ZxRec.path:
          path = r.string();
        case ZxRec.kind:
          kind = r.vint();
        case ZxRec.size:
          e.size = r.vint();
          hasSize = true;
        case ZxRec.extents:
          final n = r.count(3);
          final x = Int64List(n * 3);
          for (var i = 0; i < x.length; i++) {
            x[i] = r.vint();
          }
          e.extents = x;
        case ZxRec.linkTarget:
          e.linkTarget = r.string();
        case ZxRec.device:
          e.devMajor = r.vint();
          e.devMinor = r.vint();
        case ZxRec.mode:
          e.mode = r.vint();
        case ZxRec.owner:
          e.uid = r.vint();
          e.gid = r.vint();
          final u = r.string(), g = r.string();
          e.user = u.isEmpty ? null : u;
          e.group = g.isEmpty ? null : g;
        case ZxRec.winAttrib:
          e.winAttrib = r.vint();
        case ZxRec.mTime:
          e.mTime = r.svint();
        case ZxRec.aTime:
          e.aTime = r.svint();
        case ZxRec.cTime:
          e.cTime = r.svint();
        case ZxRec.birthTime:
          e.birthTime = r.svint();
        case ZxRec.sha256:
          if (rec.payload.length != 32) zxDamaged('bad SHA-256 attribute');
          e.sha256 = Uint8List.fromList(rec.payload);
        case ZxRec.tlsh:
          e.tlsh = r.string();
        case ZxRec.xattr:
          final name = r.string();
          final len = r.vint();
          (xattrs ??= []).add((name, Uint8List.fromList(r.bytes(len))));
        case ZxRec.entryComment:
          e.comment = r.string();
        case ZxRec.sparse:
          final n = r.count(2);
          final x = Int64List(n * 2);
          for (var i = 0; i < x.length; i++) {
            x[i] = r.vint();
          }
          e.sparse = x;
        case ZxRec.nestedHint:
          e.nestedHint = r.string();
        case ZxRec.since:
          e.since = r.vint();
        default:
          if (rec.critical) {
            e.unsupported ??= 'unsupported critical attribute '
                '${rec.hexType} (written by a newer zx?)';
          } else {
            (other ??= [])
                .add(ZxRecord(rec.type, Uint8List.fromList(rec.payload)));
          }
      }
    }
    if (path == null || kind == null) {
      zxDamaged('an entry without path or kind');
    }
    if (!zxIsValidPath(path)) zxDamaged('invalid entry path "$path"');
    e.path = path;
    e.kind = kind;
    if (kind == ZxKind.file && !hasSize) {
      if (!inline) zxDamaged('a file entry without size');
      e.size = -1;
    }
    if (xattrs != null) e.xattrs = xattrs;
    if (other != null) e.other = other;
    if (e.unsupported == null && !inline) {
      var sum = 0;
      for (var i = 2; i < e.extents.length; i += 3) {
        sum += e.extents[i];
      }
      final sp = e.sparse;
      var want = e.size;
      if (sp != null) {
        want = 0;
        for (var i = 1; i < sp.length; i += 2) {
          want += sp[i];
        }
      }
      if (e.kind == ZxKind.file && sum != want) {
        zxDamaged('extents of "$path" do not add up to its size');
      }
    }
    return e;
  }
}

/// A path is relative, '/' separated, without empty, '.' or '..'
/// components (section 6.2).
bool zxIsValidPath(String p) {
  if (p.isEmpty || p.startsWith('/')) return false;
  for (final c in p.split('/')) {
    if (c.isEmpty || c == '.' || c == '..') return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Index

/// A block of the block table (section 6.1, 10.1).
class ZxBlockRef {
  final int volume;
  final int offset;
  final int headerSize;
  final int packedSize;
  final int unpackedSize;
  final int chainId;
  const ZxBlockRef(this.volume, this.offset, this.headerSize, this.packedSize,
      this.unpackedSize, this.chainId);

  int get totalSize => headerSize + packedSize;
}

/// The location of an Index: volume, offset of its first block, size.
class ZxIndexLoc {
  final int volume;
  final int offset;
  final int size;
  const ZxIndexLoc(this.volume, this.offset, this.size);
}

/// One generation (Index records 0x42 and 0x44).
class ZxGeneration {
  final int number;

  /// Nanoseconds since 1970-01-01 UTC.
  final int time;
  final String comment;

  /// Where its Index is (null when unknown).
  final ZxIndexLoc? index;

  /// Entries the generation added or changed, entries it deleted, and
  /// the bytes of the data blocks it wrote (record 0x44).
  final int added;
  final int deleted;
  final int packed;
  const ZxGeneration(this.number, this.time, this.comment,
      [this.index, this.added = 0, this.deleted = 0, this.packed = 0]);

  ZxGeneration at(ZxIndexLoc? loc) =>
      ZxGeneration(number, time, comment, loc, added, deleted, packed);

  DateTime get dateTime =>
      DateTime.fromMicrosecondsSinceEpoch(time ~/ 1000, isUtc: true);
}

/// A volume of a multi-volume set (Index record 0x45).
class ZxVolumeInfo {
  final int number;
  final String name;
  final int size;
  final int xxh64;
  const ZxVolumeInfo(this.number, this.name, this.size, this.xxh64);
}

/// The chunk table of a deduplicating writer (Index record 0x34, section
/// 6.4): where each stored chunk is and its SHA-256, so that a later
/// generation stores a chunk it meets again only once.
class ZxChunkTable {
  /// xxHash64 of the payload of the block table record (0x12) of the
  /// Index the table was written for. A table whose value differs from
  /// the block table of its Index is stale (an older writer renumbered
  /// the blocks) and MUST be ignored.
  final int fingerprint;

  /// Flat triples: block, offset in block, length; sorted by block, then
  /// offset.
  final Int64List locs;

  /// 32 bytes (SHA-256) per chunk.
  final Uint8List sha;
  const ZxChunkTable(this.fingerprint, this.locs, this.sha);

  int get length => locs.length ~/ 3;

  /// The record payload: vint count, u64 fingerprint, then per chunk vint
  /// block_delta (block minus the previous chunk's block, the first one
  /// from 0), vint offset, vint length, bytes(32) sha256.
  void write(ZxBytes x, int fp) {
    final n = length;
    x.vint(n);
    x.u64(fp);
    var prev = 0;
    for (var i = 0; i < n; i++) {
      final b = locs[3 * i];
      x.vint(b - prev);
      prev = b;
      x.vint(locs[3 * i + 1]);
      x.vint(locs[3 * i + 2]);
      x.bytes(sha, 32 * i, 32 * i + 32);
    }
  }

  static ZxChunkTable read(ZxRead r) {
    final n = r.count(35);
    final fp = r.u64();
    final locs = Int64List(3 * n);
    final sha = Uint8List(32 * n);
    var b = 0;
    for (var i = 0; i < n; i++) {
      b += r.vint();
      final off = r.vint(), len = r.vint();
      if (b < 0 || len == 0) zxDamaged('bad chunk table');
      locs[3 * i] = b;
      locs[3 * i + 1] = off;
      locs[3 * i + 2] = len;
      sha.setRange(32 * i, 32 * i + 32, r.bytes(32));
    }
    return ZxChunkTable(fp, locs, sha);
  }
}

/// One chunk run (a block of type 6, section 6.4.1): where it is and how
/// many chunks it lists.
class ZxChunkRunRef {
  final int volume;
  final int offset;

  /// Bytes of the whole block, header included.
  final int size;
  final int count;
  const ZxChunkRunRef(this.volume, this.offset, this.size, this.count);
}

/// The chunk runs of a deduplicating writer (Index record 0x36, section
/// 6.4.1), oldest first.
class ZxChunkRuns {
  /// xxHash64 of the payload of the block table record of the Index the
  /// list was written for (as in [ZxChunkTable.fingerprint]).
  final int fingerprint;
  final List<ZxChunkRunRef> runs;
  const ZxChunkRuns(this.fingerprint, this.runs);

  int get chunks => runs.fold(0, (s, r) => s + r.count);

  /// The record payload: u64 fingerprint, vint count, then per run
  /// [vint volume, with multi_volume] vint offset, vint size, vint count.
  void write(ZxBytes x, int fp, bool multiVolume) {
    x.u64(fp);
    x.vint(runs.length);
    for (final r in runs) {
      if (multiVolume) x.vint(r.volume);
      x.vint(r.offset);
      x.vint(r.size);
      x.vint(r.count);
    }
  }

  static ZxChunkRuns read(ZxRead r, bool multiVolume) {
    final fp = r.u64();
    final n = r.count(3);
    final out = <ZxChunkRunRef>[];
    for (var i = 0; i < n; i++) {
      final vol = multiVolume ? r.vint() : 0;
      final off = r.vint(), size = r.vint(), count = r.vint();
      if (count == 0) zxDamaged('bad chunk run list');
      out.add(ZxChunkRunRef(vol, off, size, count));
    }
    return ZxChunkRuns(fp, out);
  }
}

/// The Index of one generation (section 6).
class ZxIndex {
  final Map<int, ZxChain> chains = {};
  List<ZxBlockRef> blocks = [];
  List<ZxEntry> entries = [];

  /// Sorted (sha256, entry number) pairs (record 0x30).
  List<(Uint8List, int)>? shaTable;

  /// (tlsh, entry number) pairs (record 0x32).
  List<(String, int)>? tlshList;

  /// The chunk table of the dedup writer (record 0x34, written by zx
  /// 0.5.0); see [chunksValid].
  ZxChunkTable? chunkTable;

  /// The chunk runs of the dedup writer (record 0x36); see
  /// [chunkRunsValid].
  ZxChunkRuns? chunkRuns;

  /// xxHash64 of the payload of the block table record, as read (the
  /// fingerprint a valid chunk table carries).
  int blockTableHash = 0;
  ZxIndexLoc? previous;
  ZxGeneration? generation;

  /// Every generation up to this one (record 0x44).
  List<ZxGeneration> generations = [];
  List<ZxVolumeInfo>? volumes;

  /// The requirements of this generation (record 0x46).
  ZxVer? minReaderVersion;
  int requiredFeatures = 0;
  int optionalFeatures = 0;

  /// The database root (record 0x49, section 16), null without one.
  ZxDbRoot? database;

  /// An incremental Index (record 0x4B, section 9.1.2): the full Index it
  /// takes the rest from and that Index's generation. Set on an Index
  /// read from a delta (also once resolved), null for a full Index.
  ZxIndexLoc? base;
  int baseGeneration = 0;

  /// Non-critical records this reader does not know.
  final List<ZxRecord> other = [];

  /// The chunk table, when there is one and it was written for this block
  /// table (section 6.4).
  ZxChunkTable? get chunksValid {
    final t = chunkTable;
    return t != null && t.fingerprint == blockTableHash ? t : null;
  }

  /// The chunk runs, when there are some and they were listed for this
  /// block table (section 6.4.1).
  ZxChunkRuns? get chunkRunsValid {
    final t = chunkRuns;
    return t != null && t.fingerprint == blockTableHash ? t : null;
  }

  Uint8List encode({required bool multiVolume}) {
    final w = ZxBytes(1024);
    final mr = minReaderVersion;
    if (mr != null) {
      w.rec(ZxRec.requirements, (x) {
        x.version(mr);
        x.u64(requiredFeatures);
        x.u64(optionalFeatures);
      });
    }
    final g = generation;
    if (g != null) {
      w.rec(ZxRec.generation, (x) {
        x.vint(g.number);
        x.vint(g.time);
        x.string(g.comment);
      });
    }
    final p = previous;
    if (p != null) {
      w.rec(ZxRec.prevIndex, (x) {
        if (multiVolume) x.vint(p.volume);
        x.vint(p.offset);
        x.vint(p.size);
      });
    }
    if (generations.isNotEmpty) {
      w.rec(ZxRec.generationList, (x) {
        x.vint(generations.length);
        for (final gen in generations) {
          x.vint(gen.number);
          x.vint(gen.time);
          final l = gen.index;
          x.vint(l?.volume ?? 0);
          x.vint(l?.offset ?? 0);
          x.vint(l?.size ?? 0);
          x.string(gen.comment);
          x.vint(gen.added);
          x.vint(gen.deleted);
          x.vint(gen.packed);
        }
      });
    }
    final vols = volumes;
    if (vols != null) {
      w.rec(ZxRec.volumeTable, (x) {
        x.vint(vols.length);
        for (final v in vols) {
          x.vint(v.number);
          x.string(v.name);
          x.vint(v.size);
          x.u64(v.xxh64);
        }
      });
    }
    final ids = chains.keys.toList()..sort();
    for (final id in ids) {
      if (id == 0) continue;
      w.rec(ZxRec.chain, chains[id]!.write);
    }
    final bt = ZxBytes(16 + blocks.length * 12);
    bt.vint(blocks.length);
    for (final b in blocks) {
      if (multiVolume) bt.vint(b.volume);
      bt.vint(b.offset);
      bt.vint(b.headerSize);
      bt.vint(b.packedSize);
      bt.vint(b.unpackedSize);
      bt.vint(b.chainId);
    }
    blockTableHash = xxh64(bt.view());
    w.record(ZxRec.blockTable, bt.view());
    for (final e in entries) {
      w.record(ZxRec.entry, e.encode());
    }
    final st = shaTable;
    if (st != null) {
      w.rec(ZxRec.shaTable, (x) {
        x.vint(st.length);
        for (final (h, n) in st) {
          x.bytes(h);
          x.vint(n);
        }
      });
    }
    final tl = tlshList;
    if (tl != null) {
      w.rec(ZxRec.tlshList, (x) {
        x.vint(tl.length);
        for (final (t, n) in tl) {
          x.string(t);
          x.vint(n);
        }
      });
    }
    final ct = chunkTable;
    if (ct != null) {
      final fp = blockTableHash;
      w.rec(ZxRec.chunkTable, (x) => ct.write(x, fp));
    }
    final cr = chunkRuns;
    if (cr != null) {
      final fp = blockTableHash;
      w.rec(ZxRec.chunkRuns, (x) => cr.write(x, fp, multiVolume));
    }
    final db = database;
    if (db != null) w.rec(ZxRec.database, db.write);
    for (final o in other) {
      w.record(o.type, o.payload);
    }
    return w.toBytes();
  }

  /// The incremental Index of this state (section 9.1.2): the records a
  /// database commit changes (requirements, generation, previous Index,
  /// the generations after [baseGeneration], chains, database root) and
  /// record 0x4B naming the full Index at [baseLoc] that holds the rest.
  /// The block table, entries, lookup tables, chunk records and volume
  /// table must be those of that Index.
  Uint8List encodeDelta(ZxIndexLoc baseLoc, int baseGeneration) {
    final w = ZxBytes(512);
    w.rec(ZxRec.indexBase, (x) {
      x.vint(baseLoc.offset);
      x.vint(baseLoc.size);
      x.vint(baseGeneration);
    });
    final mr = minReaderVersion;
    if (mr != null) {
      w.rec(ZxRec.requirements, (x) {
        x.version(mr);
        x.u64(requiredFeatures);
        x.u64(optionalFeatures);
      });
    }
    final g = generation;
    if (g != null) {
      w.rec(ZxRec.generation, (x) {
        x.vint(g.number);
        x.vint(g.time);
        x.string(g.comment);
      });
    }
    final p = previous;
    if (p != null) {
      w.rec(ZxRec.prevIndex, (x) {
        x.vint(p.offset);
        x.vint(p.size);
      });
    }
    final tail = [
      for (final gen in generations)
        if (gen.number > baseGeneration) gen
    ];
    w.rec(ZxRec.generationList, (x) {
      x.vint(tail.length);
      for (final gen in tail) {
        x.vint(gen.number);
        x.vint(gen.time);
        final l = gen.index;
        x.vint(l?.volume ?? 0);
        x.vint(l?.offset ?? 0);
        x.vint(l?.size ?? 0);
        x.string(gen.comment);
        x.vint(gen.added);
        x.vint(gen.deleted);
        x.vint(gen.packed);
      }
    });
    final ids = chains.keys.toList()..sort();
    for (final id in ids) {
      if (id == 0) continue;
      w.rec(ZxRec.chain, chains[id]!.write);
    }
    final db = database;
    if (db != null) w.rec(ZxRec.database, db.write);
    return w.toBytes();
  }

  /// This incremental Index completed with the full Index [full] it names
  /// (read at [base]): the state of its generation.
  ZxIndex resolveWith(ZxIndex full) {
    final bl = base!;
    final out = ZxIndex();
    out.chains.addAll(full.chains);
    out.chains.addAll(chains);
    out.blocks = full.blocks;
    out.entries = full.entries;
    out.shaTable = full.shaTable;
    out.tlshList = full.tlshList;
    out.chunkTable = full.chunkTable;
    out.chunkRuns = full.chunkRuns;
    out.blockTableHash = full.blockTableHash;
    out.volumes = full.volumes;
    out.other.addAll(full.other);
    out.other.addAll(other);
    out.previous = previous;
    out.generation = generation;
    out.minReaderVersion = minReaderVersion;
    out.requiredFeatures = requiredFeatures;
    out.optionalFeatures = optionalFeatures;
    out.database = database;
    out.base = bl;
    out.baseGeneration = baseGeneration;
    final gens = <ZxGeneration>[];
    for (final g in full.generations) {
      if (g.number > baseGeneration) break;
      gens.add(g.number == baseGeneration && g.index == null ? g.at(bl) : g);
    }
    if (gens.isEmpty || gens.last.number != baseGeneration) {
      zxDamaged('the base of an incremental Index does not match');
    }
    gens.addAll(generations);
    out.generations = gens;
    return out;
  }

  static ZxIndex decode(Uint8List b, {required bool multiVolume}) {
    final idx = ZxIndex();
    var sawEntry = false;
    for (final rec in zxRecords(b)) {
      final r = ZxRead(rec.payload);
      switch (rec.type) {
        case ZxRec.chain:
          if (sawEntry) zxDamaged('a chain declared after the entries');
          final c = ZxChain.read(r);
          idx.chains[c.id] = c;
        case ZxRec.blockTable:
          if (sawEntry) zxDamaged('the block table after the entries');
          idx.blockTableHash = xxh64(rec.payload);
          final n = r.count(5);
          final list = <ZxBlockRef>[];
          for (var i = 0; i < n; i++) {
            final vol = multiVolume ? r.vint() : 0;
            list.add(ZxBlockRef(
                vol, r.vint(), r.vint(), r.vint(), r.vint(), r.vint()));
          }
          idx.blocks = list;
        case ZxRec.entry:
          sawEntry = true;
          idx.entries.add(ZxEntry.decode(rec.payload));
        case ZxRec.shaTable:
          final n = r.count(33);
          idx.shaTable = [
            for (var i = 0; i < n; i++)
              (Uint8List.fromList(r.bytes(32)), r.vint())
          ];
        case ZxRec.tlshList:
          final n = r.count(2);
          idx.tlshList = [for (var i = 0; i < n; i++) (r.string(), r.vint())];
        case ZxRec.chunkTable:
          idx.chunkTable = ZxChunkTable.read(r);
        case ZxRec.chunkRuns:
          idx.chunkRuns = ZxChunkRuns.read(r, multiVolume);
        case ZxRec.database:
          idx.database = ZxDbRoot.read(r);
        case ZxRec.indexBase:
          if (multiVolume) {
            zxDamaged('an incremental Index in a multi-volume set');
          }
          idx.base = ZxIndexLoc(0, r.vint(), r.vint());
          idx.baseGeneration = r.vint();
        case ZxRec.prevIndex:
          final vol = multiVolume ? r.vint() : 0;
          idx.previous = ZxIndexLoc(vol, r.vint(), r.vint());
        case ZxRec.generation:
          idx.generation = ZxGeneration(r.vint(), r.vint(), r.string());
        case ZxRec.generationList:
          final n = r.count(6);
          idx.generations = [
            for (var i = 0; i < n; i++)
              () {
                final num = r.vint(), t = r.vint();
                final loc = ZxIndexLoc(r.vint(), r.vint(), r.vint());
                final c = r.string();
                final a = r.vint(), d = r.vint(), pk = r.vint();
                return ZxGeneration(
                    num, t, c, loc.size == 0 ? null : loc, a, d, pk);
              }()
          ];
        case ZxRec.volumeTable:
          final n = r.count(11);
          idx.volumes = [
            for (var i = 0; i < n; i++)
              ZxVolumeInfo(r.vint(), r.string(), r.vint(), r.u64())
          ];
        case ZxRec.requirements:
          idx.minReaderVersion = r.version();
          idx.requiredFeatures = r.u64();
          idx.optionalFeatures = r.u64();
          zxCheckCompat(
              zxFormatVersion, idx.minReaderVersion!, idx.requiredFeatures);
        default:
          if (rec.critical) {
            throw SevenZipException(
                'zx: unsupported critical Index record ${rec.hexType} '
                '(written by a newer zx?)',
                SevenZipError.unsupported);
          }
          idx.other.add(ZxRecord(rec.type, Uint8List.fromList(rec.payload)));
      }
    }
    return idx;
  }
}

// ---------------------------------------------------------------------------
// Database root and page locations (section 16)

/// Where a database page is: the database page block (type 7) at
/// [blockOffset] (the marker; [blockSize] bytes with its header) and the
/// page's bytes at [inOffset], [length] bytes long, in its unpacked
/// payload. [flags]: bit 0 set while the page is in the write buffer (not
/// folded yet), bits 16 to 31 the number of its tree (0xFFFF: unknown).
class ZxDbLoc {
  final int blockOffset;
  final int blockSize;
  final int inOffset;
  final int length;
  final int flags;
  const ZxDbLoc(
      this.blockOffset, this.blockSize, this.inOffset, this.length, this.flags);

  /// Page flag: in the write buffer (coded with a fast codec, to be folded).
  static const unfolded = 1;

  bool get isUnfolded => (flags & unfolded) != 0;
  int get treeTag => flags >> 16;

  /// A key that identifies the page in its file (for caches).
  int get cacheKey => blockOffset * 4194304 + inOffset;

  ZxDbLoc withBlock(int offset, int size) =>
      ZxDbLoc(offset, size, inOffset, length, flags);

  /// Size of an entry of a map page.
  static const entrySize = 24;

  /// Writes the 24 bytes of a map page entry at b[off].
  void writeEntry(Uint8List b, int off) {
    setUint64LE(b, off, blockOffset);
    setUint32LE(b, off + 8, blockSize);
    setUint32LE(b, off + 12, inOffset);
    setUint32LE(b, off + 16, length);
    setUint32LE(b, off + 20, flags);
  }

  /// The entry at b[off] of a map page, or null for no page.
  static ZxDbLoc? readEntry(Uint8List b, int off) {
    final o = getUint64LE(b, off);
    if (o == 0) return null;
    return ZxDbLoc(o, getUint32LE(b, off + 8), getUint32LE(b, off + 12),
        getUint32LE(b, off + 16), getUint32LE(b, off + 20));
  }

  void write(ZxBytes x) {
    x.vint(blockOffset);
    x.vint(blockSize);
    x.vint(inOffset);
    x.vint(length);
    x.vint(flags);
  }

  static ZxDbLoc read(ZxRead r) {
    final o = r.vint(), s = r.vint(), i = r.vint(), l = r.vint();
    final f = r.vint();
    if (o == 0 || s == 0) zxDamaged('bad database page location');
    return ZxDbLoc(o, s, i, l, f);
  }
}

/// The root of the database of a generation (Index record 0x49, section
/// 16): the page map (map pages of [mapPageEntries] locations each), the
/// catalog tree, the page ids free for reuse.
class ZxDbRoot {
  /// The layout version of the database (1).
  final int version;

  /// Page ids are 1 to [nextPageId] - 1.
  final int nextPageId;

  /// The page id of the root of the catalog tree (0: no tree yet).
  final int catalogRoot;

  /// The number the next tree gets (catalog).
  final int nextTreeId;

  /// Bytes of pages in the write buffer (not folded).
  final int unfoldedBytes;

  /// The map pages: map page k lists pages k * 1024 to k * 1024 + 1023;
  /// null for a map page without pages.
  final List<ZxDbLoc?> maps;

  /// Free page ids as flat (start, length) runs, sorted.
  final List<int> free;

  const ZxDbRoot(
      {this.version = 1,
      required this.nextPageId,
      required this.catalogRoot,
      required this.nextTreeId,
      this.unfoldedBytes = 0,
      required this.maps,
      required this.free});

  static const int mapPageLog2 = 10;
  static const int mapPageEntries = 1 << mapPageLog2;

  void write(ZxBytes x) {
    x.vint(version);
    x.vint(nextPageId);
    x.vint(catalogRoot);
    x.vint(nextTreeId);
    x.vint(unfoldedBytes);
    x.vint(mapPageLog2);
    x.vint(maps.length);
    for (final m in maps) {
      if (m == null) {
        x.vint(0);
      } else {
        m.write(x);
      }
    }
    x.vint(free.length ~/ 2);
    var prev = 0;
    for (var i = 0; i < free.length; i += 2) {
      x.vint(free[i] - prev);
      x.vint(free[i + 1]);
      prev = free[i] + free[i + 1];
    }
  }

  static ZxDbRoot read(ZxRead r) {
    final version = r.vint();
    if (version != 1) {
      throw SevenZipException(
          'zx: database layout version $version is not supported '
          '(written by a newer zx?)',
          SevenZipError.unsupported);
    }
    final next = r.vint(), cat = r.vint(), nt = r.vint(), unf = r.vint();
    if (r.vint() != mapPageLog2) zxDamaged('bad database map page size');
    final n = r.count(1);
    final maps = <ZxDbLoc?>[];
    for (var i = 0; i < n; i++) {
      final o = r.vint();
      if (o == 0) {
        maps.add(null);
      } else {
        final s = r.vint(), io = r.vint(), l = r.vint(), f = r.vint();
        maps.add(ZxDbLoc(o, s, io, l, f));
      }
    }
    final fc = r.count(2);
    final free = <int>[];
    var prev = 0;
    for (var i = 0; i < fc; i++) {
      final st = prev + r.vint(), len = r.vint();
      if (len == 0) zxDamaged('bad database free list');
      free
        ..add(st)
        ..add(len);
      prev = st + len;
    }
    if (next < 1 ||
        cat >= next ||
        (next > 1 && (maps.length << mapPageLog2) <= next - 1)) {
      zxDamaged('bad database root');
    }
    return ZxDbRoot(
        version: version,
        nextPageId: next,
        catalogRoot: cat,
        nextTreeId: nt,
        unfoldedBytes: unf,
        maps: maps,
        free: free);
  }
}

// ---------------------------------------------------------------------------
// Footer and volume trailer

/// The Footer (section 14).
class ZxFooter {
  final int indexOffset;
  final int indexSize;
  final int blockCount;
  final int flags;
  const ZxFooter(this.indexOffset, this.indexSize, this.blockCount,
      [this.flags = 0]);

  Uint8List encode() {
    final w = ZxBytes(zxFooterSize);
    w.u64(indexOffset);
    w.u64(indexSize);
    w.u32(blockCount);
    w.u32(flags);
    w.u32(Crc32c.of(w.view()));
    w.u32(zxFooterMagic);
    return w.toBytes();
  }

  /// Parses a Footer at b[off]; null when the magic or the CRC is wrong.
  static ZxFooter? tryParse(Uint8List b, int off) {
    if (b.length - off < zxFooterSize) return null;
    if (getUint32LE(b, off + 28) != zxFooterMagic) return null;
    if (Crc32c.of(b, off, off + 24) != getUint32LE(b, off + 24)) return null;
    return ZxFooter(getUint64LE(b, off), getUint64LE(b, off + 8),
        getUint32LE(b, off + 16), getUint32LE(b, off + 20));
  }
}

/// The trailer of a volume that does not end with a Footer (10.3).
class ZxVolumeTrailer {
  final int volume;
  final int dataSize;
  final Uint8List idPrefix;
  const ZxVolumeTrailer(this.volume, this.dataSize, this.idPrefix);

  Uint8List encode() {
    final w = ZxBytes(zxFooterSize);
    w.u32(volume);
    w.u32(0);
    w.u64(dataSize);
    w.bytes(idPrefix, 0, 8);
    w.u32(Crc32c.of(w.view()));
    w.u32(zxTrailerMagic);
    return w.toBytes();
  }

  static ZxVolumeTrailer? tryParse(Uint8List b, int off) {
    if (b.length - off < zxFooterSize) return null;
    if (getUint32LE(b, off + 28) != zxTrailerMagic) return null;
    if (Crc32c.of(b, off, off + 24) != getUint32LE(b, off + 24)) return null;
    return ZxVolumeTrailer(getUint32LE(b, off), getUint64LE(b, off + 8),
        Uint8List.fromList(Uint8List.sublistView(b, off + 16, off + 24)));
  }
}

/// Nanoseconds since 1970 of a FILETIME (100 ns since 1601).
int zxNsOfFileTime(int ft) => (ft - 116444736000000000) * 100;

/// FILETIME of nanoseconds since 1970.
int zxFileTimeOfNs(int ns) => ns ~/ 100 + 116444736000000000;

/// Hex text of bytes.
String zxHex(Uint8List b) {
  const d = '0123456789abcdef';
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(d[x >> 4]);
    sb.write(d[x & 15]);
  }
  return sb.toString();
}

/// Bytes of hex text (null when [s] is not hex of even length).
Uint8List? zxUnhex(String s) {
  if (s.length.isOdd) return null;
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(s.substring(2 * i, 2 * i + 2), radix: 16);
    if (v == null) return null;
    out[i] = v;
  }
  return out;
}
