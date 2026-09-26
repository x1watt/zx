// Output path correction for extraction: UI/Common/ExtractingFilePath.cpp
// of the LZMA SDK (POSIX build).

/// g_PathTrailReplaceMode (false on POSIX; -snt switches it).
bool gPathTrailReplaceMode = false;

// ReplaceIncorrectChars
String _replaceIncorrectChars(String s) {
  var r = s.replaceAll('/', '_');
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
  if (res.isEmpty) res = _kEmptyReplaceName;
  return res;
}

/// Correct_FsPath: changes [parts].
void correctFsPath(bool absIsAllowed, bool keepAndReplaceEmptyPrefixes,
    List<String> parts, bool isDir) {
  var i = 0;
  if (absIsAllowed) {
    if (parts.isNotEmpty && parts[0].isEmpty) i = 1;
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
String makePathFromParts(List<String> parts) => parts.join('/');
