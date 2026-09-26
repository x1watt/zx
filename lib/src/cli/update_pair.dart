// Pairing of disk items with archive items for the update commands:
// UI/Common/UpdateAction.cpp (the action sets of a, u, d and -u),
// UI/Common/UpdatePair.cpp (GetUpdatePairInfoList, MyCompareTime),
// UI/Common/UpdateProduce.cpp (UpdateProduce) and UI/Common/SortUtils.cpp
// of the LZMA SDK.

import 'common.dart';
import 'enum_dir_items.dart';
import 'open_archive.dart';
import 'wildcard.dart';

/// NUpdateArchive::NPairState.
abstract final class PairState {
  static const numValues = 7;
  static const notMasked = 0;
  static const onlyInArchive = 1;
  static const onlyOnDisk = 2;
  static const newInArchive = 3;
  static const oldInArchive = 4;
  static const sameFiles = 5;
  static const unknowNewerFiles = 6;
}

/// NUpdateArchive::NPairAction.
abstract final class PairAction {
  static const ignore = 0;
  static const copy = 1;
  static const compress = 2;
  static const compressAsAnti = 3;
}

/// CActionSet.
class ActionSet {
  final List<int> stateActions;
  ActionSet(List<int> actions) : stateActions = List.of(actions);

  ActionSet copy() => ActionSet(stateActions);

  bool isEqualTo(ActionSet a) {
    for (var i = 0; i < PairState.numValues; i++) {
      if (stateActions[i] != a.stateActions[i]) return false;
    }
    return true;
  }

  // NeedScanning
  bool needScanning() {
    for (var i = 0; i < PairState.numValues; i++) {
      if (stateActions[i] == PairAction.compress) return true;
    }
    for (var i = 1; i < PairState.numValues; i++) {
      if (stateActions[i] != PairAction.ignore) return true;
    }
    return false;
  }
}

const _c = PairAction.copy;
const _z = PairAction.compress;
const _i = PairAction.ignore;

/// k_ActionSet_Add.
ActionSet kActionSetAdd() => ActionSet([_c, _c, _z, _z, _z, _z, _z]);

/// k_ActionSet_Update.
ActionSet kActionSetUpdate() => ActionSet([_c, _c, _z, _c, _z, _c, _z]);

/// k_ActionSet_Fresh.
ActionSet kActionSetFresh() => ActionSet([_c, _c, _i, _c, _z, _c, _z]);

/// k_ActionSet_Sync.
ActionSet kActionSetSync() => ActionSet([_c, _i, _z, _c, _z, _c, _z]);

/// k_ActionSet_Delete.
ActionSet kActionSetDelete() => ActionSet([_c, _i, _i, _i, _i, _i, _i]);

/// CUpdatePair.
class UpdatePair {
  int state = 0;
  int arcIndex = -1;
  int dirIndex = -1;
  int hostIndex = -1;
}

// FileTime_To_UnixTime64
int _fileTimeToUnixTime64(int ft) =>
    (ft ~/ 10000000) - (kFileTimeUnixEpoch ~/ 10000000);

// MyCompareTime
int _myCompareTime(int prec, FiTime f1, ArcTime a2) {
  // (unsigned) NFileTimeType::kNotDefined is a big value
  if (prec < 0) prec = 0x7FFFFFFF;
  if (a2.prec != TimePrecVals.prec0) prec = a2.prec;
  final a1 = ArcTime()..setFromFiTime(f1);

  if (prec == TimePrecVals.dos) {
    // FileTime_To_DosTime with 2 s resolution (rounded up)
    int dos(int ft) => (ft + 20000000 - 1) ~/ 20000000;
    return dos(a1.ft).compareTo(dos(a2.ft));
  }
  if (prec == TimePrecVals.unix) {
    final u2 = _fileTimeToUnixTime64(a2.ft);
    final u1 = _fileTimeToUnixTime64(a1.ft);
    if (u2 == 0 || u2 == 0xFFFFFFFF) {
      int sat(int u) => u < 0 ? 0 : (u > 0xFFFFFFFF ? 0xFFFFFFFF : u);
      return sat(u1).compareTo(u2);
    }
    return u1.compareTo(u2);
  }
  if (prec == TimePrecVals.prec0) {
    prec = TimePrecVals.base + 7;
  } else if (prec == TimePrecVals.highPrec) {
    prec = TimePrecVals.base + 9;
  } else if (prec < TimePrecVals.base) {
    prec = TimePrecVals.base;
  } else if (prec > TimePrecVals.base + 9) {
    prec = TimePrecVals.base + 7;
  }
  if (prec > a1.prec && a1.prec >= TimePrecVals.base) prec = a1.prec;
  final numDigits = prec - TimePrecVals.base;
  if (numDigits >= 7) {
    final comp = compareU64(a1.ft, a2.ft);
    if (comp != 0 || numDigits == 7) return comp;
    return a1.ns100.compareTo(a2.ns100);
  }
  var d = 1;
  for (var k = numDigits; k < 7; k++) {
    d *= 10;
  }
  final v1 = a1.ft ~/ d * d;
  final v2 = a2.ft ~/ d * d;
  return compareU64(v1, v2);
}

// ThrowError
Never _throwError(String message, String s1, String s2) =>
    throw StringException('$message\n$s1\n$s2');

// CompareArcItemsBase
int _compareArcItemsBase(ArcItem ai1, ArcItem ai2) {
  final res = compareFileNames(ai1.name, ai2.name);
  if (res != 0) return res;
  if (ai1.isDir != ai2.isDir) return ai1.isDir ? -1 : 1;
  return 0;
}

/// GetUpdatePairInfoList.
List<UpdatePair> getUpdatePairInfoList(
    DirItems dirItems, List<ArcItem> arcItems, int fileTimeType) {
  final updatePairs = <UpdatePair>[];
  final numDirItems = dirItems.items.length;
  final numArcItems = arcItems.length;

  final duplicatedArcItem = List<int>.filled(numArcItems, 0);
  final arcIndices = List<int>.generate(numArcItems, (i) => i);
  arcIndices.sort((i1, i2) {
    final res = _compareArcItemsBase(arcItems[i1], arcItems[i2]);
    if (res != 0) return res;
    return i1.compareTo(i2);
  });
  for (var i = 0; i + 1 < numArcItems; i++) {
    if (_compareArcItemsBase(
            arcItems[arcIndices[i]], arcItems[arcIndices[i + 1]]) ==
        0) {
      duplicatedArcItem[i] = 1;
      duplicatedArcItem[i + 1] = -1;
    }
  }

  final dirNames = [for (var i = 0; i < numDirItems; i++) dirItems.getLogPath(i)];
  final dirIndices = sortFileNames(dirNames);
  for (var i = 0; i + 1 < numDirItems; i++) {
    final s1 = dirNames[dirIndices[i]];
    final s2 = dirNames[dirIndices[i + 1]];
    if (compareFileNames(s1, s2) == 0) {
      _throwError('Duplicate filename on disk:', s1, s2);
    }
  }

  var dirIndex = 0;
  var arcIndex = 0;
  var prevHostFile = -1;
  String? prevHostName;

  while (dirIndex < numDirItems || arcIndex < numArcItems) {
    final pair = UpdatePair();
    var dirIndex2 = -1;
    var arcIndex2 = -1;
    DirItem? di;
    ArcItem? ai;
    var compareResult = -1;
    String name;

    if (dirIndex < numDirItems) {
      dirIndex2 = dirIndices[dirIndex];
      di = dirItems.items[dirIndex2];
    }
    if (arcIndex < numArcItems) {
      arcIndex2 = arcIndices[arcIndex];
      ai = arcItems[arcIndex2];
      compareResult = 1;
      if (dirIndex < numDirItems) {
        compareResult = compareFileNames(dirNames[dirIndex2], ai.name);
        if (compareResult == 0) {
          if (di!.isDir() != ai.isDir) compareResult = ai.isDir ? 1 : -1;
        }
      }
    }

    if (compareResult < 0) {
      name = dirNames[dirIndex2];
      pair.state = PairState.onlyOnDisk;
      pair.dirIndex = dirIndex2;
      dirIndex++;
    } else if (compareResult > 0) {
      name = ai!.name;
      pair.state =
          ai.censored ? PairState.onlyInArchive : PairState.notMasked;
      pair.arcIndex = arcIndex2;
      arcIndex++;
    } else {
      final dupl = duplicatedArcItem[arcIndex];
      if (dupl != 0) {
        _throwError('Duplicate filename in archive:', ai!.name,
            arcItems[arcIndices[arcIndex + dupl]].name);
      }
      name = dirNames[dirIndex2];
      if (!ai!.censored) {
        _throwError(
            'Internal file name collision (file on disk, file in archive):',
            name,
            ai.name);
      }
      pair.dirIndex = dirIndex2;
      pair.arcIndex = arcIndex2;
      var compResult = 0;
      if (ai.mTime.def) {
        compResult = _myCompareTime(fileTimeType, di!.mTime, ai.mTime);
      }
      switch (compResult) {
        case -1:
          pair.state = PairState.newInArchive;
        case 1:
          pair.state = PairState.oldInArchive;
        default:
          pair.state = (ai.sizeDefined && di!.size == ai.size)
              ? PairState.sameFiles
              : PairState.unknowNewerFiles;
      }
      dirIndex++;
      arcIndex++;
    }

    if (ai != null && ai.isAltStream) {
      final ph = prevHostName;
      if (ph != null) {
        final hostLen = ph.length;
        if (name.length > hostLen) {
          if (name[hostLen] == ':' &&
              compareFileNames(ph, name.substring(0, hostLen)) == 0) {
            pair.hostIndex = prevHostFile;
          }
        }
      }
    } else {
      prevHostFile = updatePairs.length;
      prevHostName = name;
    }
    updatePairs.add(pair);
  }
  return updatePairs;
}

/// SortFileNames: the indices of [strings] in CompareFileNames order.
List<int> sortFileNames(List<String> strings) {
  final indices = List<int>.generate(strings.length, (i) => i);
  indices.sort((a, b) {
    final r = compareFileNames(strings[a], strings[b]);
    return r != 0 ? r : a.compareTo(b);
  });
  return indices;
}

/// CUpdatePair2.
class UpdatePair2 {
  bool newData = false;
  bool newProps = false;
  bool useArcProps = false;
  bool isAnti = false;
  int dirIndex = -1;
  int arcIndex = -1;
  int newNameIndex = -1;
  bool isMainRenameItem = false;
  bool isSameTime = false;

  // SetAs_NoChangeArcItem
  void setAsNoChangeArcItem(int arcIndex) {
    newData = newProps = false;
    useArcProps = true;
    isAnti = false;
    this.arcIndex = arcIndex;
  }

  bool existOnDisk() => dirIndex != -1;
  bool existInArchive() => arcIndex != -1;
}

/// IUpdateProduceCallback.
abstract interface class UpdateProduceCallback {
  void showDeleteFile(int arcIndex);
}

/// UpdateProduce.
List<UpdatePair2> updateProduce(List<UpdatePair> updatePairs,
    ActionSet actionSet, UpdateProduceCallback? callback) {
  const kUpdateActionSetCollision = 'Internal collision in update action set';
  final operationChain = <UpdatePair2>[];
  for (final pair in updatePairs) {
    final up2 = UpdatePair2()
      ..dirIndex = pair.dirIndex
      ..arcIndex = pair.arcIndex
      ..newData = true
      ..newProps = true
      ..useArcProps = false;
    switch (actionSet.stateActions[pair.state]) {
      case PairAction.ignore:
        if (pair.arcIndex >= 0 && callback != null) {
          callback.showDeleteFile(pair.arcIndex);
        }
        continue;
      case PairAction.copy:
        if (pair.state == PairState.onlyOnDisk) {
          throw const StringException(kUpdateActionSetCollision);
        }
        if (pair.state == PairState.onlyInArchive) {
          if (pair.hostIndex >= 0) {
            if (updatePairs[pair.hostIndex].dirIndex >= 0) continue;
          }
        }
        up2.newData = up2.newProps = false;
        up2.useArcProps = true;
      case PairAction.compress:
        if (pair.state == PairState.onlyInArchive ||
            pair.state == PairState.notMasked) {
          throw const StringException(kUpdateActionSetCollision);
        }
      case PairAction.compressAsAnti:
        up2.isAnti = true;
        up2.useArcProps = pair.arcIndex >= 0;
      default:
        throw const StringException(kUpdateActionSetCollision);
    }
    up2.isSameTime = pair.state == PairState.sameFiles;
    operationChain.add(up2);
  }
  return operationChain;
}

