// Writing of 7z archive headers: 7zOut.h and 7zOut.cpp of the LZMA SDK.
//
// 7-Zip writes the header twice when it is encoded (a counting pass to size
// the buffer, then the real pass). Here the header is built once in memory,
// which gives the same bytes: the alignment of SkipToAligned only depends
// on the position inside the header.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc.dart';
import 'compression_mode.dart';
import 'encode.dart';
import 'header.dart';

/// CHeaderOptions.
class HeaderOptions {
  bool compressMainHeader = true;
}

/// CFileItem2: the optional properties of a file.
class FileItem2 {
  int cTime = 0;
  int aTime = 0;
  int mTime = 0;
  int startPos = 0;
  int attrib = 0;
  bool cTimeDefined = false;
  bool aTimeDefined = false;
  bool mTimeDefined = false;
  bool startPosDefined = false;
  bool attribDefined = false;
  bool isAnti = false;
}

/// COutFolders.
class OutFolders {
  /// Used for headers only.
  final UInt32DefVector folderUnpackCRCs = UInt32DefVector();
  final List<int> numUnpackStreamsVector = [];

  /// Unpack sizes of all coders, including bond coders.
  final List<int> coderUnpackSizes = [];
}

/// CArchiveDatabaseOut.
class ArchiveDatabaseOut extends OutFolders {
  final List<int> packSizes = [];
  final UInt32DefVector packCRCs = UInt32DefVector();
  final List<Folder> folders = [];

  final List<FileItem> files = [];
  final List<String> names = [];
  final UInt64DefVector cTime = UInt64DefVector();
  final UInt64DefVector aTime = UInt64DefVector();
  final UInt64DefVector mTime = UInt64DefVector();
  final UInt64DefVector startPos = UInt64DefVector();
  final UInt32DefVector attrib = UInt32DefVector();
  final List<bool> isAnti = [];

  // IsEmpty
  bool get isEmpty =>
      packSizes.isEmpty &&
      numUnpackStreamsVector.isEmpty &&
      folders.isEmpty &&
      files.isEmpty;

  // CheckNumFiles
  bool checkNumFiles() {
    final size = files.length;
    return cTime.checkSize(size) &&
        aTime.checkSize(size) &&
        mTime.checkSize(size) &&
        startPos.checkSize(size) &&
        attrib.checkSize(size) &&
        (size == isAnti.length || isAnti.isEmpty);
  }

  // IsItemAnti
  bool isItemAnti(int index) => index < isAnti.length && isAnti[index];

  // SetItem_Anti
  void setItemAnti(int index, bool anti) {
    while (index >= isAnti.length) {
      isAnti.add(false);
    }
    isAnti[index] = anti;
  }

  // AddFile
  void addFile(FileItem file, FileItem2 file2, String name) {
    final index = files.length;
    cTime.setItem(index, file2.cTimeDefined, file2.cTime);
    aTime.setItem(index, file2.aTimeDefined, file2.aTime);
    mTime.setItem(index, file2.mTimeDefined, file2.mTime);
    startPos.setItem(index, file2.startPosDefined, file2.startPos);
    attrib.setItem(index, file2.attribDefined, file2.attrib);
    setItemAnti(index, file2.isAnti);
    names.add(name);
    files.add(file);
  }
}

// FillSignature
void _fillSignature(Uint8List buf) {
  buf.setRange(0, kSignatureSize, kSignature);
  buf[kSignatureSize] = kMajorVersion;
  buf[kSignatureSize + 1] = 4;
}

// GetBigNumberSize
int _getBigNumberSize(int value) {
  var i = 1;
  for (; i < 9; i++) {
    if (value >= 0 && value < (1 << (i * 7))) break;
  }
  return i;
}

// UInt64Vector_CountSum
int _uint64VectorCountSum(List<int> v) {
  var sum = 0;
  for (final x in v) {
    sum += x;
  }
  return sum;
}

/// COutArchive.
class OutArchive {
  SeekableOutStream? _stream;
  int _signatureHeaderPos = 0;

  /// The archive output (SeqStream).
  late OutStream seqStream;

  // Header being built.
  MemoryOutStream _out = MemoryOutStream();
  bool _useAlign = false;

  /// Create_and_WriteStartPrefix: writes the signature with an empty start
  /// header (rewritten by [writeDatabase]).
  void createAndWriteStartPrefix(SeekableOutStream stream) {
    seqStream = stream;
    _stream = stream;
    _signatureHeaderPos = stream.position;
    final buf = Uint8List(32);
    _fillSignature(buf);
    stream.write(buf, 0, 32);
  }

  // WriteStartHeader
  void _writeStartHeader(
      int nextHeaderOffset, int nextHeaderSize, int nextHeaderCRC) {
    final buf = Uint8List(32);
    _fillSignature(buf);
    setUint64LE(buf, 12, nextHeaderOffset);
    setUint64LE(buf, 20, nextHeaderSize);
    setUint32LE(buf, 28, nextHeaderCRC);
    setUint32LE(buf, 8, Crc32.of(buf, 12, 32));
    _stream!.write(buf, 0, 32);
  }

  int get _pos => _out.length;

  void _writeByte(int b) => _out.writeByte(b & 0xFF);

  void _writeBytes(Uint8List data) => _out.write(data, 0, data.length);

  // WriteNumber
  void _writeNumber(int value) {
    var firstByte = 0;
    var mask = 0x80;
    var i = 0;
    for (i = 0; i < 8; i++) {
      if (value >= 0 && value < (1 << (7 * (i + 1)))) {
        firstByte |= (value >> (8 * i)) & 0xFF;
        break;
      }
      firstByte |= mask;
      mask >>= 1;
    }
    _writeByte(firstByte);
    for (; i > 0; i--) {
      _writeByte(value);
      value >>= 8;
    }
  }

  void _writeID(int value) => _writeNumber(value);

  // WriteFolder
  void _writeFolder(Folder folder) {
    _writeNumber(folder.coders.length);
    for (final coder in folder.coders) {
      var id = coder.methodId;
      var idSize = 1;
      for (idSize = 1; idSize < 8; idSize++) {
        if ((id >> (8 * idSize)) == 0) break;
      }
      final temp = Uint8List(16);
      for (var t = idSize; t != 0; t--, id >>= 8) {
        temp[t] = id & 0xFF;
      }
      var b = idSize;
      final isComplex = !coder.isSimpleCoder;
      b |= isComplex ? 0x10 : 0;
      final propsSize = coder.props.length;
      b |= propsSize != 0 ? 0x20 : 0;
      temp[0] = b;
      _out.write(temp, 0, idSize + 1);
      if (isComplex) {
        _writeNumber(coder.numStreams);
        _writeNumber(1); // NumOutStreams
      }
      if (propsSize == 0) continue;
      _writeNumber(propsSize);
      _writeBytes(coder.props);
    }
    for (final bond in folder.bonds) {
      _writeNumber(bond.packIndex);
      _writeNumber(bond.unpackIndex);
    }
    if (folder.packStreams.length > 1) {
      for (final p in folder.packStreams) {
        _writeNumber(p);
      }
    }
  }

  // Write_BoolVector
  void _writeBoolVector(List<bool> v) {
    var b = 0;
    var mask = 0x80;
    for (final x in v) {
      if (x) b |= mask;
      mask >>= 1;
      if (mask == 0) {
        _writeByte(b);
        mask = 0x80;
        b = 0;
      }
    }
    if (mask != 0x80) _writeByte(b);
  }

  static int _bvGetSizeInBytes(List<bool> v) => (v.length + 7) ~/ 8;

  // WritePropBoolVector
  void _writePropBoolVector(int id, List<bool> v) {
    _writeByte(id);
    _writeNumber(_bvGetSizeInBytes(v));
    _writeBoolVector(v);
  }

  // Write_BoolVector_numDefined
  void _writeBoolVectorNumDefined(List<bool> v, int numDefined) {
    if (numDefined == v.length) {
      _writeByte(1);
    } else {
      _writeByte(0);
      _writeBoolVector(v);
    }
  }

  // WriteHashDigests
  void _writeHashDigests(UInt32DefVector digests) {
    final numDefined = boolVectorCountSum(digests.defs);
    if (numDefined == 0) return;
    _writeByte(NID.kCRC);
    _writeBoolVectorNumDefined(digests.defs, numDefined);
    _writeUInt32DefVectorNumDefined(digests, numDefined);
  }

  // WritePackInfo
  void _writePackInfo(
      int dataOffset, List<int> packSizes, UInt32DefVector packCRCs) {
    if (packSizes.isEmpty) return;
    _writeByte(NID.kPackInfo);
    _writeNumber(dataOffset);
    _writeNumber(packSizes.length);
    _writeByte(NID.kSize);
    for (final s in packSizes) {
      _writeNumber(s);
    }
    _writeHashDigests(packCRCs);
    _writeByte(NID.kEnd);
  }

  // WriteUnpackInfo
  void _writeUnpackInfo(List<Folder> folders, OutFolders outFolders) {
    if (folders.isEmpty) return;
    _writeByte(NID.kUnpackInfo);
    _writeByte(NID.kFolder);
    _writeNumber(folders.length);
    _writeByte(0);
    for (final f in folders) {
      _writeFolder(f);
    }
    _writeByte(NID.kCodersUnpackSize);
    for (final s in outFolders.coderUnpackSizes) {
      _writeNumber(s);
    }
    _writeHashDigests(outFolders.folderUnpackCRCs);
    _writeByte(NID.kEnd);
  }

  // WriteSubStreamsInfo
  void _writeSubStreamsInfo(List<Folder> folders, OutFolders outFolders,
      List<int> unpackSizes, UInt32DefVector digests) {
    final nus = outFolders.numUnpackStreamsVector;
    _writeByte(NID.kSubStreamsInfo);
    for (var i = 0; i < nus.length; i++) {
      if (nus[i] != 1) {
        _writeByte(NID.kNumUnpackStream);
        for (final n in nus) {
          _writeNumber(n);
        }
        break;
      }
    }
    for (var i = 0; i < nus.length; i++) {
      if (nus[i] > 1) {
        _writeByte(NID.kSize);
        var index = 0;
        for (final num in nus) {
          for (var j = 0; j < num; j++) {
            if (j + 1 != num) _writeNumber(unpackSizes[index]);
            index++;
          }
        }
        break;
      }
    }
    final digests2 = UInt32DefVector();
    var digestIndex = 0;
    for (var i = 0; i < folders.length; i++) {
      final numSubStreams = nus[i];
      if (numSubStreams == 1 &&
          outFolders.folderUnpackCRCs.validAndDefined(i)) {
        digestIndex++;
      } else {
        for (var j = 0; j < numSubStreams; j++, digestIndex++) {
          digests2.defs.add(digests.defs[digestIndex]);
          digests2.vals.add(digests.vals[digestIndex]);
        }
      }
    }
    _writeHashDigests(digests2);
    _writeByte(NID.kEnd);
  }

  // SkipToAligned
  void _skipToAligned(int pos, int alignShifts) {
    if (!_useAlign) return;
    final alignSize = 1 << alignShifts;
    pos += _pos;
    pos &= alignSize - 1;
    if (pos == 0) return;
    var skip = alignSize - pos;
    if (skip < 2) skip += alignSize;
    skip -= 2;
    _writeByte(NID.kDummy);
    _writeByte(skip);
    for (var i = 0; i < skip; i++) {
      _writeByte(0);
    }
  }

  // WriteAlignedBools
  void _writeAlignedBools(
      List<bool> v, int numDefined, int type, int itemSizeShifts) {
    final bvSize = (numDefined == v.length) ? 0 : _bvGetSizeInBytes(v);
    final dataSize = (numDefined << itemSizeShifts) + bvSize + 2;
    _skipToAligned(3 + bvSize + _getBigNumberSize(dataSize), itemSizeShifts);
    _writeByte(type);
    _writeNumber(dataSize);
    _writeBoolVectorNumDefined(v, numDefined);
    _writeByte(0); // 0 means no switching to external stream
  }

  // Write_UInt32DefVector_numDefined
  void _writeUInt32DefVectorNumDefined(UInt32DefVector v, int numDefined) {
    for (var i = 0; i < v.defs.length; i++) {
      if (v.defs[i]) {
        var value = v.vals[i];
        for (var k = 0; k < 4; k++) {
          _writeByte(value);
          value >>= 8;
        }
      }
    }
  }

  // Write_UInt64DefVector_type
  void _writeUInt64DefVectorType(UInt64DefVector v, int type) {
    final numDefined = boolVectorCountSum(v.defs);
    if (numDefined == 0) return;
    _writeAlignedBools(v.defs, numDefined, type, 3);
    for (var i = 0; i < v.defs.length; i++) {
      if (v.defs[i]) {
        var value = v.vals[i];
        for (var k = 0; k < 8; k++) {
          _writeByte(value);
          value >>= 8;
        }
      }
    }
  }

  // EncodeStream
  void _encodeStream(Encoder encoder, Uint8List data, List<int> packSizes,
      List<Folder> folders, OutFolders outFolders) {
    outFolders.folderUnpackCRCs.defs.add(true);
    outFolders.folderUnpackCRCs.vals.add(Crc32.of(data));
    final dataSize = data.length;
    final folder = Folder();
    folders.add(folder);
    final input = CountingInStream(MemoryInStream(data));
    encoder.encode1(input, dataSize, dataSize, folder, seqStream, packSizes);
    if (input.count != dataSize) {
      throw StateError('Header was not encoded completely');
    }
    encoder.encodePost(dataSize, outFolders.coderUnpackSizes);
  }

  // WriteHeader: returns headerOffset.
  int _writeHeader(ArchiveDatabaseOut db) {
    _useAlign = true;
    final headerOffset = _uint64VectorCountSum(db.packSizes);
    _writeByte(NID.kHeader);

    if (db.folders.isNotEmpty) {
      _writeByte(NID.kMainStreamsInfo);
      _writePackInfo(0, db.packSizes, db.packCRCs);
      _writeUnpackInfo(db.folders, db);
      final unpackSizes = <int>[];
      final digests = UInt32DefVector();
      for (final file in db.files) {
        if (!file.hasStream) continue;
        unpackSizes.add(file.size);
        digests.defs.add(file.crcDefined);
        digests.vals.add(file.crc);
      }
      _writeSubStreamsInfo(db.folders, db, unpackSizes, digests);
      _writeByte(NID.kEnd);
    }

    if (db.files.isEmpty) {
      _writeByte(NID.kEnd);
      return headerOffset;
    }

    _writeByte(NID.kFilesInfo);
    _writeNumber(db.files.length);

    {
      // Empty Streams
      final emptyStreamVector = List<bool>.filled(db.files.length, false);
      var numEmptyStreams = 0;
      for (var i = 0; i < db.files.length; i++) {
        if (!db.files[i].hasStream) {
          emptyStreamVector[i] = true;
          numEmptyStreams++;
        }
      }
      if (numEmptyStreams != 0) {
        _writePropBoolVector(NID.kEmptyStream, emptyStreamVector);
        final emptyFileVector = List<bool>.filled(numEmptyStreams, false);
        final antiVector = List<bool>.filled(numEmptyStreams, false);
        var thereAreEmptyFiles = false, thereAreAntiItems = false;
        var cur = 0;
        for (var i = 0; i < db.files.length; i++) {
          final file = db.files[i];
          if (file.hasStream) continue;
          emptyFileVector[cur] = !file.isDir;
          if (!file.isDir) thereAreEmptyFiles = true;
          final isAnti = db.isItemAnti(i);
          antiVector[cur] = isAnti;
          if (isAnti) thereAreAntiItems = true;
          cur++;
        }
        if (thereAreEmptyFiles) {
          _writePropBoolVector(NID.kEmptyFile, emptyFileVector);
        }
        if (thereAreAntiItems) _writePropBoolVector(NID.kAnti, antiVector);
      }
    }

    {
      // Names
      var namesDataSize = 0;
      for (final name in db.names) {
        namesDataSize += name.length;
      }
      if (namesDataSize != 0) {
        namesDataSize += db.files.length; // tail zero for each name
        namesDataSize *= 2;
        namesDataSize++; // switch byte
        _skipToAligned(2 + _getBigNumberSize(namesDataSize), 4);
        _writeByte(NID.kName);
        _writeNumber(namesDataSize);
        _writeByte(0);
        for (final name in db.names) {
          for (var k = 0; k < name.length; k++) {
            final c = name.codeUnitAt(k);
            _writeByte(c);
            _writeByte(c >> 8);
          }
          _writeByte(0);
          _writeByte(0);
        }
      }
    }

    _writeUInt64DefVectorType(db.cTime, NID.kCTime);
    _writeUInt64DefVectorType(db.aTime, NID.kATime);
    _writeUInt64DefVectorType(db.mTime, NID.kMTime);
    _writeUInt64DefVectorType(db.startPos, NID.kStartPos);

    {
      // Attrib
      final numDefined = boolVectorCountSum(db.attrib.defs);
      if (numDefined != 0) {
        _writeAlignedBools(db.attrib.defs, numDefined, NID.kWinAttrib, 2);
        _writeUInt32DefVectorNumDefined(db.attrib, numDefined);
      }
    }

    _writeByte(NID.kEnd); // for files
    _writeByte(NID.kEnd); // for headers
    return headerOffset;
  }

  /// WriteDatabase: writes the header after the packed data and rewrites
  /// the start header. [options] is the header method (null: plain header).
  void writeDatabase(ArchiveDatabaseOut db, CompressionMethodMode? options,
      HeaderOptions headerOptions) {
    if (!db.checkNumFiles()) throw StateError('Bad file vectors');
    var nextHeaderOffset = 0;
    var nextHeaderSize = 0;
    var nextHeaderCRC = 0;

    if (!db.isEmpty) {
      var encodeHeaders = false;
      if (options != null && options.isEmpty) options = null;
      if (options != null &&
          (options.passwordIsDefined || headerOptions.compressMainHeader)) {
        encodeHeaders = true;
      }

      _out = MemoryOutStream();
      nextHeaderOffset = _writeHeader(db);

      if (encodeHeaders) {
        final buf = Uint8List.fromList(_out.toBytes());
        final encryptOptions = CompressionMethodMode()
          ..passwordIsDefined = options!.passwordIsDefined
          ..password = options.password;
        final encoder = Encoder(
            headerOptions.compressMainHeader ? options : encryptOptions);
        final packSizes = <int>[];
        final folders = <Folder>[];
        final outFolders = OutFolders();
        _encodeStream(encoder, buf, packSizes, folders, outFolders);
        if (folders.isEmpty) throw StateError('no header folder');

        _out = MemoryOutStream();
        _useAlign = false;
        _writeID(NID.kEncodedHeader);
        _writePackInfo(nextHeaderOffset, packSizes, UInt32DefVector());
        _writeUnpackInfo(folders, outFolders);
        _writeByte(NID.kEnd);
        nextHeaderOffset += _uint64VectorCountSum(packSizes);
      }
      final bytes = _out.toBytes();
      seqStream.write(bytes, 0, bytes.length);
      nextHeaderCRC = Crc32.of(bytes);
      nextHeaderSize = bytes.length;
    }
    final s = _stream;
    if (s != null) {
      s.flush();
      final end = s.position;
      s.position = _signatureHeaderPos;
      _writeStartHeader(nextHeaderOffset, nextHeaderSize, nextHeaderCRC);
      s.position = end;
      s.flush();
    }
  }
}
