// WinZip AES encryption of zip items (AE-1 and AE-2), written from the
// WinZip specification "AES Encryption Information: Encryption
// Specification AE-1 and AE-2" (version 1.04): PBKDF2 with HMAC-SHA1 and
// 1000 iterations derives the AES key, the HMAC key and a 2 byte password
// verification value from the password and a salt; the data is encrypted
// with AES in CTR mode (a 16 byte little endian block counter starting at
// 1); the last 10 bytes are the first 10 bytes of the HMAC-SHA1 of the
// encrypted data.
//
// Stored item data: salt (8, 12 or 16 bytes), password verification value
// (2 bytes), encrypted data, authentication code (10 bytes).

import 'dart:math';
import 'dart:typed_data';

import '../io/streams.dart';
import 'aes.dart';
import 'hmac_sha1.dart';

/// The id of the AES extra field.
const int kWzAesExtraId = 0x9901;

/// Size of the authentication code after the data.
const int kWzAesMacSize = 10;

/// Size of the password verification value.
const int kWzAesPwvSize = 2;

/// PBKDF2 iterations of the specification.
const int kWzAesIterations = 1000;

/// Key size in bytes for the strength value of the extra field (1, 2, 3).
int wzAesKeySize(int strength) => 8 + strength * 8;

/// Salt size in bytes for a strength value.
int wzAesSaltSize(int strength) => 4 + strength * 4;

/// The overhead of an encrypted item (salt, verifier, code).
int wzAesOverhead(int strength) =>
    wzAesSaltSize(strength) + kWzAesPwvSize + kWzAesMacSize;

/// The derived keys of one item.
class WzAesKeys {
  final Uint8List aesKey;
  final Uint8List macKey;

  /// The 2 byte password verification value.
  final Uint8List pwv;

  WzAesKeys._(this.aesKey, this.macKey, this.pwv);

  /// Derives the keys from [password] (the password bytes, UTF-8) and
  /// [salt] for [strength] (1: AES-128, 2: AES-192, 3: AES-256).
  factory WzAesKeys.derive(Uint8List password, Uint8List salt, int strength) {
    final keySize = wzAesKeySize(strength);
    final dk = pbkdf2HmacSha1(
        password, salt, kWzAesIterations, 2 * keySize + kWzAesPwvSize);
    return WzAesKeys._(
        Uint8List.sublistView(dk, 0, keySize),
        Uint8List.sublistView(dk, keySize, 2 * keySize),
        Uint8List.sublistView(dk, 2 * keySize, 2 * keySize + kWzAesPwvSize));
  }
}

/// AES-CTR as the specification uses it: the counter block is a 128 bit
/// little endian number, 1 for the first 16 bytes of data.
class WzAesCtr {
  final Uint32List _aes = Uint32List(kAesNumIvMrkWords);
  final Uint8List _counter = Uint8List(kAesBlockSize);
  static const int _ksBlocks = 64;
  final Uint8List _ks = Uint8List(kAesBlockSize * _ksBlocks);
  int _ksPos = kAesBlockSize * _ksBlocks;

  WzAesCtr(Uint8List key) {
    aesSetKeyEnc(_aes, 4, key, key.length);
  }

  // the next [_ksBlocks] keystream blocks
  void _fill() {
    final ks = _ks;
    final ctr = _counter;
    final aes = _aes;
    for (var b = 0; b < _ksBlocks; b++) {
      // increment the little endian counter
      for (var i = 0; i < kAesBlockSize; i++) {
        final v = (ctr[i] + 1) & 0xFF;
        ctr[i] = v;
        if (v != 0) break;
      }
      final o = b * kAesBlockSize;
      ks.setRange(o, o + kAesBlockSize, ctr);
      // a zero IV makes one CBC block an ECB encryption
      aes[0] = 0;
      aes[1] = 0;
      aes[2] = 0;
      aes[3] = 0;
      aesCbcEncode(aes, ks, o, 1);
    }
    _ksPos = 0;
  }

  /// XORs the keystream into [len] bytes of [buf] at [off].
  void process(Uint8List buf, int off, int len) {
    final ks = _ks;
    var pos = _ksPos;
    final end = off + len;
    for (var i = off; i < end; i++) {
      if (pos == ks.length) {
        _fill();
        pos = 0;
      }
      buf[i] ^= ks[pos++];
    }
    _ksPos = pos;
  }
}

/// Pull decryption of an AES item. [readHeader] checks the password
/// verification value; the data is then read and decrypted, and at its end
/// the authentication code is read and checked ([SevenZipError.crc] when
/// it does not match).
class WzAesDecoder implements InStream {
  final InStream _in;
  final int _strength;
  final Uint8List _password;

  /// Size of the encrypted data (without salt, verifier and code), or null
  /// when unknown (then [finishUnknownSize] must be called at the end).
  final int? dataSize;
  WzAesCtr? _ctr;
  HmacSha1? _mac;
  int _done = 0;
  bool _checked = false;

  WzAesDecoder(this._in, this._password, this._strength, this.dataSize);

  /// Reads the salt and the verification value; false when the password
  /// is wrong.
  bool readHeader() {
    final salt = Uint8List(wzAesSaltSize(_strength));
    readExactly(_in, salt, 0, salt.length);
    final pwv = Uint8List(kWzAesPwvSize);
    readExactly(_in, pwv, 0, kWzAesPwvSize);
    final keys = WzAesKeys.derive(_password, salt, _strength);
    if (keys.pwv[0] != pwv[0] || keys.pwv[1] != pwv[1]) return false;
    _ctr = WzAesCtr(keys.aesKey);
    _mac = HmacSha1(keys.macKey);
    return true;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    final size = dataSize;
    if (size != null) {
      final rem = size - _done;
      if (rem <= 0) {
        _checkMac();
        return 0;
      }
      if (len > rem) len = rem;
    }
    final n = _in.read(buf, off, len);
    if (n == 0) {
      if (size != null) {
        throw const SevenZipException(
            'Unexpected end of data', SevenZipError.unexpectedEnd);
      }
      return 0;
    }
    _mac!.update(buf, off, n);
    _ctr!.process(buf, off, n);
    _done += n;
    if (size != null && _done == size) _checkMac();
    return n;
  }

  // reads the code after the data and compares it
  void _checkMac() {
    if (_checked) return;
    _checked = true;
    final code = Uint8List(kWzAesMacSize);
    if (readFully(_in, code, 0, kWzAesMacSize) != kWzAesMacSize) {
      throw const SevenZipException(
          'Unexpected end of data', SevenZipError.unexpectedEnd);
    }
    final mac = _mac!.digest();
    for (var i = 0; i < kWzAesMacSize; i++) {
      if (mac[i] != code[i]) {
        throw const SevenZipException(
            'AES authentication code mismatch', SevenZipError.crc);
      }
    }
  }

  /// Checks the code once the data has been read to its end (it is read
  /// right after the data). Called by the handler when the size of the
  /// data was known and the consumer stopped at exactly that size.
  void finish() => _checkMac();

  /// Bytes of encrypted data read so far.
  int get processed => _done;
}

/// Push encryption of an AES item: [writeHeader] writes the salt and the
/// verification value, [write] encrypts, [close] writes the code. Does
/// not flush or close [out].
class WzAesEncoder implements OutStream {
  final OutStream _out;
  final int strength;
  final Uint8List _password;
  WzAesCtr? _ctr;
  HmacSha1? _mac;
  final Uint8List _buf = Uint8List(1 << 16);

  WzAesEncoder(this._out, this._password, this.strength);

  /// Writes the random salt and the password verification value.
  void writeHeader([Random? random]) {
    final rnd = random ?? Random.secure();
    final salt = Uint8List(wzAesSaltSize(strength));
    for (var i = 0; i < salt.length; i++) {
      salt[i] = rnd.nextInt(256);
    }
    final keys = WzAesKeys.derive(_password, salt, strength);
    _ctr = WzAesCtr(keys.aesKey);
    _mac = HmacSha1(keys.macKey);
    _out.write(salt, 0, salt.length);
    _out.write(keys.pwv, 0, kWzAesPwvSize);
  }

  @override
  void write(Uint8List buf, int off, int len) {
    while (len > 0) {
      final n = len < _buf.length ? len : _buf.length;
      _buf.setRange(0, n, buf, off);
      _ctr!.process(_buf, 0, n);
      _mac!.update(_buf, 0, n);
      _out.write(_buf, 0, n);
      off += n;
      len -= n;
    }
  }

  @override
  void flush() => _out.flush();

  /// Writes the authentication code.
  void close() {
    final mac = _mac!.digest();
    _out.write(mac, 0, kWzAesMacSize);
  }
}
