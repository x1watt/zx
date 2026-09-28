// Tests of the arca-compatible metadata tables (docs/zxdb-design.md 1.2):
// the tables through their virtual table interface (plans, writes, AS
// OF), and arca import/export: fixtures written exactly as arca writes
// them (JsonEncoder.withIndent('  ') of LibraryFile.manifest() plus a
// newline, subtitles as <base>.<lang>.srt, previews as <sha256>.jpg|gif)
// come back byte for byte; so do the real arca collections of this
// machine when there are any (read only).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/crypto/sha256.dart';
import 'package:zx/src/db/memory_store.dart';
import 'package:zx/src/db/meta/arca_io.dart';
import 'package:zx/src/db/meta/meta_store.dart';
import 'package:zx/src/db/system/sys_vtab.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List shaOf(String s) => Sha256.hash(Uint8List.fromList(utf8.encode(s)));

/// A manifest as arca's LibraryFile.manifest() builds it.
Map<String, Object?> arcaManifest({
  required String file,
  required int size,
  required String sha256,
  String sha1 = '',
  required String mime,
  String title = '',
  String description = '',
  List<String> tags = const [],
  required int addedAt,
  List<Map<String, Object?>> layers = const [],
}) =>
    {
      'format': 'arca-manifest/1',
      'file': file,
      'size': size,
      'sha256': sha256,
      if (sha1.isNotEmpty) 'sha1': sha1,
      'mime': mime,
      'title': title,
      'description': description,
      'tags': tags,
      'added': DateTime.fromMillisecondsSinceEpoch(addedAt * 1000, isUtc: true)
          .toIso8601String(),
      'layers': layers,
    };

void writeManifest(String path, Map<String, Object?> m) =>
    File(path).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(m)}\n');

/// A tiny GIF (header and screen descriptor only).
Uint8List gif(int w, int h) => Uint8List.fromList([
      ...'GIF89a'.codeUnits, w & 255, w >> 8, h & 255, h >> 8, 0, 0, 0, //
      0x3B,
    ]);

/// A tiny JPEG with an SOF0 segment.
Uint8List jpeg(int w, int h) => Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0, // APP0, length 4
      0xFF, 0xC0, 0, 11, 8, h >> 8, h & 255, w >> 8, w & 255, 1, 1, 0x11, 0,
      0xFF, 0xD9,
    ]);

const srtEn = '1\n00:00:00,000 --> 00:00:02,500\nHello from the ISS digipeater.\n'
    '\n2\n00:00:02,500 --> 00:00:05,000\nWorking APRS without a satellite antenna.\n';
const srtPt = '1\n00:00:00,000 --> 00:00:02,000\nInforma\u00E7\u00E3o sobre a esta\u00E7\u00E3o.\n';

class Fixture {
  final String dir;
  final String previews;
  final Map<String, List<int>> files = {}; // relative path: bytes of the sidecars
  Fixture(this.dir, this.previews);
}

/// Builds an arca collection folder with the cases arca produces and a
/// few it does not (hand-edited manifests).
Fixture buildFixture(String root) {
  final dir = '$root/col';
  final previews = '$root/previews';
  Directory('$dir/Talks').createSync(recursive: true);
  Directory('$dir/Music').createSync(recursive: true);
  Directory(previews).createSync(recursive: true);
  final fx = Fixture(dir, previews);
  void put(String rel, List<int> bytes) {
    File('$dir/$rel').writeAsBytesSync(bytes);
    fx.files[rel] = bytes;
  }

  // a video with machine subtitles in two languages and previews
  final talk = shaOf('talk');
  put('Talks/Talk.webm', utf8.encode('webm bytes'));
  writeManifest(
      '$dir/Talks/Talk.arca.json',
      arcaManifest(
          file: 'Talk.webm',
          size: 10,
          sha256: hex(talk),
          sha1: 'a990c5b45e6d60a5217f8b37eef5bb7dacd3ad63',
          mime: 'video/webm',
          title: 'Working the ISS APRS Digipeater',
          description: 'A talk about the ISS.',
          tags: ['aprs', 'iss', 'dipole-antenna'],
          addedAt: 1790000000,
          layers: [
            {
              'type': 'subtitles',
              'file': 'Talk.en.srt',
              'language': 'en',
              'origin': 'machine',
              'tool': 'whisper.cpp 1.9.4',
              'model': 'ggml-large-v3-turbo-q5_0.bin',
              'created': '2026-09-24T20:00:49.528453Z',
            },
            {
              'type': 'subtitles',
              'file': 'Talk.pt-BR.srt',
              'language': 'pt-BR',
              'origin': 'person',
            },
          ]));
  fx.files['Talks/Talk.arca.json'] =
      File('$dir/Talks/Talk.arca.json').readAsBytesSync();
  put('Talks/Talk.en.srt', utf8.encode(srtEn));
  put('Talks/Talk.pt-BR.srt', utf8.encode(srtPt));
  File('$previews/${hex(talk)}.jpg').writeAsBytesSync(jpeg(640, 360));
  File('$previews/${hex(talk)}.gif').writeAsBytesSync(gif(480, 270));

  // two files with the same stem: full-name sidecars; no sha1; a null
  // language (arca writes it when whisper did not detect one)
  final mp3 = shaOf('mp3'), flac = shaOf('flac');
  put('Music/Song.mp3', utf8.encode('mp3'));
  put('Music/Song.flac', utf8.encode('flac'));
  writeManifest(
      '$dir/Music/Song.mp3.arca.json',
      arcaManifest(
          file: 'Song.mp3',
          size: 3,
          sha256: hex(mp3),
          mime: 'audio/mpeg',
          title: 'Song',
          addedAt: 1790000100,
          layers: [
            {
              'type': 'subtitles',
              'file': 'Song.mp3.srt',
              'language': null,
              'origin': 'machine',
              'tool': 'whisper.cpp 1.9.4',
              'model': 'ggml-base-q5_1.bin',
              'created': '2026-09-25T10:00:00.000Z',
            }
          ]));
  put('Music/Song.mp3.srt', utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nla la\n'));
  writeManifest(
      '$dir/Music/Song.flac.arca.json',
      arcaManifest(
          file: 'Song.flac',
          size: 4,
          sha256: hex(flac),
          sha1: 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
          mime: 'audio/flac',
          title: 'Song (lossless)',
          addedAt: 1790000200));
  for (final n in ['Song.mp3.arca.json', 'Song.flac.arca.json']) {
    fx.files['Music/$n'] = File('$dir/Music/$n').readAsBytesSync();
  }

  // a hand-edited manifest: other key order, an unknown key, a nested
  // object, a layer with an extra field; and a subtitle file beside the
  // file that the manifest does not list
  final doc = shaOf('doc');
  put('Doc.pdf', utf8.encode('%PDF'));
  File('$dir/Doc.arca.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
            'format': 'arca-manifest/1',
            'sha256': hex(doc),
            'file': 'Doc.pdf',
            'size': 4,
            'mime': 'application/pdf',
            'title': 'Manual',
            'description': '',
            'tags': ['manual'],
            'added': '2026-01-02T03:04:05.000Z',
            'license': 'CC-BY-4.0',
            'source': {'url': 'https://example.org/manual.pdf', 'isbn': null},
            'layers': [
              {'type': 'ocr', 'file': 'Doc.ocr.txt', 'origin': 'tool', 'pages': 3}
            ],
          })}\n');
  fx.files['Doc.arca.json'] = File('$dir/Doc.arca.json').readAsBytesSync();
  put('Doc.en.srt', utf8.encode('1\n00:00:00,000 --> 00:00:01,000\nunlisted\n'));
  // a manifest written with other whitespace (kept as its text)
  final odd = shaOf('odd');
  put('Odd.txt', utf8.encode('odd'));
  File('$dir/Odd.arca.json').writeAsStringSync(jsonEncode(arcaManifest(
      file: 'Odd.txt',
      size: 3,
      sha256: hex(odd),
      mime: 'text/plain',
      addedAt: 1790000300)));
  fx.files['Odd.arca.json'] = File('$dir/Odd.arca.json').readAsBytesSync();
  return fx;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('zxdb_meta_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('metadata tables', () {
    test('writes and reads through the virtual tables', () {
      final store = ZxMemoryStore();
      final access = ZxStoreMetaAccess(store);
      final tables = {for (final t in zxMetaTables(access)) t.name: t};
      access.txn = store.begin();
      ZxMetaSchema.create(access.txn!);
      final a = shaOf('a'), b = shaOf('b');
      final meta = tables['zx_meta']!;
      meta.insert([a, 'x/a.txt', 1, 'Alpha', 'first', 'text/plain', '', //
        '2026-01-01T00:00:00.000Z', ['one', 'two'], null]);
      meta.insert([b, 'b.txt', 2, 'Beta']);
      expect(() => meta.insert([b, 'b.txt']), throwsA(isA<Exception>()));
      meta.insert([b, 'b2.txt', 2, 'Beta 2'], replace: true);
      final layers = tables['zx_layers']!;
      layers.insert([a, 0, 'transcript', 'en', 'person', null, null, null, //
        null, 'hello world']);
      layers.insert([a, 1, 'ocr', 'de', 'tool', 'tesseract']);
      tables['zx_media']!.insert([a, 'screenshot', 0, 'the start', 640, 480,
        1.5, 'image/png', null, Uint8List.fromList([1, 2, 3])]);
      tables['zx_fingerprints']!.insert([a, 'tlsh', 'T1ABC', 'zx', null]);
      access.txn!.commit();
      access.txn = null;

      final all = sysScanAll(meta);
      expect(all.length, 2);
      final ra = all.firstWhere((r) => r[1] == 'x/a.txt');
      expect(ra[ZxMetaSchema.mTags], '["one","two"]');
      expect(sysQuery(meta, [('sha256', SysOp.eq, b)]).single[1], 'b2.txt');
      // point lookup and prefix plans
      final info = SysIndexInfo([const SysConstraint(0, SysOp.eq)]);
      meta.bestIndex(info);
      expect(info.idxNum, 1);
      expect(info.omit[0], isTrue);
      expect(sysQuery(meta, [('sha256', SysOp.eq, a)]).single[3], 'Alpha');
      final li = SysIndexInfo([
        const SysConstraint(0, SysOp.eq),
        const SysConstraint(2, SysOp.eq),
      ]);
      layers.bestIndex(li);
      expect(li.idxNum, 1);
      expect(li.omit[1], isFalse);
      expect(
          sysQuery(layers, [('sha256', SysOp.eq, a), ('kind', SysOp.eq, 'ocr')])
              .single[ZxMetaSchema.lTool],
          'tesseract');
      expect(sysQuery(layers, [('language', SysOp.eq, 'en')]).length, 1);
      expect(sysScanAll(tables['zx_media']!).single[ZxMetaSchema.dWidth], 640);

      // update and delete; AS OF the first commit keeps the old values
      access.txn = store.begin();
      meta.update([a], [a, 'x/a.txt', 1, 'Alpha 2']);
      expect(layers.delete([a, 1]), isTrue);
      expect(layers.delete([a, 7]), isFalse);
      access.txn!.commit();
      access.txn = null;
      expect(sysQuery(meta, [('sha256', SysOp.eq, a)]).single[3], 'Alpha 2');
      expect(sysScanAll(layers).length, 1);
      final old = sysQuery(meta, [('sha256', SysOp.eq, a)],
          asOf: const SysAsOf.generation(1));
      expect(old.single[3], 'Alpha');
      expect(sysScanAll(layers, asOf: const SysAsOf.generation(1)).length, 2);
      // no transaction: writes fail
      expect(() => meta.insert([shaOf('c')]), throwsA(isA<Exception>()));
      // bad keys
      access.txn = store.begin();
      expect(() => meta.insert([Uint8List(3)]), throwsA(isA<Exception>()));
      expect(() => layers.insert([a, null]), throwsA(isA<Exception>()));
      access.txn!.rollback();
    });

    test('ddl', () {
      expect(ZxMetaSchema.layers.ddl, contains('PRIMARY KEY (sha256, n)'));
      expect(ZxMetaSchema.media.ddl, contains('data BLOB'));
    });
  });

  group('arca import/export', () {
    test('a fixture comes back byte for byte', () {
      final fx = buildFixture(tmp.path);
      final store = ZxMemoryStore();
      final txn = store.begin();
      ZxMetaSchema.create(txn);
      final db = ZxMetaDb(txn);
      final added = <String, String>{};
      final r = arcaImport(db, fx.dir,
          previewsDirs: [fx.previews],
          addFile: (a, f) => added[a] = f);
      expect(r.manifests, 5, reason: '$r ${r.warnings}');
      expect(r.warnings, isEmpty);
      expect(r.layerTexts, 3);
      expect(r.sidecarSubtitles, 1);
      expect(r.previews, 2);
      expect(added.keys.toSet(), {
        'Talks/Talk.webm', 'Music/Song.mp3', 'Music/Song.flac', 'Doc.pdf', //
        'Odd.txt',
      });
      txn.commit();

      final s = store.snapshot();
      final rdb = ZxMetaDb(s);
      final talk = rdb.meta(shaOf('talk'))!;
      expect(talk[ZxMetaSchema.mPath], 'Talks/Talk.webm');
      expect(talk[ZxMetaSchema.mTitle], 'Working the ISS APRS Digipeater');
      expect(ZxMetaDb.tagsOf(talk[ZxMetaSchema.mTags]),
          ['aprs', 'iss', 'dipole-antenna']);
      expect(talk[ZxMetaSchema.mAdded], '2026-09-21T14:13:20.000Z');
      expect(talk[ZxMetaSchema.mExtra], isNull);
      final layers = rdb.layersOf(shaOf('talk'));
      expect(layers.length, 2);
      expect(layers[0][ZxMetaSchema.lKind], 'subtitles');
      expect(layers[0][ZxMetaSchema.lModel], 'ggml-large-v3-turbo-q5_0.bin');
      expect(layers[0][ZxMetaSchema.lContent], srtEn);
      expect(layers[1][ZxMetaSchema.lLanguage], 'pt-BR');
      final media = rdb.mediaOf(shaOf('talk'));
      expect([for (final m in media) m[ZxMetaSchema.dKind]], ['gif', 'preview']);
      expect(media[1][ZxMetaSchema.dWidth], 640);
      expect(media[1][ZxMetaSchema.dHeight], 360);
      expect(media[0][ZxMetaSchema.dWidth], 480);
      final doc = rdb.meta(shaOf('doc'))!;
      final extra = jsonDecode(doc[ZxMetaSchema.mExtra] as String) as Map;
      expect(extra['license'], 'CC-BY-4.0');
      expect(extra[r'$order'], isNotNull);
      expect(extra.containsKey(r'$raw'), isFalse);
      final odd = jsonDecode(
          rdb.meta(shaOf('odd'))![ZxMetaSchema.mExtra] as String) as Map;
      expect(odd.containsKey(r'$raw'), isTrue);
      expect(rdb.meta(shaOf('mp3'))![ZxMetaSchema.mSha1], isNull);

      // export into an empty folder with the files in place (as zx x
      // would have extracted them)
      final out = '${tmp.path}/out';
      for (final rel in ['Talks/Talk.webm', 'Music/Song.mp3', //
        'Music/Song.flac', 'Doc.pdf', 'Odd.txt']) {
        File('$out/$rel')
          ..createSync(recursive: true)
          ..writeAsBytesSync(fx.files[rel]!);
      }
      final er = arcaExport(rdb, out, previewsDir: '$out/previews');
      expect(er.manifests, 5);
      expect(er.subtitles, 4);
      expect(er.previews, 2);
      for (final e in fx.files.entries) {
        expect(File('$out/${e.key}').readAsBytesSync(), e.value,
            reason: e.key);
      }
      for (final ext in ['jpg', 'gif']) {
        final n = '${hex(shaOf('talk'))}.$ext';
        expect(File('$out/previews/$n').readAsBytesSync(),
            File('${fx.previews}/$n').readAsBytesSync());
      }
      // no temporary files left
      expect(
          Directory(out)
              .listSync(recursive: true)
              .where((e) => e.path.split('/').last.startsWith('.')),
          isEmpty);
    });

    test('edits show in the exported manifest in arca format', () {
      final fx = buildFixture(tmp.path);
      final store = ZxMemoryStore();
      final txn = store.begin();
      final db = ZxMetaDb(txn);
      arcaImport(db, fx.dir, previewsDirs: const []);
      final row = db.meta(shaOf('flac'))!;
      row[ZxMetaSchema.mTitle] = 'New title';
      row[ZxMetaSchema.mTags] = ['flac', 'lossless'];
      db.put(ZxMetaSchema.meta, row);
      final text = arcaRowsToManifestText(row, db.layersOf(shaOf('flac')));
      final m = jsonDecode(text) as Map;
      expect(m.keys.toList(), [
        'format', 'file', 'size', 'sha256', 'sha1', 'mime', 'title', //
        'description', 'tags', 'added', 'layers',
      ]);
      expect(m['title'], 'New title');
      expect(m['tags'], ['flac', 'lossless']);
      // the odd manifest's kept text gives way to the new content
      final o = db.meta(shaOf('odd'))!;
      o[ZxMetaSchema.mTitle] = 'Changed';
      final t2 = arcaRowsToManifestText(o, const []);
      expect(t2, contains('"title": "Changed"'));
      expect(t2, endsWith('}\n'));
      txn.rollback();
    });

    test('image sizes', () {
      expect(imageSize(gif(3, 4)), (3, 4));
      expect(imageSize(jpeg(300, 200)), (300, 200));
      expect(imageSize(Uint8List(3)), isNull);
    });

    test("this machine's arca collections round-trip (read only)", () {
      final home = Platform.environment['HOME'];
      final profiles = Directory('$home/.local/share/arca/profiles');
      if (!profiles.existsSync()) {
        markTestSkipped('no arca data');
        return;
      }
      final folders = <String>[];
      for (final p in profiles.listSync()) {
        final f = File('${p.path}/collections.json');
        if (!f.existsSync()) continue;
        final j = jsonDecode(f.readAsStringSync()) as Map;
        for (final c in j['collections'] as List) {
          final folder = (c as Map)['folder'] as String;
          if (Directory(folder).existsSync()) folders.add(folder);
        }
      }
      var checked = 0;
      for (final folder in folders) {
        final store = ZxMemoryStore();
        final txn = store.begin();
        final db = ZxMetaDb(txn);
        final r = arcaImport(db, folder,
            previewsDirs: ['$home/.local/share/arca/previews']);
        txn.commit();
        final out = '${tmp.path}/real${checked++}';
        Directory(out).createSync();
        arcaExport(ZxMetaDb(store.snapshot()), out,
            previewsDir: '$out/previews');
        // every manifest and every listed subtitle file is identical
        for (final e in Directory(folder).listSync(recursive: true)) {
          if (e is! File) continue;
          final rel = e.path.substring(folder.length + 1);
          if (rel.split('/').any((s) => s.startsWith('.'))) continue;
          if (!rel.endsWith('.arca.json') && !rel.endsWith('.srt')) continue;
          final o = File('$out/$rel');
          expect(o.existsSync(), isTrue, reason: rel);
          expect(o.readAsBytesSync(), e.readAsBytesSync(), reason: rel);
        }
        for (final p in Directory('$out/previews').existsSync()
            ? Directory('$out/previews').listSync()
            : const <FileSystemEntity>[]) {
          final name = p.path.split('/').last;
          expect((p as File).readAsBytesSync(),
              File('$home/.local/share/arca/previews/$name').readAsBytesSync());
        }
        expect(r.warnings, isEmpty);
      }
      if (checked == 0) markTestSkipped('no arca collection folders');
    });
  });
}
