// Signed generations (lib/src/format/zx/zx_seal.dart): the chain of
// hashes over the stored bytes, the BIP-340 seals and the roles, and the
// tampering they expose.

import 'dart:typed_data';

import 'dart:io';

import 'package:test/test.dart';
import 'package:zx/src/db/zxdb.dart';
import 'package:zx/src/format/zx/zx_handler.dart';
import 'package:zx/src/cli/main.dart' show runSevenZipCli;
import 'package:zx/src/crypto/nip19.dart';
import 'package:zx/src/crypto/schnorr.dart';
import 'package:zx/zx.dart' as api;
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/src/format/zx/zx_seal.dart';
import 'package:zx/src/format/zx/zx_writer.dart';
import 'package:zx/src/io/streams.dart';

import 'zx_test_util.dart';

final admin = Uint8List.fromList(List.generate(32, (i) => i + 1));
final maint = Uint8List.fromList(List.generate(32, (i) => 100 + i));
final other = Uint8List.fromList(List.generate(32, (i) => 50 + i));
final admin2 = Uint8List.fromList(List.generate(32, (i) => 200 - i));

ZxSealOptions sealBy(Uint8List? key) => ZxSealOptions()..signer = key;

ZxArchiveReader openReader(Uint8List a, {String? password}) =>
    ZxArchiveReader.open(
        MemoryInStream(a), ZxOpenParams(password: () => password))!;

/// Appends a generation adding [files] to [a] (the old files are kept).
Uint8List appendMem(Uint8List a, Map<String, Uint8List> files,
    {ZxSealOptions? seal, String? password, List<String>? warnings}) {
  final r = openReader(a, password: password);
  final out = MemoryOutStream();
  out.write(a, 0, r.validEnd);
  final o = testOptions()
    ..seal = seal
    ..password = password;
  final w = ZxWriter.append(r, o, ZxStreamSink(out, r.validEnd));
  for (final e in r.lastIndex.entries) {
    w.addKept(e);
  }
  for (final e in files.entries) {
    w.addNew(ZxEntry(e.key, ZxKind.file)..mTime = 1000000000,
        MemoryInStream(e.value),
        knownSize: e.value.length);
  }
  w.finish();
  warnings?.addAll(o.warnings);
  return Uint8List.fromList(out.toBytes());
}

List<ZxGenerationSeal> check(Uint8List a, {bool full = true, String? pw}) =>
    openReader(a, password: pw).checkSeals(full: full);

List<ZxSealState> states(List<ZxGenerationSeal> s) =>
    [for (final g in s) g.state];

void main() {
  final files = {
    'a.txt': textBytes(200000, 1),
    'b.bin': lcgBytes(150000, 2),
  };

  test('an archive without seals is unchanged and plain', () {
    final a = makeArchive(files, testOptions());
    final r = openReader(a);
    expect(r.lastFooter.sealSize, 0);
    expect(r.lastSeal, isNull);
    expect(states(r.checkSeals(full: true)), [ZxSealState.plain]);
  });

  test('a new archive signed by its admin', () {
    final a = makeArchive(files, testOptions()..seal = sealBy(admin));
    final r = openReader(a);
    final s = r.lastSeal!.seal;
    expect(s.isGenesis, isTrue);
    expect(s.signer, publicKeyOf(admin));
    expect(s.policy.admin, publicKeyOf(admin));
    final c = r.checkSeals(full: true);
    expect(states(c), [ZxSealState.sealed]);
    expect(c.single.role, 'admin');
    expect(extractAll(openMem(a)), files);
  });

  test('the chain: maintainer, pending, other key', () {
    var a = makeArchive(files, testOptions()..seal = sealBy(admin));
    a = appendMem(a, {'c.txt': textBytes(5000, 3)},
        seal: sealBy(admin)..addMaintainers.add(publicKeyOf(maint)));
    a = appendMem(a, {'d.txt': textBytes(5000, 4)}, seal: sealBy(maint));
    final warn = <String>[];
    a = appendMem(a, {'e.txt': textBytes(5000, 5)}, warnings: warn);
    expect(warn.single, contains('not signed'));
    var c = check(a);
    expect(states(c), [
      ZxSealState.sealed,
      ZxSealState.sealed,
      ZxSealState.sealed,
      ZxSealState.pending,
    ]);
    expect(c[2].role, 'maintainer');
    expect(c[3].covered, isFalse);
    // a maintainer's seal covers the pending one before it
    a = appendMem(a, {'f.txt': textBytes(5000, 6)}, seal: sealBy(maint));
    c = check(a);
    expect(c[3].covered, isTrue);
    expect(c[4].state, ZxSealState.sealed);
    // another key can not sign
    expect(() => appendMem(a, {'g.txt': textBytes(10, 7)}, seal: sealBy(other)),
        throwsA(isA<SevenZipException>()));
    // nor change the roles, even a maintainer
    expect(
        () => appendMem(a, {'g.txt': textBytes(10, 7)},
            seal: sealBy(maint)..addMaintainers.add(publicKeyOf(other))),
        throwsA(isA<SevenZipException>()));
  });

  test('a removed maintainer: old seals stay valid', () {
    var a = makeArchive(files, testOptions()..seal = sealBy(admin));
    a = appendMem(a, {},
        seal: sealBy(admin)..addMaintainers.add(publicKeyOf(maint)));
    a = appendMem(a, {'c.txt': textBytes(100, 3)}, seal: sealBy(maint));
    a = appendMem(a, {},
        seal: sealBy(admin)..removeMaintainers.add(publicKeyOf(maint)));
    expect(states(check(a)), everyElement(ZxSealState.sealed));
    expect(() => appendMem(a, {'d.txt': textBytes(10, 4)}, seal: sealBy(maint)),
        throwsA(isA<SevenZipException>()));
  });

  test('a new admin must accept; then the old one is a stranger', () {
    var a = makeArchive(files, testOptions()..seal = sealBy(admin));
    expect(
        () => appendMem(a, {},
            seal: sealBy(admin)..newAdmin = publicKeyOf(admin2)),
        throwsA(isA<SevenZipException>()));
    a = appendMem(a, {},
        seal: sealBy(admin)
          ..newAdmin = publicKeyOf(admin2)
          ..newAdminSecret = admin2);
    final c = check(a);
    expect(states(c), everyElement(ZxSealState.sealed));
    expect(c.last.policy!.admin, publicKeyOf(admin2));
    expect(() => appendMem(a, {}, seal: sealBy(admin)),
        throwsA(isA<SevenZipException>()));
    // the new admin endorses the history with a generation of its own
    a = appendMem(a, {}, seal: sealBy(admin2));
    expect(states(check(a)), everyElement(ZxSealState.sealed));
  });

  test('activation on an archive with history, off, on again', () {
    var a = makeArchive(files, testOptions());
    a = appendMem(a, {'c.txt': textBytes(1000, 3)});
    expect(() => appendMem(a, {}, seal: sealBy(admin)),
        throwsA(isA<SevenZipException>()));
    a = appendMem(a, {}, seal: sealBy(admin)..activate = true);
    var c = check(a);
    expect(states(c), [ZxSealState.sealed]);
    expect(c.single.seal!.isGenesis, isTrue);
    expect(c.single.seal!.prefixHash, isNotNull);
    // a change before the activation is exposed by the full check
    final t = Uint8List.fromList(a)..[200] ^= 1;
    expect(check(t, full: false).single.state, ZxSealState.sealed);
    expect(check(t).single.state, ZxSealState.broken);
    // off: later generations are plain
    a = appendMem(a, {}, seal: sealBy(admin)..deactivate = true);
    a = appendMem(a, {'d.txt': textBytes(100, 4)});
    c = check(a);
    // the activation, the switch off, then a plain generation
    expect(
        states(c), [ZxSealState.sealed, ZxSealState.sealed, ZxSealState.plain]);
    expect(c[1].policy!.active, isFalse);
    // on again: a new activation
    a = appendMem(a, {}, seal: sealBy(admin)..activate = true);
    expect(states(check(a)), [ZxSealState.sealed]);
  });

  group('tampering is exposed', () {
    late Uint8List a;
    late ZxArchiveReader r;
    setUpAll(() {
      a = makeArchive(files, testOptions()..seal = sealBy(admin));
      a = appendMem(a, {'c.txt': textBytes(50000, 3)}, seal: sealBy(admin));
      r = openReader(a);
    });

    test('a byte of data', () {
      final first = r.checkSeals().first;
      final f = ZxFooter.tryParse(a, first.footerEnd - zxFooterSize)!;
      final t = Uint8List.fromList(a)..[(f.indexOffset ~/ 2)] ^= 1;
      final c = check(t);
      expect(c.first.state, ZxSealState.broken);
      expect(c.first.problem, contains('data'));
    });

    test('a byte of the last Index', () {
      final f = r.lastFooter;
      final t = Uint8List.fromList(a)..[f.indexOffset + 20] ^= 1;
      // the CRC of the Index block still matches? flip in the payload: the
      // reader may fail to open, so check the raw seals
      final c = zxCheckSeals((o, l) => Uint8List.sublistView(t, o, o + l),
          r.header.archiveId, r.validEnd, 2,
          full: false);
      expect(c.last.state, ZxSealState.broken);
    });

    test('a stripped seal', () {
      // the last generation rewritten without its Seal
      final f = r.lastFooter;
      final t = BytesBuilder()
        ..add(Uint8List.sublistView(a, 0, f.indexOffset + f.indexSize))
        ..add(ZxFooter(f.indexOffset, f.indexSize, f.dataStart).encode());
      final b = t.toBytes();
      final c = check(b);
      expect(c.last.state, ZxSealState.broken);
      expect(c.last.problem, contains('missing'));
    });

    test('a generation signed by a stranger', () {
      final f = r.lastFooter;
      final s = r.lastSeal!.seal;
      final forged = ZxSeal.build(
          archiveId: r.header.archiveId,
          generation: s.generation,
          dataStart: s.dataStart,
          dataHash: s.dataHash,
          indexHash: s.indexHash,
          prevRoot: s.prevRoot,
          policy: s.policy,
          signerSecret: other);
      final t = BytesBuilder()
        ..add(Uint8List.sublistView(a, 0, f.indexOffset + f.indexSize))
        ..add(forged)
        ..add(ZxFooter(f.indexOffset, f.indexSize, f.dataStart, forged.length)
            .encode());
      final c = check(t.toBytes());
      expect(c.last.state, ZxSealState.broken);
      expect(c.last.problem, contains('may not sign'));
    });

    test('roles changed by a forged seal', () {
      final f = r.lastFooter;
      final s = r.lastSeal!.seal;
      final forged = ZxSeal.build(
          archiveId: r.header.archiveId,
          generation: s.generation,
          dataStart: s.dataStart,
          dataHash: s.dataHash,
          indexHash: s.indexHash,
          prevRoot: s.prevRoot,
          policy: s.policy.copyWith(admin: publicKeyOf(other), seq: 9),
          signerSecret: other);
      final t = BytesBuilder()
        ..add(Uint8List.sublistView(a, 0, f.indexOffset + f.indexSize))
        ..add(forged)
        ..add(ZxFooter(f.indexOffset, f.indexSize, f.dataStart, forged.length)
            .encode());
      expect(check(t.toBytes()).last.state, ZxSealState.broken);
    });

    test('rollback is not exposed offline (documented limit)', () {
      final first = r.checkSeals().first;
      final t = Uint8List.sublistView(a, 0, first.footerEnd);
      expect(states(check(t)), [ZxSealState.sealed]);
    });
  });

  test('encrypted archive: checked without the password', () {
    final a = makeArchive(
        files,
        testOptions()
          ..password = 'pw'
          ..seal = sealBy(admin));
    final b = appendMem(a, {'c.txt': textBytes(1000, 3)},
        seal: sealBy(admin), password: 'pw');
    // no password: the raw check reads only the Footers and Seals
    final len = b.length;
    final h = ZxArchiveReader.readHeader(MemoryInStream(b))!;
    final c = zxCheckSeals(
        (o, l) => Uint8List.sublistView(b, o, o + l), h.archiveId, len, 2,
        full: true);
    expect(states(c), [ZxSealState.sealed, ZxSealState.sealed]);
    final t = Uint8List.fromList(b)..[300] ^= 1;
    final c2 = zxCheckSeals(
        (o, l) => Uint8List.sublistView(t, o, o + l), h.archiveId, len, 2,
        full: true);
    expect(c2.first.state, ZxSealState.broken);
  });

  group('database commits', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_seal_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    List<ZxGenerationSeal> checkFile(String p) {
      final h = ZxHandler();
      final raf = File(p).openSync();
      try {
        h.open(FileInStream(raf), path: p);
        return h.verifySeals();
      } finally {
        raf.closeSync();
      }
    }

    test('every commit sealed; vacuum seals again', () {
      final p = '${tmp.path}/db.zx';
      final db = ZxDatabase.open(p,
          create: true, options: ZxDbStoreOptions(signer: admin));
      db.sql.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      for (var i = 0; i < 3; i++) {
        db.sql.execute("INSERT INTO t (v) VALUES ('row $i')");
      }
      db.close();
      var c = checkFile(p);
      expect(states(c), everyElement(ZxSealState.sealed));
      expect(c.length, greaterThan(3));
      // a writer without the key: pending, then signed at close by a key
      final db2 = ZxDatabase.open(p);
      db2.sql.execute("INSERT INTO t (v) VALUES ('anon')");
      db2.close();
      c = checkFile(p);
      expect(c.last.state, ZxSealState.pending);
      final db3 = ZxDatabase.open(p,
          options: ZxDbStoreOptions(signer: admin, sealEveryMicros: 1 << 40));
      db3.sql.execute("INSERT INTO t (v) VALUES ('x')");
      db3.sql.execute("INSERT INTO t (v) VALUES ('y')");
      db3.close();
      c = checkFile(p);
      expect(c.last.state, ZxSealState.sealed);
      expect(c.where((g) => g.state == ZxSealState.pending),
          everyElement(predicate<ZxGenerationSeal>((g) => g.covered)));
      // vacuum without the key is refused; with it the archive is sealed
      final db4 = ZxDatabase.open(p);
      expect(() => db4.store.vacuum(), throwsA(isA<Exception>()));
      db4.close();
      final db5 = ZxDatabase.open(p, options: ZxDbStoreOptions(signer: admin));
      db5.store.vacuum();
      expect(db5.sql.execute('SELECT count(*) FROM t').rows.single.single, 6);
      db5.close();
      c = checkFile(p);
      expect(states(c), [ZxSealState.sealed]);
      expect(c.single.seal!.isGenesis, isTrue);
    });
  });

  test('the API: signKey, seals, sign', () async {
    final tmp = Directory.systemTemp.createTempSync('zx_seal_api_');
    try {
      final src = File('${tmp.path}/a.txt')..writeAsStringSync('hello\n' * 100);
      final p = '${tmp.path}/a.zx';
      final k = nsecEncode(admin);
      final a = await api.ZxArchive.create(p, [api.ZxSource(src.path)],
          options: api.ZxOptions(signKey: k));
      var s = await a.seals();
      expect(states(s), [ZxSealState.sealed]);
      final g =
          await a.sign(k, addMaintainers: [npubEncode(publicKeyOf(maint))]);
      expect(g, 2);
      expect(a.items.map((i) => i.path), contains('a.txt'));
      s = await a.seals(full: true);
      expect(states(s), [ZxSealState.sealed, ZxSealState.sealed]);
      expect(s.last.policy!.maintainers.single, publicKeyOf(maint));
      expect(zxSealSummary(s), contains('sealed by'));
      await a.close();
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('zx seal and -msign', () async {
    final tmp = Directory.systemTemp.createTempSync('zx_seal_cli_');
    try {
      File('${tmp.path}/a.txt').writeAsStringSync('hello\n' * 2000);
      File('${tmp.path}/admin.nsec').writeAsStringSync(nsecEncode(admin));
      File('${tmp.path}/maint.nsec').writeAsStringSync(nsecEncode(maint));
      Future<(int, String)> run(List<String> args) async {
        final out = BytesBuilder();
        final code = await runSevenZipCli(args,
            stdout: out.add, stderr: out.add, workingDirectory: tmp.path);
        return (code, String.fromCharCodes(out.takeBytes()));
      }

      var (code, out) =
          await run(['a', '-msign=@${tmp.path}/admin.nsec', 'a.zx', 'a.txt']);
      expect(code, 0, reason: out);
      (code, out) = await run(['seal', 'a.zx']);
      expect(code, 0);
      expect(out, contains('sealed by ${npubEncode(publicKeyOf(admin))}'));
      (code, out) = await run([
        'seal',
        '-sign=@admin.nsec',
        '-add=${npubEncode(publicKeyOf(maint))}',
        'a.zx'
      ]);
      expect(code, 0, reason: out);
      (code, out) =
          await run(['a', '-msign=@${tmp.path}/maint.nsec', 'a.zx', 'a.txt']);
      expect(code, 0, reason: out);
      (code, out) = await run(['seal', '-full', 'a.zx']);
      expect(code, 0);
      expect(out, contains('maintainer'));
      (code, out) = await run(['l', '-slt', 'a.zx']);
      expect(out, contains('Seal = sealed by'));
      // a changed byte: the full check fails
      final f = File('${tmp.path}/a.zx');
      final b = f.readAsBytesSync();
      b[200] ^= 1;
      f.writeAsBytesSync(b);
      (code, out) = await run(['seal', '-full', 'a.zx']);
      expect(code, 1);
      expect(out, contains('BROKEN'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
