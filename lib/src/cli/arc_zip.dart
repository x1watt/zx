// The zip handler (lib/src/format/zip) seen through the InArchive shape of
// arc_handlers.dart, as the UI code calls IInArchive / IOutArchive.

import 'dart:typed_data';

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../format/zip/zip_handler.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';

/// IsArc_Zip for the format table: k_IsArc_Res_* (0 no, 1 yes, 2 need
/// more data).
int isArcZipFunc(Uint8List p, int size) => isArcZip(p, size);

/// The zip handler.
class ZipArc extends InArchive {
  final ZipHandler h = ZipHandler();

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    callback?.setTotal(null, stream.length);
    final ok = h.open(stream,
        maxCheckStartPosition: maxCheckStartPosition,
        volumeName: callback?.volumeName,
        openVolume: callback?.getVolumeStream);
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
  List<int> get itemPropIds => ZipHandler.itemPropIds;

  @override
  List<int> get archivePropIds => ZipHandler.archivePropIds;

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
