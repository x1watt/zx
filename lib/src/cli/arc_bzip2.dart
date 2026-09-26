// The bzip2 handler seen through the InArchive shape of arc_handlers.dart
// (the way the UI code calls IInArchive / IOutArchive).

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../format/bzip2/bzip2_handler.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';

/// The bzip2 handler.
class Bzip2Arc extends InArchive {
  final Bzip2Handler h = Bzip2Handler();

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    callback?.setTotal(null, stream.length);
    final ok = h.open(stream);
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
  List<int> get itemPropIds => Bzip2Handler.itemPropIds;

  @override
  List<int> get archivePropIds => Bzip2Handler.archivePropIds;

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
    final cb = _ReleasingUpdateCallback(callback);
    try {
      h.updateItems(out, numItems, cb);
    } finally {
      cb.releaseAll();
    }
  }
}

/// Forwards an update callback and releases the streams it gave out (as
/// the one of arc_handlers.dart).
class _ReleasingUpdateCallback extends ArchiveUpdateCallback
    implements ArchiveUpdateCallbackFile {
  final ArchiveUpdateCallback _cb;
  final List<InStream> _streams = [];
  _ReleasingUpdateCallback(this._cb);

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
