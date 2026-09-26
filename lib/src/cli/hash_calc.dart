// Hash calculation: UI/Common/HashCalc.cpp of the LZMA SDK (CHashBundle,
// CHasherState, HashCalc for the "h" command and the -scrc switch of the
// extract commands, HashHexToString) with the hashers of 7zr (CrcReg.cpp,
// Sha256Reg.cpp, XzCrc64Reg.cpp).

import 'dart:io';
import 'dart:typed_data';

import '../common/method_props.dart';
import '../crypto/sha256.dart';
import '../io/streams.dart';
import '../util/crc.dart';
import 'common.dart';
import 'enum_dir_items.dart';
import 'fs_utils.dart';
import 'globals.dart';
import 'wildcard.dart';
import 'platform.dart';

const int kHashCalcDigestSizeMax = 64;
const int kHashCalcExtraSize = 8;
const int kHashCalcNumGroups = 4;

const int kHashCalcIndexCurrent = 0;
const int kHashCalcIndexDataSum = 1;
const int kHashCalcIndexNamesSum = 2;
const int kHashCalcIndexStreamsSum = 3;

/// IHasher.
abstract class Hasher {
  String get name;
  int get id;
  int get digestSize;
  void init();
  void update(Uint8List data, int off, int size);

  /// Final: the digest bytes.
  Uint8List finalDigest();
}

class _Crc32Hasher extends Hasher {
  int _v = 0xFFFFFFFF;
  @override
  String get name => 'CRC32';
  @override
  int get id => 1;
  @override
  int get digestSize => 4;
  @override
  void init() => _v = 0xFFFFFFFF;
  @override
  void update(Uint8List data, int off, int size) =>
      _v = crc32Update(_v, data, off, off + size);
  @override
  Uint8List finalDigest() {
    final v = _v ^ 0xFFFFFFFF;
    return Uint8List(4)
      ..[0] = v
      ..[1] = v >> 8
      ..[2] = v >> 16
      ..[3] = v >> 24;
  }
}

class _Crc64Hasher extends Hasher {
  Crc64 _c = Crc64();
  @override
  String get name => 'CRC64';
  @override
  int get id => 4;
  @override
  int get digestSize => 8;
  @override
  void init() => _c = Crc64();
  @override
  void update(Uint8List data, int off, int size) =>
      _c.update(data, off, off + size);
  @override
  Uint8List finalDigest() => _c.bytes;
}

class _Sha256Hasher extends Hasher {
  final Sha256 _s = Sha256();
  @override
  String get name => 'SHA256';
  @override
  int get id => 0xA;
  @override
  int get digestSize => 32;
  @override
  void init() => _s.init();
  @override
  void update(Uint8List data, int off, int size) => _s.update(data, off, size);
  @override
  Uint8List finalDigest() => _s.digest();
}

/// g_Hashers of 7zr (registration order).
List<Hasher Function()> _hasherFactories = [
  _Crc32Hasher.new,
  _Sha256Hasher.new,
  _Crc64Hasher.new,
];

// FindHashMethod: (id, factory) or null
Hasher? _createHasherByName(String name) {
  for (final f in _hasherFactories) {
    final h = f();
    if (h.name.toLowerCase() == name.toLowerCase()) return h;
  }
  return null;
}

/// HashHexToString.
String hashHexToString(Uint8List? data, int size, [int off = 0]) {
  if (data == null) return '  ' * size;
  if (size > 8) return dataToHexLower(data, off, size);
  if (size == 0) return '';
  final sb = StringBuffer();
  for (var i = size - 1; i >= 0; i--) {
    final b = data[off + i];
    sb.write(_hexU(b >> 4));
    sb.write(_hexU(b & 15));
  }
  return sb.toString();
}

String _hexU(int v) => String.fromCharCode(v < 10 ? 0x30 + v : 0x41 + v - 10);

/// CHasherState.
class HasherState {
  final Hasher hasher;
  final String name;
  final int digestSize;
  final List<int> numSums = List<int>.filled(kHashCalcNumGroups, 0);
  final List<Uint8List> digests = [
    for (var i = 0; i < kHashCalcNumGroups; i++)
      Uint8List(kHashCalcDigestSizeMax + kHashCalcExtraSize)
  ];

  HasherState(this.hasher)
      : name = hasher.name,
        digestSize = hasher.digestSize;

  // InitDigestGroup
  void initDigestGroup(int groupIndex) {
    numSums[groupIndex] = 0;
    digests[groupIndex].fillRange(0, digests[groupIndex].length, 0);
  }

  // GetNumExtraBytes_for_Group
  int getNumExtraBytesForGroup(int groupIndex) {
    final p = digests[groupIndex];
    for (var i = kHashCalcExtraSize; i != 0; i--) {
      if (p[kHashCalcDigestSizeMax + i - 1] != 0) return i;
    }
    return 0;
  }

  // AddDigests
  static void _addDigests(Uint8List dest, Uint8List src, int size) {
    var next = 0;
    for (var i = 0; i < size; i++) {
      next += dest[i] + src[i];
      dest[i] = next;
      next >>= 8;
    }
    for (var i = 0; i < kHashCalcExtraSize; i++) {
      next += dest[kHashCalcDigestSizeMax + i];
      dest[kHashCalcDigestSizeMax + i] = next;
      next >>= 8;
    }
  }

  // AddDigest
  void addDigest(int groupIndex, Uint8List data) {
    numSums[groupIndex]++;
    _addDigests(digests[groupIndex], data, digestSize);
  }

  // WriteToString
  String writeToString(int digestIndex) {
    var s = hashHexToString(digests[digestIndex], digestSize);
    if (digestIndex != 0 && numSums[digestIndex] != 1) {
      var numExtraBytes = getNumExtraBytesForGroup(digestIndex);
      numExtraBytes = numExtraBytes > 4 ? 8 : 4;
      s += '-${hashHexToString(digests[digestIndex], numExtraBytes, kHashCalcDigestSizeMax)}';
    }
    return s;
  }
}

/// CHashBundle.
class HashBundle {
  final List<HasherState> hashers = [];
  int numDirs = 0;
  int numFiles = 0;
  int numAltStreams = 0;
  int filesSize = 0;
  int altStreamsSize = 0;
  int numErrors = 0;
  int curSize = 0;

  /// SetMethods: throws [SystemException] (E_NOTIMPL) for unknown names.
  void setMethods(List<String> hashMethods) {
    final names = List.of(hashMethods);
    if (names.isEmpty) names.add('CRC32');
    final ids = <int>[];
    final hs = <Hasher>[];

    void addSorted(Hasher h) {
      if (ids.contains(h.id)) return;
      var pos = 0;
      while (pos < ids.length && ids[pos] < h.id) {
        pos++;
      }
      ids.insert(pos, h.id);
      hs.insert(pos, h);
    }

    for (final n in names) {
      final m = OneMethodInfo();
      try {
        m.parseMethodFromString(n);
      } on InvalidArgException {
        throw const SystemException(HRes.eInvalidArg);
      }
      if (m.methodName.isEmpty) m.methodName = 'CRC32';
      if (m.methodName == '*') {
        ids.clear();
        hs.clear();
        for (final f in _hasherFactories) {
          addSorted(f());
        }
        break;
      }
      final h = _createHasherByName(m.methodName);
      if (h == null) throw const SystemException(HRes.eNotImpl);
      addSorted(h);
    }
    for (final h in hs) {
      final st = HasherState(h);
      for (var k = 0; k < kHashCalcNumGroups; k++) {
        st.initDigestGroup(k);
      }
      hashers.add(st);
    }
  }

  // InitForNewFile
  void initForNewFile() {
    curSize = 0;
    for (final h in hashers) {
      h.hasher.init();
      h.initDigestGroup(kHashCalcIndexCurrent);
    }
  }

  // Update
  void update(Uint8List data, int off, int size) {
    curSize += size;
    for (final h in hashers) {
      h.hasher.update(data, off, size);
    }
  }

  // SetSize
  void setSize(int size) => curSize = size;

  // Final
  void finalItem(bool isDir, bool isAltStream, String path) {
    if (isDir) {
      numDirs++;
    } else if (isAltStream) {
      numAltStreams++;
      altStreamsSize += curSize;
    } else {
      numFiles++;
      filesSize += curSize;
    }
    final pre = Uint8List(16);
    if (isDir) pre[0] = 1;
    for (final h in hashers) {
      if (!isDir) {
        final d = h.hasher.finalDigest();
        h.digests[0].setRange(0, d.length, d);
        if (!isAltStream) h.addDigest(kHashCalcIndexDataSum, h.digests[0]);
      }
      h.hasher.init();
      h.hasher.update(pre, 0, pre.length);
      h.hasher.update(h.digests[0], 0, h.digestSize);
      final temp = Uint8List(2);
      for (var k = 0; k < path.length; k++) {
        var c = path.codeUnitAt(k);
        // 21.04: we want same hash for linux and windows paths
        if (c == kDirSepCode) c = 0x2F;
        temp[0] = c & 0xFF;
        temp[1] = (c >> 8) & 0xFF;
        h.hasher.update(temp, 0, 2);
      }
      final tempDigest = h.hasher.finalDigest();
      if (!isAltStream) h.addDigest(kHashCalcIndexNamesSum, tempDigest);
      h.addDigest(kHashCalcIndexStreamsSum, tempDigest);
    }
  }
}

/// IHashCallbackUI.
abstract class HashCallbackUI implements DirItemsCallback {
  void startScanning();
  void finishScanning(DirItemsStat st);
  void setNumFiles(int numFiles);
  void setTotal(int size);
  void setCompleted(int completeValue);
  void beforeFirstFile(HashBundle hb);
  void getStream(String name, bool isDir);

  /// OpenFileError: returns normally for S_FALSE (continue); throws to stop.
  void openFileError(String path, int systemError);
  void setOperationResult(int fileSize, HashBundle hb, bool showHash);
  void afterLastFile(HashBundle hb);
}

/// CHashOptions.
class HashOptions {
  List<String> methods = [];
  bool preserveATime = false;
  bool openShareForWrite = false;
  bool stdInMode = false;
  bool altStreamsMode = false;
  BoolPair2 symLinks = BoolPair2();
  CensorPathMode pathMode = CensorPathMode.relatPath;
}

/// HashCalc: [errorInfo] gets a message for scanning errors. Throws
/// [SystemException] for fatal errors.
void hashCalc(Censor censor, HashOptions options, List<String> errorInfo,
    HashCallbackUI callback, InStream? stdinData) {
  final dirItems = DirItems()..callback = callback;

  if (options.stdInMode) {
    dirItems.items.add(DirItem.empty()..setAsStdInFile(gIo.statStdin?.call()));
  } else {
    callback.startScanning();
    dirItems.symLinks = options.symLinks.val;
    dirItems.scanAltStreams = options.altStreamsMode;
    dirItems.excludeDirItems = censor.excludeDirItems;
    dirItems.excludeFileItems = censor.excludeFileItems;
    dirItems.shareForWrite = options.openShareForWrite;
    try {
      enumerateItems(censor, options.pathMode, '', dirItems);
    } on SystemException catch (e) {
      if (e.errorCode != HRes.eAbort) errorInfo.add('Scanning error');
      rethrow;
    }
    callback.finishScanning(dirItems.stat);
  }

  final hb = HashBundle()..setMethods(options.methods);
  hb.numErrors = dirItems.stat.numErrors;

  var totalSize = 0;
  if (options.stdInMode) {
    callback.setNumFiles(1);
  } else {
    totalSize = dirItems.stat.getTotalBytes();
    callback.setTotal(totalSize);
  }

  const kBufSize = 1 << 15;
  final buf = Uint8List(kBufSize);
  var completeValue = 0;

  callback.beforeFirstFile(hb);

  for (var i = 0; i < dirItems.items.length; i++) {
    InStream? inStream;
    FileInStream? fileStream;
    var path = '';
    var isDir = false;
    const isAltStream = false;

    if (options.stdInMode) {
      inStream = stdinData;
    } else {
      path = dirItems.getLogPath(i);
      final di = dirItems.items[i];
      final rd = di.reparseData;
      if (rd != null && rd.isNotEmpty) {
        inStream = MemoryInStream(rd);
      } else {
        isDir = di.isDir();
        if (!isDir) {
          final phyPath = dirItems.getPhyPath(i);
          try {
            fileStream = FileInStream.open(resolvePath(phyPath));
            inStream = fileStream;
          } on FileSystemException catch (e) {
            hb.numErrors++;
            callback.openFileError(phyPath, errnoOf(e));
            continue;
          }
          final curSize = fileStream.length;
          if (curSize > di.size) {
            totalSize += curSize - di.size;
            callback.setTotal(totalSize);
          }
        }
      }
    }

    try {
      callback.getStream(path, isDir);
      var fileSize = 0;
      hb.initForNewFile();
      if (!isDir && inStream != null) {
        for (var step = 0;; step++) {
          if ((step & 0xFF) == 0) callback.setCompleted(completeValue);
          int size;
          try {
            size = inStream.read(buf, 0, kBufSize);
          } on FileSystemException catch (e) {
            throw SystemException(hresultOfFileSystemException(e));
          }
          if (size == 0) break;
          hb.update(buf, 0, size);
          fileSize += size;
          completeValue += size;
        }
      }
      hb.finalItem(isDir, isAltStream, path);
      callback.setOperationResult(fileSize, hb, !isDir);
      callback.setCompleted(completeValue);
    } finally {
      fileStream?.close();
    }
  }
  callback.afterLastFile(hb);
}
