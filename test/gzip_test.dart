import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/deflate/deflate_coder.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/gzip/gzip_handler.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc.dart';

Uint8List gen(int n, int seed) {
  var st = seed;
  int next() {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    return st >> 16;
  }

  const words = ['gzip ', 'member ', 'header ', 'crc ', 'isize\n'];
  final out = BytesBuilder();
  while (out.length < n) {
    final r = next();
    if (r % 3 == 0) {
      out.add(words[next() % words.length].codeUnits);
    } else {
      out.addByte(next() & 0x3f);
    }
  }
  return Uint8List.sublistView(out.toBytes(), 0, n);
}

Uint8List gzipCreate(Uint8List data,
    {String? name, DateTime? mTime, String? level}) {
  final out = MemoryOutStream();
  GzipArchive.create(MemoryInStream(data), out, data.length,
      name: name,
      mTime: mTime,
      properties: level == null ? const [] : [MapEntry('x', level)]);
  return Uint8List.fromList(out.toBytes());
}

/// A member with every header field, built by hand.
Uint8List fullMember(Uint8List data) {
  final h = GzipHeader()
    ..mTime = 1700000000
    ..hostOs = 11
    ..extra = Uint8List.fromList([0x41, 0x42, 3, 0, 1, 2, 3])
    ..name = Uint8List.fromList('name.txt'.codeUnits)
    ..comment = Uint8List.fromList('a comment'.codeUnits);
  final t = Uint8List(8);
  setUint32LE(t, 0, Crc32.of(data));
  setUint32LE(t, 4, data.length);
  return Uint8List.fromList(
      [...h.toBytes(withHcrc: true), ...deflateBytes(data, level: 9), ...t]);
}

(int, Uint8List, GzipArchive) extract(Uint8List gz) {
  final a = GzipArchive.open(MemoryInStream(gz));
  expect(a, isNotNull);
  final out = MemoryOutStream();
  final r = a!.extract(out);
  return (r, Uint8List.fromList(out.toBytes()), a);
}

bool _have(String exe, List<String> args) {
  try {
    return Process.runSync(exe, args).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  final data = gen(100000, 1);
  final mTime = DateTime.utc(2024, 5, 6, 7, 8, 9);

  test('create: header as 7-Zip writes it', () {
    final gz = gzipCreate(data, name: 'hello.txt', mTime: mTime);
    // 7z a -tgzip of hello.txt modified 2024-05-06 07:08:09 UTC
    expect(gz.sublist(0, 20), [
      0x1f, 0x8b, 0x08, 0x08, 0xd9, 0x81, 0x38, 0x66, 0x04, 0x03, //
      ...'hello.txt'.codeUnits, 0
    ]);
    final gz9 = gzipCreate(data, name: 'a', level: '9');
    expect(gz9[3], 0x08);
    expect(gz9.sublist(4, 8), [0, 0, 0, 0]); // no time
    expect(gz9[8], 2); // XFL: maximum compression
    final gz0 = gzipCreate(data);
    expect(gz0[3], 0); // no name
    // the trailer
    expect(getUint32LE(gz, gz.length - 8), Crc32.of(data));
    expect(getUint32LE(gz, gz.length - 4), data.length);
    // times before 1970 are not stored
    final old = gzipCreate(data, mTime: DateTime.utc(1960));
    expect(old.sublist(4, 8), [0, 0, 0, 0]);
  });

  test('round trip and properties', () {
    for (final level in ['1', '5', '9']) {
      final gz = gzipCreate(data, name: 'dir/x.bin', mTime: mTime, level: level);
      final (r, out, a) = extract(gz);
      expect(r, OperationResult.ok);
      expect(out, data);
      expect(a.name, 'x.bin');
      expect(a.mTime, mTime);
      expect(a.size, data.length);
      expect(a.packSize, gz.length);
      expect(a.numMembers, 1);
      final h = a.handler;
      expect(h.getProperty(0, Kpid.hostOS), 'Unix');
      expect(h.getProperty(0, Kpid.crc), Crc32.of(data));
      expect(h.getArchiveProperty(Kpid.headersSize), 16);
    }
    final empty = gzipCreate(Uint8List(0), name: 'e');
    final (r, out, a) = extract(empty);
    expect(r, OperationResult.ok);
    expect(out, isEmpty);
    expect(a.size, 0);
  });

  test('FEXTRA, FNAME, FCOMMENT, FHCRC', () {
    final gz = fullMember(data);
    final (r, out, a) = extract(gz);
    expect(r, OperationResult.ok);
    expect(out, data);
    expect(a.name, 'name.txt');
    expect(a.comment, 'a comment');
    expect(a.handler.getProperty(0, Kpid.hostOS), 'NTFS');
    expect(a.handler.getArchiveProperty(Kpid.headersSize), 40);
    expect(a.handler.getProperty(0, Kpid.mTime),
        1700000000 * 10000000 + 116444736000000000);
    expect(a.handler.header!.hcrcMismatch, isFalse);
    // a wrong header CRC is not checked (as in 7-Zip), only recorded
    final bad = Uint8List.fromList(gz);
    bad[38] ^= 1;
    final (r2, out2, a2) = extract(bad);
    expect(r2, OperationResult.ok);
    expect(out2, data);
    expect(a2.handler.header!.hcrcMismatch, isTrue);
  });

  test('concatenated members', () {
    final a1 = gen(3000, 2), a2 = gen(5000, 3);
    final gz = Uint8List.fromList([
      ...gzipCreate(a1, name: 'x'),
      ...fullMember(a2),
      ...gzipCreate(Uint8List(0)),
    ]);
    final (r, out, a) = extract(gz);
    expect(r, OperationResult.ok);
    expect(out, [...a1, ...a2]);
    expect(a.numMembers, 3);
    expect(a.size, a1.length + a2.length);
    expect(a.handler.getArchiveProperty(Kpid.phySize), gz.length);
  });

  test('trailing data, truncation and corruption', () {
    final gz = gzipCreate(data, name: 'x');
    int res(List<int> b) => extract(Uint8List.fromList(b)).$1;
    // zeros, garbage, a partial or invalid next header: data after the end
    expect(res([...gz, ...Uint8List(100)]), OperationResult.dataAfterEnd);
    expect(res([...gz, ...'garbage'.codeUnits]), OperationResult.dataAfterEnd);
    expect(res([...gz, 0x1f, 0x8b]), OperationResult.dataAfterEnd);
    expect(res([...gz, 0x1f, 0x8b, 9, 0, 0, 0, 0, 0, 0, 3]),
        OperationResult.dataAfterEnd);
    // a valid next header with truncated data: unexpected end
    expect(res([...gz, ...gz.sublist(0, 30)]), OperationResult.unexpectedEnd);
    // truncated data and trailer
    expect(res(gz.sublist(0, gz.length - 100)), OperationResult.unexpectedEnd);
    expect(res(gz.sublist(0, gz.length - 3)), OperationResult.unexpectedEnd);
    // CRC and ISIZE
    final c = Uint8List.fromList(gz);
    c[c.length - 8] ^= 1;
    expect(res(c), OperationResult.crcError);
    final s = Uint8List.fromList(gz);
    s[s.length - 1] ^= 1;
    expect(res(s), OperationResult.crcError);
    // bad deflate data
    final d = Uint8List.fromList(gz);
    d[12] = 0xff;
    d[13] = 0xff;
    expect(res(d), isNot(OperationResult.ok));
    // not gzip
    expect(GzipArchive.open(MemoryInStream(Uint8List.fromList([1, 2, 3]))),
        isNull);
    expect(
        GzipArchive.open(MemoryInStream(
            Uint8List.fromList([0x1f, 0x8b, 8, 0x20, 0, 0, 0, 0, 0, 3]))),
        isNull);
  });

  test('open lists the last trailer as 7-Zip does', () {
    final gz = gzipCreate(data, name: 'x');
    final a = GzipArchive.open(MemoryInStream(
        Uint8List.fromList([...gz, ...Uint8List(8)])))!;
    expect(a.size, 0);
    expect(a.test(), OperationResult.dataAfterEnd);
  });

  test('openSeq', () {
    final gz = gzipCreate(data, name: 'seq.bin', mTime: mTime);
    final a = GzipArchive.openSeq(MemoryInStream(gz));
    expect(a.name, isNull);
    final out = MemoryOutStream();
    expect(a.extract(out), OperationResult.ok);
    expect(out.toBytes(), data);
    expect(a.name, 'seq.bin');
    expect(a.size, data.length);
    expect(a.packSize, gz.length);
  });

  test('properties', () {
    final h = GzipHandler();
    h.setPropertiesFromStrings(
        [const MapEntry('x', '7'), const MapEntry('fb', '64')]);
    expect(h.level, 7);
    h.setPropertiesFromStrings([const MapEntry('m', 'Deflate')]);
    expect(h.level, 5);
    expect(() => h.setPropertiesFromStrings([const MapEntry('m', 'LZMA')]),
        throwsA(isA<SevenZipException>()));
    expect(() => h.setPropertiesFromStrings([const MapEntry('d', '20')]),
        throwsA(isA<SevenZipException>()));
    // -mtm-: no time in the header
    final out = MemoryOutStream();
    GzipArchive.create(MemoryInStream(data), out, data.length,
        name: 'x', mTime: mTime, properties: [const MapEntry('tm', '-')]);
    expect(out.toBytes().sublist(4, 8), [0, 0, 0, 0]);
  });

  final haveGzip = _have('gzip', ['--version']);
  final have7z = File('/usr/bin/7z').existsSync();

  test('gzip accepts our files, we decode gzip -1 .. -9', () {
    final dir = Directory.systemTemp.createTempSync('zx_gzip');
    try {
      final src = File('${dir.path}/src.bin')..writeAsBytesSync(data);
      for (final level in ['1', '6', '9']) {
        final f = File('${dir.path}/o$level.gz')
          ..writeAsBytesSync(gzipCreate(data, name: 'src.bin', level: level));
        expect(Process.runSync('gzip', ['-t', f.path]).exitCode, 0);
        final r =
            Process.runSync('gzip', ['-dc', f.path], stdoutEncoding: null);
        expect(r.stdout, data);
      }
      for (var level = 1; level <= 9; level++) {
        final r = Process.runSync('gzip', ['-$level', '-c', src.path],
            stdoutEncoding: null);
        final gz = Uint8List.fromList(r.stdout as List<int>);
        final (res, out, a) = extract(gz);
        expect(res, OperationResult.ok);
        expect(out, data);
        expect(a.name, 'src.bin');
      }
      // gzip itself writes concatenated members with gzip -c a b
      final r = Process.runSync('sh', ['-c', 'gzip -c ${src.path} ${src.path}'],
          stdoutEncoding: null);
      final (res, out, a) = extract(Uint8List.fromList(r.stdout as List<int>));
      expect(res, OperationResult.ok);
      expect(out.length, 2 * data.length);
      expect(a.numMembers, 2);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: haveGzip ? false : 'gzip not found');

  test('7z accepts our files and we read 7z files', () {
    final dir = Directory.systemTemp.createTempSync('zx_gzip');
    try {
      final f = File('${dir.path}/o.gz')
        ..writeAsBytesSync(gzipCreate(data, name: 'o.bin', mTime: mTime));
      final t = Process.runSync('/usr/bin/7z', ['t', f.path]);
      expect(t.exitCode, 0);
      expect(t.stdout as String, contains('Everything is Ok'));
      final src = File('${dir.path}/s.bin')..writeAsBytesSync(data);
      final g = '${dir.path}/s.gz';
      expect(Process.runSync('/usr/bin/7z', ['a', '-tgzip', '-mx9', g, src.path])
          .exitCode, 0);
      final (res, out, a) = extract(File(g).readAsBytesSync());
      expect(res, OperationResult.ok);
      expect(out, data);
      expect(a.name, 's.bin');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: have7z ? false : '7z not found');
}
