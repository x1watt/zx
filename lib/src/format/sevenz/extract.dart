// Extraction: 7zExtract.cpp of the LZMA SDK (CFolderOutStream and
// CHandler::Extract). Each folder (solid block) is decoded once, from its
// start up to the last requested file, and the files are passed to the
// callback in order.

import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import 'decode.dart';
import 'handler.dart';
import 'header.dart';
import 'sevenz_in.dart';

/// k_My_HRESULT_WritingWasCut
class _WritingWasCut implements Exception {
  const _WritingWasCut();
}

/// CFolderOutStream (7zExtract.cpp).
class FolderOutStream implements OutStream {
  OutStream? _stream;
  bool testMode = false;
  bool checkCrc = true;

  bool _fileIsOpen = false;
  bool _calcCrc = false;
  int _crc = 0;
  int _rem = 0;

  List<int>? _indexes;
  int _indexPos = 0;
  int _numFiles = 0;
  int _fileIndex = 0;

  final DbEx _db;
  final ArchiveExtractCallback extractCallback;
  bool extraWriteWasCut = false;

  FolderOutStream(this._db, this.extractCallback);

  /// Init: [indexes] from [indexPos] are the requested files (null: all
  /// files from [startIndex]).
  void init(int startIndex, List<int>? indexes, int indexPos, int numFiles) {
    _fileIndex = startIndex;
    _indexes = indexes;
    _indexPos = indexPos;
    _numFiles = numFiles;
    _fileIsOpen = false;
    extraWriteWasCut = false;
    _processEmptyFiles();
  }

  // OpenFile
  void _openFile([bool isCorrupted = false]) {
    final fi = _db.files[_fileIndex];
    final ix = _indexes;
    final nextFileIndex = ix != null ? ix[_indexPos] : _fileIndex;
    var askMode = _fileIndex == nextFileIndex
        ? (testMode ? AskMode.test : AskMode.extract)
        : AskMode.skip;
    if (isCorrupted &&
        askMode == AskMode.extract &&
        !_db.isItemAnti(_fileIndex) &&
        !fi.isDir) {
      askMode = AskMode.test;
    }
    final realOutStream = extractCallback.getStream(_fileIndex, askMode);
    _stream = realOutStream;
    _crc = 0xFFFFFFFF;
    _calcCrc = checkCrc && fi.crcDefined && !fi.isDir;
    _fileIsOpen = true;
    _rem = fi.size;
    if (askMode == AskMode.extract &&
        realOutStream == null &&
        !_db.isItemAnti(_fileIndex) &&
        !fi.isDir) {
      askMode = AskMode.skip;
    }
    extractCallback.prepareOperation(askMode);
  }

  // CloseFile_and_SetResult
  void _closeFileAndSetResult(int res) {
    _stream = null;
    _fileIsOpen = false;
    final ix = _indexes;
    if (ix == null) {
      _numFiles--;
    } else if (ix[_indexPos] == _fileIndex) {
      _indexPos++;
      _numFiles--;
    }
    _fileIndex++;
    extractCallback.setOperationResult(res);
  }

  // CloseFile
  void _closeFile() {
    final fi = _db.files[_fileIndex];
    _closeFileAndSetResult((!_calcCrc || fi.crc == (_crc ^ 0xFFFFFFFF))
        ? OperationResult.ok
        : OperationResult.crcError);
  }

  // ProcessEmptyFiles
  void _processEmptyFiles() {
    while (_numFiles != 0 && _db.files[_fileIndex].size == 0) {
      _openFile();
      _closeFile();
    }
  }

  @override
  void write(Uint8List data, int off, int size) {
    while (size != 0) {
      if (_fileIsOpen) {
        var cur = size < _rem ? size : _rem;
        if (_calcCrc) {
          const kStep = 1 << 20;
          if (cur > kStep) cur = kStep;
        }
        final s = _stream;
        if (s != null) s.write(data, off, cur);
        if (_calcCrc) _crc = crc32Update(_crc, data, off, off + cur);
        off += cur;
        size -= cur;
        _rem -= cur;
        if (_rem == 0) {
          _closeFile();
          _processEmptyFiles();
        }
        if (cur == 0) break;
        continue;
      }
      _processEmptyFiles();
      if (_numFiles == 0) {
        extraWriteWasCut = true;
        throw const _WritingWasCut();
      }
      _openFile();
    }
  }

  @override
  void flush() {}

  // FlushCorrupted
  void flushCorrupted(int callbackOperationResult) {
    while (_numFiles != 0) {
      if (_fileIsOpen) {
        _closeFileAndSetResult(callbackOperationResult);
      } else {
        _openFile(true);
      }
    }
  }

  // WasWritingFinished
  bool get wasWritingFinished => _numFiles == 0;
}

/// Maps a decoder error to an NExtract::NOperationResult value.
int operationResultForError(SevenZipException e) {
  switch (e.kind) {
    case SevenZipError.unsupportedMethod:
    case SevenZipError.unsupported:
      return OperationResult.unsupportedMethod;
    case SevenZipError.crc:
      return OperationResult.crcError;
    case SevenZipError.unexpectedEnd:
      return OperationResult.unexpectedEnd;
    case SevenZipError.dataAfterEnd:
      return OperationResult.dataAfterEnd;
    case SevenZipError.wrongPassword:
      return OperationResult.wrongPassword;
    case SevenZipError.unavailable:
      return OperationResult.unavailable;
    default:
      return OperationResult.dataError;
  }
}

/// CHandler::Extract.
void extractItems(SevenZipHandler h, List<int>? indices, bool testModeSpec,
    ArchiveExtractCallback extractCallback) {
  final db = h.db;
  final inStream = h.inStream;
  if (inStream == null) throw StateError('archive is not open');
  final allFilesMode = indices == null;
  final numItems = allFilesMode ? db.files.length : indices.length;
  if (numItems == 0) return;

  var importantTotalUnpacked = 0;
  {
    var prevFolder = kNumNoIndex;
    var nextFile = 0;
    for (var i = 0; i < numItems; i++) {
      final fileIndex = allFilesMode ? i : indices[i];
      final folderIndex = db.fileIndexToFolderIndexMap[fileIndex];
      if (folderIndex == kNumNoIndex) continue;
      if (folderIndex != prevFolder || fileIndex < nextFile) {
        nextFile = db.folderStartFileIndex[folderIndex];
      }
      for (var index = nextFile; index <= fileIndex; index++) {
        importantTotalUnpacked += db.files[index].size;
      }
      nextFile = fileIndex + 1;
      prevFolder = folderIndex;
    }
  }
  extractCallback.setTotal(importantTotalUnpacked);

  final decoder = Decoder();
  final callbackMessage = extractCallback is ArchiveExtractCallbackMessage2
      ? extractCallback as ArchiveExtractCallbackMessage2
      : null;

  final folderOutStream = FolderOutStream(db, extractCallback)
    ..testMode = testModeSpec
    ..checkCrc = h.crcSize != 0;

  PasswordProvider? getTextPassword;
  if (extractCallback is CryptoGetTextPassword) {
    final cb = extractCallback as CryptoGetTextPassword;
    getTextPassword = cb.cryptoGetTextPassword;
  } else {
    getTextPassword = h.defaultPassword;
  }

  var outSize = 0;
  final buf = Uint8List(1 << 16);
  var curUnpacked = 0;
  for (var i = 0;; outSize += curUnpacked) {
    extractCallback.setCompleted(outSize);
    if (i >= numItems) break;
    curUnpacked = 0;
    var fileIndex = allFilesMode ? i : indices[i];
    final folderIndex = db.fileIndexToFolderIndexMap[fileIndex];
    var numSolidFiles = 1;
    if (folderIndex != kNumNoIndex) {
      var nextFile = fileIndex + 1;
      fileIndex = db.folderStartFileIndex[folderIndex];
      var k = i + 1;
      for (; k < numItems; k++) {
        final fileIndex2 = allFilesMode ? k : indices[k];
        if (db.fileIndexToFolderIndexMap[fileIndex2] != folderIndex ||
            fileIndex2 < nextFile) {
          break;
        }
        nextFile = fileIndex2 + 1;
      }
      numSolidFiles = k - i;
      for (k = fileIndex; k < nextFile; k++) {
        curUnpacked += db.files[k].size;
      }
    }

    folderOutStream.init(fileIndex, allFilesMode ? null : indices,
        allFilesMode ? 0 : i, numSolidFiles);
    i += numSolidFiles;

    if (folderOutStream.wasWritingFinished) continue;
    if (folderIndex == kNumNoIndex) {
      throw const SevenZipException('Bad file index', SevenZipError.headers);
    }

    final crypto = DecoderCryptoVars(getTextPassword);
    int? resOp;
    var dataAfterEndError = false;
    try {
      final s = decoder.decode(inStream, db.arcInfo.dataStartPosition, db,
          folderIndex, curUnpacked, crypto, h.coderContext);
      var done = 0;
      while (done < curUnpacked) {
        var want = curUnpacked - done;
        if (want > buf.length) want = buf.length;
        final n = s.read(buf, 0, want);
        if (n == 0) break;
        folderOutStream.write(buf, 0, n);
        done += n;
        extractCallback.setCompleted(outSize + done);
      }
      if (done != curUnpacked) resOp = OperationResult.dataError;
    } on _WritingWasCut {
      resOp = null;
    } on SevenZipException catch (e) {
      if (e.kind == SevenZipError.io || e.kind == SevenZipError.cancelled) {
        rethrow;
      }
      resOp = operationResultForError(e);
      if (resOp == OperationResult.dataAfterEnd) dataAfterEndError = true;
    } on InArchiveException {
      resOp = OperationResult.dataError;
    }

    if (resOp != null) {
      final wasFinished = folderOutStream.wasWritingFinished;
      if (dataAfterEndError && !wasFinished) resOp = OperationResult.dataError;
      folderOutStream.flushCorrupted(resOp);
      if (wasFinished && callbackMessage != null) {
        callbackMessage.reportExtractResult(
            EventIndexType.blockIndex, folderIndex, resOp);
      }
      continue;
    }
    folderOutStream.flushCorrupted(OperationResult.dataError);
  }
}
