// Opening of archives with format detection: UI/Common/OpenArchive.cpp
// (CArc, CArchiveLink, OpenStream2 with the extension / signature order and
// the signature scan, ParseOpenTypes), UI/Common/ArchiveOpenCallback.cpp
// (COpenCallbackImp: the volume and password callback) and
// UI/Common/DefaultName.cpp of the LZMA SDK.

import 'dart:io';
import 'dart:typed_data';

import '../common/method_props.dart';
import '../format/archive_types.dart';
import '../io/streams.dart';
import 'arc_compound.dart';
import 'arc_handlers.dart';
import 'arc_zpaq.dart';
import 'arc_zx.dart';
import '../format/zx/zx_reader.dart' show ZxGenerationSelector;
import 'common.dart';
import 'fs_utils.dart' show resolvePath;
import 'load_codecs.dart';
import 'nest.dart';
import 'platform.dart';
import 'wildcard.dart';

/// kMaxCheckStartPosition: increase it to support larger SFX stubs.
const int kMaxCheckStartPosition = 1 << 23;

/// k_PropVar_TimePrec_* (7zTypes.h / PropID.h).
abstract final class TimePrecVals {
  static const prec0 = 0;
  static const unix = 1;
  static const dos = 2;
  static const highPrec = 3;
  static const base = 16;
  static const prec100ns = base + 7;
  static const prec1ns = base + 9;
}

/// CArcTime.
class ArcTime {
  int ft = 0;
  int prec = 0;
  int ns100 = 0;
  bool def = false;

  ArcTime();
  ArcTime.of(this.ft, this.prec, [this.ns100 = 0]) : def = true;

  void clear() {
    ft = 0;
    prec = 0;
    ns100 = 0;
    def = false;
  }

  void copyFrom(ArcTime a) {
    ft = a.ft;
    prec = a.prec;
    ns100 = a.ns100;
    def = a.def;
  }

  bool get isZero => ft == 0 && ns100 == 0;

  // CompareWith
  int compareWith(ArcTime a) {
    final res = compareU64(ft, a.ft);
    if (res != 0) return res;
    if (ns100 < a.ns100) return -1;
    if (ns100 > a.ns100) return 1;
    return 0;
  }

  // GetNumDigits
  int getNumDigits() {
    if (prec == TimePrecVals.unix || prec == TimePrecVals.dos) return 0;
    if (prec == TimePrecVals.highPrec) return 9;
    if (prec == TimePrecVals.prec0) return 7;
    var digits = prec - TimePrecVals.base;
    if (digits < 0) digits = 0;
    return digits;
  }

  /// Set_From_Prop: a FILETIME property with the precision of the handler.
  void setFromProp(int value, int propPrec) {
    ft = value;
    prec = propPrec;
    ns100 = 0;
    def = true;
  }

  /// Set_From_FiTime (POSIX): the disk time with 9 digits of precision.
  void setFromFiTime(FiTime t) {
    ft = t.ft;
    ns100 = t.ns100;
    prec = TimePrecVals.base + 9;
  }
}

/// CFiTime of POSIX (timespec) as FILETIME ticks plus the rest in 1 ns.
class FiTime {
  final int ft;
  final int ns100;
  const FiTime(this.ft, [this.ns100 = 0]);

  static FiTime fromDateTime(DateTime t) => FiTime(dateTimeToFileTime(t));

  // Compare_FiTime
  int compare(FiTime b) {
    final r = compareU64(ft, b.ft);
    if (r != 0) return r;
    return ns100.compareTo(b.ns100);
  }
}

/// CArcErrorInfo.
class ArcErrorInfo {
  bool thereIsTail = false;
  bool unexpecedEnd = false;
  bool ignoreTail = false;
  bool errorFlagsDefined = false;
  int errorFlags = 0;
  int warningFlags = 0;
  int errorFormatIndex = -1;
  int tailSize = 0;
  String errorMessage = '';
  String warningMessage = '';

  // IsArc_After_NonOpen
  bool isArcAfterNonOpen() =>
      errorFlagsDefined && (errorFlags & ErrorFlags.isNotArc) == 0;

  // ClearErrors
  void clearErrors() {
    thereIsTail = false;
    unexpecedEnd = false;
    ignoreTail = false;
    errorFlagsDefined = false;
    errorFlags = 0;
    warningFlags = 0;
    tailSize = 0;
    errorMessage = '';
    warningMessage = '';
  }

  void clearErrorsFull() {
    errorFormatIndex = -1;
    clearErrors();
  }

  ArcErrorInfo copy() => ArcErrorInfo()
    ..thereIsTail = thereIsTail
    ..unexpecedEnd = unexpecedEnd
    ..ignoreTail = ignoreTail
    ..errorFlagsDefined = errorFlagsDefined
    ..errorFlags = errorFlags
    ..warningFlags = warningFlags
    ..errorFormatIndex = errorFormatIndex
    ..tailSize = tailSize
    ..errorMessage = errorMessage
    ..warningMessage = warningMessage;

  bool isThereErrorOrWarning() =>
      errorFlags != 0 ||
      warningFlags != 0 ||
      needTailWarning() ||
      unexpecedEnd ||
      errorMessage.isNotEmpty ||
      warningMessage.isNotEmpty;

  bool areThereErrors() => errorFlags != 0 || unexpecedEnd;
  bool areThereWarnings() => warningFlags != 0 || needTailWarning();
  bool needTailWarning() => !ignoreTail && thereIsTail;

  int getWarningFlags() {
    var a = warningFlags;
    if (needTailWarning() && (errorFlags & ErrorFlags.dataAfterEnd) == 0) {
      a |= ErrorFlags.dataAfterEnd;
    }
    return a;
  }

  int getErrorFlags() {
    var a = errorFlags;
    if (unexpecedEnd) a |= ErrorFlags.unexpectedEnd;
    return a;
  }
}

/// COpenSpecFlags.
class OpenSpecFlags {
  bool canReturnFrontal = false;
  bool canReturnTail = false;
  bool canReturnMid = false;
  bool canReturnNonStart() => canReturnTail || canReturnMid;
  OpenSpecFlags copy() => OpenSpecFlags()
    ..canReturnFrontal = canReturnFrontal
    ..canReturnTail = canReturnTail
    ..canReturnMid = canReturnMid;
}

/// COpenType.
class OpenType {
  int formatIndex = -1;
  OpenSpecFlags specForcedType = OpenSpecFlags();
  OpenSpecFlags specMainType = OpenSpecFlags();
  OpenSpecFlags specWrongExt = OpenSpecFlags();
  OpenSpecFlags specUnknownExt = OpenSpecFlags();
  bool recursive = true;
  bool canReturnArc = true;
  bool canReturnParser = false;
  bool isHashType = false;
  bool eachPos = false;
  bool zerosTailIsAllowed = false;
  bool maxStartOffsetDefined = false;
  int maxStartOffset = 0;

  OpenType() {
    specForcedType
      ..canReturnFrontal = true
      ..canReturnTail = true
      ..canReturnMid = true;
    specMainType.canReturnFrontal = true;
    specUnknownExt
      ..canReturnTail = true
      ..canReturnMid = true
      ..canReturnFrontal = true;
  }

  OpenType copy() => OpenType()
    ..formatIndex = formatIndex
    ..specForcedType = specForcedType.copy()
    ..specMainType = specMainType.copy()
    ..specWrongExt = specWrongExt.copy()
    ..specUnknownExt = specUnknownExt.copy()
    ..recursive = recursive
    ..canReturnArc = canReturnArc
    ..canReturnParser = canReturnParser
    ..isHashType = isHashType
    ..eachPos = eachPos
    ..zerosTailIsAllowed = zerosTailIsAllowed
    ..maxStartOffsetDefined = maxStartOffsetDefined
    ..maxStartOffset = maxStartOffset;

  // GetSpec
  OpenSpecFlags getSpec(bool isForced, bool isMain, bool isUnknown) => isForced
      ? specForcedType
      : (isMain ? specMainType : (isUnknown ? specUnknownExt : specWrongExt));
}

/// IOpenCallbackUI.
abstract class OpenCallbackUI {
  void openCheckBreak() {}
  void openSetTotal(int? files, int? bytes) {}
  void openSetCompleted(int? files, int? bytes) {}

  /// Open_CryptoGetTextPassword: throws [SystemException] to fail.
  String openCryptoGetTextPassword();
  void openFinished() {}
}

/// COpenOptions.
class OpenOptions {
  late Codecs codecs;
  OpenType openType = OpenType();
  List<OpenType> types = const [];
  List<int> excludedFormats = const [];
  SeekableInStream? stream;
  InStream? seqStream;
  ArchiveOpenCallback? callback;
  OpenCallbackImp? callbackSpec;

  /// The -m switch properties (SetProperties before Open).
  List<MapEntry<String, String>>? props;
  bool stdInMode = false;
  String filePath = '';

  /// Open a tar inside a compressor as the next level even when the names
  /// do not say it is one (arc_compound.dart).
  bool forceCompound = false;

  /// Not null: a tar inside a compressor is decoded to a temporary file in
  /// this folder (with its separator, empty for the current folder) and
  /// opened seekable, for an update. null: it is read in one pass.
  String? compoundTempDir;

  /// zx extension (-snest, ZxArchive flatten): above 0 the last level is
  /// shown as one tree with the archives nested in it, up to this depth
  /// (nest.dart).
  int nestDepth = 0;

  /// The nested archives to open again (no item is tried).
  List<NestNodeSpec>? nestLayout;

  /// The temporary files of the nested archives stay on close.
  bool nestKeepTemps = false;

  /// Where they are made (default: the system temporary folder).
  String? nestTempDir;

  /// zx extension (ZxArchive.open version): a journaling archive (zpaq)
  /// is shown as of this version instead of its last one (the CLI sets it
  /// with -mversion=N, a handler property).
  int? version;

  /// zx extension: a .zx archive is shown as of this date (YYYY-MM-DD[
  /// HH:MM[:SS]], local time) instead of its last generation.
  String? versionDate;

  /// zx extension: folders where the volumes of a .zx set may be.
  List<String> zxSearchDirs = const [];
}

/// CReadArcItem.
class ReadArcItem {
  String path = '';
  List<String> pathParts = [];
  String mainPath = '';
  String altStreamName = '';
  bool isAltStream = false;
  bool writeToAltStreamIfColon = false;
  bool isDir = false;
  bool mainIsDir = false;
  int parentIndex = -1;
}

// Archive_GetItemBoolProp
bool archiveGetItemBoolProp(InArchive arc, int index, int propId) {
  final v = arc.getProperty(index, propId);
  if (v == null) return false;
  if (v is bool) return v;
  throw const SystemException(HRes.eFail);
}

bool archiveIsItemDir(InArchive arc, int index) =>
    archiveGetItemBoolProp(arc, index, Kpid.isDir);

/// ConvertPropVariantToUInt64 for handler values: null when not defined.
int? propToU64(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is bool) throw const SystemException(HRes.eFail);
  throw const SystemException(HRes.eFail);
}

// GetOpenArcErrorFlags
int _getOpenArcErrorFlags(Object? prop, [List<bool>? defined]) {
  if (prop == null) return 0;
  if (prop is int) {
    defined?[0] = true;
    return prop & 0xFFFFFFFF;
  }
  throw const SystemException(HRes.eFail);
}

/// A window of a seekable stream, positions relative to [offset]
/// (CLimitedCachedInStream / CTailInStream).
class OffsetInStream implements SeekableInStream {
  final SeekableInStream base;
  final int offset;
  final int _size;
  int _pos = 0;
  OffsetInStream(this.base, this.offset, int size) : _size = size;

  @override
  int read(Uint8List buf, int off, int len) {
    final rem = _size - _pos;
    if (rem <= 0) return 0;
    if (len > rem) len = rem;
    base.position = offset + _pos;
    final n = base.read(buf, off, len);
    _pos += n;
    return n;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => _size;
}

/// CArc.
class Arc {
  InArchive? archive;
  SeekableInStream? inStream;
  bool isParseArc = false;
  bool isTree = false;
  bool isReadOnly = false;
  bool askDeleted = false;
  bool askAltStream = false;
  bool askAux = false;
  bool askINode = false;
  bool ignoreSplit = false;

  String path = '';
  String filePath = '';
  String defaultName = '';
  int formatIndex = -1;
  int subfileIndex = -1;
  final ArcTime mTime = ArcTime();

  int offset = 0;
  int phySize = 0;
  bool phySizeDefined = false;
  int fileSize = 0;
  int availPhySize = 0;

  ArcErrorInfo errorInfo = ArcErrorInfo();
  ArcErrorInfo nonOpenErrorInfo = ArcErrorInfo();

  int arcStreamOffset = 0;

  /// The file stream the archive was opened from (closed by [close]).
  FileInStream? fileStream;

  /// A tar inside a compressor (arc_compound.dart): the format index of
  /// the compressor, -1 otherwise.
  int compoundOuterIndex = -1;

  /// The archive is read in one pass (a compound tar without a temporary
  /// file): extraction goes through the items in order, as with -si.
  bool isSeq = false;

  /// The temporary file of a compound tar opened for an update, deleted by
  /// [close].
  String? tempPath;

  int getEstmatedPhySize() => phySizeDefined ? phySize : fileSize;
  int getGlobalOffset() => arcStreamOffset + offset;

  void close() {
    inStream = null;
    archive?.close();
    try {
      fileStream?.close();
    } on Object {
      // ignore
    }
    fileStream = null;
    final t = tempPath;
    if (t != null) {
      tempPath = null;
      try {
        File(t).deleteSync();
      } on FileSystemException {
        // ignore
      }
    }
  }

  /// The error flags of a one pass archive after its headers were read
  /// (the listing reads them all after Open).
  void refreshSeqErrors() {
    final a = archive;
    if (a == null) return;
    final d = [false];
    errorInfo.errorFlags =
        _getOpenArcErrorFlags(a.getArchiveProperty(Kpid.errorFlags), d);
    errorInfo.errorFlagsDefined = d[0];
    errorInfo.warningFlags =
        _getOpenArcErrorFlags(a.getArchiveProperty(Kpid.warningFlags));
  }

  // CArc::ReadBasicProps
  void readBasicProps(InArchive archive, int startPos, int openRes) {
    phySizeDefined = false;
    phySize = 0;
    offset = 0;
    availPhySize = fileSize - startPos;

    errorInfo.clearErrors();
    {
      final d = [false];
      errorInfo.errorFlags =
          _getOpenArcErrorFlags(archive.getArchiveProperty(Kpid.errorFlags), d);
      errorInfo.errorFlagsDefined = d[0];
    }
    errorInfo.warningFlags =
        _getOpenArcErrorFlags(archive.getArchiveProperty(Kpid.warningFlags));
    {
      final p = archive.getArchiveProperty(Kpid.error);
      if (p != null) errorInfo.errorMessage = p is String ? p : 'Unknown error';
    }
    {
      final p = archive.getArchiveProperty(Kpid.warning);
      if (p != null) {
        errorInfo.warningMessage = p is String ? p : 'Unknown warning';
      }
    }

    if (openRes == HRes.sOk || errorInfo.isArcAfterNonOpen()) {
      final ps = propToU64(archive.getArchiveProperty(Kpid.phySize));
      phySizeDefined = ps != null;
      phySize = ps ?? 0;
      final off = archive.getArchiveProperty(Kpid.offset);
      if (off is int) offset = off;

      final globalOffset = startPos + offset;
      availPhySize = fileSize - globalOffset;
      if (phySizeDefined) {
        final endPos = globalOffset + phySize;
        if (endPos < fileSize) {
          availPhySize = phySize;
          errorInfo.thereIsTail = true;
          errorInfo.tailSize = fileSize - endPos;
        } else if (endPos > fileSize) {
          errorInfo.unexpecedEnd = true;
        }
      }
    }
  }

  // PrepareToOpen
  InArchive? _prepareToOpen(OpenOptions op, int formatIndex) {
    final ai = op.codecs.formats[formatIndex];
    final create = ai.createInArchive;
    if (create == null) return null;
    final archive = create();
    final props = op.props;
    if (props != null && props.isNotEmpty) {
      setArchiveProperties(archive, props);
    }
    final v = op.version;
    if (v != null && archive is ZpaqArc) archive.h.openVersion = v;
    // zx: a generation by number or date
    final vd = op.versionDate;
    if (archive is ZxArc) {
      archive.h.options.searchDirs.addAll(op.zxSearchDirs);
      if (vd != null) {
        archive.h.options.generation = ZxGenerationSelector.parse(vd);
      } else if (v != null) {
        archive.h.options.generation = ZxGenerationSelector(number: v);
      }
    }
    return archive;
  }

  // CheckZerosTail
  void _checkZerosTail(OpenOptions op, int offset) {
    final s = op.stream;
    if (s == null) return;
    s.position = offset;
    final buf = Uint8List(1 << 11);
    for (;;) {
      final processed = s.read(buf, 0, buf.length);
      if (processed == 0) {
        errorInfo.ignoreTail = true;
        return;
      }
      for (var i = 0; i < processed; i++) {
        if (buf[i] != 0) return;
      }
    }
  }

  // CArc::GetItem_Path. On Windows the path gets the system separators
  // as GetRawProp (kpidPath) of the 7z handler gives it: '/' becomes '\'
  // and a '\' inside a name becomes WCHAR_IN_FILE_NAME_BACKSLASH_REPLACEMENT.
  String getItemPath(int index) {
    final p = archive!.getProperty(index, Kpid.path);
    String result;
    if (p is String) {
      result = replaceToWinSlashes(p);
    } else if (p == null) {
      result = '';
    } else {
      throw const SystemException(HRes.eFail);
    }
    if (result.isEmpty) return getItemDefaultPath(index);
    return result;
  }

  // GetItem_DefaultPath
  String getItemDefaultPath(int index) {
    final isDir = archiveIsItemDir(archive!, index);
    if (isDir) return '';
    var result = defaultName;
    final p = archive!.getProperty(index, Kpid.extension);
    if (p is String) {
      result = '$result.$p';
    } else if (p != null) {
      throw const SystemException(HRes.eFail);
    }
    return result;
  }

  // GetItem_Path2
  String getItemPath2(int index) {
    var result = getItemPath(index);
    if (askDeleted) {
      if (archiveGetItemBoolProp(archive!, index, Kpid.isDeleted)) {
        result = '[DELETED]$kDirSep$result';
      }
    }
    return result;
  }

  // CArc::GetItem
  void getItem(int index, ReadArcItem item) {
    item.isAltStream = false;
    item.altStreamName = '';
    item.mainPath = '';
    item.isDir = false;
    item.path = '';
    item.parentIndex = -1;
    item.pathParts = [];

    item.isDir = archiveIsItemDir(archive!, index);
    item.mainIsDir = item.isDir;
    item.path = getItemPath2(index);
    item.mainPath = item.path;
    if (askAltStream) {
      item.isAltStream =
          archiveGetItemBoolProp(archive!, index, Kpid.isAltStream);
    }
    var needFindAltStream = item.isAltStream;
    if (item.writeToAltStreamIfColon || needFindAltStream) {
      final colon = findAltStreamColonInPath(item.path);
      if (colon >= 0) {
        item.mainPath = item.mainPath.substring(0, colon);
        item.altStreamName = item.path.substring(colon + 1);
        item.mainIsDir =
            colon == 0 || isPathSepar(item.path.codeUnitAt(colon - 1));
        item.isAltStream = true;
      }
    }
    item.pathParts = splitPathToParts(item.mainPath);
  }

  // GetItem_Size
  (int, bool) getItemSize(int index) {
    final p = archive!.getProperty(index, Kpid.size);
    if (p == null) return (0, false);
    if (p is int) return (p, true);
    throw const SystemException(HRes.eFail);
  }

  // GetItem_MTime
  ArcTime getItemMTime(int index) {
    final at = ArcTime();
    final p = archive!.getProperty(index, Kpid.mTime);
    if (p is int) {
      at.setFromProp(p, archive!.timePrec);
      if (at.prec == 0) {
        final tt = archive!.getProperty(index, Kpid.timeType);
        if (tt is int) {
          at.prec = tt == FileTimeType.windows ? TimePrecVals.prec100ns : tt;
        }
      }
      return at;
    }
    if (p != null) throw const SystemException(HRes.eFail);
    if (mTime.def) at.copyFrom(mTime);
    return at;
  }

  bool isItemAnti(int index) =>
      archiveGetItemBoolProp(archive!, index, Kpid.isAnti);

  // CArc::OpenStream2
  int _openStream2(OpenOptions op) {
    archive = null;
    errorInfo.clearErrors();
    errorInfo.errorFormatIndex = -1;
    isParseArc = false;
    arcStreamOffset = 0;

    final fileName = extractFileNameFromPath(path);
    var extension = '';
    {
      final dotPos = fileName.lastIndexOf('.');
      if (dotPos >= 0) extension = fileName.substring(dotPos + 1);
    }

    var orderIndices = <int>[];
    var searchMarkerInHandler = false;
    final formats = op.codecs.formats;
    final isMainFormatArr = List<bool>.filled(formats.length, false);
    final maxStartOffset = op.openType.maxStartOffsetDefined
        ? op.openType.maxStartOffset
        : kMaxCheckStartPosition;
    var isUnknownExt = false;
    var isForced = false;
    var numMainTypes = 0;
    final formatIndex0 = op.openType.formatIndex;

    if (formatIndex0 >= 0) {
      isForced = true;
      orderIndices.add(formatIndex0);
      numMainTypes = 1;
      isMainFormatArr[formatIndex0] = true;
      searchMarkerInHandler = true;
    } else {
      var numFinded = 0;
      var isPrearcExt = false;
      for (var i = 0; i < formats.length; i++) {
        final ai = formats[i];
        if (ignoreSplit || !op.openType.canReturnArc) {
          if (ai.isSplit) continue;
        }
        if (op.excludedFormats.contains(i)) continue;
        if (ai.flagsPreArc) isPrearcExt = true;
        if (ai.findExtension(extension) >= 0) {
          orderIndices.insert(numFinded++, i);
          isMainFormatArr[i] = true;
        } else {
          orderIndices.add(i);
        }
      }

      if (op.stream == null) {
        if (numFinded != 1) return HRes.eNotImpl;
        orderIndices = orderIndices.sublist(0, 1);
      }

      final stream = op.stream;
      if (stream != null && orderIndices.length >= 2) {
        stream.position = 0;
        final orderIndices2 = <int>[];
        if (numFinded == 0 || extension.toLowerCase() == 'exe') {
          // signature search was here
        } else if (extension == '000' || extension == '001') {
          // rar volumes are not supported by 7zr
        } else {
          final buf = Uint8List(1 << 10);
          final processedSize = readFully(stream, buf, 0, buf.length);
          if (processedSize == 0) return HRes.sFalse;
          for (var i = 0; i < numFinded; i++) {
            final index = orderIndices[i];
            if (index < 0) continue;
            if (formats[index].flagsBackwardOpen) {
              orderIndices2.add(index);
              orderIndices[i] = -1;
            }
          }
          _makeCheckOrder(formats, orderIndices, numFinded, orderIndices2,
              buf, 0);
          _makeCheckOrder(formats, orderIndices, numFinded, orderIndices2,
              buf, processedSize);
        }
        for (final val in orderIndices) {
          if (val != -1) orderIndices2.add(val);
        }
        orderIndices = orderIndices2;
      }
      // an ISO/UDF bridge disc opens as Udf when its extension matches
      // both (x.iso), as in 7-Zip
      if (orderIndices.length >= 2) {
        final iIso = _findFormatInOrder(formats, orderIndices, 'iso');
        final iUdf = _findFormatInOrder(formats, orderIndices, 'udf');
        if (iUdf > iIso && iIso >= 0) {
          final isoIndex = orderIndices[iIso];
          orderIndices[iIso] = orderIndices[iUdf];
          orderIndices[iUdf] = isoIndex;
        }
      }
      numMainTypes = numFinded;
      isUnknownExt = numMainTypes == 0 || isPrearcExt;
    }

    var fileSize = 0;
    final stream = op.stream;
    if (stream != null) {
      fileSize = stream.length;
      stream.position = 0;
    }
    this.fileSize = fileSize;

    final skipFrontalFormat = List<bool>.filled(formats.length, false);
    final mode = op.openType;

    if (mode.canReturnArc) {
      var numCheckTypes = orderIndices.length;
      if (formatIndex0 >= 0) numCheckTypes = numMainTypes;

      for (var i = 0; i < numCheckTypes; i++) {
        formatIndex = orderIndices[i];
        var exactOnly = false;
        final ai = formats[formatIndex];
        if (i >= numMainTypes) {
          if (!ai.flagsBackwardOpen) continue;
          exactOnly = true;
        }
        op.callback?.setTotal(null, fileSize);
        stream?.position = 0;

        final archive = _prepareToOpen(op, formatIndex);
        if (archive == null) continue;

        int result;
        if (stream != null) {
          final searchLimit =
              (!exactOnly && searchMarkerInHandler) ? maxStartOffset : 0;
          result = _callOpen(archive, stream, searchLimit, op.callback);
        } else {
          result = archive.openSeq(op.seqStream!);
          if (result == HRes.eNotImpl) return HRes.eNotImpl;
        }

        readBasicProps(archive, 0, result);

        if (result == HRes.sFalse) {
          final isArc = errorInfo.isArcAfterNonOpen();
          if (!mode.canReturnParser || !isArc) {
            skipFrontalFormat[formatIndex] = true;
          }
          if (exactOnly) continue;
          if (i == 0 && numMainTypes == 1) {
            errorInfo.errorFormatIndex = formatIndex;
            nonOpenErrorInfo = errorInfo.copy();
            if (!mode.canReturnParser && isArc) {
              if (!ai.flagsPreArc) return HRes.sFalse;
            }
          }
          continue;
        }
        if (result != HRes.sOk) return result;

        final isMainFormat = isMainFormatArr[formatIndex];
        final specFlags = mode.getSpec(isForced, isMainFormat, isUnknownExt);

        var thereIsTail = errorInfo.thereIsTail;
        if (thereIsTail && mode.zerosTailIsAllowed) {
          _checkZerosTail(op, offset + phySize);
          if (errorInfo.ignoreTail) thereIsTail = false;
        }

        if (offset > 0) {
          if (exactOnly ||
              !searchMarkerInHandler ||
              !specFlags.canReturnNonStart() ||
              (mode.maxStartOffsetDefined && offset > mode.maxStartOffset)) {
            continue;
          }
        }
        if (thereIsTail) {
          if (offset > 0) {
            if (!specFlags.canReturnMid) continue;
          } else if (!specFlags.canReturnFrontal) {
            continue;
          }
        }
        if (offset > 0 || thereIsTail) {
          if (formatIndex0 < 0) {
            if (ai.flagsPreArc) continue;
          }
        }
        this.archive = archive;
        return HRes.sOk;
      }
    }

    if (stream == null) return HRes.sFalse;

    if (formatIndex0 >= 0 && !mode.canReturnParser) {
      if (mode.maxStartOffsetDefined) {
        if (mode.maxStartOffset == 0) return HRes.sFalse;
      } else {
        final ai = formats[formatIndex0];
        if (ai.findExtension(extension) >= 0) {
          if (ai.flagsFindSignature && searchMarkerInHandler) {
            return HRes.sFalse;
          }
        }
      }
    }

    // ---------- Check all possible START archives ----------
    final parserItems = <_ParseItem>[];
    {
      var endOfFile = false;
      var bufSize = 1 << 20;
      if (bufSize > fileSize) {
        bufSize = fileSize;
        endOfFile = true;
      }
      final byteBuffer = Uint8List(bufSize);
      stream.position = 0;
      final processedSize = readFully(stream, byteBuffer, 0, bufSize);
      if (processedSize == 0) return HRes.sFalse;
      if (processedSize < bufSize) endOfFile = true;

      final sortedFormats = <int>[];
      var splitIndex = -1;

      for (final form in orderIndices) {
        if (skipFrontalFormat[form]) continue;
        final ai = formats[form];
        if (ai.isSplit) {
          splitIndex = form;
          continue;
        }
        if (ai.flagsByExtOnlyOpen) continue;
        final isArcFunc = ai.isArcFunc;
        if (isArcFunc != null) {
          final isArcRes = isArcFunc(byteBuffer, processedSize);
          if (isArcRes == IsArcRes.no) continue;
          if (isArcRes == IsArcRes.needMore && endOfFile) continue;
          sortedFormats.insert(0, form);
          continue;
        }
        const isNewStyleSignature = true;
        var needCheck = !isNewStyleSignature ||
            ai.signatures.isEmpty ||
            ai.flagsPureStartOpen ||
            ai.flagsStartOpen ||
            ai.flagsBackwardOpen;
        if (ai.signatures.isNotEmpty) {
          var k = 0;
          for (; k < ai.signatures.length; k++) {
            final sig = ai.signatures[k];
            if (processedSize < ai.signatureOffset + sig.length) {
              if (!endOfFile) needCheck = true;
            } else if (_testSignature(
                sig, byteBuffer, ai.signatureOffset, sig.length)) {
              break;
            }
          }
          if (k != ai.signatures.length) {
            sortedFormats.insert(0, form);
            continue;
          }
        }
        if (needCheck) sortedFormats.add(form);
      }

      if (splitIndex >= 0) sortedFormats.insert(0, splitIndex);

      for (final form in sortedFormats) {
        formatIndex = form;
        final ai = formats[form];
        op.callback?.setTotal(null, fileSize);
        stream.position = 0;
        final archive = _prepareToOpen(op, form);
        if (archive == null) continue;
        var result = _callOpen(archive, stream, 0, op.callback);
        if (result == HRes.sOk && !mode.canReturnArc) {
          result = _needPhySize(archive);
        }
        if (result == HRes.sFalse) {
          skipFrontalFormat[form] = true;
          continue;
        }
        if (result != HRes.sOk) return result;

        readBasicProps(archive, 0, result);
        if (offset > 0) continue;

        final pi = _ParseItem()
          ..offset = offset
          ..size = availPhySize;
        if (!phySizeDefined) pi.lenIsUnknown = true;
        pi.normalizeOffset();

        if (mode.canReturnArc) {
          final isMainFormat = isMainFormatArr[form];
          final specFlags =
              mode.getSpec(isForced, isMainFormat, isUnknownExt);
          var openCur = false;
          if (!errorInfo.thereIsTail) {
            openCur = true;
          } else {
            if (mode.zerosTailIsAllowed) {
              _checkZerosTail(op, offset + phySize);
              if (errorInfo.ignoreTail) openCur = true;
            }
            if (!openCur) {
              openCur = specFlags.canReturnFrontal;
              if (formatIndex0 < 0) {
                if (ai.flagsPreArc) openCur = false;
              }
            }
          }
          if (openCur) {
            inStream = stream;
            this.archive = archive;
            return HRes.sOk;
          }
        }
        skipFrontalFormat[form] = true;
        if (pi.offset == 0 && !pi.lenIsUnknown && pi.size >= this.fileSize) {
          continue;
        }
        pi.formatIndex = form;
        parserItems.add(pi);
      }
    }

    // ---------- PARSER: signature scan ----------
    final res = _scanSignatures(op, orderIndices, skipFrontalFormat,
        isMainFormatArr, isForced, isUnknownExt, formatIndex0, maxStartOffset,
        fileSize, parserItems);
    if (res != null) return res;
    if (archive == null) return HRes.sFalse;
    return HRes.sOk;
  }

  int _callOpen(InArchive archive, SeekableInStream stream, int searchLimit,
      ArchiveOpenCallback? callback) {
    try {
      return archive.open(stream, searchLimit, callback);
    } on SystemException {
      rethrow;
    } on FileSystemException catch (e) {
      throw SystemException(hresultOfFileSystemException(e));
    }
  }

  // OpenArchiveSpec with needPhySize
  int _needPhySize(InArchive archive) {
    final ps = archive.getArchiveProperty(Kpid.phySize);
    if (ps != null) return HRes.sOk;
    archive.extract(null, true, _NullExtractCallback());
    return HRes.sOk;
  }

  // The signature scan of OpenStream2 (the "Main Scan Loop").
  int? _scanSignatures(
      OpenOptions op,
      List<int> orderIndices,
      List<bool> skipFrontalFormat,
      List<bool> isMainFormatArr,
      bool isForced,
      bool isUnknownExt,
      int formatIndex0,
      int maxStartOffset,
      int fileSize,
      List<_ParseItem> items) {
    final stream = op.stream!;
    final formats = op.codecs.formats;
    final mode = op.openType;

    // the formats with signatures and the "difficult" ones (no signature
    // or kStartOpen), which are tried only at the start positions
    final difficultFormats = <int>[];
    final sigFormats = <int>[];
    for (final index in orderIndices) {
      if (index < 0) continue;
      final ai = formats[index];
      if (ai.flagsByExtOnlyOpen) continue;
      var isDifficult = false;
      if (ai.flagsStartOpen) isDifficult = true;
      if (ai.signatures.isEmpty) isDifficult = true;
      for (final sig in ai.signatures) {
        if (sig.length < 2) {
          isDifficult = true;
          continue;
        }
        if (!sigFormats.contains(index)) sigFormats.add(index);
      }
      if (isDifficult) difficultFormats.add(index);
    }

    var pos = 0;
    if (!mode.eachPos && items.length == 1) {
      final pi = items[0];
      if (!pi.lenIsUnknown && pi.offset == 0) pos = pi.size;
    }

    var needCheckStartOpen = true;
    const kChunk = 1 << 16;
    final buf = Uint8List(kChunk + 64);

    while (pos < fileSize) {
      if (!mode.canReturnParser) {
        if (pos > maxStartOffset) break;
      }
      // candidate list for this position
      final candidates = <(int, bool)>[];
      if (needCheckStartOpen) {
        for (final f in difficultFormats) {
          candidates.add((f, true));
        }
      }
      // find the next position with a signature
      var foundPos = -1;
      if (!needCheckStartOpen || candidates.isEmpty) {
        var p = pos;
        var limit = fileSize;
        if (!mode.canReturnParser && limit > maxStartOffset + 1) {
          limit = maxStartOffset + 1;
        }
        outer:
        while (p < limit) {
          stream.position = p;
          final n = readFully(stream, buf, 0, buf.length);
          if (n < 2) break;
          final scanEnd = n - 1;
          for (var k = 0; k < scanEnd && p + k < limit; k++) {
            for (final f in sigFormats) {
              final ai = formats[f];
              for (final sig in ai.signatures) {
                if (buf[k] != sig[0] || buf[k + 1] != sig[1]) continue;
                foundPos = p + k;
                break;
              }
              if (foundPos >= 0) break;
            }
            if (foundPos >= 0) break outer;
          }
          if (n < buf.length) break;
          p += buf.length - 64;
        }
        if (foundPos < 0) break;
        if (foundPos != pos) {
          pos = foundPos;
          if (!mode.canReturnParser && pos > maxStartOffset) break;
        }
      }
      if (!needCheckStartOpen || foundPos >= 0) {
        // signature formats that match at pos
        stream.position = pos;
        final n = readFully(stream, buf, 0, 64);
        for (final f in sigFormats) {
          final ai = formats[f];
          if (needCheckStartOpen && difficultFormats.contains(f)) continue;
          for (final sig in ai.signatures) {
            if (pos < ai.signatureOffset) continue;
            if (sig.length > n) continue;
            if (!_testSignature(sig, buf, 0, sig.length)) continue;
            candidates.add((f, false));
            break;
          }
        }
      }

      var wasOpen = false;
      var nextNeedCheckStartOpen = true;
      for (final (index, isDifficult) in candidates) {
        final ai = formats[index];
        if ((isDifficult && pos == 0) || ai.signatureOffset == pos) {
          if (skipFrontalFormat[index]) continue;
        }
        var startArcPos = pos;
        if (!isDifficult) {
          if (pos < ai.signatureOffset) continue;
          startArcPos = pos - ai.signatureOffset;
        }
        final isArcFunc = ai.isArcFunc;
        if (isArcFunc != null) {
          final b = Uint8List(1 << 10);
          stream.position = startArcPos;
          final n = readFully(stream, b, 0, b.length);
          final isArcRes = isArcFunc(b, n);
          if (isArcRes == IsArcRes.no) continue;
          if (isArcRes == IsArcRes.needMore && startArcPos + n >= fileSize) {
            continue;
          }
        }

        final isMainFormat = isMainFormatArr[index];
        final specFlags = mode.getSpec(isForced, isMainFormat, isUnknownExt);
        final archive = _prepareToOpen(op, index);
        if (archive == null) return HRes.eFail;

        final rem = fileSize - startArcPos;
        final limitedStream = OffsetInStream(stream, startArcPos, rem);
        final arcStreamOffset = startArcPos;
        final savedFileSize = this.fileSize;
        this.fileSize = rem;
        var result = _callOpen(archive, limitedStream, 0, op.callback);
        if (result == HRes.sOk) result = _needPhySize(archive);
        readBasicProps(archive, 0, result);
        this.fileSize = savedFileSize;
        // ReadBasicProps(startArcPos): the values relative to the file
        availPhySize = phySizeDefined ? availPhySize : savedFileSize - startArcPos;

        var isOpen = false;
        if (result == HRes.sFalse) {
          if (!mode.canReturnParser) {
            if (formatIndex0 < 0 && errorInfo.isArcAfterNonOpen()) {
              errorInfo.errorFormatIndex = index;
              nonOpenErrorInfo = errorInfo.copy();
              return HRes.sFalse;
            }
            continue;
          }
          if (!errorInfo.isArcAfterNonOpen() ||
              !phySizeDefined ||
              phySize == 0) {
            continue;
          }
        } else {
          if (phySizeDefined && phySize == 0) continue;
          isOpen = true;
          if (result != HRes.sOk) return result;
        }

        final pi = _ParseItem()..offset = startArcPos;
        if (offset != 0) return HRes.eFail;
        final arcRem = savedFileSize - pi.offset;
        var phySize2 = arcRem;
        final phySizeDefined2 = phySizeDefined;
        if (phySizeDefined2) {
          if (pi.offset + phySize > savedFileSize) {
            phySize = savedFileSize - pi.offset;
          }
          phySize2 = phySize;
        }
        if (phySize2 == 0) return HRes.eFail;
        var needScan = false;
        if (isOpen && !phySizeDefined2) {
          pi.lenIsUnknown = true;
          needScan = true;
          phySize2 = arcRem;
          nextNeedCheckStartOpen = false;
        }
        pi.size = phySize2;
        if (pi.offset == 0 && !pi.lenIsUnknown && pi.size >= savedFileSize) {
          if (!mode.canReturnArc) continue;
        }
        if (mode.eachPos) {
          pos++;
        } else if (needScan) {
          pos++;
        } else {
          pos = pi.offset + pi.size;
        }

        // the tail relative to the whole file
        errorInfo.thereIsTail = false;
        errorInfo.tailSize = 0;
        if (phySizeDefined2) {
          final endPos = startArcPos + phySize2;
          if (endPos < savedFileSize) {
            errorInfo.thereIsTail = true;
            errorInfo.tailSize = savedFileSize - endPos;
          }
        }

        if (isOpen && mode.canReturnArc && phySizeDefined2) {
          var openCur = false;
          var thereIsTail = errorInfo.thereIsTail;
          if (thereIsTail && mode.zerosTailIsAllowed) {
            _checkZerosTail(op, arcStreamOffset + offset + phySize);
            if (errorInfo.ignoreTail) thereIsTail = false;
          }
          if (pi.offset != 0) {
            openCur = thereIsTail
                ? specFlags.canReturnMid
                : specFlags.canReturnTail;
          } else {
            openCur = !thereIsTail || specFlags.canReturnFrontal;
            if (formatIndex0 >= -2) openCur = true;
          }
          if (formatIndex0 < 0 && ai.flagsPreArc) openCur = false;
          if (!openCur && !thereIsTail) {
            if (items.isEmpty) {
              if (specFlags.canReturnTail) openCur = true;
            }
          }
          if (openCur) {
            inStream = stream;
            this.archive = archive;
            formatIndex = index;
            this.arcStreamOffset = arcStreamOffset;
            this.fileSize = savedFileSize;
            return HRes.sOk;
          }
        }
        pi.formatIndex = index;
        items.add(pi);
        wasOpen = true;
        break;
      }
      if (!wasOpen) pos++;
      needCheckStartOpen = nextNeedCheckStartOpen && wasOpen;
    }
    return null;
  }

  // CArc::OpenStream
  int openStream(OpenOptions op) {
    final res = _openStream2(op);
    if (res != HRes.sOk) return res;
    final a = archive;
    if (a != null) {
      isTree = _getArcBool(a, Kpid.isTree);
      askDeleted = _getArcBool(a, Kpid.isDeleted);
      askAltStream = _getArcBool(a, Kpid.isAltStream);
      askAux = _getArcBool(a, Kpid.isAux);
      askINode = _getArcBool(a, Kpid.iNode);
      isReadOnly = _getArcBool(a, Kpid.readOnly);

      final fileName = extractFileNameFromPath(path);
      var extension = '';
      final dotPos = fileName.lastIndexOf('.');
      if (dotPos >= 0) extension = fileName.substring(dotPos + 1);

      defaultName = '';
      if (formatIndex >= 0) {
        final ai = op.codecs.formats[formatIndex];
        if (ai.exts.isEmpty) {
          defaultName = getDefaultName2(fileName, '', '');
        } else {
          var subExtIndex = ai.findExtension(extension);
          if (subExtIndex < 0) subExtIndex = 0;
          final extInfo = ai.exts[subExtIndex];
          defaultName = getDefaultName2(fileName, extInfo.ext, extInfo.addExt);
        }
      }
    }
    return HRes.sOk;
  }

  static bool _getArcBool(InArchive a, int pid) {
    final v = a.getArchiveProperty(pid);
    if (v == null) return false;
    if (v is bool) return v;
    throw const SystemException(HRes.eFail);
  }

  // CArc::OpenStreamOrFile
  int openStreamOrFile(OpenOptions op, InStream? stdinData) {
    if (op.stdInMode) {
      op.seqStream = stdinData;
    } else if (op.stream == null) {
      path = filePath;
      try {
        final f = FileInStream.open(resolvePath(path));
        fileStream = f;
        op.stream = f;
      } on FileSystemException catch (e) {
        return hresultOfFileSystemException(e);
      }
    }
    final res = openStream(op);
    ignoreSplit = false;
    return res;
  }
}

class _NullExtractCallback extends ArchiveExtractCallback {
  @override
  OutStream? getStream(int index, int askMode) => null;
  @override
  void setOperationResult(int opRes) {}
}

// MakeCheckOrder
void _makeCheckOrder(List<ArcInfoEx> formats, List<int> orderIndices,
    int numTypes, List<int> orderIndices2, Uint8List data, int dataSize) {
  for (var i = 0; i < numTypes; i++) {
    final index = orderIndices[i];
    if (index < 0) continue;
    final ai = formats[index];
    if (ai.signatureOffset == 0) {
      if (ai.signatures.isEmpty) {
        if (dataSize != 0) continue;
      } else {
        var k = 0;
        for (; k < ai.signatures.length; k++) {
          final sig = ai.signatures[k];
          if (sig.length <= dataSize &&
              _testSignature(sig, data, 0, sig.length)) {
            break;
          }
        }
        if (k == ai.signatures.length) continue;
      }
    }
    orderIndices2.add(index);
    orderIndices[i] = -1;
  }
}

bool _testSignature(Uint8List sig, Uint8List data, int off, int size) {
  for (var i = 0; i < size; i++) {
    if (off + i >= data.length || sig[i] != data[off + i]) return false;
  }
  return true;
}

/// CParseItem (only what the non-parser mode needs).
class _ParseItem {
  int offset = 0;
  int size = 0;
  bool lenIsUnknown = false;
  int formatIndex = -1;
  void normalizeOffset() {
    if (offset < 0) {
      size += offset;
      offset = 0;
    }
  }
}

/// FindAltStreamColon_in_Path.
int findAltStreamColonInPath(String path) {
  var colonPos = -1;
  for (var i = 0; i < path.length; i++) {
    final c = path.codeUnitAt(i);
    if (c == 0x3A) {
      if (colonPos < 0) colonPos = i;
      continue;
    }
    if (c == kDirSepCode) colonPos = -1;
  }
  return colonPos;
}

/// SetProperties (SetProperties.cpp) for an archive handler.
void setArchiveProperties(
    InArchive archive, List<MapEntry<String, String>> properties) {
  if (properties.isEmpty) return;
  archive.setProperties([
    for (final p in properties) convertCliProperty(p.key, p.value),
  ]);
}

// ---------------------------------------------------------------------------
// DefaultName.cpp

// GetDefaultName3
String _getDefaultName3(
    String fileName, String extension, String addSubExtension) {
  final extLen = extension.length;
  final fileNameLen = fileName.length;
  if (fileNameLen > extLen + 1) {
    final dotPos = fileNameLen - (extLen + 1);
    if (fileName[dotPos] == '.') {
      if (extension.toLowerCase() ==
          fileName.substring(dotPos + 1).toLowerCase()) {
        return fileName.substring(0, dotPos) + addSubExtension;
      }
    }
  }
  final dotPos = fileName.lastIndexOf('.');
  if (dotPos > 0) return fileName.substring(0, dotPos) + addSubExtension;
  if (addSubExtension.isEmpty) return '$fileName~';
  return fileName + addSubExtension;
}

/// GetDefaultName2.
String getDefaultName2(
    String fileName, String extension, String addSubExtension) {
  var name = _getDefaultName3(fileName, extension, addSubExtension);
  // TrimRight
  var end = name.length;
  while (end > 0) {
    final c = name.codeUnitAt(end - 1);
    if (c == 0x20 || c == 0x0A || c == 0x09) {
      end--;
    } else {
      break;
    }
  }
  return name.substring(0, end);
}

// ---------------------------------------------------------------------------
// ArchiveOpenCallback.cpp

/// The file information of the archive file (NFind::CFileInfo).
class ArcFileInfo {
  String name = '';
  int size = 0;
  bool isDir = false;
  FiTime mTime = const FiTime(0);
}

/// COpenCallbackImp.
class OpenCallbackImp extends ArchiveOpenCallback {
  OpenCallbackUI? callback;
  String _folderPrefix = '';
  final ArcFileInfo _fileInfo = ArcFileInfo();
  bool _subArchiveMode = false;
  String _subArchiveName = '';
  bool passwordWasAsked = false;

  final List<String> fileNames = [];
  final List<bool> fileNamesWasUsed = [];
  final List<int> fileSizes = [];
  final List<FileInStream> _openedStreams = [];

  /// Init2: returns an HRESULT.
  int init2(String folderPrefix, String fileName) {
    fileNames.clear();
    fileNamesWasUsed.clear();
    fileSizes.clear();
    _subArchiveMode = false;
    passwordWasAsked = false;
    _folderPrefix = folderPrefix;
    final path = _folderPrefix + fileName;
    try {
      final st = FileStat.statSync(path);
      if (st.type == FileSystemEntityType.notFound) {
        return hresultFromErrno(Errno.enoent);
      }
      _fileInfo
        ..name = fileName
        ..size = st.size
        ..isDir = st.type == FileSystemEntityType.directory
        ..mTime = FiTime.fromDateTime(st.modified);
    } on FileSystemException catch (e) {
      return hresultOfFileSystemException(e);
    }
    return HRes.sOk;
  }

  // SetSubArchiveName
  void setSubArchiveName(String name) {
    _subArchiveMode = true;
    _subArchiveName = name;
  }

  @override
  void setTotal(int? files, int? bytes) =>
      callback?.openSetTotal(files, bytes);

  @override
  void setCompleted(int? files, int? bytes) =>
      callback?.openSetCompleted(files, bytes);

  @override
  String? get volumeName =>
      _subArchiveMode ? _subArchiveName : _fileInfo.name;

  @override
  String? get archivePath => _subArchiveMode
      ? null
      : File(_folderPrefix + _fileInfo.name).absolute.path;

  // COpenCallbackImp::GetStream
  @override
  SeekableInStream? getVolumeStream(String name) {
    if (_subArchiveMode) return null;
    callback?.openCheckBreak();
    if (kIsWin) name = name.replaceAll('/', '\\');
    if (!isSafePath(name)) return null;
    if (kIsWin) {
      // WIN32 allows wildcards in Find() function and doesn't allow
      // wildcard in File.Open()
      if (name.contains('*')) return null;
      final startPos = name.toLowerCase().startsWith('\\\\?\\') ? 3 : 0;
      if (name.indexOf('?', startPos) >= 0) return null;
    }
    final fullPath = _folderPrefix + name;
    FileStat st;
    try {
      st = FileStat.statSync(fullPath);
    } on FileSystemException {
      return null;
    }
    if (st.type == FileSystemEntityType.notFound) return null;
    if (st.type == FileSystemEntityType.directory) return null;
    FileInStream s;
    try {
      s = FileInStream.open(fullPath);
    } on FileSystemException catch (e) {
      throw SystemException(hresultOfFileSystemException(e));
    }
    _openedStreams.add(s);
    fileSizes.add(st.size);
    fileNames.add(name);
    fileNamesWasUsed.add(true);
    return s;
  }

  @override
  String? cryptoGetTextPassword() {
    final cb = callback;
    if (cb == null) throw const SystemException(HRes.eNotImpl);
    passwordWasAsked = true;
    return cb.openCryptoGetTextPassword();
  }

  void closeVolumes() {
    for (final s in _openedStreams) {
      try {
        s.close();
      } on Object {
        // ignore
      }
    }
    _openedStreams.clear();
  }
}

// CLinkLevelsInfo::Parse + IsSafePath (ArchiveExtractCallback.cpp)
bool isSafePath(String path) {
  var isAbsolute = isAbsolutePath(path);
  var lowLevel = 0;
  final parts = splitPathToParts(path);
  var level = 0;
  for (var i = 0; i < parts.length; i++) {
    final s = parts[i];
    if (s.isEmpty) {
      if (i == 0) isAbsolute = true;
      continue;
    }
    if (s == '.') continue;
    if (s == '..') {
      level--;
      if (lowLevel > level) lowLevel = level;
    } else {
      level++;
    }
  }
  return !isAbsolute && lowLevel >= 0 && level > 0;
}

/// CArchiveLink.
class ArchiveLink {
  final List<Arc> arcs = [];
  final List<String> volumePaths = [];
  int volumesSize = 0;
  bool isOpen = false;
  bool passwordWasAsked = false;

  /// The tree of the last level with its nested archives (-snest).
  FlatArc? flat;
  String nonOpenArcPath = '';
  ArcErrorInfo nonOpenErrorInfo = ArcErrorInfo();
  OpenCallbackImp? _callbackImp;

  Arc getArc() => arcs.last;
  InArchive getArchive() => arcs.last.archive!;

  // Close
  void close() {
    for (var i = arcs.length; i != 0;) {
      i--;
      arcs[i].close();
    }
    _callbackImp?.closeVolumes();
    isOpen = false;
  }

  // Release
  void release() {
    nonOpenErrorInfo.clearErrors();
    nonOpenArcPath = '';
    arcs.clear();
  }

  // CArchiveLink::Open
  int open(OpenOptions op, InStream? stdinData) {
    release();
    if (op.types.length >= 32) return HRes.eNotImpl;

    var forceCompound = op.forceCompound;
    final callerStream = op.stream;
    if (op.nestDepth > 0 && op.compoundTempDir == null && !op.stdInMode) {
      // a compressed tar is decoded to a temporary file: the nested
      // archives need random access to its items
      final t = op.nestTempDir ?? Directory.systemTemp.path;
      op.compoundTempDir =
          t.endsWith(Platform.pathSeparator) ? t : '$t${Platform.pathSeparator}';
    }
    int resSpec;
    for (;;) {
      resSpec = HRes.sOk;
      op.openType = OpenType();
      if (op.types.isNotEmpty) {
        OpenType latest;
        if (arcs.length < op.types.length) {
          latest = op.types[op.types.length - arcs.length - 1];
        } else {
          latest = op.types[0];
          if (!latest.recursive) break;
        }
        op.openType = latest.copy();
      } else if (arcs.length >= 32) {
        break;
      }

      if (arcs.isEmpty) {
        final arc = Arc()
          ..filePath = op.filePath
          ..path = op.filePath
          ..subfileIndex = -1;
        final result = arc.openStreamOrFile(op, stdinData);
        if (result == HRes.sFalse && _isTarType(op) && !op.stdInMode) {
          // -ttar on a compressed tar: the compressor, then the tar
          final outer = _openCompoundOuter(op, callerStream);
          if (outer != null) {
            arc.close();
            arcs.add(outer);
            forceCompound = true;
            continue;
          }
          op.stream = callerStream;
        }
        if (result != HRes.sOk) {
          if (result == HRes.sFalse) {
            nonOpenErrorInfo = arc.nonOpenErrorInfo;
            nonOpenArcPath = arc.path;
          }
          arc.close();
          return result;
        }
        arcs.add(arc);
        continue;
      }

      final arc = arcs.last;
      if (op.types.length > arcs.length) resSpec = HRes.eNotImpl;

      int mainSubfile;
      {
        final prop = arc.archive!.getArchiveProperty(Kpid.mainSubfile);
        if (prop is int) {
          mainSubfile = prop;
        } else {
          break;
        }
        if (mainSubfile >= arc.archive!.numberOfItems) break;
      }

      final subStream = arc.archive!.getStream(mainSubfile);
      if (subStream == null) break;

      final arc2 = Arc()..path = arc.getItemPath(mainSubfile);
      final zerosTailIsAllowed = archiveGetItemBoolProp(
          arc.archive!, mainSubfile, Kpid.zerosTailIsAllowed);
      op.callbackSpec?.setSubArchiveName(arc2.path);
      arc2.subfileIndex = mainSubfile;

      final op2 = OpenOptions()
        ..props = op.props
        ..codecs = op.codecs
        ..openType = op.openType.copy()
        ..excludedFormats = const []
        ..stdInMode = false
        ..stream = subStream
        ..filePath = arc2.path
        ..callback = op.callback
        ..callbackSpec = op.callbackSpec;
      op2.openType.zerosTailIsAllowed = zerosTailIsAllowed;
      op2.types = const [];

      final result = arc2.openStream(op2);
      resSpec = op.types.isEmpty ? HRes.sOk : HRes.sFalse;
      if (result == HRes.sFalse) {
        nonOpenErrorInfo = arc2.errorInfo;
        nonOpenArcPath = arc2.path;
        break;
      }
      if (result != HRes.sOk) return result;
      arc2.mTime.copyFrom(arc.getItemMTime(mainSubfile));
      arcs.add(arc2);
    }

    // a tar inside a compressor (arc_compound.dart): without -t by the
    // names, with -ttar, with the chain -ttar.gzip (tar inside gzip) or
    // when the caller asks for it
    if (arcs.length == 1) {
      final tarIndex = op.codecs.findFormatForArchiveType('tar');
      final chain = op.types.length == 2 && op.types[0].formatIndex == tarIndex;
      if (chain || forceCompound || op.types.isEmpty) {
        final r = _openCompoundTar(op, chain || forceCompound, tarIndex);
        if (r == HRes.sOk) {
          resSpec = HRes.sOk;
        } else if (r != HRes.sFalse) {
          return r;
        } else if (chain || forceCompound) {
          // -ttar (or the chain) and the compressed data is not a tar
          nonOpenArcPath = arcs[0].path;
          nonOpenErrorInfo = ArcErrorInfo()..errorFormatIndex = tarIndex;
          return HRes.sFalse;
        }
      }
    }
    if (op.nestDepth > 0 && arcs.isNotEmpty && arcs.last.archive != null) {
      final last = arcs.last;
      try {
        final f = FlatArc.build(op.codecs, last,
            maxDepth: op.nestDepth,
            ui: op.callbackSpec?.callback,
            layout: op.nestLayout,
            keepTemps: op.nestKeepTemps,
            tempDir: op.nestTempDir);
        last.archive = f;
        flat = f;
      } on SystemException catch (e) {
        return e.errorCode;
      }
    }
    isOpen = arcs.isNotEmpty;
    return resSpec;
  }

  bool _isTarType(OpenOptions op) =>
      op.types.length == 1 &&
      op.types[0].formatIndex >= 0 &&
      op.codecs.formats[op.types[0].formatIndex].name == 'tar';

  // Opens the file with format detection, for -ttar on a compressed tar;
  // null when it is not a compressor.
  Arc? _openCompoundOuter(OpenOptions op, SeekableInStream? callerStream) {
    op.stream = callerStream;
    op.openType = OpenType();
    final arc = Arc()
      ..filePath = op.filePath
      ..path = op.filePath
      ..subfileIndex = -1;
    final r = arc.openStreamOrFile(op, null);
    if (r == HRes.sOk &&
        arc.formatIndex >= 0 &&
        isCompoundOuterFormat(op.codecs.formats[arc.formatIndex])) {
      return arc;
    }
    arc.close();
    op.stream = callerStream;
    return null;
  }

  // The tar level of a compound archive over arcs[0]; S_FALSE when it is
  // not one.
  int _openCompoundTar(OpenOptions op, bool forced, int tarIndex) {
    final outer = arcs[0];
    final outerArchive = outer.archive;
    if (tarIndex < 0 || outer.formatIndex < 0 || outerArchive == null) {
      return HRes.sFalse;
    }
    if (!isCompoundOuterFormat(op.codecs.formats[outer.formatIndex])) {
      return HRes.sFalse;
    }
    if (outerArchive.numberOfItems != 1) return HRes.sFalse;
    final innerPath = outer.getItemPath(0);
    if (!forced) {
      if (op.stdInMode) return HRes.sFalse;
      if (!looksLikeCompoundTar(outer.path, innerPath) &&
          !sniffCompoundTar(outerArchive)) {
        return HRes.sFalse;
      }
    }
    final arc2 = Arc()
      ..path = innerPath
      ..subfileIndex = 0
      ..compoundOuterIndex = outer.formatIndex;
    op.callbackSpec?.setSubArchiveName(innerPath);

    final tempDir = op.compoundTempDir;
    if (tempDir != null && !op.stdInMode) {
      final tmp = decodeCompoundToTempFile(outerArchive, tempDir);
      if (tmp == null) return HRes.sFalse;
      final FileInStream f;
      try {
        f = FileInStream.open(tmp);
      } on FileSystemException catch (e) {
        File(tmp).deleteSync();
        return hresultOfFileSystemException(e);
      }
      arc2
        ..fileStream = f
        ..tempPath = tmp;
      final op2 = OpenOptions()
        ..props = op.props
        ..codecs = op.codecs
        ..openType = (OpenType()
          ..formatIndex = tarIndex
          ..zerosTailIsAllowed = true)
        ..excludedFormats = const []
        ..stream = f
        ..filePath = innerPath
        ..callback = op.callback
        ..callbackSpec = op.callbackSpec;
      final r = arc2.openStream(op2);
      if (r != HRes.sOk) {
        arc2.close();
        return r;
      }
    } else {
      final decoded = outerArchive.getSeqStream(0);
      if (decoded == null) return HRes.sFalse;
      final a = SeqTarArc(decoded);
      final props = op.props;
      if (props != null && props.isNotEmpty) setArchiveProperties(a, props);
      final int r;
      try {
        r = a.openSeqTar();
      } on SevenZipException {
        return HRes.sFalse;
      }
      if (r != HRes.sOk) return HRes.sFalse;
      arc2
        ..archive = a
        ..formatIndex = tarIndex
        ..isSeq = true
        ..defaultName = getDefaultName2(
            extractFileNameFromPath(innerPath), 'tar', '');
      arc2.refreshSeqErrors();
    }
    arc2.mTime.copyFrom(outer.getItemMTime(0));
    arcs.add(arc2);
    return HRes.sOk;
  }

  // CArchiveLink::Open2
  int open2(OpenOptions op, OpenCallbackUI? callbackUI, InStream? stdinData) {
    volumesSize = 0;
    final openCallbackSpec = OpenCallbackImp()..callback = callbackUI;
    _callbackImp = openCallbackSpec;

    if (op.stream == null && !op.stdInMode) {
      final (prefix, name) = getFullPathAndSplit(op.filePath);
      final r = openCallbackSpec.init2(prefix, name);
      if (r != HRes.sOk) return r;
    } else {
      openCallbackSpec.setSubArchiveName(op.filePath);
    }
    op.callback = openCallbackSpec;
    op.callbackSpec = openCallbackSpec;

    final res = open(op, stdinData);
    passwordWasAsked = openCallbackSpec.passwordWasAsked;
    if (res != HRes.sOk) return res;

    final (prefix, _) = op.stream == null && !op.stdInMode
        ? getFullPathAndSplit(op.filePath)
        : ('', '');
    for (var i = 0; i < openCallbackSpec.fileNamesWasUsed.length; i++) {
      if (openCallbackSpec.fileNamesWasUsed[i]) {
        volumePaths.add(prefix + openCallbackSpec.fileNames[i]);
        volumesSize += openCallbackSpec.fileSizes[i];
      }
    }
    return HRes.sOk;
  }

  // Open3
  int open3(OpenOptions op, OpenCallbackUI? callbackUI, InStream? stdinData) {
    final res = open2(op, callbackUI, stdinData);
    callbackUI?.openFinished();
    return res;
  }

  // Open_Strict
  int openStrict(
      OpenOptions op, OpenCallbackUI? callbackUI, InStream? stdinData) {
    var result = open3(op, callbackUI, stdinData);
    if (result == HRes.sOk && nonOpenErrorInfo.errorFormatIndex >= 0) {
      result = HRes.sFalse;
    }
    return result;
  }
}

/// NDir::GetFullPathAndSplit: (dir prefix with the separator, name).
(String, String) getFullPathAndSplit(String path) {
  final full = myGetFullPathName(path);
  final pos = reverseFindPathSepar(full);
  return (full.substring(0, pos + 1), full.substring(pos + 1));
}

/// Current directory override for in-process runs.
String? cliCurrentDirectory;

/// MyGetFullPathName: the absolute path, "." and ".." resolved textually.
/// Windows: GetFullPathNameW, the '/' separators become '\' (the port
/// resolves the path with GetFullPath of FileName.cpp).
String myGetFullPathName(String path) {
  final cwd = cliCurrentDirectory ?? Directory.current.path;
  if (kIsWin) {
    return getFullPathWin(normalizeDirSeparators(path), cwd) ?? path;
  }
  var p = path.startsWith('/') ? path : '$cwd/$path';
  final parts = p.split('/');
  final out = <String>[];
  for (var i = 0; i < parts.length; i++) {
    final s = parts[i];
    if (s.isEmpty && i != parts.length - 1) continue;
    if (s == '.') {
      if (i == parts.length - 1) out.add('');
      continue;
    }
    if (s == '..') {
      if (out.isNotEmpty) out.removeLast();
      if (i == parts.length - 1) out.add('');
      continue;
    }
    out.add(s);
  }
  p = '/${out.join('/')}';
  return p;
}

// ---------------------------------------------------------------------------
// ParseOpenTypes

/// ParseComplexSize.
int? parseComplexSize(String s) {
  final (number, n) = convertStringToUInt64(s);
  if (n == 0) return null;
  if (n == s.length) return number;
  if (n + 1 != s.length) return null;
  int numBits;
  switch (s[n].toLowerCase()) {
    case 'b':
      return number;
    case 'k':
      numBits = 10;
    case 'm':
      numBits = 20;
    case 'g':
      numBits = 30;
    case 't':
      numBits = 40;
    default:
      return null;
  }
  if (compareU64(number, 1 << (64 - numBits)) >= 0) return null;
  return number << numBits;
}

// ParseTypeParams
bool _parseTypeParams(String s, OpenType type) {
  if (s.isEmpty) return true;
  if (s.length == 1) {
    switch (s) {
      case 'e':
        type.eachPos = true;
        return true;
      case 'a':
        type.canReturnArc = true;
        return true;
      case 'r':
        type.recursive = true;
        return true;
    }
    return false;
  }
  if (s[0] == 's') {
    final result = parseComplexSize(s.substring(1));
    if (result == null) return false;
    type.maxStartOffset = result;
    type.maxStartOffsetDefined = true;
    return true;
  }
  return false;
}

// ParseType
bool _parseType(Codecs codecs, String s, OpenType type) {
  var pos2 = s.indexOf(':');
  String name;
  if (pos2 < 0) {
    name = s;
    pos2 = s.length;
  } else {
    name = s.substring(0, pos2);
    pos2++;
  }
  final index = codecs.findFormatForArchiveType(name);
  type.recursive = false;
  if (index < 0) {
    if (name.startsWith('*')) {
      if (name.length != 1) return false;
    } else if (name.startsWith('#')) {
      if (name.length != 1) return false;
      type.canReturnArc = false;
      type.canReturnParser = true;
    } else if (name.toLowerCase() == 'hash') {
      type.isHashType = true;
    } else {
      return false;
    }
  }
  type.formatIndex = index;

  for (var i = pos2; i < s.length;) {
    var next = s.indexOf(':', i);
    if (next < 0) next = s.length;
    final name2 = s.substring(i, next);
    if (name2.isEmpty) return false;
    if (!_parseTypeParams(name2, type)) return false;
    i = next + 1;
  }
  return true;
}

/// ParseOpenTypes: null for false.
List<OpenType>? parseOpenTypes(Codecs codecs, String s) {
  final types = <OpenType>[];
  var isHashType = false;
  for (var pos = 0; pos < s.length;) {
    var pos2 = s.indexOf('.', pos);
    if (pos2 < 0) pos2 = s.length;
    final name = s.substring(pos, pos2);
    if (name.isEmpty) return null;
    final type = OpenType();
    if (!_parseType(codecs, name, type)) return null;
    if (isHashType) return null;
    if (type.isHashType) isHashType = true;
    types.add(type);
    pos = pos2 + 1;
  }
  return types;
}

// FindFormatForArchiveType (OpenArchive.cpp): the position in
// [orderIndices] of the format named [name], or -1
int _findFormatInOrder(
    List<ArcInfoEx> formats, List<int> orderIndices, String name) {
  for (var i = 0; i < orderIndices.length; i++) {
    final oi = orderIndices[i];
    if (oi >= 0 && formats[oi].name.toLowerCase() == name) return i;
  }
  return -1;
}
