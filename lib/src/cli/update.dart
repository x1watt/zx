// The update group commands (a, u, d, rn): UI/Common/Update.cpp of the
// LZMA SDK (CArchivePath, CUpdateOptions, CRenamePair, Compress,
// EnumerateInArchiveItems, UpdateArchive) with UI/Common/TempFiles.cpp.

import 'dart:io';
import 'dart:typed_data';

import '../common/method_props.dart' show InvalidArgException;
import '../format/archive_types.dart';
import '../format/split.dart';
import '../io/streams.dart';
import 'arc_compound.dart';
import 'arc_handlers.dart';
import 'arc_tar.dart';
import 'archive_extract_callback.dart' show censorNodeCheckPath2, StdOutFileStream;
import 'common.dart';
import 'enum_dir_items.dart';
import 'fs_utils.dart';
import 'globals.dart';
import 'load_codecs.dart';
import 'open_archive.dart';
import 'update_callback.dart';
import 'update_pair.dart';
import 'wildcard.dart';
import 'platform.dart';

/// EArcNameMode.
enum ArcNameMode { smart, exact, add }

/// NRecursedType.
enum RecursedType { recursed, wildcardOnlyRecursed, nonRecursed }

/// CArchivePath.
class ArchivePath {
  String originalPath = '';
  String prefix = '';
  String name = '';
  String baseExtension = '';
  String volExtension = '';
  bool temp = false;
  String tempPrefix = '';
  String tempPostfix = '';

  ArchivePath copy() => ArchivePath()
    ..originalPath = originalPath
    ..prefix = prefix
    ..name = name
    ..baseExtension = baseExtension
    ..volExtension = volExtension
    ..temp = temp
    ..tempPrefix = tempPrefix
    ..tempPostfix = tempPostfix;

  // ParseFromPath
  void parseFromPath(String path, ArcNameMode mode) {
    originalPath = path;
    final (p, n) = splitPathToParts2(path);
    prefix = p;
    name = n;
    if (mode == ArcNameMode.add) return;
    if (mode != ArcNameMode.exact) {
      final dotPos = name.lastIndexOf('.');
      if (dotPos < 0) return;
      if (dotPos == name.length - 1) {
        name = name.substring(0, name.length - 1);
      } else {
        final ext = name.substring(dotPos + 1);
        if (baseExtension.toLowerCase() == ext.toLowerCase()) {
          baseExtension = ext;
          name = name.substring(0, dotPos);
          return;
        }
      }
    }
    baseExtension = '';
  }

  String getPathWithoutExt() => prefix + name;

  // GetFinalPath
  String getFinalPath() {
    var path = getPathWithoutExt();
    if (baseExtension.isNotEmpty) path += '.$baseExtension';
    return path;
  }

  // GetFinalVolPath
  String getFinalVolPath() {
    var path = getPathWithoutExt();
    if (baseExtension.isNotEmpty) path += '.$volExtension';
    return path;
  }

  // GetTempPath
  String getTempPath() {
    var path = tempPrefix + name;
    if (baseExtension.isNotEmpty) path += '.$baseExtension';
    path += '.tmp';
    path += tempPostfix;
    return path;
  }
}

/// CUpdateArchiveCommand.
class UpdateArchiveCommand {
  String userArchivePath = '';
  ArchivePath archivePath = ArchivePath();
  ActionSet actionSet = kActionSetAdd();
}

/// CCompressionMethodMode.
class CompressionMethodMode {
  bool typeDefined = false;
  OpenType type = OpenType();
  List<MapEntry<String, String>> properties = [];
}

// CompareTwoNames
int _compareTwoNames(String s1, String s2) {
  for (var i = 0;; i++) {
    final c1 = i < s1.length ? s1.codeUnitAt(i) : 0;
    final c2 = i < s2.length ? s2.codeUnitAt(i) : 0;
    if (c1 == 0 || c2 == 0) return i;
    if (c1 == c2) continue;
    if (!gCaseSensitive && myCharUpper(c1) == myCharUpper(c2)) continue;
    if (isPathSepar(c1) && isPathSepar(c2)) continue;
    return i;
  }
}

/// CRenamePair.
class RenamePair {
  String oldName = '';
  String newName = '';
  bool wildcardParsing = true;
  RecursedType recursedType = RecursedType.nonRecursed;

  // Prepare
  bool prepare() {
    if (recursedType != RecursedType.nonRecursed) return false;
    if (!wildcardParsing) return true;
    return !doesNameContainWildcard(oldName);
  }

  // GetNewPath: null when it does not apply.
  String? getNewPath(bool isFolder, String src) {
    final num = _compareTwoNames(oldName, src);
    int at(String s, int i) => i < s.length ? s.codeUnitAt(i) : 0;
    if (at(oldName, num) == 0) {
      if (at(src, num) != 0 &&
          !isPathSepar(at(src, num)) &&
          num != 0 &&
          !isPathSepar(at(src, num - 1))) {
        return null;
      }
    } else {
      if (!isFolder ||
          at(src, num) != 0 ||
          !isPathSepar(at(oldName, num)) ||
          at(oldName, num + 1) != 0) {
        return null;
      }
    }
    return newName + src.substring(num);
  }
}

/// CUpdateOptions.
class UpdateOptions {
  bool updateArchiveItself = true;
  bool sfxMode = false;
  bool preserveATime = false;
  bool openShareForWrite = false;
  bool stopAfterOpenError = false;
  bool stdInMode = false;
  bool stdOutMode = false;
  bool eMailMode = false;
  bool eMailRemoveAfter = false;
  bool deleteAfterCompressing = false;
  bool setArcMTime = false;
  bool renameMode = false;

  BoolPair2 ntSecurity = BoolPair2();
  BoolPair2 altStreams = BoolPair2();
  BoolPair2 hardLinks = BoolPair2();
  BoolPair2 symLinks = BoolPair2();
  BoolPair2 storeOwnerId = BoolPair2();
  BoolPair2 storeOwnerName = BoolPair2();

  ArcNameMode arcNameMode = ArcNameMode.smart;
  CensorPathMode pathMode = CensorPathMode.relatPath;
  CompressionMethodMode methodMode = CompressionMethodMode();
  List<UpdateArchiveCommand> commands = [];
  ArchivePath archivePath = ArchivePath();
  String sfxModule = '';
  String stdInFileName = '';
  String eMailAddress = '';
  String workingDir = '';
  List<RenamePair> renamePairs = [];
  List<int> volumesSizes = [];

  /// A new compound archive (a tar inside this compressor, by the archive
  /// name or -ttar.gzip): the format index of the compressor, else -1.
  int compoundOuterIndex = -1;

  // InitFormatIndex
  bool initFormatIndex(Codecs codecs, List<OpenType> types, String arcPath) {
    if (types.length > 1) return false;
    if (types.isNotEmpty) {
      methodMode.type = types[0].copy();
      methodMode.typeDefined = true;
    }
    if (methodMode.type.formatIndex < 0) {
      methodMode.type = OpenType();
      if (arcNameMode != ArcNameMode.add) {
        methodMode.type.formatIndex = codecs.findFormatForArchiveName(arcPath);
        if (methodMode.type.formatIndex >= 0) methodMode.typeDefined = true;
      }
    }
    return true;
  }

  // SetArcPath
  bool setArcPath(Codecs codecs, String arcPath) {
    String typeExt;
    final formatIndex = methodMode.type.formatIndex;
    if (formatIndex < 0) {
      typeExt = '7z';
    } else {
      final arcInfo = codecs.formats[formatIndex];
      if (!arcInfo.updateEnabled) return false;
      typeExt = arcInfo.getMainExt();
    }
    var ext = typeExt;
    if (sfxMode) ext = kIsWin ? 'exe' : ''; // kSFXExtension
    archivePath.baseExtension = ext;
    archivePath.volExtension = typeExt;
    archivePath.parseFromPath(arcPath, arcNameMode);
    for (final uc in commands) {
      uc.archivePath.baseExtension = ext;
      uc.archivePath.volExtension = typeExt;
      uc.archivePath.parseFromPath(uc.userArchivePath, arcNameMode);
    }
    return true;
  }
}

/// CUpdateErrorInfo.
class UpdateErrorInfo {
  int systemError = 0;
  String message = '';
  final List<String> fileNames = [];

  bool thereIsError() =>
      systemError != 0 || message.isNotEmpty || fileNames.isNotEmpty;

  int getHresultError() =>
      systemError == 0 ? HRes.eFail : hresultFromErrno(systemError);

  // SetFromLastError
  int setFromLastError(String message, String fileName, [int? errno]) {
    systemError = errno ?? (lastFindErrno == 0 ? Errno.eio : lastFindErrno);
    this.message = message;
    fileNames.add(fileName);
    return getHresultError();
  }

  // SetFromError_DWORD
  int setFromErrorDword(String message, String fileName, int error) {
    this.message = message;
    fileNames.add(fileName);
    systemError = error;
    return getHresultError();
  }
}

/// CFinishArchiveStat.
class FinishArchiveStat {
  int outArcFileSize = 0;
  int numVolumes = 0;
  bool isMultiVolMode = false;
}

/// IUpdateCallbackUI2.
abstract class UpdateCallbackUI2 extends UpdateCallbackUI
    implements DirItemsCallback {
  void openResult(Codecs codecs, ArchiveLink arcLink, String name, int result);
  void startScanning();
  void finishScanning(DirItemsStat st);
  void startOpenArchive(String? name);
  void startArchive(String? name, bool updating);
  void finishArchive(FinishArchiveStat st);
  void deletingAfterArchiving(String path, bool isDir);
  void finishDeletingAfterArchiving();
  void moveArcStart(String srcTempPath, String destFinalPath, int size,
      bool updateMode);
  void moveArcProgress(int total, int current);
  void moveArcFinish();
}

/// CTempFiles.
class _TempFiles {
  final List<String> paths = [];
  bool needDeleteFiles = true;
  void clear() {
    if (!needDeleteFiles) return;
    for (final p in paths.reversed) {
      deleteFileAlways(p);
    }
    paths.clear();
  }
}

class _UpdateProduceCallbackImp implements UpdateProduceCallback {
  final List<ArcItem> _arcItems;
  final DirItemsStat _stat;
  final UpdateCallbackUI _callback;
  _UpdateProduceCallbackImp(this._arcItems, this._stat, this._callback);

  @override
  void showDeleteFile(int arcIndex) {
    final ai = _arcItems[arcIndex];
    if (ai.isDir) {
      _stat.numDirs++;
    } else if (ai.isAltStream) {
      _stat.numAltStreams++;
      _stat.altStreamsSize += ai.size;
    } else {
      _stat.numFiles++;
      _stat.filesSize += ai.size;
    }
    _callback.showDeleteFile(ai.name, ai.isDir);
  }
}

/// An output file opened with Create_NEW (COutFileStream).
class _OutArcFile {
  final FileOutStream s;
  final String path;
  _OutArcFile(this.s, this.path);
}

// Compress
void _compress(
    UpdateOptions options,
    bool isUpdatingItself,
    Codecs codecs,
    ActionSet actionSet,
    Arc? arc,
    ArchivePath archivePath,
    List<ArcItem> arcItems,
    Uint8List? processedItemsStatuses,
    DirItems dirItems,
    DirItem? parentDirItem,
    _TempFiles tempFiles,
    List<MultiOutStream> multiStreams,
    UpdateErrorInfo errorInfo,
    UpdateCallbackUI2 callback,
    FinishArchiveStat st) {
  InArchive outArchive;
  var formatIndex = options.methodMode.type.formatIndex;
  final compoundOuter =
      arc != null ? arc.compoundOuterIndex : options.compoundOuterIndex;
  if (arc == null && compoundOuter >= 0) {
    formatIndex = codecs.findFormatForArchiveType('tar');
  }
  if (arc != null) {
    formatIndex = arc.formatIndex;
    if (formatIndex < 0) throw const SystemException(HRes.eNotImpl);
    final a = arc.archive!;
    if (!a.supportsUpdate) {
      throw const StringException(
          'update operations are not supported for this archive');
    }
    outArchive = a;
  } else {
    final ai = codecs.formats[formatIndex];
    final create = ai.createInArchive;
    if (create == null) throw const SystemException(HRes.eNotImpl);
    outArchive = create();
    if (!outArchive.supportsUpdate) {
      throw const StringException(
          'update operations are not supported for this archive');
    }
  }

  if (compoundOuter >= 0) {
    // the tar written into the compressor (arc_compound.dart)
    final create = codecs.formats[compoundOuter].createInArchive;
    if (create == null || outArchive is! TarArc) {
      throw const SystemException(HRes.eNotImpl);
    }
    outArchive = CompoundOutArc(create(), outArchive,
        compoundInnerName(extractFileNameFromPath(archivePath.getFinalPath())));
  }

  // SetProperties
  try {
    setArchiveProperties(outArchive, options.methodMode.properties);
  } on SevenZipException {
    throw const SystemException(HRes.eInvalidArg);
  }

  var fileTimeType = outArchive.getFileTimeType();
  {
    final arcInfo = codecs.formats[formatIndex];
    if (arcInfo.isXz) fileTimeType = FileTimeType.notDefined;
    if (options.altStreams.val && !arcInfo.flagsAltStreams) {
      throw const SystemException(HRes.eNotImpl);
    }
    if (options.ntSecurity.val && !arcInfo.flagsNtSecurity) {
      throw const SystemException(HRes.eNotImpl);
    }
    if (options.deleteAfterCompressing && arcInfo.flagsHashHandler) {
      throw const SystemException(HRes.eNotImpl);
    }
  }

  var updatePairs2 = <UpdatePair2>[];
  final newNames = <String>[];
  final stat2 = ArcToDoStat();

  if (options.renameMode || options.renamePairs.isNotEmpty) {
    for (var i = 0; i < arcItems.length; i++) {
      final ai = arcItems[i];
      var needRename = false;
      String? dest;
      if (ai.censored) {
        for (final rp in options.renamePairs) {
          dest = rp.getNewPath(ai.isDir, ai.name);
          if (dest != null) {
            needRename = true;
            break;
          }
        }
      }
      final up2 = UpdatePair2()..setAsNoChangeArcItem(ai.indexInServer);
      if (needRename) {
        up2.newProps = true;
        up2.isAnti = arc!.isItemAnti(i);
        up2.newNameIndex = newNames.length;
        newNames.add(dest!);
      }
      updatePairs2.add(up2);
    }
  } else {
    final updatePairs =
        getUpdatePairInfoList(dirItems, arcItems, fileTimeType);
    final upCallback =
        _UpdateProduceCallbackImp(arcItems, stat2.deleteData, callback);
    updatePairs2 = updateProduce(
        updatePairs, actionSet, isUpdatingItself ? upCallback : null);
  }

  for (final up in updatePairs2) {
    if (up.newData && !up.useArcProps) {
      if (up.existOnDisk()) {
        final stat = stat2.newData;
        final di = dirItems.items[up.dirIndex];
        if (di.isDir()) {
          if (up.isAnti) {
            stat.antiNumDirs++;
          } else {
            stat.numDirs++;
          }
        } else {
          if (up.isAnti) {
            stat.antiNumFiles++;
          } else {
            stat.numFiles++;
            stat.filesSize += di.size;
          }
        }
      }
    } else if (up.arcIndex >= 0) {
      final stat = up.newData ? stat2.newData : stat2.oldData;
      final ai = arcItems[up.arcIndex];
      if (ai.isDir) {
        if (up.isAnti) {
          stat.antiNumDirs++;
        } else {
          stat.numDirs++;
        }
      } else if (ai.isAltStream) {
        if (up.isAnti) {
          stat.antiNumAltStreams++;
        } else {
          stat.numAltStreams++;
          stat.altStreamsSize += ai.size;
        }
      } else {
        if (up.isAnti) {
          stat.antiNumFiles++;
        } else {
          stat.numFiles++;
          stat.filesSize += ai.size;
        }
      }
    }
  }
  callback.setNumItems(stat2);

  final updateCallbackSpec = ArchiveUpdateCallbackImpl()
    ..preserveATime = options.preserveATime
    ..shareForWrite = options.openShareForWrite
    ..stopAfterOpenError = options.stopAfterOpenError
    ..stdInMode = options.stdInMode
    ..callback = callback
    ..dirItems = dirItems
    ..parentDirItem = parentDirItem
    ..storeSymLinks = options.symLinks.val
    ..arc = arc
    ..arcItems = arcItems
    ..updatePairs = updatePairs2
    ..processedItemsStatuses = processedItemsStatuses
    ..arcFileName = extractFileNameFromPath(archivePath.getFinalPath())
    ..stdinData = options.stdInMode ? gStdIn.dataStream : null;
  if (arc != null) updateCallbackSpec.archive = arc.archive;
  if (options.renamePairs.isNotEmpty) updateCallbackSpec.newNames = newNames;
  if (options.setArcMTime) updateCallbackSpec.needLatestMTime = true;

  if (!options.stdOutMode) {
    final (dirPrefix, _) = splitPathToParts2(archivePath.getFinalPath());
    if (dirPrefix.isNotEmpty) createComplexDir(dirPrefix);
  }

  _OutArcFile? outStreamSpec;
  StdOutFileStream? stdOutFileStreamSpec;
  MultiOutStream? volStreamSpec;
  OutStream outStream;

  if (options.volumesSizes.isEmpty) {
    if (options.stdOutMode) {
      stdOutFileStreamSpec = StdOutFileStream();
      outStream = stdOutFileStreamSpec;
    } else {
      var isOK = false;
      var realPath = '';
      var lastErrno = 0;
      for (var i = 0; i < (1 << 16); i++) {
        if (archivePath.temp) {
          if (i > 0) archivePath.tempPostfix = '$i';
          realPath = archivePath.getTempPath();
        } else {
          realPath = archivePath.getFinalPath();
        }
        try {
          final f = File(resolvePath(realPath));
          f.createSync(exclusive: true);
          tempFiles.paths.add(realPath);
          outStreamSpec = _OutArcFile(
              FileOutStream(f.openSync(mode: FileMode.write)), realPath);
          isOK = true;
          break;
        } on FileSystemException catch (e) {
          lastErrno = errnoOf(e);
          if (lastErrno != Errno.eexist) break;
          if (!archivePath.temp) break;
        }
      }
      if (!isOK) {
        throw SystemException(
            errorInfo.setFromLastError('cannot open file', realPath, lastErrno));
      }
      outStream = outStreamSpec!.s;
    }
  } else {
    if (options.stdOutMode) throw const SystemException(HRes.eFail);
    if (arc != null && arc.getGlobalOffset() > 0) {
      throw const SystemException(HRes.eNotImpl);
    }
    final ms = MultiOutStream(
        '${resolvePath(archivePath.getFinalVolPath())}.', options.volumesSizes);
    volStreamSpec = ms;
    multiStreams.add(ms);
    outStream = ms;
  }

  if (options.sfxMode) {
    throw const StringException('SFX modules are not supported by this port');
  }

  OutStream tailStream;
  if (arc == null || arc.arcStreamOffset == 0) {
    tailStream = outStream;
  } else {
    // copy the stub before the archive
    final src = arc.inStream!;
    src.position = 0;
    copyStream(src, outStream, limit: arc.arcStreamOffset);
    tailStream = outStream is SeekableOutStream
        ? _TailOutStream(outStream, arc.arcStreamOffset)
        : outStream;
  }

  FiTime? ft;
  for (final pair2 in updatePairs2) {
    FiTime? ft2;
    if (pair2.dirIndex >= 0 && (pair2.newProps || pair2.isSameTime)) {
      ft2 = dirItems.items[pair2.dirIndex].mTime;
    } else if (pair2.useArcProps && pair2.arcIndex >= 0) {
      final arcItem = arcItems[pair2.arcIndex];
      if (arcItem.mTime.def) ft2 = FiTime(arcItem.mTime.ft);
    }
    if (ft2 != null) {
      if (ft == null || ft.compare(ft2) < 0) ft = ft2;
    }
  }

  if (volStreamSpec != null && options.setArcMTime && ft != null) {
    volStreamSpec.mTime = fileTimeToDateTime(ft.ft);
  }

  try {
    outArchive.updateItems(tailStream, updatePairs2.length, updateCallbackSpec);
  } on InvalidArgException {
    throw const SystemException(HRes.eInvalidArg);
  } on FileSystemException catch (e) {
    throw SystemException(hresultOfFileSystemException(e));
  }

  if (!updateCallbackSpec.areAllFilesClosed()) {
    errorInfo.message = 'There are unclosed input files:';
    errorInfo.fileNames.addAll(updateCallbackSpec.openFilesPaths);
    throw const SystemException(HRes.eFail);
  }

  if (options.setArcMTime) {
    if (updateCallbackSpec.latestMTimeDefined) {
      if (ft == null || ft.compare(updateCallbackSpec.latestMTime) < 0) {
        ft = updateCallbackSpec.latestMTime;
      }
    }
  }

  var size = 0;
  if (outStreamSpec != null) {
    size = outStreamSpec.s.length;
  } else if (stdOutFileStreamSpec != null) {
    stdOutFileStreamSpec.flush();
    size = stdOutFileStreamSpec.size;
  } else {
    size = volStreamSpec!.length;
  }
  st.outArcFileSize = size;

  if (outStreamSpec != null) {
    try {
      outStreamSpec.s.close();
    } on FileSystemException catch (e) {
      throw SystemException(hresultOfFileSystemException(e));
    }
    if (options.setArcMTime && ft != null) {
      setFileTimes(outStreamSpec.path, ft.ft, null);
    }
  } else if (volStreamSpec != null) {
    st.numVolumes = volStreamSpec.finalFlushAndCloseFiles();
    st.isMultiVolMode = true;
    if (options.setArcMTime && ft != null) {
      volStreamSpec.setMTimeFinal(fileTimeToDateTime(ft.ft));
    }
  }

  if (processedItemsStatuses != null) {
    for (final up in updatePairs2) {
      if (up.newData && up.dirIndex >= 0) {
        final di = dirItems.items[up.dirIndex];
        if (di.areReparseData() || (!di.isDir() && di.size == 0)) {
          processedItemsStatuses[up.dirIndex] = 1;
        }
      }
    }
  }
}

/// CTailOutStream: an output with positions shifted by [offset].
class _TailOutStream implements SeekableOutStream {
  final SeekableOutStream s;
  final int offset;
  _TailOutStream(this.s, this.offset);
  @override
  void write(Uint8List buf, int off, int len) => s.write(buf, off, len);
  @override
  void flush() => s.flush();
  @override
  int get position => s.position - offset;
  @override
  set position(int v) => s.position = v + offset;
  @override
  int get length => s.length - offset;
  @override
  void truncate(int length) => s.truncate(length + offset);
}

// Censor_AreAllAllowed
bool _censorAreAllAllowed(Censor censor) {
  if (censor.pairs.length != 1) return false;
  return censor.pairs[0].head.areAllAllowed();
}

// Censor_CheckPath
bool _censorCheckPath(Censor censor, ReadArcItem item) {
  var finded = false;
  for (final pair in censor.pairs) {
    final (found, include) = censorNodeCheckPath2(pair.head, item);
    if (found) {
      if (!include) return false;
      finded = true;
    }
  }
  return finded;
}

// EnumerateInArchiveItems
List<ArcItem> _enumerateInArchiveItems(Censor censor, Arc arc) {
  final arcItems = <ArcItem>[];
  final numItems = arc.archive!.numberOfItems;
  final item = ReadArcItem();
  final allFilesAreAllowed = _censorAreAllAllowed(censor);
  for (var i = 0; i < numItems; i++) {
    final ai = ArcItem();
    arc.getItem(i, item);
    ai.name = item.path;
    ai.isDir = item.isDir;
    ai.isAltStream = item.isAltStream;
    ai.censored = allFilesAreAllowed ? true : _censorCheckPath(censor, item);
    ai.mTime.copyFrom(arc.getItemMTime(i));
    final (size, defined) = arc.getItemSize(i);
    ai.size = size;
    ai.sizeDefined = defined;
    ai.indexInServer = i;
    arcItems.add(ai);
  }
  return arcItems;
}

/// UpdateArchive: throws [SystemException] (the HRESULT) or
/// [StringException]; [errorInfo] gets the details.
void updateArchive(
    Codecs codecs,
    List<OpenType> types,
    String cmdArcPath2,
    Censor censor,
    UpdateOptions options,
    UpdateErrorInfo errorInfo,
    OpenCallbackUI openCallback,
    UpdateCallbackUI2 callback,
    bool needSetPath) {
  if (options.stdOutMode && options.eMailMode) {
    throw const SystemException(HRes.eFail);
  }
  // -ttar.gzip (tar inside gzip, 7-Zip's order of the chain): a compound
  // archive (arc_compound.dart)
  var chainOuter = -1;
  if (types.length == 2) {
    final t0 = types[0].formatIndex;
    final t1 = types[1].formatIndex;
    if (t0 >= 0 &&
        t1 >= 0 &&
        codecs.formats[t0].name == 'tar' &&
        isCompoundOuterFormat(codecs.formats[t1]) &&
        codecs.formats[t1].updateEnabled) {
      chainOuter = t1;
      types = [types[1]];
    }
  }
  if (types.length > 1) throw const SystemException(HRes.eNotImpl);

  final renameMode = options.renamePairs.isNotEmpty;
  if (renameMode) {
    if (options.commands.length != 1) throw const SystemException(HRes.eFail);
  }

  if (options.deleteAfterCompressing) {
    if (options.commands.length != 1) {
      throw const SystemException(HRes.eNotImpl);
    }
    final as = options.commands[0].actionSet;
    for (var i = 2; i < PairState.numValues; i++) {
      if (as.stateActions[i] != PairAction.compress) {
        throw const SystemException(HRes.eNotImpl);
      }
    }
  }

  censor.addPathsToCensor(options.pathMode);
  censor.extendExclude();

  if (options.volumesSizes.isNotEmpty && options.eMailMode) {
    throw const SystemException(HRes.eNotImpl);
  }

  if (options.sfxMode) {
    options.methodMode.properties.add(const MapEntry('rsfx', ''));
    if (options.sfxModule.isEmpty) {
      errorInfo.message = 'SFX file is not specified';
      throw const SystemException(HRes.eFail);
    }
    if (!doesFileExistFollowLink(options.sfxModule)) {
      throw SystemException(errorInfo.setFromLastError(
          'cannot find specified SFX module', options.sfxModule,
          Errno.enoent));
    }
  }

  final arcLink = ArchiveLink();

  if (needSetPath) {
    if (!options.initFormatIndex(codecs, types, cmdArcPath2) ||
        !options.setArcPath(codecs, cmdArcPath2)) {
      throw const SystemException(HRes.eNotImpl);
    }
  }

  var arcPath = options.archivePath.getFinalPath();
  if (options.volumesSizes.isNotEmpty) {
    arcPath = '${options.archivePath.getFinalVolPath()}.001';
  }

  if (chainOuter >= 0) {
    options.compoundOuterIndex = chainOuter;
  } else if (types.isEmpty && options.compoundOuterIndex < 0) {
    // x.tar.gz, x.tgz, x.tar.bz2, x.txz...: a tar inside the compressor
    final f = options.methodMode.type.formatIndex;
    if (f >= 0 &&
        isCompoundOuterFormat(codecs.formats[f]) &&
        codecs.formats[f].updateEnabled &&
        isCompoundTarName(extractFileNameFromPath(arcPath))) {
      options.compoundOuterIndex = f;
    }
  }

  try {
    if (cmdArcPath2.isEmpty) {
      if (options.methodMode.type.formatIndex < 0) {
        throw const StringException('type of archive is not specified');
      }
    } else {
      final fi = findFileFollowLink(arcPath);
      if (fi == null) {
        if (renameMode) throw const StringException("can't find archive");
        if (options.methodMode.type.formatIndex < 0) {
          if (!options.setArcPath(codecs, cmdArcPath2)) {
            throw const SystemException(HRes.eNotImpl);
          }
        }
      } else {
        if (fi.isDir) {
          throw SystemException(errorInfo.setFromErrorDword(
              'There is a folder with the name of archive',
              arcPath,
              Errno.eisdir));
        }
        if (!options.stdOutMode && options.updateArchiveItself) {
          if (fi.isReadOnly) {
            throw SystemException(errorInfo.setFromErrorDword(
                'The file is read-only', arcPath, Errno.eacces));
          }
        }
        if (options.volumesSizes.isNotEmpty) {
          errorInfo.fileNames.add(arcPath);
          errorInfo.message =
              'Updating for multivolume archives is not implemented';
          throw const SystemException(HRes.eNotImpl);
        }
        final types2 = <OpenType>[];
        if (options.methodMode.typeDefined) types2.add(options.methodMode.type);

        final op = OpenOptions()
          ..props = options.methodMode.properties
          ..codecs = codecs
          ..types = types2
          ..excludedFormats = const []
          ..stdInMode = false
          ..stream = null
          ..filePath = arcPath
          ..forceCompound = options.compoundOuterIndex >= 0
          ..compoundTempDir = _compoundTempDir(options, arcPath);

        callback.startOpenArchive(arcPath);
        int result;
        try {
          result = arcLink.openStrict(op, openCallback, null);
        } on SystemException catch (e) {
          result = e.errorCode;
        }
        if (result == HRes.eAbort) throw SystemException(result);
        callback.openResult(codecs, arcLink, arcPath, result);
        if (result != HRes.sOk) throw SystemException(result);

        if (arcLink.volumePaths.length > 1) {
          errorInfo.message =
              'Updating for multivolume archives is not implemented';
          throw const SystemException(HRes.eNotImpl);
        }
        final arc = arcLink.arcs.last;
        arc.mTime.def = true;
        arc.mTime.setFromFiTime(fi.mTime);
        if (arc.errorInfo.thereIsTail &&
            !(arc.compoundOuterIndex >= 0 && arc.errorInfo.ignoreTail)) {
          errorInfo.message =
              'There is some data block after the end of the archive';
          throw const SystemException(HRes.eNotImpl);
        }
        if (options.methodMode.type.formatIndex < 0) {
          options.methodMode.type.formatIndex = arcLink.getArc().formatIndex;
          if (!options.setArcPath(codecs, cmdArcPath2)) {
            throw const SystemException(HRes.eNotImpl);
          }
        }
      }
    }

    if (options.methodMode.type.formatIndex < 0) {
      options.methodMode.type.formatIndex =
          codecs.findFormatForArchiveType('7z');
      if (options.methodMode.type.formatIndex < 0) {
        throw const SystemException(HRes.eNotImpl);
      }
    }

    final thereIsInArchive = arcLink.isOpen;
    if (!thereIsInArchive && renameMode) throw const SystemException(HRes.eFail);

    final dirItems = DirItems()..callback = callback;
    DirItem? parentDirItemPtr;

    if (options.stdInMode) {
      final di = DirItem.empty()..setAsStdInFile(gIo.statStdin?.call());
      di.name = options.stdInFileName;
      dirItems.items.add(di);
    } else {
      var needScanning = false;
      if (!renameMode) {
        for (final c in options.commands) {
          if (c.actionSet.needScanning()) needScanning = true;
        }
      }
      if (needScanning) {
        callback.startScanning();
        dirItems.symLinks = options.symLinks.val;
        dirItems.scanAltStreams = options.altStreams.val;
        dirItems.excludeDirItems = censor.excludeDirItems;
        dirItems.excludeFileItems = censor.excludeFileItems;
        dirItems.shareForWrite = options.openShareForWrite;
        try {
          enumerateItems(censor, options.pathMode, '', dirItems);
        } on SystemException catch (e) {
          if (e.errorCode != HRes.eAbort) errorInfo.message = 'Scanning error';
          rethrow;
        }
        callback.finishScanning(dirItems.stat);

        if (options.pathMode != CensorPathMode.absPath) {
          if (censor.pairs.length == 1) {
            final prefix = '${censor.pairs[0].prefix}.';
            final fi = findFile(prefix);
            if (fi != null && fi.isDir) {
              parentDirItemPtr = DirItem(fi.name, fi, -1, -1);
            }
          }
        }
      }
    }

    final tempFiles = _TempFiles();
    var createTempFile = false;

    if (!options.stdOutMode && options.updateArchiveItself) {
      final ap = options.archivePath.copy();
      options.commands[0].archivePath = ap;
      if ((thereIsInArchive || options.workingDir.isNotEmpty) &&
          options.volumesSizes.isEmpty) {
        createTempFile = true;
        ap.temp = true;
        ap.tempPrefix =
            options.workingDir.isNotEmpty ? options.workingDir : ap.prefix;
        if (ap.tempPrefix.isNotEmpty && !endsWithPathSepar(ap.tempPrefix)) {
          ap.tempPrefix += kDirSep;
        }
      }
    }

    if (options.deleteAfterCompressing) {
      for (final c in options.commands) {
        final path = c.archivePath.getFinalPath();
        for (var i = 0; i < dirItems.items.length; i++) {
          if (dirItems.getPhyPath(i) == path) {
            throw StringException(
                'It is not allowed to include archive to itself\n$path');
          }
        }
      }
    }

    for (var ci = 0; ci < options.commands.length; ci++) {
      final ap = options.commands[ci].archivePath;
      if (!options.stdOutMode && (ci > 0 || !createTempFile)) {
        final path = ap.getFinalPath();
        if (doesFileOrDirExist(path)) {
          errorInfo.systemError = Errno.eexist;
          errorInfo.message = 'The file already exists';
          errorInfo.fileNames.add(path);
          throw SystemException(errorInfo.getHresultError());
        }
      }
    }

    var arcItems = <ArcItem>[];
    if (thereIsInArchive) {
      arcItems = _enumerateInArchiveItems(censor, arcLink.arcs.last);
    }

    Uint8List? processedItems;
    if (options.deleteAfterCompressing) {
      processedItems = Uint8List(dirItems.items.length);
    }

    final multiStreams = <MultiOutStream>[];
    var ok = false;
    try {
      for (var ci = 0; ci < options.commands.length; ci++) {
        final arc = thereIsInArchive ? arcLink.getArc() : null;
        final command = options.commands[ci];
        String name;
        bool isUpdating;
        if (options.stdOutMode) {
          name = 'stdout';
          isUpdating = thereIsInArchive;
        } else {
          name = command.archivePath.getFinalPath();
          isUpdating =
              ci == 0 && options.updateArchiveItself && thereIsInArchive;
        }
        callback.startArchive(name, isUpdating);
        final st = FinishArchiveStat();
        _compress(
            options,
            isUpdating,
            codecs,
            command.actionSet,
            arc,
            command.archivePath,
            arcItems,
            processedItems,
            dirItems,
            parentDirItemPtr,
            tempFiles,
            multiStreams,
            errorInfo,
            callback,
            st);
        callback.finishArchive(st);
      }
      ok = true;
    } finally {
      if (!ok) {
        for (final ms in multiStreams) {
          try {
            ms.destruct();
          } on Object {
            // ignore
          }
        }
        tempFiles.clear();
      }
    }

    if (thereIsInArchive) {
      arcLink.close();
      arcLink.release();
    }

    tempFiles.needDeleteFiles = false;

    if (createTempFile) {
      final ap = options.commands[0].archivePath;
      final tempPath = ap.getTempPath();
      if (thereIsInArchive) {
        if (!deleteFileAlways(arcPath)) {
          throw SystemException(
              errorInfo.setFromLastError('cannot delete the file', arcPath));
        }
      }
      var totalArcSize = 0;
      final tfi = findFile(tempPath);
      if (tfi != null) totalArcSize = tfi.size;
      callback.moveArcStart(tempPath, arcPath, totalArcSize, thereIsInArchive);
      if (!myMoveFile(tempPath, arcPath)) {
        errorInfo.systemError = lastFindErrno;
        errorInfo.message = 'cannot move the file';
        errorInfo.fileNames.add(tempPath);
        errorInfo.fileNames.add(arcPath);
        throw SystemException(errorInfo.getHresultError());
      }
      callback.moveArcFinish();
    }

    if (options.deleteAfterCompressing) {
      final dirIndices = <int>[];
      for (var i = 0; i < dirItems.items.length; i++) {
        final dirItem = dirItems.items[i];
        final phyPath = dirItems.getPhyPath(i);
        if (dirItem.isDir()) {
          dirIndices.add(i);
        } else if (processedItems![i] != 0) {
          final fileInfo = findFile(phyPath, followLink: !options.symLinks.val);
          if (fileInfo != null) {
            bool isSameSize;
            if (options.symLinks.val && dirItem.areReparseData()) {
              isSameSize = fileInfo.isOsSymLink;
            } else {
              isSameSize = fileInfo.size == dirItem.size;
            }
            if (isSameSize &&
                fileInfo.mTime.compare(dirItem.mTime) == 0 &&
                fileInfo.cTime.compare(dirItem.cTime) == 0) {
              callback.deletingAfterArchiving(phyPath, false);
              deleteFileAlways(phyPath);
            }
          }
        }
      }
      int numSlashes(String s) {
        var n = 0;
        for (var i = 0; i < s.length; i++) {
          if (isPathSepar(s.codeUnitAt(i))) n++;
        }
        return n;
      }
      final paths = [for (final i in dirIndices) dirItems.getPhyPath(i)];
      final order = List<int>.generate(paths.length, (i) => i);
      order.sort((a, b) {
        final la = numSlashes(paths[a]), lb = numSlashes(paths[b]);
        if (la < lb) return 1;
        if (la > lb) return -1;
        return a.compareTo(b);
      });
      for (final k in order) {
        final phyPath = paths[k];
        if (doesDirExist(phyPath)) {
          callback.deletingAfterArchiving(phyPath, true);
          removeDirAlwaysIfEmpty(phyPath);
        }
      }
      callback.finishDeletingAfterArchiving();
    }
  } finally {
    arcLink.close();
  }
}

// The folder of the temporary tar of a compound archive being updated:
// the -w folder, else the folder of the archive (with its separator).
String _compoundTempDir(UpdateOptions options, String arcPath) {
  var dir = options.workingDir;
  if (dir.isEmpty) dir = splitPathToParts2(arcPath).$1;
  dir = resolvePath(dir);
  if (dir.isNotEmpty && !endsWithPathSepar(dir)) dir += kDirSep;
  return dir;
}
