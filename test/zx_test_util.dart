// Helpers of the .zx tests: archives made and read in memory through the
// writer and the handler.

import 'dart:typed_data';

import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_handler.dart';
import 'package:zx/src/format/zx/zx_writer.dart';
import 'package:zx/src/io/streams.dart';

/// Deterministic pseudo random bytes.
Uint8List lcgBytes(int n, int seed) {
  final b = Uint8List(n);
  var x = seed;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    b[i] = x >> 16;
  }
  return b;
}

/// Deterministic text.
Uint8List textBytes(int n, int seed) {
  const words = [
    'archive', 'block', 'codec', 'data', 'entry', 'footer', 'header', //
    'index', 'zx', 'volume', 'generation', 'the', 'of', 'and', 'stream',
  ];
  final sb = StringBuffer();
  var x = seed;
  while (sb.length < n) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    sb.write(words[(x >> 16) % words.length]);
    sb.write((x & 7) == 0 ? '.\n' : ' ');
  }
  return Uint8List.fromList(sb.toString().substring(0, n).codeUnits);
}

/// Options with small blocks and one thread (fast tests), a fixed id and
/// time (identical outputs).
ZxWriteOptions testOptions({int threads = 1, int blockSize = 64 << 10}) =>
    ZxWriteOptions()
      ..threads = threads
      ..blockSize = blockSize
      ..archiveId = Uint8List(16)
      ..time = 1790000000000000000;

/// Writes an archive of [files] (null data: a folder) into memory.
Uint8List makeArchive(Map<String, Uint8List?> files, ZxWriteOptions o) {
  final out = MemoryOutStream();
  final w = ZxWriter.create(o, (h) => ZxStreamSink(out));
  for (final e in files.entries) {
    final d = e.value;
    if (d == null) {
      w.addNew(ZxEntry(e.key, ZxKind.directory), null);
    } else {
      w.addNew(
          ZxEntry(e.key, ZxKind.file)..mTime = 1000000000, MemoryInStream(d),
          knownSize: d.length);
    }
  }
  w.finish();
  return Uint8List.fromList(out.toBytes());
}

/// Opens an archive held in memory.
ZxHandler openMem(Uint8List a, {String? password, String? version}) {
  final h = ZxHandler();
  if (version != null) {
    h.setProperties([MapEntry('version', PropVariant.bstr(version))]);
  }
  if (!h.open(MemoryInStream(a), password: () => password)) {
    throw StateError('not zx');
  }
  return h;
}

/// An extract callback that keeps the data and the results by index.
class MemExtract extends ArchiveExtractCallback
    implements CryptoGetTextPassword {
  final Map<int, MemoryOutStream> data = {};
  final Map<int, int> results = {};
  final String? password;
  int _current = -1;
  MemExtract([this.password]);

  @override
  OutStream? getStream(int index, int askMode) {
    _current = index;
    if (askMode != AskMode.extract) return null;
    return data[index] = MemoryOutStream();
  }

  @override
  void setOperationResult(int opRes) => results[_current] = opRes;

  @override
  String cryptoGetTextPassword() {
    final p = password;
    if (p == null) throw const SevenZipException('no password');
    return p;
  }
}

/// Extracts everything: path to data (null for a failed item).
Map<String, Uint8List?> extractAll(ZxHandler h, {String? password}) {
  final cb = MemExtract(password);
  h.extract(null, false, cb, password: () => password);
  final out = <String, Uint8List?>{};
  for (var i = 0; i < h.numberOfItems; i++) {
    final p = h.getProperty(i, Kpid.path) as String;
    final ok = cb.results[i] == OperationResult.ok;
    out[p] =
        ok ? Uint8List.fromList(cb.data[i]?.toBytes() ?? Uint8List(0)) : null;
  }
  return out;
}

/// The operation results by path.
Map<String, int> testAll(ZxHandler h, {String? password}) {
  final cb = MemExtract(password);
  h.extract(null, true, cb, password: () => password);
  return {
    for (var i = 0; i < h.numberOfItems; i++)
      h.getProperty(i, Kpid.path) as String: cb.results[i] ?? -1
  };
}
