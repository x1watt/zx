// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:convert';
import 'dart:typed_data';

import '../core/decompresser.dart';
import '../core/io.dart';
import '../core/sha1.dart';
import 'archive_io.dart';
import 'franz.dart';
import 'zdate.dart';

/// One archive version (transaction).
class ZpaqVersion {
  /// 1-based version number.
  final int number;

  /// Date as decimal YYYYMMDDHHMMSS (UTC).
  final int date;

  /// Offset of the transaction header block.
  final int offset;

  /// Compressed size of the data blocks.
  final int csize;

  /// Number of files added or updated / deleted in this version.
  int updates = 0;
  int deletes = 0;

  /// Uncompressed size of added content.
  int usize = 0;

  ZpaqVersion(this.number, this.date, this.offset, this.csize);

  DateTime get dateTime => decimalToDateTime(date);

  @override
  String toString() =>
      'Version $number ${formatDecimalDate(date)} +$updates -$deletes';
}

/// A file or directory stored in the archive.
class ZpaqEntry {
  /// Stored name, '/' separated. Directories end with '/'.
  final String name;

  /// Last modified date as decimal YYYYMMDDHHMMSS (UTC), 0 if deleted.
  final int date;

  /// zpaq attributes: 'u' + (unix mode << 8) or 'w' + (windows attr << 8).
  final int attr;

  /// Fragment ids of the content, in order.
  final Uint32List ptr;

  /// Version in which this entry was written.
  final int version;

  /// Size in bytes (sum of fragment sizes), -1 if unknown.
  int size = 0;

  /// zpaqfranz extra data (hash, CRC-32), if present.
  final FranzInfo? franz;

  ZpaqEntry(this.name, this.date, this.attr, this.ptr, this.version,
      [this.franz]);

  bool get isDeleted => date == 0;
  bool get isDirectory => name.endsWith('/');

  DateTime? get modified => date == 0 ? null : decimalToDateTime(date);

  /// Unix mode bits if the entry has unix attributes.
  int? get unixMode => (attr & 255) == 0x75 ? (attr >> 8) & 0xFFFF : null;

  /// Windows attribute bits if the entry has windows attributes.
  int? get windowsAttributes =>
      (attr & 255) == 0x77 ? (attr >> 8) & 0xFFFFFFFF : null;

  @override
  String toString() => '$name ($size bytes, ${formatDecimalDate(date)})';
}

/// A compressed data block of fragments.
class ZpaqBlock {
  /// First fragment id.
  final int start;

  /// Number of fragments.
  final int frags;

  /// Offset of the block in the archive.
  final int offset;

  /// Compressed size.
  final int bsize;

  ZpaqBlock(this.start, this.frags, this.offset, this.bsize);
}

/// Growable table of fragments: SHA-1 and size by id. Id 0 is unused.
class FragmentTable {
  Uint8List _sha1 = Uint8List(20 * 1024);
  Int32List _usize = Int32List(1024);
  int _n = 1;

  FragmentTable() {
    _usize[0] = -1;
  }

  int get length => _n;

  void _grow(int n) {
    if (n <= _usize.length) return;
    var c = _usize.length * 2;
    while (c < n) {
      c *= 2;
    }
    final s = Uint8List(20 * c)..setRange(0, 20 * _n, _sha1);
    final u = Int32List(c)..setRange(0, _n, _usize);
    _sha1 = s;
    _usize = u;
  }

  /// Ensures ids up to [n]-1 exist (new ones get size -1, zero hash).
  void ensure(int n) {
    if (n <= _n) return;
    _grow(n);
    for (var i = _n; i < n; ++i) {
      _usize[i] = -1;
      _sha1.fillRange(20 * i, 20 * i + 20, 0);
    }
    _n = n;
  }

  void set(int id, Uint8List src, int srcOff, int usize) {
    ensure(id + 1);
    _sha1.setRange(20 * id, 20 * id + 20, src, srcOff);
    _usize[id] = usize;
  }

  int add(Uint8List sha1, int usize) {
    final id = _n;
    set(id, sha1, 0, usize);
    return id;
  }

  int usize(int id) => _usize[id];

  Uint8List sha1Bytes() => _sha1;

  /// SHA-1 of fragment [id] as a view.
  Uint8List sha1(int id) => Uint8List.sublistView(_sha1, 20 * id, 20 * id + 20);

  bool sha1Equals(int id, Uint8List h, [int off = 0]) {
    final b = 20 * id;
    for (var i = 0; i < 20; ++i) {
      if (_sha1[b + i] != h[off + i]) return false;
    }
    return true;
  }
}

/// Everything known about an archive after reading its index.
class ArchiveIndex {
  final List<ZpaqVersion> versions = [];
  final FragmentTable ht = FragmentTable();
  final List<ZpaqBlock> blocks = [];

  /// Files as of the selected version (including deleted markers).
  final Map<String, ZpaqEntry> files = {};

  /// Every index entry in archive order, if requested.
  final List<ZpaqEntry>? history;

  /// Offset where the next transaction should be written.
  int appendOffset = 0;

  /// True if an incomplete (interrupted) transaction was found at the end.
  bool incomplete = false;

  /// Errors skipped while reading (damaged blocks).
  final List<String> warnings = [];

  ArchiveIndex({bool keepHistory = false})
      : history = keepHistory ? <ZpaqEntry>[] : null;

  /// Current (not deleted) entries sorted by name.
  List<ZpaqEntry> get entries {
    final l = files.values.where((e) => !e.isDeleted).toList()
      ..sort((a, b) => compareNames(a.name, b.name));
    return l;
  }

  /// Block index of a fragment id, built lazily.
  Int32List? _blockOf;
  int blockOf(int frag) {
    var t = _blockOf;
    if (t == null || t.length < ht.length) {
      t = Int32List(ht.length)..fillRange(0, ht.length, -1);
      for (var b = 0; b < blocks.length; ++b) {
        final bl = blocks[b];
        for (var j = bl.start; j < bl.start + bl.frags && j < t.length; ++j) {
          t[j] = b;
        }
      }
      _blockOf = t;
    }
    return frag < t.length ? t[frag] : -1;
  }
}

/// Reads the journaling index of an archive.
///
/// [untilVersion] limits to the first N versions, [untilDate] (decimal
/// YYYYMMDDHHMMSS) to versions not newer than that date.
ArchiveIndex readIndex(ArchiveInput input,
    {int? untilVersion, int? untilDate, bool keepHistory = false}) {
  final idx = ArchiveIndex(keepHistory: keepHistory);
  final start = input.dataStart;
  var blockOffset = start;
  var dataOffset = start;
  var done = false;
  var foundData = false;
  input.seek(start);

  while (!done) {
    final d = Decompresser()..input = input;
    int pos() => input.position - d.buffered;
    try {
      var restart = false;
      while (!restart && d.findBlock()) {
        foundData = true;
        String? filename;
        while ((filename = d.findFilename()) != null) {
          final fn = filename!;
          final comment = d.readComment();
          if (!(comment.length >= 4 && comment.endsWith('jDC\x01'))) {
            zpaqError('streaming format archives are not supported');
          }
          if (fn.length != 28 || !fn.startsWith('jDC')) {
            zpaqError('bad journaling block name');
          }
          var usize = 0;
          for (var i = 0; i < comment.length; ++i) {
            final c = comment.codeUnitAt(i);
            if (c < 48 || c > 57) break;
            usize = usize * 10 + c - 48;
            if (usize > 0xffffffff) zpaqError('journaling block too big');
          }
          final fdate = int.tryParse(fn.substring(3, 17)) ?? -1;
          if (fdate < 19000000000000 || fdate >= 30000000000000) {
            zpaqError('bad date');
          }
          final num = int.tryParse(fn.substring(18, 28)) ?? -1;
          if (num < 0 || num > 0xffffffff) zpaqError('bad fragment');
          final type = fn[17];

          ZBuffer? os;
          if (type == 'c' || type == 'h' || type == 'i') {
            os = ZBuffer(usize + 16)..limit = usize;
            final sha = Sha1();
            d.output = os;
            d.sha1 = sha;
            d.decompress();
            final stored = d.readSegmentEnd();
            if (os.size != usize) zpaqError('bad block size');
            if (usize != sha.length) zpaqError('bad checksum size');
            final got = sha.digest();
            if (stored != null) {
              for (var i = 0; i < 20; ++i) {
                if (stored[i] != got[i]) zpaqError('bad checksum');
              }
            }
            d.output = null;
            d.sha1 = null;
          } else {
            d.readSegmentEnd();
          }

          if (type == 'c') {
            if (os!.size < 8) zpaqError('c block too small');
            dataOffset = pos() + 1;
            final jmp = readLE(os.data, 0, 8); // signed 64 bit
            if (jmp < 0) {
              idx.incomplete = true;
            }
            final nver = idx.versions.length;
            if (jmp < 0 ||
                (untilVersion != null && nver >= untilVersion) ||
                (untilDate != null && untilDate < fdate)) {
              done = true;
              restart = true;
              break;
            }
            idx.versions.add(ZpaqVersion(nver + 1, fdate, blockOffset, jmp));
            if (jmp > 0) {
              input.seek(dataOffset + jmp);
              restart = true;
              break;
            }
          } else if (type == 'h') {
            final data = os!.data;
            final size = os.size;
            if (size % 24 != 4) zpaqError('bad h block size');
            final n = (size - 4) ~/ 24;
            if (num < 1 || num + n > 0xffffffff) zpaqError('bad h fragment');
            final bsize = readLE(data, 0, 4);
            if (idx.ht.length > num) {
              idx.warnings.add('Unordered fragment tables');
            }
            idx.blocks.add(ZpaqBlock(num, n, dataOffset, bsize));
            idx.ht.ensure(num + n);
            var s = 4;
            for (var k = 0; k < n; ++k) {
              final f = readLE(data, s + 20, 4);
              if (f > 0x7fffffff) zpaqError('fragment too big');
              idx.ht.set(num + k, data, s, f);
              s += 24;
            }
            dataOffset += bsize;
          } else if (type == 'i') {
            if (idx.versions.isEmpty) zpaqError('index before header');
            _parseIndexBlock(idx, os!.data, os.size);
          } else if (type != 'd') {
            zpaqError('Unexpected journaling block');
          }
        }
        if (!restart) blockOffset = pos();
      }
      if (!restart) done = true;
    } on ZpaqException catch (e) {
      // Skip a damaged block like zpaq does: resync on the next block.
      idx.warnings.add('Skipping block at $blockOffset: ${e.message}');
      if (!foundData) rethrow;
      input.seek(pos());
      if (input.position >= input.length) done = true;
    }
  }
  if (input.position > start && !foundData && input.length > start) {
    zpaqError('archive contains no data');
  }
  idx.appendOffset = blockOffset;

  // Compute file sizes
  for (final e in idx.files.values) {
    var s = 0;
    for (final j in e.ptr) {
      if (j > 0 && j < idx.ht.length) {
        final u = idx.ht.usize(j);
        if (u < 0) {
          s = -1;
          break;
        }
        s += u;
      }
    }
    e.size = s;
  }
  if (idx.history != null) {
    for (final e in idx.history!) {
      if (e.size == 0 && e.ptr.isNotEmpty) {
        var s = 0;
        for (final j in e.ptr) {
          if (j > 0 && j < idx.ht.length) {
            final u = idx.ht.usize(j);
            if (u < 0) {
              s = -1;
              break;
            }
            s += u;
          }
        }
        e.size = s;
      }
    }
  }
  return idx;
}

void _parseIndexBlock(ArchiveIndex idx, Uint8List data, int size) {
  final ver = idx.versions.last;
  var s = 0;
  while (s + 9 <= size) {
    final date = readLE(data, s, 8);
    s += 8;
    var e = s;
    while (e < size && data[e] != 0) {
      ++e;
    }
    if (e >= size) zpaqError('filename too long');
    final name =
        utf8.decode(Uint8List.sublistView(data, s, e), allowMalformed: true);
    s = e + 1;
    ZpaqEntry entry;
    if (date != 0) {
      ++ver.updates;
      if (s + 4 > size) zpaqError('missing attr');
      final na = readLE(data, s, 4);
      s += 4;
      if (s + na > size || na > 65535) zpaqError('attr too long');
      var attr = 0;
      for (var k = 0; k < na && k < 8; ++k) {
        attr |= data[s + k] << (k * 8);
      }
      FranzInfo? franz;
      if (na > 50) {
        franz = FranzInfo.decode(Uint8List.sublistView(data, s + 8, s + na));
      }
      s += na;
      if (s + 4 > size) zpaqError('missing ptr');
      final ni = readLE(data, s, 4);
      s += 4;
      if (ni > (size - s) ~/ 4) zpaqError('ptr list too long');
      final ptr = Uint32List(ni);
      for (var k = 0; k < ni; ++k) {
        ptr[k] = readLE(data, s, 4);
        s += 4;
      }
      entry = ZpaqEntry(name, date, attr, ptr, ver.number, franz);
      for (final j in ptr) {
        if (j < idx.ht.length) {
          final u = idx.ht.usize(j);
          if (u > 0) ver.usize += u;
        }
      }
    } else {
      ++ver.deletes;
      entry = ZpaqEntry(name, 0, 0, Uint32List(0), ver.number);
    }
    idx.files[name] = entry;
    idx.history?.add(entry);
  }
}

/// Orders names as their UTF-8 bytes (zpaq's order), which is code point
/// order, without encoding them: UTF-16 code units compare the same way
/// except that surrogates (code points from 0x10000) must come after the
/// units 0xE000 to 0xFFFF.
int compareNames(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; ++i) {
    var x = a.codeUnitAt(i), y = b.codeUnitAt(i);
    if (x != y) {
      if (x >= 0xD800 && y >= 0xD800) {
        x = x >= 0xE000 ? x - 0x800 : x + 0x2000;
        y = y >= 0xE000 ? y - 0x800 : y + 0x2000;
      }
      return x - y;
    }
  }
  return a.length - b.length;
}
