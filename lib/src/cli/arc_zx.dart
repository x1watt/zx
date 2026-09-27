// The .zx handler seen through the CLI's IInArchive / IOutArchive shape
// (see arc_handlers.dart). Not in 7-Zip: .zx is zx's own format
// (docs/zx-format.md).
//
// Besides updateItems (a new archive into a stream, used for -so), the
// adapter writes updates itself ([updateFile], called by update.dart and
// zx_worker.dart): an existing archive gets a generation appended in place,
// a volume set gets new volumes, and -mcompact rewrites the archive after
// the update.

import 'dart:typed_data';

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../format/zx/zx_format.dart';
import '../format/zx/zx_handler.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';

/// IsArc for .zx: the magic.
int isArcZx(Uint8List p, int size) {
  if (size < 8) {
    for (var i = 0; i < size; i++) {
      if (p[i] != zxMagic[i]) return 0;
    }
    return 2;
  }
  return ZxHeader.hasMagic(p) ? 1 : 0;
}

/// The zx handler (.zx).
class ZxArc extends InArchive {
  final ZxHandler h = ZxHandler();
  String? _openedPath;

  /// The path of the file opened (null for a stream).
  String? get openedPath => _openedPath;

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    callback?.setTotal(null, stream.length);
    _openedPath = callback?.archivePath;
    try {
      return h.open(stream,
              path: _openedPath,
              password: callback == null
                  ? null
                  : () => callback.cryptoGetTextPassword())
          ? HRes.sOk
          : HRes.sFalse;
    } on SevenZipException catch (e) {
      if (e.kind == SevenZipError.headers) return HRes.sFalse;
      rethrow;
    }
  }

  @override
  int openSeq(InStream stream) => h.openSeq(stream) ? HRes.sOk : HRes.sFalse;

  @override
  void close() => h.close();

  @override
  int get numberOfItems => h.numberOfItems;

  @override
  Object? getProperty(int index, int propId) => h.getProperty(index, propId);

  @override
  Object? getArchiveProperty(int propId) => h.getArchiveProperty(propId);

  @override
  List<int> get itemPropIds => ZxHandler.itemPropIds;

  @override
  List<int> get archivePropIds => ZxHandler.archivePropIds;

  @override
  int get timePrec => kTimePrec100ns;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    String? Function()? pw;
    if (cb is CryptoGetTextPassword) {
      final c = cb as CryptoGetTextPassword;
      pw = () => c.cryptoGetTextPassword();
    }
    h.extract(indices, testMode, cb, password: pw);
  }

  @override
  SeekableInStream? getStream(int index) => h.getStream(index);

  @override
  bool get supportsUpdate => true;

  @override
  int getFileTimeType() => FileTimeType.windows;

  @override
  void setProperties(List<MapEntry<String, PropVariant>> props) =>
      h.setProperties(props);

  String? _newPassword(ArchiveUpdateCallback cb) {
    if (cb is CryptoGetTextPassword2) {
      return (cb as CryptoGetTextPassword2).cryptoGetTextPassword2();
    }
    return null;
  }

  @override
  void updateItems(
      OutStream out, int numItems, ArchiveUpdateCallback callback) {
    h.updateItems(out, numItems, callback, newPassword: _newPassword(callback));
  }

  /// Writes the update of the archive at [path] (the file opened, or a new
  /// one) and compacts it after when -mcompact is set. Returns the files
  /// written (new volumes, a new file) and the warnings.
  ZxUpdateFileResult updateFile(
      String path, int numItems, ArchiveUpdateCallback callback,
      {List<int> volumeSizes = const [], void Function(String path)? onFile}) {
    final r = h.updateFile(path, numItems, callback,
        volumeSizes: volumeSizes,
        newPassword: _newPassword(callback),
        onFile: onFile);
    final keep = h.options.compactKeep;
    if (keep != null) {
      compactFile(r.files.isNotEmpty ? r.files.last : path, keep,
          onFile: onFile, reopenFrom: h.archivePath ?? path);
    }
    return r;
  }

  /// Compacts the archive at [path] (see ZxHandler.compact); the handler
  /// opens it again first (from [reopenFrom] when given). [password] is the
  /// archive's password (the keys found before are kept).
  int compactFile(String path, int keep,
      {void Function(String path)? onFile,
      String? reopenFrom,
      String? password}) {
    final keys = h.reader?.keys;
    final pw = password ?? h.options.write.password;
    final from = reopenFrom ?? path;
    h.close();
    final src = FileInStream.open(from);
    try {
      if (!h.open(src, path: from, password: () => pw)) {
        throw const SevenZipException('zx: not a zx archive');
      }
      h.reader!.keys ??= keys;
      return h.compact(from, keep, password: pw, onFile: onFile);
    } finally {
      h.close();
      src.close();
    }
  }
}
