// Reading of 7z archive headers: 7zIn.h and 7zIn.cpp of the LZMA SDK.

import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import 'decode.dart';
import 'header.dart';

const int _kScanNumCodersMax = 64;
const int _kScanNumCodersStreamsInFolderMax = 64;

/// CInArchiveException: corrupt headers.
class InArchiveException implements Exception {
  const InArchiveException();
}

/// CUnsupportedFeatureException.
class UnsupportedFeatureException extends InArchiveException {
  const UnsupportedFeatureException();
}

Never _throwIncorrect() => throw const InArchiveException();
Never _throwEndOfData() => throw const InArchiveException();
Never _throwUnsupported() => throw const UnsupportedFeatureException();

/// CParsedMethods (7zIn.h).
class ParsedMethods {
  int lzma2Prop = 0;
  int lzmaDic = 0;
  final List<int> ids = [];

  // CRecordVector::AddToUniqueSorted
  void addId(int id) {
    var lo = 0, hi = ids.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final v = ids[mid];
      if (v == id) return;
      if (_ucmp(id, v) < 0) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    ids.insert(lo, id);
  }
}

// Unsigned 64-bit compare.
int _ucmp(int a, int b) {
  if (a == b) return 0;
  final x = a ^ 0x8000000000000000;
  final y = b ^ 0x8000000000000000;
  return x < y ? -1 : 1;
}

/// CFolders (7zIn.h).
class Folders {
  int numPackStreams = 0;
  int numFolders = 0;

  /// numPackStreams + 1 entries.
  List<int> packPositions = const [];
  bool packPositionsDefined = false;

  final UInt32DefVector folderCRCs = UInt32DefVector();
  List<int> numUnpackStreamsVector = const [];

  /// Unpack sizes of all coders, including bond coders.
  List<int> coderUnpackSizes = const [];
  List<int> foToCoderUnpackSizes = const []; // numFolders + 1
  List<int> foStartPackStreamIndex = const []; // numFolders + 1
  List<int> foToMainUnpackSizeIndex = const []; // numFolders
  List<int> foCodersDataOffset = const []; // numFolders + 1
  Uint8List codersData = Uint8List(0);

  final ParsedMethods parsedMethods = ParsedMethods();

  // ParseFolderInfo
  void parseFolderInfo(int folderIndex, Folder folder) {
    final startPos = foCodersDataOffset[folderIndex];
    final inByte = InByte2();
    inByte.init(codersData, startPos, foCodersDataOffset[folderIndex + 1]);
    inByte.parseFolder(folder);
    if (inByte.rem != 0) throw const InArchiveException();
  }

  // ParseFolderEx
  FolderEx parseFolderEx(int folderIndex) {
    final f = FolderEx();
    parseFolderInfo(folderIndex, f);
    f.unpackCoder = foToMainUnpackSizeIndex[folderIndex];
    return f;
  }

  // GetNumFolderUnpackSizes
  int getNumFolderUnpackSizes(int folderIndex) =>
      foToCoderUnpackSizes[folderIndex + 1] - foToCoderUnpackSizes[folderIndex];

  // GetFolderUnpackSize
  int getFolderUnpackSize(int folderIndex) => coderUnpackSizes[
      foToCoderUnpackSizes[folderIndex] + foToMainUnpackSizeIndex[folderIndex]];

  // GetStreamPackSize
  int getStreamPackSize(int index) =>
      packPositions[index + 1] - packPositions[index];
}

/// CDatabase (7zIn.h).
class Database extends Folders {
  List<FileItem> files = [];
  final UInt64DefVector cTime = UInt64DefVector();
  final UInt64DefVector aTime = UInt64DefVector();
  final UInt64DefVector mTime = UInt64DefVector();
  final UInt64DefVector startPos = UInt64DefVector();
  final UInt32DefVector attrib = UInt32DefVector();
  List<bool> isAnti = [];

  Uint8List? namesBuf;

  /// numFiles + 1 offsets in UTF-16 units.
  List<int>? nameOffsets;

  // IsSolid
  bool get isSolid {
    for (var i = 0; i < numFolders; i++) {
      if (numUnpackStreamsVector[i] > 1) return true;
    }
    return false;
  }

  // IsItemAnti
  bool isItemAnti(int index) => index < isAnti.length && isAnti[index];

  // GetPath: the stored name (UTF-16), '/' separated as 7-Zip writes it.
  String getPath(int index) {
    final nb = namesBuf;
    final no = nameOffsets;
    if (nb == null || no == null) return '';
    final offset = no[index];
    final size = no[index + 1] - offset;
    if (size >= (1 << 28) || size <= 0) return '';
    final units = Uint16List(size - 1);
    var p = offset * 2;
    for (var i = 0; i < size - 1; i++) {
      units[i] = nb[p] | (nb[p + 1] << 8);
      p += 2;
    }
    return String.fromCharCodes(units);
  }
}

/// CInArchiveInfo (7zIn.h).
class InArchiveInfo {
  int versionMajor = 0;
  int versionMinor = 0;
  int startPosition = 0;
  int startPositionAfterHeader = 0;
  int dataStartPosition = 0;
  int dataStartPosition2 = 0;
  final List<int> fileInfoPopIDs = [];
}

/// CDbEx (7zIn.h).
class DbEx extends Database {
  final InArchiveInfo arcInfo = InArchiveInfo();
  List<int> folderStartFileIndex = const [];
  List<int> fileIndexToFolderIndexMap = const [];

  int headersSize = 0;
  int phySize = 0;

  bool isArc = false;
  bool phySizeWasConfirmed = false;
  bool thereIsHeaderError = false;
  bool unexpectedEnd = false;
  bool startHeaderWasRecovered = false;
  bool unsupportedFeatureWarning = false;
  bool unsupportedFeatureError = false;

  // CanUpdate
  bool get canUpdate => !(thereIsHeaderError ||
      unexpectedEnd ||
      startHeaderWasRecovered ||
      unsupportedFeatureError);

  // FillLinks
  void fillLinks() {
    folderStartFileIndex = List<int>.filled(numFolders, 0);
    fileIndexToFolderIndexMap = List<int>.filled(files.length, 0);
    var folderIndex = 0;
    var indexInFolder = 0;
    var i = 0;
    for (i = 0; i < files.length; i++) {
      final emptyStream = !files[i].hasStream;
      if (indexInFolder == 0) {
        if (emptyStream) {
          fileIndexToFolderIndexMap[i] = kNumNoIndex;
          continue;
        }
        // v4.07: we skip empty folders
        for (;;) {
          if (folderIndex >= numFolders) _throwIncorrect();
          folderStartFileIndex[folderIndex] = i;
          if (numUnpackStreamsVector[folderIndex] != 0) break;
          folderIndex++;
        }
      }
      fileIndexToFolderIndexMap[i] = folderIndex;
      if (emptyStream) continue;
      if (++indexInFolder >= numUnpackStreamsVector[folderIndex]) {
        folderIndex++;
        indexInFolder = 0;
      }
    }
    if (indexInFolder != 0) {
      folderIndex++;
      thereIsHeaderError = true;
    }
    for (;;) {
      if (folderIndex >= numFolders) return;
      folderStartFileIndex[folderIndex] = i;
      if (numUnpackStreamsVector[folderIndex] != 0) thereIsHeaderError = true;
      folderIndex++;
    }
  }

  // GetFolderStreamPos
  int getFolderStreamPos(int folderIndex, int indexInFolder) =>
      arcInfo.dataStartPosition +
      packPositions[foStartPackStreamIndex[folderIndex] + indexInFolder];

  // GetFolderFullPackSize
  int getFolderFullPackSize(int folderIndex) =>
      packPositions[foStartPackStreamIndex[folderIndex + 1]] -
      packPositions[foStartPackStreamIndex[folderIndex]];

  // GetFolderPackStreamSize
  int getFolderPackStreamSize(int folderIndex, int streamIndex) {
    final i = foStartPackStreamIndex[folderIndex] + streamIndex;
    return packPositions[i + 1] - packPositions[i];
  }
}

// ReadNumberSpec: returns the value, [processed] gets the byte count (0 on
// error).
int _readNumberSpec(Uint8List p, int pos, int size, List<int> processed) {
  if (size == 0) {
    processed[0] = 0;
    return 0;
  }
  final b = p[pos++];
  size--;
  if ((b & 0x80) == 0) {
    processed[0] = 1;
    return b;
  }
  if (size == 0) {
    processed[0] = 0;
    return 0;
  }
  var value = p[pos++];
  size--;
  for (var i = 1; i < 8; i++) {
    final mask = 0x80 >> i;
    if ((b & mask) == 0) {
      final high = b & (mask - 1);
      value |= high << (i * 8);
      processed[0] = i + 1;
      return value;
    }
    if (size == 0) {
      processed[0] = 0;
      return 0;
    }
    value |= p[pos++] << (i * 8);
    size--;
  }
  processed[0] = 9;
  return value;
}

/// CInByte2 (7zIn.h): a bounded reader over a byte buffer.
class InByte2 {
  Uint8List _buffer = Uint8List(0);
  int _start = 0;
  int size = 0; // end offset in _buffer
  int pos = 0; // absolute offset in _buffer
  final List<int> _processed = [0];

  void init(Uint8List buffer, int start, int end) {
    _buffer = buffer;
    _start = start;
    size = end;
    pos = start;
  }

  Uint8List get buffer => _buffer;
  int get rem => size - pos;

  /// Offset from the start of this reader.
  int get relPos => pos - _start;

  // ReadByte
  int readByte() {
    if (pos >= size) _throwEndOfData();
    return _buffer[pos++];
  }

  // ReadBytes
  Uint8List readBytes(int n) {
    if (n > size - pos) _throwEndOfData();
    final r = Uint8List.fromList(Uint8List.sublistView(_buffer, pos, pos + n));
    pos += n;
    return r;
  }

  // SkipDataNoCheck
  void skipDataNoCheck(int n) => pos += n;

  // SkipData(size)
  void skipDataSize(int n) {
    if (n < 0 || n > size - pos) _throwEndOfData();
    pos += n;
  }

  // SkipData()
  void skipData() => skipDataSize(readNumber());

  // SkipRem
  void skipRem() => pos = size;

  // ReadNumber
  int readNumber() {
    final res = _readNumberSpec(_buffer, pos, size - pos, _processed);
    if (_processed[0] == 0) _throwEndOfData();
    pos += _processed[0];
    return res;
  }

  // ReadNum
  int readNum() {
    final value = readNumber();
    if (_ucmp(value, kNumMax) > 0) _throwUnsupported();
    return value;
  }

  // ReadUInt32
  int readUInt32() {
    if (pos + 4 > size) _throwEndOfData();
    final res = getUint32LE(_buffer, pos);
    pos += 4;
    return res;
  }

  // ReadUInt64
  int readUInt64() {
    if (pos + 8 > size) _throwEndOfData();
    final res = getUint64LE(_buffer, pos);
    pos += 8;
    return res;
  }

  // ParseFolder
  void parseFolder(Folder folder) {
    final numCoders = readNum();
    if (numCoders == 0 || numCoders > _kScanNumCodersMax) _throwUnsupported();
    folder.coders = List.generate(numCoders, (_) => CoderInfo());
    var numInStreams = 0;
    for (var i = 0; i < numCoders; i++) {
      final coder = folder.coders[i];
      final mainByte = readByte();
      if ((mainByte & 0xC0) != 0) _throwUnsupported();
      final idSize = mainByte & 0xF;
      if (idSize > 8 || idSize > rem) _throwUnsupported();
      var id = 0;
      for (var j = 0; j < idSize; j++) {
        id = (id << 8) | _buffer[pos + j];
      }
      skipDataNoCheck(idSize);
      coder.methodId = id;
      if ((mainByte & 0x10) != 0) {
        coder.numStreams = readNum();
        readNum(); // numOutStreams
      } else {
        coder.numStreams = 1;
      }
      if ((mainByte & 0x20) != 0) {
        final propsSize = readNum();
        coder.props = readBytes(propsSize);
      } else {
        coder.props = Uint8List(0);
      }
      numInStreams += coder.numStreams;
    }
    final numBonds = numCoders - 1;
    folder.bonds = [];
    for (var i = 0; i < numBonds; i++) {
      final packIndex = readNum();
      final unpackIndex = readNum();
      folder.bonds.add(Bond(packIndex, unpackIndex));
    }
    if (numInStreams < numBonds) _throwUnsupported();
    final numPackStreams = numInStreams - numBonds;
    folder.packStreams = List<int>.filled(numPackStreams, 0);
    if (numPackStreams == 1) {
      var i = 0;
      for (i = 0; i < numInStreams; i++) {
        if (folder.findBondForPackStream(i) < 0) {
          folder.packStreams[0] = i;
          break;
        }
      }
      if (i == numInStreams) _throwUnsupported();
    } else {
      for (var i = 0; i < numPackStreams; i++) {
        folder.packStreams[i] = readNum();
      }
    }
  }
}

/// Crypto state collected while decoding (Z7_7Z_DECODER_CRYPRO_VARS).
class DecoderCryptoVars {
  final PasswordProvider? getTextPassword;
  bool isEncrypted = false;
  bool passwordIsDefined = false;
  String? password;
  DecoderCryptoVars(this.getTextPassword);
}

const int _kNumBufLevelsMax = 4;

/// CInArchive (7zIn.h, 7zIn.cpp).
class InArchive {
  SeekableInStream? _stream;
  final List<InByte2> _inByteVector =
      List.generate(_kNumBufLevelsMax, (_) => InByte2());
  int _numInByteBufs = 0;
  late InByte2 _inByteBack;
  bool thereIsHeaderError = false;

  int _arhiveBeginStreamPosition = 0;
  int _fileEndPosition = 0;
  int _rangeLimit = 0;
  final Uint8List _header = Uint8List(kHeaderSize);
  int headersSize = 0;

  final CoderContext coderContext;

  InArchive({this.coderContext = const CoderContext()});

  // AddByteStream
  void _addByteStream(Uint8List buf, int start, int end) {
    if (_numInByteBufs == _kNumBufLevelsMax) _throwIncorrect();
    _inByteBack = _inByteVector[_numInByteBufs++];
    _inByteBack.init(buf, start, end);
  }

  // DeleteByteStream
  void _deleteByteStream(bool needUpdatePos) {
    _numInByteBufs--;
    if (_numInByteBufs > 0) {
      final removed = _inByteVector[_numInByteBufs];
      _inByteBack = _inByteVector[_numInByteBufs - 1];
      if (needUpdatePos) _inByteBack.pos += removed.relPos;
    }
  }

  int _readByte() => _inByteBack.readByte();
  int _readNumber() => _inByteBack.readNumber();
  int _readNum() => _inByteBack.readNum();
  int _readID() => _inByteBack.readNumber();
  int _readUInt32() => _inByteBack.readUInt32();
  int _readUInt64() => _inByteBack.readUInt64();
  void _skipData() => _inByteBack.skipData();

  // CStreamSwitch::Set(archive, data, size, needUpdatePos); returns a
  // remover to call in a finally block (CStreamSwitch::Remove).
  _StreamSwitch _switchTo(
      Uint8List data, int start, int end, bool needUpdatePos) {
    _addByteStream(data, start, end);
    return _StreamSwitch(this, needUpdatePos);
  }

  // CStreamSwitch::Set(archive, dataVector)
  _StreamSwitch? _switchToExternal(List<Uint8List>? dataVector) {
    final external = _readByte();
    if (external != 0) {
      if (dataVector == null) _throwIncorrect();
      final dataIndex = _readNum();
      if (dataIndex >= dataVector.length) _throwIncorrect();
      final d = dataVector[dataIndex];
      return _switchTo(d, 0, d.length, false);
    }
    return null;
  }

  static bool _isSignature(Uint8List p, int o) =>
      p[o + 2] == 0xBC &&
      p[o + 3] == 0xAF &&
      p[o + 5] == 0x1C &&
      p[o + 4] == 0x27 &&
      p[o + 1] == 0x7A &&
      p[o] == 0x37;

  // TestStartCrc
  static bool _testStartCrc(Uint8List p, int o) =>
      Crc32.of(p, o + 12, o + 32) == getUint32LE(p, o + 8);

  // TestSignature2 (with FORMAT_7Z_RECOVERY)
  static bool _testSignature2(Uint8List p) {
    if (!_isSignature(p, 0)) return false;
    if (_testStartCrc(p, 0)) return true;
    for (var i = 8; i < kHeaderSize; i++) {
      if (p[i] != 0) return false;
    }
    return p[6] != 0 || p[7] != 0;
  }

  // FindAndReadSignature: returns false if no archive was found.
  bool _findAndReadSignature(SeekableInStream stream, int? searchLimit) {
    if (readFully(stream, _header, 0, kHeaderSize) != kHeaderSize) {
      return false;
    }
    if (_testSignature2(_header)) return true;
    if (searchLimit != null && searchLimit == 0) return false;

    const kBufSize = (1 << 15) + kHeaderSize;
    final buf = Uint8List(kBufSize + kHeaderSize);
    buf.setRange(0, kHeaderSize, _header);
    var offset = 0;
    for (;;) {
      var readSize = offset == 0
          ? kBufSize - kHeaderSize - kHeaderSize
          : kBufSize - kHeaderSize;
      if (searchLimit != null) {
        final rem = searchLimit - offset;
        if (readSize > rem) readSize = rem;
        if (readSize <= 0) return false;
      }
      final processed = stream.read(buf, kHeaderSize, readSize);
      if (processed == 0) return false;
      // Every position p in [1, processed] has 32 bytes available.
      for (var p = 1; p <= processed; p++) {
        if (buf[p] == 0x37 && _isSignature(buf, p) && _testStartCrc(buf, p)) {
          _header.setRange(0, kHeaderSize, buf, p);
          _arhiveBeginStreamPosition += offset + p;
          stream.position = _arhiveBeginStreamPosition + kHeaderSize;
          return true;
        }
      }
      offset += processed;
      buf.setRange(0, kHeaderSize, buf, processed);
    }
  }

  /// Open. Returns false when the stream is not a 7z archive.
  bool open(SeekableInStream stream, {int? searchHeaderSizeLimit}) {
    headersSize = 0;
    close();
    _arhiveBeginStreamPosition = stream.position;
    _fileEndPosition = stream.length;
    if (!_findAndReadSignature(stream, searchHeaderSizeLimit)) return false;
    _stream = stream;
    return true;
  }

  // Close
  void close() {
    _numInByteBufs = 0;
    _stream = null;
    thereIsHeaderError = false;
  }

  // ReadArchiveProperties
  void _readArchiveProperties(InArchiveInfo archiveInfo) {
    for (;;) {
      if (_readID() == NID.kEnd) break;
      _skipData();
    }
  }

  // WaitId
  void _waitId(int id) {
    for (;;) {
      final type = _readID();
      if (type == id) return;
      if (type == NID.kEnd) _throwIncorrect();
      _skipData();
    }
  }

  // Read_UInt32_Vector
  void _readUInt32Vector(UInt32DefVector v) {
    final numItems = v.defs.length;
    v.vals = List<int>.filled(numItems, 0);
    for (var i = 0; i < numItems; i++) {
      if (v.defs[i]) v.vals[i] = _readUInt32();
    }
  }

  // ReadHashDigests
  void _readHashDigests(int numItems, UInt32DefVector crcs) {
    crcs.defs = _readBoolVector2(numItems);
    _readUInt32Vector(crcs);
  }

  // ReadPackInfo
  void _readPackInfo(Folders f) {
    final numPackStreams = _readNum();
    _waitId(NID.kSize);
    final pp = List<int>.filled(numPackStreams + 1, 0);
    f.numPackStreams = numPackStreams;
    var sum = 0;
    for (var i = 0; i < numPackStreams; i++) {
      pp[i] = sum;
      final packSize = _readNumber();
      sum += packSize;
      if (_ucmp(sum, packSize) < 0) _throwIncorrect();
    }
    pp[numPackStreams] = sum;
    f.packPositions = pp;
    f.packPositionsDefined = true;
    for (;;) {
      final type = _readID();
      if (type == NID.kEnd) return;
      if (type == NID.kCRC) {
        final packCRCs = UInt32DefVector();
        _readHashDigests(numPackStreams, packCRCs);
        continue;
      }
      _skipData();
    }
  }

  // ReadUnpackInfo
  void _readUnpackInfo(List<Uint8List>? dataVector, Folders folders) {
    _waitId(NID.kFolder);
    final numFolders = _readNum();
    var numCodersOutStreams = 0;
    {
      final sw = _switchToExternal(dataVector);
      try {
        final inByte = _inByteBack;
        final startBufPtr = inByte.pos;
        folders.numFolders = numFolders;
        folders.foStartPackStreamIndex = List<int>.filled(numFolders + 1, 0);
        folders.foToMainUnpackSizeIndex = List<int>.filled(numFolders, 0);
        folders.foCodersDataOffset = List<int>.filled(numFolders + 1, 0);
        folders.foToCoderUnpackSizes = List<int>.filled(numFolders + 1, 0);

        var packStreamIndex = 0;
        var fo = 0;
        final buf = inByte.buffer;
        for (fo = 0; fo < numFolders; fo++) {
          var indexOfMainStream = 0;
          var numPackStreams = 0;
          folders.foCodersDataOffset[fo] = inByte.pos - startBufPtr;
          var numInStreams = 0;
          final numCoders = inByte.readNum();
          if (numCoders == 0 || numCoders > _kScanNumCodersMax) {
            _throwUnsupported();
          }
          for (var ci = 0; ci < numCoders; ci++) {
            final mainByte = inByte.readByte();
            if ((mainByte & 0xC0) != 0) _throwUnsupported();
            final idSize = mainByte & 0xF;
            if (idSize > 8) _throwUnsupported();
            if (idSize > inByte.rem) _throwEndOfData();
            var id = 0;
            for (var j = 0; j < idSize; j++) {
              id = (id << 8) | buf[inByte.pos + j];
            }
            inByte.skipDataNoCheck(idSize);
            if (folders.parsedMethods.ids.length < 128) {
              folders.parsedMethods.addId(id);
            }
            var coderInStreams = 1;
            if ((mainByte & 0x10) != 0) {
              coderInStreams = inByte.readNum();
              if (coderInStreams > _kScanNumCodersStreamsInFolderMax) {
                _throwUnsupported();
              }
              if (inByte.readNum() != 1) _throwUnsupported();
            }
            numInStreams += coderInStreams;
            if (numInStreams > _kScanNumCodersStreamsInFolderMax) {
              _throwUnsupported();
            }
            if ((mainByte & 0x20) != 0) {
              final propsSize = inByte.readNum();
              if (propsSize > inByte.rem) _throwEndOfData();
              if (id == MethodId.lzma2 && propsSize == 1) {
                final v = buf[inByte.pos];
                if (folders.parsedMethods.lzma2Prop < v) {
                  folders.parsedMethods.lzma2Prop = v;
                }
              } else if (id == MethodId.lzma && propsSize == 5) {
                final dicSize = getUint32LE(buf, inByte.pos + 1);
                if (folders.parsedMethods.lzmaDic < dicSize) {
                  folders.parsedMethods.lzmaDic = dicSize;
                }
              }
              inByte.skipDataNoCheck(propsSize);
            }
          }

          if (numCoders == 1 && numInStreams == 1) {
            indexOfMainStream = 0;
            numPackStreams = 1;
          } else {
            final numBonds = numCoders - 1;
            if (numInStreams < numBonds) _throwUnsupported();
            final streamUsed = List<bool>.filled(numInStreams, false);
            final coderUsed = List<bool>.filled(numCoders, false);
            for (var i = 0; i < numBonds; i++) {
              var index = _readNum();
              if (index >= numInStreams || streamUsed[index]) {
                _throwUnsupported();
              }
              streamUsed[index] = true;
              index = _readNum();
              if (index >= numCoders || coderUsed[index]) _throwUnsupported();
              coderUsed[index] = true;
            }
            numPackStreams = numInStreams - numBonds;
            if (numPackStreams != 1) {
              for (var i = 0; i < numPackStreams; i++) {
                final index = inByte.readNum();
                if (index >= numInStreams || streamUsed[index]) {
                  _throwUnsupported();
                }
                streamUsed[index] = true;
              }
            }
            var i = 0;
            for (i = 0; i < numCoders; i++) {
              if (!coderUsed[i]) {
                indexOfMainStream = i;
                break;
              }
            }
            if (i == numCoders) _throwUnsupported();
          }

          folders.foToCoderUnpackSizes[fo] = numCodersOutStreams;
          numCodersOutStreams += numCoders;
          folders.foStartPackStreamIndex[fo] = packStreamIndex;
          if (numPackStreams > folders.numPackStreams - packStreamIndex) {
            _throwIncorrect();
          }
          packStreamIndex += numPackStreams;
          folders.foToMainUnpackSizeIndex[fo] = indexOfMainStream;
        }
        final dataSize = inByte.pos - startBufPtr;
        folders.foToCoderUnpackSizes[fo] = numCodersOutStreams;
        folders.foStartPackStreamIndex[fo] = packStreamIndex;
        folders.foCodersDataOffset[fo] = dataSize;
        folders.codersData = Uint8List.fromList(
            Uint8List.sublistView(buf, startBufPtr, startBufPtr + dataSize));
      } finally {
        sw?.remove();
      }
    }

    _waitId(NID.kCodersUnpackSize);
    final cus = List<int>.filled(numCodersOutStreams, 0);
    for (var i = 0; i < numCodersOutStreams; i++) {
      cus[i] = _readNumber();
    }
    folders.coderUnpackSizes = cus;

    for (;;) {
      final type = _readID();
      if (type == NID.kEnd) return;
      if (type == NID.kCRC) {
        _readHashDigests(numFolders, folders.folderCRCs);
        continue;
      }
      _skipData();
    }
  }

  // ReadSubStreamsInfo
  void _readSubStreamsInfo(
      Folders folders, List<int> unpackSizes, UInt32DefVector digests) {
    final nus = List<int>.filled(folders.numFolders, 1);
    folders.numUnpackStreamsVector = nus;
    int type;
    for (;;) {
      type = _readID();
      if (type == NID.kNumUnpackStream) {
        for (var i = 0; i < folders.numFolders; i++) {
          nus[i] = _readNum();
        }
        continue;
      }
      if (type == NID.kCRC || type == NID.kSize || type == NID.kEnd) break;
      _skipData();
    }

    if (type == NID.kSize) {
      for (var i = 0; i < folders.numFolders; i++) {
        final numSubstreams = nus[i];
        if (numSubstreams == 0) continue;
        var sum = 0;
        for (var j = 1; j < numSubstreams; j++) {
          final size = _readNumber();
          unpackSizes.add(size);
          sum += size;
          if (_ucmp(sum, size) < 0) _throwIncorrect();
        }
        final folderUnpackSize = folders.getFolderUnpackSize(i);
        if (_ucmp(folderUnpackSize, sum) < 0) _throwIncorrect();
        unpackSizes.add(folderUnpackSize - sum);
      }
      type = _readID();
    } else {
      for (var i = 0; i < folders.numFolders; i++) {
        final val = nus[i];
        if (val > 1) _throwIncorrect();
        if (val == 1) unpackSizes.add(folders.getFolderUnpackSize(i));
      }
    }

    var numDigests = 0;
    for (var i = 0; i < folders.numFolders; i++) {
      final numSubstreams = nus[i];
      if (numSubstreams != 1 || !folders.folderCRCs.validAndDefined(i)) {
        numDigests += numSubstreams;
      }
    }

    for (;;) {
      if (type == NID.kEnd) break;
      if (type == NID.kCRC) {
        final digests2 = _readBoolVector2(numDigests);
        digests.clearAndSetSize(unpackSizes.length);
        var k = 0;
        var k2 = 0;
        for (var i = 0; i < folders.numFolders; i++) {
          final numSubstreams = nus[i];
          if (numSubstreams == 1 && folders.folderCRCs.validAndDefined(i)) {
            digests.defs[k] = true;
            digests.vals[k] = folders.folderCRCs.vals[i];
            k++;
          } else {
            for (var j = 0; j < numSubstreams; j++) {
              final defined = digests2[k2++];
              digests.defs[k] = defined;
              var crc = 0;
              if (defined) crc = _readUInt32();
              digests.vals[k] = crc;
              k++;
            }
          }
        }
      } else {
        _skipData();
      }
      type = _readID();
    }

    if (digests.defs.length != unpackSizes.length) {
      digests.clearAndSetSize(unpackSizes.length);
      var k = 0;
      for (var i = 0; i < folders.numFolders; i++) {
        final numSubstreams = nus[i];
        if (numSubstreams == 1 && folders.folderCRCs.validAndDefined(i)) {
          digests.defs[k] = true;
          digests.vals[k] = folders.folderCRCs.vals[i];
          k++;
        } else {
          for (var j = 0; j < numSubstreams; j++) {
            digests.defs[k] = false;
            digests.vals[k] = 0;
            k++;
          }
        }
      }
    }
  }

  // ReadStreamsInfo; returns dataOffset.
  int _readStreamsInfo(List<Uint8List>? dataVector, int dataOffset,
      Folders folders, List<int> unpackSizes, UInt32DefVector digests) {
    var type = _readID();
    if (type == NID.kPackInfo) {
      dataOffset = _readNumber();
      if (_ucmp(dataOffset, _rangeLimit) > 0) _throwIncorrect();
      _readPackInfo(folders);
      if (_ucmp(folders.packPositions[folders.numPackStreams],
              _rangeLimit - dataOffset) >
          0) {
        _throwIncorrect();
      }
      type = _readID();
    }
    if (type == NID.kUnpackInfo) {
      _readUnpackInfo(dataVector, folders);
      type = _readID();
    }
    if (folders.numFolders != 0 && !folders.packPositionsDefined) {
      folders.packPositions = [0];
      folders.packPositionsDefined = true;
    }
    if (type == NID.kSubStreamsInfo) {
      _readSubStreamsInfo(folders, unpackSizes, digests);
      type = _readID();
    } else {
      folders.numUnpackStreamsVector = List<int>.filled(folders.numFolders, 1);
      for (var i = 0; i < folders.numFolders; i++) {
        unpackSizes.add(folders.getFolderUnpackSize(i));
      }
    }
    if (type != NID.kEnd) _throwIncorrect();
    return dataOffset;
  }

  // ReadBoolVector
  List<bool> _readBoolVector(int numItems) {
    final v = List<bool>.filled(numItems, false);
    var b = 0;
    var mask = 0;
    for (var i = 0; i < numItems; i++) {
      if (mask == 0) {
        b = _readByte();
        mask = 0x80;
      }
      v[i] = (b & mask) != 0;
      mask >>= 1;
    }
    return v;
  }

  // ReadBoolVector2
  List<bool> _readBoolVector2(int numItems) {
    final allAreDefined = _readByte();
    if (allAreDefined == 0) return _readBoolVector(numItems);
    return List<bool>.filled(numItems, true);
  }

  // ReadUInt64DefVector
  void _readUInt64DefVector(
      List<Uint8List> dataVector, UInt64DefVector v, int numItems) {
    v.defs = _readBoolVector2(numItems);
    final sw = _switchToExternal(dataVector);
    try {
      v.vals = List<int>.filled(numItems, 0);
      for (var i = 0; i < numItems; i++) {
        if (v.defs[i]) v.vals[i] = _readUInt64();
      }
    } finally {
      sw?.remove();
    }
  }

  // ReadAndDecodePackedStreams; returns the new dataOffset.
  int _readAndDecodePackedStreams(int baseOffset, int dataOffset,
      List<Uint8List> dataVector, DecoderCryptoVars crypto) {
    final folders = Folders();
    final unpackSizes = <int>[];
    final digests = UInt32DefVector();
    dataOffset =
        _readStreamsInfo(null, dataOffset, folders, unpackSizes, digests);

    final decoder = Decoder();
    for (var i = 0; i < folders.numFolders; i++) {
      final unpackSize = folders.getFolderUnpackSize(i);
      if (unpackSize < 0 || unpackSize > 0x7FFFFFFF) _throwUnsupported();
      final data = Uint8List(unpackSize);
      final s = decoder.decode(_stream!, baseOffset + dataOffset, folders, i,
          null, crypto, coderContext);
      final got = readFully(s, data, 0, unpackSize);
      if (got != unpackSize) _throwIncorrect();
      if (folders.folderCRCs.validAndDefined(i)) {
        if (Crc32.of(data) != folders.folderCRCs.vals[i]) _throwIncorrect();
      }
      dataVector.add(data);
    }
    if (folders.packPositionsDefined) {
      headersSize += folders.packPositions[folders.numPackStreams];
    }
    return dataOffset;
  }

  // ReadHeader
  void _readHeader(DbEx db, DecoderCryptoVars crypto) {
    var type = _readID();
    if (type == NID.kArchiveProperties) {
      _readArchiveProperties(db.arcInfo);
      type = _readID();
    }

    final dataVector = <Uint8List>[];
    if (type == NID.kAdditionalStreamsInfo) {
      db.arcInfo.dataStartPosition2 = _readAndDecodePackedStreams(
          db.arcInfo.startPositionAfterHeader,
          db.arcInfo.dataStartPosition2,
          dataVector,
          crypto);
      db.arcInfo.dataStartPosition2 += db.arcInfo.startPositionAfterHeader;
      type = _readID();
    }

    final unpackSizes = <int>[];
    final digests = UInt32DefVector();
    if (type == NID.kMainStreamsInfo) {
      db.arcInfo.dataStartPosition = _readStreamsInfo(
          dataVector, db.arcInfo.dataStartPosition, db, unpackSizes, digests);
      db.arcInfo.dataStartPosition += db.arcInfo.startPositionAfterHeader;
      type = _readID();
    }

    if (type == NID.kFilesInfo) {
      final numFiles = _readNum();
      db.arcInfo.fileInfoPopIDs.add(NID.kSize);
      db.arcInfo.fileInfoPopIDs.add(NID.kPackInfo);
      if (numFiles > 0 && digests.defs.isNotEmpty) {
        db.arcInfo.fileInfoPopIDs.add(NID.kCRC);
      }

      var emptyStreamVector = <bool>[];
      var emptyFileVector = <bool>[];
      var antiFileVector = <bool>[];
      var numEmptyStreams = 0;

      for (;;) {
        final type2 = _readID();
        if (type2 == NID.kEnd) break;
        final size = _readNumber();
        if (_ucmp(size, _inByteBack.rem) > 0) _throwIncorrect();
        final back = _inByteBack;
        final switchProp =
            _switchTo(back.buffer, back.pos, back.pos + size, true);
        try {
          var addPropIdToList = true;
          var isKnownType = true;
          if (_ucmp(type2, 1 << 30) > 0) {
            isKnownType = false;
          } else {
            switch (type2) {
              case NID.kName:
                final sw = _switchToExternal(dataVector);
                try {
                  final ib = _inByteBack;
                  final rem = ib.rem;
                  final nb = ib.readBytes(rem);
                  db.namesBuf = nb;
                  final no = List<int>.filled(numFiles + 1, 0);
                  var pos = 0;
                  var i = 0;
                  for (i = 0; i < numFiles; i++) {
                    final curRem = (rem - pos) ~/ 2;
                    var j = 0;
                    while (j < curRem &&
                        (nb[pos + j * 2] | nb[pos + j * 2 + 1]) != 0) {
                      j++;
                    }
                    if (j == curRem) _throwEndOfData();
                    no[i] = pos ~/ 2;
                    pos += j * 2 + 2;
                  }
                  no[i] = pos ~/ 2;
                  db.nameOffsets = no;
                  if (pos != rem) thereIsHeaderError = true;
                } finally {
                  sw?.remove();
                }
                break;
              case NID.kWinAttrib:
                db.attrib.defs = _readBoolVector2(numFiles);
                final sw = _switchToExternal(dataVector);
                try {
                  _readUInt32Vector(db.attrib);
                } finally {
                  sw?.remove();
                }
                break;
              case NID.kEmptyStream:
                emptyStreamVector = _readBoolVector(numFiles);
                numEmptyStreams = boolVectorCountSum(emptyStreamVector);
                emptyFileVector = [];
                antiFileVector = [];
                break;
              case NID.kEmptyFile:
                emptyFileVector = _readBoolVector(numEmptyStreams);
                break;
              case NID.kAnti:
                antiFileVector = _readBoolVector(numEmptyStreams);
                break;
              case NID.kStartPos:
                _readUInt64DefVector(dataVector, db.startPos, numFiles);
                break;
              case NID.kCTime:
                _readUInt64DefVector(dataVector, db.cTime, numFiles);
                break;
              case NID.kATime:
                _readUInt64DefVector(dataVector, db.aTime, numFiles);
                break;
              case NID.kMTime:
                _readUInt64DefVector(dataVector, db.mTime, numFiles);
                break;
              case NID.kDummy:
                for (var j = 0; j < size; j++) {
                  if (_readByte() != 0) thereIsHeaderError = true;
                }
                addPropIdToList = false;
                break;
              default:
                addPropIdToList = isKnownType = false;
            }
          }
          if (isKnownType) {
            if (addPropIdToList) db.arcInfo.fileInfoPopIDs.add(type2);
          } else {
            db.unsupportedFeatureWarning = true;
            _inByteBack.skipRem();
          }
          if (_inByteBack.rem != 0) _throwIncorrect();
        } finally {
          switchProp.remove();
        }
      }

      type = _readID(); // kEnd, end of headers

      if (numFiles - numEmptyStreams != unpackSizes.length) {
        _throwUnsupported();
      }

      var emptyFileIndex = 0;
      var sizeIndex = 0;
      final numAntiItems = boolVectorCountSum(antiFileVector);
      if (numAntiItems != 0) db.isAnti = List<bool>.filled(numFiles, false);
      db.files = List.generate(numFiles, (_) => FileItem());
      for (var i = 0; i < numFiles; i++) {
        final file = db.files[i];
        bool isAnti;
        file.crc = 0;
        if (!(i < emptyStreamVector.length && emptyStreamVector[i])) {
          file.hasStream = true;
          file.isDir = false;
          isAnti = false;
          file.size = unpackSizes[sizeIndex];
          file.crcDefined = digests.validAndDefined(sizeIndex);
          if (file.crcDefined) file.crc = digests.vals[sizeIndex];
          sizeIndex++;
        } else {
          file.hasStream = false;
          file.isDir = !(emptyFileIndex < emptyFileVector.length &&
              emptyFileVector[emptyFileIndex]);
          isAnti = emptyFileIndex < antiFileVector.length &&
              antiFileVector[emptyFileIndex];
          emptyFileIndex++;
          file.size = 0;
          file.crcDefined = false;
        }
        if (numAntiItems != 0) db.isAnti[i] = isAnti;
      }
    }

    db.fillLinks();

    if (type != NID.kEnd || _inByteBack.rem != 0) {
      db.unsupportedFeatureWarning = true;
    }
  }

  // ReadDatabase2: returns false for S_FALSE.
  bool _readDatabase2(DbEx db, DecoderCryptoVars crypto) {
    db.arcInfo.startPosition = _arhiveBeginStreamPosition;
    db.arcInfo.versionMajor = _header[6];
    db.arcInfo.versionMinor = _header[7];
    if (db.arcInfo.versionMajor != kMajorVersion) return false;

    var nextHeaderOffset = getUint64LE(_header, 12);
    var nextHeaderSize = getUint64LE(_header, 20);
    var nextHeaderCRC = getUint32LE(_header, 28);

    final stream = _stream!;
    // FORMAT_7Z_RECOVERY
    final crcFromArc = getUint32LE(_header, 8);
    if (crcFromArc == 0 &&
        nextHeaderOffset == 0 &&
        nextHeaderSize == 0 &&
        nextHeaderCRC == 0) {
      final cur = stream.position;
      const kCheckSize = 512;
      final fileSize = stream.length;
      final rem = fileSize - cur;
      var checkSize = kCheckSize;
      if (rem < kCheckSize) checkSize = rem;
      if (checkSize < 3) return false;
      final buf = Uint8List(checkSize);
      stream.position = fileSize - checkSize;
      if (readFully(stream, buf, 0, checkSize) != checkSize) return false;
      if (buf[checkSize - 1] != 0) return false;
      var i = checkSize - 2;
      for (;; i--) {
        if ((buf[i] == NID.kEncodedHeader && buf[i + 1] == NID.kPackInfo) ||
            (buf[i] == NID.kHeader && buf[i + 1] == NID.kMainStreamsInfo)) {
          break;
        }
        if (i == 0) return false;
      }
      nextHeaderSize = checkSize - i;
      nextHeaderOffset = rem - nextHeaderSize;
      nextHeaderCRC = Crc32.of(buf, i, i + nextHeaderSize);
      stream.position = cur;
      db.startHeaderWasRecovered = true;
    }

    db.arcInfo.startPositionAfterHeader =
        _arhiveBeginStreamPosition + kHeaderSize;
    db.phySize = kHeaderSize;
    db.isArc = false;
    if (nextHeaderOffset < 0 || _ucmp(nextHeaderSize, 1 << 62) > 0) {
      return false;
    }
    headersSize = kHeaderSize;
    if (nextHeaderSize == 0) {
      if (nextHeaderOffset != 0 || nextHeaderCRC != 0) return false;
      db.isArc = true;
      db.headersSize = headersSize;
      return true;
    }
    if (!db.startHeaderWasRecovered) db.isArc = true;
    headersSize += nextHeaderSize;
    _rangeLimit = nextHeaderOffset;
    db.phySize = kHeaderSize + nextHeaderOffset + nextHeaderSize;
    if (_fileEndPosition - db.arcInfo.startPositionAfterHeader <
        nextHeaderOffset + nextHeaderSize) {
      db.unexpectedEnd = true;
      return false;
    }
    stream.position = db.arcInfo.startPositionAfterHeader + nextHeaderOffset;
    if (nextHeaderSize > 0x7FFFFFFF) {
      throw const SevenZipException('Header too large', SevenZipError.headers);
    }
    final buffer2 = Uint8List(nextHeaderSize);
    if (readFully(stream, buffer2, 0, nextHeaderSize) != nextHeaderSize) {
      return false;
    }
    if (Crc32.of(buffer2) != nextHeaderCRC) _throwIncorrect();
    if (!db.startHeaderWasRecovered) db.phySizeWasConfirmed = true;

    var sw = _switchTo(buffer2, 0, buffer2.length, false);
    try {
      final dataVector = <Uint8List>[];
      final type = _readID();
      if (type != NID.kHeader) {
        if (type != NID.kEncodedHeader) _throwIncorrect();
        db.arcInfo.dataStartPosition2 = _readAndDecodePackedStreams(
            db.arcInfo.startPositionAfterHeader,
            db.arcInfo.dataStartPosition2,
            dataVector,
            crypto);
        if (dataVector.isEmpty) return true;
        if (dataVector.length > 1) _throwIncorrect();
        sw.remove();
        sw = _switchTo(dataVector[0], 0, dataVector[0].length, false);
        if (_readID() != NID.kHeader) _throwIncorrect();
      }
      db.isArc = true;
      db.headersSize = headersSize;
      _readHeader(db, crypto);
      return true;
    } finally {
      sw.remove();
    }
  }

  /// ReadDatabase. Returns false for S_FALSE (not an archive or broken
  /// headers, see the flags in [db]). Decoder errors of encoded headers
  /// (unsupported method, wrong password...) are thrown as
  /// [SevenZipException].
  bool readDatabase(DbEx db, DecoderCryptoVars crypto) {
    try {
      final res = _readDatabase2(db, crypto);
      if (thereIsHeaderError) db.thereIsHeaderError = true;
      return res;
    } on UnsupportedFeatureException {
      db.unsupportedFeatureError = true;
      return false;
    } on InArchiveException {
      db.thereIsHeaderError = true;
      return false;
    } on RangeError {
      db.thereIsHeaderError = true;
      return false;
    }
  }
}

/// CStreamSwitch.
class _StreamSwitch {
  final InArchive _archive;
  final bool _needUpdatePos;
  bool _needRemove = true;
  _StreamSwitch(this._archive, this._needUpdatePos);

  // Remove
  void remove() {
    if (_needRemove) {
      if (_archive._inByteBack.rem != 0) _archive.thereIsHeaderError = true;
      _archive._deleteByteStream(_needUpdatePos);
      _needRemove = false;
    }
  }
}
