// Archive interface types: the parts of PropID.h and Archive/IArchive.h of
// the LZMA SDK that the archive handlers (7z, xz, lzma, split) implement
// (IInArchive, IOutArchive and their callbacks), as Dart interfaces.
//
// Property values are plain Dart objects: int (VT_UI4, VT_UI8 and VT_FILETIME,
// the latter as 100 ns ticks since 1601), String (VT_BSTR), bool (VT_BOOL),
// null (VT_EMPTY).

import '../io/streams.dart';

/// PROPID values (PropID.h).
abstract final class Kpid {
  static const noProperty = 0;
  static const mainSubfile = 1;
  static const handlerItemIndex = 2;
  static const path = 3;
  static const name = 4;
  static const extension = 5;
  static const isDir = 6;
  static const size = 7;
  static const packSize = 8;
  static const attrib = 9;
  static const cTime = 10;
  static const aTime = 11;
  static const mTime = 12;
  static const solid = 13;
  static const commented = 14;
  static const encrypted = 15;
  static const splitBefore = 16;
  static const splitAfter = 17;
  static const dictionarySize = 18;
  static const crc = 19;
  static const type = 20;
  static const isAnti = 21;
  static const method = 22;
  static const hostOS = 23;
  static const fileSystem = 24;
  static const user = 25;
  static const group = 26;
  static const block = 27;
  static const comment = 28;
  static const position = 29;
  static const prefix = 30;
  static const numSubDirs = 31;
  static const numSubFiles = 32;
  static const unpackVer = 33;
  static const volume = 34;
  static const isVolume = 35;
  static const offset = 36;
  static const links = 37;
  static const numBlocks = 38;
  static const numVolumes = 39;
  static const timeType = 40;
  static const bit64 = 41;
  static const bigEndian = 42;
  static const cpu = 43;
  static const phySize = 44;
  static const headersSize = 45;
  static const checksum = 46;
  static const characts = 47;
  static const va = 48;
  static const id = 49;
  static const shortName = 50;
  static const creatorApp = 51;
  static const sectorSize = 52;
  static const posixAttrib = 53;
  static const symLink = 54;
  static const error = 55;
  static const totalSize = 56;
  static const freeSpace = 57;
  static const clusterSize = 58;
  static const volumeName = 59;
  static const localName = 60;
  static const provider = 61;
  static const ntSecure = 62;
  static const isAltStream = 63;
  static const isAux = 64;
  static const isDeleted = 65;
  static const isTree = 66;
  static const sha1 = 67;
  static const sha256 = 68;
  static const errorType = 69;
  static const numErrors = 70;
  static const errorFlags = 71;
  static const warningFlags = 72;
  static const warning = 73;
  static const numStreams = 74;
  static const numAltStreams = 75;
  static const altStreamsSize = 76;
  static const virtualSize = 77;
  static const unpackSize = 78;
  static const totalPhySize = 79;
  static const volumeIndex = 80;
  static const subType = 81;
  static const shortComment = 82;
  static const codePage = 83;
  static const isNotArcType = 84;
  static const phySizeCantBeDetected = 85;
  static const zerosTailIsAllowed = 86;
  static const tailSize = 87;
  static const embeddedStubSize = 88;
  static const ntReparse = 89;
  static const hardLink = 90;
  static const iNode = 91;
  static const streamId = 92;
  static const readOnly = 93;
  static const outName = 94;
  static const copyLink = 95;
  static const arcFileName = 96;
  static const isHash = 97;
  static const changeTime = 98;
  static const userId = 99;
  static const groupId = 100;
  static const deviceMajor = 101;
  static const deviceMinor = 102;
  static const devMajor = 103;
  static const devMinor = 104;
  static const userDefined = 0x10000;
}

/// kpv_ErrorFlags_* (PropID.h).
abstract final class ErrorFlags {
  static const isNotArc = 1 << 0;
  static const headersError = 1 << 1;
  static const encryptedHeadersError = 1 << 2;
  static const unavailableStart = 1 << 3;
  static const unconfirmedStart = 1 << 4;
  static const unexpectedEnd = 1 << 5;
  static const dataAfterEnd = 1 << 6;
  static const unsupportedMethod = 1 << 7;
  static const unsupportedFeature = 1 << 8;
  static const dataError = 1 << 9;
  static const crcError = 1 << 10;
}

/// NArchive::NExtract::NAskMode.
abstract final class AskMode {
  static const extract = 0;
  static const test = 1;
  static const skip = 2;
  static const readExternal = 3;
}

/// NArchive::NExtract::NOperationResult.
abstract final class OperationResult {
  static const ok = 0;
  static const unsupportedMethod = 1;
  static const dataError = 2;
  static const crcError = 3;
  static const unavailable = 4;
  static const unexpectedEnd = 5;
  static const dataAfterEnd = 6;
  static const isNotArc = 7;
  static const headersError = 8;
  static const wrongPassword = 9;
}

/// NEventIndexType.
abstract final class EventIndexType {
  static const noIndex = 0;
  static const inArcIndex = 1;
  static const blockIndex = 2;
  static const outArcIndex = 3;
}

/// NUpdateNotifyOp.
abstract final class UpdateNotifyOp {
  static const add = 0;
  static const update = 1;
  static const analyze = 2;
  static const replicate = 3;
  static const repack = 4;
  static const skip = 5;
  static const delete = 6;
  static const header = 7;
  static const hashRead = 8;
  static const inFileChanged = 9;
}

/// NFileTimeType.
abstract final class FileTimeType {
  static const notDefined = -1;
  static const windows = 0;
  static const unix = 1;
  static const dos = 2;
  static const unix1ns = 3;
}

/// FILE_ATTRIBUTE_* values used by the handlers.
abstract final class FileAttrib {
  static const readOnly = 0x1;
  static const hidden = 0x2;
  static const system = 0x4;
  static const directory = 0x10;
  static const archive = 0x20;

  /// 7-Zip stores the POSIX st_mode in the high 16 bits and sets this flag.
  static const unixExtension = 0x8000;
}

/// IProgress.
abstract class ArchiveProgress {
  void setTotal(int total) {}
  void setCompleted(int completeValue) {}
}

/// IArchiveExtractCallback.
abstract class ArchiveExtractCallback extends ArchiveProgress {
  /// The output for item [index], or null to skip writing it (the data is
  /// still checked). [askMode] is an [AskMode] value.
  OutStream? getStream(int index, int askMode);

  void prepareOperation(int askMode) {}

  /// [opRes] is an [OperationResult] value for the item opened last.
  void setOperationResult(int opRes);
}

/// ICryptoGetTextPassword, for extract and update callbacks. Throw to abort.
abstract interface class CryptoGetTextPassword {
  String cryptoGetTextPassword();
}

/// ICryptoGetTextPassword2 (update callbacks): the password for new data,
/// or null when the archive is not to be encrypted.
abstract interface class CryptoGetTextPassword2 {
  String? cryptoGetTextPassword2();
}

/// IArchiveExtractCallbackMessage2.
abstract interface class ArchiveExtractCallbackMessage2 {
  void reportExtractResult(int indexType, int index, int opRes);
}

/// IArchiveUpdateCallback::GetUpdateItemInfo result.
class UpdateItemInfo {
  final bool newData;
  final bool newProps;

  /// Index of the item in the old archive, or -1.
  final int indexInArchive;
  const UpdateItemInfo(this.newData, this.newProps, this.indexInArchive);
}

/// IArchiveUpdateCallback.
abstract class ArchiveUpdateCallback extends ArchiveProgress {
  UpdateItemInfo getUpdateItemInfo(int index);

  /// Properties of new item [index] by [Kpid]: path (String), isDir (bool),
  /// isAnti (bool), size (int), attrib (int), cTime / aTime / mTime (int
  /// FILETIME). null means VT_EMPTY.
  Object? getProperty(int index, int propId);

  /// The data of item [index], or null when the file can not be opened
  /// (S_FALSE: the item is left out of the archive).
  InStream? getStream(int index);

  /// NUpdate::NOperationResult for the stream returned last.
  void setOperationResult(int opRes) {}
}

/// IArchiveUpdateCallbackFile: optional extras of update callbacks.
abstract interface class ArchiveUpdateCallbackFile {
  /// GetStream2 with [notifyOp] (UpdateNotifyOp.analyze for the filter
  /// analysis). null when the stream is not available.
  InStream? getStream2(int index, int notifyOp);

  /// ReportOperation.
  void reportOperation(int indexType, int index, int notifyOp);
}

/// IStreamGetProps: an input stream from an update callback may implement
/// it to give the file properties read when the file was opened.
abstract interface class StreamGetProps {
  int? get size;
  int? get cTime;
  int? get aTime;
  int? get mTime;
  int? get attrib;
}

/// IStreamGetSize: an input stream from an update callback may implement
/// it to give the size of the file (BCJ2 uses it to find file boundaries
/// in solid blocks).
abstract interface class StreamGetSize {
  int? get streamSize;
}

/// A stream from a callback that holds a resource (an open file). The
/// handler calls [release] when it is done with the stream, where 7-Zip
/// releases its COM reference.
abstract interface class ReleasableStream {
  void release();
}

/// Releases [s] if it holds a resource ([ReleasableStream] or an open
/// [FileInStream]).
void releaseStream(InStream? s) {
  if (s is ReleasableStream) {
    (s as ReleasableStream).release();
  } else if (s is FileInStream) {
    s.close();
  }
}
