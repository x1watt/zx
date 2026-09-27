// The zpaq handler seen through the CLI's IInArchive / IOutArchive shape
// (see arc_handlers.dart). Not in 7-Zip.

import 'dart:typed_data';

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../format/zpaq/zpaq_handler.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';

/// Magic numbers of other formats: a file named .zpaq that starts with one
/// of them is not taken for an encrypted zpaq archive (no password asked).
final List<Uint8List> _otherMagics = [
  for (final m in const [
    [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], // 7z
    [0x50, 0x4B, 0x03, 0x04], // zip
    [0x50, 0x4B, 0x05, 0x06], // empty zip
    [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], // rar
    [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], // xz
    [0x1F, 0x8B], // gzip
    [0x42, 0x5A, 0x68], // bzip2
    [0x60, 0xEA], // arj
    [0x5D, 0x00, 0x00], // lzma
  ])
    Uint8List.fromList(m)
];

bool _startsWithOtherMagic(SeekableInStream s) {
  final b = Uint8List(8);
  s.position = 0;
  final n = readFully(s, b, 0, b.length);
  for (final m in _otherMagics) {
    if (n < m.length) continue;
    var eq = true;
    for (var i = 0; i < m.length; i++) {
      if (b[i] != m[i]) {
        eq = false;
        break;
      }
    }
    if (eq) return true;
  }
  return false;
}

/// The zpaq handler (.zpaq).
class ZpaqArc extends InArchive {
  final ZpaqHandler h = ZpaqHandler();

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
      ArchiveOpenCallback? callback) {
    callback?.setTotal(null, stream.length);
    final ask = callback == null || _startsWithOtherMagic(stream)
        ? null
        : () => callback.cryptoGetTextPassword();
    return h.open(stream, getPassword: ask) ? HRes.sOk : HRes.sFalse;
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
  List<int> get itemPropIds => ZpaqHandler.itemPropIds;

  @override
  List<int> get archivePropIds => ZpaqHandler.archivePropIds;

  @override
  int get timePrec => FileTimeType.unix;

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) =>
      h.extract(indices, testMode, cb);

  @override
  SeekableInStream? getStream(int index) => h.getStream(index);

  @override
  bool get supportsUpdate => true;

  @override
  int getFileTimeType() => FileTimeType.unix;

  @override
  void setProperties(List<MapEntry<String, PropVariant>> props) =>
      h.setProperties(props);

  @override
  void updateItems(
      OutStream out, int numItems, ArchiveUpdateCallback callback) {
    // the c header of the new version is written again at the end
    if (out is! SeekableOutStream) {
      throw const SystemException(HRes.eNotImpl);
    }
    h.updateItems(out, numItems, callback);
  }
}
