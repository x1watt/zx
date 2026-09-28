// Tests of the full-text index over the metadata tables
// (lib/src/db/meta/fts.dart): tokenizer, subtitle cleaning, field
// prefixes (tag:, transcript:, lang:), boolean and prefix queries, BM25
// ranking, incremental maintenance (equal to a rebuild), fts_search and
// fts_match.

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/crypto/sha256.dart';
import 'package:zx/src/db/memory_store.dart';
import 'package:zx/src/db/meta/fts.dart';
import 'package:zx/src/db/meta/meta_store.dart';
import 'package:zx/src/db/storage_api.dart';
import 'package:zx/src/db/system/sys_vtab.dart';

Uint8List shaOf(String s) => Sha256.hash(Uint8List.fromList(utf8.encode(s)));

List<String> dump(ZxSnapshot s, String tree) {
  final t = s.tree(tree);
  if (t == null) return const [];
  final out = <String>[];
  final c = t.scan();
  while (c.moveNext()) {
    out.add('${c.key} ${c.value}');
  }
  return out;
}

void main() {
  group('tokenizer', () {
    test('folds case and Latin diacritics', () {
      expect(ftsTokenize('Informa\u00E7\u00E3o sobre a Esta\u00E7\u00E3o, S\u00E3o Paulo!'),
          ['informacao', 'sobre', 'a', 'estacao', 'sao', 'paulo']);
      expect(ftsTokenize('Stra\u00DFe \u00DCBER Gr\u00F6\u00DFe'), ['strasse', 'uber', 'grosse']);
      expect(ftsTokenize('dipole-antenna 40m_band x1'),
          ['dipole', 'antenna', '40m', 'band', 'x1']);
      expect(ftsTokenize('\u0395\u03BB\u03BB\u03B7\u03BD\u03B9\u03BA\u03AC \u043A\u0438\u0440\u0438\u043B\u043B\u0438\u0446\u0430 \u65E5\u672C'), ['\u03B5\u03BB\u03BB\u03B7\u03BD\u03B9\u03BA\u03B1', '\u043A\u0438\u0440\u0438\u043B\u043B\u0438\u0446\u0430', '\u65E5\u672C']);
      expect(ftsTokenize('antennas batteries glasses', stem: true),
          ['antenna', 'battery', 'glass']);
    });

    test('subtitle text loses cue numbers, times and tags', () {
      const srt = '1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i> there\n\n'
          '2\n00:00:02,000 --> 00:00:03,000\n{\\an8}General Kenobi\n';
      final t = ftsSubtitleText(srt);
      expect(ftsTokenize(t), ['hello', 'there', 'general', 'kenobi']);
      expect(ftsSubtitleText('plain 12 text'), 'plain 12 text');
    });
  });

  group('index', () {
    late ZxMemoryStore store;
    late ZxWriteTxn txn;
    late ZxMetaDb db;
    final talk = shaOf('talk'), song = shaOf('song'), doc = shaOf('doc');

    setUp(() {
      store = ZxMemoryStore();
      txn = store.begin();
      ZxMetaSchema.create(txn);
      db = ZxMetaDb(txn);
      db.batch(() {
        db.put(ZxMetaSchema.meta, [
          talk, 'Talks/ISS Talk.webm', 10, 'Working the ISS digipeater',
          'APRS through the space station without a satellite antenna', //
          'video/webm', '', '', ['aprs', 'iss', 'dipole-antenna'], null,
        ]);
        db.put(ZxMetaSchema.layers, [
          talk, 0, 'subtitles', 'en', 'machine', 'whisper.cpp', 'm', null, //
          'Talk.en.srt',
          '1\n00:00:00,000 --> 00:00:01,000\nThe packet came back from orbit.\n',
        ]);
        db.put(ZxMetaSchema.layers, [
          talk, 1, 'subtitles', 'pt-BR', 'person', null, null, null, //
          'Talk.pt-BR.srt',
          '1\n00:00:00,000 --> 00:00:01,000\nO pacote voltou da \u00F3rbita.\n',
        ]);
        db.put(ZxMetaSchema.meta, [
          song, 'Music/Song.mp3', 3, 'Antenna song', 'a song', 'audio/mpeg', //
          '', '', ['music'], null,
        ]);
        db.put(ZxMetaSchema.meta, [
          doc, 'Doc.pdf', 4, 'Manual', 'How to build a dipole antenna for '
              'the forty meter band. The antenna antenna antenna.',
          'application/pdf', '', '', ['manual', 'antenna'], null,
        ]);
        db.put(ZxMetaSchema.layers, [
          doc, 0, 'ocr', 'en', 'tool', 'tesseract', null, null, null, //
          'Page 1: dipole construction with coax',
        ]);
      });
    });

    String nameOf(Uint8List sha) => sysCompareBytes(sha, talk) == 0
        ? 'talk'
        : sysCompareBytes(sha, song) == 0
            ? 'song'
            : 'doc';

    List<String> hits(String q, [int n = 10]) =>
        [for (final h in db.fts.search(q, n)) nameOf(h.sha256)];

    test('plain words search every field and rank', () {
      expect(db.fts.documentCount, 3);
      // title and tag hits outrank description mentions
      final r = hits('antenna');
      expect(r.length, 3);
      expect(r.first, anyOf('song', 'doc'));
      expect(hits('orbit'), ['talk']); // subtitle text
      expect(hits('ORBITA'), ['talk']); // folded, Portuguese subtitles
      expect(hits('iss talk'), ['talk']); // file name and title
      expect(hits('nothing'), isEmpty);
    });

    test('field prefixes', () {
      expect(hits('tag:dipole-antenna'), ['talk']);
      expect(hits('tag:antenna'), ['doc']);
      expect(hits('tag:iss'), ['talk']);
      expect(hits('title:manual'), ['doc']);
      expect(hits('title:antenna')..sort(), ['song']);
      expect(hits('transcript:packet'), ['talk']);
      expect(hits('subtitles:packet'), ['talk']);
      expect(hits('ocr:coax'), ['doc']);
      expect(hits('ocr:packet'), isEmpty);
      expect(hits('lang:pt'), ['talk']);
      expect(hits('lang:pt-br'), ['talk']);
      expect(hits('lang:en')..sort(), ['talk', 'doc']..sort());
      expect(hits('antenna lang:en')..sort(), ['talk', 'doc']..sort());
      expect(hits('name:song'), ['song']);
    });

    test('boolean and prefix queries', () {
      expect(hits('antenna -music')..sort(), ['talk', 'doc']..sort());
      expect(hits('manual OR orbit')..sort(), ['talk', 'doc']..sort());
      expect(hits('digi*'), ['talk']);
      expect(hits('ant* song'), ['song']);
      expect(hits('"dipole antenna"')..sort(), ['talk', 'doc']..sort());
      expect(hits('-antenna'), isEmpty);
    });

    test('BM25: a term that fills a short field ranks first', () {
      final r = db.fts.search('antenna', 3);
      expect(r[0].score, greaterThan(r[2].score));
      expect(r.map((h) => h.score), everyElement(greaterThan(0)));
    });

    test('incremental maintenance equals a rebuild', () {
      db.put(ZxMetaSchema.meta, [
        song, 'Music/Song.mp3', 3, 'Renamed tune', 'a song', 'audio/mpeg', //
        '', '', ['music'], null,
      ]);
      expect(hits('title:antenna'), isEmpty);
      expect(hits('tune'), ['song']);
      db.delete(ZxMetaSchema.layers, [talk, 0]);
      expect(hits('packet'), isEmpty);
      expect(hits('lang:en'), ['doc']);
      db.deleteFile(doc);
      expect(hits('manual'), isEmpty);
      expect(db.fts.documentCount, 2);
      final before = [
        for (final t in [ZxFts.postTree, ZxFts.docsTree, ZxFts.statsTree])
          ...dump(txn, t)
      ];
      db.fts.rebuild();
      final after = [
        for (final t in [ZxFts.postTree, ZxFts.docsTree, ZxFts.statsTree])
          ...dump(txn, t)
      ];
      expect(after, before);
      txn.commit();
      // committed and readable from a snapshot
      final s = store.snapshot();
      expect([for (final h in ZxMetaDb(s).fts.search('tune', 5)) nameOf(h.sha256)],
          ['song']);
    });

    test('fts_search and fts_match', () {
      txn.commit();
      final access = ZxStoreMetaAccess(store);
      final t = ZxFtsSearchTable(access);
      final rows = sysQuery(t, [
        ('query', SysOp.eq, 'antenna'),
        ('n', SysOp.eq, 2),
      ]);
      expect(rows.length, 2);
      expect(rows.first[1], anyOf('Music/Song.mp3', 'Doc.pdf'));
      expect((rows[0][3] as double) >= (rows[1][3] as double), isTrue);
      final m = ZxFtsMatchFunction(access);
      expect(m([talk, 'orbit']), 1);
      expect(m([song, 'orbit']), 0);
      expect(m(['x', 'orbit']), isNull);
    });
  });
}
