// Output path correction for extraction: UI/Common/ExtractingFilePath.cpp
// of the LZMA SDK, with its _WIN32 branches (the characters Windows does
// not allow in names, the reserved device names, drive prefixes).

import 'platform.dart';

/// g_PathTrailReplaceMode (true on Windows, false on POSIX; -snt switches
/// it).
bool gPathTrailReplaceMode = kIsWin;

// ReplaceIncorrectChars
String _replaceIncorrectChars(String s) {
  String r;
  if (kIsWin) {
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x5C) {
        // 22.00 : WSL replacement for backslash
        b.writeCharCode(kBackslashReplacement);
      } else if (c == 0x3A || // ':'
          c == 0x2A || // '*'
          c == 0x3F || // '?'
          c < 0x20 ||
          c == 0x3C || // '<'
          c == 0x3E || // '>'
          c == 0x7C || // '|'
          c == 0x22 || // '"'
          c == 0x2F) {
        b.write('_');
      } else {
        b.writeCharCode(c);
      }
    }
    r = b.toString();
  } else {
    r = s.replaceAll('/', '_');
  }
  if (gPathTrailReplaceMode) {
    final chars = r.split('');
    for (var i = chars.length; i != 0;) {
      final c = chars[i - 1];
      if (c != '.' && c != ' ') break;
      i--;
      chars[i] = '_';
    }
    r = chars.join();
  }
  return r;
}

/// Correct_AltStream_Name.
String correctAltStreamName(String s) {
  var len = s.length;
  const kPostfixSize = 6;
  if (s.length >= kPostfixSize &&
      s.substring(s.length - kPostfixSize).toUpperCase() == ':\$DATA') {
    len -= kPostfixSize;
  }
  final chars = s.split('');
  for (var i = 0; i < len; i++) {
    final c = chars[i];
    if (c == ':' || c == '\\' || c == '/' || c == '\u202E') chars[i] = '_';
  }
  final r = chars.join();
  return r.isEmpty ? '_' : r;
}

// g_ReservedNames (Windows)
const List<String> _kReservedNames = ['CON', 'PRN', 'AUX', 'NUL', 'COM', 'LPT'];
const int _kReservedWithNumIndex = 4;

// IsSupportedName (Windows)
bool _isSupportedName(String name) {
  int at(int i) => i < name.length ? name.codeUnitAt(i) : 0;
  for (var i = 0; i < _kReservedNames.length; i++) {
    final reservedName = _kReservedNames[i];
    var len = reservedName.length;
    if (name.length < len) continue;
    if (name.substring(0, len).toUpperCase() != reservedName) continue;
    if (i >= _kReservedWithNumIndex) {
      final c = at(len);
      if (c < 0x30 || c > 0x39) continue;
      len++;
    }
    for (;;) {
      final c = at(len++);
      if (c == 0 || c == 0x2E) return false;
      if (c != 0x20) break;
    }
  }
  return true;
}

// CorrectUnsupportedName (Windows)
String _correctUnsupportedName(String name) =>
    _isSupportedName(name) ? name : '_$name';

// Correct_PathPart
String _correctPathPart(String s) {
  if (s.isEmpty) return s;
  if (s == '.' || s == '..') return '';
  return _replaceIncorrectChars(s);
}

const String _kEmptyReplaceName = '_';

/// Get_Correct_FsFile_Name.
String getCorrectFsFileName(String name) {
  var res = _correctPathPart(name);
  if (kIsWin) res = _correctUnsupportedName(res);
  if (res.isEmpty) res = _kEmptyReplaceName;
  return res;
}

/// Correct_FsPath: changes [parts].
void correctFsPath(bool absIsAllowed, bool keepAndReplaceEmptyPrefixes,
    List<String> parts, bool isDir) {
  var i = 0;
  if (absIsAllowed && parts.isNotEmpty) {
    var isDrive = false;
    if (parts[0].isEmpty) {
      i = 1;
      if (kIsWin && parts.length > 1 && parts[1].isEmpty) {
        i = 2;
        if (parts.length > 2 && parts[2] == '?') {
          i = 3;
          if (parts.length > 3 && isDrivePath2(parts[3])) {
            isDrive = true;
            i = 4;
          }
        }
      }
    } else if (kIsWin && isDrivePath2(parts[0])) {
      isDrive = true;
      i = 1;
    }
    if (isDrive) {
      // we convert "c:name" to "c:\name", if absIsAllowed path.
      final ds = parts[i - 1];
      if (ds.length > 2) {
        parts.insert(i, ds.substring(2));
        parts[i - 1] = ds.substring(0, 2);
      }
    }
  }
  if (i != 0) keepAndReplaceEmptyPrefixes = false;

  while (i < parts.length) {
    final s = _correctPathPart(parts[i]);
    parts[i] = s;
    if (s.isEmpty) {
      if (!keepAndReplaceEmptyPrefixes) {
        if (isDir || i != parts.length - 1) {
          parts.removeAt(i);
          continue;
        }
      }
      parts[i] = _kEmptyReplaceName;
    } else {
      keepAndReplaceEmptyPrefixes = false;
      if (kIsWin) parts[i] = _correctUnsupportedName(s);
    }
    i++;
  }

  if (!isDir) {
    if (parts.isEmpty) {
      parts.add(_kEmptyReplaceName);
    } else if (parts.last.isEmpty) {
      parts[parts.length - 1] = _kEmptyReplaceName;
    }
  }
}

/// MakePathFromParts.
String makePathFromParts(List<String> parts) => parts.join(kDirSep);
