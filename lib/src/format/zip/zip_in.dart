// Reading the zip structures, written from the PKWARE APPNOTE: the end of
// central directory record (searched backward from the end, a comment may
// follow it), the Zip64 end of central directory locator and record, the
// central directory, the local headers, the data descriptors, and the
// sequential reading of local headers when there is no central directory
// (a stream, a truncated archive).
//
// libarchive's archive_read_support_format_zip.c (BSD 2-clause, see
// LICENSE) was the model for the tolerant parts: the backward search, the
// base offset of archives with data in front (self extracting stubs), and
// the search of the data descriptor after stored data of unknown size.

import 'dart:typed_data';

import '../../io/streams.dart';
import 'zip_header.dart';

/// Size of the fixed part of a local header.
const int kLocalHeaderSize = 30;

/// Size of the fixed part of a central directory record.
const int kCentralHeaderSize = 46;

/// Size of the end of central directory record without its comment.
const int kEocdSize = 22;

/// Size of the Zip64 end of central directory locator.
const int kZip64LocatorSize = 20;

/// Size of the Zip64 end of central directory record without its
/// extensible data.
const int kZip64EocdSize = 56;

/// The end of central directory data (with the Zip64 values applied).
class ZipEocd {
  /// Position of the record in the stream.
  int pos = 0;
  int thisDisk = 0;
  int cdDisk = 0;
  int numEntriesOnDisk = 0;
  int numEntries = 0;
  int cdSize = 0;
  int cdOffset = 0;
  Uint8List comment = Uint8List(0);

  /// Position of the Zip64 record, or -1.
  int zip64Pos = -1;
  bool isZip64 = false;

  /// The end of the record and its comment.
  int get end => pos + kEocdSize + comment.length;
}

/// Finds the end of central directory record in the last 64 KiB of [s].
/// Returns null when there is none.
ZipEocd? findEocd(SeekableInStream s) {
  final len = s.length;
  if (len < kEocdSize) return null;
  var tailSize = 0xFFFF + kEocdSize + kZip64LocatorSize;
  if (tailSize > len) tailSize = len;
  final tailStart = len - tailSize;
  final buf = Uint8List(tailSize);
  s.position = tailStart;
  final n = readFully(s, buf, 0, tailSize);
  for (var i = n - kEocdSize; i >= 0; i--) {
    if (buf[i] != 0x50 ||
        buf[i + 1] != 0x4B ||
        buf[i + 2] != 5 ||
        buf[i + 3] != 6) {
      continue;
    }
    final commentLen = buf[i + 20] | (buf[i + 21] << 8);
    // the comment must fit in the file (a longer declared comment is
    // accepted when the file ends inside it: the rest is missing)
    if (i + kEocdSize + commentLen > n && i + kEocdSize > n) continue;
    final e = ZipEocd()
      ..pos = tailStart + i
      ..thisDisk = buf[i + 4] | (buf[i + 5] << 8)
      ..cdDisk = buf[i + 6] | (buf[i + 7] << 8)
      ..numEntriesOnDisk = buf[i + 8] | (buf[i + 9] << 8)
      ..numEntries = buf[i + 10] | (buf[i + 11] << 8)
      ..cdSize = getUint32LE(buf, i + 12)
      ..cdOffset = getUint32LE(buf, i + 16);
    var cEnd = i + kEocdSize + commentLen;
    if (cEnd > n) cEnd = n;
    e.comment = Uint8List.fromList(buf.sublist(i + kEocdSize, cEnd));
    // the Zip64 locator right before it
    if (i >= kZip64LocatorSize &&
        getUint32LE(buf, i - kZip64LocatorSize) == ZipSig.zip64Locator) {
      final lp = i - kZip64LocatorSize;
      final z64Offset = getUint64LE(buf, lp + 8);
      _readZip64Eocd(s, e, tailStart + lp, z64Offset);
    }
    return e;
  }
  return null;
}

// the Zip64 end of central directory record: right before the locator
// (the usual place), else at the offset the locator gives
void _readZip64Eocd(
    SeekableInStream s, ZipEocd e, int locatorPos, int z64Offset) {
  final b = Uint8List(kZip64EocdSize);
  final candidates = <int>[];
  if (locatorPos >= kZip64EocdSize) candidates.add(locatorPos - kZip64EocdSize);
  candidates.add(z64Offset);
  for (final p in candidates) {
    if (p < 0 || p + kZip64EocdSize > s.length) continue;
    s.position = p;
    if (readFully(s, b, 0, kZip64EocdSize) != kZip64EocdSize) continue;
    if (getUint32LE(b, 0) != ZipSig.zip64Eocd) continue;
    e.isZip64 = true;
    e.zip64Pos = p;
    // the Zip64 values win when both are given
    e.thisDisk = getUint32LE(b, 16);
    e.cdDisk = getUint32LE(b, 20);
    e.numEntries = getUint64LE(b, 32);
    e.cdSize = getUint64LE(b, 40);
    e.cdOffset = getUint64LE(b, 48);
    return;
  }
}

/// Parses the central directory records in [cd] (read from the archive).
/// Returns the items; [cdError] is set when a record is malformed (the
/// items before it are kept).
List<ZipItem> parseCentralDirectory(
    Uint8List cd, int codePage, void Function() cdError) {
  final items = <ZipItem>[];
  var p = 0;
  while (p + 4 <= cd.length) {
    final sig = getUint32LE(cd, p);
    if (sig != ZipSig.central) {
      // digital signature (0x05054b50) or the end records
      if (sig != 0x05054b50 && sig != ZipSig.zip64Eocd && sig != ZipSig.eocd) {
        cdError();
      }
      break;
    }
    if (p + kCentralHeaderSize > cd.length) {
      cdError();
      break;
    }
    final it = ZipItem()
      ..versionMadeBy = cd[p + 4] | (cd[p + 5] << 8)
      ..versionNeeded = cd[p + 6] | (cd[p + 7] << 8)
      ..flags = cd[p + 8] | (cd[p + 9] << 8)
      ..method = cd[p + 10] | (cd[p + 11] << 8)
      ..dosTime = getUint32LE(cd, p + 12)
      ..crc = getUint32LE(cd, p + 16)
      ..packSize = getUint32LE(cd, p + 20)
      ..size = getUint32LE(cd, p + 24)
      ..disk = cd[p + 34] | (cd[p + 35] << 8)
      ..internalAttr = cd[p + 36] | (cd[p + 37] << 8)
      ..externalAttr = getUint32LE(cd, p + 38)
      ..localOffset = getUint32LE(cd, p + 42);
    final nameLen = cd[p + 28] | (cd[p + 29] << 8);
    final extraLen = cd[p + 30] | (cd[p + 31] << 8);
    final commentLen = cd[p + 32] | (cd[p + 33] << 8);
    var q = p + kCentralHeaderSize;
    if (q + nameLen + extraLen + commentLen > cd.length) {
      cdError();
      break;
    }
    it.nameBytes = Uint8List.fromList(cd.sublist(q, q + nameLen));
    q += nameLen;
    it.centralExtra = Uint8List.fromList(cd.sublist(q, q + extraLen));
    q += extraLen;
    it.comment = Uint8List.fromList(cd.sublist(q, q + commentLen));
    q += commentLen;
    it.parseExtra(it.centralExtra, false);
    decodeItemName(it, codePage);
    items.add(it);
    p = q;
  }
  return items;
}

/// Sets [ZipItem.name] from the name bytes.
void decodeItemName(ZipItem it, int codePage) {
  if (it.isUtf8) {
    it.name = decodeZipString(it.nameBytes, ZipCodePage.utf8);
  } else {
    it.name = decodeZipString(it.nameBytes, codePage);
  }
}

/// The fields of a local header.
class ZipLocalHeader {
  int versionNeeded = 0;
  int flags = 0;
  int method = 0;
  int dosTime = 0;
  int crc = 0;
  int packSize = 0;
  int size = 0;
  Uint8List nameBytes = Uint8List(0);
  Uint8List extra = Uint8List(0);

  /// Total size of the header (fixed part, name, extra).
  int get headerSize => kLocalHeaderSize + nameBytes.length + extra.length;

  /// Parses the 30 fixed bytes of [b] at [o] (signature included); false
  /// when the signature does not match. The name and extra lengths are
  /// returned by [nameLen] and [extraLen].
  bool parseFixed(Uint8List b, int o) {
    if (getUint32LE(b, o) != ZipSig.local) return false;
    versionNeeded = b[o + 4] | (b[o + 5] << 8);
    flags = b[o + 6] | (b[o + 7] << 8);
    method = b[o + 8] | (b[o + 9] << 8);
    dosTime = getUint32LE(b, o + 10);
    crc = getUint32LE(b, o + 14);
    packSize = getUint32LE(b, o + 18);
    size = getUint32LE(b, o + 22);
    _nameLen = b[o + 26] | (b[o + 27] << 8);
    _extraLen = b[o + 28] | (b[o + 29] << 8);
    return true;
  }

  int _nameLen = 0;
  int _extraLen = 0;
  int get nameLen => _nameLen;
  int get extraLen => _extraLen;

  /// An item made of this header (for archives read without their central
  /// directory).
  ZipItem toItem(int codePage) {
    final it = ZipItem()
      ..fromCentral = false
      ..versionNeeded = versionNeeded
      ..flags = flags
      ..method = method
      ..dosTime = dosTime
      ..crc = crc
      ..packSize = packSize
      ..size = size
      ..nameBytes = nameBytes
      ..localExtra = extra;
    it.parseExtra(extra, true);
    decodeItemName(it, codePage);
    return it;
  }
}

/// Reads the local header at [pos] of [s]; null when it is not one.
ZipLocalHeader? readLocalHeader(SeekableInStream s, int pos) {
  if (pos < 0 || pos + kLocalHeaderSize > s.length) return null;
  final b = Uint8List(kLocalHeaderSize);
  s.position = pos;
  if (readFully(s, b, 0, kLocalHeaderSize) != kLocalHeaderSize) return null;
  final h = ZipLocalHeader();
  if (!h.parseFixed(b, 0)) return null;
  final rest = Uint8List(h.nameLen + h.extraLen);
  if (readFully(s, rest, 0, rest.length) != rest.length) return null;
  h.nameBytes = Uint8List.sublistView(rest, 0, h.nameLen);
  h.extra = Uint8List.sublistView(rest, h.nameLen);
  return h;
}

/// A sequential input with a position and a push back buffer: decoders
/// read ahead, and the bytes they did not use are given back with
/// [unread] so that the next header is read from the right place.
class ZipSeqInput implements InStream {
  final InStream _base;
  Uint8List _pb = Uint8List(0);
  int _pbPos = 0;

  /// Bytes consumed so far (read minus unread).
  int pos = 0;
  bool _eof = false;

  ZipSeqInput(this._base);

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0) return 0;
    final avail = _pb.length - _pbPos;
    if (avail > 0) {
      final n = avail < len ? avail : len;
      buf.setRange(off, off + n, _pb, _pbPos);
      _pbPos += n;
      pos += n;
      return n;
    }
    if (_eof) return 0;
    final n = _base.read(buf, off, len);
    if (n == 0) _eof = true;
    pos += n;
    return n;
  }

  /// Gives back [len] bytes of [data] at [off]: they are read again next.
  void unread(Uint8List data, int off, int len) {
    if (len <= 0) return;
    final rest = _pb.length - _pbPos;
    final nb = Uint8List(len + rest);
    nb.setRange(0, len, data, off);
    nb.setRange(len, len + rest, _pb, _pbPos);
    _pb = nb;
    _pbPos = 0;
    pos -= len;
  }

  /// Skips [n] bytes; returns the number skipped.
  int skip(int n) {
    final buf = Uint8List(n < (1 << 16) ? n : (1 << 16));
    var done = 0;
    while (done < n) {
      final want = n - done < buf.length ? n - done : buf.length;
      final r = read(buf, 0, want);
      if (r == 0) break;
      done += r;
    }
    return done;
  }

  /// Reads exactly [len] bytes; false at the end of the input (the bytes
  /// read are given back).
  bool readExact(Uint8List buf, int off, int len) {
    final n = readFully(this, buf, off, len);
    if (n == len) return true;
    unread(buf, off, n);
    return false;
  }
}

/// What [ZipSeqReader.next] found.
enum ZipSeqResult { item, centralDirectory, end, headersError }

/// Reads local headers one after the other from a [ZipSeqInput].
class ZipSeqReader {
  final ZipSeqInput input;
  final int codePage;

  /// Set when the first header is a spanned archive marker.
  bool spanMarker = false;

  ZipSeqReader(this.input, this.codePage);

  /// Reads the next local header into a new item ([item] result), or
  /// stops at the central directory, at the end of the input, or at bytes
  /// that are no header.
  (ZipSeqResult, ZipItem?) next() {
    final b = Uint8List(kLocalHeaderSize);
    final start = input.pos;
    final n = readFully(input, b, 0, 4);
    if (n < 4) {
      input.unread(b, 0, n);
      return (ZipSeqResult.end, null);
    }
    var sig = getUint32LE(b, 0);
    if (start == 0 &&
        (sig == ZipSig.spanMarker || sig == ZipSig.tempSpanMarker)) {
      spanMarker = true;
      if (readFully(input, b, 0, 4) < 4) return (ZipSeqResult.end, null);
      sig = getUint32LE(b, 0);
    }
    if (sig == ZipSig.central ||
        sig == ZipSig.eocd ||
        sig == ZipSig.zip64Eocd) {
      input.unread(b, 0, 4);
      return (ZipSeqResult.centralDirectory, null);
    }
    if (sig != ZipSig.local) {
      input.unread(b, 0, 4);
      return (ZipSeqResult.headersError, null);
    }
    final headerPos = input.pos - 4;
    if (!input.readExact(b, 4, kLocalHeaderSize - 4)) {
      return (ZipSeqResult.end, null);
    }
    final h = ZipLocalHeader()..parseFixed(b, 0);
    final rest = Uint8List(h.nameLen + h.extraLen);
    if (!input.readExact(rest, 0, rest.length)) {
      return (ZipSeqResult.end, null);
    }
    h.nameBytes = Uint8List.fromList(rest.sublist(0, h.nameLen));
    h.extra = Uint8List.fromList(rest.sublist(h.nameLen));
    final it = h.toItem(codePage);
    it.localPos = headerPos;
    it.localOffset = headerPos;
    it.dataPos = input.pos;
    return (ZipSeqResult.item, it);
  }

  /// Reads the data descriptor after the data of [it] (whose data was
  /// consumed, [ZipItem.packSize] being its size) and sets the CRC and the
  /// sizes. The signature is optional; the sizes are 8 bytes when the item
  /// has a Zip64 extra field or when that is what matches [packSize].
  void readDescriptor(ZipItem it, {int? packSize}) {
    final b = Uint8List(24);
    final n = readFully(input, b, 0, 24);
    var p = 0;
    if (n >= 4 && getUint32LE(b, 0) == ZipSig.descriptor) p = 4;
    final ps = packSize ?? it.packSize;
    bool is64;
    if (it.zip64) {
      is64 = true;
    } else if (p + 12 <= n && getUint32LE(b, p + 4) == (ps & 0xFFFFFFFF)) {
      is64 = false;
      // a 64 bit form whose low half matches: prefer it when the high
      // half is zero and the next header does not start 8 bytes earlier
      if (p + 20 <= n &&
          getUint32LE(b, p + 8) == 0 &&
          getUint64LE(b, p + 4) == ps &&
          !_isHeaderSig(b, p + 12, n)) {
        is64 = true;
      }
    } else {
      is64 = p + 20 <= n && getUint64LE(b, p + 4) == ps;
    }
    final size = is64 ? p + 20 : p + 12;
    if (size > n) {
      it.truncated = true;
      input.unread(b, 0, n);
      return;
    }
    it.crc = getUint32LE(b, p);
    if (is64) {
      it.packSize = getUint64LE(b, p + 4);
      it.size = getUint64LE(b, p + 12);
    } else {
      it.packSize = getUint32LE(b, p + 4);
      it.size = getUint32LE(b, p + 8);
    }
    it.descriptorSize = size;
    input.unread(b, size, n - size);
  }

  static bool _isHeaderSig(Uint8List b, int p, int n) {
    if (p + 4 > n) return false;
    final s = getUint32LE(b, p);
    return s == ZipSig.local || s == ZipSig.central || s == ZipSig.eocd;
  }
}

/// The stored data of an item of unknown size (data descriptor, no
/// central directory): the bytes up to a data descriptor signature whose
/// compressed size field matches the number of bytes before it (as
/// libarchive does). The descriptor itself is left in the input.
class StoredScanInStream implements InStream {
  final ZipSeqInput _in;
  final bool _zip64;
  final Uint8List _buf = Uint8List(1 << 16);
  int _pos = 0;
  int _lim = 0;
  int _done = 0;
  bool _end = false;
  bool _eof = false;

  StoredScanInStream(this._in, this._zip64);

  /// Bytes of data returned.
  int get size => _done;

  /// Set when the input ended before a descriptor was found.
  bool get truncated => _eof && !_end;

  // keeps at least 24 bytes after _pos in the buffer when possible
  void _fill() {
    if (_pos > 0) {
      _buf.setRange(0, _lim - _pos, _buf, _pos);
      _lim -= _pos;
      _pos = 0;
    }
    while (!_eof && _lim < _buf.length) {
      final n = _in.read(_buf, _lim, _buf.length - _lim);
      if (n == 0) {
        _eof = true;
        break;
      }
      _lim += n;
      if (_lim >= 24) break;
    }
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (_end || len <= 0) return 0;
    if (_lim - _pos < 24) _fill();
    var i = _pos;
    final lim = _lim;
    var emitEnd = lim - 23;
    if (_eof) emitEnd = lim;
    if (emitEnd <= _pos && !_eof) {
      emitEnd = _pos;
    }
    // look for the descriptor
    while (i < emitEnd && i - _pos < len) {
      if (_buf[i] == 0x50 &&
          i + 16 <= lim &&
          _buf[i + 1] == 0x4B &&
          _buf[i + 2] == 7 &&
          _buf[i + 3] == 8) {
        final at = _done + (i - _pos);
        final ok = _zip64
            ? i + 24 <= lim && getUint64LE(_buf, i + 8) == at
            : getUint32LE(_buf, i + 8) == (at & 0xFFFFFFFF);
        if (ok) {
          _end = true;
          break;
        }
      }
      i++;
    }
    final n = i - _pos;
    if (n > 0) {
      buf.setRange(off, off + n, _buf, _pos);
      _pos += n;
      _done += n;
    }
    if (_end) {
      // the descriptor and what follows go back to the input
      _in.unread(_buf, _pos, _lim - _pos);
      _pos = _lim;
      if (n == 0) return 0;
      return n;
    }
    if (n == 0 && _eof && _pos >= _lim) return 0;
    if (n == 0) return read(buf, off, len);
    return n;
  }
}
