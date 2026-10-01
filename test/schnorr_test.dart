// BIP-340 signatures and NIP-19 keys (lib/src/crypto/schnorr.dart,
// nip19.dart), against the vectors Arca uses (the first two are the
// official BIP-340 test vectors 0 and 1).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/crypto/nip19.dart';
import 'package:zx/src/crypto/schnorr.dart';

Uint8List fromHex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final vectors =
      (jsonDecode(File('test/data/bip340_vectors.json').readAsStringSync())
              as List)
          .cast<Map<String, dynamic>>();

  test('public keys match', () {
    for (final v in vectors) {
      expect(toHex(publicKeyOf(fromHex(v['sk']))), v['pk']);
    }
  });

  test('signatures match byte for byte and verify', () {
    for (final v in vectors) {
      final sig = schnorrSign(fromHex(v['sk']), fromHex(v['msg']),
          aux: fromHex(v['aux']));
      expect(toHex(sig), v['sig']);
      expect(schnorrVerify(fromHex(v['pk']), fromHex(v['msg']), sig), isTrue);
    }
  });

  test('rejects a changed message, key or signature', () {
    final v = vectors[5];
    final pk = fromHex(v['pk']), msg = fromHex(v['msg']);
    final sig = fromHex(v['sig']);
    expect(schnorrVerify(pk, msg, sig), isTrue);
    expect(schnorrVerify(pk, Uint8List.fromList(msg)..[0] ^= 1, sig), isFalse);
    expect(schnorrVerify(fromHex(vectors[6]['pk']), msg, sig), isFalse);
    expect(schnorrVerify(pk, msg, Uint8List.fromList(sig)..[40] ^= 1), isFalse);
    expect(schnorrVerify(pk, msg, sig.sublist(0, 63)), isFalse);
  });

  test('random keys sign and verify', () {
    for (var i = 0; i < 3; i++) {
      final sk = generateSecretKey();
      final msg = generateSecretKey();
      expect(schnorrVerify(publicKeyOf(sk), msg, schnorrSign(sk, msg)), isTrue);
    }
  });

  test('invalid keys are refused', () {
    expect(isValidSecretKey(List.filled(32, 0)), isFalse);
    expect(isValidSecretKey(List.filled(31, 1)), isFalse);
    expect(() => publicKeyOf(List.filled(32, 0xff)),
        throwsA(isA<SchnorrException>()));
    expect(isValidPublicKey(List.filled(32, 0xff)), isFalse);
  });

  test('npub and nsec', () {
    // NIP-19 example
    const npub =
        'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg';
    final pk = nip19Decode(npub, 'npub');
    expect(toHex(pk),
        '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e');
    expect(npubEncode(pk), npub);
    expect(parsePublicKey(npub), pk);
    expect(parsePublicKey(toHex(pk)), pk);
    const nsec =
        'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';
    final sk = parseSecretKey(nsec);
    expect(toHex(sk),
        '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa');
    expect(nsecEncode(sk), nsec);
    expect(() => nip19Decode(npub, 'nsec'), throwsFormatException);
  });

  test('speed', () {
    final sk = generateSecretKey();
    final pk = publicKeyOf(sk);
    final msg = generateSecretKey();
    final sig = schnorrSign(sk, msg);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      schnorrVerify(pk, msg, sig);
    }
    final verify = sw.elapsedMicroseconds / 20;
    sw.reset();
    for (var i = 0; i < 20; i++) {
      schnorrSign(sk, msg);
    }
    final sign = sw.elapsedMicroseconds / 20;
    print('verify ${(verify / 1000).toStringAsFixed(2)} ms, '
        'sign ${(sign / 1000).toStringAsFixed(2)} ms');
  });
}
