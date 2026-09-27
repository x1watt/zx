// File system helpers: Windows/FileFind.cpp (CFileInfo from stat / lstat,
// Get_WinAttribPosix_From_PosixMode; FindFirstFile attributes on Windows),
// Windows/FileDir.cpp (CreateComplexDir, SetFileAttrib_PosixHighDetect with
// the umask, SetDirTime, MyMoveFile, DeleteFileAlways) and
// Common/FilePathAutoRename.cpp, over dart:io.
//
// dart:io has no chmod, lstat or directory timestamp call. On Linux and
// macOS the port runs the system "chmod" and "touch" programs for those
// (batched), and "stat" for the own timestamps of symbolic links, with the
// GNU syntax on Linux and the BSD syntax on macOS. On Windows no program
// is run for times: dart:io sets the times of files, the times of
// directories are set only where dart:io can (see [setDirOrLinkMTime]).
// The read-only, hidden and system attributes are set with "attrib", the
// only way without FFI. A missing program is reported like a failed
// attribute call of 7-Zip, it never stops the operation.

import 'dart:convert';
import 'dart:io';

import '../format/archive_types.dart' show FileAttrib;
import 'common.dart';
import 'open_archive.dart' show FiTime, cliCurrentDirectory;
import 'platform.dart';

const int sIFMT = 0xF000;
const int sIFDIR = 0x4000;
const int sIFREG = 0x8000;
const int sIFLNK = 0xA000;
const int sIFBLK = 0x6000;
const int sIFCHR = 0x2000;

bool sIsDir(int mode) => (mode & sIFMT) == sIFDIR;
bool sIsReg(int mode) => (mode & sIFMT) == sIFREG;
bool sIsLnk(int mode) => (mode & sIFMT) == sIFLNK;

/// Resolves [path] against the working directory of the run.
String resolvePath(String path) {
  final cwd = cliCurrentDirectory;
  if (cwd == null || isAbsolutePath(path)) return path;
  if (path.isEmpty) return cwd;
  return '$cwd$kDirSep$path';
}

/// NFind::CFileInfo.
class FileInfo {
  String name = '';
  int size = 0;
  int mode = 0;

  /// The FILE_ATTRIBUTE_* value of Windows (FindFirstFile). POSIX derives
  /// it from [mode].
  int attrib = 0;
  FiTime cTime = const FiTime(0);
  FiTime aTime = const FiTime(0);
  FiTime mTime = const FiTime(0);

  /// The target of a symbolic link found with followLink = false.
  String? linkTarget;

  bool get isDir => sIsDir(mode);
  bool get isPosixLink => sIsLnk(mode);

  /// HasReparsePoint (Windows).
  bool get hasReparsePoint => (attrib & FileAttrib.reparsePoint) != 0;

  /// IsOsSymLink: HasReparsePoint on Windows, IsPosixLink on POSIX.
  bool get isOsSymLink => kIsWin ? hasReparsePoint : isPosixLink;

  /// IsReadOnly: FILE_ATTRIBUTE_READONLY, or (mode & 0222) == 0 on POSIX.
  bool get isReadOnly =>
      kIsWin ? (attrib & FileAttrib.readOnly) != 0 : (mode & 0x92) == 0;

  /// GetWinAttrib: the attributes on Windows,
  /// Get_WinAttribPosix_From_PosixMode on POSIX.
  int getWinAttrib() => kIsWin ? attrib : winAttribFromPosixMode(mode);

  FileInfo copy() => FileInfo()
    ..name = name
    ..size = size
    ..mode = mode
    ..attrib = attrib
    ..cTime = cTime
    ..aTime = aTime
    ..mTime = mTime
    ..linkTarget = linkTarget;
}

/// Get_WinAttribPosix_From_PosixMode.
int winAttribFromPosixMode(int mode) {
  var attrib = sIsDir(mode) ? 0x10 : 0x20;
  if ((mode & 0x92) == 0) attrib |= 0x1;
  return (attrib | 0x8000 | ((mode & 0xFFFF) << 16)) & 0xFFFFFFFF;
}

/// The errno of the last failing [findFile].
int lastFindErrno = 0;

// Get_Name_from_Path
String _nameFromPath(String path) {
  if (path.isEmpty) return path;
  var p = path.length - 1;
  if (p == 0) return path;
  p--;
  for (;;) {
    if (isPathSepar(path.codeUnitAt(p))) return path.substring(p + 1);
    if (p == 0) return path;
    p--;
  }
}

// The file information of Windows (FindFirstFile): the attributes, the
// creation time (FileStat.changed is the creation time on Windows), the
// times of the target for a link (dart:io has no lstat).
FileInfo? _findFileWin(String path, String real, FileSystemEntityType type,
    bool followLink, bool exactName) {
  final isLink = type == FileSystemEntityType.link;
  final st = FileStat.statSync(real);
  final fi = FileInfo();
  var isDir = st.type == FileSystemEntityType.directory;
  if (st.type == FileSystemEntityType.notFound) {
    if (!isLink || followLink) {
      lastFindErrno = Errno.enoent;
      return null;
    }
    // a dangling link: its own entry
    isDir = false;
  }
  if (isLink && !followLink) {
    try {
      fi.linkTarget = Link(real).targetSync();
    } on FileSystemException {
      fi.linkTarget = null;
    }
  }
  final readOnly = st.type != FileSystemEntityType.notFound &&
      (st.mode & 0x92) == 0;
  var attrib = isDir ? FileAttrib.directory : FileAttrib.archive;
  if (readOnly) attrib |= FileAttrib.readOnly;
  if (isLink && !followLink) attrib |= FileAttrib.reparsePoint;
  fi.attrib = attrib;
  fi.mode = isDir
      ? sIFDIR | 0x1FF
      : sIFREG | (readOnly ? 0x124 : 0x1B6); // 0444 or 0666
  fi.size = isDir || (isLink && !followLink) || st.size < 0 ? 0 : st.size;
  final now = FiTime.fromDateTime(DateTime.now());
  final ok = st.type != FileSystemEntityType.notFound;
  fi.mTime = ok ? FiTime.fromDateTime(st.modified) : now;
  fi.aTime = ok ? FiTime.fromDateTime(st.accessed) : now;
  fi.cTime = ok ? FiTime.fromDateTime(st.changed) : now;
  var name = _nameFromPath(path);
  while (name.length > 1 && endsWithPathSepar(name)) {
    name = name.substring(0, name.length - 1);
  }
  if (exactName) name = _exactNameWin(real, name);
  fi.name = name;
  return fi;
}

// CFileInfo::Find (_WIN32) for "c:\\" and "\\": FindFirstFile does not
// work for a root folder, the SDK uses GetFileAttributes.
FileInfo? _findRootWin(String path, String real) {
  final rootSize = isSuperPath(path) ? kSuperPathPrefixSize : 0;
  final String name;
  if (isDrivePath(path, rootSize) && path.length == rootSize + 3) {
    name = path.substring(rootSize, rootSize + 2);
  } else if (path.length == 1 && isPathSepar(path.codeUnitAt(0))) {
    name = '';
  } else {
    return null;
  }
  if (!Directory(real).existsSync()) return null;
  final fi = FileInfo()
    ..name = name
    ..mode = sIFDIR | 0x1FF
    ..attrib = FileAttrib.directory;
  final st = FileStat.statSync(real);
  if (st.type != FileSystemEntityType.notFound) {
    fi.mTime = FiTime.fromDateTime(st.modified);
    fi.aTime = FiTime.fromDateTime(st.accessed);
    fi.cTime = FiTime.fromDateTime(st.changed);
  }
  return fi;
}

// FindFirstFile returns the name as it is stored in the directory (the
// case can differ from the requested name).
String _exactNameWin(String real, String name) {
  if (name.isEmpty || name.contains('*') || name.contains('?')) return name;
  var r = real;
  while (r.length > 1 && endsWithPathSepar(r)) {
    r = r.substring(0, r.length - 1);
  }
  final sep = reverseFindPathSepar(r);
  final dir = sep < 0 ? '.' : r.substring(0, sep + 1);
  if (sep < 0 && isDrivePath2(r)) return name;
  try {
    final upper = name.toUpperCase();
    for (final e in Directory(dir).listSync(followLinks: false)) {
      final p = e.path;
      final n = p.substring(reverseFindPathSepar(p) + 1);
      if (n == name) return name;
      if (n.toUpperCase() == upper) return n;
    }
  } on FileSystemException {
    // keep the requested name
  }
  return name;
}

/// CFileInfo::Find (followLink = false uses lstat semantics). With
/// [exactName] the Windows build returns the name as the directory stores
/// it.
FileInfo? findFile(String path,
    {bool followLink = false, bool exactName = false}) {
  lastFindErrno = 0;
  final real = resolvePath(path);
  try {
    final type = FileSystemEntity.typeSync(real, followLinks: false);
    if (kIsWin) {
      final root = _findRootWin(path, real);
      if (root != null) return root;
    }
    if (type == FileSystemEntityType.notFound) {
      lastFindErrno = Errno.enoent;
      return null;
    }
    if (kIsWin) return _findFileWin(path, real, type, followLink, exactName);
    final fi = FileInfo();
    if (type == FileSystemEntityType.link && !followLink) {
      final target = Link(real).targetSync();
      fi.linkTarget = target;
      fi.mode = sIFLNK | 0x1FF;
      fi.size = utf8.encode(target).length;
      final t = lstatTimes([real])[real];
      final now = FiTime.fromDateTime(DateTime.now());
      fi.mTime = t?.$1 ?? now;
      fi.aTime = t?.$2 ?? now;
      fi.cTime = t?.$3 ?? now;
    } else {
      final st = FileStat.statSync(real);
      if (st.type == FileSystemEntityType.notFound) {
        // a dangling link with followLink
        lastFindErrno = Errno.enoent;
        return null;
      }
      fi.mode = st.mode;
      fi.size = st.type == FileSystemEntityType.directory ? 0 : st.size;
      fi.mTime = FiTime.fromDateTime(st.modified);
      fi.aTime = FiTime.fromDateTime(st.accessed);
      fi.cTime = FiTime.fromDateTime(st.changed);
    }
    fi.attrib = winAttribFromPosixMode(fi.mode);
    var name = _nameFromPath(path);
    if (name.isNotEmpty && name.endsWith('/')) {
      name = name.substring(0, name.length - 1);
    }
    fi.name = name;
    return fi;
  } on FileSystemException catch (e) {
    lastFindErrno = errnoOf(e, Errno.enoent);
    return null;
  }
}

/// CFileInfo::Find_FollowLink.
FileInfo? findFileFollowLink(String path) => findFile(path, followLink: true);

/// DoesFileOrDirExist (lstat).
bool doesFileOrDirExist(String path) =>
    FileSystemEntity.typeSync(resolvePath(path), followLinks: false) !=
    FileSystemEntityType.notFound;

/// DoesDirExist.
bool doesDirExist(String path, {bool followLink = true}) =>
    FileSystemEntity.typeSync(resolvePath(path), followLinks: followLink) ==
    FileSystemEntityType.directory;

/// DoesFileExist_Raw (lstat, not a dir).
bool doesFileExistRaw(String path) {
  final t = FileSystemEntity.typeSync(resolvePath(path), followLinks: false);
  return t != FileSystemEntityType.notFound &&
      t != FileSystemEntityType.directory;
}

/// DoesFileExist_FollowLink.
bool doesFileExistFollowLink(String path) {
  final t = FileSystemEntity.typeSync(resolvePath(path), followLinks: true);
  return t != FileSystemEntityType.notFound &&
      t != FileSystemEntityType.directory;
}

/// A directory entry with its info (CEnumerator + Fill_FileInfo).
class DirEntryInfo {
  final String name;
  final FileInfo? info;
  final int errno;
  DirEntryInfo(this.name, this.info, this.errno);
}

/// Enumerates a directory (readdir order). Returns null and sets
/// [lastFindErrno] when the directory can not be read.
List<DirEntryInfo>? enumerateDir(String dirPrefix, bool followLink) {
  lastFindErrno = 0;
  final dir = dirPrefix.isEmpty ? './' : dirPrefix;
  List<FileSystemEntity> list;
  try {
    list = Directory(resolvePath(dir)).listSync(followLinks: false);
  } on FileSystemException catch (e) {
    lastFindErrno = errnoOf(e);
    return null;
  }
  final r = <DirEntryInfo>[];
  final linkPaths = <String>[];
  for (final e in list) {
    final name = e.path.substring(reverseFindPathSepar(e.path) + 1);
    if (e is Link && !followLink) linkPaths.add(resolvePath(dirPrefix + name));
    r.add(DirEntryInfo(name, null, 0));
  }
  if (linkPaths.isNotEmpty && !kIsWin) _prefetchLstat(linkPaths);
  for (var i = 0; i < r.length; i++) {
    final name = r[i].name;
    final fi = findFile(dirPrefix + name, followLink: followLink);
    r[i] = DirEntryInfo(name, fi, fi == null ? lastFindErrno : 0);
  }
  return r;
}

// ---------------------------------------------------------------------------
// lstat times of symbolic links (via the "stat" program: GNU "stat -c" on
// Linux, BSD "stat -f" on macOS; never on Windows)

final Map<String, (FiTime, FiTime, FiTime)> _lstatCache = {};

FiTime _parseTs(String s) {
  // "sec.nsec"
  var dot = s.indexOf('.');
  if (dot < 0) dot = s.indexOf(',');
  final sec = int.parse(dot < 0 ? s : s.substring(0, dot));
  var ns = 0;
  if (dot >= 0) {
    final f = s.substring(dot + 1).padRight(9, '0').substring(0, 9);
    ns = int.parse(f);
  }
  final ft = sec * 10000000 + kFileTimeUnixEpoch + ns ~/ 100;
  return FiTime(ft, ns % 100);
}

void _prefetchLstat(List<String> paths) {
  final need = paths.where((p) => !_lstatCache.containsKey(p)).toList();
  if (need.isEmpty) return;
  try {
    final r = Process.runSync(
        'stat',
        kIsMac
            ? ['-f', '%.9Fm %.9Fa %.9Fc', '--', ...need]
            : ['-c', '%.9Y %.9X %.9Z', '--', ...need],
        stdoutEncoding: utf8,
        environment: {'LC_ALL': 'C'});
    if (r.exitCode != 0) return;
    final lines = (r.stdout as String).split('\n');
    for (var i = 0; i < need.length && i < lines.length; i++) {
      final parts = lines[i].trim().split(' ');
      if (parts.length != 3) continue;
      _lstatCache[need[i]] =
          (_parseTs(parts[0]), _parseTs(parts[1]), _parseTs(parts[2]));
    }
  } on Object {
    // no stat program: the caller uses other times
  }
}

/// (mTime, aTime, cTime) of symbolic links themselves.
Map<String, (FiTime, FiTime, FiTime)?> lstatTimes(List<String> paths) {
  if (!kIsWin) _prefetchLstat(paths);
  return {for (final p in paths) p: _lstatCache[p]};
}

// ---------------------------------------------------------------------------
// FileDir.cpp

/// CreateDir: true when created or when it exists as a directory.
bool createDir(String path) {
  try {
    Directory(resolvePath(path)).createSync();
    return true;
  } on FileSystemException catch (e) {
    lastFindErrno = errnoOf(e);
    return false;
  }
}

/// CreateComplexDir.
bool createComplexDir(String path) {
  try {
    final real = resolvePath(path);
    if (doesDirExist(real)) return true;
    Directory(real).createSync(recursive: true);
    return true;
  } on FileSystemException catch (e) {
    lastFindErrno = errnoOf(e);
    return false;
  }
}

/// RemoveDir.
bool removeDir(String path) {
  try {
    Directory(resolvePath(path)).deleteSync();
    return true;
  } on FileSystemException catch (e) {
    lastFindErrno = errnoOf(e);
    return false;
  }
}

/// DeleteFileAlways: on Windows FILE_ATTRIBUTE_READONLY is cleared first.
bool deleteFileAlways(String path) {
  final real = resolvePath(path);
  for (var pass = 0;; pass++) {
    try {
      final t = FileSystemEntity.typeSync(real, followLinks: false);
      if (t == FileSystemEntityType.link) {
        Link(real).deleteSync();
      } else {
        File(real).deleteSync();
      }
      return true;
    } on FileSystemException catch (e) {
      lastFindErrno = errnoOf(e);
      if (!kIsWin || pass != 0 || lastFindErrno != 5) return false;
      final fi = findFile(path);
      if (fi == null || fi.isDir || !fi.isReadOnly) return false;
      if (!_runAttrib(real, fi.attrib & ~FileAttrib.readOnly, fi.attrib)) {
        lastFindErrno = 5; // ERROR_ACCESS_DENIED
        return false;
      }
    }
  }
}

/// RemoveDirAlways_if_Empty.
bool removeDirAlwaysIfEmpty(String path) => removeDir(path);

/// MyMoveFile.
bool myMoveFile(String oldFile, String newFile) {
  try {
    final a = resolvePath(oldFile);
    final b = resolvePath(newFile);
    final t = FileSystemEntity.typeSync(a, followLinks: false);
    if (t == FileSystemEntityType.directory) {
      Directory(a).renameSync(b);
    } else if (t == FileSystemEntityType.link) {
      Link(a).renameSync(b);
    } else {
      try {
        File(a).renameSync(b);
      } on FileSystemException catch (e) {
        if ((e.osError?.errorCode ?? 0) != Errno.exdev) rethrow;
        File(a).copySync(b);
        File(a).deleteSync();
      }
    }
    return true;
  } on FileSystemException catch (e) {
    lastFindErrno = errnoOf(e);
    return false;
  }
}

/// AutoRenamePath (FilePathAutoRename.cpp): null when no name was found.
String? autoRenamePath(String path) {
  final dotPos = path.lastIndexOf('.');
  final slashPos = reverseFindPathSepar(path);
  var name = path;
  var extension = '';
  if (dotPos > slashPos + 1) {
    name = path.substring(0, dotPos);
    extension = path.substring(dotPos);
  }
  name += '_';
  bool makeAutoName(int value) => doesFileOrDirExist('$name$value$extension');
  var left = 1, right = 1 << 30;
  while (left != right) {
    final mid = (left + right) ~/ 2;
    if (makeAutoName(mid)) {
      left = mid + 1;
    } else {
      right = mid;
    }
  }
  if (makeAutoName(right)) return null;
  return '$name$right$extension';
}

// ---------------------------------------------------------------------------
// chmod (attrib on Windows), directory and link times: batched through
// system programs.

/// Receives the paths whose attributes could not be set (SetAttrib_Base:
/// "Cannot set file attribute") with the error code.
typedef AttribErrorSink = void Function(String path, int errorCode);

int? _umaskMask;

/// C_umask: 0777 & ~umask (read from a new temporary directory).
int umaskMask() {
  final m = _umaskMask;
  if (m != null) return m;
  var mask = 0x1ED; // 0755
  try {
    final t = Directory.systemTemp.createTempSync('7zum');
    mask = t.statSync().mode & 0x1FF;
    t.deleteSync();
  } on Object {
    // keep 0755
  }
  return _umaskMask = mask;
}

final Map<int, List<String>> _pendingChmod = {};

/// The attribute changes of Windows: (path, new attributes, current).
final List<(String, int, int)> _pendingAttrib = [];

/// SetFileAttrib_PosixHighDetect: the mode change is queued and applied by
/// [flushFileAttribs]. Returns false when the file does not exist.
bool setFileAttribPosixHighDetect(String path, int attrib) {
  final fi = findFile(path);
  if (fi == null) return false;
  if (kIsWin) {
    // SetFileAttrib_PosixHighDetect (_WIN32): SetFileAttributes with the
    // low bits. dart:io can not change attributes: the read-only, hidden
    // and system bits are set with "attrib" when they change; the archive
    // bit is kept as Windows sets it.
    attrib &= 0xFFFFFFFF;
    if ((attrib & 0xF0000000) != 0) attrib &= 0x3FFF;
    const kMask = FileAttrib.readOnly | FileAttrib.hidden | FileAttrib.system;
    if ((attrib & kMask) != (fi.attrib & kMask)) {
      _pendingAttrib.add((resolvePath(path), attrib, fi.attrib));
    }
    return true;
  }
  var mode = fi.mode;
  if ((attrib & 0x8000) != 0) {
    mode = (attrib >> 16) & 0xFFFF;
    if (sIsDir(mode)) {
      mode |= 0x1C0; // S_IRWXU
    } else if (!sIsReg(mode)) {
      return true;
    }
  } else if (sIsLnk(mode)) {
    return true;
  } else {
    if (sIsDir(mode) || (attrib & 0x1) == 0) return true;
    mode &= ~0x92;
  }
  final m = mode & umaskMask();
  if ((fi.mode & 0xFFF) == m) return true;
  (_pendingChmod[m] ??= []).add(resolvePath(path));
  return true;
}

// Runs [exe] for the paths in chunks. Returns the paths of the chunks that
// failed with their error code: the errno of a program that can not be
// started, EPERM for a path whose [check] fails after a failing run.
List<(String, int)> _runBatched(String exe, List<String> fixedArgs,
    List<String> paths, bool Function(String path) check) {
  const kMaxArgsLen = 100000;
  final failed = <(String, int)>[];
  var i = 0;
  while (i < paths.length) {
    final chunk = <String>[];
    var len = 0;
    while (i < paths.length && (chunk.isEmpty || len < kMaxArgsLen)) {
      chunk.add(paths[i]);
      len += paths[i].length + 1;
      i++;
    }
    try {
      final r = Process.runSync(exe, [...fixedArgs, '--', ...chunk]);
      if (r.exitCode != 0) {
        for (final p in chunk) {
          if (!check(p)) failed.add((p, Errno.eperm));
        }
      }
    } on ProcessException catch (e) {
      // the program is missing: the attributes stay as created
      final code = e.errorCode > 0 ? e.errorCode : Errno.enoent;
      for (final p in chunk) {
        failed.add((p, code));
      }
    }
  }
  return failed;
}

// "attrib" (Windows) for one path: sets the read-only, hidden and system
// bits of [attrib] where they differ from [current].
bool _runAttrib(String path, int attrib, int current) {
  final args = <String>[];
  for (final (bit, c) in const [
    (FileAttrib.readOnly, 'R'),
    (FileAttrib.hidden, 'H'),
    (FileAttrib.system, 'S')
  ]) {
    if ((attrib & bit) != (current & bit)) {
      args.add('${(attrib & bit) != 0 ? '+' : '-'}$c');
    }
  }
  if (args.isEmpty) return true;
  try {
    final r = Process.runSync('attrib', [...args, path]);
    if (r.exitCode != 0) return false;
    // attrib also returns 0 when it did not change the file
    final fi = findFile(path);
    const kMask = FileAttrib.readOnly;
    return fi == null || (fi.attrib & kMask) == (attrib & kMask);
  } on ProcessException {
    return false;
  }
}

/// Applies the queued mode changes. [onError] receives the paths that
/// could not be changed.
void flushFileAttribs([AttribErrorSink? onError]) {
  if (_pendingAttrib.isNotEmpty) {
    final list = List.of(_pendingAttrib);
    _pendingAttrib.clear();
    for (final (path, attrib, current) in list) {
      if (!_runAttrib(path, attrib, current)) {
        onError?.call(path, Errno.eacces);
      }
    }
  }
  if (_pendingChmod.isEmpty) return;
  final entries = _pendingChmod.entries.toList();
  _pendingChmod.clear();
  for (final e in entries) {
    final m = e.key;
    final failed = _runBatched('chmod', [m.toRadixString(8)], e.value, (p) {
      try {
        return (FileStat.statSync(p).mode & 0xFFF) == m;
      } on Object {
        return false;
      }
    });
    for (final (p, code) in failed) {
      onError?.call(p, code);
    }
  }
}

String _touchStamp(int ft, int ns100) {
  final t = ft - kFileTimeUnixEpoch;
  final sec = t ~/ 10000000;
  var rem = t % 10000000;
  if (t < 0 && rem != 0) rem = rem;
  final ns = rem * 100 + ns100;
  return '@$sec.${ns.toString().padLeft(9, '0')}';
}

String _two(int v) => v.toString().padLeft(2, '0');

// The ISO 8601 form of "touch -d" of BSD: YYYY-MM-DDThh:mm:SS.fracZ.
String _touchStampBsd(int ft, int ns100) {
  final d = fileTimeToDateTime(ft);
  final t = ft - kFileTimeUnixEpoch;
  var rem = t % 10000000;
  if (rem < 0) rem += 10000000;
  final ns = rem * 100 + ns100;
  return '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-'
      '${_two(d.day)}T${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}'
      '.${ns.toString().padLeft(9, '0')}Z';
}

// The POSIX form of "touch -t" ([[CC]YY]MMDDhhmm[.SS]) in UTC.
String _touchStampPosix(int ft) {
  final d = fileTimeToDateTime(ft);
  return '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}'
      '${_two(d.hour)}${_two(d.minute)}.${_two(d.second)}';
}

/// SetDirTime / SetLinkFileTime: sets the modification time of a directory
/// (or of a symbolic link itself with [link]) through "touch" (GNU syntax
/// on Linux, BSD syntax on macOS: "-d" with an ISO 8601 time, then "-t"
/// when that fails). On Windows dart:io is tried for directories (it can
/// not set the times of a directory on every Windows version) and the
/// times of links are not set.
bool setDirOrLinkMTime(String path, int ft, int ns100, {bool link = false}) {
  final real = resolvePath(path);
  if (kIsWin) {
    if (link) return false;
    try {
      File(real).setLastModifiedSync(fileTimeToDateTime(ft));
      return true;
    } on FileSystemException {
      return false;
    }
  }
  try {
    if (kIsMac) {
      var r = Process.runSync('touch', [
        if (link) '-h',
        '-m',
        '-d',
        _touchStampBsd(ft, ns100),
        '--',
        real
      ], environment: {'LC_ALL': 'C'});
      if (r.exitCode == 0) return true;
      r = Process.runSync('touch', [
        if (link) '-h',
        '-m',
        '-t',
        _touchStampPosix(ft),
        '--',
        real
      ], environment: {'LC_ALL': 'C', 'TZ': 'UTC0'});
      return r.exitCode == 0;
    }
    final r = Process.runSync('touch', [
      if (link) '-h',
      '-m',
      '-d',
      _touchStamp(ft, ns100),
      '--',
      real
    ], environment: {'LC_ALL': 'C'});
    return r.exitCode == 0;
  } on Object {
    return false;
  }
}

/// Sets the modification (and access) time of a regular file.
bool setFileTimes(String path, int? mTime, int? aTime) {
  try {
    final f = File(resolvePath(path));
    if (mTime != null) f.setLastModifiedSync(fileTimeToDateTime(mTime));
    if (aTime != null) f.setLastAccessedSync(fileTimeToDateTime(aTime));
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Makes [path] a hard link to the existing file [target]: `ln` on POSIX
/// systems, `mklink /H` on Windows (the system tools, as for the modes and
/// times above). When the file system can not link (FAT, another volume),
/// [path] becomes a copy of [target]. An existing file at [path] is
/// replaced. Returns false when neither worked.
bool createHardLinkOrCopy(String target, String path) {
  final t = resolvePath(target);
  final p = resolvePath(path);
  try {
    if (FileSystemEntity.typeSync(p, followLinks: false) ==
        FileSystemEntityType.file) {
      File(p).deleteSync();
    }
  } on FileSystemException {
    // the tools report it
  }
  try {
    final r = kIsWin
        ? Process.runSync('cmd', ['/c', 'mklink', '/H', p, t])
        : Process.runSync('ln', ['-f', '--', t, p],
            environment: {'LC_ALL': 'C'});
    if (r.exitCode == 0) return true;
  } on ProcessException {
    // no tool: copy
  }
  try {
    File(t).copySync(p);
    return true;
  } on FileSystemException {
    return false;
  }
}
