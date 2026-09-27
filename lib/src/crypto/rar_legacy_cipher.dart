// The ciphers of RAR 1.5 and RAR 2.0 archives (encrypted files with
// unpack versions 15 to 26; RAR 2.9 and later use AES). An independent
// implementation written from the published descriptions of the two
// ciphers (the rar-research documents: key setup, the substitution table,
// the round function and the key update) and checked black box against
// archives written by RAR 1.55 and WinRAR 2.90 and extracted by unrar. No
// unRAR derived code was read.
//
// RAR 1.5: a byte stream cipher on four 16 bit words, keyed by the CRC-32
// of the password. RAR 2.0: a 32 round Feistel cipher on 16 byte blocks
// with a byte substitution table shuffled by the password; the four round
// keys change after every block with the CRC table entries of the cipher
// text, which chains the blocks.

import 'dart:convert';
import 'dart:typed_data';

// the CRC-32 table (polynomial 0xEDB88320)
final Uint32List _crcTab = () {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var j = 0; j < 8; j++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1;
    }
    t[i] = c;
  }
  return t;
}();

// the characters of bytes 0x80 to 0xFF of code page 437 (the DOS code
// page of RAR 1.5 and of the console RAR 2.x)
const List<int> _cp437High = [
  0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, //
  0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
  0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
  0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
  0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
  0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
  0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
  0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
  0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
  0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
  0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
  0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
  0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
  0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
  0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
  0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
];

/// The password bytes of the RAR 1.5 and 2.0 ciphers. RAR of that time
/// used the bytes of the OEM (DOS) code page: characters of code page 437
/// give its bytes; a password with other characters is taken as UTF-8.
Uint8List rarLegacyPasswordBytes(String password) {
  final units = password.runes.toList();
  final out = Uint8List(units.length);
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c < 0x80) {
      out[i] = c;
      continue;
    }
    final j = _cp437High.indexOf(c);
    if (j < 0) return Uint8List.fromList(utf8.encode(password));
    out[i] = 0x80 + j;
  }
  return out;
}

/// The RAR 1.5 stream cipher.
final class Rar15Cipher {
  int _k0 = 0, _k1 = 0, _k2 = 0, _k3 = 0;

  Rar15Cipher(Uint8List password) {
    var crc = 0xFFFFFFFF;
    for (final b in password) {
      crc = (crc >> 8) ^ _crcTab[(crc ^ b) & 0xFF];
    }
    _k0 = crc & 0xFFFF;
    _k1 = (crc >> 16) & 0xFFFF;
    var k2 = 0, k3 = 0;
    for (final b in password) {
      final c = _crcTab[b];
      k2 = (k2 ^ b ^ c) & 0xFFFF;
      k3 = (k3 + b + (c >> 16)) & 0xFFFF;
    }
    _k2 = k2;
    _k3 = k3;
  }

  /// Decrypts (or encrypts: the cipher is an xor) [len] bytes in place.
  void crypt(Uint8List data, int off, int len) {
    var k0 = _k0, k1 = _k1, k2 = _k2, k3 = _k3;
    final t = _crcTab;
    for (var i = off; i < off + len; i++) {
      k0 = (k0 + 0x1234) & 0xFFFF;
      final c = t[(k0 & 0x1FE) >> 1];
      k1 = (k1 ^ c) & 0xFFFF;
      k2 = (k2 - (c >> 16)) & 0xFFFF;
      k0 ^= k2;
      k3 = (((k3 >> 1) | (k3 << 15)) & 0xFFFF) ^ k1;
      k3 = ((k3 >> 1) | (k3 << 15)) & 0xFFFF;
      k0 ^= k3;
      data[i] ^= k0 >> 8;
    }
    _k0 = k0;
    _k1 = k1;
    _k2 = k2;
    _k3 = k3;
  }
}

// the initial substitution table of RAR 2.0
const List<int> _subst20 = [
  215, 19, 149, 35, 73, 197, 192, 205, 249, 28, 16, 119, 48, 221, 2, 42, //
  232, 1, 177, 233, 14, 88, 219, 25, 223, 195, 244, 90, 87, 239, 153, 137,
  255, 199, 147, 70, 92, 66, 246, 13, 216, 40, 62, 29, 217, 230, 86, 6,
  71, 24, 171, 196, 101, 113, 218, 123, 93, 91, 163, 178, 202, 67, 44, 235,
  107, 250, 75, 234, 49, 167, 125, 211, 83, 114, 157, 144, 32, 193, 143, 36,
  158, 124, 247, 187, 89, 214, 141, 47, 121, 228, 61, 130, 213, 194, 174, 251,
  97, 110, 54, 229, 115, 57, 152, 94, 105, 243, 212, 55, 209, 245, 63, 11,
  164, 200, 31, 156, 81, 176, 227, 21, 76, 99, 139, 188, 127, 17, 248, 51,
  207, 120, 189, 210, 8, 226, 41, 72, 183, 203, 135, 165, 166, 60, 98, 7,
  122, 38, 155, 170, 69, 172, 252, 238, 39, 134, 59, 128, 236, 27, 240, 80,
  131, 3, 85, 206, 145, 79, 154, 142, 159, 220, 201, 133, 74, 64, 20, 129,
  224, 185, 138, 103, 173, 182, 43, 34, 254, 82, 198, 151, 231, 180, 58, 10,
  118, 26, 102, 12, 50, 132, 22, 191, 136, 111, 162, 179, 45, 4, 148, 108,
  161, 56, 78, 126, 242, 222, 15, 175, 146, 23, 33, 241, 181, 190, 77, 225,
  0, 46, 169, 186, 68, 95, 237, 65, 53, 208, 253, 168, 9, 18, 100, 52,
  116, 184, 160, 96, 109, 37, 30, 106, 140, 104, 150, 5, 204, 117, 112, 84,
];

/// The RAR 2.0 block cipher (16 byte blocks, chained by the key update).
final class Rar20Cipher {
  final Uint8List _s = Uint8List.fromList(_subst20);
  final Uint32List _key =
      Uint32List.fromList([0xD3A3B879, 0x3F6D12F7, 0x7515A235, 0xA4E7F123]);
  final Uint8List _block = Uint8List(16);

  Rar20Cipher(Uint8List password) {
    final n = password.length;
    // the password with a zero after it (an odd length pairs its last
    // byte with that zero), padded to whole blocks
    final p = Uint8List(((n >> 4) + 1) << 4);
    p.setRange(0, n, password);
    final s = _s;
    final t = _crcTab;
    for (var j = 0; j < 256; j++) {
      for (var i = 0; i < n; i += 2) {
        var n1 = t[(p[i] - j) & 0xFF] & 0xFF;
        final n2 = t[(p[i + 1] + j) & 0xFF] & 0xFF;
        for (var k = 1; n1 != n2; k++) {
          final a = (n1 + i + k) & 0xFF;
          final x = s[n1];
          s[n1] = s[a];
          s[a] = x;
          n1 = (n1 + 1) & 0xFF;
        }
      }
    }
    // the password blocks go through the cipher to mix the keys
    for (var i = 0; i < n; i += 16) {
      _encryptBlock(p, i);
    }
  }

  @pragma('vm:prefer-inline')
  int _substLong(int v) {
    final s = _s;
    return s[v & 0xFF] |
        (s[(v >> 8) & 0xFF] << 8) |
        (s[(v >> 16) & 0xFF] << 16) |
        (s[(v >> 24) & 0xFF] << 24);
  }

  @pragma('vm:prefer-inline')
  static int _rotl(int v, int n) => ((v << n) | (v >> (32 - n))) & 0xFFFFFFFF;

  static int _u32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  static void _put32(Uint8List b, int o, int v) {
    b[o] = v & 0xFF;
    b[o + 1] = (v >> 8) & 0xFF;
    b[o + 2] = (v >> 16) & 0xFF;
    b[o + 3] = (v >> 24) & 0xFF;
  }

  // the key update with the cipher text of a block
  void _updateKeys(Uint8List b, int o) {
    final k = _key;
    final t = _crcTab;
    for (var i = 0; i < 16; i += 4) {
      k[0] ^= t[b[o + i]];
      k[1] ^= t[b[o + i + 1]];
      k[2] ^= t[b[o + i + 2]];
      k[3] ^= t[b[o + i + 3]];
    }
  }

  // [decrypt]: the rounds in reverse order
  void _rounds(Uint8List b, int o, bool decrypt) {
    final k = _key;
    var a = _u32(b, o) ^ k[0];
    var bb = _u32(b, o + 4) ^ k[1];
    var c = _u32(b, o + 8) ^ k[2];
    var d = _u32(b, o + 12) ^ k[3];
    for (var r = 0; r < 32; r++) {
      final key = k[(decrypt ? 31 - r : r) & 3];
      final t1 = ((c + _rotl(d, 11)) & 0xFFFFFFFF) ^ key;
      final ta = a ^ _substLong(t1);
      final t2 = ((d ^ _rotl(c, 17)) + key) & 0xFFFFFFFF;
      final tb = bb ^ _substLong(t2);
      a = c;
      bb = d;
      c = ta;
      d = tb;
    }
    _put32(b, o, c ^ k[0]);
    _put32(b, o + 4, d ^ k[1]);
    _put32(b, o + 8, a ^ k[2]);
    _put32(b, o + 12, bb ^ k[3]);
  }

  void _encryptBlock(Uint8List b, int o) {
    _rounds(b, o, false);
    _updateKeys(b, o);
  }

  /// Decrypts the 16 byte block at [o] in place.
  void decryptBlock(Uint8List b, int o) {
    final save = _block;
    save.setRange(0, 16, b, o);
    _rounds(b, o, true);
    _updateKeys(save, 0);
  }

  /// Encrypts the 16 byte block at [o] in place.
  void encryptBlock(Uint8List b, int o) => _encryptBlock(b, o);
}
