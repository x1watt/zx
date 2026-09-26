// The tar handler seen through the CLI's IInArchive / IOutArchive shape
// (see arc_handlers.dart).

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../format/tar/tar_handler.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';

/// The tar handler.
class TarArc extends InArchive {
  final TarHandler h = TarHandler();

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    callback?.setTotal(null, stream.length);
    final ok = h.open(stream);
    return ok ? HRes.sOk : HRes.sFalse;
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
  List<int> get itemPropIds => TarHandler.itemPropIds;

  @override
  List<int> get archivePropIds => TarHandler.archivePropIds;

  @override
  int get timePrec => h.timePrec;

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
          OutStream out, int numItems, ArchiveUpdateCallback callback) =>
      // each input stream is released after its item is written
      h.updateItems(out, numItems, callback);
}
