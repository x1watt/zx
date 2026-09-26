// The platform switches of the console program: the "#ifdef _WIN32" choices
// of Common/MyString.h (WCHAR_PATH_SEPARATOR, IS_PATH_SEPAR,
// WCHAR_IN_FILE_NAME_BACKSLASH_REPLACEMENT), Archive/Common/ItemNameUtils.cpp
// (ReplaceToWinSlashes) and the path functions of Windows/FileName.cpp
// (IsDrivePath, IsSuperPath, GetRootPrefixSize, ResolveDotsFolders,
// GetFullPath) that the Windows build uses.
//
// The port keeps one code path for every platform: [kIsWin] selects the
// Windows branches at run time where the SDK selects them at compile time.

import 'dart:convert';
import 'dart:io';

/// _WIN32 of the SDK build.
final bool kIsWin = Platform.isWindows;

/// __APPLE__ of the SDK build (macOS: POSIX with BSD tools).
final bool kIsMac = Platform.isMacOS;

/// WCHAR_PATH_SEPARATOR ('\' on Windows, '/' elsewhere).
final String kDirSep = kIsWin ? '\\' : '/';

/// WCHAR_PATH_SEPARATOR as a code unit.
final int kDirSepCode = kIsWin ? 0x5C : 0x2F;

/// WCHAR_IN_FILE_NAME_BACKSLASH_REPLACEMENT (WSL scheme, Windows only).
const int kBackslashReplacement = 0xF05C;

/// IS_PATH_SEPAR / IsPathSepar: both '\' and '/' on Windows.
bool isPathSepar(int c) => c == 0x2F || (kIsWin && c == 0x5C);

/// IsPathSepar for the last character of [s].
bool endsWithPathSepar(String s) =>
    s.isNotEmpty && isPathSepar(s.codeUnitAt(s.length - 1));

/// UString::ReverseFind_PathSepar.
int reverseFindPathSepar(String s) {
  for (var i = s.length - 1; i >= 0; i--) {
    if (isPathSepar(s.codeUnitAt(i))) return i;
  }
  return -1;
}

/// NName::NormalizeDirPathPrefix: adds the separator at the end.
String normalizeDirPathPrefix(String dirPath) {
  if (dirPath.isEmpty || endsWithPathSepar(dirPath)) return dirPath;
  return dirPath + kDirSep;
}

/// NName::NormalizeDirSeparators (Windows): '/' to '\'.
String normalizeDirSeparators(String s) =>
    kIsWin ? s.replaceAll('/', '\\') : s;

/// ReplaceToWinSlashes (ItemNameUtils.cpp): the item path of an archive as
/// the Windows build sees it: '/' becomes '\' and a '\' that is part of a
/// name becomes WCHAR_IN_FILE_NAME_BACKSLASH_REPLACEMENT. Unchanged on
/// other platforms.
String replaceToWinSlashes(String name, [bool useBackslashReplacement = true]) {
  if (!kIsWin) return name;
  if (!name.contains('/') && !name.contains('\\')) return name;
  final r = StringBuffer();
  for (var i = 0; i < name.length; i++) {
    final c = name.codeUnitAt(i);
    if (c == 0x2F) {
      r.writeCharCode(0x5C);
    } else if (useBackslashReplacement && c == 0x5C) {
      r.writeCharCode(kBackslashReplacement);
    } else {
      r.writeCharCode(c);
    }
  }
  return r.toString();
}

/// The text encoding for a code page number of the -scc and -scs
/// switches: UTF-8 for CP_UTF8; on Windows the ANSI code page of the system
/// (dart:io systemEncoding) for CP_ACP and CP_OEMCP, the only single byte
/// code page that dart:io can convert; Latin-1 otherwise (the bytes as
/// they are).
Encoding codePageEncoding(int codePage) {
  if (codePage == 65001) return utf8;
  if (kIsWin && (codePage == 0 || codePage == 1)) return systemEncoding;
  return latin1;
}

/// ReplaceSlashes_OsToUnix (ItemNameUtils.cpp).
String replaceSlashesOsToUnix(String name) =>
    kIsWin ? name.replaceAll('\\', '/') : name;

// ---------------------------------------------------------------------------
// Windows/FileName.cpp (the _WIN32 path forms)

int _at(String s, int i) => i < s.length ? s.codeUnitAt(i) : 0;

bool _isLetterChar(int c) => ((c | 0x20) - 0x61) >= 0 && ((c | 0x20) - 0x61) <= 25;

/// IsDrivePath2: "c:".
bool isDrivePath2(String s, [int pos = 0]) =>
    _isLetterChar(_at(s, pos)) && _at(s, pos + 1) == 0x3A;

/// IsDrivePath: "c:\".
bool isDrivePath(String s, [int pos = 0]) =>
    isDrivePath2(s, pos) && isPathSepar(_at(s, pos + 2));

/// kSuperPathPrefixSize ("\\?\").
const int kSuperPathPrefixSize = 4;

/// kSuperUncPathPrefixSize ("\\?\UNC\").
const int kSuperUncPathPrefixSize = 8;

/// kDevicePathPrefixSize ("\\.\").
const int kDevicePathPrefixSize = 4;

/// IS_SUPER_PREFIX / IsSuperPath.
bool isSuperPath(String s, [int pos = 0]) =>
    isPathSepar(_at(s, pos)) &&
    isPathSepar(_at(s, pos + 1)) &&
    _at(s, pos + 2) == 0x3F &&
    isPathSepar(_at(s, pos + 3));

/// IS_DEVICE_PATH.
bool _isDevicePathPrefix(String s) =>
    isPathSepar(_at(s, 0)) &&
    isPathSepar(_at(s, 1)) &&
    _at(s, 2) == 0x2E &&
    isPathSepar(_at(s, 3));

/// IsSuperOrDevicePath.
bool isSuperOrDevicePath(String s) =>
    isPathSepar(_at(s, 0)) &&
    isPathSepar(_at(s, 1)) &&
    (_at(s, 2) == 0x3F || _at(s, 2) == 0x2E) &&
    isPathSepar(_at(s, 3));

// IS_UNC_WITH_SLASH
bool _isUncWithSlash(String s, int pos) =>
    (_at(s, pos) | 0x20) == 0x75 &&
    (_at(s, pos + 1) | 0x20) == 0x6E &&
    (_at(s, pos + 2) | 0x20) == 0x63 &&
    isPathSepar(_at(s, pos + 3));

/// IsDevicePath: "\\.\c:" and "\\.\PhysicalDriveN".
bool isDevicePath(String s) {
  if (!_isDevicePathPrefix(s)) return false;
  final len = s.length;
  if (len == 6 && s.codeUnitAt(5) == 0x3A) return true;
  if (len < 18 || len > 22 || !s.startsWith('PhysicalDrive', 4)) return false;
  for (var i = 17; i < len; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}

/// IsAbsolutePath.
bool isAbsolutePath(String s) {
  if (s.isEmpty) return false;
  if (isPathSepar(s.codeUnitAt(0))) return true;
  return kIsWin && isDrivePath2(s);
}

// FindSepar
int _findSepar(String s, int pos) {
  for (var i = pos; i < s.length; i++) {
    if (isPathSepar(s.codeUnitAt(i))) return i - pos;
  }
  return -1;
}

// GetRootPrefixSize_Of_NetworkPath
int _rootPrefixSizeOfNetworkPath(String s, int pos) {
  final p1 = _findSepar(s, pos);
  if (p1 < 0) return 0;
  final p2 = _findSepar(s, pos + p1 + 1);
  if (p2 < 0) return 0;
  return p1 + p2 + 2;
}

// GetRootPrefixSize_Of_SimplePath
int _rootPrefixSizeOfSimplePath(String s, int pos) {
  if (isDrivePath(s, pos)) return 3;
  if (!isPathSepar(_at(s, pos))) return 0;
  if (_at(s, pos + 1) == 0 || !isPathSepar(_at(s, pos + 1))) return 1;
  final size = _rootPrefixSizeOfNetworkPath(s, pos + 2);
  return size == 0 ? 0 : 2 + size;
}

// GetRootPrefixSize_Of_SuperPath
int _rootPrefixSizeOfSuperPath(String s) {
  if (_isUncWithSlash(s, kSuperPathPrefixSize)) {
    final size = _rootPrefixSizeOfNetworkPath(s, kSuperUncPathPrefixSize);
    return size == 0 ? 0 : kSuperUncPathPrefixSize + size;
  }
  final pos = _findSepar(s, kSuperPathPrefixSize);
  if (pos < 0) return 0;
  return kSuperPathPrefixSize + pos + 1;
}

/// GetRootPrefixSize (the POSIX form is 1 for a leading '/').
int getRootPrefixSize(String s) {
  if (!kIsWin) return s.isNotEmpty && s.codeUnitAt(0) == 0x2F ? 1 : 0;
  if (_isDevicePathPrefix(s)) return kDevicePathPrefixSize;
  if (isSuperPath(s)) return _rootPrefixSizeOfSuperPath(s);
  return _rootPrefixSizeOfSimplePath(s, 0);
}

/// ResolveDotsFolders: null for false.
String? resolveDotsFolders(String s0) {
  final s = s0.codeUnits.toList();
  int at(int i) => i < s.length ? s[i] : 0;
  for (var i = 0;;) {
    final c = at(i);
    if (c == 0) return String.fromCharCodes(s);
    if (c == 0x2E && (i == 0 || isPathSepar(at(i - 1)))) {
      final c1 = at(i + 1);
      if (c1 == 0x2E) {
        final c2 = at(i + 2);
        if (isPathSepar(c2) || c2 == 0) {
          if (i == 0) return null;
          var k = i - 2;
          i += 2;
          for (;; k--) {
            if (k < 0) return null;
            if (!isPathSepar(s[k])) break;
          }
          do {
            k--;
          } while (k >= 0 && !isPathSepar(s[k]));
          int num;
          if (k >= 0) {
            num = i - k;
            i = k;
          } else {
            num = c2 == 0 ? i : i + 1;
            i = 0;
          }
          s.removeRange(i, i + num > s.length ? s.length : i + num);
          continue;
        }
      } else if (isPathSepar(c1) || c1 == 0) {
        var num = 2;
        if (i != 0) {
          i--;
        } else if (c1 == 0) {
          num = 1;
        }
        s.removeRange(i, i + num > s.length ? s.length : i + num);
        continue;
      }
    }
    i++;
  }
}

// AreThereDotsFolders
bool _areThereDotsFolders(String s, int pos) {
  for (var i = pos; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x2E && (i == pos || isPathSepar(s.codeUnitAt(i - 1)))) {
      final c1 = _at(s, i + 1);
      if (c1 == 0 ||
          isPathSepar(c1) ||
          (c1 == 0x2E && (_at(s, i + 2) == 0 || isPathSepar(_at(s, i + 2))))) {
        return true;
      }
    }
  }
  return false;
}

/// GetFullPath (FileName.cpp, _WIN32 form) with [curDir] as the current
/// directory. "c:name" (a path relative to the current directory of
/// another drive) is resolved against the root of that drive, since a
/// process has one current directory only. Null when it fails.
String? getFullPathWin(String s, String curDir) {
  final prefixSize = getRootPrefixSize(s);
  if (prefixSize != 0 && prefixSize != 1) {
    if (!_areThereDotsFolders(s, prefixSize)) return s;
    final rem = resolveDotsFolders(s.substring(prefixSize));
    if (rem == null) return s;
    return s.substring(0, prefixSize) + rem;
  }
  if (prefixSize == 0 && isDrivePath2(s)) {
    // GetFullPathNameW: "c:name" of another drive
    final drive = s.substring(0, 2);
    if (!(curDir.length >= 2 &&
        curDir.substring(0, 2).toUpperCase() == drive.toUpperCase())) {
      return getFullPathWin('$drive\\${s.substring(2)}', curDir);
    }
    s = s.substring(2);
  }
  var cur = normalizeDirPathPrefix(curDir);
  var fixedSize = getRootPrefixSize(cur);
  var temp = '';
  var rel = s;
  if (prefixSize != 0) {
    rel = s.substring(prefixSize);
    if (fixedSize == 0) {
      cur = kDirSep;
      fixedSize = 1;
    }
  } else {
    temp = cur.substring(fixedSize);
  }
  final t = resolveDotsFolders(temp + rel);
  if (t == null) return null;
  return cur.substring(0, fixedSize) + t;
}
