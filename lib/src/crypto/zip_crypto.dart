// Traditional PKWARE encryption of zip archives ("ZipCrypto"), written from
// the PKWARE APPNOTE (section 6.1, Traditional PKWARE Encryption): three 32
// bit keys updated with CRC-32 per plain byte, a 12 byte encryption header
// whose last byte checks the password.

import 'dart:math';
import 'dart:typed_data';

import '../io/streams.dart';

/// Size of the encryption header in front of the data.
const int kZipCryptoHeaderSize = 12;

final Uint32List _crcTable = _makeTable();

Uint32List _makeTable() {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var r = i;
    for (var j = 0; j < 8; j++) {
      r = (r & 1) != 0 ? (r >> 1) ^ 0xEDB88320 : r >> 1;
    }
    t[i] = r;
  }
  return t;
}

/// The key state of APPNOTE 6.1.5 and 6.1.6.
class ZipCryptoKeys {
  int _k0 = 0;
  int _k1 = 0;
  int _k2 = 0;

  /// Initializes the keys with [password] (APPNOTE 6.1.5).
  ZipCryptoKeys(Uint8List password) {
    _k0 = 0x12345678;
    _k1 = 0x23456789;
    _k2 = 0x34567890;
    for (var i = 0; i < password.length; i++) {
      _update(password[i]);
    }
  }

  // update_keys
  void _update(int c) {
    final t = _crcTable;
    _k0 = t[(_k0 ^ c) & 0xFF] ^ (_k0 >> 8);
    _k1 = (_k1 + (_k0 & 0xFF)) & 0xFFFFFFFF;
    _k1 = (_k1 * 134775813 + 1) & 0xFFFFFFFF;
    _k2 = t[(_k2 ^ (_k1 >> 24)) & 0xFF] ^ (_k2 >> 8);
  }

  // decrypt_byte
  int _decryptByte() {
    final temp = (_k2 | 2) & 0xFFFF;
    return ((temp * (temp ^ 1)) >> 8) & 0xFF;
  }

  /// Decrypts [len] bytes of [buf] at [off] in place.
  void decrypt(Uint8List buf, int off, int len) {
    final t = _crcTable;
    var k0 = _k0, k1 = _k1, k2 = _k2;
    final end = off + len;
    for (var i = off; i < end; i++) {
      final temp = (k2 | 2) & 0xFFFF;
      final c = buf[i] ^ (((temp * (temp ^ 1)) >> 8) & 0xFF);
      buf[i] = c;
      k0 = t[(k0 ^ c) & 0xFF] ^ (k0 >> 8);
      k1 = (((k1 + (k0 & 0xFF)) & 0xFFFFFFFF) * 134775813 + 1) & 0xFFFFFFFF;
      k2 = t[(k2 ^ (k1 >> 24)) & 0xFF] ^ (k2 >> 8);
    }
    _k0 = k0;
    _k1 = k1;
    _k2 = k2;
  }

  /// Encrypts [len] bytes of [src] at [srcOff] into [dst] at [dstOff].
  void encrypt(Uint8List src, int srcOff, Uint8List dst, int dstOff, int len) {
    final t = _crcTable;
    var k0 = _k0, k1 = _k1, k2 = _k2;
    for (var i = 0; i < len; i++) {
      final c = src[srcOff + i];
      final temp = (k2 | 2) & 0xFFFF;
      dst[dstOff + i] = c ^ (((temp * (temp ^ 1)) >> 8) & 0xFF);
      k0 = t[(k0 ^ c) & 0xFF] ^ (k0 >> 8);
      k1 = (((k1 + (k0 & 0xFF)) & 0xFFFFFFFF) * 134775813 + 1) & 0xFFFFFFFF;
      k2 = t[(k2 ^ (k1 >> 24)) & 0xFF] ^ (k2 >> 8);
    }
    _k0 = k0;
    _k1 = k1;
    _k2 = k2;
  }

  /// One keystream byte without changing the state (for tests).
  int get nextMask => _decryptByte();
}

/// Pull decryption of a ZipCrypto item: [readHeader] first, then the
/// plain data.
class ZipCryptoDecoder implements InStream {
  final InStream _in;
  final ZipCryptoKeys _keys;

  ZipCryptoDecoder(this._in, Uint8List password)
      : _keys = ZipCryptoKeys(password);

  /// Reads and decrypts the 12 byte header (APPNOTE 6.1.6) and returns its
  /// last byte, the password check value: the high byte of the CRC, or of
  /// the DOS time when the item has a data descriptor.
  int readHeader() {
    final h = Uint8List(kZipCryptoHeaderSize);
    readExactly(_in, h, 0, kZipCryptoHeaderSize);
    _keys.decrypt(h, 0, kZipCryptoHeaderSize);
    return h[kZipCryptoHeaderSize - 1];
  }

  @override
  int read(Uint8List buf, int off, int len) {
    final n = _in.read(buf, off, len);
    if (n > 0) _keys.decrypt(buf, off, n);
    return n;
  }
}

/// Push encryption of a ZipCrypto item: [writeHeader] first, then the
/// data. Does not flush or close [out].
class ZipCryptoEncoder implements OutStream {
  final OutStream _out;
  final ZipCryptoKeys _keys;
  final Uint8List _buf = Uint8List(1 << 16);

  ZipCryptoEncoder(this._out, Uint8List password)
      : _keys = ZipCryptoKeys(password);

  /// Writes the 12 byte header: 11 random bytes and [checkByte].
  void writeHeader(int checkByte, [Random? random]) {
    final rnd = random ?? Random.secure();
    final h = Uint8List(kZipCryptoHeaderSize);
    for (var i = 0; i < kZipCryptoHeaderSize - 1; i++) {
      h[i] = rnd.nextInt(256);
    }
    h[kZipCryptoHeaderSize - 1] = checkByte & 0xFF;
    write(h, 0, kZipCryptoHeaderSize);
  }

  @override
  void write(Uint8List buf, int off, int len) {
    while (len > 0) {
      final n = len < _buf.length ? len : _buf.length;
      _keys.encrypt(buf, off, _buf, 0, n);
      _out.write(_buf, 0, n);
      off += n;
      len -= n;
    }
  }

  @override
  void flush() => _out.flush();
}
