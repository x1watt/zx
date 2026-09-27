// The "l" command: Console/List.cpp of the LZMA SDK (the listing table,
// the -slt technical listing, the archive properties block and the open
// error messages).

import '../format/archive_types.dart';
import 'arc_handlers.dart';
import 'common.dart';
import 'console.dart';
import 'globals.dart';
import 'load_codecs.dart';
import 'open_archive.dart';
import 'prop_id_utils.dart';
import 'std_stream.dart';
import 'wildcard.dart';
import 'archive_extract_callback.dart' show censorNodeCheckPath;
import 'fs_utils.dart';
import 'extract_callback_console.dart'
    show printErrorFlags, printUInt64AndString;

const List<String> kPropIdToName = [
  '0',
  '1',
  '2',
  'Path',
  'Name',
  'Extension',
  'Folder',
  'Size',
  'Packed Size',
  'Attributes',
  'Created',
  'Accessed',
  'Modified',
  'Solid',
  'Commented',
  'Encrypted',
  'Split Before',
  'Split After',
  'Dictionary Size',
  'CRC',
  'Type',
  'Anti',
  'Method',
  'Host OS',
  'File System',
  'User',
  'Group',
  'Block',
  'Comment',
  'Position',
  'Path Prefix',
  'Folders',
  'Files',
  'Version',
  'Volume',
  'Multivolume',
  'Offset',
  'Links',
  'Blocks',
  'Volumes',
  'Time Type',
  '64-bit',
  'Big-endian',
  'CPU',
  'Physical Size',
  'Headers Size',
  'Checksum',
  'Characteristics',
  'Virtual Address',
  'ID',
  'Short Name',
  'Creator Application',
  'Sector Size',
  'Mode',
  'Symbolic Link',
  'Error',
  'Total Size',
  'Free Space',
  'Cluster Size',
  'Label',
  'Local Name',
  'Provider',
  'NT Security',
  'Alternate Stream',
  'Aux',
  'Deleted',
  'Tree',
  'SHA-1',
  'SHA-256',
  'Error Type',
  'Errors',
  'Errors',
  'Warnings',
  'Warning',
  'Streams',
  'Alternate Streams',
  'Alternate Streams Size',
  'Virtual Size',
  'Unpack Size',
  'Total Physical Size',
  'Volume Index',
  'SubType',
  'Short Comment',
  'Code Page',
  'Is not archive type',
  "Physical Size can't be detected",
  'Zeros Tail Is Allowed',
  'Tail Size',
  'Embedded Stub Size',
  'Link',
  'Hard Link',
  'iNode',
  'Stream ID',
  'Read-only',
  'Out Name',
  'Copy Link',
  'ArcFileName',
  'IsHash',
  'Metadata Changed',
  'User ID',
  'Group ID',
  'Device Major',
  'Device Minor',
  'Dev Major',
  'Dev Minor',
];

const String _kEmptyAttribChar = '.';
const String _kListing = 'Listing archive: ';
const String _kStringFiles = 'files';
const String _kStringDirs = 'folders';
const String _kStringAltStreams = 'alternate streams';
const String _kStringStreams = 'streams';
const String _kError = 'ERROR: ';

// GetAttribString
String _getAttribString(int wa, bool isDir, bool allAttribs) {
  if (isDir) wa |= FileAttrib.directory;
  if (allAttribs) return convertWinAttribToString(wa);
  return ((wa & FileAttrib.directory) != 0 ? 'D' : _kEmptyAttribChar) +
      ((wa & FileAttrib.readOnly) != 0 ? 'R' : _kEmptyAttribChar) +
      ((wa & FileAttrib.hidden) != 0 ? 'H' : _kEmptyAttribChar) +
      ((wa & FileAttrib.system) != 0 ? 'S' : _kEmptyAttribChar) +
      ((wa & FileAttrib.archive) != 0 ? 'A' : _kEmptyAttribChar);
}

/// EAdjustment.
enum Adjustment { left, center, right }

/// CFieldInfo.
class _FieldInfo {
  int propId = 0;
  String nameA = '';
  Adjustment titleAdjustment = Adjustment.left;
  Adjustment textAdjustment = Adjustment.left;
  int prefixSpacesWidth = 0;
  int width = 0;
}

class _FieldInfoInit {
  final int propId;
  final String name;
  final Adjustment titleAdjustment;
  final Adjustment textAdjustment;
  final int prefixSpacesWidth;
  final int width;
  const _FieldInfoInit(this.propId, this.name, this.titleAdjustment,
      this.textAdjustment, this.prefixSpacesWidth, this.width);
}

const List<_FieldInfoInit> _kStandardFieldTable = [
  _FieldInfoInit(Kpid.mTime, '   Date      Time', Adjustment.left,
      Adjustment.left, 0, 19),
  _FieldInfoInit(
      Kpid.attrib, 'Attr', Adjustment.right, Adjustment.center, 1, 5),
  _FieldInfoInit(Kpid.size, 'Size', Adjustment.right, Adjustment.right, 1, 12),
  _FieldInfoInit(
      Kpid.packSize, 'Compressed', Adjustment.right, Adjustment.right, 1, 12),
  _FieldInfoInit(Kpid.path, 'Name', Adjustment.left, Adjustment.left, 2, 24),
];

const int _kNumSpacesMax = 32;

// PrintSpaces
void _printSpaces(int numSpaces) {
  if (numSpaces > 0 && numSpaces <= _kNumSpacesMax) gStdOut.write(' ' * numSpaces);
}

// PrintString / PrintStringToString / PrintUString: aligned text.
String _alignString(Adjustment adj, int width, String s) {
  var numSpaces = 0;
  var numLeftSpaces = 0;
  if (width > s.length) {
    numSpaces = width - s.length;
    switch (adj) {
      case Adjustment.center:
        numLeftSpaces = numSpaces ~/ 2;
      case Adjustment.right:
        numLeftSpaces = numSpaces;
      case Adjustment.left:
        break;
    }
    numSpaces -= numLeftSpaces;
  }
  return ' ' * numLeftSpaces + s + ' ' * numSpaces;
}

void _printString(Adjustment adj, int width, String s) {
  var numSpaces = 0;
  if (width > s.length) {
    numSpaces = width - s.length;
    var numLeftSpaces = 0;
    switch (adj) {
      case Adjustment.center:
        numLeftSpaces = numSpaces ~/ 2;
      case Adjustment.right:
        numLeftSpaces = numSpaces;
      case Adjustment.left:
        break;
    }
    _printSpaces(numLeftSpaces);
    numSpaces -= numLeftSpaces;
  }
  gStdOut.write(s);
  _printSpaces(numSpaces);
}

/// CListUInt64Def.
class _ListUInt64Def {
  int val = 0;
  bool def = false;
  void add(int v) {
    val += v;
    def = true;
  }

  void addDef(_ListUInt64Def v) {
    if (v.def) add(v.val);
  }
}

/// CListStat.
class _ListStat {
  final _ListUInt64Def size = _ListUInt64Def();
  final _ListUInt64Def packSize = _ListUInt64Def();
  final ArcTime mTime = ArcTime();
  int numFiles = 0;

  void update(_ListStat st) {
    size.addDef(st.size);
    packSize.addDef(st.packSize);
    // CListFileTimeDef::Update
    if (st.mTime.def && (!mTime.def || mTime.compareWith(st.mTime) < 0)) {
      mTime.copyFrom(st.mTime);
    }
    numFiles += st.numFiles;
  }

  void setSizeDefIfNoFiles() {
    if (numFiles == 0) size.def = true;
  }

  _ListStat copy() => _ListStat()..update(this);
}

/// CListStat2.
class _ListStat2 {
  final _ListStat mainFiles = _ListStat();
  final _ListStat altStreams = _ListStat();
  int numDirs = 0;

  void update(_ListStat2 st) {
    mainFiles.update(st.mainFiles);
    altStreams.update(st.altStreams);
    numDirs += st.numDirs;
  }

  int getNumStreams() => mainFiles.numFiles + altStreams.numFiles;
  _ListStat getStat(bool altStreamsMode) =>
      altStreamsMode ? altStreams : mainFiles;
}

// PrintTime
String _printTime(ArcTime t, bool showNS) {
  if (t.isZero) return '';
  var prec = kTimestampPrintLevelSec;
  var flags = 0;
  if (showNS) {
    prec = kTimestampPrintLevelNtfs;
    if (t.prec != 0) {
      prec = t.getNumDigits();
      if (prec < kTimestampPrintLevelDay) prec = kTimestampPrintLevelNtfs;
    }
  } else {
    flags = kTimestampPrintFlagsDisableZ;
  }
  return convertUtcFileTimeToString2(t.ft, t.ns100, prec, flags) ?? '';
}

// IsPropId_for_PathString
bool _isPropIdForPathString(int propId) =>
    propId == Kpid.path ||
    propId == Kpid.symLink ||
    propId == Kpid.hardLink ||
    propId == Kpid.copyLink;

// GetPropName
String _getPropName(int propId) {
  if (propId < kPropIdToName.length) return kPropIdToName[propId];
  // not in 7-Zip: the names of the zx properties
  return kZxPropNames[propId] ?? '$propId';
}

/// CFieldPrinter.
class _FieldPrinter {
  final List<_FieldInfo> _fields = [];
  Arc? arc;
  bool techMode = false;
  String filePath = '';
  bool isDir = false;
  String linesString = '';

  void clear() {
    _fields.clear();
    linesString = '';
  }

  // Init
  void init(List<_FieldInfoInit> table) {
    clear();
    final ls = StringBuffer();
    for (final fii in table) {
      final f = _FieldInfo()
        ..propId = fii.propId
        ..nameA = fii.name
        ..titleAdjustment = fii.titleAdjustment
        ..textAdjustment = fii.textAdjustment
        ..prefixSpacesWidth = fii.prefixSpacesWidth
        ..width = fii.width;
      _fields.add(f);
      ls.write(' ' * fii.prefixSpacesWidth);
      ls.write('-' * fii.width);
    }
    linesString = ls.toString();
  }

  // AddProp
  void _addProp(int propId) {
    _fields.add(_FieldInfo()
      ..propId = propId
      ..nameA = '${_getPropName(propId)} = ');
  }

  // AddMainProps
  void addMainProps(InArchive archive) {
    for (final pid in archive.itemPropIds) {
      _addProp(pid);
    }
  }

  // PrintTitle
  void printTitle() {
    for (final f in _fields) {
      _printSpaces(f.prefixSpacesWidth);
      _printString(
          f.titleAdjustment, f.propId == Kpid.path ? 0 : f.width, f.nameA);
    }
  }

  // PrintTitleLines
  void printTitleLines() => gStdOut.write(linesString);

  // PrintItemInfo
  void printItemInfo(int index, _ListStat st) {
    final temp = StringBuffer();
    final archive = arc!.archive!;
    for (final f in _fields) {
      if (!techMode) temp.write(' ' * f.prefixSpacesWidth);
      if (techMode) gStdOut.write(f.nameA);

      if (f.propId == Kpid.path) {
        if (!techMode) gStdOut.write(temp.toString());
        gStdOut.normalizePrintPath(filePath);
        if (techMode) gStdOut.endl();
        continue;
      }

      final width = f.width;
      Object? prop;
      var timePrec = archive.timePrec;
      switch (f.propId) {
        case Kpid.size:
          if (st.size.def) prop = st.size.val;
        case Kpid.packSize:
          if (st.packSize.def) prop = st.packSize.val;
        case Kpid.mTime:
          if (st.mTime.def) {
            prop = st.mTime.ft;
            timePrec = st.mTime.prec;
          }
        default:
          prop = archive.getProperty(index, f.propId);
      }
      if (f.propId == Kpid.attrib && (prop == null || prop is int)) {
        final s = _getAttribString(prop == null ? 0 : prop as int, isDir, techMode);
        if (techMode) {
          gStdOut.write(s);
        } else {
          temp.write(s);
        }
      } else if (prop == null) {
        if (!techMode) temp.write(' ' * width);
      } else if (prop is int && isFileTimeProp(f.propId)) {
        final t = ArcTime()..setFromProp(prop, timePrec);
        final s = _printTime(t, techMode);
        if (techMode) {
          gStdOut.write(s);
        } else {
          temp.write(s);
          if (s.length < f.width) temp.write(' ' * (f.width - s.length));
        }
      } else if (prop is String) {
        final s = _isPropIdForPathString(f.propId)
            ? gStdOut.normalizeStringPath(prop)
            : gStdOut.normalizeString(prop);
        if (techMode) {
          gStdOut.write(s);
        } else {
          gStdOut.write(temp.toString());
          temp.clear();
          gStdOut.write(_alignString(f.textAdjustment, width, s));
        }
      } else {
        final s = convertPropertyToShortString2(prop, f.propId,
            timePrec: timePrec);
        if (techMode) {
          gStdOut.write(s);
        } else {
          temp.write(_alignString(f.textAdjustment, width, s));
        }
      }
      if (techMode) gStdOut.endl();
    }
    gStdOut.endl();
  }

  // PrintSum
  void printSum(_ListStat st, int numDirs, String str) {
    for (final f in _fields) {
      _printSpaces(f.prefixSpacesWidth);
      if (f.propId == Kpid.size) {
        _printString(f.textAdjustment, f.width,
            st.size.def ? u64ToString(st.size.val) : '');
      } else if (f.propId == Kpid.packSize) {
        _printString(f.textAdjustment, f.width,
            st.packSize.def ? u64ToString(st.packSize.val) : '');
      } else if (f.propId == Kpid.mTime) {
        final s = st.mTime.def ? _printTime(st.mTime, false) : '';
        _printString(f.textAdjustment, f.width, s);
      } else if (f.propId == Kpid.path) {
        var s = printUInt64AndString(st.numFiles, str);
        if (numDirs != 0) {
          s += ', ${printUInt64AndString(numDirs, _kStringDirs)}';
        }
        _printString(f.textAdjustment, 0, s);
      } else {
        _printString(f.textAdjustment, f.width, '');
      }
    }
    gStdOut.endl();
  }

  void printSum2(_ListStat2 stat2) {
    printSum(stat2.mainFiles, stat2.numDirs, _kStringFiles);
    if (stat2.altStreams.numFiles != 0) {
      printSum(stat2.altStreams, 0, _kStringAltStreams);
      final st = stat2.mainFiles.copy()..update(stat2.altStreams);
      printSum(st, 0, _kStringStreams);
    }
  }
}

// UString_Replace_CRLF_to_LF
String _replaceCrlfToLf(String s) => s.replaceAll('\r\n', '\n');

// PrintPropVal_MultiLine
void _printPropValMultiLine(StdOutStream so, String val) {
  if (val.contains('\n')) {
    so.endl();
    so.write('{');
    so.endl();
    final s = _replaceCrlfToLf(val);
    var start = 0;
    for (;;) {
      var size = s.length - start;
      if (size == 0) break;
      final next = s.indexOf('\n', start);
      if (next >= 0) size = next - start;
      so.normalizePrint(s.substring(start, start + size));
      so.endl();
      if (next < 0) break;
      start = next + 1;
    }
    so.write('}');
  } else {
    so.normalizePrint(val);
  }
  so.endl();
}

// PrintPropPair
void _printPropPair(StdOutStream so, String name, String val, bool multiLine,
    [bool isPath = false]) {
  so.write('$name = ');
  if (multiLine) {
    _printPropValMultiLine(so, val);
    return;
  }
  so.write(isPath ? so.normalizeStringPath(val) : so.normalizeString(val));
  so.endl();
}

// PrintPropPair_Path
void printPropPairPath(StdOutStream so, String path) =>
    _printPropPair(so, 'Path', path, false, true);

// PrintPropertyPair2
void _printPropertyPair2(
    StdOutStream so, int propId, Object? prop, int timePrec) {
  const levelTopLimit = 9;
  final s = convertPropertyToString2(prop, propId,
      level: levelTopLimit, timePrec: timePrec);
  if (s.isNotEmpty) {
    so.write('${_getPropName(propId)} = ');
    _printPropValMultiLine(so, s);
  }
}

// PrintArcProp
void _printArcProp(StdOutStream so, InArchive archive, int propId) {
  _printPropertyPair2(
      so, propId, archive.getArchiveProperty(propId), archive.timePrec);
}

// PrintArcTypeError
void printArcTypeError(StdOutStream so, String type, bool isWarning) {
  so.write(
      'Open ${isWarning ? 'WARNING' : 'ERROR'}: Cannot open the file as [$type] archive');
  so.endl();
}

// ErrorInfo_Print
void _errorInfoPrint(StdOutStream so, ArcErrorInfo er) {
  printErrorFlags(so, 'ERRORS:', er.getErrorFlags());
  if (er.errorMessage.isNotEmpty) {
    _printPropPair(so, 'ERROR', er.errorMessage, true);
  }
  printErrorFlags(so, 'WARNINGS:', er.getWarningFlags());
  if (er.warningMessage.isNotEmpty) {
    _printPropPair(so, 'WARNING', er.warningMessage, true);
  }
}

/// Print_OpenArchive_Props.
void printOpenArchiveProps(StdOutStream so, Codecs codecs, ArchiveLink link) {
  for (var r = 0; r < link.arcs.length; r++) {
    final arc = link.arcs[r];
    final er = arc.errorInfo;
    so.write('--\n');
    printPropPairPath(so, arc.path);
    if (er.errorFormatIndex >= 0) {
      if (er.errorFormatIndex == arc.formatIndex) {
        so.write('Warning: The archive is open with offset');
        so.endl();
      } else {
        printArcTypeError(so, codecs.getFormatNamePtr(er.errorFormatIndex), true);
      }
    }
    _printPropPair(so, 'Type', codecs.getFormatNamePtr(arc.formatIndex), false);
    _errorInfoPrint(so, er);
    final offset = arc.getGlobalOffset();
    if (offset != 0) {
      so.write('${_getPropName(Kpid.offset)} = $offset');
      so.endl();
    }
    final archive = arc.archive!;
    _printArcProp(so, archive, Kpid.phySize);
    if (er.tailSize != 0) {
      so.write('${_getPropName(Kpid.tailSize)} = ${u64ToString(er.tailSize)}');
      so.endl();
    }
    for (final pid in archive.archivePropIds) {
      _printArcProp(so, archive, pid);
    }
    if (r != link.arcs.length - 1) {
      so.write('----\n');
      final mainIndex = link.arcs[r + 1].subfileIndex;
      for (final pid in archive.itemPropIds) {
        _printPropertyPair2(
            so, pid, archive.getProperty(mainIndex, pid), archive.timePrec);
      }
    }
  }
}

/// Print_OpenArchive_Error.
void printOpenArchiveError(StdOutStream so, Codecs codecs, ArchiveLink link) {
  if (link.passwordWasAsked) {
    so.write('Cannot open encrypted archive. Wrong password?');
  } else {
    if (link.nonOpenErrorInfo.errorFormatIndex >= 0) {
      so.normalizePrintPath(link.nonOpenArcPath);
      so.endl();
      printArcTypeError(
          so, codecs.formats[link.nonOpenErrorInfo.errorFormatIndex].name,
          false);
    } else {
      so.write('Cannot open the file as archive');
    }
  }
  so.endl();
  so.endl();
  _errorInfoPrint(so, link.nonOpenErrorInfo);
}

/// Find_FileName_InSortedVector.
int findFileNameInSortedVector(List<String> fileNames, String name) {
  var left = 0, right = fileNames.length;
  while (left != right) {
    final mid = (left + right) ~/ 2;
    final comp = compareFileNames(name, fileNames[mid]);
    if (comp == 0) return mid;
    if (comp < 0) {
      right = mid;
    } else {
      left = mid + 1;
    }
  }
  return -1;
}

/// CListOptions.
class ListOptions {
  bool excludeDirItems = false;
  bool excludeFileItems = false;
  bool disablePercents = false;

  /// -snest (zx extension): the depth of the nested archives, 0 when off.
  int nestDepth = 0;
}

/// ListArchives: returns (hresult, numErrors, numWarnings).
(int, int, int) listArchives(
    ListOptions listOptions,
    Codecs codecs,
    List<OpenType> types,
    List<int> excludedFormats,
    bool stdInMode,
    List<String> arcPaths,
    List<String> arcPathsFull,
    bool processAltStreams,
    bool showAltStreams,
    CensorNode wildcardCensor,
    bool enableHeaders,
    bool techMode,
    bool passwordEnabled,
    String password,
    List<MapEntry<String, String>> props) {
  final allFilesAreAllowed = wildcardCensor.areAllAllowed();
  var numErrors = 0;
  var numWarnings = 0;

  final fp = _FieldPrinter();
  if (!techMode) fp.init(_kStandardFieldTable);

  final stat2total = _ListStat2();
  final skipArcs = List<bool>.filled(arcPaths.length, false);
  var numVolumes = 0;
  var numArcs = 0;
  var totalArcSizes = 0;
  var lastError = 0;

  for (var arcIndex = 0; arcIndex < arcPaths.length; arcIndex++) {
    if (skipArcs[arcIndex]) continue;
    final arcPath = arcPaths[arcIndex];
    var arcPackSize = 0;

    if (!stdInMode) {
      final fi = findFileFollowLink(arcPath);
      if (fi == null) {
        var errorCode = lastFindErrno;
        if (errorCode == 0) errorCode = Errno.enoent;
        lastError = hresultFromErrno(errorCode);
        gStdOut.flush();
        final es = gErrStream;
        if (es != null) {
          es.endl();
          es.write('$_kError${myFormatMessage(errorCode)}');
          es.endl();
          es.normalizePrintPath(arcPath);
          es.endl();
          es.endl();
        }
        numErrors++;
        continue;
      }
      if (fi.isDir) {
        gStdOut.flush();
        final es = gErrStream;
        if (es != null) {
          es.endl();
          es.write(_kError);
          es.normalizePrintPath(arcPath);
          es.write(' is not a file');
          es.endl();
          es.endl();
        }
        numErrors++;
        continue;
      }
      arcPackSize = fi.size;
      totalArcSizes += arcPackSize;
    }

    final arcLink = ArchiveLink();
    final openCallback = OpenCallbackConsole()
      ..init(gStdOut, gErrStream, null, listOptions.disablePercents, gStdIn)
      ..passwordIsDefined = passwordEnabled
      ..password = password;

    final options = OpenOptions()
      ..props = props
      ..codecs = codecs
      ..types = types
      ..excludedFormats = excludedFormats
      ..stdInMode = stdInMode
      ..stream = null
      ..filePath = arcPath
      ..nestDepth = stdInMode ? 0 : listOptions.nestDepth;

    if (enableHeaders) {
      gStdOut.endl();
      gStdOut.write(_kListing);
      gStdOut.normalizePrintPath(arcPath);
      gStdOut.endl();
      gStdOut.endl();
    }

    int result;
    try {
      result = arcLink.openStrict(
          options, openCallback, stdInMode ? gStdIn.dataStream : null);
    } on SystemException catch (e) {
      result = e.errorCode;
    }

    if (result != HRes.sOk) {
      arcLink.close();
      if (result == HRes.eAbort) return (result, numErrors, numWarnings);
      if (result != HRes.sFalse) lastError = result;
      gStdOut.flush();
      final es = gErrStream;
      if (es != null) {
        es.endl();
        es.write(_kError);
        es.normalizePrintPath(arcPath);
        es.write(' : ');
        if (result == HRes.sFalse) {
          printOpenArchiveError(es, codecs, arcLink);
        } else {
          es.write('opening : ');
          if (result == HRes.eOutOfMemory) {
            es.write("Can't allocate required memory");
          } else {
            es.write(myFormatMessage(result));
          }
        }
        es.endl();
      }
      numErrors++;
      continue;
    }

    try {
      final lastArc = arcLink.arcs.last;
      if (lastArc.isSeq) {
        // a compound tar read in one pass: its headers (and errors) are
        // known after all were read
        lastArc.archive!.numberOfItems;
        lastArc.refreshSeqErrors();
      }

      for (final a in arcLink.arcs) {
        final arc = a.errorInfo;
        if (arc.warningMessage.isNotEmpty) numWarnings++;
        if (arc.areThereWarnings()) numWarnings++;
        if (arc.errorFormatIndex >= 0) numWarnings++;
        if (arc.areThereErrors()) numErrors++;
        if (arc.errorMessage.isNotEmpty) numErrors++;
      }

      numArcs++;
      numVolumes++;

      if (!stdInMode) {
        numVolumes += arcLink.volumePaths.length;
        totalArcSizes += arcLink.volumesSize;
        for (final v in arcLink.volumePaths) {
          final index = findFileNameInSortedVector(arcPathsFull, v);
          if (index >= 0 && index > arcIndex) skipArcs[index] = true;
        }
      }

      if (enableHeaders) {
        printOpenArchiveProps(gStdOut, codecs, arcLink);
        gStdOut.endl();
        if (techMode) gStdOut.write('----------\n');
      }

      if (enableHeaders && !techMode) {
        fp.printTitle();
        gStdOut.endl();
        fp.printTitleLines();
        gStdOut.endl();
      }

      final arc = arcLink.arcs.last;
      fp.arc = arc;
      fp.techMode = techMode;
      final archive = arc.archive!;
      if (techMode) {
        fp.clear();
        fp.addMainProps(archive);
      }

      final stat2 = _ListStat2();
      final numItems = archive.numberOfItems;
      final item = ReadArcItem();

      for (var i = 0; i < numItems; i++) {
        if (testBreakSignal()) return (HRes.eAbort, numErrors, numWarnings);
        fp.filePath = arc.getItemPath2(i);

        if (arc.askAux) {
          if (archiveGetItemBoolProp(archive, i, Kpid.isAux)) continue;
        }
        var isAltStream = false;
        if (arc.askAltStream) {
          isAltStream = archiveGetItemBoolProp(archive, i, Kpid.isAltStream);
          if (isAltStream && !processAltStreams) continue;
        }
        fp.isDir = archiveIsItemDir(archive, i);
        if (fp.isDir
            ? listOptions.excludeDirItems
            : listOptions.excludeFileItems) {
          continue;
        }
        if (!allFilesAreAllowed) {
          if (isAltStream) {
            arc.getItem(i, item);
            if (!censorNodeCheckPath(wildcardCensor, item)) continue;
          } else {
            final pathParts = splitPathToParts(fp.filePath);
            final (found, include) =
                wildcardCensor.checkPathVect(pathParts, !fp.isDir);
            if (!found) continue;
            if (!include) continue;
          }
        }

        final st = _ListStat();
        final size = propToU64(archive.getProperty(i, Kpid.size));
        if (size != null) {
          st.size
            ..val = size
            ..def = true;
        }
        final packSize = propToU64(archive.getProperty(i, Kpid.packSize));
        if (packSize != null) {
          st.packSize
            ..val = packSize
            ..def = true;
        }
        {
          final p = archive.getProperty(i, Kpid.mTime);
          if (p is int) {
            st.mTime.setFromProp(p, archive.timePrec);
          } else if (p != null) {
            throw const SystemException(HRes.eFail);
          }
        }

        if (fp.isDir) {
          stat2.numDirs++;
        } else {
          st.numFiles = 1;
        }
        stat2.getStat(isAltStream).update(st);

        if (isAltStream && !showAltStreams) continue;
        fp.printItemInfo(i, st);
      }

      final numStreams = stat2.getNumStreams();
      if (!stdInMode &&
          !stat2.mainFiles.packSize.def &&
          !stat2.altStreams.packSize.def) {
        if (arcLink.volumePaths.isNotEmpty) arcPackSize += arcLink.volumesSize;
        stat2.mainFiles.packSize.add(numStreams == 0 ? 0 : arcPackSize);
      }

      stat2.mainFiles.setSizeDefIfNoFiles();
      stat2.altStreams.setSizeDefIfNoFiles();

      if (enableHeaders && !techMode) {
        fp.printTitleLines();
        gStdOut.endl();
        fp.printSum2(stat2);
      }

      if (enableHeaders) {
        if (arcLink.nonOpenErrorInfo.errorFormatIndex >= 0) {
          gStdOut.write('----------\n');
          printPropPairPath(gStdOut, arcLink.nonOpenArcPath);
          printArcTypeError(
              gStdOut,
              codecs.formats[arcLink.nonOpenErrorInfo.errorFormatIndex].name,
              false);
        }
      }

      stat2total.update(stat2);
      gStdOut.flush();
    } finally {
      arcLink.close();
    }
  }

  if (enableHeaders && !techMode && (arcPaths.length > 1 || numVolumes > 1)) {
    gStdOut.endl();
    fp.printTitleLines();
    gStdOut.endl();
    fp.printSum2(stat2total);
    gStdOut.endl();
    gStdOut.write('Archives: $numArcs\n');
    gStdOut.write('Volumes: $numVolumes\n');
    gStdOut.write('Total archives size: $totalArcSizes\n');
  }

  if (numErrors == 1 && lastError != 0) {
    return (lastError, numErrors, numWarnings);
  }
  return (HRes.sOk, numErrors, numWarnings);
}

