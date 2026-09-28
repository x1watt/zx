// Scalar SQL functions of the system layer (docs/zxdb-design.md 5):
//
//   sha256(blob|text)       32 byte BLOB (text is hashed as UTF-8)
//   tlsh(blob|text)         the TLSH digest text ('T1' + 70 hex digits), or
//                           NULL for input under 50 bytes or too uniform
//   tlsh_distance(a, b)     INTEGER distance of two digests, NULL when one
//                           does not parse
//
// Until the SQL engine's function registry exists they are described by
// [SysFunction]; lib/src/db/system/register.dart adapts them.

import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/sha256.dart';
import '../../util/tlsh.dart';

typedef SysScalarFn = Object? Function(List<Object?> args);

class SysFunction {
  final String name;
  final int minArgs;
  final int maxArgs;

  /// Same arguments give the same result (the planner may fold it).
  final bool deterministic;
  final SysScalarFn fn;
  const SysFunction(this.name, this.minArgs, this.maxArgs, this.fn,
      {this.deterministic = true});
}

Uint8List? _bytesOf(Object? v) {
  if (v is Uint8List) return v;
  if (v is String) return Uint8List.fromList(utf8.encode(v));
  if (v is int || v is double) {
    return Uint8List.fromList(utf8.encode(v.toString()));
  }
  return null;
}

Object? sqlSha256(List<Object?> a) {
  final b = _bytesOf(a[0]);
  return b == null ? null : Sha256.hash(b);
}

Object? sqlTlsh(List<Object?> a) {
  final b = _bytesOf(a[0]);
  return b == null ? null : Tlsh.of(b);
}

Object? sqlTlshDistance(List<Object?> a) {
  final x = a[0], y = a[1];
  if (x is! String || y is! String) return null;
  return tlshDistance(x, y);
}

/// The system scalar functions.
const List<SysFunction> zxSystemFunctions = [
  SysFunction('sha256', 1, 1, sqlSha256),
  SysFunction('tlsh', 1, 1, sqlTlsh),
  SysFunction('tlsh_distance', 2, 2, sqlTlshDistance),
];
