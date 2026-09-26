// Scanning of the file system with the censor rules: UI/Common/DirItem.h
// (CDirItemsStat, CDirItem, CArcItem) and UI/Common/EnumDirItems.cpp
// (CDirItems, EnumerateItems, EnumerateDirItemsAndSort) of the LZMA SDK.
// POSIX: links are not followed with -snl, and never entered. Windows: the
// drive and "\\?\" prefixes, the attributes of FindFirstFile, links
// (reparse points) are not entered with -snl.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'common.dart';
import '../format/archive_types.dart' show FileAttrib;
import 'file_link.dart';
import 'fs_utils.dart';
import 'open_archive.dart';
import 'platform.dart';
import 'wildcard.dart';

/// CDirItemsStat.
class DirItemsStat {
  int numDirs = 0;
  int numFiles = 0;
  int numAltStreams = 0;
  int filesSize = 0;
  int altStreamsSize = 0;
  int numErrors = 0;

  int getNumDataItems() => numFiles + numAltStreams;
  int getTotalBytes() => filesSize + altStreamsSize;

  bool get isEmpty =>
      numDirs == 0 &&
      numFiles == 0 &&
      numAltStreams == 0 &&
      filesSize == 0 &&
      altStreamsSize == 0 &&
      numErrors == 0;

  DirItemsStat copy() => DirItemsStat()
    ..numDirs = numDirs
    ..numFiles = numFiles
    ..numAltStreams = numAltStreams
    ..filesSize = filesSize
    ..altStreamsSize = altStreamsSize
    ..numErrors = numErrors;
}

/// CDirItemsStat2.
class DirItemsStat2 extends DirItemsStat {
  int antiNumDirs = 0;
  int antiNumFiles = 0;
  int antiNumAltStreams = 0;

  int getNumDataItems2() =>
      antiNumFiles + antiNumAltStreams + getNumDataItems();

  @override
  bool get isEmpty =>
      super.isEmpty &&
      antiNumDirs == 0 &&
      antiNumFiles == 0 &&
      antiNumAltStreams == 0;
}

/// IDirItemsCallback.
abstract class DirItemsCallback {
  /// ScanError: returns normally to continue; throws to stop.
  void scanError(String path, int systemError);
  void scanProgress(DirItemsStat st, String path, bool isDir);
}

/// CDirItem.
class DirItem {
  String name;
  int size;
  int mode;

  /// The attributes on Windows (CDirItem::Attrib).
  int attrib;
  FiTime cTime;
  FiTime aTime;
  FiTime mTime;
  int phyParent;
  int logParent;

  /// The target of a symbolic link stored with -snl (ReparseData).
  Uint8List? reparseData;

  DirItem(this.name, FileInfo fi, this.phyParent, this.logParent)
      : size = fi.size,
        mode = fi.mode,
        attrib = fi.attrib,
        cTime = fi.cTime,
        aTime = fi.aTime,
        mTime = fi.mTime;

  DirItem.empty()
      : name = '',
        size = 0,
        mode = 0,
        attrib = 0,
        cTime = const FiTime(0),
        aTime = const FiTime(0),
        mTime = const FiTime(0),
        phyParent = -1,
        logParent = -1;

  bool isDir() => sIsDir(mode);
  bool get isPosixLink => sIsLnk(mode);
  bool areReparseData() => reparseData != null && reparseData!.isNotEmpty;
  int getWinAttrib() => kIsWin ? attrib : winAttribFromPosixMode(mode);
  int getPosixAttrib() => mode;

  /// SetAs_StdInFile: [st] is fstat(0) when available.
  void setAsStdInFile(FileStat? st) {
    final now = FiTime.fromDateTime(DateTime.now());
    size = -1;
    mode = 0x1000 | 0x1FF; // S_IFIFO | 0777
    attrib = 0; // ClearBase (Windows: GetFileInformationByHandle is not available)
    cTime = now;
    aTime = now;
    mTime = now;
    if (st != null && st.type != FileSystemEntityType.notFound) {
      mode = st.mode;
      size = st.type == FileSystemEntityType.directory ? 0 : st.size;
      mTime = FiTime.fromDateTime(st.modified);
      aTime = FiTime.fromDateTime(st.accessed);
      cTime = FiTime.fromDateTime(st.changed);
      if (!sIsReg(st.mode) || st.size == 0) size = -1;
    }
  }
}

// FindFile_KeepDots
FileInfo? _findFileKeepDots(String path, bool followLink) {
  final fi = findFile(path, followLink: followLink, exactName: true);
  if (fi == null) return null;
  if (path.isEmpty) return fi;
  var p = path.length - 1;
  if (path.codeUnitAt(p) != 0x2E) return fi;
  if (p != 0) {
    var c = path.codeUnitAt(p - 1);
    if (!isPathSepar(c)) {
      if (c != 0x2E) return fi;
      p--;
      if (p != 0) {
        c = path.codeUnitAt(p - 1);
        if (!isPathSepar(c)) return fi;
      }
    }
  }
  fi.name = path.substring(p);
  return fi;
}

/// CDirItems.
class DirItems {
  final List<String> _prefixes = [];
  final List<int> _phyParents = [];
  final List<int> _logParents = [];
  final List<DirItem> items = [];

  bool symLinks = false;
  bool scanAltStreams = false;
  bool excludeDirItems = false;
  bool excludeFileItems = false;
  bool shareForWrite = false;

  final DirItemsStat stat = DirItemsStat();
  DirItemsCallback? callback;

  bool canIncludeItem(bool isDir) => isDir ? !excludeDirItems : !excludeFileItems;

  // AddDirFileInfo
  void addDirFileInfo(int phyParent, int logParent, FileInfo fi) {
    items.add(DirItem(fi.name, fi, phyParent, logParent));
    if (fi.isDir) {
      stat.numDirs++;
    } else {
      stat.numFiles++;
      stat.filesSize += fi.size;
    }
  }

  // AddError: DI_DEFAULT_ERROR is ERROR_INVALID_FUNCTION (EINVAL)
  void addError(String path, int errorCode) {
    if (errorCode == 0) errorCode = Errno.einval;
    stat.numErrors++;
    callback?.scanError(path, errorCode);
  }

  // ScanProgress
  void scanProgress(String dirPath) =>
      callback?.scanProgress(stat, dirPath, true);

  // GetPrefixesPath
  String _getPrefixesPath(List<int> parents, int index, String name) {
    final parts = <String>[name];
    for (var i = index; i >= 0; i = parents[i]) {
      parts.add(_prefixes[i]);
    }
    return parts.reversed.join();
  }

  String getPhyPath(int index) {
    final di = items[index];
    return _getPrefixesPath(_phyParents, di.phyParent, di.name);
  }

  String getLogPath(int index) {
    final di = items[index];
    return _getPrefixesPath(_logParents, di.logParent, di.name);
  }

  // AddPrefix
  int addPrefix(int phyParent, int logParent, String prefix) {
    _phyParents.add(phyParent);
    _logParents.add(logParent);
    _prefixes.add(prefix);
    return _prefixes.length - 1;
  }

  // DeleteLastPrefix
  void deleteLastPrefix() {
    _phyParents.removeLast();
    _logParents.removeLast();
    _prefixes.removeLast();
  }

  // EnumerateOneDir
  List<FileInfo>? _enumerateOneDir(String phyPrefix) {
    final entries = enumerateDir(phyPrefix, !symLinks);
    if (entries == null) {
      addError(phyPrefix, lastFindErrno);
      return null;
    }
    final files = <FileInfo>[];
    for (var i = 0; i < entries.length; i++) {
      final de = entries[i];
      final fi = de.info;
      if (fi == null) {
        addError(phyPrefix + de.name, de.errno);
        continue;
      }
      fi.name = de.name;
      files.add(fi);
    }
    return files;
  }

  // SetLinkInfo
  void setLinkInfo(DirItem dirItem, FileInfo fi, String phyPrefix) {
    if (!symLinks) return;
    if (kIsWin) {
      _setLinkInfoWin(dirItem, fi, phyPrefix);
      return;
    }
    if (!fi.isPosixLink) return;
    final target = fi.linkTarget;
    if (target != null) {
      dirItem.reparseData = Uint8List.fromList(utf8.encode(target));
      stat.filesSize -= fi.size;
      stat.filesSize += 0;
      return;
    }
    addError(phyPrefix + fi.name, Errno.einval);
  }
}

// IsVirtualFsFolder (Windows): true for a non real folder like "\\SERVER\".
bool _isVirtualFsFolder(String prefix, String name) {
  if (!kIsWin) return false;
  final s = '$prefix$name$kDirSep';
  return isPathSepar(s.codeUnitAt(0)) && getRootPrefixSize(s) == 0;
}

extension on DirItems {
  // SetLinkInfo (_WIN32): the reparse data of the link (GetReparseData),
  // made from the link target (see file_link.dart).
  void _setLinkInfoWin(DirItem dirItem, FileInfo fi, String phyPrefix) {
    if (!fi.hasReparsePoint) return;
    final target = fi.linkTarget;
    final data = target == null ? null : fillLinkDataWinLink(target, true);
    if (data != null) {
      dirItem.reparseData = data;
      stat.filesSize -= fi.size;
      return;
    }
    addError(phyPrefix + fi.name, 4392); // ERROR_INVALID_REPARSE_DATA
  }
}

// EnumerateDirItems_Spec
void _enumerateDirItemsSpec(
    CensorNode curNode,
    int phyParent,
    int logParent,
    String curFolderName,
    String phyPrefix,
    List<String> addParts,
    DirItems dirItems,
    bool enterToSubFolders) {
  final name2 = '$curFolderName$kDirSep';
  final parent = dirItems.addPrefix(phyParent, logParent, name2);
  final numItems = dirItems.items.length;
  _enumerateDirItems(curNode, parent, parent, phyPrefix + name2, addParts,
      dirItems, enterToSubFolders);
  if (numItems == dirItems.items.length) dirItems.deleteLastPrefix();
}

// EnumerateForItem
void _enumerateForItem(
    FileInfo fi,
    CensorNode curNode,
    int phyParent,
    int logParent,
    String phyPrefix,
    List<String> addParts,
    DirItems dirItems,
    bool enterToSubFolders) {
  final name = fi.name;
  var newParts = [...addParts, name];

  if (curNode.checkPathToRoot(false, newParts, !fi.isDir)) return;

  var dirItemIndex = -1;
  if (curNode.checkPathToRoot(true, newParts, !fi.isDir)) {
    if (dirItems.canIncludeItem(fi.isDir)) {
      dirItemIndex = dirItems.items.length;
      dirItems.addDirFileInfo(phyParent, logParent, fi);
    }
    if (fi.isDir) enterToSubFolders = true;
  }

  if (dirItemIndex >= 0) {
    final dirItem = dirItems.items[dirItemIndex];
    dirItems.setLinkInfo(dirItem, fi, phyPrefix);
    if (dirItem.areReparseData()) return;
  }

  if (kIsWin || !fi.isPosixLink) {
    if (!fi.isDir) return;
  }

  CensorNode? nextNode;
  if (addParts.isEmpty) {
    final index = curNode.findSubNode(name);
    if (index >= 0) {
      nextNode = curNode.subNodes[index];
      newParts = [];
    }
  }

  if (nextNode == null) {
    if (!enterToSubFolders) return;
    if (kIsWin) {
      // 20.03: in SymLinks mode: we don't enter to directory that has
      // reparse point and has no CCensorNode
      if (dirItems.symLinks && fi.hasReparsePoint) return;
    } else if (fi.isPosixLink) {
      return;
    }
    nextNode = curNode;
  }

  _enumerateDirItemsSpec(nextNode, phyParent, logParent, fi.name, phyPrefix,
      newParts, dirItems, enterToSubFolders);
}

// CanUseFsDirect
bool _canUseFsDirect(CensorNode curNode) {
  for (final item in curNode.includeItems) {
    if (item.recursive || item.pathParts.length != 1) return false;
    if (doesNameContainWildcard(item.pathParts.first)) return false;
  }
  return true;
}

// EnumerateDirItems
void _enumerateDirItems(CensorNode curNode, int phyParent, int logParent,
    String phyPrefix, List<String> addParts, DirItems dirItems,
    bool enterToSubFolders) {
  if (!enterToSubFolders) {
    if (curNode.needCheckSubDirs()) enterToSubFolders = true;
  }

  dirItems.scanProgress(phyPrefix);

  if (addParts.isEmpty && !enterToSubFolders) {
    if (_canUseFsDirect(curNode)) {
      final needEnterVector = <bool>[];
      for (final item in curNode.includeItems) {
        final name = item.pathParts.first;
        var fullPath = phyPrefix + name;

        if (phyPrefix.isEmpty) {
          if (!item.forFile) {
            if (name.isEmpty) {
              fullPath = kDirSep;
            } else if (item.isDriveItem()) {
              fullPath += kDirSep;
            }
          }
        }

        FileInfo? fi;
        if (_isVirtualFsFolder(phyPrefix, name)) {
          fi = FileInfo()
            ..mode = sIFDIR | 0x1FF
            ..attrib = FileAttrib.directory
            ..name = name;
        } else {
          fi = _findFileKeepDots(fullPath, !dirItems.symLinks);
        }
        if (fi == null) {
          dirItems.addError(fullPath, lastFindErrno);
          continue;
        }
        final isDir = fi.isDir;
        if (isDir ? !item.forDir : !item.forFile) {
          dirItems.addError(fullPath, Errno.einval);
          continue;
        }
        if (curNode.checkPathToRoot(false, [fi.name], !isDir)) continue;

        if (dirItems.canIncludeItem(fi.isDir)) {
          dirItems.addDirFileInfo(phyParent, logParent, fi);
          final dirItem = dirItems.items.last;
          dirItems.setLinkInfo(dirItem, fi, phyPrefix);
          if (dirItem.areReparseData()) continue;
        }

        if (kIsWin || !fi.isPosixLink) {
          if (!isDir) continue;
        }

        var newParts = <String>[];
        CensorNode nextNode;
        final index = curNode.findSubNode(name);
        if (index >= 0) {
          for (var t = needEnterVector.length; t <= index; t++) {
            needEnterVector.add(true);
          }
          needEnterVector[index] = false;
          nextNode = curNode.subNodes[index];
        } else {
          if (kIsWin) {
            if (dirItems.symLinks && fi.hasReparsePoint) continue;
          } else if (fi.isPosixLink) {
            continue;
          }
          nextNode = curNode;
          newParts = [name];
        }
        _enumerateDirItemsSpec(nextNode, phyParent, logParent, fi.name,
            phyPrefix, newParts, dirItems, true);
      }

      for (var i = 0; i < curNode.subNodes.length; i++) {
        if (i < needEnterVector.length) {
          if (!needEnterVector[i]) continue;
        }
        final nextNode = curNode.subNodes[i];
        var fullPath = phyPrefix + nextNode.name;
        FileInfo? fi;
        if (nextNode.name.isEmpty) {
          if (phyPrefix.isEmpty) fullPath = kDirSep;
        } else if (kIsWin &&
            (phyPrefix.isEmpty ||
                (phyPrefix.length == kSuperPathPrefixSize &&
                    isSuperPath(phyPrefix)))) {
          if (isDriveColonName(nextNode.name)) fullPath += kDirSep;
        }
        if ((phyPrefix.isEmpty && nextNode.name.isEmpty) ||
            _isVirtualFsFolder(phyPrefix, nextNode.name)) {
          fi = FileInfo()
            ..mode = sIFDIR | 0x1FF
            ..attrib = FileAttrib.directory
            ..name = nextNode.name;
        } else {
          fi = _findFileKeepDots(fullPath, !dirItems.symLinks);
          if (fi == null) {
            if (!nextNode.areThereIncludeItems()) continue;
            dirItems.addError(fullPath, lastFindErrno);
            continue;
          }
          if (!fi.isDir) {
            dirItems.addError(fullPath, Errno.einval);
            continue;
          }
        }
        _enumerateDirItemsSpec(nextNode, phyParent, logParent, fi.name,
            phyPrefix, const [], dirItems, false);
      }
      return;
    }
  }

  final files = dirItems._enumerateOneDir(phyPrefix);
  if (files == null) return;
  for (final fi in files) {
    _enumerateForItem(fi, curNode, phyParent, logParent, phyPrefix, addParts,
        dirItems, enterToSubFolders);
  }
}

/// EnumerateItems.
void enumerateItems(Censor censor, CensorPathMode pathMode,
    String addPathPrefix, DirItems dirItems) {
  for (final pair in censor.pairs) {
    final phyParent =
        pair.prefix.isEmpty ? -1 : dirItems.addPrefix(-1, -1, pair.prefix);
    var logParent = -1;
    if (pathMode == CensorPathMode.absPath) {
      logParent = phyParent;
    } else {
      if (addPathPrefix.isNotEmpty) {
        logParent = dirItems.addPrefix(-1, -1, addPathPrefix);
      }
    }
    _enumerateDirItems(
        pair.head, phyParent, logParent, pair.prefix, const [], dirItems, false);
  }
}

/// EnumerateDirItemsAndSort: (sortedPaths, sortedFullPaths, stat).
(List<String>, List<String>, DirItemsStat) enumerateDirItemsAndSort(
    Censor censor,
    CensorPathMode censorPathMode,
    String addPathPrefix,
    DirItemsCallback? callback) {
  final paths = <String>[];
  DirItemsStat st;
  {
    final dirItems = DirItems()..callback = callback;
    try {
      enumerateItems(censor, censorPathMode, addPathPrefix, dirItems);
    } finally {
      st = dirItems.stat.copy();
    }
    for (var i = 0; i < dirItems.items.length; i++) {
      if (!dirItems.items[i].isDir()) paths.add(dirItems.getPhyPath(i));
    }
  }
  if (paths.isEmpty) throw MessagePathException('Cannot find archive');

  final fullPaths = [for (final p in paths) myGetFullPathName(p)];
  final indices = List<int>.generate(paths.length, (i) => i);
  indices.sort((a, b) => compareFileNames(fullPaths[a], fullPaths[b]));
  final sortedPaths = <String>[];
  final sortedFullPaths = <String>[];
  for (var i = 0; i < indices.length; i++) {
    final index = indices[i];
    sortedPaths.add(paths[index]);
    sortedFullPaths.add(fullPaths[index]);
    if (i > 0 &&
        compareFileNames(sortedFullPaths[i], sortedFullPaths[i - 1]) == 0) {
      throw MessagePathException('Duplicate archive path:', sortedFullPaths[i]);
    }
  }
  return (sortedPaths, sortedFullPaths, st);
}

/// CArcItem.
class ArcItem {
  int size = 0;
  String name = '';
  final ArcTime mTime = ArcTime();
  bool isDir = false;
  bool isAltStream = false;
  bool sizeDefined = false;
  bool censored = false;
  int indexInServer = 0;
}
