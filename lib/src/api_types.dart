// The types of the background operations that the callers of api.dart and
// zx_api.dart hold (progress, cancel token, source). Plain Dart: the web
// client (lib/zx_client.dart) compiles them with dart2js too.

import 'io/streams.dart' show SevenZipException, SevenZipError;

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

  /// Calls [listener] when [cancel] is called (for the operations of
  /// `zx_api.dart`). Remove it with [removeCancelListener].
  void addCancelListener(void Function() listener) => _listeners.add(listener);

  void removeCancelListener(void Function() listener) =>
      _listeners.remove(listener);
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
