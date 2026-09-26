// The update callback that gives the handlers the new items:
// UI/Common/UpdateCallback.cpp of the LZMA SDK (CArchiveUpdateCallback),
// POSIX build (symbolic links with -snl are stored as their target path).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../format/archive_types.dart';
import '../io/streams.dart';
import 'arc_handlers.dart';
import 'common.dart';
import 'enum_dir_items.dart';
import 'fs_utils.dart';
import 'open_archive.dart';
import 'update_pair.dart';

/// IUpdateCallbackUI.
abstract class UpdateCallbackUI {
  void setTotal(int size);
  void setCompleted(int completeValue);
  void checkBreak();
  void getStream(String name, bool isDir, bool isAnti, int mode);

  /// OpenFileError: returns normally for S_FALSE (skip the file); throws to
  /// stop.
  void openFileError(String path, int systemError);

  /// ReadingFileError: returns the HRESULT to fail with.
  int readingFileError(String path, int systemError);
  void setOperationResult(int opRes);
  void reportExtractResult(int opRes, bool isEncrypted, String name);
  void reportUpdateOperation(int op, String? name, bool isDir);

  /// CryptoGetTextPassword2: null when no password is used.
  String? cryptoGetTextPassword2();
  String cryptoGetTextPassword();
  void showDeleteFile(String name, bool isDir);
  void setNumItems(ArcToDoStat stat);
}

/// CArcToDoStat.
class ArcToDoStat {
  final DirItemsStat2 newData = DirItemsStat2();
  final DirItemsStat2 oldData = DirItemsStat2();
  final DirItemsStat2 deleteData = DirItemsStat2();
}

/// A file opened for the handler (CInFileStream): read errors go to
/// ReadingFileError, and the handler learns the size (IStreamGetSize).
class _InFileStream implements InStream, StreamGetSize, ReleasableStream {
  final FileInStream _f;
  final String path;
  final ArchiveUpdateCallbackImpl _owner;
  final int _index;
  _InFileStream(this._f, this.path, this._owner, this._index);

  @override
  int read(Uint8List buf, int off, int len) {
    try {
      return _f.read(buf, off, len);
    } on FileSystemException catch (e) {
      final hr = _owner.callback.readingFileError(path, errnoOf(e));
      throw SystemException(hr);
    }
  }

  @override
  int? get streamSize => _f.length;

  @override
  void release() {
    try {
      _f.close();
    } on Object {
      // ignore
    }
    _owner._onClose(_index);
  }
}

/// CArchiveUpdateCallback.
class ArchiveUpdateCallbackImpl extends ArchiveUpdateCallback
    implements
        ArchiveUpdateCallbackFile,
        CryptoGetTextPassword2,
        CryptoGetTextPassword,
        ArchiveExtractCallbackMessage2 {
  bool preserveATime = false;
  bool shareForWrite = false;
  bool stopAfterOpenError = false;
  bool stdInMode = false;
  bool storeSymLinks = false;
  bool needLatestMTime = false;
  bool latestMTimeDefined = false;
  FiTime latestMTime = const FiTime(0);

  late UpdateCallbackUI callback;
  DirItems? dirItems;
  DirItem? parentDirItem;
  Arc? arc;
  InArchive? archive;
  List<ArcItem>? arcItems;
  late List<UpdatePair2> updatePairs;
  List<String>? newNames;
  Uint8List? processedItemsStatuses;
  String arcFileName = '';
  InStream? stdinData;

  final List<int> _openFilesIndexes = [];
  final List<String> openFilesPaths = [];

  bool areAllFilesClosed() => _openFilesIndexes.isEmpty;

  void _onClose(int index) {
    final i = _openFilesIndexes.indexOf(index);
    if (i >= 0) {
      _openFilesIndexes.removeAt(i);
      openFilesPaths.removeAt(i);
    }
  }

  @override
  void setTotal(int total) => callback.setTotal(total);

  @override
  void setCompleted(int completeValue) => callback.setCompleted(completeValue);

  int _arcIndexOf(UpdatePair2 up) {
    final items = arcItems;
    return items != null ? items[up.arcIndex].indexInServer : up.arcIndex;
  }

  @override
  UpdateItemInfo getUpdateItemInfo(int index) {
    callback.checkBreak();
    final up = updatePairs[index];
    var indexInArchive = -1;
    if (up.existInArchive()) indexInArchive = _arcIndexOf(up);
    return UpdateItemInfo(up.newData, up.newProps, indexInArchive);
  }

  @override
  Object? getProperty(int index, int propId) {
    final up = updatePairs[index];
    if (up.newData) {
      if (propId == Kpid.symLink) {
        if (up.dirIndex >= 0) {
          final di = dirItems!.items[up.dirIndex];
          final rd = di.reparseData;
          if (rd != null && rd.isNotEmpty) {
            try {
              final us = utf8.decode(rd);
              if (us.isNotEmpty) return us;
            } on FormatException {
              return null;
            }
          }
          return null;
        }
      } else if (propId == Kpid.hardLink) {
        if (up.dirIndex >= 0) return null;
      }
    }

    if (up.isAnti &&
        propId != Kpid.isDir &&
        propId != Kpid.path &&
        propId != Kpid.isAltStream) {
      switch (propId) {
        case Kpid.size:
          return 0;
        case Kpid.isAnti:
          return true;
      }
      return null;
    }
    if (propId == Kpid.path && up.newNameIndex >= 0) {
      return newNames![up.newNameIndex];
    }
    if (up.useArcProps && up.existInArchive() && archive != null) {
      return archive!.getProperty(_arcIndexOf(up), propId);
    }
    if (up.existOnDisk()) {
      final di = dirItems!.items[up.dirIndex];
      switch (propId) {
        case Kpid.path:
          return dirItems!.getLogPath(up.dirIndex);
        case Kpid.isDir:
          return di.isDir();
        case Kpid.size:
          return di.isDir() ? 0 : di.size;
        case Kpid.cTime:
          return di.cTime.ft;
        case Kpid.aTime:
          return di.aTime.ft;
        case Kpid.mTime:
          return di.mTime.ft;
        case Kpid.attrib:
          return di.getWinAttrib();
        case Kpid.posixAttrib:
          return di.getPosixAttrib();
      }
    }
    return null;
  }

  // IsDir
  bool _isDir(UpdatePair2 up) {
    if (up.dirIndex >= 0) return dirItems!.items[up.dirIndex].isDir();
    if (up.arcIndex >= 0) return arcItems![up.arcIndex].isDir;
    return false;
  }

  // UpdateProcessedItemStatus
  void _updateProcessedItemStatus(int dirIndex) {
    final p = processedItemsStatuses;
    if (p != null) p[dirIndex] = 1;
  }

  // GetStream2
  @override
  InStream? getStream2(int index, int mode) {
    final up = updatePairs[index];
    if (!up.newData) throw const SystemException(HRes.eFail);
    callback.checkBreak();
    final isDir = _isDir(up);

    if (up.isAnti) {
      var name = '';
      if (up.arcIndex >= 0) {
        name = arcItems![up.arcIndex].name;
      } else if (up.dirIndex >= 0) {
        name = dirItems!.getLogPath(up.dirIndex);
      }
      callback.getStream(name, isDir, true, mode);
      if (!isDir) return MemoryInStream(Uint8List(0));
      return null;
    }

    callback.getStream(dirItems!.getLogPath(up.dirIndex), isDir, false, mode);
    if (isDir) return null;

    if (stdInMode) {
      if (mode != UpdateNotifyOp.add && mode != UpdateNotifyOp.update) {
        return null;
      }
      return stdinData ?? MemoryInStream(Uint8List(0));
    }

    final di = dirItems!.items[up.dirIndex];
    if (di.areReparseData()) {
      _updateProcessedItemStatus(up.dirIndex);
      return MemoryInStream(di.reparseData!);
    }

    final path = dirItems!.getPhyPath(up.dirIndex);
    _openFilesIndexes.add(index);
    openFilesPaths.add(path);
    FileInStream f;
    try {
      f = FileInStream.open(resolvePath(path));
    } on FileSystemException catch (e) {
      _onClose(index);
      final error = errnoOf(e);
      callback.openFileError(path, error);
      if (stopAfterOpenError || error == Errno.emfile) {
        throw SystemException(hresultFromErrno(error));
      }
      return null;
    }
    if (needLatestMTime) {
      final fi = findFile(path, followLink: true);
      if (fi != null) {
        if (!latestMTimeDefined || latestMTime.compare(fi.mTime) < 0) {
          latestMTime = fi.mTime;
        }
        latestMTimeDefined = true;
      }
    }
    _updateProcessedItemStatus(up.dirIndex);
    return _InFileStream(f, path, this, index);
  }

  @override
  InStream? getStream(int index) => getStream2(
      index,
      updatePairs[index].arcIndex < 0
          ? UpdateNotifyOp.add
          : UpdateNotifyOp.update);

  @override
  void setOperationResult(int opRes) => callback.setOperationResult(opRes);

  @override
  void reportOperation(int indexType, int index, int op) {
    var isDir = false;
    if (indexType == EventIndexType.outArcIndex) {
      var name = '';
      if (index != -1) {
        final up = updatePairs[index];
        if (up.existOnDisk()) {
          name = dirItems!.getLogPath(up.dirIndex);
          isDir = dirItems!.items[up.dirIndex].isDir();
        }
      }
      callback.reportUpdateOperation(op, name.isEmpty ? null : name, isDir);
      return;
    }
    String? s;
    if (indexType == EventIndexType.inArcIndex) {
      if (index != -1) {
        final items = arcItems;
        if (items != null) {
          final ai = items[index];
          s = ai.name;
          isDir = ai.isDir;
        } else if (arc != null) {
          s = arc!.getItemPath(index);
          isDir = archiveIsItemDir(arc!.archive!, index);
        }
      }
    } else if (indexType == EventIndexType.blockIndex) {
      s = '#$index';
    }
    callback.reportUpdateOperation(op, s ?? '', isDir);
  }

  @override
  void reportExtractResult(int indexType, int index, int opRes) {
    var isEncrypted = false;
    String? s;
    if (indexType == EventIndexType.outArcIndex) {
      throw const SystemException(HRes.eFail);
    }
    if (indexType == EventIndexType.inArcIndex) {
      if (index != -1) {
        final items = arcItems;
        if (items != null) {
          s = items[index].name;
        } else if (arc != null) {
          s = arc!.getItemPath(index);
        }
        final a = archive;
        if (a != null) {
          isEncrypted = archiveGetItemBoolProp(a, index, Kpid.encrypted);
        }
      }
    } else if (indexType == EventIndexType.blockIndex) {
      s = '#$index';
    }
    callback.reportExtractResult(opRes, isEncrypted, s ?? '');
  }

  @override
  String? cryptoGetTextPassword2() => callback.cryptoGetTextPassword2();

  @override
  String cryptoGetTextPassword() => callback.cryptoGetTextPassword();
}

