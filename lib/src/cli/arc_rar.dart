// The RAR handlers seen through the CLI's IInArchive / IOutArchive shape
// (see arc_handlers.dart): "Rar" (RAR 1.5 to 4.x archives) and
// "Rar5" (RAR5 archives, read and write); both create RAR5 archives.

import 'dart:typed_data';

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../format/rar/rar_handler.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';

/// The signature of RAR 1.5 to 4.x archives.
final Uint8List rar4ArcSignature =
    Uint8List.fromList([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);

/// The signature of RAR5 archives.
final Uint8List rar5ArcSignature =
    Uint8List.fromList([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]);

class _RarArcBase extends InArchive {
  final RarHandler h;
  _RarArcBase(bool rar5) : h = RarHandler(rar5: rar5);

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    callback?.setTotal(null, stream.length);
    final String? name = callback?.volumeName;
    bool ok;
    try {
      ok = h.open(stream,
          name: name,
          openVolume: callback?.getVolumeStream,
          getPassword:
              callback == null ? null : () => callback.cryptoGetTextPassword());
    } on SevenZipException catch (e) {
      // a wrong password for encrypted headers is S_FALSE, as for 7z
      if (e.kind == SevenZipError.io || e.kind == SevenZipError.cancelled) {
        rethrow;
      }
      ok = false;
    }
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
  List<int> get archivePropIds => RarHandler.archivePropIds;

  @override
  int get timePrec => h.timePrec;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      h.extract(indices, testMode, cb);

  // IOutArchive: both write RAR5 archives

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

/// The Rar handler: RAR 1.5 to 4.x archives. It reads them, and creates
/// new archives in the RAR5 format (so that -trar and "a x.rar" write
/// RAR5); an existing RAR 4.x archive can not be updated.
class RarArc extends _RarArcBase {
  RarArc() : super(false);
}

/// The Rar5 handler: RAR5 archives, read and written.
class Rar5Arc extends _RarArcBase {
  Rar5Arc() : super(true);
}
