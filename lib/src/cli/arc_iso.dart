// The ISO 9660 handler seen through the CLI's IInArchive shape (see
// arc_handlers.dart). Read only.

import '../format/archive_types.dart';
import '../format/iso/iso_handler.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';

/// The Iso handler.
class IsoArc extends InArchive {
  final IsoHandler h = IsoHandler();

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    callback?.setTotal(null, stream.length);
    return h.open(stream) ? HRes.sOk : HRes.sFalse;
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
  List<int> get itemPropIds => IsoHandler.itemPropIds;

  @override
  List<int> get archivePropIds => IsoHandler.archivePropIds;

  @override
  int get timePrec => FileTimeType.unix;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      h.extract(indices, testMode, cb);

  @override
  SeekableInStream? getStream(int index) => h.getStream(index);
}
