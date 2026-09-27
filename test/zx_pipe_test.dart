// Tests of .zx read from a pipe (docs/zx-format.md, sections 8 and 8.1):
// an appended archive holds its generations one after the other, and a
// generation's inline records are only its new or changed entries, so a
// reader that must give the current state copies the pipe first (in
// memory, or a temporary file) and reads it as a file: entries deleted or
// replaced by a later generation are not extracted, and any generation can
// be chosen. The one pass reader (-mpipe=onepass) gives every version in
// stream order and says what the last generation changed; the reader of a
// damaged streamed file (no valid Footer) applies the replacements it can
// see.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_handler.dart';
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/src/format/zx/zx_writer.dart';
import 'package:zx/src/io/streams.dart';

import 'zx_test_util.dart';

/// A pipe: an input that can not seek.
class _Pipe implements InStream {
  final MemoryInStream _s;
  _Pipe(Uint8List b) : _s = MemoryInStream(b);
  @override
  int read(Uint8List buf, int off, int len) => _s.read(buf, off, len);
}

/// A new generation after [old]: [add] replaces or adds, [delete] removes.
Uint8List _append(Uint8List old, ZxWriteOptions o,
    {Map<String, Uint8List> add = const {}, Set<String> delete = const {}}) {
  final r = ZxArchiveReader.open(MemoryInStream(old), const ZxOpenParams())!;
  final out = MemoryOutStream()..write(old, 0, r.validEnd);
  final w = ZxWriter.append(r, o, ZxStreamSink(out, r.validEnd));
  for (final e in r.lastIndex.entries) {
    if (!delete.contains(e.path) && !add.containsKey(e.path)) w.addKept(e);
  }
  for (final e in add.entries) {
    w.addNew(ZxEntry(e.key, ZxKind.file), MemoryInStream(e.value),
        knownSize: e.value.length);
  }
  w.finish();
  return Uint8List.fromList(out.toBytes());
}

ZxHandler _openPipe(Uint8List a,
    {String? version, bool onePass = false, String? temp}) {
  final h = ZxHandler();
  h.setProperties([
    if (version != null) MapEntry('version', PropVariant.bstr(version)),
    if (onePass) MapEntry('pipe', PropVariant.bstr('onepass')),
    if (temp != null) MapEntry('pipetemp', PropVariant.bstr(temp)),
  ]);
  expect(h.openSeq(_Pipe(a)), true);
  return h;
}

void main() {
  final a1 = textBytes(30000, 1), a2 = textBytes(31000, 2);
  final b = lcgBytes(20000, 3), c = textBytes(9000, 4);
  final d = lcgBytes(15000, 5), e = textBytes(7000, 6);

  // gen 1: a (v1), b, c; gen 2: a (v2), d, b deleted; gen 3: e, c deleted
  late Uint8List streamed;
  late Uint8List plain;
  setUpAll(() {
    Uint8List three(ZxWriteOptions Function() o) {
      final g1 = makeArchive({'a': a1, 'b': b, 'c': c}, o());
      final g2 = _append(g1, o(), add: {'a': a2, 'd': d}, delete: {'b'});
      return _append(g2, o(), add: {'e': e}, delete: {'c'});
    }

    streamed = three(() => testOptions()..streamed = true);
    plain = three(testOptions);
  });

  final current = {'a': a2, 'd': d, 'e': e};

  group('pipe', () {
    test('the state of the last generation: deletions and replacements', () {
      for (final z in [streamed, plain]) {
        final h = _openPipe(z);
        expect(extractAll(h), current);
        h.close();
        // listed first, then extracted
        final h2 = _openPipe(z);
        expect(h2.numberOfItems, 3);
        expect(extractAll(h2), current);
        h2.close();
      }
    });

    test('a chosen generation', () {
      expect(extractAll(_openPipe(streamed, version: '1')),
          {'a': a1, 'b': b, 'c': c});
      expect(extractAll(_openPipe(streamed, version: '2')),
          {'a': a2, 'c': c, 'd': d});
      expect(extractAll(_openPipe(plain, version: '2')),
          {'a': a2, 'c': c, 'd': d});
      final h = _openPipe(streamed);
      expect(h.getArchiveProperty(ZxKpid.numVersions), 3);
    });

    test('a long pipe goes to a temporary file, deleted at close', () {
      final tmp = Directory.systemTemp.createTempSync('zx_pipe_');
      final keep = zxPipeMemory;
      zxPipeMemory = 4096;
      try {
        final h = _openPipe(streamed, temp: tmp.path);
        expect(tmp.listSync(), hasLength(1));
        expect(extractAll(h), current);
        h.close();
        expect(tmp.listSync(), isEmpty);
        // not a zx input: nothing is left either
        final h2 = ZxHandler()
          ..setProperties([MapEntry('pipetemp', PropVariant.bstr(tmp.path))]);
        expect(h2.openSeq(_Pipe(lcgBytes(10000, 9))), false);
        expect(tmp.listSync(), isEmpty);
      } finally {
        zxPipeMemory = keep;
        tmp.deleteSync(recursive: true);
      }
    });

    test('one pass: every version in stream order, and a note', () {
      final h = _openPipe(streamed, onePass: true);
      final cb = MemExtract();
      h.extract(null, false, cb);
      // a (v1), b, c, a (v2), d, e
      expect(h.numberOfItems, 6);
      final paths = [
        for (var i = 0; i < 6; i++) h.getProperty(i, Kpid.path) as String
      ];
      expect(paths, ['a', 'b', 'c', 'a', 'd', 'e']);
      expect(cb.data[0]!.toBytes(), a1);
      expect(cb.data[3]!.toBytes(), a2);
      expect(cb.results.values.toSet(), {OperationResult.ok});
      final w = h.getArchiveProperty(Kpid.warning) as String;
      expect(w, contains('3 generations'));
      expect(w, contains('3 entries'));
      // listed without extracting: the current entries
      final l = _openPipe(streamed, onePass: true);
      expect(l.numberOfItems, 3);
      expect({for (var i = 0; i < 3; i++) l.getProperty(i, Kpid.path)},
          {'a', 'd', 'e'});
      // a version needs the whole input
      expect(() => _openPipe(streamed, onePass: true, version: '1'),
          throwsA(isA<SevenZipException>()));
      // a file not written streamed can not be read in one pass
      expect(() => ZxHandler().openSeq(_Pipe(plain)), returnsNormally);
      final p = ZxHandler()
        ..setProperties([MapEntry('pipe', PropVariant.bstr('onepass'))]);
      expect(() => p.openSeq(_Pipe(plain)), throwsA(isA<SevenZipException>()));
      expect(
          () => ZxHandler()
              .setProperties([MapEntry('pipe', PropVariant.bstr('x'))]),
          throwsA(isA<InvalidArgException>()));
    });

    test('a damaged streamed file: the last version of each path', () {
      // no valid Footer at all: the Footers of generations 1 and 2 are
      // damaged, generation 3 is cut before its Index
      final r =
          ZxArchiveReader.open(MemoryInStream(streamed), const ZxOpenParams())!;
      final gens = r.generations;
      final bad =
          Uint8List.fromList(streamed.sublist(0, r.lastIndexLoc.offset));
      for (final g in gens.take(2)) {
        final at = g.index!.offset + g.index!.size;
        bad[at + 28] ^= 0xFF; // the Footer's magic
      }
      final h = ZxHandler();
      expect(h.open(MemoryInStream(bad)), true);
      final got = extractAll(h);
      // a is its version 2; the deletions are not known without the Index
      expect(got['a'], a2);
      expect(got['d'], d);
      expect(got['e'], e);
      expect(got.keys.toSet(), {'a', 'b', 'c', 'd', 'e'});
      expect(h.getArchiveProperty(Kpid.warning), contains('inline records'));
    });
  });
}
