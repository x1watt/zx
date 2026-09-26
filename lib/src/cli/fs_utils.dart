// File system helpers of the POSIX build: Windows/FileFind.cpp (CFileInfo
// from stat / lstat, Get_WinAttribPosix_From_PosixMode), Windows/FileDir.cpp
// (CreateComplexDir, SetFileAttrib_PosixHighDetect with the umask,
// SetDirTime, MyMoveFile) and Common/FilePathAutoRename.cpp, over dart:io.
//
// dart:io has no chmod, lstat or directory timestamp call. The port runs
// the system "chmod" and "touch" programs for those (batched), and "stat"
// for the own timestamps of symbolic links.

import 'dart:convert';
import 'dart:io';

import 'common.dart';
import 'open_archive.dart' show FiTime, cliCurrentDirectory;

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
  if (cwd == null || path.startsWith('/')) return path;
  if (path.isEmpty) return cwd;
  return '$cwd/$path';
}

/// NFind::CFileInfo (POSIX).
class FileInfo {
  String name = '';
  int size = 0;
  int mode = 0;
  FiTime cTime = const FiTime(0);
  FiTime aTime = const FiTime(0);
  FiTime mTime = const FiTime(0);

  /// The target of a symbolic link found with followLink = false.
  String? linkTarget;

  bool get isDir => sIsDir(mode);
  bool get isPosixLink => sIsLnk(mode);
  bool get isReadOnly => (mode & 0x92) == 0; // (mode & 0222) == 0

  /// GetWinAttrib: Get_WinAttribPosix_From_PosixMode.
  int getWinAttrib() => winAttribFromPosixMode(mode);

  FileInfo copy() => FileInfo()
    ..name = name
    ..size = size
    ..mode = mode
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
    if (path.codeUnitAt(p) == 0x2F) return path.substring(p + 1);
    if (p == 0) return path;
    p--;
  }
}

/// CFileInfo::Find (followLink = false uses lstat semantics).
FileInfo? findFile(String path, {bool followLink = false}) {
  lastFindErrno = 0;
  final real = resolvePath(path);
  try {
    final type = FileSystemEntity.typeSync(real, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      lastFindErrno = Errno.enoent;
      return null;
    }
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
    final name = e.path.substring(e.path.lastIndexOf('/') + 1);
    if (e is Link && !followLink) linkPaths.add(resolvePath(dirPrefix + name));
    r.add(DirEntryInfo(name, null, 0));
  }
  if (linkPaths.isNotEmpty) _prefetchLstat(linkPaths);
  for (var i = 0; i < r.length; i++) {
    final name = r[i].name;
    final fi = findFile(dirPrefix + name, followLink: followLink);
    r[i] = DirEntryInfo(name, fi, fi == null ? lastFindErrno : 0);
  }
  return r;
}

// ---------------------------------------------------------------------------
// lstat times of symbolic links (via the "stat" program)

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
        'stat', ['-c', '%.9Y %.9X %.9Z', '--', ...need],
        stdoutEncoding: utf8, environment: {'LC_ALL': 'C'});
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
  _prefetchLstat(paths);
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

/// DeleteFileAlways.
bool deleteFileAlways(String path) {
  try {
    final real = resolvePath(path);
    final t = FileSystemEntity.typeSync(real, followLinks: false);
    if (t == FileSystemEntityType.link) {
      Link(real).deleteSync();
    } else {
      File(real).deleteSync();
    }
    return true;
  } on FileSystemException catch (e) {
    lastFindErrno = errnoOf(e);
    return false;
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
  final slashPos = path.lastIndexOf('/');
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
// chmod, directory and link times: batched through system programs.

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

/// SetFileAttrib_PosixHighDetect: the mode change is queued and applied by
/// [flushFileAttribs]. Returns false when the file does not exist.
bool setFileAttribPosixHighDetect(String path, int attrib) {
  final fi = findFile(path);
  if (fi == null) return false;
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

void _runBatched(String exe, List<String> fixedArgs, List<String> paths) {
  const kMaxArgsLen = 100000;
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
      Process.runSync(exe, [...fixedArgs, '--', ...chunk]);
    } on Object {
      // the program is missing: the attributes stay as created
    }
  }
}

/// Applies the queued mode changes.
void flushFileAttribs() {
  if (_pendingChmod.isEmpty) return;
  final entries = _pendingChmod.entries.toList();
  _pendingChmod.clear();
  for (final e in entries) {
    _runBatched('chmod', [e.key.toRadixString(8)], e.value);
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

/// SetDirTime / SetLinkFileTime: sets the modification time of a directory
/// (or of a symbolic link itself with [link]) through "touch".
bool setDirOrLinkMTime(String path, int ft, int ns100, {bool link = false}) {
  try {
    final r = Process.runSync('touch', [
      if (link) '-h',
      '-m',
      '-d',
      _touchStamp(ft, ns100),
      '--',
      resolvePath(path)
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
