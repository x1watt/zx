// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/zpaq/core/crc32.dart';
import 'package:zx/src/zpaq/core/sha1.dart';
import 'package:zx/src/zpaq/core/xxhash64.dart';
import 'package:zx/src/zpaq/crypto/aes_ctr.dart';
import 'package:zx/src/zpaq/crypto/sha256.dart';

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) => Uint8List.fromList(List.generate(
    s.length ~/ 2, (i) => int.parse(s.substring(2 * i, 2 * i + 2), radix: 16)));

void main() {
  test('SHA-1 vectors', () {
    expect(hex(Sha1.hash(utf8.encode(''))),
        'da39a3ee5e6b4b0d3255bfef95601890afd80709');
    expect(hex(Sha1.hash(utf8.encode('abc'))),
        'a9993e364706816aba3e25717850c26c9cd0d89d');
    final s = Sha1();
    for (var i = 0; i < 1000000; ++i) {
      s.addByte(0x61);
    }
    expect(hex(s.digest()), '34aa973cd4c4daa4f61eeb2bdbad27316534016f');
    // chunked adds give the same digest
    final data = Uint8List.fromList(List.generate(1000, (i) => i * 7));
    final c = Sha1()
      ..add(data, 0, 13)
      ..add(data, 13, 500)
      ..add(data, 500);
    expect(hex(c.digest()), hex(Sha1.hash(data)));
  });

  test('SHA-256 vectors', () {
    expect(hex(Sha256.hash(utf8.encode('abc'))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(
        hex(Sha256.hash(utf8.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
  });

  test('XXH64 vectors, whole and in pieces', () {
    String h64(int x) =>
        (x >>> 32).toRadixString(16).padLeft(8, '0') +
        (x & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    expect(h64(XxHash64.hash(Uint8List(0))), 'ef46db3751d8e999');
    expect(h64(XxHash64.hash(Uint8List.fromList(utf8.encode('abc')))),
        '44bc2cf5ad770999');
    expect(
        h64(XxHash64.hash(Uint8List.fromList(
            utf8.encode('Nobody inspects the spammish repetition')))),
        'fbcea83c8a378bf1');
    final data = Uint8List.fromList(List.generate(1000, (i) => i * 13));
    final whole = XxHash64.hash(data);
    for (final cut in [1, 7, 31, 32, 33, 100, 999]) {
      final x = XxHash64()
        ..add(data, 0, cut)
        ..add(data, cut);
      expect(x.digest(), whole, reason: 'cut $cut');
    }
  });

  test('CRC-32 vector', () {
    final c = Crc32()..add(Uint8List.fromList(utf8.encode('123456789')));
    expect(c.value, 0xCBF43926);
  });

  test('AES-256 block (FIPS-197 C.3) and CTR key stream', () {
    final key = unhex(
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    final aes = AesCtr(key, unhex('0001020304050607'));
    expect(hex(aes.encryptBlock(unhex('00112233445566778899aabbccddeeff'))),
        '8ea2b7ca516745bfeafc49904b496089');
    // CTR: block number 2 (offset 32..47) uses counter iv || 00..02
    final buf = Uint8List(16);
    aes.apply(buf, 0, 16, 32);
    expect(hex(buf),
        hex(aes.encryptBlock(unhex('00010203040506070000000000000002'))));
  });

  test('scrypt (RFC 7914 test vector 2)', () {
    final out = scrypt(Uint8List.fromList(utf8.encode('password')),
        Uint8List.fromList(utf8.encode('NaCl')), 1024, 8, 16, 64);
    expect(
        hex(out),
        'fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162'
        '2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640');
  });
}
