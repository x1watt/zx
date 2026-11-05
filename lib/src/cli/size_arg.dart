// A size argument of the zx commands: digits and an optional k, m or g
// (powers of 1024). Used by `zx parts` and `zx mount`.

/// "95m" to 99614720; null when [s] is not a size.
int? parseSizeArg(String s) {
  final m = RegExp(r'^(\d+)([kmgKMG]?)$').firstMatch(s);
  if (m == null) return null;
  final n = int.parse(m[1]!);
  return switch (m[2]!.toLowerCase()) {
    'k' => n << 10,
    'm' => n << 20,
    'g' => n << 30,
    _ => n,
  };
}
