// The public, isolate based API: 7z archives and xz / lzma files for Dart and
// Flutter programs. Everything below lib/src is synchronous; this file runs
// it in background isolates, so the caller's isolate (the UI isolate of a
// Flutter app) only sends requests and receives results and progress.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'cli/extracting_file_path.dart' show getCorrectFsFileName;
import 'format/lzma_alone.dart';
import 'format/sevenz/sevenz.dart';
import 'format/split.dart';
import 'format/xz/xz_handler.dart';
import 'io/streams.dart';
import 'parallel.dart';
import 'pool.dart';

// ---------------------------------------------------------------------------
// Public types

/// Progress of a background operation, delivered on the calling isolate at
/// most every 100 ms, plus the last event.
class SevenZipProgress {
  /// Bytes processed so far (unpacked bytes for extraction and for
  /// compression).
  final int doneBytes;

  /// Total bytes of the operation, 0 when unknown.
  final int totalBytes;

  /// The item being processed, when there is one.
  final String? currentFile;

  const SevenZipProgress(this.doneBytes, this.totalBytes, [this.currentFile]);

  /// 0.0 to 1.0, or null when the total is unknown.
  double? get fraction =>
      totalBytes > 0 ? (doneBytes / totalBytes).clamp(0.0, 1.0) : null;

  @override
  String toString() => 'SevenZipProgress($doneBytes of $totalBytes'
      '${currentFile == null ? '' : ', $currentFile'})';
}

/// Cancels background operations. Pass it to any number of operations;
/// [cancel] stops all of them.
///
/// A cancelled operation completes with a [SevenZipException] of kind
/// [SevenZipError.cancelled]. Its isolates are killed and the files it was
/// writing (the new archive, the file being extracted) are deleted; files
/// already extracted stay, and an archive being updated is left as it was.
class SevenZipCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }
}

/// A file or a directory (with everything below it) to add to an archive.
class SevenZipSource {
  /// Path on disk.
  final String path;

  /// Name inside the archive. Defaults to the last component of [path],
  /// as 7-Zip stores `7z a arc.7z /some/dir` under `dir/`. Use an empty
  /// string to store the contents of a directory at the top level.
  final String? storedAs;

  const SevenZipSource(this.path, {this.storedAs});
}

/// What to do when a file to extract already exists.
enum SevenZipOverwrite {
  /// Replace it (7-Zip -aoa).
  overwrite,

  /// Keep it and skip the item (7-Zip -aos).
  skip,

  /// Extract to a new name, `name_1.ext` (7-Zip -aou).
  rename,
}

/// Compression settings for [SevenZipArchive.add] and the other writing
/// operations. They become 7-Zip -m switches.
class SevenZipOptions {
  /// Compression level 0 (store) to 9, 7-Zip's -mx. Default 5.
  final int level;

  /// The main method (-m0): 'LZMA2' (default), 'LZMA', 'PPMd', 'Copy', or
  /// a method with properties such as 'LZMA2:d=64m' or 'PPMd:o=32:mem=256m'.
  final String? method;

  /// One solid block for all files (-ms=on, the default) or one block per
  /// file (-ms=off). [solidBlock] sets a 7-Zip size or count limit instead
  /// ('64m', '100f', 'e').
  final bool solid;
  final String? solidBlock;

  /// Branch filter for executables (-mf): 'BCJ', 'BCJ2', 'ARM64', 'off'...
  /// Default: 7-Zip's analysis of the files decides.
  final String? filter;

  /// Encrypts the file names too (-mhe). Needs a password. Null (the
  /// default) does what 7-Zip does: a new archive has readable names, an
  /// update keeps the names encrypted when they were.
  final bool? encryptHeaders;

  /// 7-Zip's -mmt. The 7z writer of this port encodes on one isolate, so
  /// for 7z this only selects the LZMA2 block layout (the archive then has
  /// the bytes 7-Zip writes with the same -mmt). Default 1: one LZMA2
  /// stream, the best ratio.
  final int? threads;

  /// Store symbolic links as links (7-Zip -snl). When false (the default),
  /// a link to a file is stored as the file it points to, and a link to a
  /// directory is skipped.
  final bool storeSymlinks;

  /// More -m switch bodies, applied last: 'd=64m', 'qs', 'hc=off', 'tm=off'.
  final List<String> switches;

  const SevenZipOptions({
    this.level = 5,
    this.method,
    this.solid = true,
    this.solidBlock,
    this.filter,
    this.encryptHeaders,
    this.threads,
    this.storeSymlinks = false,
    this.switches = const [],
  });

  CompressionOptions _toCompressionOptions(bool hasPassword) {
    final r = <String>[
      'x=$level',
      if (method != null) '0=$method',
      if (solidBlock != null) 's=$solidBlock' else 's=${solid ? 'on' : 'off'}',
      if (filter != null) 'f=$filter',
      'mt=${threads ?? 1}',
      if (encryptHeaders != null && hasPassword)
        'he=${encryptHeaders! ? 'on' : 'off'}',
      ...switches,
    ];
    return CompressionOptions.parse(r);
  }
}

/// The contents of a 7z archive.
class SevenZipListing {
  final List<SevenZipEntry> entries;
  final bool isSolid;

  /// Number of folders (solid blocks).
  final int numBlocks;
  final int physicalSize;
  final int headersSize;

  const SevenZipListing(this.entries, this.isSolid, this.numBlocks,
      this.physicalSize, this.headersSize);

  /// Total unpacked size of the files.
  int get totalSize => entries.fold(0, (s, e) => s + e.size);
}

/// An item that could not be extracted or tested.
class SevenZipItemError {
  final String path;
  final SevenZipError kind;
  const SevenZipItemError(this.path, this.kind);
  @override
  String toString() => '$path: ${kind.name}';
}

/// Result of [SevenZipArchive.extract] and [SevenZipArchive.test].
class SevenZipExtractResult {
  final int files;
  final int dirs;

  /// Unpacked bytes of the files that were extracted (or tested).
  final int bytes;

  /// Items not written because they existed ([SevenZipOverwrite.skip]).
  final int skipped;
  final List<SevenZipItemError> errors;

  const SevenZipExtractResult(
      this.files, this.dirs, this.bytes, this.skipped, this.errors);

  bool get ok => errors.isEmpty;

  /// True when the failures look like a wrong password (7zAES has no
  /// password check; wrong keys show as data or CRC errors).
  bool get wrongPassword =>
      errors.isNotEmpty &&
      errors.every((e) => e.kind == SevenZipError.wrongPassword);

  @override
  String toString() =>
      'SevenZipExtractResult($files files, $dirs dirs, $bytes bytes'
      '${skipped == 0 ? '' : ', $skipped skipped'}'
      '${errors.isEmpty ? '' : ', ${errors.length} errors'})';
}

/// Result of the operations that write a new version of the archive.
class SevenZipUpdateResult {
  /// Items written with new data (add) or changed (delete, rename).
  final int changed;

  /// Items of the old archive copied unchanged.
  final int kept;

  /// Input paths that could not be read, or were skipped.
  final List<String> skipped;
  final int archiveSize;

  const SevenZipUpdateResult(
      this.changed, this.kept, this.skipped, this.archiveSize);

  @override
  String toString() => 'SevenZipUpdateResult($changed changed, $kept kept, '
      '$archiveSize bytes${skipped.isEmpty ? '' : ', ${skipped.length} skipped'})';
}

// ---------------------------------------------------------------------------
// 7z archives

/// A 7z archive file (also split volumes: pass `name.7z.001`).
///
/// Every operation runs in a background isolate, so it never blocks the
/// UI isolate of a Flutter app. Operations that write take an optional
/// [SevenZipCancelToken] and report [SevenZipProgress].
class SevenZipArchive {
  final String path;

  /// Password for encrypted data and encrypted headers; for [add], new data
  /// is encrypted with it (7zAES, AES-256).
  final String? password;

  const SevenZipArchive(this.path, {this.password});

  /// Lists the archive.
  Future<SevenZipListing> list() {
    final archive = path, pw = password;
    return _run((ops) {
      final r = _openReader(archive, pw);
      try {
        return SevenZipListing(
            r.entries, r.isSolid, r.numBlocks, r.physicalSize, r.headersSize);
      } finally {
        _closeReader(r);
      }
    });
  }

  /// Extracts into [outputDir]. [paths] selects stored names; a directory
  /// name selects everything below it (default: everything). Modification
  /// times are restored; POSIX permissions are not (dart:io can not set
  /// them). Symbolic links stored with -snl are created last, after every
  /// file, so a link in the archive can not redirect other files.
  ///
  /// Each file is written as `name.zx-part` and renamed when it is complete
  /// and its CRC matched.
  Future<SevenZipExtractResult> extract(
    String outputDir, {
    List<String>? paths,
    SevenZipOverwrite overwrite = SevenZipOverwrite.overwrite,
    bool restoreTimes = true,
    void Function(SevenZipProgress progress)? onProgress,
    SevenZipCancelToken? cancel,
  }) {
    final archive = path, pw = password;
    return _run(
        (ops) => _extract(
            archive, pw, outputDir, paths, overwrite, restoreTimes, ops),
        onProgress: onProgress,
        cancel: cancel);
  }

  /// Decodes the selected items (default: all) and checks their CRCs
  /// without writing anything.
  Future<SevenZipExtractResult> test({
    List<String>? paths,
    void Function(SevenZipProgress progress)? onProgress,
    SevenZipCancelToken? cancel,
  }) {
    final archive = path, pw = password;
    return _run(
        (ops) => _extract(
            archive, pw, null, paths, SevenZipOverwrite.overwrite, false, ops),
        onProgress: onProgress,
        cancel: cancel);
  }

  /// Reads one stored file into memory.
  Future<Uint8List> readFile(String name) {
    final archive = path, pw = password;
    return _run((ops) {
      final r = _openReader(archive, pw);
      try {
        final n = _normalizeName(name);
        for (final e in r.entries) {
          if (!e.isDir && !e.isAnti && _normalizeName(e.path) == n) {
            return r.readItem(e.index);
          }
        }
        throw SevenZipException('$name: not found in archive');
      } finally {
        _closeReader(r);
      }
    });
  }

  /// Adds [sources] to the archive, creating it when it does not exist.
  /// Stored names that already exist are replaced, the other items are
  /// kept. The new archive is written next to the old one as
  /// `name.zx-part` and renamed over it at the end, like 7-Zip does.
  Future<SevenZipUpdateResult> add(
    List<SevenZipSource> sources, {
    SevenZipOptions options = const SevenZipOptions(),
    void Function(SevenZipProgress progress)? onProgress,
    SevenZipCancelToken? cancel,
  }) {
    final archive = path, pw = password;
    return _run((ops) => _add(archive, pw, sources, options, ops),
        onProgress: onProgress, cancel: cancel);
  }

  /// Deletes the items named [names] (a directory with everything below
  /// it). Returns the number of items removed in [SevenZipUpdateResult]
  /// `changed`.
  Future<SevenZipUpdateResult> delete(
    List<String> names, {
    SevenZipOptions options = const SevenZipOptions(),
    void Function(SevenZipProgress progress)? onProgress,
    SevenZipCancelToken? cancel,
  }) {
    final archive = path, pw = password;
    return _run(
        (ops) => _rewrite(archive, pw, options, ops, (e) {
              final n = _normalizeName(e.path);
              for (final d in names) {
                if (_isUnder(n, _normalizeName(d))) return null;
              }
              return SevenZipUpdateItem.keep(e.index);
            }),
        onProgress: onProgress,
        cancel: cancel);
  }

  /// Renames items: each key of [renames] is an old stored name, its value
  /// the new one. Renaming a directory renames everything below it. The
  /// data is not recompressed.
  Future<SevenZipUpdateResult> rename(
    Map<String, String> renames, {
    SevenZipOptions options = const SevenZipOptions(),
    void Function(SevenZipProgress progress)? onProgress,
    SevenZipCancelToken? cancel,
  }) {
    final archive = path, pw = password;
    final map = {
      for (final e in renames.entries)
        _normalizeName(e.key): _normalizeName(e.value)
    };
    return _run(
        (ops) => _rewrite(archive, pw, options, ops, (e) {
              final n = _normalizeName(e.path);
              for (final m in map.entries) {
                if (_isUnder(n, m.key)) {
                  return SevenZipUpdateItem.newProps(e.index,
                      path: m.value + n.substring(m.key.length),
                      isDir: e.isDir,
                      attrib: e.attrib,
                      cTime: e.cTime,
                      aTime: e.aTime,
                      mTime: e.mTime);
                }
              }
              return SevenZipUpdateItem.keep(e.index);
            }),
        onProgress: onProgress,
        cancel: cancel);
  }
}

// ---------------------------------------------------------------------------
// xz and lzma files

/// Compresses the file [input] to the xz file [output], like
/// `7z a -txz -mx<level>`. [filter] is a branch filter ('BCJ', 'ARM64'...,
/// or 'Delta:4'). [check] is the check size in bytes (0, 4 for CRC32, 8
/// for CRC64, 32 for SHA-256; default CRC32 like 7-Zip).
///
/// [threads] is 7-Zip's -mmt (default: [defaultThreads]). When 7-Zip would
/// cut the data into independent blocks for it (the file is larger than a
/// block, and from 4 threads at levels 5 to 9, which give each block two
/// LZMA threads, or from 2 threads at levels 1 to 4), worker isolates
/// encode the blocks in parallel, up to [threads] at a time, and the file
/// has the bytes `7z a -txz -mmt=<threads>` writes with the same switches.
/// The block size is 4 times the dictionary (128 MB at level 5, at least
/// 1 MB); `switches: ['s=4m']` sets it, like 7-Zip's -ms. Memory: each
/// worker holds an encoder (about 11 times the dictionary, which 7-Zip
/// reduces to the block size) plus its block in and out.
Future<void> xzCompressFile(
  String input,
  String output, {
  int level = 5,
  String? filter,
  int? check,
  int? threads,
  List<String> switches = const [],
  void Function(SevenZipProgress progress)? onProgress,
  SevenZipCancelToken? cancel,
}) {
  final n = threads ?? defaultThreads();
  return _run((ops) async {
    final size = File(input).lengthSync();
    final h = XzHandler();
    h.setPropertiesFromStrings(
        _xzProperties(level, filter, check, n, switches));
    final encoder = h.createEncoder(size);
    // The properties XzEnc.setProps normalizes.
    final normalized = encoder.xzProps.copy()..normalize();
    final part = ops.partFor(output);
    final inp = FileInStream.open(input);
    final out = FileOutStream.create(part);
    try {
      if (normalized.numBlockThreadsReduced > 1) {
        // 7-Zip gives each block thread two LZMA threads at levels 5 and up
        // (the multithreaded match finder, which isolates can not share).
        // The output depends only on the blocks, so use every thread
        // allowed for blocks: min(threads, number of blocks).
        final blockSize = normalized.blockSize;
        final numBlocks = (size + blockSize - 1) ~/ blockSize;
        final pool = await WorkerPool.spawn(
            (n < numBlocks ? n : numBlocks).clamp(2, 256),
            onSpawn: ops.child);
        try {
          await xzEncodeParallel(normalized, inp, out, pool,
              onBlock: (i, o) => ops.progress(i, size));
        } finally {
          pool.close();
        }
      } else {
        encoder.encode(inp, out, progress: (i, o) => ops.progress(i, size));
      }
      out.flush();
    } finally {
      out.close();
      inp.close();
    }
    ops.commit(part, output);
    ops.progress(size, size, force: true);
    return null;
  }, onProgress: onProgress, cancel: cancel);
}

/// Decompresses the xz file [input] to [output] (every stream of a
/// multi-stream file, as xz does). Throws [SevenZipException] on corrupt
/// data or a failed check.
Future<void> xzDecompressFile(
  String input,
  String output, {
  void Function(SevenZipProgress progress)? onProgress,
  SevenZipCancelToken? cancel,
}) {
  return _run((ops) {
    final inp = FileInStream.open(input);
    final part = ops.partFor(output);
    final out = FileOutStream.create(part);
    try {
      final total = inp.length;
      final a = XzArchive.open(inp);
      if (a == null) {
        throw const SevenZipException('Not an xz file', SevenZipError.isNotArc);
      }
      final res =
          a.extract(out, progress: (i, o) => ops.progress(inp.position, total));
      _checkResult(res);
      out.flush();
    } finally {
      out.close();
      inp.close();
    }
    ops.commit(part, output);
    return null;
  }, onProgress: onProgress, cancel: cancel);
}

/// Compresses the file [input] to the .lzma file [output], like `lzma e`
/// of the SDK (LzmaAlone). [properties] are LZMA properties in 7-Zip's -m
/// syntax, for example 'd=24:fb=64:lc=0'.
Future<void> lzmaCompressFile(
  String input,
  String output, {
  String properties = '',
  void Function(SevenZipProgress progress)? onProgress,
  SevenZipCancelToken? cancel,
}) {
  return _run((ops) {
    final inp = FileInStream.open(input);
    final part = ops.partFor(output);
    final out = FileOutStream.create(part);
    try {
      final size = inp.length;
      lzmaAloneEncode(inp, out,
          size: size,
          methodProps: properties,
          progress: (i, o) => ops.progress(i, size));
      out.flush();
    } finally {
      out.close();
      inp.close();
    }
    ops.commit(part, output);
    return null;
  }, onProgress: onProgress, cancel: cancel);
}

/// Decompresses the .lzma file [input] to [output].
Future<void> lzmaDecompressFile(
  String input,
  String output, {
  void Function(SevenZipProgress progress)? onProgress,
  SevenZipCancelToken? cancel,
}) {
  return _run((ops) {
    final inp = FileInStream.open(input);
    final part = ops.partFor(output);
    final out = FileOutStream.create(part);
    try {
      final total = inp.length;
      final a = LzmaAloneArchive.open(inp);
      if (a == null) {
        throw const SevenZipException(
            'Not an lzma file', SevenZipError.isNotArc);
      }
      _checkResult(a.extract(out,
          progress: (i, o) => ops.progress(inp.position, total)));
      out.flush();
    } finally {
      out.close();
      inp.close();
    }
    ops.commit(part, output);
    return null;
  }, onProgress: onProgress, cancel: cancel);
}

// ---------------------------------------------------------------------------
// In memory helpers. They run on the calling isolate: use them for small
// data, or call them inside Isolate.run.

/// Compresses [data] to an xz stream (one thread; see [xzCompressFile] for
/// the parameters). Runs on the calling isolate.
Uint8List xzCompress(Uint8List data,
    {int level = 5,
    String? filter,
    int? check,
    List<String> switches = const []}) {
  final out = MemoryOutStream(data.length ~/ 2 + 1024);
  XzArchive.create(MemoryInStream(data), out, data.length,
      properties: _xzProperties(level, filter, check, 1, switches));
  return Uint8List.fromList(out.toBytes());
}

/// Decompresses an xz stream. Runs on the calling isolate.
Uint8List xzDecompress(Uint8List data) {
  final a = XzArchive.openSeq(MemoryInStream(data));
  final out = MemoryOutStream(data.length * 4 + 1024);
  _checkResult(a.extract(out));
  return Uint8List.fromList(out.toBytes());
}

/// Compresses [data] to the .lzma format ([lzmaCompressFile]). Runs on the
/// calling isolate.
Uint8List lzmaCompress(Uint8List data, {String properties = ''}) {
  final out = MemoryOutStream(data.length ~/ 2 + 1024);
  lzmaAloneEncode(MemoryInStream(data), out,
      size: data.length, methodProps: properties);
  return Uint8List.fromList(out.toBytes());
}

/// Decompresses .lzma data. Runs on the calling isolate.
Uint8List lzmaDecompress(Uint8List data) {
  final a = LzmaAloneArchive.openSeq(MemoryInStream(data));
  final out = MemoryOutStream(data.length * 4 + 1024);
  _checkResult(a.extract(out));
  return Uint8List.fromList(out.toBytes());
}

/// Builds a 7z archive in memory from [files] (stored name to content).
/// Runs on the calling isolate.
Uint8List sevenZipCompressBytes(Map<String, Uint8List> files,
    {SevenZipOptions options = const SevenZipOptions(), String? password}) {
  final out = MemoryOutStream();
  final now = dateTimeToFileTime(DateTime.now());
  SevenZipWriter.update(
      out: out,
      items: [
        for (final e in files.entries)
          SevenZipUpdateItem.file(
              path: e.key,
              size: e.value.length,
              mTime: now,
              attrib: FileAttrib.archive,
              open: () => MemoryInStream(e.value)),
      ],
      options: options._toCompressionOptions(password != null),
      password: password);
  return Uint8List.fromList(out.toBytes());
}

/// Reads every file of an in-memory 7z archive (stored name to content;
/// directories are left out). Runs on the calling isolate. Throws
/// [SevenZipException] on errors.
Map<String, Uint8List> sevenZipDecompressBytes(Uint8List archive,
    {String? password}) {
  final r = SevenZipReader.open(MemoryInStream(archive), password: password);
  final result = <String, Uint8List>{};
  for (final e in r.entries) {
    if (!e.isDir && !e.isAnti) result[e.path] = r.readItem(e.index);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Worker side

List<MapEntry<String, String>> _xzProperties(int level, String? filter,
        int? check, int threads, List<String> switches) =>
    CompressionOptions.parse([
      'x=$level',
      if (filter != null) 'f=$filter',
      if (check != null) 'crc=$check',
      'mt=$threads',
      ...switches,
    ]).properties;

void _checkResult(int res) {
  if (res == OperationResult.ok) return;
  throw SevenZipException('Result $res', _errorOf(res));
}

SevenZipError _errorOf(int opRes) => opRes >= 1 && opRes <= 9
    ? SevenZipError.values[opRes - 1]
    : SevenZipError.data;

SevenZipReader _openReader(String path, String? password) {
  final SeekableInStream s;
  if (RegExp(r'\.\d{3}$').hasMatch(path)) {
    s = MultiInStream.openFiles(path) ?? FileInStream.open(path);
  } else {
    s = FileInStream.open(path);
  }
  try {
    return SevenZipReader.open(s, password: password);
  } catch (_) {
    _closeStream(s);
    rethrow;
  }
}

void _closeStream(SeekableInStream s) {
  if (s is FileInStream) s.close();
  if (s is MultiInStream) s.close();
}

void _closeReader(SevenZipReader r) => _closeStream(r.stream);

/// Stored names use '/'; 7-Zip on Windows may store '\'.
String _normalizeName(String n) {
  var s = n.replaceAll('\\', '/');
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  return s;
}

bool _isUnder(String name, String dir) =>
    dir.isEmpty ||
    name == dir ||
    (name.length > dir.length &&
        name.startsWith(dir) &&
        name.codeUnitAt(dir.length) == 0x2F);

/// A stored name as a relative path that stays inside the output folder:
/// no root, no drive, no '.' or '..' components. Null when nothing is
/// left.
String? _safeRelativePath(String name) {
  final parts = <String>[];
  for (var p in name.replaceAll('\\', '/').split('/')) {
    if (p.isEmpty || p == '.' || p == '..') continue;
    // Windows: the corrections of ExtractingFilePath.cpp (characters that
    // Windows does not allow, dots and spaces at the end, device names)
    if (Platform.isWindows) p = getCorrectFsFileName(p);
    parts.add(p);
  }
  if (parts.isEmpty) return null;
  return parts.join(Platform.pathSeparator);
}

String _renamedTarget(String target) {
  final sep = target.lastIndexOf(Platform.pathSeparator);
  final dot = target.lastIndexOf('.');
  final hasExt = dot > sep + 1;
  final base = hasExt ? target.substring(0, dot) : target;
  final ext = hasExt ? target.substring(dot) : '';
  for (var i = 1;; i++) {
    final t = '${base}_$i$ext';
    if (FileSystemEntity.typeSync(t, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return t;
    }
  }
}

SevenZipExtractResult _extract(
    String archive,
    String? password,
    String? outDir,
    List<String>? paths,
    SevenZipOverwrite overwrite,
    bool restoreTimes,
    _Ops ops) {
  final r = _openReader(archive, password);
  try {
    final sel = paths?.map(_normalizeName).toList();
    List<int>? indices;
    if (sel != null) {
      indices = [
        for (final e in r.entries)
          if (sel.any((d) => _isUnder(_normalizeName(e.path), d))) e.index
      ];
    }
    var files = 0, dirs = 0, bytes = 0, skipped = 0;
    final errors = <SevenZipItemError>[];
    String? current;
    var total = 0;
    void progress(int done, int t) {
      total = t;
      ops.progress(done, t, file: current);
    }

    if (outDir == null) {
      // No output streams: the data is decoded and checked (the
      // callback's test path), with progress.
      final results = r.extract(indices, progress: progress, open: (e) {
        current = e.path;
        return null;
      });
      for (final it in results) {
        final e = r.entries[it.index];
        if (it.ok) {
          if (e.isDir) {
            dirs++;
          } else {
            files++;
            bytes += e.size;
          }
        } else {
          errors.add(SevenZipItemError(
              e.path,
              it.possiblyWrongPassword
                  ? SevenZipError.wrongPassword
                  : _errorOf(it.result)));
        }
      }
      return SevenZipExtractResult(files, dirs, bytes, 0, errors);
    }

    final root = Directory(outDir)..createSync(recursive: true);
    final rootPath = root.path;
    final links = <(String, String)>[];
    final times = <(String, DateTime)>[];

    // State of the item being extracted.
    var curIndex = -1;
    String? target, part;
    FileOutStream? out;
    MemoryOutStream? linkData;
    var skip = false;

    r.extract(indices, progress: progress, open: (e) {
      curIndex = e.index;
      target = part = null;
      out = null;
      linkData = null;
      skip = false;
      current = e.path;
      if (e.isAnti) return null;
      final rel = _safeRelativePath(e.path);
      if (rel == null) return null;
      var t = '$rootPath${Platform.pathSeparator}$rel';
      if (e.isDir) {
        Directory(t).createSync(recursive: true);
        target = t;
        return null;
      }
      final exists = FileSystemEntity.typeSync(t, followLinks: false) !=
          FileSystemEntityType.notFound;
      if (exists) {
        switch (overwrite) {
          case SevenZipOverwrite.skip:
            skip = true;
            return null;
          case SevenZipOverwrite.rename:
            t = _renamedTarget(t);
          case SevenZipOverwrite.overwrite:
            break;
        }
      }
      target = t;
      if (e.isSymlink && !Platform.isWindows) {
        return linkData = MemoryOutStream();
      }
      File(t).parent.createSync(recursive: true);
      final p = ops.partFor(t);
      part = p;
      return out = FileOutStream.create(p);
    }, done: (e, res) {
      final opened = curIndex == e.index;
      out?.close();
      final ok = res == OperationResult.ok;
      if (!ok) {
        if (part != null) {
          ops.discard(part!);
        }
        errors.add(SevenZipItemError(
            e.path,
            e.encrypted &&
                    (res == OperationResult.dataError ||
                        res == OperationResult.crcError)
                ? SevenZipError.wrongPassword
                : _errorOf(res)));
      } else if (skip && opened) {
        skipped++;
      } else if (e.isAnti) {
        // nothing to do
      } else if (e.isDir) {
        dirs++;
      } else {
        var t = target;
        if (!opened || t == null) {
          // No stream was requested: an empty file.
          final rel = _safeRelativePath(e.path);
          if (rel != null) {
            t = '$rootPath${Platform.pathSeparator}$rel';
            File(t).parent.createSync(recursive: true);
            File(t).writeAsBytesSync(const []);
          }
        } else if (linkData != null) {
          links
              .add((t, utf8.decode(linkData!.toBytes(), allowMalformed: true)));
        } else if (part != null) {
          ops.commit(part!, t);
        } else {
          File(t).writeAsBytesSync(const []);
        }
        if (t != null && restoreTimes && linkData == null) {
          final m = e.modified;
          if (m != null) times.add((t, m));
        }
        files++;
        bytes += e.size;
      }
      curIndex = -1;
      target = part = null;
      out = null;
      linkData = null;
    });

    for (final (t, m) in times) {
      try {
        File(t).setLastModifiedSync(m);
      } on FileSystemException {
        // not fatal
      }
    }
    for (final (t, target) in links) {
      try {
        if (FileSystemEntity.typeSync(t, followLinks: false) !=
            FileSystemEntityType.notFound) {
          File(t).deleteSync();
        }
        Link(t).createSync(target);
      } on FileSystemException {
        errors.add(SevenZipItemError(t, SevenZipError.io));
      }
    }
    ops.progress(total, total, force: true);
    return SevenZipExtractResult(files, dirs, bytes, skipped, errors);
  } finally {
    _closeReader(r);
  }
}

/// One file or directory found by the scan.
class _Scanned {
  final String disk;
  final String stored;
  final FileSystemEntityType type;
  final FileStat stat;
  _Scanned(this.disk, this.stored, this.type, this.stat);
}

void _scan(String disk, String stored, bool storeLinks, List<_Scanned> out,
    List<String> skipped) {
  var type = FileSystemEntity.typeSync(disk, followLinks: false);
  if (type == FileSystemEntityType.link && !storeLinks) {
    type = FileSystemEntity.typeSync(disk);
    // A link to a directory is skipped: following it could loop.
    if (type != FileSystemEntityType.file) {
      skipped.add(disk);
      return;
    }
  }
  if (type == FileSystemEntityType.notFound) {
    skipped.add(disk);
    return;
  }
  final stat = type == FileSystemEntityType.link
      ? Link(disk).statSync()
      : FileStat.statSync(disk);
  if (stored.isNotEmpty) out.add(_Scanned(disk, stored, type, stat));
  if (type == FileSystemEntityType.directory) {
    final List<FileSystemEntity> children;
    try {
      children = Directory(disk).listSync(followLinks: false);
    } on FileSystemException {
      skipped.add(disk);
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final c in children) {
      final name =
          c.path.substring(c.path.lastIndexOf(Platform.pathSeparator) + 1);
      _scan(c.path, stored.isEmpty ? name : '$stored/$name', storeLinks, out,
          skipped);
    }
  }
}

// The attributes 7-Zip stores for a file or directory: on Windows the
// FILE_ATTRIBUTE_* value (dart:io gives the read-only state only), on POSIX
// the st_mode in the high 16 bits (FILE_ATTRIBUTE_UNIX_EXTENSION).
int _diskAttrib(bool isDir, int mode) {
  if (Platform.isWindows) {
    var a = isDir ? FileAttrib.directory : FileAttrib.archive;
    if ((mode & 0x92) == 0) a |= FileAttrib.readOnly;
    return a;
  }
  return (isDir ? FileAttrib.directory : FileAttrib.archive) |
      FileAttrib.unixExtension |
      (((isDir ? 0x4000 : 0x8000) | mode) << 16);
}

SevenZipUpdateItem _newItem(_Scanned s, int indexInArchive) {
  final mt = dateTimeToFileTime(s.stat.modified);
  final mode = s.stat.mode & 0xFFF;
  switch (s.type) {
    case FileSystemEntityType.directory:
      return SevenZipUpdateItem.dir(
          path: s.stored,
          mTime: mt,
          attrib: _diskAttrib(true, mode),
          indexInArchive: indexInArchive);
    case FileSystemEntityType.link:
      final data = Uint8List.fromList(
          const Utf8Encoder().convert(Link(s.disk).targetSync()));
      return SevenZipUpdateItem.file(
          path: s.stored,
          size: data.length,
          mTime: mt,
          attrib: FileAttrib.archive |
              FileAttrib.unixExtension |
              ((0xA000 | 0x1FF) << 16),
          open: () => MemoryInStream(data),
          indexInArchive: indexInArchive);
    default:
      final disk = s.disk;
      return SevenZipUpdateItem.file(
          path: s.stored,
          size: s.stat.size,
          mTime: mt,
          attrib: _diskAttrib(false, mode),
          open: () {
            try {
              return FileInStream.open(disk);
            } on FileSystemException {
              return null;
            }
          },
          indexInArchive: indexInArchive);
  }
}

SevenZipUpdateResult _add(String archive, String? password,
    List<SevenZipSource> sources, SevenZipOptions options, _Ops ops) {
  final scanned = <_Scanned>[];
  final skipped = <String>[];
  for (final s in sources) {
    var disk = s.path;
    while (disk.length > 1 && disk.endsWith(Platform.pathSeparator)) {
      disk = disk.substring(0, disk.length - 1);
    }
    final stored = _normalizeName(s.storedAs ??
        disk.substring(disk.lastIndexOf(Platform.pathSeparator) + 1));
    _scan(disk, stored, options.storeSymlinks, scanned, skipped);
  }
  final newByName = <String, _Scanned>{};
  for (final s in scanned) {
    newByName[s.stored] = s;
  }
  return _update(archive, password, options, ops, (old) {
    final items = <SevenZipUpdateItem>[];
    var kept = 0;
    if (old != null) {
      for (final e in old.entries) {
        if (newByName.containsKey(_normalizeName(e.path))) continue;
        items.add(SevenZipUpdateItem.keep(e.index));
        kept++;
      }
    }
    for (final s in newByName.values) {
      items.add(_newItem(s, -1));
    }
    return (items, items.length - kept, kept);
  }, skipped);
}

SevenZipUpdateResult _rewrite(
    String archive,
    String? password,
    SevenZipOptions options,
    _Ops ops,
    SevenZipUpdateItem? Function(SevenZipEntry e) map) {
  if (!File(archive).existsSync()) {
    throw SevenZipException('$archive: not found', SevenZipError.io);
  }
  return _update(archive, password, options, ops, (old) {
    final items = <SevenZipUpdateItem>[];
    var changed = 0, kept = 0;
    for (final e in old!.entries) {
      final it = map(e);
      if (it == null) {
        changed++;
      } else if (it.newProps) {
        items.add(it);
        changed++;
      } else {
        items.add(it);
        kept++;
      }
    }
    return (items, changed, kept);
  }, const []);
}

SevenZipUpdateResult _update(
    String archive,
    String? password,
    SevenZipOptions options,
    _Ops ops,
    (List<SevenZipUpdateItem>, int, int) Function(SevenZipReader? old) build,
    List<String> skipped) {
  final old =
      File(archive).existsSync() ? _openReader(archive, password) : null;
  final part = ops.partFor(archive);
  int size;
  int changed, kept;
  try {
    final (items, c, k) = build(old);
    changed = c;
    kept = k;
    final out = FileOutStream.create(part);
    try {
      SevenZipWriter.update(
          old: old,
          out: out,
          items: items,
          options: options._toCompressionOptions(password != null),
          password: password,
          progress: (done, total) => ops.progress(done, total));
      out.flush();
      size = out.length;
    } finally {
      out.close();
    }
  } catch (_) {
    if (old != null) _closeReader(old);
    ops.discard(part);
    rethrow;
  }
  if (old != null) _closeReader(old);
  ops.commit(part, archive);
  return SevenZipUpdateResult(changed, kept, skipped, size);
}

// ---------------------------------------------------------------------------
// Isolates

/// The worker side of one operation: throttled progress, the files it is
/// writing (deleted if the operation is cancelled) and its child isolates
/// (killed with it).
class _Ops {
  final SendPort _port;
  final bool _wantProgress;
  final Stopwatch _sw = Stopwatch()..start();
  int _last = -1000;

  _Ops(this._port, this._wantProgress);

  void progress(int done, int total, {String? file, bool force = false}) {
    if (!_wantProgress) return;
    final t = _sw.elapsedMilliseconds;
    if (force || t - _last >= 100) {
      _last = t;
      _port.send(('p', SevenZipProgress(done, total, file)));
    }
  }

  /// The temporary name of [path] while it is written, registered for
  /// deletion on cancellation.
  String partFor(String path) {
    final p = '$path.zx-part';
    _port.send(('f+', p));
    return p;
  }

  /// Renames a finished [part] to [path].
  void commit(String part, String path) {
    if (Platform.isWindows && File(path).existsSync()) File(path).deleteSync();
    File(part).renameSync(path);
    _port.send(('f-', part));
  }

  void discard(String part) {
    try {
      File(part).deleteSync();
    } on FileSystemException {
      // already gone
    }
    _port.send(('f-', part));
  }

  void child(Isolate i) =>
      _port.send(('i', i.controlPort, i.terminateCapability));
}

typedef _Body = FutureOr<Object?> Function(_Ops ops);

Future<void> _isolateMain((SendPort, _Body, bool) args) async {
  final (port, body, wantProgress) = args;
  final ops = _Ops(port, wantProgress);
  Object? r;
  try {
    r = await body(ops);
  } catch (e, st) {
    try {
      port.send(('err', e, st.toString()));
    } catch (_) {
      port.send(('err', e.toString(), st.toString()));
    }
    return;
  }
  Isolate.exit(port, ('ok', r));
}

/// Runs [body] in a new isolate. Progress events go to [onProgress] on the
/// calling isolate; [cancel] kills the isolate and its children, then
/// deletes the files registered with [_Ops.partFor].
Future<R> _run<R>(_Body body,
    {void Function(SevenZipProgress)? onProgress,
    SevenZipCancelToken? cancel}) async {
  if (cancel != null && cancel.isCancelled) {
    throw const SevenZipException('Cancelled', SevenZipError.cancelled);
  }
  final port = RawReceivePort();
  final done = Completer<R>();
  final isolates = <Isolate>[];
  final parts = <String>{};
  var cancelled = false;

  void finish(Object? error, [StackTrace? st]) {
    port.close();
    if (done.isCompleted) return;
    if (error != null) {
      done.completeError(error, st);
    }
  }

  void deleteParts() {
    for (final p in parts) {
      try {
        File(p).deleteSync();
      } on FileSystemException {
        // already gone
      }
    }
    parts.clear();
  }

  void killAll() {
    for (final i in isolates) {
      i.kill(priority: Isolate.immediate);
    }
  }

  port.handler = (Object? m) {
    switch (m) {
      case ('p', final SevenZipProgress p):
        if (!cancelled) onProgress?.call(p);
      case ('f+', final String p):
        parts.add(p);
      case ('f-', final String p):
        parts.remove(p);
      case ('i', final SendPort cp, final Capability? cap):
        final i = Isolate(cp, terminateCapability: cap);
        isolates.add(i);
        if (cancelled) i.kill(priority: Isolate.immediate);
      case ('ok', final Object? v):
        if (!done.isCompleted) done.complete(v as R);
        finish(null);
      case ('err', final Object e, final String st):
        killAll(); // children left by a failed operation
        deleteParts();
        finish(e, StackTrace.fromString(st));
      case [final Object? e, final Object? st]:
        // An uncaught asynchronous error (onError).
        killAll();
        finish(e ?? 'isolate error',
            st == null ? null : StackTrace.fromString('$st'));
      case null:
        // The isolate exited (onExit), killed or after a result.
        killAll();
        if (!done.isCompleted) {
          deleteParts();
          finish(cancelled
              ? const SevenZipException('Cancelled', SevenZipError.cancelled)
              : const SevenZipException(
                  'Worker isolate exited', SevenZipError.io));
        }
    }
  };

  void onCancel() {
    if (done.isCompleted || cancelled) return;
    cancelled = true;
    killAll();
  }

  cancel?._listeners.add(onCancel);
  try {
    final iso = await Isolate.spawn(
        _isolateMain, (port.sendPort, body, onProgress != null),
        onExit: port.sendPort, onError: port.sendPort);
    isolates.add(iso);
    if (cancelled) iso.kill(priority: Isolate.immediate);
  } catch (_) {
    port.close();
    cancel?._listeners.remove(onCancel);
    rethrow;
  }
  try {
    return await done.future;
  } finally {
    cancel?._listeners.remove(onCancel);
  }
}
