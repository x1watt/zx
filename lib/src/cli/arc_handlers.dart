// The archive handlers of 7zr seen through one IInArchive / IOutArchive
// shape (Archive/IArchive.h), the way the UI code of the SDK calls them:
// 7z (7zHandler), xz (XzHandler), lzma and lzma86 (LzmaHandler) and Split
// (SplitHandler).

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../format/lzma_alone.dart';
import '../format/sevenz/handler.dart';
import '../format/sevenz/handler_out.dart' as sevenz_out;
import '../format/sevenz/method_factory.dart';
import '../format/split.dart';
import '../format/xz/xz_handler.dart';
import '../io/streams.dart';
import 'common.dart';

/// IArchiveOpenCallback plus IArchiveOpenVolumeCallback and
/// ICryptoGetTextPassword, as the handlers use them during Open.
abstract class ArchiveOpenCallback {
  void setTotal(int? files, int? bytes) {}
  void setCompleted(int? files, int? bytes) {}

  /// IArchiveOpenVolumeCallback::GetProperty(kpidName).
  String? get volumeName => null;

  /// IArchiveOpenVolumeCallback::GetStream: null for S_FALSE.
  SeekableInStream? getVolumeStream(String name) => null;

  /// ICryptoGetTextPassword: throws [SystemException] to abort.
  String? cryptoGetTextPassword() => null;
}

/// An IInArchive (+ IOutArchive) handler.
abstract class InArchive {
  /// IInArchive::Open: [HRes.sOk] or [HRes.sFalse].
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback);

  /// IArchiveOpenSeq::OpenSeq; [HRes.eNotImpl] when not supported.
  int openSeq(InStream stream) => HRes.eNotImpl;

  void close();

  int get numberOfItems;

  /// GetProperty: int, String, bool or null. Times are FILETIME ints.
  Object? getProperty(int index, int propId);

  Object? getArchiveProperty(int propId);

  /// GetPropertyInfo: the item properties in listing order.
  List<int> get itemPropIds;

  /// GetArchivePropertyInfo.
  List<int> get archivePropIds;

  /// Precision of the FILETIME properties (k_PropVar_TimePrec_*), 0 when
  /// not given.
  int get timePrec => 0;

  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb);

  /// IInArchiveGetStream::GetStream; null when not supported.
  SeekableInStream? getStream(int index) => null;

  // ---- IOutArchive / ISetProperties ----

  bool get supportsUpdate => false;

  int getFileTimeType() => FileTimeType.windows;

  /// ISetProperties::SetProperties.
  void setProperties(List<MapEntry<String, PropVariant>> props) {}

  /// IOutArchive::UpdateItems.
  void updateItems(
      OutStream out, int numItems, ArchiveUpdateCallback callback) {
    throw const SystemException(HRes.eNotImpl);
  }
}

// k_PropVar_TimePrec_Base + 7
const int kTimePrec100ns = 16 + 7;

/// The 7z handler.
class SevenZipArc extends InArchive {
  SevenZipHandler h = SevenZipHandler();

  SevenZipArc() {
    registerSevenZipMethods();
  }

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    stream.position = 0;
    final ok = h.open(stream,
        maxCheckStartPosition: maxCheckStartPosition,
        getTextPassword: callback == null
            ? null
            : () => callback.cryptoGetTextPassword());
    return ok ? HRes.sOk : HRes.sFalse;
  }

  @override
  void close() => h.close();

  @override
  int get numberOfItems => h.numberOfItems;

  @override
  Object? getProperty(int index, int propId) => h.getProperty(index, propId);

  @override
  Object? getArchiveProperty(int propId) {
    if (propId == Kpid.errorFlags) {
      final v = h.errorFlags;
      return v;
    }
    return h.getArchiveProperty(propId);
  }

  @override
  List<int> get itemPropIds => h.itemPropIds;

  @override
  List<int> get archivePropIds => SevenZipHandler.archivePropIds;

  @override
  int get timePrec => kTimePrec100ns;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      h.extract(indices, testMode, cb);

  @override
  bool get supportsUpdate => true;

  @override
  int getFileTimeType() => FileTimeType.windows;

  @override
  void setProperties(List<MapEntry<String, PropVariant>> props) =>
      h.setProperties(props);

  @override
  void updateItems(
      OutStream out, int numItems, ArchiveUpdateCallback callback) {
    // 7z needs IOutStream: the start header is written last
    if (out is! SeekableOutStream) {
      throw const SystemException(HRes.eNotImpl);
    }
    sevenz_out.updateItems(h, out, numItems, callback);
  }
}

/// The xz handler.
class XzArc extends InArchive {
  XzHandler h = XzHandler();

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    final ok = h.open(stream, callback: _OpenProgress(callback));
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
  List<int> get itemPropIds => XzHandler.itemPropIds;

  @override
  List<int> get archivePropIds => XzHandler.archivePropIds;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      h.extract(indices, testMode, cb);

  @override
  SeekableInStream? getStream(int index) => h.getStream(index);

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

/// Forwards an update callback and releases the streams it gave out.
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

class _OpenProgress extends ArchiveProgress {
  final ArchiveOpenCallback? cb;
  _OpenProgress(this.cb);
  @override
  void setTotal(int total) => cb?.setTotal(null, total);
  @override
  void setCompleted(int completeValue) => cb?.setCompleted(null, completeValue);
}

/// The lzma and lzma86 handlers.
class LzmaArc extends InArchive {
  final bool lzma86;
  late LzmaAloneHandler h = LzmaAloneHandler(lzma86: lzma86);
  LzmaArc(this.lzma86);

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
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
  List<int> get itemPropIds => LzmaAloneHandler.itemPropIds;

  @override
  List<int> get archivePropIds => LzmaAloneHandler.archivePropIds;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      h.extract(indices, testMode, cb);
}

/// The Split handler.
class SplitArc extends InArchive {
  final SplitHandler h = SplitHandler();

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    final name = callback?.volumeName;
    if (name == null || callback == null) return HRes.sFalse;
    final ok = h.open(stream, name, callback.getVolumeStream,
        callback: _SplitProgress(callback));
    return ok ? HRes.sOk : HRes.sFalse;
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
  List<int> get itemPropIds => SplitHandler.itemPropIds;

  @override
  List<int> get archivePropIds => SplitHandler.archivePropIds;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      h.extract(indices, testMode, cb);

  @override
  SeekableInStream? getStream(int index) => h.getStream(index);
}

class _SplitProgress extends ArchiveProgress {
  final ArchiveOpenCallback cb;
  _SplitProgress(this.cb);
  @override
  void setCompleted(int completeValue) => cb.setCompleted(completeValue, null);
}
