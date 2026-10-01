// Bech32 (BIP-173) and the NIP-19 keys of NOSTR: npub (public key) and
// nsec (secret key), for the signers of .zx generations. Ported from
// Arca's arca_core (nostr/nip19.dart, the same author, BSD 3-clause).

import 'dart:typed_data';

const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const _gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];

int _polymod(List<int> values) {
  var chk = 1;
  for (final v in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if ((top >> i) & 1 == 1) chk ^= _gen[i];
    }
  }
  return chk;
}

List<int> _hrpExpand(String hrp) => [
      for (final c in hrp.codeUnits) c >> 5,
      0,
      for (final c in hrp.codeUnits) c & 31
    ];

List<int> _convertBits(List<int> data, int from, int to, {required bool pad}) {
  var acc = 0, bits = 0;
  final out = <int>[];
  final maxv = (1 << to) - 1;
  for (final v in data) {
    if (v < 0 || v >> from != 0) throw const FormatException('bad data value');
    acc = (acc << from) | v;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.add((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits > 0) out.add((acc << (to - bits)) & maxv);
  } else if (bits >= from || ((acc << (to - bits)) & maxv) != 0) {
    throw const FormatException('bad padding');
  }
  return out;
}

String bech32Encode(String hrp, List<int> data) {
  final values = _convertBits(data, 8, 5, pad: true);
  final polymod =
      _polymod([..._hrpExpand(hrp), ...values, 0, 0, 0, 0, 0, 0]) ^ 1;
  final checksum = [
    for (var i = 0; i < 6; i++) (polymod >> (5 * (5 - i))) & 31
  ];
  return '${hrp}1${[...values, ...checksum].map((v) => _charset[v]).join()}';
}

/// Decodes a bech32 string into its human-readable part and bytes.
(String, Uint8List) bech32Decode(String input) {
  final s = input.trim();
  if (s.toLowerCase() != s && s.toUpperCase() != s) {
    throw const FormatException('mixed case');
  }
  final lower = s.toLowerCase();
  final pos = lower.lastIndexOf('1');
  if (pos < 1 || pos + 7 > lower.length) {
    throw const FormatException('no separator');
  }
  final hrp = lower.substring(0, pos);
  final values = <int>[];
  for (final ch in lower.substring(pos + 1).split('')) {
    final v = _charset.indexOf(ch);
    if (v < 0) throw FormatException('invalid character $ch');
    values.add(v);
  }
  if (_polymod([..._hrpExpand(hrp), ...values]) != 1) {
    throw const FormatException('bad checksum');
  }
  final data =
      _convertBits(values.sublist(0, values.length - 6), 5, 8, pad: false);
  return (hrp, Uint8List.fromList(data));
}

String npubEncode(List<int> pubkey) => bech32Encode('npub', _check32(pubkey));
String nsecEncode(List<int> secret) => bech32Encode('nsec', _check32(secret));

/// The 32 bytes of an entity with the expected [hrp] (npub, nsec).
Uint8List nip19Decode(String input, String hrp) {
  final (h, data) = bech32Decode(input);
  if (h != hrp) throw FormatException('expected $hrp, got $h');
  return _check32(data);
}

/// A public key from an npub or 64 hex digits.
Uint8List parsePublicKey(String s) {
  final t = s.trim();
  if (t.toLowerCase().startsWith('npub1')) return nip19Decode(t, 'npub');
  return _hex32(t);
}

/// A secret key from an nsec or 64 hex digits.
Uint8List parseSecretKey(String s) {
  final t = s.trim();
  if (t.toLowerCase().startsWith('nsec1')) return nip19Decode(t, 'nsec');
  return _hex32(t);
}

Uint8List _hex32(String t) {
  if (t.length != 64) {
    throw const FormatException('expected an npub/nsec or 64 hex digits');
  }
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    final v = int.tryParse(t.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) throw const FormatException('bad hex digit');
    out[i] = v;
  }
  return out;
}

Uint8List _check32(List<int> b) {
  if (b.length != 32) throw const FormatException('expected 32 bytes');
  return Uint8List.fromList(b);
}
