// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/io.dart';
import '../crypto/aes_ctr.dart';
import '../crypto/sha256.dart';

/// Encryption key material for a zpaq `-key` archive.
class ZpaqKey {
  /// SHA-256 of the password, as zpaq hashes the `-key` argument.
  final Uint8List passwordHash;

  ZpaqKey(this.passwordHash);

  /// Keys are the SHA-256 of the UTF-8 password bytes, as zpaq does.
  factory ZpaqKey.fromPassword(String password) =>
      ZpaqKey(Sha256.hash(utf8.encode(password)));

  final Map<String, Uint8List> _stretched = {};

  /// AES-256-CTR cipher for an archive with [salt] (key stretching with
  /// scrypt is cached per salt).
  AesCtr cipherFor(Uint8List salt) {
    final k = _stretched[salt.join(',')] ??= zpaqStretchKey(passwordHash, salt);
    return AesCtr(k, salt);
  }
}

/// Random 32 byte salt whose first byte is never 'z' or '7' (so an
/// encrypted archive is never mistaken for a plain one).
Uint8List randomSalt() {
  final r = Random.secure();
  final s = Uint8List(32);
  for (var i = 0; i < 32; ++i) {
    s[i] = r.nextInt(256);
  }
  if (s[0] == 0x7a || s[0] == 0x37) s[0] ^= 0x80;
  return s;
}

/// Buffered, seekable, optionally decrypting reader over an archive file.
/// Positions are absolute file offsets (including the 32 byte salt).
class ArchiveInput extends ZReader {
  final RandomAccessFile _raf;
  final AesCtr? _aes;
  final int length;
  final Uint8List _buf = Uint8List(1 << 16);
  int _bufStart = 0; // file offset of _buf[0]
  int _bufLen = 0;
  int _pos = 0;

  ArchiveInput._(this._raf, this._aes, this.length, int start) : _pos = start {
    _bufStart = start;
  }

  /// Opens [path]. With a [key], reads the salt and decrypts.
  static ArchiveInput open(String path, {ZpaqKey? key}) {
    final raf = File(path).openSync();
    final len = raf.lengthSync();
    if (key == null) return ArchiveInput._(raf, null, len, 0);
    if (len < 32) {
      raf.closeSync();
      zpaqError('archive too small to be encrypted');
    }
    final salt = raf.readSync(32);
    return ArchiveInput._(raf, key.cipherFor(salt), len, 32);
  }

  /// Offset where archive data starts (32 when encrypted).
  int get dataStart => _aes == null ? 0 : 32;

  int get position => _pos;

  void seek(int p) {
    _pos = p;
  }

  void close() => _raf.closeSync();

  bool _refill() {
    if (_pos >= length) return false;
    _raf.setPositionSync(_pos);
    final n = _raf.readIntoSync(_buf, 0, _buf.length);
    if (n <= 0) return false;
    _bufStart = _pos;
    _bufLen = n;
    _aes?.apply(_buf, 0, n, _pos);
    return true;
  }

  @override
  int get() {
    final i = _pos - _bufStart;
    if (i < 0 || i >= _bufLen) {
      if (!_refill()) return -1;
      return _buf[(_pos++) - _bufStart];
    }
    _pos++;
    return _buf[i];
  }

  @override
  int read(Uint8List buf, int off, int n) {
    var done = 0;
    while (done < n) {
      var i = _pos - _bufStart;
      if (i < 0 || i >= _bufLen) {
        if (!_refill()) break;
        i = 0;
      }
      var k = _bufLen - i;
      if (k > n - done) k = n - done;
      buf.setRange(off + done, off + done + k, _buf, i);
      done += k;
      _pos += k;
    }
    return done;
  }

  /// Reads the first bytes to check for a plain zpaq archive header.
  static bool looksPlain(String path) {
    final raf = File(path).openSync();
    try {
      final b = raf.readSync(4);
      if (b.isEmpty) return true;
      // "7kSt" locator tag or "zPQ" block header
      return (b.length >= 4 &&
              b[0] == 0x37 &&
              b[1] == 0x6b &&
              b[2] == 0x53 &&
              b[3] == 0x74) ||
          (b.length >= 3 && b[0] == 0x7a && b[1] == 0x50 && b[2] == 0x51);
    } finally {
      raf.closeSync();
    }
  }
}

/// Buffered, seekable, optionally encrypting writer to an archive file.
class ArchiveOutput extends ZWriter {
  final RandomAccessFile _raf;
  final AesCtr? _aes;
  final Uint8List _buf = Uint8List(1 << 16);
  int _bufLen = 0;
  int _pos; // logical position of _buf[0] + _bufLen

  ArchiveOutput._(this._raf, this._aes, this._pos);

  /// Opens [path] for update (creating it). With a [key] a new file gets a
  /// fresh salt, an existing one keeps its salt.
  static ArchiveOutput open(String path, {ZpaqKey? key}) {
    final f = File(path);
    final exists = f.existsSync() && f.lengthSync() > 0;
    final raf = f.openSync(mode: exists ? FileMode.append : FileMode.write);
    if (key == null) return ArchiveOutput._(raf, null, 0);
    Uint8List salt;
    if (exists) {
      raf.setPositionSync(0);
      salt = raf.readSync(32);
      if (salt.length != 32) zpaqError('cannot read salt');
    } else {
      salt = randomSalt();
      raf.writeFromSync(salt);
    }
    return ArchiveOutput._(raf, key.cipherFor(salt), 32);
  }

  int get position => _pos + _bufLen;

  void flush() {
    if (_bufLen == 0) return;
    _aes?.apply(_buf, 0, _bufLen, _pos);
    _raf.setPositionSync(_pos);
    _raf.writeFromSync(_buf, 0, _bufLen);
    _pos += _bufLen;
    _bufLen = 0;
  }

  void seek(int p) {
    flush();
    _pos = p;
  }

  @override
  void put(int c) {
    if (_bufLen == _buf.length) flush();
    _buf[_bufLen++] = c;
  }

  @override
  void write(Uint8List buf, int off, int n) {
    while (n > 0) {
      if (_bufLen == _buf.length) flush();
      var k = _buf.length - _bufLen;
      if (k > n) k = n;
      _buf.setRange(_bufLen, _bufLen + k, buf, off);
      _bufLen += k;
      off += k;
      n -= k;
    }
  }

  void truncate(int length) {
    flush();
    _raf.truncateSync(length);
  }

  void close() {
    flush();
    _raf.flushSync();
    _raf.closeSync();
  }
}

/// Opens an archive for reading after checking that it is a zpaq archive
/// and, with a [key], that the key decrypts it.
ArchiveInput openArchive(String path, ZpaqKey? key) {
  final plain = ArchiveInput.looksPlain(path);
  if (key == null && !plain) {
    zpaqError('archive is encrypted (password needed) or not a zpaq archive');
  }
  if (key != null && plain) zpaqError('archive is not encrypted');
  final input = ArchiveInput.open(path, key: key);
  if (key != null) {
    // A wrong password decrypts to noise: detect it before scanning.
    final c0 = input.get(), c1 = input.get(), c2 = input.get();
    input.seek(input.dataStart);
    final ok = (c0 == 0x37 && c1 == 0x6b && c2 == 0x53) ||
        (c0 == 0x7a && c1 == 0x50 && c2 == 0x51) ||
        c0 == -1;
    if (!ok) {
      input.close();
      zpaqError('wrong password or not an encrypted zpaq archive');
    }
  }
  return input;
}
