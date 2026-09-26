// Tar reader: the header parsing of libarchive's
// archive_read_support_format_tar.c (BSD 2-clause, see LICENSE), reading
// from a synchronous stream: v7, ustar, GNU (long names 'L' and 'K', old
// sparse 'S' headers, base-256 numbers, volume headers), POSIX pax ('x' and
// 'g' extended headers) and the GNU sparse formats 0.0, 0.1 and 1.0.
//
// libarchive reads ahead in a buffer and "consumes" bytes; the port reads
// whole records instead. The special headers ('x', 'L', 'K'...) are small
// (limited as in libarchive), so they are read into memory and parsed from
// there. The reader works on a SeekableInStream (Open: data is skipped by
// seeking) or on a sequential InStream (OpenSeq: data is read and dropped,
// or given to the caller by [TarReader.dataStream]).

import 'dart:convert';
import 'dart:typed_data';

import '../../io/streams.dart';
import 'tar_header.dart';

/// One sparse data block of an item: [length] bytes of the file at
/// [offset], stored in order in the archive.
class TarSparseBlock {
  final int offset;
  final int length;
  const TarSparseBlock(this.offset, this.length);
}

/// A time of a pax or ustar header: seconds since 1970 and nanoseconds.
class TarTime {
  final int sec;
  final int ns;
  const TarTime(this.sec, this.ns);
  int toFileTime() => tarTimeToFileTime(sec, ns);
}

/// The entry that libarchive's tar_read_header builds (archive_entry plus
/// the struct tar fields of the item), with the archive positions the
/// handler needs.
class TarItem {
  String name = '';
  String linkName = '';
  String user = '';
  String group = '';

  /// The mode field (permission bits, and the type bits some writers set).
  int mode = 0;
  int uid = 0;
  int gid = 0;

  /// Size of the file on disk (disk_size).
  int size = 0;

  /// Bytes of data in the archive after the headers (and after the sparse
  /// map of GNU sparse 1.0): entry_bytes_remaining.
  int packSize = 0;

  int typeFlag = TarType.regular;
  TarFormat format = TarFormat.v7;

  TarTime? mTime;
  TarTime? aTime;
  TarTime? cTime;

  int devMajor = -1;
  int devMinor = -1;

  /// Offset of the first header record of the item (its 'x', 'L', 'K'
  /// headers included).
  int headerPos = 0;

  /// Offset of the item's main header record.
  int mainHeaderPos = 0;

  /// Offset of the data (after the GNU sparse 1.0 map).
  int dataPos = 0;

  /// Offset of the next header: the data rounded up to 512 bytes.
  int endPos = 0;

  /// The data blocks of a sparse file, in archive order; null when the
  /// item is not sparse.
  List<TarSparseBlock>? sparse;

  /// true when the archive ends inside the item's data.
  bool truncated = false;

  /// Header properties for kpidCharacts.
  bool paxSeen = false;
  bool nameIsUtf8 = false;
  bool nameIsAscii = true;
  bool gnuLongName = false;
  bool gnuLongLink = false;
  final List<String> paxKeys = [];

  /// The file type bits (S_IF*), from the type flag as in header_common.
  int get fileType {
    switch (typeFlag) {
      case TarType.hardLink:
        return PosixMode.regular;
      case TarType.symLink:
        return PosixMode.symLink;
      case TarType.charDevice:
        return PosixMode.charDevice;
      case TarType.blockDevice:
        return PosixMode.blockDevice;
      case TarType.directory:
      case TarType.gnuDumpDir:
        return PosixMode.directory;
      case TarType.fifo:
        return PosixMode.fifo;
    }
    if (isDir) return PosixMode.directory;
    return PosixMode.regular;
  }

  bool get isHardLink => typeFlag == TarType.hardLink;
  bool get isSymLink => typeFlag == TarType.symLink;

  /// "Regular" entries whose name ends with '/' are directories
  /// (archive_read_format_tar_read_header).
  bool get isDir =>
      typeFlag == TarType.directory ||
      typeFlag == TarType.gnuDumpDir ||
      (_isRegularType && name.endsWith('/'));

  bool get _isRegularType =>
      typeFlag != TarType.hardLink &&
      typeFlag != TarType.symLink &&
      typeFlag != TarType.charDevice &&
      typeFlag != TarType.blockDevice &&
      typeFlag != TarType.directory &&
      typeFlag != TarType.fifo &&
      typeFlag != TarType.gnuDumpDir;

  /// The data stored for the item: regular files (and hard links with a
  /// pax body); links, devices and directories have none.
  bool get hasData => packSize > 0;

  /// Size of the data blocks in the archive (packSize rounded up to 512).
  int get packSizeAligned => (packSize + 511) & ~511;
}

/// Result of [TarReader.readItem].
enum TarReadResult {
  /// An item was read.
  item,

  /// The end marker (a zero block) was found.
  end,

  /// The stream ended at a block boundary without an end marker.
  eof,

  /// The stream ended inside a header or inside a sequence of headers.
  unexpectedEnd,

  /// A header with a bad checksum or broken extended headers.
  headersError,
}

// Sanity limits of libarchive
const int _pathnameLimit = 1048576;
const int _gunameLimit = 65536;
const int _sparseMapLimit = 8 * 1048576;
const int _extSizeLimit = 1 << 26; // libarchive allows 1 GiB; memory is small
const int _entryLimit = 0xfffffffffffffff;

/// struct tar: the state of the reader.
class TarReader {
  final InStream _s;
  final SeekableInStream? _seek;
  final int? _length;

  /// Position in the archive of the next byte read.
  int pos = 0;

  // one block of look-ahead (the hard link heuristic peeks at the next header)
  final Uint8List _ahead = Uint8List(kTarBlockSize);
  int _aheadLen = 0;

  final Uint8List _h = Uint8List(kTarBlockSize);
  final Uint8List _skipBuf = Uint8List(1 << 14);

  /// The archive format as libarchive tracks it (archive_format), updated
  /// by every header.
  TarFormat archiveFormat = TarFormat.v7;
  bool _formatSet = false;

  /// Warnings met while reading (malformed pax records and such).
  bool warning = false;

  /// Number of all-zero blocks read at the end marker.
  int numZeroBlocks = 0;

  TarReader(InStream s, {int startPos = 0})
      : _s = s,
        _seek = s is SeekableInStream ? s : null,
        _length = s is SeekableInStream ? s.length : null,
        pos = startPos;

  bool get isSeekable => _seek != null;

  // __archive_read_ahead + __archive_read_consume for n bytes
  int _read(Uint8List buf, int off, int len) {
    var done = 0;
    if (_aheadLen > 0) {
      final n = len < _aheadLen ? len : _aheadLen;
      buf.setRange(off, off + n, _ahead);
      if (n < _aheadLen) {
        _ahead.setRange(0, _aheadLen - n, _ahead, n);
      }
      _aheadLen -= n;
      done = n;
    }
    if (done < len) done += readFully(_s, buf, off + done, len - done);
    pos += done;
    return done;
  }

  /// Reads up to [len] bytes of item data (for extraction in OpenSeq mode).
  int readData(Uint8List buf, int off, int len) => _read(buf, off, len);

  /// Skips [n] bytes; returns the number skipped (less at the end).
  int skip(int n) {
    if (n <= 0) return 0;
    var done = 0;
    if (_aheadLen > 0) {
      final k = n < _aheadLen ? n : _aheadLen;
      if (k < _aheadLen) _ahead.setRange(0, _aheadLen - k, _ahead, k);
      _aheadLen -= k;
      done = k;
      pos += k;
    }
    final seek = _seek;
    if (seek != null) {
      final avail = _length! - seek.position;
      var k = n - done;
      if (k > avail) k = avail;
      seek.position = seek.position + k;
      pos += k;
      return done + k;
    }
    final tmp = _skipBuf;
    while (done < n) {
      final want = n - done < tmp.length ? n - done : tmp.length;
      final k = readFully(_s, tmp, 0, want);
      pos += k;
      done += k;
      if (k < want) break;
    }
    return done;
  }

  /// Positions a seekable reader at [p].
  void seekTo(int p) {
    _aheadLen = 0;
    _seek!.position = p;
    pos = p;
  }

  // peeks at the next block without consuming it; null at the end
  Uint8List? _peekBlock() {
    if (_aheadLen < kTarBlockSize) {
      final n = readFully(_s, _ahead, _aheadLen, kTarBlockSize - _aheadLen);
      _aheadLen += n;
      if (_aheadLen < kTarBlockSize) return null;
    }
    return _ahead;
  }

  void _setFormat(TarFormat f) {
    archiveFormat = f;
    _formatSet = true;
  }

  // per item state (tar_reset_header_state)
  Uint8List? _paxPath;
  Uint8List? _paxPathOverride;
  Uint8List? _paxLinkPath;
  Uint8List? _paxUname;
  Uint8List? _paxGname;
  bool _paxHdrcharsetUtf8 = true;
  String? _longName;
  Uint8List? _longNameBytes;
  String? _longLink;
  TarTime? _paxMTime;
  TarTime? _paxATime;
  TarTime? _paxCTime;
  int? _paxUid;
  int? _paxGid;
  int? _paxDevMajor;
  int? _paxDevMinor;

  // size fields (TAR_SIZE_*)
  bool _hasPaxSize = false;
  bool _hasGnuSparseRealSize = false;
  bool _hasGnuSparseSize = false;
  bool _hasSchilySparseRealSize = false;
  int _paxSize = 0;
  int _gnuSparseRealSize = 0;
  int _gnuSparseSize = 0;
  int _schilySparseRealSize = 0;

  // sparse state
  List<TarSparseBlock>? _sparseList;
  int _sparseOffset = -1;
  int _sparseNumBytes = -1;
  int _sparseGnuMajor = 0;
  int _sparseGnuMinor = 0;
  bool _sparseGnuAttributesSeen = false;

  // tar_reset_header_state
  void _resetHeaderState() {
    _paxHdrcharsetUtf8 = true;
    _sparseGnuAttributesSeen = false;
    _paxPath = null;
    _paxPathOverride = null;
    _paxLinkPath = null;
    _paxUname = null;
    _paxGname = null;
    _longName = null;
    _longNameBytes = null;
    _longLink = null;
    _paxMTime = null;
    _paxATime = null;
    _paxCTime = null;
    _paxUid = null;
    _paxGid = null;
    _paxDevMajor = null;
    _paxDevMinor = null;
  }

  // gnu_add_sparse_entry
  bool _gnuAddSparseEntry(int offset, int remaining) {
    if (remaining == 0) return true;
    if (remaining < 0 || offset < 0 || offset > _entryLimit - remaining) {
      return false;
    }
    (_sparseList ??= []).add(TarSparseBlock(offset, remaining));
    return true;
  }

  /// archive_read_format_tar_read_header + tar_read_header: reads the
  /// headers of the next item into [item]. At the end, [pos] is the
  /// position of the item data (or of the end of the archive).
  TarReadResult readItem(TarItem item) {
    _sparseList = null;
    _hasPaxSize = false;
    _hasGnuSparseRealSize = false;
    _hasGnuSparseSize = false;
    _hasSchilySparseRealSize = false;
    _resetHeaderState();

    const seenA = 1, seenG = 2, seenK = 4, seenL = 8, seenV = 16, seenX = 32;
    var seenHeaders = 0;
    var eofFatal = false;
    item.headerPos = pos;
    final h = _h;

    for (;;) {
      final headerStart = pos;
      final bytes = _read(h, 0, kTarBlockSize);
      if (bytes == 0) {
        return eofFatal ? TarReadResult.unexpectedEnd : TarReadResult.eof;
      }
      if (bytes < kTarBlockSize) {
        // a short block at the end: it is not part of the archive
        pos = headerStart;
        return TarReadResult.unexpectedEnd;
      }
      if (h[0] == 0 && tarBlockIsNull(h)) {
        // end of archive: 7-Zip counts all the zero blocks that follow
        numZeroBlocks = 1;
        for (;;) {
          final p = _peekBlock();
          if (p == null || !tarBlockIsNull(p)) break;
          _aheadLen = 0;
          pos += kTarBlockSize;
          numZeroBlocks++;
        }
        pos = headerStart + numZeroBlocks * kTarBlockSize;
        return TarReadResult.end;
      }
      if (!tarChecksumOk(h)) {
        pos = headerStart;
        return TarReadResult.headersError;
      }

      final typeFlag = h[TarHeader.typeflagOffset];
      TarReadResult? err;
      switch (typeFlag) {
        case TarType.solarisAcl:
          if ((seenHeaders & seenA) != 0) return TarReadResult.headersError;
          seenHeaders |= seenA;
          _setFormat(TarFormat.pax);
          item.paxSeen = true;
          err = _readBody(h, null);
        case TarType.paxGlobal:
          if ((seenHeaders & seenG) != 0) return TarReadResult.headersError;
          seenHeaders |= seenG;
          _setFormat(TarFormat.pax);
          err = _headerPaxRecords(h, item, true);
          // a global header is not part of the item
          item.headerPos = pos;
        case TarType.gnuLongLink:
          if ((seenHeaders & seenK) != 0) warning = true;
          seenHeaders |= seenK;
          _setFormat(TarFormat.gnu);
          final out = <Uint8List>[];
          err = _readBody(h, out);
          if (err == null && out.isNotEmpty) {
            final b = out[0];
            _longLink = tarDecodeString(b, 0, tarStrLen(b, 0, b.length));
            item.gnuLongLink = true;
          }
        case TarType.gnuLongName:
          if ((seenHeaders & seenL) != 0) warning = true;
          seenHeaders |= seenL;
          _setFormat(TarFormat.gnu);
          final out = <Uint8List>[];
          err = _readBody(h, out);
          if (err == null && out.isNotEmpty) {
            final b = out[0];
            final n = tarStrLen(b, 0, b.length);
            _longNameBytes = Uint8List.sublistView(b, 0, n);
            _longName = tarDecodeString(b, 0, n);
            item.gnuLongName = true;
          }
        case TarType.gnuVolume:
          if ((seenHeaders & seenV) != 0) warning = true;
          seenHeaders |= seenV;
          _setFormat(TarFormat.gnu);
          err = _headerVolume(h);
          item.headerPos = pos;
        case TarType.paxSun:
        case TarType.paxLocal:
          if ((seenHeaders & seenX) != 0) return TarReadResult.headersError;
          seenHeaders |= seenX;
          _setFormat(TarFormat.pax);
          item.paxSeen = true;
          err = _headerPaxRecords(h, item, false);
        default:
          item.mainHeaderPos = headerStart;
          if (tarIsGnuMagic(h)) {
            _setFormat(TarFormat.gnu);
            item.format = TarFormat.gnu;
            final r = _headerGnutar(h, item);
            if (r != null) return r;
          } else if (tarIsUstarMagic(h)) {
            if (archiveFormat != TarFormat.pax || !_formatSet) {
              _setFormat(TarFormat.ustar);
            }
            item.format = item.paxSeen ? TarFormat.pax : TarFormat.ustar;
            final r = _headerUstar(h, item);
            if (r != null) return r;
          } else {
            _setFormat(TarFormat.v7);
            item.format = item.paxSeen ? TarFormat.pax : TarFormat.v7;
            final r = _headerOldTar(h, item);
            if (r != null) return r;
          }

          // Reconcile GNU sparse attributes
          if (_sparseGnuAttributesSeen) {
            if (item.typeFlag != TarType.gnuSparse &&
                item.typeFlag != TarType.regular) {
              warning = true;
            } else if (_sparseGnuMajor == 1 && _sparseGnuMinor == 0) {
              final bytesRead = _gnuSparse10Read(item);
              if (bytesRead < 0) return TarReadResult.headersError;
              item.packSize -= bytesRead;
            } else if (_sparseGnuMajor == 0 &&
                (_sparseGnuMinor == 0 || _sparseGnuMinor == 1)) {
              // sparse map already parsed from the 'x' header
            } else {
              warning = true;
            }
          }
          item.sparse = _sparseList;
          _sparseList = null;
          item.dataPos = pos;
          item.endPos = pos + item.packSizeAligned;
          return TarReadResult.item;
      }
      if (err != null) return err;
      if ((seenHeaders & ~seenV & ~seenG) != 0) eofFatal = true;
    }
  }

  // header_volume: skips the body of a 'V' header
  TarReadResult? _headerVolume(Uint8List h) {
    final size = tarAtol(h, TarHeader.sizeOffset, 12);
    if (size < 0 || size > _pathnameLimit) return TarReadResult.headersError;
    final toConsume = (size + 511) & ~511;
    if (skip(toConsume) != toConsume) return TarReadResult.unexpectedEnd;
    return null;
  }

  // read_body_to_string: the body of a special header, padded to 512 bytes.
  // Stores it in [out] when [out] is not null and it is not too large.
  TarReadResult? _readBody(Uint8List h, List<Uint8List>? out) {
    final size = tarAtol(h, TarHeader.sizeOffset, 12);
    if (size < 0 || size > _entryLimit) return TarReadResult.headersError;
    final toConsume = (size + 511) & ~511;
    if (size > _pathnameLimit || out == null) {
      if (size > _pathnameLimit) warning = true;
      if (skip(toConsume) != toConsume) return TarReadResult.unexpectedEnd;
      return null;
    }
    final buf = Uint8List(toConsume);
    if (_read(buf, 0, toConsume) != toConsume) {
      return TarReadResult.unexpectedEnd;
    }
    out.add(Uint8List.sublistView(buf, 0, size));
    return null;
  }

  // header_pax_records (global: header_pax_global, else
  // header_pax_extension)
  TarReadResult? _headerPaxRecords(Uint8List h, TarItem item, bool global) {
    final extSize = tarAtol(h, TarHeader.sizeOffset, 12);
    if (extSize < 0 || extSize > _entryLimit) {
      return TarReadResult.headersError;
    }
    if (extSize == 0) return TarReadResult.headersError;
    final toConsume = (extSize + 511) & ~511;
    if (extSize > _extSizeLimit) {
      warning = true;
      if (skip(toConsume) != toConsume) return TarReadResult.unexpectedEnd;
      return null;
    }
    final body = Uint8List(toConsume);
    if (_read(body, 0, toConsume) != toConsume) {
      return TarReadResult.unexpectedEnd;
    }
    var p = 0;
    final end = extSize;
    while (p < end) {
      // size of the attribute
      var lineLength = 0;
      var q = p;
      for (;;) {
        if (q >= end) {
          warning = true;
          return null;
        }
        final c = body[q];
        if (c == 0x20) {
          q++;
          break;
        }
        if (c < 0x30 || c > 0x39) {
          warning = true;
          return null;
        }
        lineLength = lineLength * 10 + (c - 0x30);
        if (lineLength > 99999999) {
          warning = true;
          return null;
        }
        q++;
      }
      if (lineLength > end - p) {
        warning = true;
        return null;
      }
      final lineEnd = p + lineLength;
      // name of the attribute
      if (q >= lineEnd || body[q] == 0x3D) {
        warning = true;
        return null;
      }
      final nameStart = q;
      while (q < lineEnd && body[q] != 0x3D) {
        q++;
      }
      if (q >= lineEnd) {
        warning = true;
        return null;
      }
      final key = latin1.decode(Uint8List.sublistView(body, nameStart, q));
      q++; // '='
      if (lineEnd - q == 0) {
        warning = true;
        return null;
      }
      if (body[lineEnd - 1] != 0x0A) {
        warning = true;
        return null;
      }
      final value = Uint8List.sublistView(body, q, lineEnd - 1);
      if (!global) {
        final r = _paxAttribute(item, key, value);
        if (r != null) return r;
      }
      p = lineEnd;
    }
    if (global) return null;

    // pathname, uname, gname and linkpath are decoded once the charset is
    // known (hdrcharset)
    String dec(Uint8List b) =>
        _paxHdrcharsetUtf8 ? tarDecodeString(b, 0, b.length) : latin1.decode(b);
    final pas = (_paxPathOverride != null && _paxPathOverride!.isNotEmpty)
        ? _paxPathOverride
        : ((_paxPath != null && _paxPath!.isNotEmpty) ? _paxPath : null);
    if (pas != null) {
      item.name = dec(pas);
      _setNameCharset(item, pas);
    }
    if (_paxUname != null && _paxUname!.isNotEmpty) item.user = dec(_paxUname!);
    if (_paxGname != null && _paxGname!.isNotEmpty) {
      item.group = dec(_paxGname!);
    }
    if (_paxLinkPath != null && _paxLinkPath!.isNotEmpty) {
      item.linkName = dec(_paxLinkPath!);
    }
    return null;
  }

  // pax_attribute_read_number
  int? _paxNumber(Uint8List v) {
    if (v.length > 64) {
      warning = true;
      return null;
    }
    final r = tarAtol10(v, 0, v.length);
    if (r < 0 || r == 0x7FFFFFFFFFFFFFFF) {
      warning = true;
      return null;
    }
    return r;
  }

  // pax_attribute_read_time
  TarTime? _paxTimeValue(Uint8List v) {
    if (v.length > 128) {
      warning = true;
      return null;
    }
    final t = tarPaxTime(v, 0, v.length);
    if (t == null) {
      warning = true;
      return null;
    }
    return TarTime(t.$1, t.$2);
  }

  // pax_attribute: one key=value record of an 'x' header
  TarReadResult? _paxAttribute(TarItem item, String key, Uint8List value) {
    item.paxKeys.add(key);
    if (key.startsWith('GNU.')) {
      final k = key.substring(4);
      if (k == 'sparse') {
        _sparseGnuAttributesSeen = true;
      } else if (k.startsWith('sparse.')) {
        _sparseGnuAttributesSeen = true;
        final s = k.substring(7);
        switch (s) {
          case 'numblocks':
            _sparseOffset = -1;
            _sparseNumBytes = -1;
            _sparseGnuMajor = 0;
            _sparseGnuMinor = 0;
          case 'offset':
            final t = _paxNumber(value);
            if (t != null) {
              _sparseOffset = t;
              if (_sparseNumBytes != -1) {
                if (!_gnuAddSparseEntry(_sparseOffset, _sparseNumBytes)) {
                  return TarReadResult.headersError;
                }
                _sparseOffset = -1;
                _sparseNumBytes = -1;
              }
            }
          case 'numbytes':
            final t = _paxNumber(value);
            if (t != null) {
              _sparseNumBytes = t;
              if (_sparseOffset != -1) {
                if (!_gnuAddSparseEntry(_sparseOffset, _sparseNumBytes)) {
                  return TarReadResult.headersError;
                }
                _sparseOffset = -1;
                _sparseNumBytes = -1;
              }
            }
          case 'size':
            final t = _paxNumber(value);
            if (t != null) {
              _gnuSparseSize = t;
              _hasGnuSparseSize = true;
            }
          case 'map':
            _sparseGnuMajor = 0;
            _sparseGnuMinor = 1;
            if (value.length > _sparseMapLimit) {
              warning = true;
            } else if (!_gnuSparse01Parse(value)) {
              warning = true;
            }
          case 'major':
            final t = _paxNumber(value);
            if (t != null && t >= 0 && t <= 10) _sparseGnuMajor = t;
          case 'minor':
            final t = _paxNumber(value);
            if (t != null && t >= 0 && t <= 10) _sparseGnuMinor = t;
          case 'name':
            if (value.length > _pathnameLimit) {
              warning = true;
            } else {
              _paxPathOverride = value;
            }
          case 'realsize':
            final t = _paxNumber(value);
            if (t != null) {
              _gnuSparseRealSize = t;
              _hasGnuSparseRealSize = true;
            }
        }
      }
      return null;
    }
    if (key.startsWith('SCHILY.')) {
      switch (key.substring(7)) {
        case 'devmajor':
          final t = _paxNumber(value);
          if (t != null) _paxDevMajor = t;
        case 'devminor':
          final t = _paxNumber(value);
          if (t != null) _paxDevMinor = t;
        case 'realsize':
          final t = _paxNumber(value);
          if (t != null) {
            _schilySparseRealSize = t;
            _hasSchilySparseRealSize = true;
          }
      }
      // SCHILY.xattr.*, SCHILY.acl.*, SCHILY.fflags... are not used
      return null;
    }
    switch (key) {
      case 'atime':
        _paxATime = _paxTimeValue(value);
      case 'ctime':
        _paxCTime = _paxTimeValue(value);
      case 'mtime':
        _paxMTime = _paxTimeValue(value);
      case 'gid':
        final t = _paxNumber(value);
        if (t != null) _paxGid = t;
      case 'gname':
        if (value.length > _gunameLimit) {
          warning = true;
        } else {
          _paxGname = value;
        }
      case 'uid':
        final t = _paxNumber(value);
        if (t != null) _paxUid = t;
      case 'uname':
        if (value.length > _gunameLimit) {
          warning = true;
        } else {
          _paxUname = value;
        }
      case 'hdrcharset':
        final s = latin1.decode(value);
        if (s == 'BINARY') {
          _paxHdrcharsetUtf8 = false;
        } else if (s == 'ISO-IR 10646 2000 UTF-8') {
          _paxHdrcharsetUtf8 = true;
        } else {
          warning = true;
        }
      case 'linkpath':
        if (value.length > _pathnameLimit) {
          warning = true;
        } else {
          _paxLinkPath = value;
        }
      case 'path':
        if (value.length > _pathnameLimit) {
          warning = true;
        } else {
          _paxPath = value;
        }
      case 'size':
        final t = _paxNumber(value);
        if (t != null) {
          _paxSize = t;
          _hasPaxSize = true;
        } else if (value.isNotEmpty) {
          return TarReadResult.headersError;
        }
    }
    return null;
  }

  // gnu_sparse_01_parse: "offset,size,offset,size..."
  bool _gnuSparse01Parse(Uint8List p) {
    var offset = -1;
    var start = 0;
    var length = p.length;
    var e = 0;
    for (;;) {
      e = start;
      while (length > 0 && p[e] != 0x2C) {
        if (p[e] < 0x30 || p[e] > 0x39) return false;
        e++;
        length--;
      }
      if (offset < 0) {
        offset = tarAtol10(p, start, e - start);
        if (offset < 0) return false;
      } else {
        final size = tarAtol10(p, start, e - start);
        if (size < 0) return false;
        if (!_gnuAddSparseEntry(offset, size)) return false;
        offset = -1;
      }
      if (length == 0) return true;
      start = e + 1;
      length--;
    }
  }

  // name, prefix and the charset flags for kpidCharacts
  void _setNameCharset(TarItem item, Uint8List bytes) {
    final nonAscii = tarHasNonAscii(bytes);
    item.nameIsAscii = !nonAscii;
    if (nonAscii) {
      try {
        const Utf8Decoder(allowMalformed: false).convert(bytes);
        item.nameIsUtf8 = true;
      } on FormatException {
        item.nameIsUtf8 = false;
      }
    }
  }

  String _field(Uint8List h, int off, int size) =>
      tarDecodeString(h, off, tarStrLen(h, off, size));

  // header_common
  TarReadResult? _headerCommon(Uint8List h, TarItem item) {
    item.mode = tarAtol(h, TarHeader.modeOffset, 8) & 0xFFFFFFFF;
    item.uid = _paxUid ?? tarAtol(h, TarHeader.uidOffset, 8);
    item.gid = _paxGid ?? tarAtol(h, TarHeader.gidOffset, 8);
    item.mTime = _paxMTime ?? TarTime(tarAtol(h, TarHeader.mtimeOffset, 12), 0);
    item.aTime = _paxATime;
    item.cTime = _paxCTime;

    // the size of the file on disk
    int diskSize;
    if (_hasGnuSparseRealSize) {
      diskSize = _gnuSparseRealSize;
    } else if (_hasGnuSparseSize && _sparseGnuMajor == 0) {
      diskSize = _gnuSparseSize;
    } else if (_hasSchilySparseRealSize) {
      diskSize = _schilySparseRealSize;
    } else if (_hasPaxSize) {
      diskSize = _paxSize;
    } else {
      diskSize = tarAtol(h, TarHeader.sizeOffset, 12);
    }
    if (diskSize < 0 || diskSize > _entryLimit) {
      return TarReadResult.headersError;
    }
    item.size = diskSize;

    // the size of the data in the archive
    int remaining;
    if (_hasGnuSparseSize && _sparseGnuMajor == 1) {
      remaining = _gnuSparseSize;
    } else if (_hasPaxSize) {
      remaining = _paxSize;
    } else {
      remaining = tarAtol(h, TarHeader.sizeOffset, 12);
    }
    if (remaining < 0 || remaining > _entryLimit) {
      return TarReadResult.headersError;
    }
    item.packSize = remaining;

    item.typeFlag = h[TarHeader.typeflagOffset];
    switch (item.typeFlag) {
      case TarType.hardLink:
        if (item.linkName.isEmpty) {
          item.linkName = _field(h, TarHeader.linknameOffset, 100);
        }
        // Hard links of old and GNU archives have no body; ustar ones have
        // one only when the next record is not a header (pax permits
        // bodies).
        if (item.size == 0) {
        } else if (archiveFormat == TarFormat.pax) {
        } else if (archiveFormat == TarFormat.v7 ||
            archiveFormat == TarFormat.gnu) {
          item.size = 0;
          item.packSize = 0;
        } else {
          final next = _peekAfter(item.packSize);
          if (next) {
            item.size = 0;
            item.packSize = 0;
          }
        }
      case TarType.symLink:
        if (item.linkName.isEmpty) {
          item.linkName = _field(h, TarHeader.linknameOffset, 100);
        }
        item.size = 0;
        item.packSize = 0;
      case TarType.charDevice:
      case TarType.blockDevice:
      case TarType.directory:
      case TarType.fifo:
        item.size = 0;
        item.packSize = 0;
    }
    return null;
  }

  // the "archive_read_format_tar_bid(a, 50) > 50" test of header_common:
  // true when the next record is a valid ustar header
  bool _peekAfter(int packSize) {
    final p = _peekBlock();
    if (p == null) return false;
    return tarBid(p) > 50;
  }

  // header_old_tar
  TarReadResult? _headerOldTar(Uint8List h, TarItem item) {
    if (_longName != null) {
      item.name = _longName!;
      _setNameCharset(item, _longNameBytes!);
    } else if (item.name.isEmpty) {
      final n = tarStrLen(h, 0, 100);
      item.name = tarDecodeString(h, 0, n);
      _setNameCharset(item, Uint8List.sublistView(h, 0, n));
    }
    if (_longLink != null) item.linkName = _longLink!;
    return _headerCommon(h, item);
  }

  // header_ustar
  TarReadResult? _headerUstar(Uint8List h, TarItem item) {
    if (_longName != null) {
      item.name = _longName!;
      _setNameCharset(item, _longNameBytes!);
    } else if (item.name.isEmpty) {
      final nl = tarStrLen(h, 0, 100);
      Uint8List bytes;
      if (h[TarHeader.prefixOffset] != 0) {
        final pl = tarStrLen(h, TarHeader.prefixOffset, TarHeader.prefixSize);
        final b = BytesBuilder(copy: false)
          ..add(Uint8List.sublistView(
              h, TarHeader.prefixOffset, TarHeader.prefixOffset + pl));
        if (h[TarHeader.prefixOffset + pl - 1] != 0x2F) b.addByte(0x2F);
        b.add(Uint8List.sublistView(h, 0, nl));
        bytes = b.toBytes();
      } else {
        bytes = Uint8List.sublistView(h, 0, nl);
      }
      item.name = tarDecodeString(bytes, 0, bytes.length);
      _setNameCharset(item, bytes);
    }
    if (_longLink != null) item.linkName = _longLink!;
    final r = _headerCommon(h, item);
    if (r != null) return r;
    if (item.user.isEmpty) item.user = _field(h, TarHeader.unameOffset, 32);
    if (item.group.isEmpty) item.group = _field(h, TarHeader.gnameOffset, 32);
    _readDev(h, item);
    return null;
  }

  void _readDev(Uint8List h, TarItem item) {
    if (item.typeFlag == TarType.charDevice ||
        item.typeFlag == TarType.blockDevice) {
      item.devMajor = _paxDevMajor ?? tarAtol(h, TarHeader.rdevmajorOffset, 8);
      item.devMinor = _paxDevMinor ?? tarAtol(h, TarHeader.rdevminorOffset, 8);
    }
  }

  // header_gnutar
  TarReadResult? _headerGnutar(Uint8List h0, TarItem item) {
    // the old sparse extension blocks reuse the header buffer
    final h = Uint8List.fromList(h0);
    if (_longName != null) {
      item.name = _longName!;
      _setNameCharset(item, _longNameBytes!);
    } else if (item.name.isEmpty) {
      final n = tarStrLen(h, 0, 100);
      item.name = tarDecodeString(h, 0, n);
      _setNameCharset(item, Uint8List.sublistView(h, 0, n));
    }
    if (_longLink != null) item.linkName = _longLink!;
    if (item.user.isEmpty) item.user = _field(h, TarHeader.unameOffset, 32);
    if (item.group.isEmpty) item.group = _field(h, TarHeader.gnameOffset, 32);
    _readDev(h, item);

    if (_paxATime == null) {
      final t = tarAtol(h, TarHeader.atimeOffset, 12);
      if (t > 0) _paxATime = TarTime(t, 0);
    }
    if (_paxCTime == null) {
      final t = tarAtol(h, TarHeader.ctimeOffset, 12);
      if (t > 0) _paxCTime = TarTime(t, 0);
    }
    if (h[TarHeader.gnuRealSizeOffset] != 0) {
      _gnuSparseRealSize = tarAtol(h, TarHeader.gnuRealSizeOffset, 12);
      _hasGnuSparseRealSize = true;
    }
    if (h[TarHeader.gnuSparseOffset] != 0) {
      final r = _gnuSparseOldRead(h);
      if (r != null) return r;
    }
    return _headerCommon(h, item);
  }

  // gnu_sparse_old_read
  TarReadResult? _gnuSparseOldRead(Uint8List h) {
    if (!_gnuSparseOldParse(h, TarHeader.gnuSparseOffset, 4)) {
      return TarReadResult.headersError;
    }
    if (h[TarHeader.gnuIsExtendedOffset] == 0) return null;
    final ext = Uint8List(kTarBlockSize);
    do {
      if (_read(ext, 0, kTarBlockSize) != kTarBlockSize) {
        return TarReadResult.unexpectedEnd;
      }
      if (!_gnuSparseOldParse(ext, 0, 21)) return TarReadResult.headersError;
    } while (ext[504] != 0);
    return null;
  }

  // gnu_sparse_old_parse: entries of 12 byte offset and 12 byte size
  bool _gnuSparseOldParse(Uint8List p, int off, int length) {
    while (length > 0 && p[off] != 0) {
      if (!_gnuAddSparseEntry(tarAtol(p, off, 12), tarAtol(p, off + 12, 12))) {
        return false;
      }
      off += 24;
      length--;
    }
    return true;
  }

  // gnu_sparse_10_read: the map of GNU sparse 1.0 at the start of the data.
  // Returns the bytes used (a multiple of 512), -1 on error.
  int _gnuSparse10Read(TarItem item) {
    _sparseList = null;
    var remaining = item.packSize;
    final lineBuf = Uint8List(1);
    // gnu_sparse_10_atol: one decimal number per line
    int atol() {
      for (;;) {
        var l = 0;
        var count = 0;
        var comment = false;
        for (;;) {
          if (remaining <= 0 || count >= 100) return -1;
          if (_read(lineBuf, 0, 1) != 1) return -1;
          remaining--;
          final c = lineBuf[0];
          count++;
          if (count == 1 && c == 0x23) comment = true;
          if (c == 0x0A) break;
          if (comment) continue;
          if (c < 0x30 || c > 0x39) return -1;
          if (l < 0x7FFFFFFFFFFFFFFF ~/ 10) {
            l = l * 10 + (c - 0x30);
          } else {
            l = 0x7FFFFFFFFFFFFFFF;
          }
        }
        if (!comment) return l;
      }
    }

    var entries = atol();
    if (entries < 0) return -1;
    while (entries-- > 0) {
      final offset = atol();
      if (offset < 0) return -1;
      final size = atol();
      if (size < 0) return -1;
      if (!_gnuAddSparseEntry(offset, size)) return -1;
    }
    final bytesRead = item.packSize - remaining;
    final toSkip = (-bytesRead) & 0x1FF;
    if (toSkip > remaining) return -1;
    if (skip(toSkip) != toSkip) return -1;
    return bytesRead + toSkip;
  }
}

/// The data of a sparse item: the stored blocks at their offsets, zeros in
/// the holes (archive_read_format_tar_read_data with a sparse list).
class TarSparseInStream implements InStream {
  final InStream _base;
  final List<TarSparseBlock> _blocks;
  final int _size;
  int _pos = 0;
  int _block = 0;
  int _blockDone = 0;

  TarSparseInStream(this._base, this._blocks, this._size);

  @override
  int read(Uint8List buf, int off, int len) {
    if (_pos >= _size || len <= 0) return 0;
    if (len > _size - _pos) len = _size - _pos;
    while (_block < _blocks.length && _blockDone >= _blocks[_block].length) {
      _block++;
      _blockDone = 0;
    }
    if (_block >= _blocks.length) {
      // a hole up to the end
      buf.fillRange(off, off + len, 0);
      _pos += len;
      return len;
    }
    final b = _blocks[_block];
    final dataStart = b.offset + _blockDone;
    if (_pos < dataStart) {
      var n = dataStart - _pos;
      if (n > len) n = len;
      buf.fillRange(off, off + n, 0);
      _pos += n;
      return n;
    }
    if (_pos > dataStart) {
      // overlapping or unordered map: drop the stored bytes before _pos
      final skipN = _pos - dataStart < b.length - _blockDone
          ? _pos - dataStart
          : b.length - _blockDone;
      final tmp = Uint8List(skipN < 4096 ? skipN : 4096);
      var left = skipN;
      while (left > 0) {
        final k = _base.read(tmp, 0, left < tmp.length ? left : tmp.length);
        if (k == 0) {
          throw const SevenZipException(
              'Unexpected end of data', SevenZipError.unexpectedEnd);
        }
        left -= k;
      }
      _blockDone += skipN;
      return read(buf, off, len);
    }
    var n = b.length - _blockDone;
    if (n > len) n = len;
    final k = _base.read(buf, off, n);
    if (k == 0) {
      throw const SevenZipException(
          'Unexpected end of data', SevenZipError.unexpectedEnd);
    }
    _blockDone += k;
    _pos += k;
    return k;
  }
}
