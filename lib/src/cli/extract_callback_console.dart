// Console output of the extract group commands: Console/ExtractCallbackConsole
// .cpp of the LZMA SDK (CExtractScanConsole, CExtractCallbackConsole and the
// helpers that print sizes, item counts and error flags).

import '../format/archive_types.dart';
import 'archive_extract_callback.dart';
import 'common.dart';
import 'console.dart';
import 'enum_dir_items.dart';
import 'extract.dart' show ExtractCallbackUI;
import 'list.dart';
import 'load_codecs.dart';
import 'open_archive.dart';
import 'prop_id_utils.dart';
import 'std_stream.dart';
import 'platform.dart';

const String _kError = 'ERROR: ';

/// CExtractScanConsole.
class ExtractScanConsole implements DirItemsCallback {
  StdOutStream? _so;
  StdOutStream? _se;
  final PercentPrinter _percent = PercentPrinter();

  bool _needPercents() => _percent.so != null && !_percent.disablePrint;

  void _closePercentsAndFlush() {
    if (_needPercents()) _percent.closePrint(true);
    _so?.flush();
  }

  void init(StdOutStream? outStream, StdOutStream? errorStream,
      StdOutStream? percentStream, bool disablePercents) {
    _so = outStream;
    _se = errorStream;
    _percent.so = percentStream;
    _percent.disablePrint = disablePercents;
  }

  void setWindowWidth(int width) => _percent.maxLen = width - 1;

  // StartScanning
  void startScanning() {
    if (_needPercents()) _percent.command = 'Scan';
  }

  @override
  void scanProgress(DirItemsStat st, String path, bool isDir) {
    if (_needPercents()) {
      _percent.files = st.numDirs + st.numFiles;
      _percent.completed = st.getTotalBytes();
      _percent.fileName = path;
      _percent.print();
    }
    checkBreak2();
  }

  @override
  void scanError(String path, int systemError) {
    _closePercentsAndFlush();
    final se = _se;
    if (se != null) {
      se.endl();
      se.write('$_kError${myFormatMessage(systemError)}');
      se.endl();
      se.normalizePrintPath(path);
      se.endl();
      se.endl();
      se.flush();
    }
    throw SystemException(hresultFromErrno(systemError));
  }

  // CloseScanning
  void closeScanning() {
    if (_needPercents()) _percent.closePrint(true);
  }

  // PrintStat
  void printStat(DirItemsStat st) {
    _so?.write('${printDirItemsStat(st)}\n');
  }
}

/// Print_UInt64_and_String.
String printUInt64AndString(int val, String name) => '${u64ToString(val)} $name';

/// PrintSize_bytes_Smart.
String printSizeBytesSmart(int val) {
  var s = printUInt64AndString(val, 'bytes');
  if (val == 0) return s;
  var numBits = 10;
  var c = 'K';
  if (compareU64(val, 10 << 30) >= 0) {
    numBits = 30;
    c = 'G';
  } else if (compareU64(val, 10 << 20) >= 0) {
    numBits = 20;
    c = 'M';
  }
  s += ' (${printUInt64AndString((val + (1 << numBits) - 1) >>> numBits, '${c}iB')})';
  return s;
}

// PrintSize_bytes_Smart_comma
String _printSizeBytesSmartComma(int val) {
  if (val == -1) return '';
  return ', ${printSizeBytesSmart(val)}';
}

/// Print_DirItemsStat.
String printDirItemsStat(DirItemsStat st) {
  final s = StringBuffer();
  if (st.numDirs != 0) {
    s.write(printUInt64AndString(
        st.numDirs, st.numDirs == 1 ? 'folder' : 'folders'));
    s.write(', ');
  }
  s.write(printUInt64AndString(st.numFiles, st.numFiles == 1 ? 'file' : 'files'));
  s.write(_printSizeBytesSmartComma(st.filesSize));
  if (st.numAltStreams != 0) {
    s.write('\n');
    s.write(printUInt64AndString(st.numAltStreams, 'alternate streams'));
    s.write(_printSizeBytesSmartComma(st.altStreamsSize));
  }
  return s.toString();
}

/// Print_DirItemsStat2.
String printDirItemsStat2(DirItemsStat2 st) {
  final s = StringBuffer(printDirItemsStat(st));
  var needLF = true;
  if (st.antiNumDirs != 0) {
    if (needLF) s.write('\n');
    needLF = false;
    s.write(printUInt64AndString(
        st.antiNumDirs, st.antiNumDirs == 1 ? 'anti-folder' : 'anti-folders'));
  }
  if (st.antiNumFiles != 0) {
    if (needLF) {
      s.write('\n');
    } else {
      s.write(', ');
    }
    needLF = false;
    s.write(printUInt64AndString(
        st.antiNumFiles, st.antiNumFiles == 1 ? 'anti-file' : 'anti-files'));
  }
  if (st.antiNumAltStreams != 0) {
    if (needLF) {
      s.write('\n');
    } else {
      s.write(', ');
    }
    needLF = false;
    s.write(
        printUInt64AndString(st.antiNumAltStreams, 'anti-alternate-streams'));
  }
  return s.toString();
}

const List<String> _kErrorFlagsMessages = [
  'Is not archive',
  'Headers Error',
  'Headers Error in encrypted archive. Wrong password?',
  'Unavailable start of archive',
  'Unconfirmed start of archive',
  'Unexpected end of archive',
  'There are data after the end of archive',
  'Unsupported method',
  'Unsupported feature',
  'Data Error',
  'CRC Error',
];

// GetOpenArcErrorMessage
String _getOpenArcErrorMessage(int errorFlags) {
  final s = StringBuffer();
  for (var i = 0; i < _kErrorFlagsMessages.length; i++) {
    final f = 1 << i;
    if ((errorFlags & f) == 0) continue;
    if (s.isNotEmpty) s.write('\n');
    s.write(_kErrorFlagsMessages[i]);
    errorFlags &= ~f;
  }
  if (errorFlags != 0) {
    if (s.isNotEmpty) s.write('\n');
    s.write('0x${hexUpper(errorFlags)}');
  }
  return s.toString();
}

/// PrintErrorFlags.
void printErrorFlags(StdOutStream so, String s, int errorFlags) {
  if (errorFlags == 0) return;
  so.write('$s\n${_getOpenArcErrorMessage(errorFlags)}\n');
}

// Add_Messsage_Pre_ArcType
String _addMesssagePreArcType(String pre, String arcType) =>
    '\n$pre as [$arcType] archive';

/// Print_ErrorFormatIndex_Warning.
void printErrorFormatIndexWarning(StdOutStream so, Codecs codecs, Arc arc) {
  final er = arc.errorInfo;
  so.write('WARNING:\n');
  so.normalizePrintPath(arc.path);
  String s;
  if (arc.formatIndex == er.errorFormatIndex) {
    s = '\nThe archive is open with offset';
  } else {
    s = _addMesssagePreArcType('Cannot open the file',
            codecs.getFormatNamePtr(er.errorFormatIndex)) +
        _addMesssagePreArcType(
            'The file is open', codecs.getFormatNamePtr(arc.formatIndex));
  }
  so.write('$s\n\n');
}

/// SetExtractErrorMessage.
String setExtractErrorMessage(int opRes, bool encrypted) {
  String? s;
  switch (opRes) {
    case OperationResult.unsupportedMethod:
      s = 'Unsupported Method';
    case OperationResult.crcError:
      s = encrypted ? 'CRC Failed in encrypted file. Wrong password?' : 'CRC Failed';
    case OperationResult.dataError:
      s = encrypted
          ? 'Data Error in encrypted file. Wrong password?'
          : 'Data Error';
    case OperationResult.unavailable:
      s = 'Unavailable data';
    case OperationResult.unexpectedEnd:
      s = 'Unexpected end of data';
    case OperationResult.dataAfterEnd:
      s = 'There are some data after the end of the payload data';
    case OperationResult.isNotArc:
      s = 'Is not archive';
    case OperationResult.headersError:
      s = 'Headers Error';
    case OperationResult.wrongPassword:
      s = 'Wrong password';
  }
  return _kError + (s ?? 'Error #$opRes');
}

const String _kTab = '  ';

// PrintFileInfo
void _printFileInfo(StdOutStream so, String path, int? ft, int? size) {
  so.write('${_kTab}Path:     ');
  so.normalizePrintPath(path);
  so.endl();
  if (size != null && size != -1) {
    so.write('${_kTab}Size:     ${printSizeBytesSmart(size)}\n');
  }
  if (ft != null) {
    final temp = convertUtcFileTimeToString(ft, kTimestampPrintLevelSec);
    if (temp != null) so.write('${_kTab}Modified: $temp\n');
  }
}

/// CExtractCallbackConsole.
class ExtractCallbackConsole extends OpenCallbackConsole
    implements ExtractCallbackUI {
  bool _needWriteArchivePath = true;
  bool thereIsErrorInCurrent = false;
  bool thereIsWarningInCurrent = false;
  bool needFlush = false;
  String _currentArchivePath = '';
  String _currentName = '';

  int numTryArcs = 0;
  int numOkArcs = 0;
  int numCantOpenArcs = 0;
  int numArcsWithError = 0;
  int numArcsWithWarnings = 0;
  int numOpenArcErrors = 0;
  int numOpenArcWarnings = 0;
  int numFileErrors = 0;
  int numFileErrorsInCurrent = 0;
  int percentsNameLevel = 1;
  int logLevel = 0;

  void setWindowWidth(int width) => percent.maxLen = width - 1;

  void _closePercentsForSo() {
    if (needPercents() && so == percent.so) percent.closePrint(false);
  }

  void _closePercentsAndFlush() {
    if (needPercents()) percent.closePrint(true);
    so?.flush();
  }

  // Init
  @override
  void init(StdOutStream? outStream, StdOutStream? errorStream,
      StdOutStream? percentStream, bool disablePercents, StdInStream sin) {
    super.init(outStream, errorStream, percentStream, disablePercents, sin);
    numTryArcs = 0;
    thereIsErrorInCurrent = false;
    thereIsWarningInCurrent = false;
    numOkArcs = 0;
    numCantOpenArcs = 0;
    numArcsWithError = 0;
    numArcsWithWarnings = 0;
    numOpenArcErrors = 0;
    numOpenArcWarnings = 0;
    numFileErrors = 0;
    numFileErrorsInCurrent = 0;
  }

  @override
  void setTotal(int size) {
    if (needPercents()) {
      percent.total = size;
      percent.print();
    }
    checkBreak2();
  }

  @override
  void setCompleted(int? completeValue) {
    if (needPercents()) {
      if (completeValue != null) percent.completed = completeValue;
      percent.print();
    }
    checkBreak2();
  }

  @override
  OverwriteAnswer askOverwrite(String existName, int? existTime,
      int? existSize, String newName, int? newTime, int? newSize) {
    checkBreak2();
    _closePercentsAndFlush();
    final so = this.so;
    if (so != null) {
      so.write('\nWould you like to replace the existing file:\n');
      _printFileInfo(so, existName, existTime, existSize);
      so.write('with the file from archive:\n');
      _printFileInfo(so, newName, newTime, newSize);
    }
    final overwriteAnswer = scanUserYesNoAllQuit(so, stdIn);
    OverwriteAnswer answer;
    switch (overwriteAnswer) {
      case UserAnswerMode.quit:
        throw const SystemException(HRes.eAbort);
      case UserAnswerMode.no:
        answer = OverwriteAnswer.no;
      case UserAnswerMode.noAll:
        answer = OverwriteAnswer.noToAll;
      case UserAnswerMode.yesAll:
        answer = OverwriteAnswer.yesToAll;
      case UserAnswerMode.yes:
        answer = OverwriteAnswer.yes;
      case UserAnswerMode.autoRenameAll:
        answer = OverwriteAnswer.autoRename;
      case UserAnswerMode.eof:
        throw const SystemException(HRes.eAbort);
      case UserAnswerMode.error:
        throw const SystemException(HRes.eFail);
    }
    if (so != null) {
      so.endl();
      if (needFlush) so.flush();
    }
    checkBreak2();
    return answer;
  }

  @override
  void prepareOperation(
      String name, bool isFolder, int askExtractMode, int? position) {
    _currentName = name;
    String s;
    var requiredLevel = 1;
    switch (askExtractMode) {
      case AskMode.extract:
        s = '-';
      case AskMode.test:
        s = 'T';
      case AskMode.skip:
        s = '.';
        requiredLevel = 2;
      case AskMode.readExternal:
        s = 'H';
        requiredLevel = 0;
      default:
        s = '???';
        requiredLevel = 2;
    }
    final so = this.so;
    final show2 = logLevel >= requiredLevel && so != null;
    if (show2) {
      _closePercentsForSo();
      so.write('$s ');
      var tempU = so.normalizeStringPath(name);
      if (isFolder) {
        if (tempU.isNotEmpty && !tempU.endsWith(kDirSep)) tempU += kDirSep;
      }
      so.write(tempU);
      if (position != null) so.write(' <${u64ToString(position)}>');
      so.endl();
      if (needFlush) so.flush();
    }
    if (needPercents()) {
      if (percentsNameLevel >= 1) {
        percent.fileName = '';
        percent.command = '';
        if (percentsNameLevel > 1 || !show2) {
          percent.command = s;
          percent.fileName = name;
        }
      }
      percent.print();
    }
    checkBreak2();
  }

  @override
  void messageError(String message) {
    checkBreak2();
    numFileErrorsInCurrent++;
    numFileErrors++;
    _closePercentsAndFlush();
    final se = this.se;
    if (se != null) {
      se.write('$_kError$message\n');
      se.flush();
    }
    checkBreak2();
  }

  @override
  void setOperationResult(int opRes, bool encrypted) {
    if (opRes == OperationResult.ok) {
      if (needPercents()) {
        percent.command = '';
        percent.fileName = '';
        percent.files++;
      }
    } else {
      numFileErrorsInCurrent++;
      numFileErrors++;
      final se = this.se;
      if (se != null) {
        _closePercentsAndFlush();
        se.write(setExtractErrorMessage(opRes, encrypted));
        if (_currentName.isNotEmpty) {
          se.write(' : ');
          se.normalizePrintPath(_currentName);
        }
        se.endl();
        se.flush();
      }
    }
    checkBreak2();
  }

  @override
  void reportExtractResult(int opRes, bool encrypted, String name) {
    if (opRes != OperationResult.ok) {
      _currentName = name;
      setOperationResult(opRes, encrypted);
      return;
    }
    checkBreak2();
  }

  @override
  String cryptoGetTextPassword() => openCryptoGetTextPassword();

  @override
  void beforeOpen(String name, bool testMode) {
    _currentArchivePath = name;
    _needWriteArchivePath = true;
    checkBreak2();
    numTryArcs++;
    thereIsErrorInCurrent = false;
    thereIsWarningInCurrent = false;
    numFileErrorsInCurrent = 0;
    _closePercentsForSo();
    final so = this.so;
    if (so != null) {
      so.write(testMode ? '\nTesting archive: ' : '\nExtracting archive: ');
      so.normalizePrintPath(name);
      so.endl();
    }
    if (needPercents()) percent.command = 'Open';
  }

  @override
  void openResult(Codecs codecs, ArchiveLink arcLink, String name, int result) {
    _currentArchivePath = name;
    _needWriteArchivePath = true;
    closePercents();
    if (needPercents()) {
      percent.files = 0;
      percent.command = '';
      percent.fileName = '';
    }
    _closePercentsAndFlush();

    final so = this.so;
    final se = this.se;
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
          numOpenArcErrors++;
          thereIsErrorInCurrent = true;
        }
        if (er.errorMessage.isNotEmpty) {
          if (se != null) {
            se.write('ERRORS:\n');
            se.normalizePrint(er.errorMessage);
            se.endl();
          }
          numOpenArcErrors++;
          thereIsErrorInCurrent = true;
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
            so.endl();
          }
        }
        if (warningFlags != 0) {
          if (so != null) printErrorFlags(so, 'WARNINGS:', warningFlags);
          numOpenArcWarnings++;
          thereIsWarningInCurrent = true;
        }
        if (er.warningMessage.isNotEmpty) {
          if (so != null) {
            so.write('WARNINGS:\n');
            so.normalizePrint(er.warningMessage);
            so.endl();
          }
          numOpenArcWarnings++;
          thereIsWarningInCurrent = true;
        }
        if (so != null) {
          so.endl();
          if (needFlush) so.flush();
        }
      }

      if (er.errorFormatIndex >= 0) {
        if (so != null) {
          printErrorFormatIndexWarning(so, codecs, arc);
          if (needFlush) so.flush();
        }
        thereIsWarningInCurrent = true;
      }
    }

    if (result == HRes.sOk) {
      if (so != null) {
        printOpenArchiveProps(so, codecs, arcLink);
        so.endl();
      }
    } else {
      numCantOpenArcs++;
      so?.flush();
      if (se != null) {
        se.write(_kError);
        se.normalizePrintPath(name);
        se.endl();
        printOpenArchiveError(se, codecs, arcLink);
        if (result != HRes.sFalse) {
          if (result == HRes.eOutOfMemory) {
            se.write("Can't allocate required memory");
          } else {
            se.write(myFormatMessage(result));
          }
          se.endl();
        }
        se.flush();
      }
    }
    checkBreak2();
  }

  @override
  void thereAreNoFiles() {
    _closePercentsForSo();
    final so = this.so;
    if (so != null) {
      so.write('\nNo files to process\n');
      if (needFlush) so.flush();
    }
    checkBreak2();
  }

  @override
  void extractResult(int result) {
    if (needPercents()) {
      percent.closePrint(true);
      percent.command = '';
      percent.fileName = '';
    }
    so?.flush();
    if (result == HRes.sOk) {
      if (numFileErrorsInCurrent == 0 && !thereIsErrorInCurrent) {
        if (thereIsWarningInCurrent) {
          numArcsWithWarnings++;
        } else {
          numOkArcs++;
        }
        so?.write('Everything is Ok\n');
      } else {
        numArcsWithError++;
        final so = this.so;
        if (so != null) {
          so.endl();
          if (numFileErrorsInCurrent != 0) {
            so.write('Sub items Errors: $numFileErrorsInCurrent\n');
          }
        }
      }
      if (so != null && needFlush) so!.flush();
    } else {
      if (result == HRes.eAbort || result == hresultFromErrno(Errno.enospc)) {
        throw SystemException(result);
      }
      numArcsWithError++;
      final se = this.se;
      if (se != null) {
        se.endl();
        se.write(_kError);
        if (result == HRes.eOutOfMemory) {
          se.write("Can't allocate required memory!");
        } else {
          se.write(myFormatMessage(result));
        }
        se.endl();
        se.flush();
      }
    }
    checkBreak2();
  }

  /// Add_ArchiveName_Error (for memory messages).
  void addArchiveNameError() {
    if (_needWriteArchivePath) {
      se?.write('Archive: ');
      se?.normalizePrintPath(_currentArchivePath);
      se?.endl();
      _needWriteArchivePath = false;
    }
  }
}

