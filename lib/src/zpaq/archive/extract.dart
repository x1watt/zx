// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/decompresser.dart';
import '../core/io.dart';
import '../core/sha1.dart';
import '../pool.dart';
import 'archive_io.dart';
import 'index.dart';
import 'zdate.dart';

/// Progress of an extract or verify operation.
class ZpaqExtractProgress {
  final int totalBytes;
  final int doneBytes;
  const ZpaqExtractProgress(this.totalBytes, this.doneBytes);
}

/// Result of an extract or verify.
class ZpaqExtractResult {
  final int files;
  final int directories;
  final int bytes;
  final List<String> errors;
  const ZpaqExtractResult(
      this.files, this.directories, this.bytes, this.errors);
  bool get ok => errors.isEmpty;
  @override
  String toString() => '$files files, $directories directories, $bytes bytes, '
      '${errors.length} errors';
}

/// Suffix of files being written; renamed to the real name once complete.
const String partSuffix = '.zpaq-part';

/// Maps a stored name to a safe relative path: no leading '/', no drive
/// colon, no '.' or '..' components.
String safeRelativePath(String stored) {
  final parts = <String>[];
  for (var seg in stored.split('/')) {
    if (seg.isEmpty || seg == '.' || seg == '..') continue;
    seg = seg.replaceAll(':', '_');
    parts.add(seg);
  }
  return parts.join('/');
}

/// Selects entries whose name equals or is under one of [paths] (stored
/// names). Empty [paths] selects everything.
bool matchesSelection(String name, List<String>? paths) {
  if (paths == null || paths.isEmpty) return true;
  for (var p in paths) {
    p = p.replaceAll('\\', '/');
    if (p.endsWith('/') && p.length > 1) p = p.substring(0, p.length - 1);
    if (name == p ||
        name == '$p/' ||
        name.startsWith(p.endsWith('/') ? p : '$p/')) {
      return true;
    }
  }
  return false;
}

/// Decompresses the data block at [offset] and returns its content
/// (fragments followed by the fragment size table), verifying the block
/// checksum.
Uint8List readBlockAt(ArchiveInput input, int offset,
    {bool checkBlock = true}) {
  input.seek(offset);
  final d = Decompresser()..input = input;
  if (!d.findBlock()) zpaqError('missing block at $offset');
  final out = ZBuffer(1 << 16);
  final sha = checkBlock ? Sha1() : null;
  d.output = out;
  d.sha1 = sha;
  var first = true;
  while (d.findFilename() != null) {
    // The comment starts with the uncompressed size: size buffers once.
    final comment = d.readComment();
    final m = RegExp(r'^\d+').stringMatch(comment);
    if (m != null && m.length < 11) d.sizeHint = int.parse(m);
    if (!first) zpaqError('unexpected segment in data block');
    first = false;
    d.decompress();
    final stored = d.readSegmentEnd();
    final got = sha?.digest();
    if (stored != null && got != null) {
      for (var i = 0; i < 20; ++i) {
        if (stored[i] != got[i]) zpaqError('block checksum error at $offset');
      }
    }
  }
  return Uint8List.sublistView(out.data, 0, out.size);
}

Uint8List readBlock(ArchiveInput input, ArchiveIndex idx, int b) =>
    readBlockAt(input, idx.blocks[b].offset);

/// Decompresses the block at [offset] and checks each of its fragments
/// against its SHA-1 ([sha1s], 20 bytes each, sizes [usizes]), as zpaq does
/// in its decompression threads. The fragment hashes cover every byte of
/// content, so the whole block checksum is not computed as well. Returns
/// the block and one flag per fragment (1 = good).
(Uint8List, Uint8List) decodeBlock(
    ArchiveInput input, int offset, Uint8List sha1s, Int32List usizes) {
  final data = readBlockAt(input, offset, checkBlock: false);
  final n = usizes.length;
  final ok = Uint8List(n);
  final sha = Sha1();
  var s = 0;
  for (var k = 0; k < n; ++k) {
    final len = usizes[k] < 0 ? 0 : usizes[k];
    if (s + len > data.length) break;
    sha.add(data, s, s + len);
    final h = sha.digest();
    var good = 1;
    for (var i = 0; i < 20; ++i) {
      if (h[i] != sha1s[20 * k + i]) {
        good = 0;
        break;
      }
    }
    ok[k] = good;
    s += len;
  }
  return (data, ok);
}

/// Finishing of one extracted file.
class _Finish {
  final String name, part, path;
  final bool good;
  final int size, date;
  const _Finish(
      this.name, this.part, this.path, this.good, this.size, this.date);
}

/// Deletes failed part files; for good ones sets the size (a part file left
/// by an interrupted earlier try may be longer), the date, and renames them
/// into place. Returns an error or null per file.
List<String?> _finishFiles(List<_Finish> jobs) {
  final out = <String?>[];
  for (final j in jobs) {
    final part = File(j.part);
    try {
      if (!j.good) {
        if (part.existsSync()) part.deleteSync();
      } else {
        if (j.size == 0) {
          part.writeAsBytesSync(const []);
        } else if (part.lengthSync() > j.size) {
          final raf = part.openSync(mode: FileMode.append);
          raf.truncateSync(j.size);
          raf.closeSync();
        }
        if (j.date != 0) part.setLastModifiedSync(decimalToDateTime(j.date));
        part.renameSync(j.path);
      }
      out.add(null);
    } catch (err) {
      out.add('$err');
    }
  }
  return out;
}

List<String?> Function() _finishTask(List<_Finish> jobs) =>
    () => _finishFiles(jobs);

/// Where the fragments of one block go: entry e writes fragment
/// [frag] of the block to [paths][path] at offset [offset].
class _Writes {
  final List<String> paths;
  final Int32List frag, path;
  final Int64List offset;
  const _Writes(this.paths, this.frag, this.path, this.offset);
}

/// Outcome of one block: fragment checks and, when writing, which writes
/// failed (writeOk per entry) with the first error.
class _BlockResult {
  final Uint8List fragOk;
  final Uint8List writeOk;
  final String? writeError;
  const _BlockResult(this.fragOk, this.writeOk, this.writeError);
}

/// Decodes and checks the block at [offset] and writes its good fragments
/// as [writes] says. Each file is opened without truncation (other blocks
/// write other parts of it, maybe at the same time in other workers).
_BlockResult _decodeWriteBlock(ArchiveInput input, int offset, Uint8List sha1s,
    Int32List usizes, _Writes? writes) {
  final (data, ok) = decodeBlock(input, offset, sha1s, usizes);
  if (writes == null) return _BlockResult(ok, Uint8List(0), null);
  final start = Int64List(usizes.length + 1);
  for (var k = 0; k < usizes.length; ++k) {
    start[k + 1] = start[k] + (usizes[k] < 0 ? 0 : usizes[k]);
  }
  final n = writes.frag.length;
  final writeOk = Uint8List(n);
  String? error;
  final files = List<RandomAccessFile?>.filled(writes.paths.length, null);
  try {
    for (var e = 0; e < n; ++e) {
      final k = writes.frag[e];
      if (ok[k] != 1) continue;
      final s = start[k], len = start[k + 1] - s;
      if (len == 0) {
        writeOk[e] = 1;
        continue;
      }
      try {
        final p = writes.path[e];
        final raf =
            files[p] ??= File(writes.paths[p]).openSync(mode: FileMode.append);
        raf.setPositionSync(writes.offset[e]);
        raf.writeFromSync(data, s, s + len);
        writeOk[e] = 1;
      } catch (err) {
        error ??= '$err';
      }
    }
  } finally {
    for (final f in files) {
      f?.closeSync();
    }
  }
  return _BlockResult(ok, writeOk, error);
}

// Top level so the closure sent to a worker captures only its arguments.
_BlockResult Function() _blockTask(String path, ZpaqKey? key, int offset,
        Uint8List sha1s, Int32List usizes, _Writes? writes) =>
    () {
      final inp = ArchiveInput.open(path, key: key);
      try {
        return _decodeWriteBlock(inp, offset, sha1s, usizes, writes);
      } finally {
        inp.close();
      }
    };

class _Target {
  final ZpaqEntry entry;
  final String? outPath;
  int written = 0;
  _Target(this.entry, this.outPath);
  String get partPath => '$outPath$partSuffix';
}

/// Extracts (or with [outputDir] null, only verifies) [entries].
///
/// Every block checksum and every fragment SHA-1 is checked. Files are
/// written as `name.zpaq-part` and renamed only when complete and correct.
/// With [pool], blocks are decompressed by worker isolates (at most
/// pool.size blocks in flight), which then read the archive at
/// [archivePath] themselves.
Future<ZpaqExtractResult> extractEntries(
  ArchiveInput input,
  ArchiveIndex idx,
  List<ZpaqEntry> entries, {
  String? outputDir,
  bool overwrite = true,
  bool restoreDates = true,
  WorkerPool? pool,
  String? archivePath,
  ZpaqKey? key,
  void Function(ZpaqExtractProgress)? onProgress,
}) async {
  final errors = <String>[];
  final targets = <_Target>[];
  final madeDirs = <String>{};
  var dirs = 0;
  var total = 0;
  final sep = Platform.pathSeparator;

  String outPathFor(ZpaqEntry e) {
    final rel = safeRelativePath(e.name);
    return rel.isEmpty
        ? outputDir!
        : '${outputDir!}$sep${rel.replaceAll('/', sep)}';
  }

  for (final e in entries) {
    if (e.isDeleted) continue;
    if (e.isDirectory) {
      if (outputDir != null) {
        try {
          final d = outPathFor(e);
          if (madeDirs.add(d)) Directory(d).createSync(recursive: true);
        } catch (err) {
          errors.add('${e.name}: $err');
        }
      }
      ++dirs;
      continue;
    }
    _Target t;
    if (outputDir != null) {
      t = _Target(e, outPathFor(e));
      if (!overwrite && File(t.outPath!).existsSync()) {
        errors.add('${e.name}: exists, skipped');
        continue;
      }
      try {
        // The part file itself is created by its first write (or at the
        // end for an empty file); only make sure the folder exists.
        final dir = File(t.partPath).parent.path;
        if (madeDirs.add(dir)) Directory(dir).createSync(recursive: true);
      } catch (err) {
        errors.add('${e.name}: $err');
        continue;
      }
    } else {
      t = _Target(e, null);
    }
    targets.add(t);
    total += e.size > 0 ? e.size : 0;
  }

  // Plan: for each block, the list of (target, fragment, offset in file)
  final plan = <int, List<(int, int, int)>>{};
  final bad = <int>{};
  for (var t = 0; t < targets.length; ++t) {
    final e = targets[t].entry;
    var off = 0;
    for (final j in e.ptr) {
      final b = j < idx.ht.length ? idx.blockOf(j) : -1;
      if (b < 0) {
        errors.add('${e.name}: missing fragment $j');
        bad.add(t);
        break;
      }
      (plan[b] ??= []).add((t, j, off));
      final u = idx.ht.usize(j);
      off += u < 0 ? 0 : u;
    }
  }

  var done = 0;
  final blockIds = plan.keys.toList()..sort();

  // Blocks are decoded, checked and written ahead (by the workers when
  // there is a pool) and their results are accounted in order.
  final ahead = <Future<_BlockResult>>[];
  var next = 0;
  Future<_BlockResult> fetch(int b) {
    final bl = idx.blocks[b];
    final sha1s = Uint8List.fromList(Uint8List.sublistView(
        idx.ht.sha1Bytes(), 20 * bl.start, 20 * (bl.start + bl.frags)));
    final usizes = Int32List(bl.frags);
    for (var k = 0; k < bl.frags; ++k) {
      usizes[k] = idx.ht.usize(bl.start + k);
    }
    final entries = plan[b]!;
    _Writes? writes;
    if (outputDir != null) {
      final paths = <String>[];
      final pathIndex = <int, int>{};
      final frag = Int32List(entries.length);
      final path = Int32List(entries.length);
      final offs = Int64List(entries.length);
      for (var e = 0; e < entries.length; ++e) {
        final (t, j, off) = entries[e];
        frag[e] = j - bl.start;
        path[e] = pathIndex.putIfAbsent(t, () {
          paths.add(targets[t].partPath);
          return paths.length - 1;
        });
        offs[e] = off;
      }
      writes = _Writes(paths, frag, path, offs);
    }
    if (pool != null && archivePath != null) {
      return pool
          .run(_blockTask(archivePath, key, bl.offset, sha1s, usizes, writes));
    }
    return Future.sync(
        () => _decodeWriteBlock(input, bl.offset, sha1s, usizes, writes));
  }

  final depth = pool == null ? 1 : pool.size * 2;
  for (var bi = 0; bi < blockIds.length; ++bi) {
    while (next < blockIds.length && next < bi + depth) {
      final f = fetch(blockIds[next++]);
      f.ignore(); // errors are handled when awaited below
      ahead.add(f);
    }
    final b = blockIds[bi];
    final entries = plan[b]!;
    _BlockResult r;
    try {
      r = await ahead.removeAt(0);
    } catch (err) {
      final msg = err is ZpaqException ? err.message : err.toString();
      for (final (t, _, _) in entries) {
        if (bad.add(t)) errors.add('${targets[t].entry.name}: $msg');
      }
      continue;
    }
    final bl = idx.blocks[b];
    for (var e = 0; e < entries.length; ++e) {
      final (t, j, _) = entries[e];
      if (bad.contains(t)) continue;
      final k = j - bl.start;
      if (r.fragOk[k] != 1) {
        bad.add(t);
        errors.add('${targets[t].entry.name}: fragment $j checksum error');
        continue;
      }
      if (r.writeError != null && r.writeOk[e] != 1) {
        bad.add(t);
        errors.add('${targets[t].entry.name}: ${r.writeError}');
        continue;
      }
      final u = idx.ht.usize(j);
      final len = u < 0 ? 0 : u;
      targets[t].written += len;
      done += len;
    }
    onProgress?.call(ZpaqExtractProgress(total, done));
  }

  // Finish the files: check, date and rename (in batches on the workers:
  // three system calls per file add up over thousands of files).
  var files = 0;
  final jobs = <_Finish>[];
  for (var t = 0; t < targets.length; ++t) {
    final tg = targets[t];
    var good = !bad.contains(t);
    if (good && tg.written != tg.entry.size && tg.entry.size >= 0) {
      errors.add('${tg.entry.name}: size mismatch');
      good = false;
    }
    if (tg.outPath == null) {
      if (good) ++files;
      continue;
    }
    jobs.add(_Finish(tg.entry.name, tg.partPath, tg.outPath!, good, tg.written,
        restoreDates && tg.entry.date != 0 ? tg.entry.date : 0));
  }
  const batch = 256;
  final results = <Future<List<String?>>>[];
  for (var i = 0; i < jobs.length; i += batch) {
    final part =
        jobs.sublist(i, i + batch < jobs.length ? i + batch : jobs.length);
    results.add(pool == null
        ? Future.value(_finishFiles(part))
        : pool.run(_finishTask(part)));
  }
  var ji = 0;
  for (final f in results) {
    for (final err in await f) {
      final job = jobs[ji++];
      if (err != null) {
        errors.add('${job.name}: $err');
      } else if (job.good) {
        ++files;
      }
    }
  }
  return ZpaqExtractResult(files, dirs, done, errors);
}

/// Reads one file of the archive fully into memory.
Uint8List readEntry(ArchiveInput input, ArchiveIndex idx, ZpaqEntry e) {
  final out = Uint8List(e.size < 0 ? 0 : e.size);
  var off = 0;
  final cache = <int, Uint8List>{};
  for (final j in e.ptr) {
    final b = idx.blockOf(j);
    if (b < 0) zpaqError('${e.name}: missing fragment $j');
    final data = cache[b] ??= readBlock(input, idx, b);
    if (cache.length > 2) cache.remove(cache.keys.first);
    final bl = idx.blocks[b];
    var s = 0;
    for (var k = bl.start; k < j; ++k) {
      s += idx.ht.usize(k);
    }
    final len = idx.ht.usize(j);
    if (!idx.ht.sha1Equals(j, Sha1.hash(data, s, s + len))) {
      zpaqError('${e.name}: fragment $j checksum error');
    }
    out.setRange(off, off + len, data, s);
    off += len;
  }
  return out;
}
