// The read-only handlers of lib/src/format (pak, uimage, fdt, cpio) seen
// through the CLI's IInArchive shape (see arc_handlers.dart).

import '../format/archive_types.dart';
import '../format/item_streams.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';

/// A read-only [InArchive] over a [ReadOnlyHandler].
class ReadOnlyArc extends InArchive {
  final ReadOnlyHandler h;
  ReadOnlyArc(this.h);

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    callback?.setTotal(null, stream.length);
    final ok = h.open(stream, name: callback?.volumeName);
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
  List<int> get itemPropIds => h.itemPropIds;

  @override
  List<int> get archivePropIds => h.archivePropIds;

  @override
  int get timePrec => h.timePrec;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      h.extract(indices, testMode, cb);

  @override
  SeekableInStream? getStream(int index) => h.getStream(index);
}
