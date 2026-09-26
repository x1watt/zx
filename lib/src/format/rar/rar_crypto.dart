// AES-256-CBC streams of RAR5 encrypted data and headers (the RAR5
// technote: AES-256, a 16 byte IV per file and per encrypted header).

import 'dart:typed_data';

import '../../crypto/aes.dart';
import '../../io/streams.dart';

/// Decrypts [base] (whole 16 byte blocks) with AES-256-CBC.
final class RarAesDecryptInStream implements InStream {
  final InStream base;
  final Uint32List _aes = Uint32List(kAesNumIvMrkWords);
  final Uint8List _buf = Uint8List(1 << 16);
  int _pos = 0;
  int _len = 0;
  bool _eof = false;

  RarAesDecryptInStream(this.base, Uint8List key, Uint8List iv) {
    aesSetKeyDec(_aes, 4, key, key.length);
    aesCbcInit(_aes, iv);
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (_pos == _len) {
      if (_eof) return 0;
      var n = readFully(base, _buf, 0, _buf.length);
      if (n < _buf.length) _eof = true;
      n &= ~15;
      if (n == 0) return 0;
      aesCbcDecode(_aes, _buf, 0, n >> 4);
      _pos = 0;
      _len = n;
    }
    final n = len < _len - _pos ? len : _len - _pos;
    buf.setRange(off, off + n, _buf, _pos);
    _pos += n;
    return n;
  }
}

/// Decrypts [data] in place ([len] a multiple of 16).
void rarAesDecrypt(
    Uint8List key, Uint8List iv, Uint8List data, int off, int len) {
  final aes = Uint32List(kAesNumIvMrkWords);
  aesSetKeyDec(aes, 4, key, key.length);
  aesCbcInit(aes, iv);
  aesCbcDecode(aes, data, off, len >> 4);
}

/// Encrypts with AES-256-CBC into [base], padding the end with zeros to a
/// whole block on [finish].
final class RarAesEncryptOutStream implements OutStream {
  final OutStream base;
  final Uint32List _aes = Uint32List(kAesNumIvMrkWords);
  final Uint8List _buf = Uint8List(1 << 16);
  int _len = 0;
  int written = 0;

  RarAesEncryptOutStream(this.base, Uint8List key, Uint8List iv) {
    aesSetKeyEnc(_aes, 4, key, key.length);
    aesCbcInit(_aes, iv);
  }

  @override
  void write(Uint8List buf, int off, int len) {
    while (len > 0) {
      var n = _buf.length - _len;
      if (n > len) n = len;
      _buf.setRange(_len, _len + n, buf, off);
      _len += n;
      off += n;
      len -= n;
      if (_len == _buf.length) _drain(_len);
    }
  }

  void _drain(int n) {
    aesCbcEncode(_aes, _buf, 0, n >> 4);
    base.write(_buf, 0, n);
    written += n;
    final rest = _len - n;
    if (rest > 0) _buf.setRange(0, rest, _buf, n);
    _len = rest;
  }

  @override
  void flush() {}

  /// Pads the last block and writes it.
  void finish() {
    final pad = (16 - (_len & 15)) & 15;
    _buf.fillRange(_len, _len + pad, 0);
    _len += pad;
    if (_len > 0) _drain(_len);
  }
}

/// Encrypts [data] in place ([len] a multiple of 16).
void rarAesEncrypt(
    Uint8List key, Uint8List iv, Uint8List data, int off, int len) {
  final aes = Uint32List(kAesNumIvMrkWords);
  aesSetKeyEnc(aes, 4, key, key.length);
  aesCbcInit(aes, iv);
  aesCbcEncode(aes, data, off, len >> 4);
}
