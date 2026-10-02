// Writes the archives of the browser tests of the web engine into DIR,
// with expected.json (per archive: the files, their sizes and CRC-32).
// Usage: dart run tool/web_check/make_fixtures.dart DIR

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zx/zx.dart';
import 'package:zx/src/db/zxdb.dart' show ZxDatabase;

Future<void> main(List<String> args) async {
  final out = Directory(args.single)..createSync(recursive: true);
  final src = Directory('${out.path}/.src');
  if (src.existsSync()) src.deleteSync(recursive: true);
  src.createSync();
  final files = <String, Uint8List>{
    'README.md': utf8.encode('# Fixture\n\nSee [the data](data/b.bin).\n'),
    'a.txt': Uint8List.fromList(
        List.generate(300000, (i) => 32 + (i * 7 + i ~/ 13) % 90)),
    'data/b.bin': Uint8List.fromList(
        List.generate(200000, (i) => (i * 2654435761) >> 7 & 255)),
  };
  for (final e in files.entries) {
    File('${src.path}/${e.key}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(e.value);
  }
  final sources = [
    ZxSource('${src.path}/README.md'),
    ZxSource('${src.path}/a.txt'),
    ZxSource('${src.path}/data'),
  ];
  final expected = <String, Object?>{};
  void expect(String name) => expected[name] = {
        for (final e in files.entries)
          e.key: [e.value.length, Crc32.of(e.value)]
      };

  for (final name in ['t.7z', 't.zip', 't.zx', 't.tar.gz']) {
    final p = '${out.path}/$name';
    if (File(p).existsSync()) File(p).deleteSync();
    await ZxArchive.create(p, sources);
    expect(name);
  }

  // sealed, with a password, with a database
  final key = nsecEncode(generateSecretKey());
  var p = '${out.path}/sealed.zx';
  if (File(p).existsSync()) File(p).deleteSync();
  await ZxArchive.create(p, sources, options: ZxOptions(signKey: key));
  expect('sealed.zx');

  p = '${out.path}/secret.zx';
  if (File(p).existsSync()) File(p).deleteSync();
  await ZxArchive.create(p, sources,
      options: const ZxOptions(password: 'pw', encryptHeaders: true));
  expect('secret.zx');

  p = '${out.path}/db.zx';
  if (File(p).existsSync()) File(p).deleteSync();
  final db = ZxDatabase.open(p, create: true);
  db.sql.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
  for (var i = 0; i < 50; i++) {
    db.sql.execute('INSERT INTO t (name) VALUES (?)', ['n$i']);
  }
  db.close();
  final lock = File('$p.zx-lock');
  if (lock.existsSync()) lock.deleteSync();
  expected['db.zx'] = {};

  // many small files: listing reads the head and the tail only
  final many = Directory('${src.path}/many')..createSync();
  final big = <String, Uint8List>{};
  var seed = 12345;
  int next() => seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
  for (var i = 0; i < 300; i++) {
    // incompressible: the archive is about 6 MB
    final b = Uint8List.fromList(
        List.generate(20000 + i * 7, (_) => next() >> 16 & 255));
    File('${many.path}/f$i.txt').writeAsBytesSync(b);
    big['many/f$i.txt'] = b;
  }
  p = '${out.path}/many.zx';
  if (File(p).existsSync()) File(p).deleteSync();
  await ZxArchive.create(p, [ZxSource(many.path)]);
  expected['many.zx'] = {
    for (final e in big.entries) e.key: [e.value.length, Crc32.of(e.value)]
  };

  File('${out.path}/expected.json').writeAsStringSync(jsonEncode(expected));
  src.deleteSync(recursive: true);
  stdout.writeln('fixtures in ${out.path}');
}
