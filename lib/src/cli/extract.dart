// The extract group commands (e, x, t): UI/Common/Extract.cpp of the LZMA
// SDK (DecompressArchive, Extract).

import 'dart:io';

import '../format/archive_types.dart';
import 'archive_extract_callback.dart';
import 'common.dart';
import 'extracting_file_path.dart';
import 'fs_utils.dart';
import 'globals.dart';
import 'hash_calc.dart';
import 'list.dart' show findFileNameInSortedVector;
import 'load_codecs.dart';
import 'open_archive.dart';
import 'platform.dart';
import 'wildcard.dart';

/// CExtractOptions.
class ExtractOptions {
  BoolPair2 elimDup = BoolPair2();
  bool excludeDirItems = false;
  bool excludeFileItems = false;
  bool pathModeForce = false;
  bool overwriteModeForce = false;
  PathMode pathMode = PathMode.fullPaths;
  OverwriteMode overwriteMode = OverwriteMode.ask;
  ExtractOutDirMode outDirMode = ExtractOutDirMode.replaceAsterisk;
  ExtractNtOptions ntOptions = ExtractNtOptions();
  String outputDir = '';
  String hashDir = '';

  /// NExtract::NZoneIdMode (-snz, Windows): 0 none, 1 all, 2 office.
  int zoneMode = 0;

  bool stdInMode = false;
  bool stdOutMode = false;
  bool yesToAll = false;
  bool testMode = false;
  List<MapEntry<String, String>> properties = [];
}

/// CDecompressStat.
class DecompressStat {
  int numArchives = 0;
  int unpackSize = 0;
  int altStreamsUnpackSize = 0;
  int packSize = 0;
  int numFolders = 0;
  int numFiles = 0;
  int numAltStreams = 0;
}

/// IExtractCallbackUI (with the open callback of the same object).
abstract class ExtractCallbackUI extends OpenCallbackUI
    implements FolderArchiveExtractCallback {
  void beforeOpen(String name, bool testMode);
  void openResult(Codecs codecs, ArchiveLink arcLink, String name, int result);
  void thereAreNoFiles();

  /// ExtractResult: throws for a result that stops the command.
  void extractResult(int result);
}

/// CArchiveExtractCallback_Closer.
int _closeEcs(ArchiveExtractCallbackImpl ecs) {
  try {
    ecs.closeArc();
  } on SystemException catch (e) {
    return e.errorCode;
  }
  return HRes.sOk;
}

// DecompressArchive: returns stdInProcessed.
int _decompressArchive(
    Codecs codecs,
    ArchiveLink arcLink,
    int packSize,
    CensorNode wildcardCensor,
    ExtractOptions options,
    bool calcCrc,
    ExtractCallbackUI callback,
    ArchiveExtractCallbackImpl ecs,
    List<String> errorMessage) {
  final arc = arcLink.arcs.last;
  var stdInProcessed = 0;
  final archive = arc.archive!;
  final realIndices = <int>[];
  final removePathParts = <String>[];

  var outDir = options.outputDir;
  if (options.outDirMode != ExtractOutDirMode.direct) {
    final replaceName = arc.defaultName;
    final correctedName = getCorrectFsFileName(replaceName);
    if (options.outDirMode == ExtractOutDirMode.addArcName) {
      outDir += correctedName;
      outDir = normalizeDirPathPrefix(outDir);
    } else {
      outDir = outDir.replaceAll('*', correctedName);
    }
  }

  var elimIsPossible = false;
  var elimPrefix = '';
  if (options.elimDup.val && options.pathMode != PathMode.absPaths) {
    final (_, name) = splitPathToPartsSmart(outDir);
    elimPrefix = name;
    if (elimPrefix.isNotEmpty) {
      if (endsWithPathSepar(elimPrefix)) {
        elimPrefix = elimPrefix.substring(0, elimPrefix.length - 1);
      }
      if (elimPrefix.isNotEmpty) elimIsPossible = true;
    }
  }

  final allFilesAreAllowed = wildcardCensor.areAllAllowed();

  // a one pass archive (-si, or a compound tar read without a temporary
  // file, arc_compound.dart): all items in order, the censor selects
  final seqMode = options.stdInMode || arc.isSeq;

  if (!seqMode) {
    final numItems = archive.numberOfItems;
    final item = ReadArcItem();
    for (var i = 0; i < numItems; i++) {
      if (elimIsPossible ||
          !allFilesAreAllowed ||
          options.excludeDirItems ||
          options.excludeFileItems) {
        arc.getItem(i, item);
        if (item.isDir ? options.excludeDirItems : options.excludeFileItems) {
          continue;
        }
      } else {
        item.isAltStream = false;
        if (!options.ntOptions.altStreams.val && arc.askAltStream) {
          item.isAltStream =
              archiveGetItemBoolProp(archive, i, Kpid.isAltStream);
        }
      }
      if (!options.ntOptions.altStreams.val && item.isAltStream) continue;

      if (elimIsPossible) {
        final s = item.mainPath;
        if (!isPath1PrefixedByPath2(s, elimPrefix)) {
          elimIsPossible = false;
        } else {
          if (s.length == elimPrefix.length) {
            if (!item.mainIsDir) elimIsPossible = false;
          } else if (!isPathSepar(s.codeUnitAt(elimPrefix.length))) {
            elimIsPossible = false;
          }
        }
      }
      if (!allFilesAreAllowed) {
        if (!censorNodeCheckPath(wildcardCensor, item)) continue;
      }
      realIndices.add(i);
    }
    if (realIndices.isEmpty) {
      callback.thereAreNoFiles();
      callback.extractResult(HRes.sOk);
      return stdInProcessed;
    }
  }

  if (elimIsPossible) removePathParts.add(elimPrefix);

  if (outDir.isEmpty) {
    outDir = '.$kDirSep';
  } else if (!createComplexDir(outDir)) {
    final res = hresultFromErrno(lastFindErrno);
    errorMessage.add(
        'Cannot create output directory : ${myFormatMessage(res)} : $outDir');
    throw SystemException(res);
  }

  ecs.init(
      options.ntOptions,
      seqMode ? wildcardCensor : null,
      arc,
      callback,
      options.stdOutMode,
      options.testMode,
      outDir,
      removePathParts,
      false,
      packSize);
  ecs.isElimPrefixMode = elimIsPossible;

  var result = HRes.sOk;
  final testMode = options.testMode && !calcCrc;
  try {
    if (seqMode) {
      archive.extract(null, testMode, ecs);
      final p = archive.getArchiveProperty(Kpid.phySize);
      if (p is int && options.stdInMode) stdInProcessed = p;
    } else {
      ecs.setCompleted(0);
      archive.extract(realIndices, testMode, ecs);
    }
  } on SystemException catch (e) {
    result = e.errorCode;
  } on FileSystemException catch (e) {
    result = hresultOfFileSystemException(e);
  }
  final res2 = _closeEcs(ecs);
  if (result == HRes.sOk) result = res2;
  callback.extractResult(result);
  return stdInProcessed;
}

/// Extract: throws [SystemException] for errors that stop the command;
/// [errorMessage] gets a message for them.
void extract(
    Codecs codecs,
    List<OpenType> types,
    List<int> excludedFormats,
    List<String> arcPaths,
    List<String> arcPathsFull,
    CensorNode wildcardCensor,
    ExtractOptions options,
    ExtractCallbackUI callback,
    HashBundle? hash,
    List<String> errorMessage,
    DecompressStat st) {
  var totalPackSize = 0;
  final arcSizes = <int>[];
  final numArcs = options.stdInMode ? 1 : arcPaths.length;

  for (var i = 0; i < numArcs; i++) {
    var size = 0;
    if (!options.stdInMode) {
      final arcPath = arcPaths[i];
      final fi = findFileFollowLink(arcPath);
      if (fi == null) {
        final errorCode = hresultFromErrno(lastFindErrno);
        errorMessage.add(
            'Cannot find archive file : ${myFormatMessage(errorCode)} : $arcPath');
        throw SystemException(errorCode);
      }
      if (fi.isDir) {
        const errorCode = HRes.eFail;
        errorMessage.add(
            'The item is a directory : ${myFormatMessage(errorCode)} : $arcPath');
        throw const SystemException(errorCode);
      }
      size = fi.size;
    }
    arcSizes.add(size);
    totalPackSize += size;
  }

  final skipArcs = List<bool>.filled(numArcs, false);
  final ecs = ArchiveExtractCallbackImpl();
  final multi = numArcs > 1;
  ecs.initForMulti(multi, options.pathMode, options.overwriteMode, false);
  ecs.setHashMethods(hash);

  if (multi) callback.setTotal(totalPackSize);

  var totalPackProcessed = 0;
  var thereAreNotOpenArcs = false;

  for (var i = 0; i < numArcs; i++) {
    if (skipArcs[i]) continue;
    ecs.initBeforeNewArchive();
    final arcPath = arcPaths[i];
    var fiSize = 0;
    FiTime? fiMTime;
    if (!options.stdInMode) {
      final fi = findFileFollowLink(arcPath);
      if (fi == null || fi.isDir) {
        final errorCode = hresultFromErrno(
            fi == null ? lastFindErrno : Errno.eisdir);
        errorMessage.add(
            'Cannot find archive file : ${myFormatMessage(errorCode)} : $arcPath');
        throw SystemException(errorCode);
      }
      fiSize = fi.size;
      fiMTime = fi.mTime;
    }

    if (kIsWin && options.zoneMode != 0 && !options.stdInMode) {
      ecs.zoneBuf = readZoneFileOfBaseFile(resolvePath(arcPath));
      ecs.zoneMode = options.zoneMode;
    }

    callback.beforeOpen(arcPath, options.testMode);
    final arcLink = ArchiveLink();

    final op = OpenOptions()
      ..props = options.properties
      ..codecs = codecs
      ..types = types
      ..excludedFormats = excludedFormats
      ..stdInMode = options.stdInMode
      ..stream = null
      ..filePath = arcPath;

    int result;
    try {
      result = arcLink.openStrict(
          op, callback, options.stdInMode ? gStdIn.dataStream : null);
    } on SystemException catch (e) {
      result = e.errorCode;
    }
    if (result == HRes.eAbort) {
      arcLink.close();
      throw SystemException(result);
    }

    try {
      callback.openResult(codecs, arcLink, arcPath, result);

      if (result != HRes.sOk) {
        thereAreNotOpenArcs = true;
        if (!options.stdInMode) totalPackProcessed += fiSize;
        continue;
      }

      if (!options.stdInMode) {
        if (arcLink.volumePaths.isNotEmpty) {
          var correctionSize = arcLink.volumesSize;
          for (final v in arcLink.volumePaths) {
            final index = findFileNameInSortedVector(arcPathsFull, v);
            if (index >= 0) {
              if (index > i) {
                skipArcs[index] = true;
                correctionSize -= arcSizes[index];
              }
            }
          }
          if (correctionSize != 0) {
            var newPackSize = totalPackSize + correctionSize;
            if (newPackSize < 0) newPackSize = 0;
            totalPackSize = newPackSize;
            callback.setTotal(totalPackSize);
          }
        }
      }

      final arc = arcLink.arcs.last;
      arc.mTime.def = !options.stdInMode;
      if (arc.mTime.def) arc.mTime.setFromFiTime(fiMTime!);

      final calcCrc = hash != null;
      var packProcessed = _decompressArchive(
          codecs,
          arcLink,
          fiSize + arcLink.volumesSize,
          wildcardCensor,
          options,
          calcCrc,
          callback,
          ecs,
          errorMessage);

      if (!options.stdInMode) packProcessed = fiSize + arcLink.volumesSize;
      totalPackProcessed += packProcessed;
      ecs.localProgressInSize += packProcessed;
      ecs.localProgressOutSize = ecs.unpackSize;
      if (errorMessage.isNotEmpty) throw const SystemException(HRes.eFail);
    } finally {
      arcLink.close();
    }
  }

  if (multi || thereAreNotOpenArcs) {
    callback.setTotal(totalPackSize);
    callback.setCompleted(totalPackProcessed);
  }

  st.numFolders = ecs.numFolders;
  st.numFiles = ecs.numFiles;
  st.numAltStreams = ecs.numAltStreams;
  st.unpackSize = ecs.unpackSize;
  st.altStreamsUnpackSize = ecs.altStreamsUnpackSize;
  st.numArchives = arcPaths.length;
  st.packSize = ecs.localProgressInSize;
}
