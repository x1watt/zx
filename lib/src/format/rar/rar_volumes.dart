// Names of the volumes of multivolume RAR archives: the new numbering of
// RAR 3.0 and later (name.part1.rar, name.part2.rar...) and the old one
// (name.rar, name.r00, name.r01... name.r99, name.s00...).

/// The name of the volume after [name], or null when [name] does not look
/// like a volume name. [newNumbering] selects name.partN.rar.
String? rarNextVolumeName(String name, bool newNumbering) {
  final dot = name.lastIndexOf('.');
  final slash = name.lastIndexOf(RegExp(r'[/\\]'));
  if (dot <= slash) return null;
  final ext = name.substring(dot + 1);
  final base = name.substring(0, dot);
  if (newNumbering && ext.toLowerCase() == 'rar') {
    // the last group of digits of the base name
    var end = base.length;
    while (end > 0 && !_isDigit(base.codeUnitAt(end - 1))) {
      end--;
    }
    // only a digit group right before ".rar" (name.part01.rar) counts
    if (end != base.length) return null;
    var start = end;
    while (start > 0 && _isDigit(base.codeUnitAt(start - 1))) {
      start--;
    }
    if (start == end) return null;
    return '${base.substring(0, start)}'
        '${_increment(base.substring(start, end))}.$ext';
  }
  if (ext.length == 3) {
    final e = ext.toLowerCase();
    if (e == 'rar') {
      final r = ext[0] == 'R' ? 'R' : 'r';
      return '$base.${r}00';
    }
    final c = e.codeUnitAt(0);
    if (c >= 0x61 &&
        c <= 0x7A &&
        _isDigit(e.codeUnitAt(1)) &&
        _isDigit(e.codeUnitAt(2))) {
      final n = int.parse(e.substring(1));
      if (n < 99) {
        return '$base.${ext[0]}${(n + 1).toString().padLeft(2, '0')}';
      }
      final upper = ext[0] != e[0];
      var next = String.fromCharCode(c + 1);
      if (upper) next = next.toUpperCase();
      return '$base.${next}00';
    }
  }
  return null;
}

/// The name of the first volume for [name] (name.part1.rar for any
/// name.partN.rar, name.rar for name.rNN), or [name] itself.
String rarFirstVolumeName(String name) {
  final m = RegExp(r'^(.*\.part)(\d+)(\.rar)$', caseSensitive: false)
      .firstMatch(name);
  if (m != null) {
    final digits = m.group(2)!;
    return '${m.group(1)}${'1'.padLeft(digits.length, '0')}${m.group(3)}';
  }
  return name;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

String _increment(String digits) {
  final chars = digits.codeUnits.toList();
  var i = chars.length - 1;
  while (i >= 0) {
    if (chars[i] == 0x39) {
      chars[i] = 0x30;
      i--;
      continue;
    }
    chars[i]++;
    return String.fromCharCodes(chars);
  }
  return '1${String.fromCharCodes(chars)}';
}
