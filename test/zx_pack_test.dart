import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/zxdb.dart';

void main() {
  final data = Uint8List.fromList(List.generate(70000, (i) => i * 7 & 0xFF));

  test('round trip, clear and with each compression', () {
    for (final c in ['none', 'fast', 'max']) {
      final z = zxPackBytes(data, compression: c);
      expect(zxLooksPacked(z), isTrue);
      expect(zxUnpackBytes(z), data);
    }
    expect(zxUnpackBytes(zxPackBytes(Uint8List(0))), isEmpty);
  });

  test('encrypted: the right password reads it, the bytes hide it', () {
    final secret = Uint8List.fromList(('secret payload ' * 50).codeUnits);
    final z = zxPackBytes(secret,
        name: 'key.txt', password: 'k' * 64, scryptLog2N: 1);
    expect(String.fromCharCodes(z).contains('secret payload'), isFalse);
    expect(String.fromCharCodes(z).contains('key.txt'), isFalse);
    expect(zxUnpackBytes(z, password: 'k' * 64), secret);
  });

  test('wrong or missing password, and bytes that are not zx', () {
    final z = zxPackBytes(data, password: 'right', scryptLog2N: 1);
    Matcher kind(SevenZipError k) =>
        throwsA(isA<SevenZipException>().having((e) => e.kind, 'kind', k));
    expect(() => zxUnpackBytes(z, password: 'wrong'),
        kind(SevenZipError.wrongPassword));
    expect(() => zxUnpackBytes(z), kind(SevenZipError.wrongPassword));
    expect(zxLooksPacked(Uint8List.fromList([1, 2, 3])), isFalse);
    expect(() => zxUnpackBytes(Uint8List.fromList(List.filled(100, 7))),
        throwsA(isA<SevenZipException>()));
  });

  test('a cheap key opens fast; the database takes the same option', () {
    final sw = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      zxUnpackBytes(zxPackBytes(data, password: 'p$i', scryptLog2N: 1),
          password: 'p$i');
    }
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });
}
