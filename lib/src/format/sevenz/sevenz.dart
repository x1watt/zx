// Library API of the 7z handler: a reader (IInArchive) and a writer
// (IOutArchive::UpdateItems) over the synchronous streams of this package.
//
// The CLI port (UI/Common/Update.cpp, Extract.cpp...) can use
// [SevenZipHandler] directly, which keeps the IInArchive / IOutArchive
// semantics (kpid properties, callbacks, UpdateItemInfo). The classes here
// are a convenience layer on top of it.

import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import 'handler.dart';
import 'handler_out.dart';
import 'method_factory.dart';
import '../../common/method_props.dart';

export '../archive_types.dart';
export 'handler.dart' show SevenZipHandler;
export 'handler_out.dart' show updateItems;
export '../../common/method_props.dart'
    show PropVariant, InvalidArgException, convertCliProperty;

/// One item of a 7z archive with all its properties.
class SevenZipEntry {
  final int index;
  final String path;
  final bool isDir;
  final int size;

  /// Packed size of the folder, reported on its first file (0 for empty
  /// files, null for the other files of a solid block).
  final int? packSize;
  final int? crc;

  /// Windows attributes; with [FileAttrib.unixExtension] set, the high 16
  /// bits hold the POSIX st_mode.
  final int? attrib;

  /// FILETIME values (100 ns ticks since 1601-01-01 UTC).
  final int? cTime;
  final int? aTime;
  final int? mTime;
  final int? startPos;
  final bool isAnti;
  final bool encrypted;
  final String? method;

  /// Folder (solid block) index, null for items without data.
  final int? block;

  const SevenZipEntry({
    required this.index,
    required this.path,
    required this.isDir,
    required this.size,
    this.packSize,
    this.crc,
    this.attrib,
    this.cTime,
    this.aTime,
    this.mTime,
    this.startPos,
    this.isAnti = false,
    this.encrypted = false,
    this.method,
    this.block,
  });

  /// POSIX st_mode from the high 16 bits of [attrib], if stored.
  int? get posixMode {
    final a = attrib;
    if (a == null || (a & FileAttrib.unixExtension) == 0) return null;
    return a >> 16;
  }

  /// True for a symbolic link stored with its POSIX mode (7-Zip -snl): the
  /// data of the item is the link target.
  bool get isSymlink {
    final m = posixMode;
    return m != null && (m & 0xF000) == 0xA000;
  }

  /// [mTime] as a UTC DateTime.
  DateTime? get modified => fileTimeToDateTime(mTime);

  @override
  String toString() => 'SevenZipEntry($index, $path, size: $size)';
}

/// FILETIME ticks between 1601-01-01 and 1970-01-01.
const int kFileTimeUnixEpoch = 116444736000000000;

DateTime? fileTimeToDateTime(int? ft) => ft == null
    ? null
    : DateTime.fromMicrosecondsSinceEpoch((ft - kFileTimeUnixEpoch) ~/ 10,
        isUtc: true);

int dateTimeToFileTime(DateTime t) =>
    t.toUtc().microsecondsSinceEpoch * 10 + kFileTimeUnixEpoch;

/// Result of extracting or testing one item.
class ItemResult {
  final int index;

  /// An [OperationResult] value.
  final int result;

  /// The item is in an encrypted folder. 7zAES has no password check, so a
  /// data or CRC error there usually means a wrong password (7-Zip then
  /// prints "Wrong password?").
  final bool encrypted;
  const ItemResult(this.index, this.result, {this.encrypted = false});
  bool get ok => result == OperationResult.ok;

  bool get possiblyWrongPassword =>
      encrypted &&
      (result == OperationResult.dataError ||
          result == OperationResult.crcError ||
          result == OperationResult.wrongPassword);
  @override
  String toString() => 'ItemResult($index, $result)';
}

/// Reads a 7z archive.
class SevenZipReader {
  final SevenZipHandler handler;
  final SeekableInStream stream;
  late final List<SevenZipEntry> entries = _buildEntries();

  SevenZipReader._(this.handler, this.stream);

  /// Opens the archive in [stream] (for split volumes the caller passes the
  /// joined stream). [password] (or [passwordProvider]) is used for
  /// encrypted headers and, by default, for encrypted data.
  ///
  /// Throws [SevenZipException]: isNotArc, headers, unsupportedMethod, or
  /// wrongPassword when encrypted headers can not be read.
  static SevenZipReader open(SeekableInStream stream,
      {String? password,
      PasswordProvider? passwordProvider,
      int? maxCheckStartPosition,
      CoderContext coderContext = const CoderContext()}) {
    registerSevenZipMethods();
    final pp = passwordProvider ?? (password != null ? () => password : null);
    final h = SevenZipHandler()
      ..coderContext = coderContext
      ..defaultPassword = pp;
    final ok = h.open(stream,
        maxCheckStartPosition: maxCheckStartPosition, getTextPassword: pp);
    if (!ok) {
      if (h.isEncrypted) {
        throw const SevenZipException(
            'Can not open encrypted archive. Wrong password?',
            SevenZipError.wrongPassword);
      }
      if (!h.db.isArc) {
        throw const SevenZipException(
            'Not a 7z archive', SevenZipError.isNotArc);
      }
      if (h.db.unsupportedFeatureError) {
        throw const SevenZipException(
            'Unsupported feature', SevenZipError.unsupportedMethod);
      }
      if (h.db.unexpectedEnd) {
        throw const SevenZipException(
            'Unexpected end of archive', SevenZipError.unexpectedEnd);
      }
      throw const SevenZipException('Headers error', SevenZipError.headers);
    }
    return SevenZipReader._(h, stream);
  }

  int get length => handler.numberOfItems;

  /// IInArchive::GetProperty by [Kpid].
  Object? getProperty(int index, int propId) =>
      handler.getProperty(index, propId);

  /// IInArchive::GetArchiveProperty by [Kpid].
  Object? getArchiveProperty(int propId) => handler.getArchiveProperty(propId);

  bool get isSolid => handler.db.isSolid;
  int get numBlocks => handler.db.numFolders;
  int get physicalSize => handler.db.phySize;
  int get headersSize => handler.db.headersSize;

  /// Warning flags ([ErrorFlags]) of the headers, 0 when clean.
  int get warningFlags => handler.warningFlags;

  List<SevenZipEntry> _buildEntries() {
    final r = <SevenZipEntry>[];
    for (var i = 0; i < handler.numberOfItems; i++) {
      r.add(SevenZipEntry(
        index: i,
        path: (getProperty(i, Kpid.path) as String?) ?? '',
        isDir: getProperty(i, Kpid.isDir) as bool,
        size: getProperty(i, Kpid.size) as int,
        packSize: getProperty(i, Kpid.packSize) as int?,
        crc: getProperty(i, Kpid.crc) as int?,
        attrib: getProperty(i, Kpid.attrib) as int?,
        cTime: getProperty(i, Kpid.cTime) as int?,
        aTime: getProperty(i, Kpid.aTime) as int?,
        mTime: getProperty(i, Kpid.mTime) as int?,
        startPos: getProperty(i, Kpid.position) as int?,
        isAnti: getProperty(i, Kpid.isAnti) as bool,
        encrypted: getProperty(i, Kpid.encrypted) as bool,
        method: getProperty(i, Kpid.method) as String?,
        block: getProperty(i, Kpid.block) as int?,
      ));
    }
    return r;
  }

  /// IInArchive::Extract. [indices] must be sorted (null: all items).
  void extractWithCallback(List<int>? indices, ArchiveExtractCallback cb,
      {bool test = false}) {
    handler.extract(indices, test, cb);
  }

  /// Extracts [indices] (sorted; null for all). [open] returns the output
  /// for an item, or null to skip it; [done] gets each item's result.
  /// Solid blocks are decoded once, in order.
  List<ItemResult> extract(List<int>? indices,
      {required OutStream? Function(SevenZipEntry entry) open,
      void Function(SevenZipEntry entry, int result)? done,
      void Function(int completed, int total)? progress}) {
    final cb = _SimpleExtractCallback(this, false, open, done, progress);
    handler.extract(indices, false, cb);
    return cb.results;
  }

  /// Tests [indices] (null: all items): decodes and checks CRCs.
  List<ItemResult> test([List<int>? indices]) {
    final cb = _SimpleExtractCallback(this, true, null, null, null);
    handler.extract(indices, true, cb);
    return cb.results;
  }

  /// Reads the data of one item into memory.
  Uint8List readItem(int index) {
    final out = MemoryOutStream();
    final r = extract([index], open: (_) => out);
    if (r.isEmpty || !r.first.ok) {
      final res = r.isEmpty ? OperationResult.dataError : r.first.result;
      if (r.isNotEmpty && r.first.possiblyWrongPassword) {
        throw SevenZipException('Item $index: data error. Wrong password?',
            SevenZipError.wrongPassword);
      }
      throw SevenZipException(
          'Item $index: result $res',
          res == OperationResult.crcError
              ? SevenZipError.crc
              : res == OperationResult.unsupportedMethod
                  ? SevenZipError.unsupportedMethod
                  : SevenZipError.data);
    }
    return Uint8List.fromList(out.toBytes());
  }
}

class _SimpleExtractCallback extends ArchiveExtractCallback
    implements ArchiveExtractCallbackMessage2 {
  final SevenZipReader reader;
  final bool testMode;
  final OutStream? Function(SevenZipEntry entry)? openFn;
  final void Function(SevenZipEntry entry, int result)? doneFn;
  final void Function(int completed, int total)? progressFn;
  final List<ItemResult> results = [];
  int _index = -1;
  int _askMode = AskMode.skip;
  int _total = 0;

  _SimpleExtractCallback(
      this.reader, this.testMode, this.openFn, this.doneFn, this.progressFn);

  @override
  void setTotal(int total) => _total = total;

  @override
  void setCompleted(int completeValue) =>
      progressFn?.call(completeValue, _total);

  @override
  OutStream? getStream(int index, int askMode) {
    _index = index;
    _askMode = askMode;
    if (askMode != AskMode.extract || testMode) return null;
    return openFn?.call(reader.entries[index]);
  }

  @override
  void setOperationResult(int opRes) {
    if (_askMode == AskMode.skip) return;
    results.add(
        ItemResult(_index, opRes, encrypted: reader.entries[_index].encrypted));
    doneFn?.call(reader.entries[_index], opRes);
  }

  @override
  void reportExtractResult(int indexType, int index, int opRes) {}
}

/// Compression settings as 7-Zip's -m switches give them: pairs of
/// property name and value, e.g. ("x", "9"), ("0", "LZMA2:d=64m"),
/// ("hc", "off"), ("s", "on"), ("mt", "4"), ("tc", "on"), ("he", "").
class CompressionOptions {
  final List<MapEntry<String, String>> properties;
  const CompressionOptions([this.properties = const []]);

  /// Parses switch bodies without the "-m" prefix: "x=9", "0=LZMA2:d=64m",
  /// "hc=off", "qs", "tm-".
  factory CompressionOptions.parse(List<String> switches) {
    final r = <MapEntry<String, String>>[];
    for (final s in switches) {
      final eq = s.indexOf('=');
      r.add(eq < 0
          ? MapEntry(s, '')
          : MapEntry(s.substring(0, eq), s.substring(eq + 1)));
    }
    return CompressionOptions(r);
  }
}

/// One item of the new archive for [SevenZipWriter.update].
class SevenZipUpdateItem {
  /// Index in the old archive, or -1 for a new item.
  final int indexInArchive;
  final bool newData;
  final bool newProps;

  final String? path;
  final bool isDir;
  final bool isAnti;
  final int size;
  final int? attrib;
  final int? cTime;
  final int? aTime;
  final int? mTime;

  /// Opens the data of a new item (null: the file can not be read and is
  /// left out). Called once, when the data is compressed.
  final InStream? Function()? open;

  /// Opens the data for the filter analysis (the first 16 KiB are read);
  /// defaults to [open].
  final InStream? Function()? openForAnalysis;

  const SevenZipUpdateItem._({
    required this.indexInArchive,
    required this.newData,
    required this.newProps,
    this.path,
    this.isDir = false,
    this.isAnti = false,
    this.size = 0,
    this.attrib,
    this.cTime,
    this.aTime,
    this.mTime,
    this.open,
    this.openForAnalysis,
  });

  /// Keeps item [indexInArchive] of the old archive unchanged.
  const SevenZipUpdateItem.keep(int indexInArchive)
      : this._(indexInArchive: indexInArchive, newData: false, newProps: false);

  /// Keeps the data of an old item with new properties (rename etc.).
  const SevenZipUpdateItem.newProps(int indexInArchive,
      {required String path,
      bool isDir = false,
      int? attrib,
      int? cTime,
      int? aTime,
      int? mTime})
      : this._(
            indexInArchive: indexInArchive,
            newData: false,
            newProps: true,
            path: path,
            isDir: isDir,
            attrib: attrib,
            cTime: cTime,
            aTime: aTime,
            mTime: mTime);

  /// A new file (or the new data of an old one when [indexInArchive] is
  /// given).
  const SevenZipUpdateItem.file(
      {required String path,
      required int size,
      required InStream? Function() open,
      InStream? Function()? openForAnalysis,
      int? attrib,
      int? cTime,
      int? aTime,
      int? mTime,
      int indexInArchive = -1})
      : this._(
            indexInArchive: indexInArchive,
            newData: true,
            newProps: true,
            path: path,
            size: size,
            open: open,
            openForAnalysis: openForAnalysis,
            attrib: attrib,
            cTime: cTime,
            aTime: aTime,
            mTime: mTime);

  /// A new directory.
  const SevenZipUpdateItem.dir(
      {required String path,
      int? attrib,
      int? cTime,
      int? aTime,
      int? mTime,
      int indexInArchive = -1})
      : this._(
            indexInArchive: indexInArchive,
            newData: true,
            newProps: true,
            path: path,
            isDir: true,
            attrib: attrib,
            cTime: cTime,
            aTime: aTime,
            mTime: mTime);

  /// An anti item (deletes [path] when the archive is applied as an
  /// update).
  const SevenZipUpdateItem.anti({required String path, bool isDir = false})
      : this._(
            indexInArchive: -1,
            newData: true,
            newProps: true,
            path: path,
            isDir: isDir,
            isAnti: true);
}

/// Writes or updates 7z archives.
class SevenZipWriter {
  /// Writes a new archive to [out] from [items]: kept items refer to
  /// [old] (null for a new archive), deleted items are simply not listed.
  /// The caller writes to a temp file and renames it, like 7-Zip.
  ///
  /// [password] encrypts new data (7zAES); headers are encrypted with
  /// "he" in [options]. Throws [InvalidArgException] for bad options and
  /// [SevenZipException] for codec errors.
  static void update(
      {SevenZipReader? old,
      required SeekableOutStream out,
      required List<SevenZipUpdateItem> items,
      CompressionOptions options = const CompressionOptions(),
      String? password,
      void Function(int completed, int total)? progress,
      CoderContext coderContext = const CoderContext()}) {
    registerSevenZipMethods();
    final h = old?.handler ?? SevenZipHandler();
    h.coderContext = coderContext;
    h.setPropertiesFromStrings(options.properties);
    final cb = _ListUpdateCallback(items, password, progress);
    updateItems(h, out, items.length, cb);
  }
}

class _ListUpdateCallback extends ArchiveUpdateCallback
    implements ArchiveUpdateCallbackFile, CryptoGetTextPassword2 {
  final List<SevenZipUpdateItem> items;
  final String? password;
  final void Function(int completed, int total)? progressFn;
  int _total = 0;

  _ListUpdateCallback(this.items, this.password, this.progressFn);

  @override
  void setTotal(int total) => _total = total;

  @override
  void setCompleted(int completeValue) =>
      progressFn?.call(completeValue, _total);

  @override
  UpdateItemInfo getUpdateItemInfo(int index) {
    final it = items[index];
    return UpdateItemInfo(it.newData, it.newProps, it.indexInArchive);
  }

  @override
  Object? getProperty(int index, int propId) {
    final it = items[index];
    switch (propId) {
      case Kpid.path:
        return it.path;
      case Kpid.isDir:
        return it.isDir;
      case Kpid.isAnti:
        return it.isAnti;
      case Kpid.size:
        return it.size;
      case Kpid.attrib:
        return it.attrib;
      case Kpid.cTime:
        return it.cTime;
      case Kpid.aTime:
        return it.aTime;
      case Kpid.mTime:
        return it.mTime;
    }
    return null;
  }

  @override
  InStream? getStream(int index) {
    final s = items[index].open?.call();
    return s == null ? null : _SizedInStream(s, items[index].size);
  }

  @override
  InStream? getStream2(int index, int notifyOp) {
    final it = items[index];
    return (it.openForAnalysis ?? it.open)?.call();
  }

  @override
  void reportOperation(int indexType, int index, int notifyOp) {}

  @override
  String? cryptoGetTextPassword2() => password;
}

/// The 7z method names with an encoder available now.
List<String> get availableEncoders {
  registerSevenZipMethods();
  return [
    for (final m in knownMethods)
      if (encoderRegistry[m.id] != null) m.name
  ];
}

/// Gives the declared size of a new item to the handler (IStreamGetSize,
/// as 7-Zip's file streams do) and releases the wrapped stream.
class _SizedInStream implements InStream, StreamGetSize, ReleasableStream {
  final InStream _s;
  final int _size;
  _SizedInStream(this._s, this._size);
  @override
  int read(Uint8List buf, int off, int len) => _s.read(buf, off, len);
  @override
  int? get streamSize => _size;
  @override
  void release() => releaseStream(_s);
}
