// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/crc32.dart';
import '../core/io.dart';
import '../core/lzbuffer.dart';
import '../core/method.dart';
import '../core/sha1.dart';
import '../core/xxhash64.dart';
import '../pool.dart';
import 'archive_io.dart';
import 'franz.dart';
import 'index.dart';
import 'zdate.dart';

/// Stage timers, enabled with ZPAQ_TIMING=1. Prints to stderr at the end.
final bool _timing = Platform.environment['ZPAQ_TIMING'] == '1';
final Map<String, int> _times = {};
final Stopwatch _clock = Stopwatch()..start();
int _now() => _clock.elapsedMicroseconds;
void _addTime(String name, int t0) {
  if (_timing) _times[name] = (_times[name] ?? 0) + (_now() - t0);
}

void _printTimes() {
  if (!_timing) return;
  final names = _times.keys.toList()
    ..sort((a, b) => _times[b]!.compareTo(_times[a]!));
  stderr.writeln('--- stage times (ms) ---');
  for (final n in names) {
    stderr
        .writeln('${n.padRight(20)} ${(_times[n]! / 1000).toStringAsFixed(0)}');
  }
}

/// A file or directory to back up and the name it gets in the archive.
class ZpaqSource {
  /// Path on disk.
  final String path;

  /// Name in the archive ('/' separated, no trailing '/'). Defaults to the
  /// normalized [path], like zpaq does.
  final String storedAs;

  ZpaqSource(this.path, {String? storedAs})
      : storedAs = _trimSlash(normalizeStoredName(storedAs ?? path));

  static String _trimSlash(String s) {
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// Converts a platform path to zpaq's stored form ('/' separators).
String normalizeStoredName(String p) => p.replaceAll('\\', '/');

/// Progress of an add operation.
class ZpaqAddProgress {
  final int totalBytes;
  final int doneBytes;
  final int files;
  final String? currentFile;
  const ZpaqAddProgress(
      this.totalBytes, this.doneBytes, this.files, this.currentFile);
}

/// Whole file hash stored with each file (see [ZpaqAddOptions.fileHash]).
enum ZpaqFileHash { xxhash64, sha1 }

/// Options for [addToArchive].
class ZpaqAddOptions {
  /// Compression method: "0".."5" (optionally followed by a block size digit
  /// 0..11, e.g. "16" for 64 MB blocks) or an explicit zpaq method string.
  final String method;

  /// Log2 of the average fragment size in KB (zpaq default 6 = 64 KB).
  final int fragment;

  /// Mark files as deleted in the new version when they are missing from
  /// disk under one of the given sources.
  final bool deleteMissing;

  /// Store a hash and the CRC-32 of every file in the zpaqfranz format, so
  /// `zpaqfranz t` and `zpaqfranz v` can check whole files. zpaq 7.15
  /// ignores them.
  final bool storeHashes;

  /// Which whole file hash to store: XXHASH64 (zpaqfranz's default, fast)
  /// or SHA-1 (about four times slower to compute).
  final ZpaqFileHash fileHash;

  /// Re-read files even if date and size are unchanged.
  final bool force;

  /// Encryption key (zpaq `-key`), or null for a plain archive.
  final ZpaqKey? key;

  /// Parallel block compressors (worker isolates); 1 compresses inline.
  /// Null picks a budget for the device (see `defaultThreads`). Each
  /// compressor holds a block and its model: about 100 MB with method 1,
  /// several hundred MB with methods 2..5 (64 MB blocks).
  final int? threads;

  /// Return false to skip a path (receives the disk path).
  final bool Function(String path, bool isDirectory)? filter;

  /// Store no attributes (zpaq `-noattributes`).
  final bool noAttributes;

  /// Version date to record (defaults to now).
  final DateTime? date;

  const ZpaqAddOptions({
    this.method = '1',
    this.fragment = 6,
    this.deleteMissing = true,
    this.storeHashes = true,
    this.fileHash = ZpaqFileHash.xxhash64,
    this.force = false,
    this.key,
    this.threads,
    this.filter,
    this.noAttributes = false,
    this.date,
  });
}

/// Result of an add.
class ZpaqAddResult {
  /// New version number, or 0 if nothing changed (no version written).
  final int version;
  final int added;
  final int updated;
  final int removed;
  final int unchanged;

  /// Bytes read from changed files.
  final int inputBytes;

  /// Bytes left after deduplication.
  final int dedupedBytes;

  /// Bytes appended to the archive.
  final int archiveBytes;
  final List<String> errors;

  const ZpaqAddResult(
      this.version,
      this.added,
      this.updated,
      this.removed,
      this.unchanged,
      this.inputBytes,
      this.dedupedBytes,
      this.archiveBytes,
      this.errors);

  @override
  String toString() => version == 0
      ? 'No changes'
      : 'Version $version: +$added #$updated -$removed ($unchanged unchanged), '
          'read $inputBytes, new after dedup $dedupedBytes, written $archiveBytes bytes';
}

class _Ext {
  final String path; // on disk
  final String name; // stored
  final int date;
  final int size;
  final int attr;
  bool data = false; // content read in this update
  Uint32List ptr = Uint32List(0);
  _FileHash? fileHash;
  int sortHi = 0, sortLo = 0;
  _Ext(this.path, this.name, this.date, this.size, this.attr);
  bool get isDir => name.endsWith('/');
}

/// Lookup of a fragment id by SHA-1 (libzpaq HTIndex).
class _HtIndex {
  final FragmentTable ht;
  Uint32List _t;
  int _indexed = 1;

  _HtIndex(this.ht, int sz) : _t = Uint32List(_pow2(sz)) {
    update();
  }

  static int _pow2(int sz) {
    var b = 1;
    while ((sz * 3) >> b != 0) {
      ++b;
    }
    return 1 << (b - 1);
  }

  int _hash(Uint8List s, int o) =>
      (s[o] | s[o + 1] << 8 | s[o + 2] << 16 | s[o + 3] << 24) &
      (_t.length - 1);

  int find(Uint8List sha1) {
    final h = _hash(sha1, 0);
    for (var i = 0; i < _t.length; ++i) {
      final id = _t[h ^ i];
      if (id == 0) return 0;
      if (ht.sha1Equals(id, sha1)) return id;
    }
    return 0;
  }

  void update() {
    final all = ht.sha1Bytes();
    while (_indexed < ht.length) {
      if (_indexed >= _t.length ~/ 4 * 3) {
        _t = Uint32List(_t.length * 2);
        _indexed = 1;
        continue;
      }
      final id = _indexed;
      var zero = true;
      for (var k = 0; k < 20; ++k) {
        if (all[20 * id + k] != 0) {
          zero = false;
          break;
        }
      }
      if (ht.usize(id) >= 0 && !zero) {
        final h = _hash(all, 20 * id);
        for (var i = 0; i < _t.length; ++i) {
          if (_t[h ^ i] == 0) {
            _t[h ^ i] = id;
            break;
          }
        }
      }
      ++_indexed;
    }
  }
}

const List<int> _dt = [
  160, 80, 53, 40, 32, 26, 22, 20, 17, 16, 14, 13, 12, 11, 10, 10, //
  9, 8, 8, 8, 7, 7, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5,
  4, 4, 4, 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3,
  3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

bool _isAlnum(int c) =>
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

/// State of a fragment that did not fit in the scan window that started it.
class _FragCarry {
  final Uint8List data;
  final Uint8List o1;
  final int n, hits, c1, h;
  const _FragCarry(this.data, this.o1, this.n, this.hits, this.c1, this.h);
}

/// Bytes of file scanned per scanner job.
const int _scanWindow = 8 << 20;

/// Files bigger than this are cut by a streaming job ([_cutFileTask]) and
/// get their whole file hash from a separate job that reads them again, so
/// the hash does not slow down the cut, which is sequential.
// Must not exceed _scanWindow: smaller files are scanned as one window.
const int _hashJobLimit = _scanWindow;

/// Bytes of fragment metadata: offset, size, hits, SHA-1 and the order 1
/// predictions, per fragment.
const int _recSize = 288;

/// One window of a file: its complete fragments, the state to continue
/// with the next window, and the updated whole file hash state.
class _ScanResult {
  final TransferableTypedData data;

  /// [data] once materialized by the coordinator.
  Uint8List? bytes;
  Uint8List meta;
  final int count;
  final bool more;
  final _FragCarry? carry;
  final _FileHasher? fileHash;
  final String? error;

  _ScanResult(this.data, this.meta, this.count, this.more, this.carry,
      this.fileHash, this.error);
}

// Per isolate scratch buffers, reused by every scan job to keep the cost
// of large allocations and page faults out of the scan loop.
Uint8List? _scanData;
Uint8List? _scanMeta;
Uint8List? _scanIo;
final Uint8List _scanO1 = Uint8List(256);

Uint8List _reuse(Uint8List? buf, int n) {
  final b = buf;
  if (b != null && b.length >= n) return b;
  return Uint8List(n);
}

/// Scans bytes [start, start + _scanWindow) of [path] (to [size]), cutting
/// fragments with zpaq's rolling hash. The rolling hash, the previous byte
/// and the order 1 predictions restart at every fragment, so a window only
/// needs the partial fragment left by the previous one ([carry]).
///
/// The window is read in one piece into a reused buffer (after the carried
/// bytes) and cut in place, so the fragments of the window end up
/// contiguous in that buffer.
@pragma('vm:unsafe:no-bounds-checks')
_ScanResult _scanRange(String path, int start, int size, int maxFragment,
    int minFragment, int fragment, _FragCarry? carry, _FileHasher? fileHash,
    [bool hashFrags = true]) {
  final stop = start + _scanWindow < size ? start + _scanWindow : size;
  final maxN = (_scanWindow ~/ minFragment) + 4;
  final meta = _reuse(_scanMeta, _recSize * maxN);
  final data = _reuse(_scanData, _scanWindow + maxFragment + 64);
  _scanMeta = meta;
  _scanData = data;
  final o1 = _scanO1;
  final fragSha = Sha1();
  final mv = ByteData.sublistView(meta);
  final limit = fragment <= 22 ? 1 << (22 - fragment) : 0;
  var n = 0;
  RandomAccessFile? inp;
  try {
    // A window after the one that met the end of the file (the file
    // shrank while being read): nothing left.
    if (carry == null && start > 0) {
      return _ScanResult(TransferableTypedData.fromList(<Uint8List>[]),
          Uint8List(0), 0, stop < size, null, fileHash, null);
    }
    var sz = 0, hits = 0, c1 = 0, h = 0;
    zeroFill(o1);
    if (carry != null) {
      data.setRange(0, carry.n, carry.data);
      o1.setRange(0, 256, carry.o1);
      sz = carry.n;
      hits = carry.hits;
      c1 = carry.c1;
      h = carry.h;
    }
    final carried = sz;
    final want = carried + (stop - start);
    var end = carried;
    if (stop > start) {
      inp = File(path).openSync();
      if (start > 0) inp.setPositionSync(start);
      while (end < want) {
        final r = inp.readIntoSync(data, end, want);
        if (r <= 0) break;
        end += r;
      }
      inp.closeSync();
      inp = null;
    }
    // zpaq cuts until EOF: the last window ends with the fragment cut by
    // EOF, even an empty one (when the last byte closed a fragment).
    final eof = end < want || stop >= size;

    void emit(int base, int len, int hits) {
      fileHash?.add(data, base, base + len);
      final mo = _recSize * n;
      mv.setUint32(mo, base, Endian.little);
      mv.setUint32(mo + 4, len, Endian.little);
      mv.setUint32(mo + 8, hits, Endian.little);
      if (hashFrags) {
        fragSha.add(data, base, base + len);
        meta.setRange(mo + 12, mo + 32, fragSha.digest());
      }
      meta.setRange(mo + 32, mo + 288, o1);
      ++n;
    }

    var base = 0;
    var i = carried;
    while (i < end) {
      // Scan to the next cut. No call in this loop (emit is below), so
      // its values stay in registers.
      var cut = false;
      while (i < end) {
        final c = data[i++];
        // Branch free: whether c was predicted is random on binary data,
        // and a mispredicted branch per byte halved the speed of this loop.
        final hit = ((c ^ o1[c1]) - 1) >>> 63; // 1 if c == o1[c1]
        h = ((h + c + 1) * (271828182 + hit * (314159265 - 271828182))) &
            0xFFFFFFFF;
        hits += hit;
        o1[c1] = c;
        c1 = c;
        if (++sz >= maxFragment || (h < limit && sz >= minFragment)) {
          cut = true;
          break;
        }
      }
      if (!cut) break;
      emit(base, sz, hits);
      base = i;
      sz = hits = c1 = h = 0;
      zeroFill(o1);
    }
    _FragCarry? out;
    var used = base;
    if (eof) {
      emit(base, sz, hits);
      used = base + sz;
    } else {
      out = _FragCarry(
          Uint8List.fromList(Uint8List.sublistView(data, base, end)),
          Uint8List.fromList(o1),
          sz,
          hits,
          c1,
          h);
    }
    return _ScanResult(
        TransferableTypedData.fromList([Uint8List.sublistView(data, 0, used)]),
        Uint8List.sublistView(meta, 0, _recSize * n),
        n,
        stop < size,
        out,
        fileHash,
        null);
  } catch (e) {
    try {
      inp?.closeSync();
    } catch (_) {}
    return _ScanResult(TransferableTypedData.fromList(<Uint8List>[]),
        Uint8List(0), 0, false, null, fileHash, '$path: $e');
  }
}

/// Scans several small files (each one window) in one job.
List<_ScanResult> Function() _scanBatchTask(
        List<String> paths,
        List<int> sizes,
        int maxFragment,
        int minFragment,
        int fragment,
        List<_FileHasher?> hashers) =>
    () {
      final out = <_ScanResult>[];
      for (var k = 0; k < paths.length; ++k) {
        final r = _scanRange(paths[k], 0, sizes[k], maxFragment, minFragment,
            fragment, null, hashers[k]);
        // meta is a view of a buffer the next file reuses
        r.meta = Uint8List.fromList(r.meta);
        out.add(r);
      }
      return out;
    };

/// A whole file hash (XXH64 or SHA-1) and CRC-32.
class _FileHash {
  final Uint8List? sha1;
  final int? xxhash64;
  final int crc;
  const _FileHash(this.sha1, this.xxhash64, this.crc);
}

/// Computes a whole file hash and CRC-32 as the file is read.
class _FileHasher {
  final Sha1? sha;
  final XxHash64? xx;
  final Crc32 crc = Crc32();
  _FileHasher(ZpaqFileHash type)
      : sha = type == ZpaqFileHash.sha1 ? Sha1() : null,
        xx = type == ZpaqFileHash.xxhash64 ? XxHash64() : null;

  void add(Uint8List data, int start, int end) {
    sha?.add(data, start, end);
    xx?.add(data, start, end);
    crc.add(data, start, end);
  }

  _FileHash finish() => _FileHash(sha?.digest(), xx?.digest(), crc.value);
}

_FileHash _hashFile(String path, ZpaqFileHash type) {
  final h = _FileHasher(type);
  final buf = _scanIo ??= Uint8List(1 << 20);
  final inp = File(path).openSync();
  try {
    while (true) {
      final n = inp.readIntoSync(buf);
      if (n <= 0) break;
      h.add(buf, 0, n);
    }
  } finally {
    inp.closeSync();
  }
  return h.finish();
}

/// Fills in the SHA-1 of the [count] fragments described by [meta].
Uint8List _hashFrags(Uint8List data, Uint8List meta, int count) {
  final sha = Sha1();
  final mv = ByteData.sublistView(meta);
  for (var k = 0; k < count; ++k) {
    final mo = _recSize * k;
    final off = mv.getUint32(mo, Endian.little);
    final sz = mv.getUint32(mo + 4, Endian.little);
    sha.add(data, off, off + sz);
    meta.setRange(mo + 12, mo + 32, sha.digest());
  }
  return meta;
}

Uint8List Function() _hashFragsTask(
        TransferableTypedData data, Uint8List meta, int count) =>
    () => _hashFrags(data.materialize().asUint8List(), meta, count);
_FileHash Function() _hashTask(String path, ZpaqFileHash type) =>
    () => _hashFile(path, type);

/// A scan window of file [fi] ([wi]-th, starting at byte [start]), already
/// submitted to the scanners.
class _ScanWindow {
  final int fi, wi, start;
  final Future<_ScanResult> result;
  final _CutStream? cutter;
  const _ScanWindow(this.fi, this.wi, this.start, this.result, [this.cutter]);
}

/// Receives the windows of a big file cut by one worker ([_cutFileTask]),
/// and hands it one credit per window consumed, so the worker stays at most
/// [initialCredit] windows ahead however big the file is.
class _CutStream {
  final int initialCredit;
  final ReceivePort port = ReceivePort();
  final Map<int, Completer<_ScanResult>> _slots = {};
  SendPort? _credits;
  int _owed = 0;
  _ScanResult? _failed;
  Object? _error;

  _CutStream(this.initialCredit) {
    port.listen((m) {
      if (m is SendPort) {
        _credits = m;
        if (_owed > 0) m.send(_owed);
        _owed = 0;
        return;
      }
      final (w, r) = m as (int, _ScanResult);
      slot(w).complete(r);
      if (r.error != null) {
        _failed = r;
        for (final c in _slots.values) {
          if (!c.isCompleted) c.complete(r);
        }
      }
      if (r.error != null || !r.more) port.close();
    });
  }

  /// The completer of window [w].
  Completer<_ScanResult> slot(int w) {
    final c = _slots.putIfAbsent(w, Completer.new);
    if (!c.isCompleted) {
      if (_failed != null) c.complete(_failed);
      if (_error != null) c.completeError(_error!);
    }
    return c;
  }

  /// The worker job failed outright.
  void fail(Object e) {
    _error = e;
    for (final c in _slots.values) {
      if (!c.isCompleted) c.completeError(e);
    }
    port.close();
  }

  void grant() {
    final c = _credits;
    if (c != null) {
      c.send(1);
    } else {
      ++_owed;
    }
  }
}

/// Cuts all windows of [path] in order in one worker, sending each window
/// (and the carry to the next) to [toMain] as `(window, result)`. It waits
/// for credits from the coordinator before running more than [credit]
/// windows ahead.
Future<int> Function() _cutFileTask(String path, int size, int maxFragment,
        int minFragment, int fragment, SendPort toMain, int credit) =>
    () async {
      final credits = ReceivePort();
      toMain.send(credits.sendPort);
      final it = StreamIterator(credits);
      var allowed = credit;
      _FragCarry? carry;
      try {
        var w = 0;
        for (var start = 0; start < size; start += _scanWindow, ++w) {
          while (w >= allowed) {
            if (!await it.moveNext()) return w;
            allowed += it.current as int;
          }
          final r = _scanRange(path, start, size, maxFragment, minFragment,
              fragment, carry, null, false);
          r.meta = Uint8List.fromList(r.meta); // the buffer is reused
          carry = r.carry;
          toMain.send((w, r));
          if (r.error != null) break;
        }
        return w;
      } finally {
        await it.cancel();
        credits.close();
      }
    };

/// Writes the 8 byte transaction header block (method 0, fixed size).
void _writeJidacHeader(ZWriter out, int date, int cdata, int htsize) {
  final b = ZBuffer(8)..putLE(cdata, 8);
  compressBlock(b, out, '0',
      filename: 'jDC${itos(date, 14)}c${itos(htsize, 10)}', comment: 'jDC\x01');
}

/// Builds the list of files/directories under [sources].
///
/// Most of the time goes to the stat of each entry, and within it to the
/// three local time DateTime objects dart:io makes per stat: each asks the
/// C library for the time zone, which on Linux rereads /etc/localtime under
/// a process wide lock (so stat'ing on several isolates does not help).
List<_Ext> _scan(
    List<ZpaqSource> sources, ZpaqAddOptions opt, List<String> errors) {
  final out = <String, _Ext>{};
  final isWindows = Platform.isWindows;

  int attrOf(FileStat st, bool dir) {
    if (opt.noAttributes) return 0;
    if (isWindows) return 0x77 + ((dir ? 0x10 : 0x20) << 8);
    final type = dir ? 0x4000 : 0x8000; // S_IFDIR / S_IFREG
    return 0x75 + (((type | (st.mode & 0xFFF)) & 0xFFFF) << 8);
  }

  void addEntry(String path, String name, FileStat st, bool dir) {
    final date = dateTimeToDecimal(st.modified);
    out[name] = _Ext(path, name, date, dir ? 0 : st.size, attrOf(st, dir));
  }

  // [checkLink]: whether [path] may be a symbolic link. Children come from
  // listSync(followLinks: false), which already gives links their own type,
  // so only the sources need the extra lstat.
  void walk(String path, String name, bool checkLink) {
    // Skip symbolic links, like zpaq (lstat).
    if (checkLink && FileSystemEntity.isLinkSync(path)) return;
    FileStat st;
    try {
      st = FileStat.statSync(path);
    } catch (e) {
      errors.add('$path: $e');
      return;
    }
    if (st.type == FileSystemEntityType.file) {
      if (opt.filter != null && !opt.filter!(path, false)) return;
      addEntry(path, name, st, false);
    } else if (st.type == FileSystemEntityType.directory) {
      if (opt.filter != null && !opt.filter!(path, true)) return;
      addEntry(path, name == '/' ? '/' : '$name/', st, true);
      List<FileSystemEntity> children;
      try {
        children = Directory(path).listSync(followLinks: false);
      } catch (e) {
        errors.add('$path: $e');
        return;
      }
      for (final c in children) {
        if (c is Link) continue;
        final base =
            c.path.substring(c.path.lastIndexOf(Platform.pathSeparator) + 1);
        final childName = name == '/' ? '/$base' : '$name/$base';
        walk(c.path, childName, false);
      }
    } else if (st.type == FileSystemEntityType.notFound) {
      errors.add('$path: not found');
    }
  }

  for (final s in sources) {
    walk(s.path, s.storedAs, true);
  }
  final l = out.values.toList()..sort((a, b) => compareNames(a.name, b.name));
  return l;
}

bool _underSource(String name, List<ZpaqSource> sources) {
  for (final s in sources) {
    final r = s.storedAs;
    if (name == r || name == '$r/') return true;
    final prefix = r.endsWith('/') ? r : '$r/';
    if (name.startsWith(prefix)) return true;
  }
  return false;
}

bool _ptrEqual(Uint32List a, Uint32List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; ++i) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _BlockJob {
  final int firstFrag;
  final Future<Uint8List> result;
  _BlockJob(this.firstFrag, this.result);
}

// The LZ77 hash table of this isolate, reused by its next block instead
// of allocating 64 MB per block. Compression runs in isolates that end
// with the add, so the table does not outlive it.
final LzHashTables _lzTables = LzHashTables();

Uint8List _compressJob(Uint8List data, int n, String method, String name) {
  final out = ZBuffer(n ~/ 2 + 1024);
  compressBlock(ZBuffer.wrap(data, n), out, method,
      filename: name, comment: 'jDC\x01', tables: _lzTables);
  return Uint8List.sublistView(out.data, 0, out.size);
}

// Top level so the closure sent to a worker captures only its arguments.
TransferableTypedData Function() _compressTask(
        TransferableTypedData data, String m, String fn) =>
    () {
      final d = data.materialize().asUint8List();
      return TransferableTypedData.fromList([_compressJob(d, d.length, m, fn)]);
    };

/// Adds [sources] to the archive at [archivePath] as a new version
/// (creating the archive if needed). Only new or changed files are read;
/// content already in the archive is deduplicated.
Future<ZpaqAddResult> addToArchive(
  String archivePath,
  List<ZpaqSource> sources, {
  ZpaqAddOptions options = const ZpaqAddOptions(),
  void Function(ZpaqAddProgress)? onProgress,
}) async {
  final tAll = _now();
  final opt = options;
  final errors = <String>[];

  // Read the existing index
  final arcFile = File(archivePath);
  ArchiveIndex idx;
  if (arcFile.existsSync() && arcFile.lengthSync() > 0) {
    final input = openArchive(archivePath, opt.key);
    try {
      idx = readIndex(input);
    } finally {
      input.close();
    }
  } else {
    idx = ArchiveIndex();
    if (opt.key != null) idx.appendOffset = 32;
  }
  final ht = idx.ht;
  final dt = idx.files;

  // Method and block size
  var method = opt.method.isEmpty ? '1' : opt.method;
  if (method.length == 1) {
    final c = method.codeUnitAt(0);
    method += (c >= 50 && c <= 57) ? '6' : '4';
  }
  if (!RegExp(r'^[0-9x]').hasMatch(method)) {
    zpaqError('method must begin with 0..5 or x');
  }
  final fragment = opt.fragment < 0 ? 0 : opt.fragment;
  final logBlocksize = 20 +
      (int.tryParse(RegExp(r'^\d+').stringMatch(method.substring(1)) ?? '0') ??
          0);
  if (logBlocksize < 20 || logBlocksize > 31) {
    zpaqError('blocksize must be 0..11');
  }
  final blocksize = (1 << logBlocksize) - 4096;
  final maxFragment = fragment > 19 || (8128 << fragment) > blocksize - 12
      ? blocksize - 12
      : 8128 << fragment;
  final minFragment = fragment > 25 || (64 << fragment) > maxFragment
      ? maxFragment
      : 64 << fragment;

  // Scan
  final tScan = _now();
  final edt = _scan(sources, opt, errors);
  _addTime('dir scan', tScan);
  final edtByName = {for (final e in edt) e.name: e};
  final keep = <String>{};
  final vf = <_Ext>[];
  var totalSize = 0;
  for (final p in edt) {
    final a = dt[p.name];
    if (a != null) keep.add(p.name);
    if (p.date != 0 &&
        !p.isDir &&
        (opt.force ||
            a == null ||
            a.isDeleted ||
            p.date != a.date ||
            p.size != a.size)) {
      totalSize += p.size;
      // Sort key (zpaq): first 5 bytes of the extension, lower case, then
      // decreasing size in 16 KB units, as one unsigned 64 bit number split
      // into hi (bits 32..63) and lo (bits 0..31).
      var hi = 0, lo = 0, sp = 0;
      for (final c0 in utf8.encode(p.name)) {
        var c = c0;
        if (c >= 65 && c <= 90) c += 32;
        if (c == 47) {
          sp = 0;
          hi = lo = 0;
        } else if (c == 46) {
          sp = 8;
          hi = lo = 0;
        } else if (sp > 3) {
          --sp;
          if (sp >= 4) {
            hi += c << ((sp - 4) * 8);
          } else {
            lo += c << 24;
          }
        }
      }
      var s = p.size >> 14;
      if (s >= (1 << 24)) s = (1 << 24) - 1;
      p.sortHi = hi;
      p.sortLo = lo + (1 << 24) - s - 1;
      vf.add(p);
    }
  }
  vf.sort((a, b) {
    if (a.sortHi != b.sortHi) return a.sortHi - b.sortHi;
    if (a.sortLo != b.sortLo) return a.sortLo - b.sortLo;
    return compareNames(a.name, b.name);
  });

  // Version date, strictly after the last one
  var date = dateTimeToDecimal(opt.date ?? DateTime.now());
  if (idx.versions.isNotEmpty) {
    final last =
        idx.versions.map((v) => v.date).reduce((a, b) => a > b ? a : b);
    if (last >= date) {
      date = dateTimeToDecimal(
          decimalToDateTime(last).add(const Duration(seconds: 1)));
    }
  }

  final htinv =
      _HtIndex(ht, ht.length + (totalSize >> (10 + fragment)) + vf.length);
  final htsize = ht.length;

  final out = ArchiveOutput.open(archivePath, key: opt.key);
  final headerPos = idx.appendOffset;
  var committed = false;
  WorkerPool? pool;
  WorkerPool? scanners;
  try {
    out.seek(headerPos);
    _writeJidacHeader(out, date, -1, htsize);
    final headerEnd = out.position;

    // Compression pipeline: blocks are compressed by a pool of worker
    // isolates and written in order, with at most `threads` in flight.
    final threads = opt.threads ?? defaultThreads();
    final tSpawn = _now();
    if (threads > 1) pool = await WorkerPool.spawn(threads);
    _addTime('spawn', tSpawn);
    final pending = <_BlockJob>[];
    final blocklist = <int>[];
    final csize = <int>[];

    Future<void> drain(int maxPending) async {
      while (pending.length > maxPending) {
        final j = pending.removeAt(0);
        final bytes = await j.result;
        out.write(bytes, 0, bytes.length);
        csize.add(bytes.length);
      }
    }

    final sb = ZBuffer(blocksize + 4096 - 128);
    var frags = 0;
    var redundancy = 0;
    var text = 0;
    var exe = 0;
    const on = 4;
    final o1prev = Uint8List(on * 256);
    var totalDone = 0;
    var dedupeSize = 0;
    var filesDone = 0;

    Future<void> flushBlock() async {
      for (var i = ht.length - frags; i < ht.length; ++i) {
        sb.putLE(ht.usize(i), 4);
      }
      sb.putLE(0, 4);
      sb.putLE(frags, 4);
      var m = method;
      if (method.codeUnitAt(0) >= 48 && method.codeUnitAt(0) <= 57) {
        m += ',${redundancy ~/ (sb.size ~/ 256 + 1)},'
            '${(exe > frags ? 1 : 0) * 2 + (text > frags ? 1 : 0)}';
      }
      final first = ht.length - frags;
      final fn = 'jDC${itos(date, 14)}d${itos(first, 10)}';
      Future<Uint8List> fut;
      if (pool == null) {
        // Compressed right away from the block buffer (no copy).
        fut = Future.value(_compressJob(sb.data, sb.size, m, fn));
      } else {
        final data = TransferableTypedData.fromList(
            [Uint8List.sublistView(sb.data, 0, sb.size)]);
        fut = pool
            .run(_compressTask(data, m, fn))
            .then((t) => t.materialize().asUint8List());
      }
      sb.clear();
      pending.add(_BlockJob(first, fut));
      blocklist.add(first);
      // Like zpaq: up to 2 * threads - 1 blocks queued (threads of them
      // compressing), so building the next block rarely waits.
      await drain(threads <= 1 ? 0 : 2 * threads - 1);
      frags = redundancy = text = exe = 0;
      o1prev.fillRange(0, o1prev.length, 0);
    }

    // Scanner pipeline: files are read and fragmented in worker isolates
    // ahead of this loop, so the coordinator only looks up duplicates,
    // analyzes fragments and assembles blocks. Small files go in batches;
    // a big file is cut by one streaming job (the cut is sequential) while
    // its fragments are hashed on the other scanners. Scanners take half
    // the thread budget on top of the compressors. With fewer than 6
    // compressors (every phone) the coordinator keeps up scanning by
    // itself: scanner isolates only added memory there (measured).
    final scanThreads = threads < 6 ? 0 : (threads ~/ 2).clamp(2, 4);
    final tSpawn2 = _now();
    if (scanThreads > 1) scanners = await WorkerPool.spawn(scanThreads);
    _addTime('spawn', tSpawn2);
    // A queue: removing the head of a List shifts it all, and with many
    // small files this queue holds thousands of entries.
    final scanQueue = ListQueue<_ScanWindow>();
    // Bytes of input queued to the scanners and not consumed yet: deep enough
    // to keep every scanner busy and to start the next big file while one
    // is still being cut (each pending window holds up to 8 MB).
    final maxPendingBytes =
        scanners == null ? 0 : scanThreads * 2 * _scanWindow;
    var pendingBytes = 0;
    int windowBytes(_ScanWindow w) {
      final left = vf[w.fi].size - w.start;
      return left < _scanWindow ? left : _scanWindow;
    }

    final fileHashType = opt.fileHash;
    final hashFuts = <Future<_FileHash>>[];
    final hashOwner = <_Ext>[];
    // The cutter of the big file being queued.
    _CutStream? cutter;
    var nextToScan = 0;
    var nextStart = 0;
    var windows = 0;
    for (final p in vf) {
      windows += p.size > _hashJobLimit
          ? (p.size + _scanWindow - 1) ~/ _scanWindow
          : 1;
    }
    final carries = <_FragCarry?>[for (var i = 0; i < vf.length; ++i) null];

    void fillScanQueue() {
      while (nextToScan < vf.length &&
          (scanQueue.isEmpty || pendingBytes < maxPendingBytes)) {
        final fi = nextToScan;
        final p = vf[fi];
        final big = p.size > _hashJobLimit;
        if (nextStart == 0) {
          if (big && opt.storeHashes) {
            hashFuts.add(scanners == null
                ? Future.value(_hashFile(p.path, fileHashType))
                : scanners.run(_hashTask(p.path, fileHashType)));
            hashOwner.add(p);
          }
          onProgress
              ?.call(ZpaqAddProgress(totalSize, totalDone, filesDone, p.name));
        }
        final wi = nextStart ~/ _scanWindow;
        final storeWhole = !big && opt.storeHashes;
        final start = nextStart;
        Future<_ScanResult> result;
        if (scanners == null) {
          result = Future.value(_scanRange(
              p.path,
              start,
              p.size,
              maxFragment,
              minFragment,
              fragment,
              carries[fi],
              storeWhole ? _FileHasher(fileHashType) : null));
        } else if (!big) {
          // Small files go to the scanners in batches (up to 64 files or
          // 8 MB): one message per batch instead of one per file.
          final paths = <String>[], sizes = <int>[];
          final hashers = <_FileHasher?>[];
          var bytes = 0;
          var fj = fi;
          while (fj < vf.length &&
              paths.length < 64 &&
              vf[fj].size <= _hashJobLimit &&
              (paths.isEmpty || bytes + vf[fj].size <= _scanWindow)) {
            paths.add(vf[fj].path);
            sizes.add(vf[fj].size);
            hashers.add(opt.storeHashes ? _FileHasher(fileHashType) : null);
            bytes += vf[fj].size;
            ++fj;
          }
          final batch = scanners.run(_scanBatchTask(
              paths, sizes, maxFragment, minFragment, fragment, hashers));
          batch.ignore();
          for (var k = 0; k < paths.length; ++k) {
            final r = batch.then((l) => l[k]);
            r.ignore();
            final w = _ScanWindow(fi + k, 0, 0, r);
            pendingBytes += windowBytes(w);
            scanQueue.add(w);
          }
          nextToScan = fj;
          nextStart = 0;
          continue;
        } else {
          // Windows of a big file: the cut (rolling hash) is sequential, each
          // window needs the state the previous one ended with, so it runs
          // first in the queue. Fragment hashing is a separate job that can
          // run on any scanner meanwhile.
          final pool = scanners;
          if (wi == 0) {
            // One job cuts the whole file, window after window, and streams
            // each window back as soon as it is cut.
            final c = cutter = _CutStream(4);
            pool
                .run(
                    _cutFileTask(p.path, p.size, maxFragment, minFragment,
                        fragment, c.port.sendPort, c.initialCredit),
                    urgent: true)
                .then((_) {}, onError: c.fail);
          }
          final cut = cutter!.slot(wi).future;
          result = cut.then<_ScanResult>((r) async {
            if (r.error != null) return r;
            final d = r.data.materialize().asUint8List();
            r.bytes = d;
            // Urgent too: the coordinator needs these windows next, while
            // the queue may hold batches of files that come later.
            r.meta = await pool.run(
                _hashFragsTask(
                    TransferableTypedData.fromList([d]), r.meta, r.count),
                urgent: true);
            return r;
          });
        }
        result.ignore(); // errors are seen when the window is consumed
        final w = _ScanWindow(fi, wi, start, result, big ? cutter : null);
        pendingBytes += windowBytes(w);
        scanQueue.add(w);
        nextStart += _scanWindow;
        if (nextStart >= p.size) {
          ++nextToScan;
          nextStart = 0;
        }
      }
    }

    final mainLoopT0 = _now();
    var curFile = -1;
    var erroredFile = -1;
    var ptrs = <int>[];
    var fj = 0;
    _FileHasher? fileHash;
    for (var w = 0; w < windows; ++w) {
      final tq = _now();
      fillScanQueue();
      _addTime('fill queue', tq);
      final job = scanQueue.removeFirst();
      pendingBytes -= windowBytes(job);
      job.cutter?.grant();
      final p = vf[job.fi];
      if (job.fi != curFile && job.fi != erroredFile) {
        curFile = job.fi;
        ptrs = <int>[];
        fj = 0;
        fileHash = null;
      }
      final tw = _now();
      final res = await job.result;
      _addTime('await scan', tw);
      carries[job.fi] = res.carry;
      if (job.fi == erroredFile) continue;
      if (res.error != null) {
        errors.add(res.error!);
        totalSize -= p.size;
        edtByName.remove(p.name); // keep the previous version, if any
        p.data = false;
        erroredFile = job.fi;
        continue;
      }
      p.data = true;
      fileHash = res.fileHash;
      final data = res.bytes ?? res.data.materialize().asUint8List();
      final mv = ByteData.sublistView(res.meta);
      for (var k = 0; k < res.count; ++k) {
        final mo = _recSize * k;
        final off = mv.getUint32(mo, Endian.little);
        final sz = mv.getUint32(mo + 4, Endian.little);
        var hits = mv.getUint32(mo + 8, Endian.little);
        final sha1result = Uint8List.sublistView(res.meta, mo + 12, mo + 32);
        final o1 = Uint8List.sublistView(res.meta, mo + 32, mo + 288);
        totalDone += sz;
        var htptr = htinv.find(sha1result);

        if (htptr == 0) {
          // Analyze fragment for redundancy, x86, text
          var text1 = 0, exe1 = 0;
          var h1 = sz;
          final o1ct = Uint8List(256);
          for (var i = 0; i < 256; ++i) {
            if (o1ct[o1[i]] < 255) h1 -= (sz * _dt[o1ct[o1[i]]++]) >> 15;
            if (o1[i] == 32 && (_isAlnum(i) || i == 46 || i == 44)) ++text1;
            if (o1[i] != 0 &&
                (i < 9 ||
                    i == 11 ||
                    i == 12 ||
                    (i >= 14 && i <= 31) ||
                    i >= 240)) {
              --text1;
            }
            if (i >= 192 &&
                i < 240 &&
                o1[i] != 0 &&
                (o1[i] < 128 || o1[i] >= 192)) {
              --text1;
            }
            if (o1[i] == 139) ++exe1;
          }
          text1 = text1 >= 3 ? 1 : 0;
          exe1 = exe1 >= 5 ? 1 : 0;
          if (sz > 0) h1 = h1 * h1 ~/ sz;
          var h2 = h1 & 0xFFFFFFFF;
          if (h2 > hits) hits = h2;
          h2 = o1ct[0] * sz ~/ 256;
          if (h2 > hits) hits = h2;
          h2 = 0;
          for (var i = 0; i < 256 * on; ++i) {
            if (o1prev[i] == o1[i & 255]) ++h2;
          }
          h2 = h2 * sz ~/ (256 * on);
          if (h2 > hits) hits = h2;
          if (hits > sz) hits = sz;

          var newblock = false;
          if (frags > 0 && fj == 0) {
            final esize = p.size;
            final newsize = sb.size + esize + (esize >> 14) + 4096 + frags * 4;
            if (newsize > blocksize ~/ 4 && redundancy < sb.size ~/ 128) {
              newblock = true;
            }
            if (newblock) {
              var ct = 0;
              for (var i = 0; i < 256 * on; ++i) {
                if (o1prev[i] != 0 && o1prev[i] == o1[i & 255]) ++ct;
              }
              if (ct > on * 2) newblock = false;
            }
            if (newsize >= blocksize) newblock = true;
          }
          if (sb.size + sz + 80 + frags * 4 >= blocksize) newblock = true;
          if (frags < 1) newblock = false;
          if (newblock) {
            final tB = _now();
            await flushBlock();
            _addTime('flushBlock', tB);
          }
          sb.write(data, off, sz);
          ++frags;
          redundancy = (redundancy + hits) & 0xFFFFFFFF;
          exe += exe1 * 4;
          text += text1 * 2;
          if (sz >= minFragment) {
            o1prev.setRange(0, 256 * (on - 1), o1prev, 256);
            o1prev.setRange(256 * (on - 1), 256 * on, o1);
          }
        }

        if (htptr == 0) {
          htptr = ht.add(sha1result, sz);
          htinv.update();
          dedupeSize += sz;
        }
        ptrs.add(htptr);
        ++fj;
      }
      if (!res.more) {
        p.ptr = Uint32List.fromList(ptrs);
        if (fileHash != null) p.fileHash = fileHash.finish();
        ++filesDone;
      }
    }
    if (hashFuts.isNotEmpty) {
      for (var i = 0; i < hashFuts.length; ++i) {
        final h = await hashFuts[i];
        hashOwner[i].fileHash = h;
      }
    }
    if (frags > 0) await flushBlock();
    await drain(0);
    onProgress?.call(ZpaqAddProgress(totalSize, totalDone, filesDone, null));

    // Fragment tables
    final cdatasize = out.position - headerEnd;
    final isb = ZBuffer();
    blocklist.add(ht.length);
    _addTime('main loop', mainLoopT0);
    final tIdx = _now();
    for (var i = 0; i < csize.length; ++i) {
      if (blocklist[i] < blocklist[i + 1]) {
        isb.putLE(csize[i], 4);
        for (var j = blocklist[i]; j < blocklist[i + 1]; ++j) {
          isb.write(ht.sha1Bytes(), 20 * j, 20);
          isb.putLE(ht.usize(j), 4);
        }
        compressBlock(isb, out, '0',
            filename: 'jDC${itos(date, 14)}h${itos(blocklist[i], 10)}',
            comment: 'jDC\x01');
        isb.clear();
      }
    }

    // Deletions
    var dtcount = 0;
    var removed = 0;
    final indexTables = LzHashTables();
    void flushIndex() {
      compressBlock(isb, out, '1',
          filename: 'jDC${itos(date)}i${itos(++dtcount, 10)}',
          comment: 'jDC\x01',
          tables: indexTables);
      isb.clear();
    }

    if (opt.deleteMissing) {
      final names = dt.keys.toList()..sort(compareNames);
      for (final name in names) {
        final e = dt[name]!;
        if (!e.isDeleted &&
            !keep.contains(name) &&
            _underSource(name, sources)) {
          isb.putLE(0, 8);
          isb.addAll(utf8.encode(name));
          isb.put(0);
          ++removed;
          if (isb.size > 16000) flushIndex();
        }
      }
    }

    // Index entries
    var added = 0, updated = 0, unchanged = 0;
    for (final p in edt) {
      if (!edtByName.containsKey(p.name)) continue;
      final a = dt[p.name];
      final isNew = a == null || a.isDeleted;
      final changed = p.date != 0 &&
          (isNew ||
              a.date != p.date ||
              (a.attr != 0 && a.attr != p.attr) ||
              a.size != p.size ||
              (p.data && !_ptrEqual(a.ptr, p.ptr)));
      if (!changed) {
        ++unchanged;
        continue;
      }
      if (isNew) {
        ++added;
      } else {
        ++updated;
      }
      isb.putLE(p.date, 8);
      isb.addAll(utf8.encode(p.name));
      isb.put(0);
      final nattr =
          (p.attr & 255) == 0x75 ? 3 : ((p.attr & 255) == 0x77 ? 5 : 0);
      Uint8List? franz;
      if (!p.isDir) {
        final h = p.fileHash;
        if (p.data && h != null) {
          franz = h.xxhash64 != null
              ? FranzInfo.encodeXxhash64(h.xxhash64!, h.crc, isNew)
              : FranzInfo.encodeSha1(h.sha1!, h.crc);
        } else if (a != null && a.franz != null) {
          // Metadata only change: the content, and so its hash, is the same.
          franz = _reencode(a.franz!, isNew);
        }
      }
      if (franz != null) {
        isb.putLE(8 + franz.length, 4);
        isb.putLE(p.attr, nattr);
        isb.putLE(0, 8 - nattr);
        isb.write(franz, 0, franz.length);
      } else {
        isb.putLE(nattr, 4);
        isb.putLE(p.attr, nattr);
      }
      final ptr = (a == null || p.data) ? p.ptr : a.ptr;
      isb.putLE(ptr.length, 4);
      for (final j in ptr) {
        isb.putLE(j, 4);
      }
      if (isb.size > 16000) flushIndex();
    }
    if (isb.size > 0) flushIndex();

    // Commit: rewrite the header with the real data size
    _addTime('index write', tIdx);
    final archiveEnd = out.position;
    var version = idx.versions.length + 1;
    if (added + updated + removed == 0 && csize.isEmpty) {
      out.truncate(headerPos);
      version = 0;
      committed = true;
      return ZpaqAddResult(
          0, 0, 0, 0, unchanged, totalDone, dedupeSize, 0, errors);
    }
    out.seek(headerPos);
    _writeJidacHeader(out, date, cdatasize, htsize);
    out.flush();
    out.truncate(archiveEnd);
    committed = true;
    return ZpaqAddResult(version, added, updated, removed, unchanged, totalDone,
        dedupeSize, archiveEnd - headerPos, errors);
  } finally {
    _addTime('add total', tAll);
    _printTimes();
    scanners?.close();
    pool?.close();
    if (!committed) {
      // Leave the archive as it was before this update.
      try {
        out.truncate(headerPos);
      } catch (_) {}
    }
    out.close();
    if (headerPos == 0 || (opt.key != null && headerPos == 32)) {
      final f = File(archivePath);
      if (f.existsSync() && f.lengthSync() <= headerPos) f.deleteSync();
    }
  }
}

Uint8List? _reencode(FranzInfo f, bool isNew) {
  if (f.hashType == 'XXHASH64' && f.hash.length == 16) {
    final v = (int.parse(f.hash.substring(0, 8), radix: 16) << 32) |
        int.parse(f.hash.substring(8), radix: 16);
    return FranzInfo.encodeXxhash64(
        v, int.tryParse(f.crc32, radix: 16) ?? 0, isNew);
  }
  if (f.hashType != 'SHA-1' || f.hash.length != 40) return null;
  final b = Uint8List(20);
  for (var i = 0; i < 20; ++i) {
    b[i] = int.parse(f.hash.substring(2 * i, 2 * i + 2), radix: 16);
  }
  final crc = int.tryParse(f.crc32, radix: 16) ?? 0;
  return FranzInfo.encodeSha1(b, crc);
}
