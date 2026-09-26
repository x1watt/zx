import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/codec.dart';
import 'package:zx/src/crypto/aes.dart';
import 'package:zx/src/crypto/seven_zip_aes.dart';
import 'package:zx/src/crypto/sha256.dart';
import 'package:zx/src/io/streams.dart';

Uint8List unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

String hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

final Map<int, DecoderFactory> reg = () {
  final r = <int, DecoderFactory>{};
  registerCryptoCodecs(r);
  return r;
}();

Uint8List decrypt(
    Uint8List props, Uint8List packed, int? size, String? password) {
  return readAll(reg[MethodId.aes]!(props, [MemoryInStream(packed)], size,
      CoderContext(password: password == null ? null : () => password)));
}

void main() {
  group('SHA-256 (FIPS 180)', () {
    test('short messages', () {
      expect(hex(Sha256.hash(Uint8List(0))),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(hex(Sha256.hash(ascii.encode('abc'))),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
          hex(Sha256.hash(ascii.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    });

    test('one million a, in odd pieces', () {
      final sha = Sha256();
      final chunk = Uint8List(1100)..fillRange(0, 1100, 0x61);
      var left = 1000000;
      var piece = 1;
      while (left > 0) {
        final n = piece < left ? piece : left;
        sha.update(chunk, 0, n);
        left -= n;
        piece = piece % 997 + 7;
      }
      expect(hex(sha.digest()),
          'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
    });
  });

  group('AES (FIPS 197, SP 800-38A)', () {
    final pt = unhex('00112233445566778899aabbccddeeff');
    final vectors = {
      '000102030405060708090a0b0c0d0e0f': '69c4e0d86a7b0430d8cdb78070b4c55a',
      '000102030405060708090a0b0c0d0e0f1011121314151617':
          'dda97ca4864cdfe06eaf70a0ec0d7191',
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f':
          '8ea2b7ca516745bfeafc49904b496089',
    };
    vectors.forEach((key, ct) {
      test('${key.length * 4}-bit key', () {
        final b = Uint8List.fromList(pt);
        aesEncryptBlock(unhex(key), b);
        expect(hex(b), ct);
        aesDecryptBlock(unhex(key), b);
        expect(b, pt);
      });
    });

    test('CBC-AES256', () {
      final key = unhex(
          '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4');
      final iv = unhex('000102030405060708090a0b0c0d0e0f');
      final plain = unhex('6bc1bee22e409f96e93d7e117393172a'
          'ae2d8a571e03ac9c9eb76fac45af8e51'
          '30c81c46a35ce411e5fbc1191a0a52ef'
          'f69f2445df4f9b17ad2b417be66c3710');
      const cipher = 'f58c4c04d6e5f1ba779eabfb5f7bfbd6'
          '9cfc4e967edb808d679f777bc6702c7d'
          '39f23369a9d9bacfa530e26304231461'
          'b2eb05e2c39be9fcda6c19078c6a9d1b';
      final enc = AesCbcFilter(true)
        ..setKey(key)
        ..setInitVector(iv)
        ..init();
      final b = Uint8List.fromList(plain);
      // Two calls: the CBC chain value carries over.
      expect(enc.filter(b, 0, 16), 16);
      expect(enc.filter(b, 16, 48), 48);
      expect(hex(b), cipher);
      final dec = AesCbcFilter(false)
        ..setKey(key)
        ..setInitVector(iv)
        ..init();
      expect(dec.filter(b, 0, 64), 64);
      expect(b, plain);
      // A short tail asks for a full block.
      expect(dec.filter(b, 0, 5), 16);
    });
  });

  group('7zAES', () {
    test('key derivation', () {
      Uint8List derive(String pw, List<int> salt, int power) =>
          sevenZipAesDeriveKey(
              Uint8List.fromList(salt), sevenZipPasswordBytes(pw), power);
      // Reference values from Python's hashlib over the same byte stream.
      expect(hex(derive('abc', [], 5)),
          '5672f039fab1e2b8b4ad6b1616d08a178721ed357d54b04d58efdaa7adf88f94');
      expect(hex(derive('Passw0rd!', [1, 2, 3, 4, 5, 6, 7, 8], 10)),
          '33c306cd53e81887f6aa91c221d7518a388fdd8887f1f117a2146c4a3423159a');
      expect(hex(derive('SECRET', [], 19)),
          '1a1b2d5a6c0a216a1464fb68fab3d58e07833479011fa8ae4466894164b2ac50');
      // NumCyclesPower 0x3F: salt + password bytes, zero padded.
      expect(hex(derive('ab', [9, 8], 0x3F)),
          '0908610062000000000000000000000000000000000000000000000000000000');
    });

    test('decrypts data made by 7-Zip (Copy, UTF-16 password)', () {
      // 7z a -m0=Copy -mhc=off -p'P\u00e4ss w\u00f6rd' (UTF-8 locale) v.7z fox.txt
      final props = unhex('530f842115981caeb2ad596bb06c52358276');
      final packed = unhex(
          'aa24f0258c14bb52aeb36104b487c97a912e7c97223c8c7d9d8632c9689273cd'
          '9aada62997391bfdda8ac40bda84ed5c');
      final out = decrypt(props, packed, 45, 'P\u00e4ss w\u00f6rd');
      expect(
          ascii.decode(out), 'The quick brown fox jumps over the lazy dog.\n');
      // A wrong password decrypts to garbage (no check value in 7zAES).
      expect(decrypt(props, packed, 45, 'wrong'), isNot(out));
    });

    test('encoder round trip, props and padding', () {
      final plain = Uint8List.fromList(List.generate(1000, (i) => i * 7));
      for (final len in [0, 1, 15, 16, 17, 1000]) {
        final out = MemoryOutStream();
        final e = SevenZipAesEncoder(out, 'secret',
            numCyclesPower: 6, iv: Uint8List.fromList(List.filled(16, 3)));
        // Written in odd pieces.
        for (var i = 0; i < len; i += 7) {
          e.write(plain, i, len - i < 7 ? len - i : 7);
        }
        e.close();
        final packed = Uint8List.fromList(out.toBytes());
        expect(packed.length, (len + 15) ~/ 16 * 16);
        expect(e.props, [0x46, 0x0f, ...List.filled(16, 3)]);
        expect(decrypt(e.props, packed, len, 'secret'),
            Uint8List.sublistView(plain, 0, len));
        if (len > 0) {
          // The zero padding decrypts back when the size is not limited.
          final all = decrypt(e.props, packed, null, 'secret');
          expect(all.skip(len), everyElement(0));
        }
      }
    });

    test('default encoder: 7-Zip props and random IV', () {
      final a = SevenZipAesEncoder(NullOutStream(), 'x');
      final b = SevenZipAesEncoder(NullOutStream(), 'x');
      expect(a.props.length, 18);
      expect(a.props[0], 0x40 | 19);
      expect(a.props[1], 0x0f);
      expect(a.props, isNot(b.props));
    });

    test('errors', () {
      final props = unhex('530f842115981caeb2ad596bb06c52358276');
      expect(
          () => decrypt(props, Uint8List(16), 16, null),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.wrongPassword)));
      // Size not a multiple of the block size.
      expect(() => decrypt(unhex('06'), Uint8List(20), null, 'a'),
          throwsA(isA<SevenZipException>()));
      // Bad props: wrong length, too many cycles.
      for (final p in ['53', '530f00', '5f0f', '590f${'00' * 16}']) {
        expect(
            () => decrypt(unhex(p), Uint8List(16), 16, 'a'),
            throwsA(isA<SevenZipException>().having(
                (e) => e.kind, 'kind', SevenZipError.unsupportedMethod)),
            reason: p);
      }
    });
  });
}
