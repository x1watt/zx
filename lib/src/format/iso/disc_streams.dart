// Streams shared by the disc image handlers (ISO 9660 and UDF): the data of
// an item as a list of runs of the image, and the 2048 byte user data view
// of a raw CD image with 2352 byte sectors. Written for this package.

import 'dart:typed_data';

import '../../io/streams.dart';

/// The data of an item: runs of the image in order. A run with a negative
/// position reads as zeros (sparse or unrecorded extents).
class RunList {
  final List<int> pos = [];
  final List<int> len = [];
  int total = 0;

  /// Appends [l] bytes at image offset [p] (-1 for zeros), merging with the
  /// previous run when contiguous.
  void add(int p, int l) {
    if (l <= 0) return;
    total += l;
    final n = pos.length;
    if (n != 0) {
      final lp = pos[n - 1];
      if (p < 0 && lp < 0) {
        len[n - 1] += l;
        return;
      }
      if (p >= 0 && lp >= 0 && lp + len[n - 1] == p) {
        len[n - 1] += l;
        return;
      }
    }
    pos.add(p < 0 ? -1 : p);
    len.add(l);
  }

  /// The recorded bytes (runs that are not zeros).
  int get recorded {
    var r = 0;
    for (var i = 0; i < pos.length; i++) {
      if (pos[i] >= 0) r += len[i];
    }
    return r;
  }

  /// The end of the last recorded byte in the image, 0 when none.
  int get maxEnd {
    var r = 0;
    for (var i = 0; i < pos.length; i++) {
      final p = pos[i];
      if (p >= 0 && p + len[i] > r) r = p + len[i];
    }
    return r;
  }
}

/// A seekable view of [size] bytes made of the runs of a [RunList] over the
/// image. Reading past the recorded runs (a truncated image, or a size
/// larger than the runs) returns 0.
class RunsInStream implements SeekableInStream {
  final SeekableInStream base;
  final Int64List _start;
  final Int64List _pos;
  final Int64List _len;
  final int _count;
  @override
  final int length;
  int _p = 0;
  int _run = 0;

  RunsInStream(this.base, RunList runs, int size)
      : _start = Int64List(runs.pos.length + 1),
        _pos = Int64List.fromList(runs.pos),
        _len = Int64List.fromList(runs.len),
        _count = runs.pos.length,
        length = size {
    var s = 0;
    for (var i = 0; i < _count; i++) {
      _start[i] = s;
      s += _len[i];
    }
    _start[_count] = s;
  }

  @override
  int get position => _p;

  @override
  set position(int v) => _p = v;

  // the run holding offset p (p < total)
  int _findRun(int p) {
    var r = _run;
    if (r < _count && _start[r] <= p && p < _start[r + 1]) return r;
    var lo = 0;
    var hi = _count - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_start[mid] <= p) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    _run = lo;
    return lo;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    var rem = length - _p;
    if (rem <= 0 || len <= 0) return 0;
    if (len > rem) len = rem;
    final total = _start[_count];
    if (_p >= total) return 0;
    rem = total - _p;
    if (len > rem) len = rem;
    var done = 0;
    while (done < len) {
      final r = _findRun(_p);
      final inRun = _p - _start[r];
      var n = _len[r] - inRun;
      if (n > len - done) n = len - done;
      final ip = _pos[r];
      if (ip < 0) {
        buf.fillRange(off + done, off + done + n, 0);
      } else {
        base.position = ip + inRun;
        final got = readFully(base, buf, off + done, n);
        if (got != n) {
          done += got;
          _p += got;
          return done;
        }
      }
      done += n;
      _p += n;
    }
    return done;
  }
}

/// The 2048 byte user data of a raw CD image (2352 byte sectors: sync,
/// header, data, EDC/ECC): mode 1 sectors hold the data at offset 16, mode
/// 2 form 1 (XA) sectors at offset 24.
class RawSectorInStream implements SeekableInStream {
  static const int rawSectorSize = 2352;
  final SeekableInStream base;
  final int dataOffset;
  @override
  final int length;
  int _p = 0;

  RawSectorInStream(this.base, this.dataOffset)
      : length = (base.length ~/ rawSectorSize) * 2048;

  @override
  int get position => _p;

  @override
  set position(int v) => _p = v;

  @override
  int read(Uint8List buf, int off, int len) {
    var done = 0;
    while (done < len && _p < length) {
      final sector = _p >> 11;
      final inSector = _p & 2047;
      var n = 2048 - inSector;
      if (n > len - done) n = len - done;
      base.position = sector * rawSectorSize + dataOffset + inSector;
      final got = readFully(base, buf, off + done, n);
      done += got;
      _p += got;
      if (got != n) break;
    }
    return done;
  }

  /// The user data offset of a raw image whose sector [lba] is a data
  /// sector (sync pattern, then mode 1 or mode 2), or -1.
  static int dataOffsetOf(Uint8List b, int size, int lba) {
    final s = lba * rawSectorSize;
    if (s + 24 + 8 > size) return -1;
    if (b[s] != 0 || b[s + 11] != 0) return -1;
    for (var i = 1; i < 11; i++) {
      if (b[s + i] != 0xFF) return -1;
    }
    final mode = b[s + 15];
    if (mode == 1) return 16;
    if (mode == 2) return 24;
    return -1;
  }
}

/// Little endian 16 bit value at [o].
int le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

/// Little endian 32 bit value at [o].
int le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// Little endian 64 bit value at [o].
int le64(Uint8List b, int o) => le32(b, o) | (le32(b, o + 4) << 32);

/// Big endian 16 bit value at [o].
int be16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

/// Big endian 32 bit value at [o].
int be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// Seconds from 1601-01-01 to 1970-01-01.
const int kUnixToFileTimeSeconds = 11644473600;

/// FILETIME (100 ns ticks since 1601, UTC) of a broken down local time with
/// its offset from UTC in minutes. null when the date is not valid.
int? fileTimeOf(int year, int month, int day, int hour, int minute, int second,
    int ticks, int offsetMinutes) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 60) return null;
  if (year < 1601 || year > 9999) return null;
  final unix = DateTime.utc(year, month, day, hour, minute, second)
              .millisecondsSinceEpoch ~/
          1000 -
      offsetMinutes * 60;
  return (unix + kUnixToFileTimeSeconds) * 10000000 + ticks;
}

/// Reads [len] bytes at image offset [pos] into a new buffer; the buffer is
/// shorter when the image ends before.
Uint8List readAt(SeekableInStream s, int pos, int len) {
  final b = Uint8List(len);
  if (pos < 0 || pos >= s.length) return Uint8List(0);
  s.position = pos;
  final n = readFully(s, b, 0, len);
  return n == len ? b : Uint8List.sublistView(b, 0, n);
}
