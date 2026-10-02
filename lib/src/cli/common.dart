// Shared pieces of the console program: the HRESULT values and error
// messages (Windows/ErrorMsg.cpp, C/7zTypes.h for POSIX), the number
// formatting of Common/IntToString.cpp and the exceptions that MainAr.cpp
// catches (CSystemException, CMessagePathException, NExitCode::EEnum,
// UString / AString / const char * throws).

import '../host/io.dart';

import 'platform.dart';

/// HRESULT values used by the UI code (MyWindows.h, 7zTypes.h for POSIX).
abstract final class HRes {
  static const sOk = 0;
  static const sFalse = 1;
  static const eNotImpl = 0x80004001;
  static const eNoInterface = 0x80004002;
  static const eAbort = 0x80004004;
  static const eFail = 0x80004005;
  static const stgEInvalidFunction = 0x80030001;
  static const classEClassNotAvailable = 0x80040111;
  static const eOutOfMemory = 0x8007000E;
  static const eInvalidArg = 0x80070057;
  static const internalError = 0x8007054F;
}

/// The system error codes that the UI code uses by name: errno values on
/// POSIX (Linux numbering, with the macOS values where they differ), and
/// the Win32 error codes (GetLastError) that the _WIN32 build uses in the
/// same places on Windows.
abstract final class Errno {
  static int get eperm => kIsWin ? 5 : 1; // ERROR_ACCESS_DENIED
  static int get enoent => 2; // ERROR_FILE_NOT_FOUND
  static int get eio => kIsWin ? 1117 : 5; // ERROR_IO_DEVICE
  static int get ebadf => kIsWin ? 6 : 9; // ERROR_INVALID_HANDLE
  static int get enomem => kIsWin ? 8 : 12; // ERROR_NOT_ENOUGH_MEMORY
  static int get eacces => kIsWin ? 5 : 13; // ERROR_ACCESS_DENIED
  static int get eexist => kIsWin ? 80 : 17; // ERROR_FILE_EXISTS
  static int get exdev => kIsWin ? 17 : 18; // ERROR_NOT_SAME_DEVICE
  static int get enotdir => kIsWin ? 267 : 20; // ERROR_DIRECTORY
  static int get eisdir => kIsWin ? 5 : 21; // ERROR_ACCESS_DENIED
  // DI_DEFAULT_ERROR (ERROR_INVALID_FUNCTION) and ERROR_INVALID_PARAMETER
  static int get einval => kIsWin ? 1 : 22;
  static int get emfile => kIsWin ? 1450 : 24; // ERROR_NO_SYSTEM_RESOURCES
  static int get enospc => kIsWin ? 112 : 28; // ERROR_DISK_FULL
  static int get erofs => kIsWin ? 19 : 30; // ERROR_WRITE_PROTECT
  static int get enametoolong =>
      kIsWin ? 206 : (kIsMac ? 63 : 36); // ERROR_FILENAME_EXCED_RANGE
  static int get enotempty =>
      kIsWin ? 145 : (kIsMac ? 66 : 39); // ERROR_DIR_NOT_EMPTY
  static int get eloop => kIsWin ? 1921 : (kIsMac ? 62 : 40);
}

// MY_FACILITY_ERRNO
const int _kFacilityErrno = 0x800;

/// HRESULT_FROM_WIN32 (MY_SRes_HRESULT_FROM_WRes) for an errno value
/// (FACILITY_WIN32 for a Win32 error code on Windows).
int hresultFromErrno(int errno) {
  if (errno <= 0) return errno & 0xFFFFFFFF;
  final facility = kIsWin ? 7 : _kFacilityErrno;
  return ((errno & 0xFFFF) | (facility << 16) | 0x80000000) & 0xFFFFFFFF;
}

// FormatMessageW texts (English) of the Win32 error codes and HRESULT values
// the port can meet on Windows, for the codes that dart:io did not report
// with their text.
const Map<int, String> _kWinMessages = {
  1: 'Incorrect function.',
  2: 'The system cannot find the file specified.',
  3: 'The system cannot find the path specified.',
  4: 'The system cannot open the file.',
  5: 'Access is denied.',
  6: 'The handle is invalid.',
  8: 'Not enough memory resources are available to process this command.',
  14: 'Not enough memory resources are available to complete this operation.',
  17: 'The system cannot move the file to a different disk drive.',
  19: 'The media is write protected.',
  32: 'The process cannot access the file because it is being used by '
      'another process.',
  33: 'The process cannot access the file because another process has '
      'locked a portion of the file.',
  80: 'The file exists.',
  87: 'The parameter is incorrect.',
  109: 'The pipe has been ended.',
  112: 'There is not enough space on the disk.',
  123: 'The filename, directory name, or volume label syntax is incorrect.',
  145: 'The directory is not empty.',
  183: 'Cannot create a file when that file already exists.',
  206: 'The filename or extension is too long.',
  267: 'The directory name is invalid.',
  1117: 'The request could not be performed because of an I/O device error.',
  1314: 'A required privilege is not held by the client.',
  1450: 'Insufficient system resources exist to complete the requested '
      'service.',
  1921: 'The name of the file cannot be resolved by the system.',
  0x80004001: 'Not implemented',
  0x80004002: 'No such interface supported',
  0x80004004: 'Operation aborted',
  0x80004005: 'Unspecified error',
  0x80030001: 'Unable to perform requested operation.',
  0x80040111: 'ClassFactory cannot supply requested class',
};

// MyFormatMessage (_WIN32): FormatMessageW of the system.
String? _myFormatMessageWin(int errorCode) {
  var code = errorCode;
  if ((code & 0xFFFF0000) == 0x80070000) code &= 0xFFFF;
  return _seenMessages[code] ?? _kWinMessages[code];
}

// strerror() texts of glibc for the errno values the port can meet.
const Map<int, String> _strerror = {
  1: 'Operation not permitted',
  2: 'No such file or directory',
  3: 'No such process',
  4: 'Interrupted system call',
  5: 'Input/output error',
  6: 'No such device or address',
  7: 'Argument list too long',
  8: 'Exec format error',
  9: 'Bad file descriptor',
  10: 'No child processes',
  11: 'Resource temporarily unavailable',
  12: 'Cannot allocate memory',
  13: 'Permission denied',
  14: 'Bad address',
  15: 'Block device required',
  16: 'Device or resource busy',
  17: 'File exists',
  18: 'Invalid cross-device link',
  19: 'No such device',
  20: 'Not a directory',
  21: 'Is a directory',
  22: 'Invalid argument',
  23: 'Too many open files in system',
  24: 'Too many open files',
  25: 'Inappropriate ioctl for device',
  26: 'Text file busy',
  27: 'File too large',
  28: 'No space left on device',
  29: 'Illegal seek',
  30: 'Read-only file system',
  31: 'Too many links',
  32: 'Broken pipe',
  36: 'File name too long',
  39: 'Directory not empty',
  40: 'Too many levels of symbolic links',
  95: 'Operation not supported',
  122: 'Disk quota exceeded',
};

/// Messages of the OS for errno values seen at run time (dart:io gives
/// the strerror() text with the error code).
final Map<int, String> _seenMessages = {};

/// Records the strerror() text that dart:io reported for [errno].
void noteOsError(OSError? e) {
  if (e == null) return;
  if (e.errorCode > 0 && e.message.isNotEmpty) {
    var m = e.message;
    // MyFormatMessage removes the CR LF at the end of the system text
    if (m.endsWith('\r\n')) m = m.substring(0, m.length - 2);
    _seenMessages[e.errorCode] = m;
  }
}

/// Records the strerror() text of [errno] (from a dart:io error).
void noteErrnoMessage(int errno, String? message) {
  if (errno > 0 && message != null && message.isNotEmpty) {
    _seenMessages[errno] = message;
  }
}

String? _strerrorText(int errno) =>
    _seenMessages[errno] ?? _strerror[errno];

// MyFormatMessage (static part)
String? _myFormatMessage(int errorCode) {
  errorCode &= 0xFFFFFFFF;
  if (errorCode == HRes.internalError) {
    return 'Internal Error: The failure in hardware (RAM or CPU), OS or program';
  }
  if (kIsWin) return _myFormatMessageWin(errorCode);
  String? s;
  switch (errorCode) {
    case HRes.eNotImpl:
      s = 'E_NOTIMPL : Not implemented';
    case HRes.eNoInterface:
      s = 'E_NOINTERFACE : No such interface supported';
    case HRes.eAbort:
      s = 'E_ABORT : Operation aborted';
    case HRes.eFail:
      s = 'E_FAIL : Unspecified error';
    case HRes.stgEInvalidFunction:
      s = 'STG_E_INVALIDFUNCTION';
    case HRes.classEClassNotAvailable:
      s = 'CLASS_E_CLASSNOTAVAILABLE';
    case HRes.eOutOfMemory:
      s = "E_OUTOFMEMORY : Can't allocate required memory";
    case HRes.eInvalidArg:
      s = 'E_INVALIDARG : One or more arguments are invalid';
  }
  if (s != null) return s;
  if ((errorCode & 0xFFFF0000) == ((_kFacilityErrno << 16) | 0x80000000)) {
    errorCode &= 0xFFFF;
  } else if ((errorCode & 0x80000000) != 0) {
    return null;
  }
  final text = _strerrorText(errorCode) ?? 'Unknown error $errorCode';
  return 'errno=$errorCode : $text';
}

/// NError::MyFormatMessage: the text of an HRESULT or errno value.
String myFormatMessage(int errorCode) {
  final m = _myFormatMessage(errorCode);
  if (m == null || m.isEmpty) {
    return 'Error #${hex8Upper(errorCode & 0xFFFFFFFF)}';
  }
  return m;
}

/// CSystemException: an HRESULT failure that ends the command.
class SystemException implements Exception {
  final int errorCode;
  const SystemException(this.errorCode);
  @override
  String toString() => 'SystemException(${myFormatMessage(errorCode)})';
}

/// CMessagePathException (CArcCmdLineException): a command line error.
class MessagePathException implements Exception {
  final String message;
  MessagePathException(String a, [String? u])
      : message = u == null ? a : '$a\n$u';
  @override
  String toString() => message;
}

/// throw "..." / throw UString(...) of the C++ code: printed after
/// "ERROR:" with exit code 2.
class StringException implements Exception {
  final String message;
  const StringException(this.message);
  @override
  String toString() => message;
}

/// throw NExitCode::EEnum.
class ExitCodeException implements Exception {
  final int code;
  const ExitCodeException(this.code);
}

/// NExitCode.
abstract final class ExitCode {
  static const success = 0;
  static const warning = 1;
  static const fatalError = 2;
  static const userError = 7;
  static const memoryError = 8;
  static const userBreak = 255;
}

/// Throws [SystemException] for a failing HRESULT (ThrowException_if_Error,
/// RINOK at the top level).
void throwIfError(int hr) {
  if (hr != HRes.sOk) throw SystemException(hr);
}

/// The HRESULT for a file system exception from dart:io.
int hresultOfFileSystemException(FileSystemException e) {
  final os = e.osError;
  noteOsError(os);
  if (os != null && os.errorCode > 0) return hresultFromErrno(os.errorCode);
  return HRes.eFail;
}

/// The errno of a file system exception (for messages that print errno).
int errnoOf(FileSystemException e, [int? def]) {
  final os = e.osError;
  noteOsError(os);
  if (os != null && os.errorCode > 0) return os.errorCode;
  return def ?? Errno.eio;
}

// ---------------------------------------------------------------------------
// IntToString.cpp

String _hexDigitUpper(int v) =>
    String.fromCharCode(v < 10 ? 0x30 + v : 0x41 + v - 10);

String _hexDigitLower(int v) =>
    String.fromCharCode(v < 10 ? 0x30 + v : 0x61 + v - 10);

/// ConvertUInt32ToHex8Digits (upper case).
String hex8Upper(int v) {
  final sb = StringBuffer();
  for (var i = 7; i >= 0; i--) {
    sb.write(_hexDigitUpper((v >> (i * 4)) & 0xF));
  }
  return sb.toString();
}

/// ConvertUInt64ToHex / ConvertUInt32ToHex (upper case, no leading zeros).
String hexUpper(int v) {
  if (v == 0) return '0';
  final sb = <String>[];
  var x = v;
  var n = 0;
  while ((x != 0) && n < 16) {
    sb.add(_hexDigitUpper(x & 0xF));
    x = (x >> 4) & 0x0FFFFFFFFFFFFFFF;
    n++;
  }
  return sb.reversed.join();
}

/// ConvertDataToHex_Lower.
String dataToHexLower(List<int> data, [int off = 0, int? size]) {
  final end = off + (size ?? data.length - off);
  final sb = StringBuffer();
  for (var i = off; i < end; i++) {
    sb.write(_hexDigitLower(data[i] >> 4));
    sb.write(_hexDigitLower(data[i] & 15));
  }
  return sb.toString();
}

/// ConvertUInt64ToString for the full unsigned 64-bit range.
String u64ToString(int v) {
  if (v >= 0) return '$v';
  // unsigned value above 2^63
  final q = (v >>> 1) ~/ 5;
  final r = v - q * 10;
  return '$q$r';
}

/// Unsigned comparison of two 64-bit values.
int compareU64(int a, int b) {
  final x = a ^ 0x8000000000000000;
  final y = b ^ 0x8000000000000000;
  return x < y ? -1 : (x > y ? 1 : 0);
}

/// CBoolPair.
class BoolPair2 {
  bool val = false;
  bool def = false;
  BoolPair2([this.val = false, this.def = false]);
  void setTrueTrue() {
    val = true;
    def = true;
  }

  BoolPair2 copy() => BoolPair2(val, def);
}

/// FILETIME ticks between 1601-01-01 and 1970-01-01.
const int kFileTimeUnixEpoch = 116444736000000000;

/// Converts a DateTime (microsecond precision) to FILETIME ticks.
int dateTimeToFileTime(DateTime t) =>
    t.toUtc().microsecondsSinceEpoch * 10 + kFileTimeUnixEpoch;

/// Converts FILETIME ticks to a UTC DateTime (the sub-microsecond part is
/// dropped).
DateTime fileTimeToDateTime(int ft) => DateTime.fromMicrosecondsSinceEpoch(
    (ft - kFileTimeUnixEpoch) ~/ 10,
    isUtc: true);
