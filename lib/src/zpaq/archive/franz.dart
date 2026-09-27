// Vendored from zpaq-flutter by tool/sync_zpaq.sh: do not edit here, change
// zpaq-flutter and sync again. Pure Dart port of libzpaq and zpaq 7.15 (Matt
// Mahoney, public domain) with the zpaqfranz attribute format (Franco
// Corbelli, MIT). Copyright (c) 2026 Max Brito, BSD 3-clause; see LICENSE
// for the license and the third party notices.

import 'dart:typed_data';

String _cstr(Uint8List b, int off, [int max = 1 << 30]) {
  final sb = StringBuffer();
  for (var i = off; i < b.length && i < off + max && b[i] != 0; ++i) {
    sb.writeCharCode(b[i]);
  }
  return sb.toString();
}

int _le(Uint8List b, int o, int n) {
  var x = 0;
  for (var i = n - 1; i >= 0; --i) {
    x = (x << 8) | (o + i < b.length ? b[o + i] : 0);
  }
  return x;
}

String _hex(int x, int digits) {
  String h32(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  final s = digits > 8 ? h32(x >>> 32) + h32(x) : h32(x);
  return s.substring(s.length - digits).toUpperCase();
}

/// Size of the zpaqfranz extension written for SHA-1 (FRANZOFFSETV2).
const int franzBlockSizeV2 = 76;

/// zpaqfranz per-file extra data stored after the 8 attribute bytes.
class FranzInfo {
  /// Hash algorithm name (e.g. "SHA-1", "XXHASH64", "SHA-256"), or empty.
  final String hashType;

  /// Hash of the whole file, upper case hex, or empty.
  final String hash;

  /// CRC-32 of the whole file, 8 upper case hex digits, or empty.
  final String crc32;

  const FranzInfo(this.hashType, this.hash, this.crc32);

  static const Map<String, String> _asciiTypes = {
    '01': 'MD5',
    '02': 'SHA-3',
    '03': 'BLAKE3',
    '04': 'SHA-256',
    '08': 'SHA-1',
    '09': 'XXH3',
    '10': 'WINXXHASH64',
  };

  /// Decodes the block (attr bytes after the first 8). Unknown layouts give
  /// empty fields.
  static FranzInfo? decode(Uint8List b) {
    if (b.length < 42) return null;
    final code = b.length >= 2 ? String.fromCharCodes(b.sublist(0, 2)) : '';
    final num = int.tryParse(code);
    // Binary layouts (zpaqfranz 58+): 14..20
    if (num != null && num >= 14 && num <= 20 && b.length >= 42) {
      const names = {
        14: 'XXHASH64',
        15: 'MD5',
        16: 'BLAKE3',
        17: 'SHA-256',
        18: 'SHA-3',
        19: 'XXH3',
        20: 'SHA-1'
      };
      String h;
      if (num == 14) {
        h = _hex(_le(b, 2, 8), 16);
      } else if (num == 15 || num == 19) {
        h = _hex(_le(b, 10, 8), 16) + _hex(_le(b, 2, 8), 16);
      } else if (num == 20) {
        h = _hex(_le(b, 18, 4), 8) +
            _hex(_le(b, 10, 8), 16) +
            _hex(_le(b, 2, 8), 16);
      } else {
        h = _hex(_le(b, 26, 8), 16) +
            _hex(_le(b, 18, 8), 16) +
            _hex(_le(b, 10, 8), 16) +
            _hex(_le(b, 2, 8), 16);
      }
      return FranzInfo(names[num]!, h, _hex(_le(b, 34, 4), 8));
    }
    if (b.length > 67 && _asciiTypes.containsKey(code) && b[66] == 0) {
      final crc =
          b.length > 75 && b[67] != 0 && b[75] == 0 ? _cstr(b, 67, 8) : '';
      return FranzInfo(_asciiTypes[code]!, _cstr(b, 2, 64), crc);
    }
    // Legacy XXHASH64 / CRC-32 only layout (FRANZOFFSETV1)
    var type = '', hash = '', crc = '';
    if (b[0] == 0 && b.length > 8 && b[8] != 0) {
      type = 'XXHASH64';
      hash = _cstr(b, 8, 32);
    }
    if (b.length > 49 && b[41] != 0 && b[49] == 0) crc = _cstr(b, 41, 8);
    if (type.isEmpty && crc.isEmpty) return null;
    return FranzInfo(type, hash, crc);
  }

  /// Encodes the SHA-1 layout ("08", 40 hex digits, CRC-32 hex at 67).
  static Uint8List encodeSha1(Uint8List sha1, int crc32) {
    final b = Uint8List(franzBlockSizeV2);
    b[0] = 0x30;
    b[1] = 0x38;
    final h = StringBuffer();
    for (final x in sha1) {
      h.write(x.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    final hs = h.toString();
    for (var i = 0; i < hs.length; ++i) {
      b[2 + i] = hs.codeUnitAt(i);
    }
    final cs = _hex(crc32, 8);
    for (var i = 0; i < 8; ++i) {
      b[67 + i] = cs.codeUnitAt(i);
    }
    return b;
  }

  /// Encodes zpaqfranz's binary XXHASH64 layout (type 14, 50 bytes): the
  /// hash little endian at 2, the CRC-32 at 34, the creation date at 38
  /// (0: unknown), "added" at 47 and a 1 at 49.
  static Uint8List encodeXxhash64(int hash, int crc32, bool added) {
    final b = Uint8List(50);
    final v = ByteData.sublistView(b);
    b[0] = 0x31; // '1'
    b[1] = 0x34; // '4'
    v.setUint64(2, hash, Endian.little);
    v.setUint32(34, crc32, Endian.little);
    b[47] = added ? 1 : 0;
    b[49] = 1;
    return b;
  }

  @override
  String toString() => '$hashType $hash crc32=$crc32';
}
