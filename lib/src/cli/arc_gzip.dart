// The gzip handler (lib/src/format/gzip) seen through the InArchive shape
// of arc_handlers.dart, as the UI code calls IInArchive / IOutArchive.

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../format/gzip/gzip_handler.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';

// k_PropVar_TimePrec_Unix: MTIME is in whole seconds
const int _kTimePrecUnix = 1;

/// The gzip handler.
class GzipArc extends InArchive {
  final GzipHandler h = GzipHandler();

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    final ok = h.open(stream, callback: _GzipOpenProgress(callback));
    return ok ? HRes.sOk : HRes.sFalse;
  }

  @override
  int openSeq(InStream stream) {
    h.openSeq(stream);
    return HRes.sOk;
  }

  @override
  void close() => h.close();

  @override
  int get numberOfItems => h.numberOfItems;

  @override
  Object? getProperty(int index, int propId) => h.getProperty(index, propId);

  @override
  Object? getArchiveProperty(int propId) => h.getArchiveProperty(propId);

  @override
  List<int> get itemPropIds => GzipHandler.itemPropIds;

  @override
  List<int> get archivePropIds => GzipHandler.archivePropIds;

  @override
  int get timePrec => _kTimePrecUnix;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      h.extract(indices, testMode, cb);

  @override
  InStream? getSeqStream(int index) => index == 0 ? h.getSeqStream() : null;

  @override
  bool get supportsUpdate => true;

  @override
  int getFileTimeType() => h.getFileTimeType();

  @override
  void setProperties(List<MapEntry<String, PropVariant>> props) =>
      h.setProperties(props);

  @override
  void updateItems(
      OutStream out, int numItems, ArchiveUpdateCallback callback) {
    // the C++ handler releases the file stream when UpdateItems returns
    final cb = _GzipReleasingUpdateCallback(callback);
    try {
      h.updateItems(out, numItems, cb);
    } finally {
      cb.releaseAll();
    }
  }
}

/// Forwards an update callback and releases the streams it gave out.
class _GzipReleasingUpdateCallback extends ArchiveUpdateCallback
    implements ArchiveUpdateCallbackFile {
  final ArchiveUpdateCallback _cb;
  final List<InStream> _streams = [];
  _GzipReleasingUpdateCallback(this._cb);

  void releaseAll() {
    for (final s in _streams) {
      releaseStream(s);
    }
    _streams.clear();
  }

  @override
  void setTotal(int total) => _cb.setTotal(total);
  @override
  void setCompleted(int completeValue) => _cb.setCompleted(completeValue);
  @override
  UpdateItemInfo getUpdateItemInfo(int index) => _cb.getUpdateItemInfo(index);
  @override
  Object? getProperty(int index, int propId) => _cb.getProperty(index, propId);
  @override
  InStream? getStream(int index) {
    final s = _cb.getStream(index);
    if (s != null) _streams.add(s);
    return s;
  }

  @override
  void setOperationResult(int opRes) => _cb.setOperationResult(opRes);

  @override
  InStream? getStream2(int index, int notifyOp) {
    final cb = _cb;
    if (cb is! ArchiveUpdateCallbackFile) return null;
    final s = (cb as ArchiveUpdateCallbackFile).getStream2(index, notifyOp);
    if (s != null) _streams.add(s);
    return s;
  }

  @override
  void reportOperation(int indexType, int index, int notifyOp) {
    final cb = _cb;
    if (cb is ArchiveUpdateCallbackFile) {
      (cb as ArchiveUpdateCallbackFile)
          .reportOperation(indexType, index, notifyOp);
    }
  }
}

class _GzipOpenProgress extends ArchiveProgress {
  final ArchiveOpenCallback? cb;
  _GzipOpenProgress(this.cb);
  @override
  void setTotal(int total) => cb?.setTotal(null, total);
  @override
  void setCompleted(int completeValue) => cb?.setCompleted(null, completeValue);
}
