// The extract callback that writes the files: UI/Common/ArchiveExtractCallback
// .cpp of the LZMA SDK (CArchiveExtractCallback: output paths, overwrite
// modes, directories, attributes and times, symbolic links of POSIX, hash
// calculation for -scrc), POSIX build.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../format/archive_types.dart';
import '../io/streams.dart';
import 'common.dart';
import 'extracting_file_path.dart';
import 'file_link.dart';
import 'fs_utils.dart';
import 'globals.dart';
import 'hash_calc.dart';
import 'open_archive.dart';
import 'platform.dart';
import 'wildcard.dart';

/// NExtract::NPathMode.
enum PathMode { fullPaths, curPaths, noPaths, absPaths, noPathsAlt }

/// NExtract::NOverwriteMode.
enum OverwriteMode { ask, overwrite, skip, rename, renameExisting }

/// NOverwriteAnswer.
enum OverwriteAnswer { yes, yesToAll, no, noToAll, autoRename, cancel }

/// NExtractOutDirMode.
enum ExtractOutDirMode { direct, addArcName, replaceAsterisk }

/// CExtractNtOptions.
class ExtractNtOptions {
  BoolPair2 ntSecurity = BoolPair2();
  BoolPair2 symLinks = BoolPair2(true);
  BoolPair2 hardLinks = BoolPair2(true);
  BoolPair2 altStreams = BoolPair2(true);
  bool replaceColonForAltStream = false;
  bool writeToAltStreamIfColon = false;
  bool extractOwner = false;
  bool preAllocateOutFile = false;
  bool preserveATime = false;
  bool openShareForWrite = false;
  int symLinksDangerousLevel = 5;
  int memLimit = -1;
}

/// IFolderArchiveExtractCallback + IFolderArchiveExtractCallback2 +
/// ICryptoGetTextPassword of the UI.
abstract class FolderArchiveExtractCallback {
  void setTotal(int total);
  void setCompleted(int? completeValue);
  OverwriteAnswer askOverwrite(String existName, int? existTime,
      int? existSize, String newName, int? newTime, int? newSize);
  void prepareOperation(
      String name, bool isFolder, int askExtractMode, int? position);
  void messageError(String message);
  void setOperationResult(int opRes, bool encrypted);
  void reportExtractResult(int opRes, bool encrypted, String name);
  String cryptoGetTextPassword();
}

// kOfficeExtensions
const String _kOfficeExtensions = ' doc dot wbk'
    ' docx docm dotx dotm docb wll wwl'
    ' xls xlt xlm'
    ' xlsx xlsm xltx xltm xlsb xla xlam'
    ' ppt pot pps ppa ppam'
    ' pptx pptm potx potm ppam ppsx ppsm sldx sldm'
    ' ';

// FindExt2
bool _findExt2(String p, String name) {
  final pathPos = reverseFindPathSepar(name);
  final dotPos = name.lastIndexOf('.');
  if (dotPos < 0 || dotPos < pathPos || dotPos == name.length - 1) {
    return false;
  }
  final ext = name.substring(dotPos + 1);
  for (final c in ext.codeUnits) {
    if (c >= 0x80) return false;
  }
  return p.contains(' ${ext.toLowerCase()} ');
}

const String _kZoneIdStreamNameWithColonPrefix = ':Zone.Identifier';

// Is_ZoneId_StreamName
bool _isZoneIdStreamName(String s) =>
    s.toLowerCase() == _kZoneIdStreamNameWithColonPrefix.substring(1).toLowerCase();

/// ReadZoneFile_Of_BaseFile (Windows): the Zone.Identifier stream of
/// [fileName] (dart:io opens alternate streams by name on NTFS).
Uint8List? readZoneFileOfBaseFile(String fileName) {
  try {
    final f = File(fileName + _kZoneIdStreamNameWithColonPrefix);
    final data = f.readAsBytesSync();
    if (data.isEmpty || data.length >= (1 << 15)) return null;
    return data;
  } on FileSystemException {
    return null;
  }
}

// WriteZoneFile_To_BaseFile
bool _writeZoneFileToBaseFile(String fileName, Uint8List buf) {
  try {
    File(fileName + _kZoneIdStreamNameWithColonPrefix).writeAsBytesSync(buf);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// CensorNode_CheckPath2: (found, include).
(bool, bool) censorNodeCheckPath2(CensorNode node, ReadArcItem item) {
  var found = false;
  var include = false;
  final r = node.checkPathVect(item.pathParts, !item.mainIsDir);
  if (r.$1) {
    include = r.$2;
    if (!include) return (true, include);
    if (!item.isAltStream) return (true, include);
    found = true;
  }
  if (!item.isAltStream) return (false, include);
  final pathParts2 = List.of(item.pathParts);
  if (pathParts2.isEmpty) pathParts2.add('');
  pathParts2[pathParts2.length - 1] =
      '${pathParts2.last}:${item.altStreamName}';
  final r2 = node.checkPathVect(pathParts2, true);
  if (r2.$1) return (true, r2.$2);
  return (found, include);
}

/// CensorNode_CheckPath.
bool censorNodeCheckPath(CensorNode node, ReadArcItem item) {
  final (found, include) = censorNodeCheckPath2(node, item);
  return found && include;
}

/// CProcessedFileInfo.
class _ProcessedFileInfo {
  final ArcTime cTime = ArcTime();
  final ArcTime aTime = ArcTime();
  final ArcTime mTime = ArcTime();
  int attrib = 0;
  bool attribDefined = false;

  bool isLinuxSymLink() =>
      attribDefined && ((attrib >> 16) & 0xF000) == 0xA000;

  bool isReparse() => attribDefined && (attrib & 0x400) != 0;

  void setFromPosixAttrib(int a) {
    attrib = ((a << 16) | 0x8000) & 0xFFFFFFFF;
    attribDefined = true;
  }

  _ProcessedFileInfo copy() {
    final r = _ProcessedFileInfo()
      ..attrib = attrib
      ..attribDefined = attribDefined;
    r.cTime.copyFrom(cTime);
    r.aTime.copyFrom(aTime);
    r.mTime.copyFrom(mTime);
    return r;
  }
}

/// CFiTimesCAM (the times to set on a file).
class _FiTimesCAM {
  int? cTime;
  int? aTime;
  int? mTime;
  int mNs100 = 0;
  bool isSomeTimeDefined() => cTime != null || aTime != null || mTime != null;
}

// GetFiTimesCAM
_FiTimesCAM _getFiTimesCAM(_ProcessedFileInfo fi, Arc arc) {
  final pt = _FiTimesCAM();
  if (fi.mTime.def) {
    pt.mTime = fi.mTime.ft;
    if (fi.mTime.prec == TimePrecVals.base + 8 ||
        fi.mTime.prec == TimePrecVals.base + 9) {
      pt.mNs100 = fi.mTime.ns100;
    }
  } else if (arc.mTime.def) {
    pt.mTime = arc.mTime.ft;
    if (arc.mTime.prec == TimePrecVals.base + 8 ||
        arc.mTime.prec == TimePrecVals.base + 9) {
      pt.mNs100 = arc.mTime.ns100;
    }
  }
  if (fi.cTime.def) pt.cTime = fi.cTime.ft;
  if (fi.aTime.def) pt.aTime = fi.aTime.ft;
  return pt;
}

/// CDirPathTime.
class _DirPathTime {
  final String path;
  final _FiTimesCAM t;
  _DirPathTime(this.path, this.t);
}

/// CLinkInfo (symbolic links of POSIX archives).
class _LinkInfo {
  String linkPath = '';
  bool isRelative = false;
  bool isHardLink = false;

  // Parse_from_LinuxData
  bool parseFromLinuxData(Uint8List data) {
    if (data.length >= (1 << 12)) return false;
    var n = data.indexOf(0);
    if (n < 0) n = data.length;
    String u;
    try {
      u = const Utf8Decoder(allowMalformed: false)
          .convert(Uint8List.sublistView(data, 0, n));
    } on FormatException {
      return false;
    }
    if (u.isEmpty) return false;
    isRelative = !u.startsWith('/');
    // REPLACE_SLASHES_from_Linux_to_Sys
    linkPath = replaceToWinSlashes(u);
    return true;
  }

  // Parse_from_WindowsReparseData (used by the Windows build)
  bool parseFromWindowsReparseData(Uint8List data) {
    final reparse = ReparseAttr();
    if (!reparse.parse(data)) return false;
    linkPath = reparse.getPath();
    if (reparse.isSymLinkWsl) {
      isRelative = reparse.isRelativeWsl;
      linkPath = replaceToWinSlashes(linkPath);
    } else {
      isRelative = reparse.isRelativeWin;
      linkPath = linkPath.replaceAll(kIsWin ? '/' : '\\', kDirSep);
    }
    return true;
  }

  // Remove_AbsPathPrefixes
  void _removeAbsPathPrefixes() {
    while (linkPath.isNotEmpty) {
      var n = getRootPrefixSize(linkPath);
      if (n == 0) {
        if (!isPathSepar(linkPath.codeUnitAt(0))) break;
        n = 1;
      }
      isRelative = false;
      linkPath = linkPath.substring(n);
    }
  }

  // Normalize_to_RelativeSafe
  void normalizeToRelativeSafe(List<String> removePathParts) {
    // RemoveRedundantPathSeparators
    final sb = StringBuffer();
    for (var i = 0; i < linkPath.length; i++) {
      final c = linkPath[i];
      if (c == kDirSep && sb.length >= 2 && sb.toString().endsWith(kDirSep)) {
        continue;
      }
      sb.write(c);
    }
    linkPath = sb.toString();
    _removeAbsPathPrefixes();
    if (linkPath.isEmpty || isRelative || removePathParts.isEmpty) return;
    final pathParts = splitPathToParts(linkPath);
    var badPrefix = false;
    for (var i = 0; i < removePathParts.length; i++) {
      if (i >= pathParts.length ||
          compareFileNames(removePathParts[i], pathParts[i]) != 0) {
        badPrefix = true;
        break;
      }
    }
    if (!badPrefix) pathParts.removeRange(0, removePathParts.length);
    linkPath = makePathFromParts(pathParts);
    _removeAbsPathPrefixes();
  }
}

/// CPostLink.
class _PostLink {
  int indexInArc = 0;
  bool itemIsDir = false;
  String itemPath = '';
  List<String> itemPathParts = [];
  late _ProcessedFileInfo itemFileInfo;
  String fullProcessedPathFrom = '';
  final _LinkInfo linkInfo = _LinkInfo();
}

/// CLinkLevelsInfo.
class _LinkLevelsInfo {
  bool isAbsolute = false;
  bool parentDirDotsAfterNonParent = false;
  int lowLevel = 0;
  int finalLevel = 0;

  void parse(String path) {
    isAbsolute = isAbsolutePath(path);
    lowLevel = 0;
    finalLevel = 0;
    parentDirDotsAfterNonParent = false;
    var nonParentDir = false;
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
        if (isAbsolute || nonParentDir) parentDirDotsAfterNonParent = true;
        level--;
        if (lowLevel > level) lowLevel = level;
      } else {
        nonParentDir = true;
        level++;
      }
    }
    finalLevel = level;
  }
}

/// COutStreamWithHash around the real output.
class _HashOutStream implements OutStream {
  OutStream? stream;
  final HashBundle hash;
  int size = 0;
  _HashOutStream(this.hash);

  void init() {
    size = 0;
    hash.initForNewFile();
  }

  @override
  void write(Uint8List buf, int off, int len) {
    stream?.write(buf, off, len);
    hash.update(buf, off, len);
    size += len;
  }

  @override
  void flush() => stream?.flush();
}

/// The output file (COutFileStream) with its processed size.
class _OutFile implements OutStream {
  final FileOutStream s;
  final String path;
  int processedSize = 0;
  _OutFile(this.s, this.path);

  @override
  void write(Uint8List buf, int off, int len) {
    try {
      s.write(buf, off, len);
    } on FileSystemException catch (e) {
      throw SystemException(hresultOfFileSystemException(e));
    }
    processedSize += len;
  }

  @override
  void flush() {}
}

/// Collects the data of a symbolic link item (CBufPtrSeqOutStream).
class _MemOut implements OutStream {
  final Uint8List buf;
  int pos = 0;
  _MemOut(int size) : buf = Uint8List(size);
  @override
  void write(Uint8List b, int off, int len) {
    var n = len;
    if (n > buf.length - pos) n = buf.length - pos;
    if (n > 0) buf.setRange(pos, pos + n, b, off);
    pos += n;
  }

  @override
  void flush() {}
}

/// CStdOutFileStream.
class StdOutFileStream implements OutStream {
  int size = 0;
  final BytesBuilder _buf = BytesBuilder(copy: true);
  @override
  void write(Uint8List buf, int off, int len) {
    if (len == 0) return;
    _buf.add(Uint8List.sublistView(buf, off, off + len));
    size += len;
    if (_buf.length >= (1 << 16)) flush();
  }

  @override
  void flush() {
    if (_buf.isEmpty) return;
    gIo.writeOut(_buf.takeBytes());
  }
}

/// CArchiveExtractCallback.
class ArchiveExtractCallbackImpl extends ArchiveExtractCallback
    implements CryptoGetTextPassword, ArchiveExtractCallbackMessage2 {
  bool _multiArchives = false;
  PathMode _pathMode = PathMode.fullPaths;
  OverwriteMode _overwriteMode = OverwriteMode.ask;
  bool _keepAndReplaceEmptyDirPrefixes = false;

  int numFolders = 0;
  int numFiles = 0;
  int numAltStreams = 0;
  int unpackSize = 0;
  int altStreamsUnpackSize = 0;

  /// LocalProgressSpec->InSize and OutSize.
  int localProgressInSize = 0;
  int localProgressOutSize = 0;

  ExtractNtOptions _ntOptions = ExtractNtOptions();
  CensorNode? _wildcardCensor;
  Arc? _arc;
  late FolderArchiveExtractCallback _extractCallback2;
  bool _stdOutMode = false;
  bool _testMode = false;
  int _packTotal = 0;
  int _progressTotal = 0;
  List<String> _removePathParts = [];
  bool _removePartsForAltStreams = false;
  String _dirPathPrefix = '';
  String _dirPathPrefixFull = '';
  bool isElimPrefixMode = false;

  HashBundle? _hash;
  _HashOutStream? _hashStream;
  bool _hashStreamWasUsed = false;

  // item state
  final ReadArcItem _item = ReadArcItem();
  _ProcessedFileInfo _fi = _ProcessedFileInfo();
  int _index = 0;
  bool _encrypted = false;
  bool _isSplit = false;
  bool _curSizeDefined = false;
  int _curSize = 0;
  int _position = 0;
  bool _extractMode = false;
  bool _isSymLinkInDataLinux = false;
  bool _needSetAttrib = false;
  bool _isSymLinkCreated = false;
  bool _itemFailure = false;
  bool _somePathPartsWereRemoved = false;
  String _diskFilePath = '';
  _LinkInfo _link = _LinkInfo();

  _OutFile? _outFileStream;
  _MemOut? _bufPtrSeqOutStream;
  StdOutFileStream? stdOutStream;

  final List<_DirPathTime> _extractedFolders = [];
  final List<_PostLink> _postLinks = [];

  /// DirPathPrefix_for_HashFiles.
  String dirPathPrefixForHashFiles = '';

  /// ZoneBuf and ZoneMode (-snz, Windows).
  Uint8List? zoneBuf;
  int zoneMode = 0;

  // InitForMulti
  void initForMulti(bool multiArchives, PathMode pathMode,
      OverwriteMode overwriteMode, bool keepAndReplaceEmptyDirPrefixes) {
    _multiArchives = multiArchives;
    _pathMode = pathMode;
    _overwriteMode = overwriteMode;
    _keepAndReplaceEmptyDirPrefixes = keepAndReplaceEmptyDirPrefixes;
    numFolders = numFiles = numAltStreams = unpackSize = altStreamsUnpackSize = 0;
  }

  // SetHashMethods
  void setHashMethods(HashBundle? hash) {
    if (hash == null) return;
    _hash = hash;
    _hashStream = _HashOutStream(hash);
  }

  // InitBeforeNewArchive
  void initBeforeNewArchive() {}

  // Init
  void init(
      ExtractNtOptions ntOptions,
      CensorNode? wildcardCensor,
      Arc arc,
      FolderArchiveExtractCallback extractCallback2,
      bool stdOutMode,
      bool testMode,
      String directoryPath,
      List<String> removePathParts,
      bool removePartsForAltStreams,
      int packSize) {
    _extractedFolders.clear();
    _outFileStream = null;
    _bufPtrSeqOutStream = null;
    _postLinks.clear();
    _ntOptions = ntOptions;
    _wildcardCensor = wildcardCensor;
    _stdOutMode = stdOutMode;
    _testMode = testMode;
    _packTotal = packSize;
    _progressTotal = packSize;
    _extractCallback2 = extractCallback2;
    _removePathParts = removePathParts;
    _removePartsForAltStreams = removePartsForAltStreams;
    _arc = arc;
    _dirPathPrefix = normalizeDirPathPrefix(directoryPath);
    _dirPathPrefixFull =
        normalizeDirPathPrefix(myGetFullPathName(directoryPath));
  }

  @override
  void setTotal(int total) {
    _progressTotal = total;
    if (!_multiArchives) _extractCallback2.setTotal(total);
  }

  static void _normalizeVals(List<int> v1v2) {
    const kMax = 1 << 31;
    while (v1v2[0] > kMax) {
      v1v2[0] >>= 1;
      v1v2[1] >>= 1;
    }
  }

  // MyMultDiv64
  static int _myMultDiv64(int unpCur, int unpTotal, int packTotal) {
    final a = [packTotal, unpTotal];
    _normalizeVals(a);
    packTotal = a[0];
    unpTotal = a[1];
    final b = [unpCur, unpTotal];
    _normalizeVals(b);
    unpCur = b[0];
    unpTotal = b[1];
    if (unpTotal == 0) unpTotal = 1;
    return unpCur * packTotal ~/ unpTotal;
  }

  @override
  void setCompleted(int completeValue) {
    var v = completeValue;
    if (_multiArchives) {
      v = localProgressInSize +
          _myMultDiv64(completeValue, _progressTotal, _packTotal);
    }
    _extractCallback2.setCompleted(v);
  }

  // CreateComplexDirectory: returns fullPath.
  String _createComplexDirectory(List<String> dirPathParts, bool isFinal) {
    var isAbsPath = false;
    if (dirPathParts.isNotEmpty && dirPathParts[0].isEmpty) isAbsPath = true;
    var fullPath =
        (_pathMode == PathMode.absPaths && isAbsPath) ? '' : _dirPathPrefix;
    for (var i = 0; i < dirPathParts.length; i++) {
      if (i != 0) fullPath += kDirSep;
      fullPath += dirPathParts[i];
      final isFinalDir =
          i == dirPathParts.length - 1 && isFinal && _item.isDir;
      if (fullPath.isEmpty) {
        if (isFinalDir) _itemFailure = true;
        continue;
      }
      var hres = HRes.sOk;
      if (!createDir(fullPath)) hres = hresultFromErrno(lastFindErrno);
      if (isFinalDir) {
        if (!doesDirExist(fullPath)) {
          _itemFailure = true;
          _sendMessageErrorWithError(hres, 'Cannot create folder', fullPath);
        }
      }
    }
    return fullPath;
  }

  ArcTime _getTime(int index, int propId) {
    final ft = ArcTime();
    final p = _arc!.archive!.getProperty(index, propId);
    if (p is int) {
      ft.setFromProp(p, _arc!.archive!.timePrec);
    } else if (p != null) {
      throw const SystemException(HRes.eFail);
    }
    return ft;
  }

  // GetUnpackSize
  void _getUnpackSize() {
    final (size, defined) = _arc!.getItemSize(_index);
    _curSize = size;
    _curSizeDefined = defined;
  }

  void _sendMessageError(String message, String path) =>
      _extractCallback2.messageError('$message : $path');

  void _sendMessageErrorWithError(int errorCode, String message, String path) {
    var s = message;
    if (errorCode != HRes.sOk) s += ' : ${myFormatMessage(errorCode)}';
    s += ' : $path';
    _extractCallback2.messageError(s);
  }

  void _sendMessageErrorWithLastError(String message, String path) =>
      _sendMessageErrorWithError(
          hresultFromErrno(lastFindErrno == 0 ? Errno.einval : lastFindErrno),
          message,
          path);

  void _sendMessageError2(
      int errorCode, String message, String path1, String path2) {
    var s = message;
    if (errorCode != 0) s += ' : ${myFormatMessage(errorCode)}';
    s += ' : $path1 : $path2';
    _extractCallback2.messageError(s);
  }

  // Read_fi_Props
  void _readFiProps() {
    final archive = _arc!.archive!;
    final index = _index;
    _fi = _ProcessedFileInfo();
    {
      final p = archive.getProperty(index, Kpid.posixAttrib);
      if (p is int) {
        _fi.setFromPosixAttrib(p);
      } else if (p != null) {
        throw const SystemException(HRes.eFail);
      }
    }
    {
      final p = archive.getProperty(index, Kpid.attrib);
      if (p is int) {
        _fi.attrib = p & 0xFFFFFFFF;
        _fi.attribDefined = true;
      } else if (p != null) {
        throw const SystemException(HRes.eFail);
      }
    }
    _fi.cTime.copyFrom(_getTime(index, Kpid.cTime));
    _fi.aTime.copyFrom(_getTime(index, Kpid.aTime));
    _fi.mTime.copyFrom(_getTime(index, Kpid.mTime));
  }

  // CorrectPathParts
  void _correctPathParts() {
    correctFsPath(_pathMode == PathMode.absPaths,
        _keepAndReplaceEmptyDirPrefixes, _item.pathParts, _item.mainIsDir);
  }

  // CreateFolders
  void _createFolders() {
    final pathParts = List.of(_item.pathParts);
    var isFinal = true;
    if (pathParts.isNotEmpty) {
      if (!_item.isDir || _link.linkPath.isNotEmpty) {
        pathParts.removeLast();
        isFinal = false;
      }
    }
    if (pathParts.isEmpty) {
      if (!_somePathPartsWereRemoved || !isElimPrefixMode) return;
    }
    final fullPathNew = _createComplexDirectory(pathParts, isFinal);
    if (!_item.isDir) return;
    if (fullPathNew.isEmpty) return;
    if (_itemFailure) return;
    final pt = _getFiTimesCAM(_fi, _arc!);
    if (pt.isSomeTimeDefined()) {
      // the SDK also sets the times here; the final pass sets them again
      _extractedFolders.add(_DirPathTime(fullPathNew, pt));
    }
  }

  // CheckExistFile: returns (path, needExit).
  (String, bool) _checkExistFile(String fullProcessedPath) {
    final fileInfo = findFile(fullProcessedPath);
    if (fileInfo != null) {
      if (_overwriteMode == OverwriteMode.skip) return (fullProcessedPath, true);
      if (_overwriteMode == OverwriteMode.ask) {
        final slashPos = reverseFindPathSepar(fullProcessedPath);
        final realFullProcessedPath =
            fullProcessedPath.substring(0, slashPos + 1) + fileInfo.name;
        final answer = _extractCallback2.askOverwrite(
            realFullProcessedPath,
            fileInfo.mTime.ft,
            fileInfo.size,
            _item.path,
            _fi.mTime.def ? _fi.mTime.ft : null,
            _curSizeDefined ? _curSize : null);
        switch (answer) {
          case OverwriteAnswer.cancel:
            throw const SystemException(HRes.eAbort);
          case OverwriteAnswer.no:
            return (fullProcessedPath, true);
          case OverwriteAnswer.noToAll:
            _overwriteMode = OverwriteMode.skip;
            return (fullProcessedPath, true);
          case OverwriteAnswer.yes:
            break;
          case OverwriteAnswer.yesToAll:
            _overwriteMode = OverwriteMode.overwrite;
          case OverwriteAnswer.autoRename:
            _overwriteMode = OverwriteMode.rename;
        }
      }
      if (_overwriteMode == OverwriteMode.rename) {
        final newPath = autoRenamePath(fullProcessedPath);
        if (newPath == null) {
          _sendMessageError('Cannot create file with auto name', fullProcessedPath);
          throw const SystemException(HRes.eFail);
        }
        fullProcessedPath = newPath;
      } else if (_overwriteMode == OverwriteMode.renameExisting) {
        final existPath = autoRenamePath(fullProcessedPath);
        if (existPath == null) {
          _sendMessageError('Cannot create file with auto name', fullProcessedPath);
          throw const SystemException(HRes.eFail);
        }
        if (!myMoveFile(fullProcessedPath, existPath)) {
          _sendMessageError2(hresultFromErrno(lastFindErrno),
              'Cannot rename existing file', existPath, fullProcessedPath);
          throw const SystemException(HRes.eFail);
        }
      } else {
        if (fileInfo.isDir) {
          if (!removeDir(fullProcessedPath)) {
            _sendMessageErrorWithLastError(
                'Cannot delete output folder', fullProcessedPath);
            return (fullProcessedPath, true);
          }
        } else {
          if (doesFileExistRaw(fullProcessedPath)) {
            if (!deleteFileAlways(fullProcessedPath)) {
              if (lastFindErrno != Errno.enoent) {
                _sendMessageErrorWithLastError(
                    'Cannot delete output file', fullProcessedPath);
                return (fullProcessedPath, true);
              }
            }
          }
        }
      }
    }
    return (fullProcessedPath, false);
  }

  // MakePath_from_2_Parts
  static String _makePathFrom2Parts(String prefix, String path) =>
      prefix + path;

  // GetExtractStream: returns (stream, needExit).
  (OutStream?, bool) _getExtractStream() {
    _readFiProps();
    final isAnti = _arc!.isItemAnti(_index);

    _correctPathParts();
    final processedPath = makePathFromParts(_item.pathParts);

    if (!isAnti) _createFolders();

    var fullProcessedPath = processedPath;
    if (_pathMode != PathMode.absPaths || !isAbsolutePath(processedPath)) {
      fullProcessedPath = _makePathFrom2Parts(_dirPathPrefix, fullProcessedPath);
    }

    if (_item.isDir) {
      _diskFilePath = fullProcessedPath;
      if (isAnti) removeDir(_diskFilePath);
      if (_link.linkPath.isEmpty) {
        if (!isAnti) _setAttrib();
        return (null, true);
      }
    } else if (!_isSplit) {
      final (p, needExit) = _checkExistFile(fullProcessedPath);
      fullProcessedPath = p;
      if (needExit) return (null, true);
    }

    _diskFilePath = fullProcessedPath;

    if (isAnti) return (null, false);

    if (_link.linkPath.isNotEmpty) {
      _setLink(fullProcessedPath, _link);
      return (null, false);
    }

    // ---------- CREATE WRITE FILE -----
    FileOutStream fos;
    try {
      final f = File(resolvePath(fullProcessedPath));
      fos = FileOutStream(
          f.openSync(mode: _isSplit ? FileMode.append : FileMode.write));
    } on FileSystemException catch (e) {
      lastFindErrno = errnoOf(e);
      _sendMessageErrorWithLastError('Cannot open output file', fullProcessedPath);
      return (null, true);
    }
    final outFile = _OutFile(fos, fullProcessedPath);
    _needSetAttrib = true;

    var isSymLinkInData = false;
    if (_curSizeDefined && _curSize != 0 && _curSize < (1 << 12)) {
      if (_fi.isLinuxSymLink()) {
        isSymLinkInData = true;
        _isSymLinkInDataLinux = true;
      } else if (_fi.isReparse()) {
        isSymLinkInData = true;
        _isSymLinkInDataLinux = false;
      }
    }

    OutStream outStreamLoc;
    if (isSymLinkInData) {
      _bufPtrSeqOutStream = _MemOut(_curSize);
      outStreamLoc = _bufPtrSeqOutStream!;
    } else {
      if (_isSplit) fos.position = _position;
      outStreamLoc = outFile;
    }
    _outFileStream = outFile;
    return (outStreamLoc, false);
  }

  // GetItem
  void _getItem(int index) {
    _item.writeToAltStreamIfColon = _ntOptions.writeToAltStreamIfColon;
    _arc!.getItem(index, _item);
  }

  @override
  OutStream? getStream(int index, int askExtractMode) {
    _hashStream?.stream = null;
    _hashStreamWasUsed = false;
    _outFileStream = null;
    _bufPtrSeqOutStream = null;

    _encrypted = false;
    _isSplit = false;
    _curSizeDefined = false;
    _extractMode = false;
    _isSymLinkInDataLinux = false;
    _needSetAttrib = false;
    _isSymLinkCreated = false;
    _itemFailure = false;
    _somePathPartsWereRemoved = false;
    _position = 0;
    _curSize = 0;
    _index = index;
    _diskFilePath = '';
    _link = _LinkInfo();

    if (askExtractMode == AskMode.extract && !_testMode) _extractMode = true;

    final archive = _arc!.archive!;
    _getItem(index);
    {
      final p = archive.getProperty(index, Kpid.position);
      if (p != null) {
        if (p is! int) throw const SystemException(HRes.eFail);
        _position = p;
        _isSplit = true;
      }
    }
    _readLink();
    _encrypted = archiveGetItemBoolProp(archive, index, Kpid.encrypted);
    _getUnpackSize();

    if (!_ntOptions.altStreams.val && _item.isAltStream) return null;

    final pathParts = _item.pathParts;
    final wc = _wildcardCensor;
    if (wc != null) {
      if (!censorNodeCheckPath(wc, _item)) return null;
    }

    final zb = zoneBuf;
    if (kIsWin &&
        askExtractMode == AskMode.extract &&
        !_testMode &&
        _item.isAltStream &&
        zb != null &&
        _isZoneIdStreamName(_item.altStreamName)) {
      if (zoneMode != 2 ||
          _item.pathParts.isEmpty ||
          _findExt2(_kOfficeExtensions, _item.pathParts.last)) {
        return null;
      }
    }

    if (pathParts.isEmpty) {
      if (_item.isDir) return null;
    }
    var numRemovePathParts = 0;
    switch (_pathMode) {
      case PathMode.fullPaths:
      case PathMode.curPaths:
        if (_removePathParts.isEmpty) break;
        var badPrefix = false;
        if (pathParts.length < _removePathParts.length) {
          badPrefix = true;
        } else {
          if (pathParts.length == _removePathParts.length) {
            if (_removePartsForAltStreams) {
              if (!_item.isAltStream) badPrefix = true;
            } else {
              if (!_item.mainIsDir) badPrefix = true;
            }
          }
          if (!badPrefix) {
            for (var i = 0; i < _removePathParts.length; i++) {
              if (compareFileNames(_removePathParts[i], pathParts[i]) != 0) {
                badPrefix = true;
                break;
              }
            }
          }
        }
        if (badPrefix) {
          if (askExtractMode == AskMode.extract && !_testMode) {
            throw const SystemException(HRes.eFail);
          }
        } else {
          numRemovePathParts = _removePathParts.length;
          _somePathPartsWereRemoved = true;
        }
      case PathMode.noPaths:
        if (pathParts.isNotEmpty) numRemovePathParts = pathParts.length - 1;
      case PathMode.noPathsAlt:
        if (_item.isAltStream) {
          numRemovePathParts = pathParts.length;
        } else if (pathParts.isNotEmpty) {
          numRemovePathParts = pathParts.length - 1;
        }
      case PathMode.absPaths:
        break;
    }
    pathParts.removeRange(0, numRemovePathParts);

    OutStream? outStreamLoc;
    if (askExtractMode == AskMode.extract && !_testMode) {
      if (_stdOutMode) {
        outStreamLoc = stdOutStream ??= StdOutFileStream();
      } else {
        final (s, needExit) = _getExtractStream();
        if (needExit) return null;
        outStreamLoc = s;
      }
    }

    final hs = _hashStream;
    if (hs != null) {
      if (askExtractMode == AskMode.extract || askExtractMode == AskMode.test) {
        hs.stream = outStreamLoc;
        outStreamLoc = hs;
        hs.init();
        _hashStreamWasUsed = true;
      }
    }
    return outStreamLoc;
  }

  // ReadLink: the 7z handler has no link properties (kpidSymLink,
  // kpidHardLink); links of POSIX archives are in the data (see
  // IsLinuxSymLink).
  void _readLink() {
    final archive = _arc!.archive!;
    final hl = archive.getProperty(_index, Kpid.hardLink);
    if (hl is String) {
      _link.isHardLink = true;
      _link.isRelative = false;
      _link.linkPath = hl;
    }
    final sl = archive.getProperty(_index, Kpid.symLink);
    if (sl is String) {
      _link.isHardLink = false;
      _link.isRelative = true;
      _link.linkPath = sl;
    }
    if (_link.linkPath.isEmpty) return;
    _link.normalizeToRelativeSafe(_removePathParts);
  }

  @override
  void prepareOperation(int askMode) {
    _extractMode = false;
    var mode = askMode;
    if (askMode == AskMode.extract) {
      if (_testMode) {
        mode = AskMode.test;
      } else {
        _extractMode = true;
      }
    }
    _extractCallback2.prepareOperation(
        _item.path, _item.isDir, mode, _isSplit ? _position : null);
  }

  // CloseFile
  void _closeFile() {
    final out = _outFileStream;
    if (out == null) return;
    _curSize = out.processedSize;
    _curSizeDefined = true;
    try {
      out.s.close();
    } on FileSystemException catch (e) {
      throw SystemException(hresultOfFileSystemException(e));
    }
    final zb = zoneBuf;
    if (kIsWin && zb != null && !_item.isAltStream) {
      if (zoneMode != 2 || _findExt2(_kOfficeExtensions, _diskFilePath)) {
        // we must write zone file before setting of timestamps
        _writeZoneFileToBaseFile(resolvePath(_diskFilePath), zb);
      }
    }
    final t = _getFiTimesCAM(_fi, _arc!);
    if (t.isSomeTimeDefined()) setFileTimes(out.path, t.mTime, t.aTime);
    _outFileStream = null;
  }

  // CloseReparseAndFile
  void _closeReparseAndFile() {
    var reparseSize = 0;
    var repraseMode = false;
    var needSetReparse = false;
    final link = _LinkInfo();
    final mem = _bufPtrSeqOutStream;
    if (mem != null) {
      repraseMode = true;
      reparseSize = mem.pos;
      if (_curSizeDefined && reparseSize == mem.buf.length) {
        needSetReparse = _isSymLinkInDataLinux
            ? link.parseFromLinuxData(mem.buf)
            : (kIsWin && link.parseFromWindowsReparseData(mem.buf));
        if (!needSetReparse) {
          _sendMessageErrorWithError(
              HRes.eFail, 'Incorrect reparse stream', _item.path);
        }
      } else {
        _sendMessageErrorWithError(
            HRes.eFail, 'Unknown reparse stream', _item.path);
      }
      final out = _outFileStream;
      if (!needSetReparse && out != null) {
        out.write(mem.buf, 0, reparseSize);
      }
      _bufPtrSeqOutStream = null;
    }
    _closeFile();
    if (repraseMode) {
      _curSize = reparseSize;
      _curSizeDefined = true;
      if (needSetReparse) {
        if (!deleteFileAlways(_diskFilePath)) {
          _sendMessageErrorWithLastError("can't delete file", _diskFilePath);
        }
        link.normalizeToRelativeSafe(_removePathParts);
        _setLink(_diskFilePath, link);
        _needSetAttrib = false;
      }
    }
  }

  // SetLink: the link is created after all items (SetPostLinks); an empty
  // placeholder file is created now.
  void _setLink(String fullProcessedPathFrom, _LinkInfo link) {
    if (link.linkPath.isEmpty) return;
    if (!_ntOptions.symLinks.val && !link.isHardLink) return;
    final postLink = _PostLink()
      ..indexInArc = _index
      ..itemIsDir = _item.isDir
      ..itemPath = _item.path
      ..itemPathParts = List.of(_item.pathParts)
      ..itemFileInfo = _fi.copy()
      ..fullProcessedPathFrom = fullProcessedPathFrom;
    postLink.linkInfo
      ..linkPath = link.linkPath
      ..isRelative = link.isRelative
      ..isHardLink = link.isHardLink;
    _postLinks.add(postLink);
    _deleteLinkFileAlwaysOrRemoveEmptyDir(fullProcessedPathFrom, false);
    try {
      File(resolvePath(fullProcessedPathFrom))
          .createSync(exclusive: true);
    } on FileSystemException {
      _sendMessageError(
          'Cannot create temporary link file', fullProcessedPathFrom);
    }
  }

  // DeleteLinkFileAlways_or_RemoveEmptyDir
  void _deleteLinkFileAlwaysOrRemoveEmptyDir(
      String path, bool checkThatFileIsEmpty) {
    final fi = findFile(path);
    if (fi == null) return;
    if (fi.isDir) {
      if (removeDirAlwaysIfEmpty(path)) return;
    } else {
      if (checkThatFileIsEmpty && !fi.isOsSymLink && fi.size != 0) {
        _sendMessageError('Temporary link file is not empty', path);
        return;
      }
      if (deleteFileAlways(path)) return;
    }
    if (lastFindErrno != Errno.enoent) {
      _sendMessageErrorWithLastError(
          fi.isDir
              ? 'Cannot delete directory for symbolic link creation'
              : 'Cannot delete file for symbolic link creation',
          path);
    }
  }

  // CheckLinkPath_in_FS_for_pathParts
  static bool _checkLinkPathInFsForPathParts(String path, List<String> v) {
    var path2 = path;
    for (final s in v) {
      path2 += s;
      final fi = findFile(path2);
      if (fi != null && fi.isOsSymLink) return false;
      path2 += kDirSep;
    }
    return true;
  }

  // CheckLinkPath_in_FS
  bool _checkLinkPathInFs(
      String pathPrefixInFs, _PostLink postLink, String relativeItemPathPrefix) {
    final link = postLink.linkInfo;
    if (postLink.itemPathParts.isEmpty || link.linkPath.isEmpty) return false;
    var path = '';
    {
      final s = postLink.itemPathParts[0];
      if (s.isNotEmpty && !isAbsolutePath(s)) path = pathPrefixInFs;
    }
    if (!_checkLinkPathInFsForPathParts(path, postLink.itemPathParts)) {
      return false;
    }
    path += relativeItemPathPrefix;
    return _checkLinkPathInFsForPathParts(path, splitPathToParts(link.linkPath));
  }

  // SetLink2
  bool _setLink2(_PostLink postLink) {
    final link = postLink.linkInfo;
    final from = postLink.fullProcessedPathFrom;
    final level = _ntOptions.symLinksDangerousLevel;
    if (level < 20) {
      final li = _LinkLevelsInfo()..parse(link.linkPath);
      bool isDang;
      var relativePathPrefix = '';
      if (li.isAbsolute ||
          li.parentDirDotsAfterNonParent ||
          (level <= 5 && link.isRelative && li.finalLevel < 1) ||
          (level <= 5 && link.isRelative && li.lowLevel < 0)) {
        isDang = true;
      } else {
        var path = '';
        if (link.isRelative) {
          final v = List.of(postLink.itemPathParts);
          while (v.isNotEmpty) {
            final len = v.last.length;
            v.removeLast();
            if (len != 0) break;
          }
          path = makePathFromParts(v);
          path = normalizeDirPathPrefix(path);
          relativePathPrefix = path;
        }
        path += link.linkPath;
        isDang = !isSafePath(path);
      }
      String? message;
      if (isDang) {
        message = 'Dangerous link path was ignored';
      } else if (level <= 9 &&
          !_checkLinkPathInFs(_dirPathPrefixFull, postLink, relativePathPrefix)) {
        message = 'Dangerous link via another link was ignored';
      }
      if (message != null) {
        _sendMessageError2(0, message, postLink.itemPath, link.linkPath);
        return false;
      }
    }

    String target;
    if (link.isHardLink || !link.isRelative) {
      target = myGetFullPathName(_dirPathPrefixFull + link.linkPath);
    } else {
      target = link.linkPath;
    }
    if (target.isEmpty) {
      _sendMessageError('Empty link', from);
      return false;
    }
    _deleteLinkFileAlwaysOrRemoveEmptyDir(from, true);
    if (link.isHardLink) {
      // MyCreateHardLink: a copy when the file system can not link
      if (!createHardLinkOrCopy(target, from)) {
        _sendMessageError2(0, 'Cannot create hard link', from, target);
        return false;
      }
      return true;
    }
    try {
      Link(resolvePath(from)).createSync(target);
    } on FileSystemException catch (e) {
      lastFindErrno = errnoOf(e);
      _sendMessageErrorWithLastError('Cannot create symbolic link', from);
      return false;
    }
    return true;
  }

  // SetAttrib_Base
  void _setAttribBase(String path, _ProcessedFileInfo fi) {
    if (fi.attribDefined) {
      if (!setFileAttribPosixHighDetect(path, fi.attrib)) {
        _sendMessageErrorWithLastError('Cannot set file attribute', path);
      }
    }
  }

  // SetAttrib_Base: the error of a queued attribute change.
  void _attribError(String path, int errorCode) => _sendMessageErrorWithError(
      hresultFromErrno(errorCode), 'Cannot set file attribute', path);

  // SetAttrib
  void _setAttrib() {
    if (!kIsWin && _isSymLinkCreated) return;
    if (_itemFailure || _diskFilePath.isEmpty || _stdOutMode || !_extractMode) {
      return;
    }
    _setAttribBase(_diskFilePath, _fi);
  }

  @override
  void setOperationResult(int opRes) {
    final hs = _hashStream;
    if (_hashStreamWasUsed && hs != null) {
      _hash!.finalItem(_item.isDir, _item.isAltStream, _item.path);
      _curSize = hs.size;
      _curSizeDefined = true;
      hs.stream = null;
      _hashStreamWasUsed = false;
    }
    _closeReparseAndFile();
    if (!_curSizeDefined) _getUnpackSize();
    if (_curSizeDefined) {
      if (_item.isAltStream) {
        altStreamsUnpackSize += _curSize;
      } else {
        unpackSize += _curSize;
      }
    }
    if (_item.isDir) {
      numFolders++;
    } else if (_item.isAltStream) {
      numAltStreams++;
    } else {
      numFiles++;
    }
    if (_needSetAttrib) _setAttrib();
    _extractCallback2.setOperationResult(opRes, _encrypted);
  }

  @override
  void reportExtractResult(int indexType, int index, int opRes) {
    var isEncrypted = false;
    String s;
    if (indexType == EventIndexType.inArcIndex && index != -1) {
      final item = ReadArcItem();
      _arc!.getItem(index, item);
      s = item.path;
      isEncrypted =
          archiveGetItemBoolProp(_arc!.archive!, index, Kpid.encrypted);
    } else {
      s = '#$index';
    }
    _extractCallback2.reportExtractResult(opRes, isEncrypted, s);
  }

  @override
  String cryptoGetTextPassword() => _extractCallback2.cryptoGetTextPassword();

  // SetPostLinks
  void _setPostLinks() {
    for (final link in _postLinks) {
      final linkWasSet = _setLink2(link);
      if (linkWasSet) {
        final pt = _getFiTimesCAM(link.itemFileInfo, _arc!);
        if (pt.isSomeTimeDefined() && pt.mTime != null) {
          setDirOrLinkMTime(link.fullProcessedPathFrom, pt.mTime!, pt.mNs100,
              link: true);
        }
      }
    }
  }

  // SetDirsTimes: children first (more slashes first).
  void _setDirsTimes() {
    if (_arc == null) return;
    final pairs = List<int>.generate(_extractedFolders.length, (i) => i);
    int numSlashes(String s) {
      var n = 0;
      for (var i = 0; i < s.length; i++) {
        if (isPathSepar(s.codeUnitAt(i))) n++;
      }
      return n;
    }
    pairs.sort((a, b) {
      final la = numSlashes(_extractedFolders[a].path);
      final lb = numSlashes(_extractedFolders[b].path);
      if (la < lb) return 1;
      if (la > lb) return -1;
      return a.compareTo(b);
    });
    // chmod before the times (the times of directories do not change with
    // chmod, but they do when files are added)
    flushFileAttribs(_attribError);
    for (final i in pairs) {
      final dpt = _extractedFolders[i];
      final mt = dpt.t.mTime;
      if (mt != null) setDirOrLinkMTime(dpt.path, mt, dpt.t.mNs100);
    }
    _extractedFolders.clear();
  }

  /// CloseArc (CArchiveExtractCallback_Closer).
  void closeArc() {
    try {
      _closeReparseAndFile();
    } finally {
      stdOutStream?.flush();
      _setPostLinks();
      _setDirsTimes();
      flushFileAttribs(_attribError);
      _arc = null;
    }
  }
}
