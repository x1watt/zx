// The HTTP range stream of the web engine (lib/src/web/range_stream.dart)
// over a fake transport: archives are opened and extracted through the
// generic opener with only the ranges they need, and the server's
// misbehaviours are reported.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/load_codecs.dart';
import 'package:zx/src/cli/open_archive.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/web/range_stream.dart';
import 'package:zx/zx.dart' show ZxArchive, ZxSource, ZxOptions;

class FakeTransport implements RangeTransport {
  final Uint8List data;
  int status = 206;
  bool exposeRange = true;
  String? etag = '"v1"';
  String? encoding;
  int? reportedTotal;
  int short = 0;
  final List<(int, int)> calls = [];
  FakeTransport(this.data);

  @override
  RangeResponse fetch(int start, int endInclusive) {
    calls.add((start, endInclusive));
    var end = endInclusive + 1 - short;
    if (end > data.length) end = data.length;
    return RangeResponse(status, Uint8List.sublistView(data, start, end),
        contentRange: exposeRange
            ? 'bytes $start-${end - 1}/${reportedTotal ?? data.length}'
            : null,
        etag: etag,
        contentEncoding: encoding);
  }
}

class RangeFiles implements HostFiles {
  final Map<String, HttpRangeInStream> streams = {};
  @override
  int? sizeOf(String path) => streams[path]?.length;
  @override
  ClosableInStream open(String path) => streams[path]!;
}

class _Ui extends OpenCallbackUI {
  @override
  String openCryptoGetTextPassword() => throw StateError('password');
}

class _Cb extends ArchiveExtractCallback {
  final Map<int, Uint8List> data = {};
  MemoryOutStream? _out;
  int _idx = -1;
  @override
  OutStream? getStream(int index, int askMode) {
    _idx = index;
    return askMode == AskMode.extract ? _out = MemoryOutStream() : null;
  }

  @override
  void setOperationResult(int opRes) {
    final o = _out;
    if (o != null && opRes == OperationResult.ok) {
      data[_idx] = Uint8List.fromList(o.toBytes());
    }
    _out = null;
  }
}

/// Opens [path] (served by [files]) and extracts everything: path to data.
Map<String, Uint8List> openAndExtract(RangeFiles files, String path) {
  final saved = hostFiles;
  hostFiles = files;
  final link = ArchiveLink();
  try {
    final op = OpenOptions()
      ..codecs = Codecs.load()
      ..types = const []
      ..stdInMode = false
      ..filePath = path;
    expect(link.openStrict(op, _Ui(), null), 0);
    final arc = link.arcs.last;
    final a = arc.archive!;
    final cb = _Cb();
    a.extract(null, false, cb);
    return {
      for (var i = 0; i < a.numberOfItems; i++)
        if (cb.data[i] != null) arc.getItemPath(i): cb.data[i]!
    };
  } finally {
    link.close();
    hostFiles = saved;
  }
}

void main() {
  late Directory tmp;
  late Map<String, Uint8List> files;
  final archives = <String, Uint8List>{};

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('zx_range_');
    final src = Directory('${tmp.path}/src')..createSync();
    files = {
      'a.txt': Uint8List.fromList(
          List.generate(300000, (i) => 32 + (i * 7 + i ~/ 13) % 90)),
      'b.bin': Uint8List.fromList(
          List.generate(200000, (i) => (i * 2654435761) >> 7 & 255)),
    };
    for (final e in files.entries) {
      File('${src.path}/${e.key}').writeAsBytesSync(e.value);
    }
    for (final name in ['t.7z', 't.zip', 't.zx']) {
      final p = '${tmp.path}/$name';
      await ZxArchive.create(p, [
        for (final f in files.keys) ZxSource('${src.path}/$f'),
      ]);
      archives[name] = File(p).readAsBytesSync();
    }
    // a .zx with many small files, where the index is at the end
    final many = Directory('${tmp.path}/many')..createSync();
    for (var i = 0; i < 200; i++) {
      File('${many.path}/f$i.txt').writeAsStringSync('file $i\n' * (50 + i));
    }
    final p = '${tmp.path}/many.zx';
    await ZxArchive.create(p, [ZxSource(many.path)],
        options: const ZxOptions(level: 1));
    archives['many.zx'] = File(p).readAsBytesSync();
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  for (final name in ['t.7z', 't.zip', 't.zx']) {
    test('open and extract $name through ranges', () {
      final t = FakeTransport(archives[name]!);
      final s = HttpRangeInStream(t, archives[name]!.length,
          blockSize: 16 << 10, etag: '"v1"')
        ..prefetch();
      final rf = RangeFiles()..streams['/url/1/$name'] = s;
      final out = openAndExtract(rf, '/url/1/$name');
      expect(out.keys.toSet(), files.keys.toSet());
      for (final e in files.entries) {
        expect(out[e.key], e.value, reason: '${e.key} of $name');
      }
      // every byte at most once (blocks are cached)
      expect(s.bytesFetched,
          lessThanOrEqualTo(archives[name]!.length + (16 << 10)));
      printOnFailure('$name: ${s.requests} requests');
    });
  }

  test('listing a large .zx reads its head and tail only', () {
    final bytes = archives['many.zx']!;
    final t = FakeTransport(bytes);
    final s = HttpRangeInStream(t, bytes.length,
        blockSize: 4 << 10, pinHead: 4 << 10, pinTail: 8 << 10)
      ..prefetch();
    final rf = RangeFiles()..streams['/url/1/many.zx'] = s;
    final saved = hostFiles;
    hostFiles = rf;
    final link = ArchiveLink();
    try {
      final op = OpenOptions()
        ..codecs = Codecs.load()
        ..types = const []
        ..stdInMode = false
        ..filePath = '/url/1/many.zx';
      expect(link.openStrict(op, _Ui(), null), 0);
      expect(link.arcs.last.archive!.numberOfItems, greaterThanOrEqualTo(200));
    } finally {
      link.close();
      hostFiles = saved;
    }
    expect(s.requests, lessThanOrEqualTo(4));
    expect(s.bytesFetched, lessThan(bytes.length));
  });

  test('adjacent missing blocks are fetched in one request', () {
    final data = Uint8List.fromList(List.generate(1 << 20, (i) => i & 255));
    final t = FakeTransport(data);
    final s = HttpRangeInStream(t, data.length,
        blockSize: 4096, pinHead: 0, pinTail: 0, maxReadahead: 4096);
    final buf = Uint8List(40000);
    s.position = 100000;
    expect(s.read(buf, 0, buf.length), buf.length);
    expect(t.calls, hasLength(1));
    expect(buf.sublist(0, 4), data.sublist(100000, 100004));
  });

  test('sequential reads grow the readahead, a seek resets it', () {
    final data = Uint8List(4 << 20);
    final t = FakeTransport(data);
    final s = HttpRangeInStream(t, data.length,
        blockSize: 4096, pinHead: 0, pinTail: 0, maxReadahead: 64 << 10);
    final buf = Uint8List(4096);
    for (var i = 0; i < 40; i++) {
      s.read(buf, 0, buf.length);
    }
    // 40 blocks read with a growing readahead: far fewer requests
    expect(t.calls.length, lessThan(10));
    final before = t.calls.length;
    s.position = 3 << 20;
    s.read(buf, 0, buf.length);
    expect(t.calls.length, before + 1);
    expect(t.calls.last.$2 - t.calls.last.$1 + 1, 4096);
  });

  group('server errors', () {
    final data = Uint8List(100000);
    HttpRangeInStream stream(FakeTransport t) =>
        HttpRangeInStream(t, data.length,
            blockSize: 4096, pinHead: 0, pinTail: 0, etag: '"v1"');
    Matcher io(String text) => throwsA(isA<SevenZipException>()
        .having((e) => e.message, 'message', contains(text)));

    test('200 instead of 206', () {
      final t = FakeTransport(data)..status = 200;
      expect(() => stream(t).read(Uint8List(10), 0, 10), io('HTTP 200'));
    });
    test('short body', () {
      final t = FakeTransport(data)..short = 5;
      expect(() => stream(t).read(Uint8List(10), 0, 10), io('bytes instead'));
    });
    test('changed size', () {
      final t = FakeTransport(data)..reportedTotal = 99999;
      expect(() => stream(t).read(Uint8List(10), 0, 10), io('changed'));
    });
    test('changed ETag', () {
      final t = FakeTransport(data)..etag = '"v2"';
      expect(() => stream(t).read(Uint8List(10), 0, 10), io('changed'));
    });
    test('compressed', () {
      final t = FakeTransport(data)..encoding = 'gzip';
      expect(() => stream(t).read(Uint8List(10), 0, 10), io('compresses'));
    });
  });
}
