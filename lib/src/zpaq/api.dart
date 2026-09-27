// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'archive/add.dart';
import 'archive/archive_io.dart';
import 'archive/extract.dart';
import 'archive/index.dart';
import 'archive/zdate.dart';
import 'core/io.dart';
import 'pool.dart';

/// Contents of an archive as of one version.
class ZpaqListing {
  /// All versions up to the selected one.
  final List<ZpaqVersion> versions;

  /// Files and directories present in the selected version, sorted by name.
  final List<ZpaqEntry> entries;

  /// Every index entry of every listed version (only with allVersions).
  final List<ZpaqEntry>? history;

  /// True if the archive ends with an interrupted update, which the next
  /// add will overwrite.
  final bool incomplete;

  final List<String> warnings;

  const ZpaqListing(this.versions, this.entries, this.history, this.incomplete,
      this.warnings);
}

/// A zpaq journaling archive (compatible with zpaq 7.15 and zpaqfranz).
///
/// All operations run in a background isolate, so they never block the UI
/// isolate of a Flutter app.
class ZpaqArchive {
  /// Archive file path.
  final String path;

  /// Password for an encrypted (zpaq `-key`) archive.
  final String? password;

  ZpaqArchive(this.path, {this.password});

  /// Adds (or updates) [sources] as a new version. Unchanged files are not
  /// read again and repeated content is stored once.
  ///
  /// [options.key] is ignored; the archive [password] is used instead.
  Future<ZpaqAddResult> add(
    List<ZpaqSource> sources, {
    ZpaqAddOptions options = const ZpaqAddOptions(),
    void Function(ZpaqAddProgress progress)? onProgress,
  }) {
    final archive = path;
    final pw = password;
    return _runWithProgress<ZpaqAddResult, ZpaqAddProgress>(
      (send) async {
        final opt = ZpaqAddOptions(
          method: options.method,
          fragment: options.fragment,
          deleteMissing: options.deleteMissing,
          storeHashes: options.storeHashes,
          fileHash: options.fileHash,
          force: options.force,
          key: pw == null ? null : ZpaqKey.fromPassword(pw),
          threads: options.threads,
          filter: options.filter,
          noAttributes: options.noAttributes,
          date: options.date,
        );
        return addToArchive(archive, sources,
            options: opt, onProgress: send == null ? null : _throttle(send));
      },
      onProgress,
    );
  }

  /// Lists the archive as of [version] (1-based, default latest) or of the
  /// last version not newer than [until].
  Future<ZpaqListing> list(
      {int? version, DateTime? until, bool allVersions = false}) {
    final archive = path;
    final pw = password;
    return Isolate.run(() {
      final input = _open(archive, pw);
      try {
        final idx = readIndex(input,
            untilVersion: version,
            untilDate: until == null ? null : dateTimeToDecimal(until),
            keepHistory: allVersions);
        return ZpaqListing(idx.versions, idx.entries, idx.history,
            idx.incomplete, idx.warnings);
      } finally {
        input.close();
      }
    });
  }

  /// Restores files into [outputDir]. [paths] selects stored names (a
  /// directory selects everything below it); default is everything.
  Future<ZpaqExtractResult> extract(
    String outputDir, {
    List<String>? paths,
    int? version,
    DateTime? until,
    bool overwrite = true,
    bool restoreDates = true,
    int? threads,
    void Function(ZpaqExtractProgress progress)? onProgress,
  }) {
    final archive = path;
    final pw = password;
    return _runWithProgress<ZpaqExtractResult, ZpaqExtractProgress>(
      (send) => _extract(
          archive,
          pw,
          outputDir,
          paths,
          version,
          until == null ? null : dateTimeToDecimal(until),
          overwrite,
          restoreDates,
          threads,
          send == null ? null : _throttle(send)),
      onProgress,
    );
  }

  /// Decompresses the selected version and checks every block and fragment
  /// checksum without writing anything.
  Future<ZpaqExtractResult> verify({
    int? version,
    List<String>? paths,
    int? threads,
    void Function(ZpaqExtractProgress progress)? onProgress,
  }) {
    final archive = path;
    final pw = password;
    return _runWithProgress<ZpaqExtractResult, ZpaqExtractProgress>(
      (send) => _extract(archive, pw, null, paths, version, null, true, false,
          threads, send == null ? null : _throttle(send)),
      onProgress,
    );
  }

  /// Reads one stored file into memory.
  Future<Uint8List> readFile(String name, {int? version}) {
    final archive = path;
    final pw = password;
    return Isolate.run(() {
      final input = _open(archive, pw);
      try {
        final idx = readIndex(input, untilVersion: version);
        final e = idx.files[name.replaceAll('\\', '/')];
        if (e == null || e.isDeleted || e.isDirectory) {
          zpaqError('$name: not found in archive');
        }
        return readEntry(input, idx, e);
      } finally {
        input.close();
      }
    });
  }
}

Future<ZpaqExtractResult> _extract(
    String archive,
    String? pw,
    String? outputDir,
    List<String>? paths,
    int? version,
    int? untilDate,
    bool overwrite,
    bool restoreDates,
    int? threads,
    void Function(ZpaqExtractProgress)? onProgress) async {
  final key = pw == null ? null : ZpaqKey.fromPassword(pw);
  final input = _open(archive, pw, key);
  WorkerPool? pool;
  try {
    final idx = readIndex(input, untilVersion: version, untilDate: untilDate);
    final sel =
        idx.entries.where((e) => matchesSelection(e.name, paths)).toList();
    final n = threads ?? defaultThreads();
    if (n > 1 && idx.blocks.length > 1) pool = await WorkerPool.spawn(n);
    return await extractEntries(input, idx, sel,
        outputDir: outputDir,
        overwrite: overwrite,
        restoreDates: restoreDates,
        pool: pool,
        archivePath: archive,
        key: key,
        onProgress: onProgress);
  } finally {
    pool?.close();
    input.close();
  }
}

ArchiveInput _open(String archive, String? pw, [ZpaqKey? key]) =>
    openArchive(archive, key ?? (pw == null ? null : ZpaqKey.fromPassword(pw)));

/// Forwards at most one event per 100 ms, plus the last one.
void Function(T) _throttle<T>(void Function(T) f) {
  var last = 0;
  final sw = Stopwatch()..start();
  return (T p) {
    final t = sw.elapsedMilliseconds;
    final isFinal = (p is ZpaqAddProgress && p.currentFile == null) ||
        (p is ZpaqExtractProgress && p.doneBytes >= p.totalBytes);
    if (isFinal || t - last >= 100 || last == 0) {
      last = t == 0 ? 1 : t;
      f(p);
    }
  };
}

/// Runs [body] in a new isolate, forwarding progress events to [onProgress]
/// on the calling isolate.
Future<R> _runWithProgress<R, P>(
  Future<R> Function(void Function(P)? send) body,
  void Function(P)? onProgress,
) async {
  if (onProgress == null) {
    return Isolate.run(() => body(null));
  }
  final port = ReceivePort();
  final sub = port.listen((m) => onProgress(m as P));
  final sendPort = port.sendPort;
  try {
    return await Isolate.run(() => body((P p) => sendPort.send(p)));
  } finally {
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    port.close();
  }
}
