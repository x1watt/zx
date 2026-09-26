// 7z format constants and item structures: 7zHeader.h, 7zHeader.cpp and
// 7zItem.h of the LZMA SDK (CPP/7zip/Archive/7z).

import 'dart:typed_data';

import '../../codec/codec.dart';

/// kSignature (7zHeader.cpp).
final Uint8List kSignature =
    Uint8List.fromList(const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]);
const int kSignatureSize = 6;
const int kMajorVersion = 0;
const int kStartHeaderSize = 20;

/// kHeaderSize (7zIn.h): signature, version, start header CRC and start
/// header.
const int kHeaderSize = 32;

/// k_StartHeadersRewriteSize (7zOut.h).
const int kStartHeadersRewriteSize = 32;

/// NID::EEnum (7zHeader.h).
abstract final class NID {
  static const kEnd = 0;
  static const kHeader = 1;
  static const kArchiveProperties = 2;
  static const kAdditionalStreamsInfo = 3;
  static const kMainStreamsInfo = 4;
  static const kFilesInfo = 5;
  static const kPackInfo = 6;
  static const kUnpackInfo = 7;
  static const kSubStreamsInfo = 8;
  static const kSize = 9;
  static const kCRC = 10;
  static const kFolder = 11;
  static const kCodersUnpackSize = 12;
  static const kNumUnpackStream = 13;
  static const kEmptyStream = 14;
  static const kEmptyFile = 15;
  static const kAnti = 16;
  static const kName = 17;
  static const kCTime = 18;
  static const kATime = 19;
  static const kMTime = 20;
  static const kWinAttrib = 21;
  static const kComment = 22;
  static const kEncodedHeader = 23;
  static const kStartPos = 24;
  static const kDummy = 25;
}

// IsFilterMethod (7zHeader.h)
bool isFilterMethod(int m) {
  if (m > 0xFFFFFFFF || m < 0) return false;
  switch (m) {
    case MethodId.delta:
    case MethodId.arm64:
    case MethodId.riscv:
    case MethodId.bcj:
    case MethodId.bcj2:
    case MethodId.ppc:
    case MethodId.ia64:
    case MethodId.arm:
    case MethodId.armt:
    case MethodId.sparc:
    case MethodId.swap2:
    case MethodId.swap4:
      return true;
  }
  return false;
}

/// CNum limits (7zItem.h).
const int kNumMax = 0x7FFFFFFF;
const int kNumNoIndex = 0xFFFFFFFF;

/// CCoderInfo (7zItem.h).
class CoderInfo {
  int methodId = 0;
  Uint8List props = Uint8List(0);
  int numStreams = 1;

  // IsSimpleCoder
  bool get isSimpleCoder => numStreams == 1;
}

/// CBond (7zItem.h). [packIndex] is an input stream index of the folder
/// (decoder side), [unpackIndex] the coder whose output feeds it.
class Bond {
  int packIndex;
  int unpackIndex;
  Bond(this.packIndex, this.unpackIndex);
}

/// CFolder (7zItem.h).
class Folder {
  List<CoderInfo> coders = [];
  List<Bond> bonds = [];
  List<int> packStreams = [];

  // IsDecodingSupported
  bool get isDecodingSupported => coders.length <= 32;

  // Find_in_PackStreams
  int findInPackStreams(int packStream) {
    for (var i = 0; i < packStreams.length; i++) {
      if (packStreams[i] == packStream) return i;
    }
    return -1;
  }

  // FindBond_for_PackStream
  int findBondForPackStream(int packStream) {
    for (var i = 0; i < bonds.length; i++) {
      if (bonds[i].packIndex == packStream) return i;
    }
    return -1;
  }

  // IsEncrypted
  bool get isEncrypted {
    for (final c in coders) {
      if (c.methodId == MethodId.aes) return true;
    }
    return false;
  }
}

/// CFolderEx (7zIn.h): a folder with the index of its main (unpack) coder.
class FolderEx extends Folder {
  int unpackCoder = 0;
}

/// CUInt32DefVector (7zItem.h).
class UInt32DefVector {
  List<bool> defs = [];
  List<int> vals = [];

  void clearAndSetSize(int n) {
    defs = List<bool>.filled(n, false);
    vals = List<int>.filled(n, 0);
  }

  void clear() {
    defs = [];
    vals = [];
  }

  // GetItem: returns null when not defined.
  int? getItem(int index) =>
      (index < defs.length && defs[index]) ? vals[index] : null;

  // ValidAndDefined
  bool validAndDefined(int i) => i < defs.length && defs[i];

  // CheckSize
  bool checkSize(int size) => defs.length == size || defs.isEmpty;

  // SetItem (7zOut.cpp)
  void setItem(int index, bool defined, int value) {
    while (index >= defs.length) {
      defs.add(false);
    }
    defs[index] = defined;
    if (!defined) return;
    while (index >= vals.length) {
      vals.add(0);
    }
    vals[index] = value;
  }

  // if_NonEmpty_FillResidue_with_false
  void ifNonEmptyFillResidueWithFalse(int numItems) {
    if (defs.isNotEmpty && defs.length < numItems) {
      setItem(numItems - 1, false, 0);
    }
  }
}

/// CUInt64DefVector (7zItem.h).
class UInt64DefVector {
  List<bool> defs = [];
  List<int> vals = [];

  void clear() {
    defs = [];
    vals = [];
  }

  // GetItem: returns null when not defined.
  int? getItem(int index) =>
      (index < defs.length && defs[index]) ? vals[index] : null;

  bool checkSize(int size) => defs.length == size || defs.isEmpty;

  // SetItem (7zOut.cpp)
  void setItem(int index, bool defined, int value) {
    while (index >= defs.length) {
      defs.add(false);
    }
    defs[index] = defined;
    if (!defined) return;
    while (index >= vals.length) {
      vals.add(0);
    }
    vals[index] = value;
  }
}

/// CFileItem (7zItem.h).
class FileItem {
  int size = 0;
  int crc = 0;

  /// There is a stream for this file in some folder.
  bool hasStream = true;
  bool isDir = false;
  bool crcDefined = false;

  FileItem();

  FileItem copy() => FileItem()
    ..size = size
    ..crc = crc
    ..hasStream = hasStream
    ..isDir = isDir
    ..crcDefined = crcDefined;
}

// BoolVector_CountSum (7zIn.cpp)
int boolVectorCountSum(List<bool> v) {
  var sum = 0;
  for (final b in v) {
    if (b) sum++;
  }
  return sum;
}
