// Console output of the update commands: Console/UpdateCallbackConsole.cpp
// of the LZMA SDK (CCallbackConsoleBase, CUpdateCallbackConsole).

import '../format/archive_types.dart';
import 'common.dart';
import 'console.dart';
import 'enum_dir_items.dart';
import 'extract_callback_console.dart';
import 'list.dart';
import 'load_codecs.dart';
import 'open_archive.dart';
import 'std_stream.dart';
import 'update.dart';
import 'update_callback.dart';
import 'platform.dart';

const String _kEmptyFileAlias = '[Content]';
const String _kError = 'ERROR: ';
const String _kWarning = 'WARNING: ';

/// CErrorPathCodes.
class ErrorPathCodes {
  final List<String> paths = [];
  final List<int> codes = [];
  void addError(String path, int systemError) {
    paths.add(path);
    codes.add(systemError);
  }

  void clear() {
    paths.clear();
    codes.clear();
  }
}

/// CCallbackConsoleBase.
class CallbackConsoleBase {
  StdOutStream? so;
  StdOutStream? se;
  bool stdOutMode = false;
  bool needFlush = false;
  int percentsNameLevel = 1;
  int logLevel = 0;
  final PercentPrinter percent = PercentPrinter();
  final ErrorPathCodes failedFiles = ErrorPathCodes();
  final ErrorPathCodes scanErrors = ErrorPathCodes();
  int numNonOpenFiles = 0;

  bool needPercents() => percent.so != null;
  void setWindowWidth(int width) => percent.maxLen = width - 1;

  void initBase(StdOutStream? outStream, StdOutStream? errorStream,
      StdOutStream? percentStream, bool disablePercents) {
    failedFiles.clear();
    so = outStream;
    se = errorStream;
    percent.so = percentStream;
    percent.disablePrint = disablePercents;
  }

  void closePercents2() {
    if (needPercents()) percent.closePrint(true);
  }

  void closePercentsForSo() {
    if (needPercents() && so == percent.so) percent.closePrint(false);
  }

  // CommonError
  void _commonError(String path, int systemError, bool isWarning) {
    closePercents2();
    final se = this.se;
    if (se != null) {
      so?.flush();
      se.write('\n${isWarning ? _kWarning : _kError}'
          '${myFormatMessage(systemError)}\n');
      se.normalizePrintPath(path);
      se.write('\n\n');
      se.flush();
    }
  }

  // ScanError_Base
  void scanErrorBase(String path, int systemError) {
    scanErrors.addError(path, systemError);
    _commonError(path, systemError, true);
  }

  // OpenFileError_Base: S_FALSE
  void openFileErrorBase(String path, int systemError) {
    failedFiles.addError(path, systemError);
    numNonOpenFiles++;
    _commonError(path, systemError, true);
  }

  // ReadingFileError_Base
  int readingFileErrorBase(String path, int systemError) {
    _commonError(path, systemError, false);
    return hresultFromErrno(systemError);
  }

  // PrintProgress
  void printProgress(String? name, bool isDir, String command, bool showInLog) {
    final so = this.so;
    final show2 = showInLog && so != null;
    if (show2) {
      closePercentsForSo();
      so.write(name != null ? '$command ' : command);
      var tempU = '';
      if (name != null) {
        tempU = name;
        if (isDir) tempU = normalizeDirPathPrefix(tempU);
        tempU = so.normalizeStringPath(tempU);
      }
      so.write(tempU);
      so.endl();
      if (needFlush) so.flush();
    }
    if (needPercents()) {
      if (percentsNameLevel >= 1) {
        percent.fileName = '';
        percent.command = '';
        if (percentsNameLevel > 1 || !show2) {
          percent.command = command;
          if (name != null) percent.fileName = name;
        }
      }
      percent.print();
    }
    checkBreak2();
  }
}

/// CUpdateCallbackConsole.
class UpdateCallbackConsole extends UpdateCallbackUI2 with CallbackConsoleBaseMix {
  int _arcMovingTotal = 0;
  int _arcMovingCurrent = 0;
  int _arcMovingPercents = 0;
  bool _arcMovingUpdateMode = false;
  bool deleteMessageWasShown = false;

  bool passwordIsDefined = false;
  bool askPassword = false;
  String password = '';
  late StdInStream stdIn;

  void init(StdOutStream? outStream, StdOutStream? errorStream,
      StdOutStream? percentStream, bool disablePercents, StdInStream sin) {
    base.initBase(outStream, errorStream, percentStream, disablePercents);
    stdIn = sin;
  }

  @override
  void openResult(Codecs codecs, ArchiveLink arcLink, String name, int result) {
    base.closePercents2();
    final so = base.so;
    final se = base.se;
    for (var level = 0; level < arcLink.arcs.length; level++) {
      final arc = arcLink.arcs[level];
      final er = arc.errorInfo;
      final errorFlags = er.getErrorFlags();
      if (errorFlags != 0 || er.errorMessage.isNotEmpty) {
        if (se != null) {
          se.endl();
          if (level != 0) {
            se.normalizePrintPath(arc.path);
            se.endl();
          }
        }
        if (errorFlags != 0) {
          if (se != null) printErrorFlags(se, 'ERRORS:', errorFlags);
        }
        if (er.errorMessage.isNotEmpty) {
          if (se != null) {
            se.write('ERRORS:\n');
            se.normalizePrint(er.errorMessage);
            se.endl();
          }
        }
        if (se != null) {
          se.endl();
          se.flush();
        }
      }
      final warningFlags = er.getWarningFlags();
      if (warningFlags != 0 || er.warningMessage.isNotEmpty) {
        if (so != null) {
          so.endl();
          if (level != 0) {
            so.normalizePrintPath(arc.path);
            so.write('${arc.path}\n');
          }
        }
        if (warningFlags != 0) {
          if (so != null) printErrorFlags(so, 'WARNINGS:', warningFlags);
        }
        if (er.warningMessage.isNotEmpty) {
          if (so != null) {
            so.write('WARNINGS:\n');
            so.normalizePrint(er.warningMessage);
            so.endl();
          }
        }
        if (so != null) {
          so.endl();
          if (base.needFlush) so.flush();
        }
      }
      if (er.errorFormatIndex >= 0) {
        if (so != null) {
          printErrorFormatIndexWarning(so, codecs, arc);
          if (base.needFlush) so.flush();
        }
      }
    }
    if (result == HRes.sOk) {
      if (so != null) {
        printOpenArchiveProps(so, codecs, arcLink);
        so.endl();
      }
    } else {
      so?.flush();
      if (se != null) {
        se.write(_kError);
        se.normalizePrintPath(name);
        se.endl();
        printOpenArchiveError(se, codecs, arcLink);
        se.flush();
      }
    }
  }

  @override
  void startScanning() {
    base.so?.write('Scanning the drive:\n');
    base.percent.command = 'Scan ';
  }

  @override
  void scanProgress(DirItemsStat st, String path, bool isDir) {
    if (base.needPercents()) {
      final p = base.percent;
      p.files = st.numDirs + st.numFiles + st.numAltStreams;
      p.completed = st.getTotalBytes();
      p.fileName = path;
      p.print();
    }
    checkBreak();
  }

  @override
  void scanError(String path, int systemError) =>
      base.scanErrorBase(path, systemError);

  @override
  void finishScanning(DirItemsStat st) {
    if (base.needPercents()) {
      base.percent.closePrint(true);
      base.percent.clearCurState();
    }
    base.so?.write('${printDirItemsStat(st)}\n\n');
  }

  @override
  void startOpenArchive(String? name) {
    final so = base.so;
    if (so != null) {
      so.write('Open archive: ');
      if (name != null) {
        so.normalizePrintPath(name);
      } else {
        so.write('StdOut');
      }
      so.endl();
    }
  }

  @override
  void startArchive(String? name, bool updating) {
    if (base.needPercents()) base.percent.closePrint(true);
    base.percent.clearCurState();
    base.numNonOpenFiles = 0;
    final so = base.so;
    if (so != null) {
      so.write(updating ? 'Updating archive: ' : 'Creating archive: ');
      if (name != null) {
        so.normalizePrintPath(name);
      } else {
        so.write('StdOut');
      }
      so.write('\n\n');
    }
  }

  @override
  void finishArchive(FinishArchiveStat st) {
    base.closePercents2();
    final so = base.so;
    if (so != null) {
      final s = StringBuffer();
      s.write('Files read from disk: '
          '${u64ToString(base.percent.files - base.numNonOpenFiles)}');
      s.write('\n');
      s.write('Archive size: ${printSizeBytesSmart(st.outArcFileSize)}');
      s.write('\n');
      if (st.isMultiVolMode) {
        s.write('Volumes: ${st.numVolumes}\n');
      }
      so.endl();
      so.write(s.toString());
    }
  }

  // MoveArc_UpdateStatus
  void _moveArcUpdateStatus() {
    if (base.needPercents()) {
      final s = StringBuffer(' : $_arcMovingPercents%');
      final totalDefined = _arcMovingTotal != 0 && _arcMovingTotal != -1;
      if (_arcMovingCurrent != 0 || totalDefined) {
        s.write(' : ${_arcMovingCurrent >> 20} MiB');
      }
      if (totalDefined) {
        s.write(' / ${(_arcMovingTotal + ((1 << 20) - 1)) >> 20} MiB');
      }
      s.write(' : temporary archive moving ...');
      base.percent.command = s.toString();
      base.percent.print();
    }
    if (gBreakCounter == 1 && _arcMovingUpdateMode) return;
    checkBreak();
  }

  @override
  void moveArcStart(
      String srcTempPath, String destFinalPath, int size, bool updateMode) {
    _arcMovingUpdateMode = updateMode;
    _arcMovingTotal = size;
    _arcMovingCurrent = 0;
    _arcMovingPercents = 0;
    _moveArcUpdateStatus();
  }

  @override
  void moveArcProgress(int totalSize, int currentSize) {
    var percents = 0;
    if (totalSize != 0) {
      if (totalSize < (1 << 57)) {
        percents = currentSize * 100 ~/ totalSize;
      } else {
        percents = currentSize ~/ (totalSize ~/ 100);
      }
    }
    if (percents == _arcMovingPercents) {
      checkBreak();
      return;
    }
    _arcMovingCurrent = currentSize;
    _arcMovingTotal = totalSize;
    _arcMovingPercents = percents;
    _moveArcUpdateStatus();
  }

  @override
  void moveArcFinish() {
    if (base.needPercents()) {
      base.percent.command = '';
      base.percent.print();
    }
    checkBreak();
  }

  @override
  void deletingAfterArchiving(String path, bool isDir) {
    final so = base.so;
    if (base.logLevel > 0 && so != null) {
      base.closePercentsForSo();
      if (!deleteMessageWasShown) {
        so.write('\n: Removing files after including to archive\n');
      }
      so.write('Removing ');
      so.write(so.normalizeStringPath(path));
      so.endl();
      if (base.needFlush) so.flush();
    }
    if (!deleteMessageWasShown) {
      if (base.needPercents()) base.percent.clearCurState();
      deleteMessageWasShown = true;
    } else {
      base.percent.files++;
    }
    if (base.needPercents()) {
      base.percent.command = 'Removing';
      base.percent.fileName = path;
      base.percent.print();
    }
  }

  @override
  void finishDeletingAfterArchiving() {
    base.closePercents2();
    if (base.so != null && deleteMessageWasShown) base.so!.endl();
  }

  @override
  void checkBreak() => checkBreak2();

  // PrintToDoStat
  void _printToDoStat(StdOutStream so, DirItemsStat2 stat, String name) {
    so.write('$name: ${printDirItemsStat2(stat)}\n');
  }

  @override
  void setNumItems(ArcToDoStat stat) {
    final so = base.so;
    if (so != null) {
      base.closePercentsForSo();
      if (!stat.deleteData.isEmpty) {
        so.endl();
        _printToDoStat(so, stat.deleteData, 'Delete data from archive');
      }
      if (!stat.oldData.isEmpty) {
        _printToDoStat(so, stat.oldData, 'Keep old data in archive');
      }
      _printToDoStat(so, stat.newData, 'Add new data to archive');
      so.endl();
    }
  }

  @override
  void setTotal(int size) {
    if (base.needPercents()) {
      base.percent.total = size;
      base.percent.print();
    }
  }

  @override
  void setCompleted(int completeValue) {
    if (base.needPercents()) {
      base.percent.completed = completeValue;
      base.percent.print();
    }
    checkBreak2();
  }

  @override
  void getStream(String name, bool isDir, bool isAnti, int mode) {
    if (base.stdOutMode) return;
    if (name.isEmpty) name = _kEmptyFileAlias;
    var requiredLevel = 1;
    String s;
    if (mode == UpdateNotifyOp.add || mode == UpdateNotifyOp.update) {
      if (isAnti) {
        s = 'Anti';
      } else if (mode == UpdateNotifyOp.add) {
        s = '+';
      } else {
        s = 'U';
      }
    } else {
      requiredLevel = 3;
      s = mode == UpdateNotifyOp.analyze ? 'A' : 'Reading';
    }
    base.printProgress(name, isDir, s, base.logLevel >= requiredLevel);
  }

  @override
  void openFileError(String path, int systemError) =>
      base.openFileErrorBase(path, systemError);

  @override
  int readingFileError(String path, int systemError) =>
      base.readingFileErrorBase(path, systemError);

  @override
  void setOperationResult(int opRes) {
    base.percent.files++;
  }

  @override
  void reportExtractResult(int opRes, bool isEncrypted, String name) {
    if (opRes != OperationResult.ok) {
      base.closePercents2();
      final se = base.se;
      if (se != null) {
        base.so?.flush();
        se.write('${setExtractErrorMessage(opRes, isEncrypted)} : \n');
        se.normalizePrintPath(name);
        se.write('\n\n');
        se.flush();
      }
    }
  }

  @override
  void reportUpdateOperation(int op, String? name, bool isDir) {
    String s;
    var requiredLevel = 1;
    switch (op) {
      case UpdateNotifyOp.add:
        s = '+';
      case UpdateNotifyOp.update:
        s = 'U';
      case UpdateNotifyOp.analyze:
        s = 'A';
        requiredLevel = 3;
      case UpdateNotifyOp.replicate:
        s = '=';
        requiredLevel = 3;
      case UpdateNotifyOp.repack:
        s = 'R';
        requiredLevel = 2;
      case UpdateNotifyOp.skip:
        s = '.';
        requiredLevel = 2;
      case UpdateNotifyOp.delete:
        s = 'D';
        requiredLevel = 3;
      case UpdateNotifyOp.header:
        s = 'Header creation';
        requiredLevel = 100;
      case UpdateNotifyOp.inFileChanged:
        s = 'Size of input file was changed:';
        requiredLevel = 10;
      default:
        s = 'op$op';
    }
    base.printProgress(name, isDir, s, base.logLevel >= requiredLevel);
  }

  @override
  String? cryptoGetTextPassword2() {
    if (!passwordIsDefined) {
      if (askPassword) {
        password = getPasswordHResult(base.so, stdIn);
        passwordIsDefined = true;
      }
    }
    return passwordIsDefined ? password : null;
  }

  @override
  String cryptoGetTextPassword() {
    if (!passwordIsDefined) {
      password = getPasswordHResult(base.so, stdIn);
      passwordIsDefined = true;
    }
    return password;
  }

  @override
  void showDeleteFile(String name, bool isDir) {
    if (base.stdOutMode) return;
    if (base.logLevel > 7) {
      if (name.isEmpty) name = _kEmptyFileAlias;
      base.printProgress(name, isDir, 'D', true);
    }
  }
}

/// The CCallbackConsoleBase part of CUpdateCallbackConsole.
mixin CallbackConsoleBaseMix {
  final CallbackConsoleBase base = CallbackConsoleBase();
}
