// The input of a new solid block: 7zFolderInStream.h and
// 7zFolderInStream.cpp of the LZMA SDK. Concatenates the streams of the
// files of a folder (asked from the update callback in order), computing
// the size and CRC of each file.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';

/// CFolderInStream.
class FolderInStream implements InStream {
  InStream? _stream;
  int _totalSizeForCoder = 0;
  int _pos = 0;
  int _crc = 0xFFFFFFFF;
  bool _sizeDefined = false;
  bool _timesDefined = false;
  int _size = 0;
  int _mTime = 0;
  int _cTime = 0;
  int _aTime = 0;
  int _attrib = 0;

  int _numFiles = 0;
  late List<int> _indexes;
  int _indexStart = 0;
  late ArchiveUpdateCallback _updateCallback;

  bool needMTime = false;
  bool needCTime = false;
  bool needATime = false;
  bool needAttrib = false;

  final List<bool> processed = [];
  final List<int> sizes = [];
  final List<int> crcs = [];
  final List<int> attribs = [];
  final List<bool> timesDefined = [];
  final List<int> mTimes = [];
  final List<int> cTimes = [];
  final List<int> aTimes = [];

  /// Init: the files are [indexes] from [start], [numFiles] of them.
  void init(ArchiveUpdateCallback updateCallback, List<int> indexes, int start,
      int numFiles) {
    _updateCallback = updateCallback;
    _indexes = indexes;
    _indexStart = start;
    _numFiles = numFiles;
    _totalSizeForCoder = 0;
    _clearFileInfo();
    processed.clear();
    sizes.clear();
    crcs.clear();
    timesDefined.clear();
    mTimes.clear();
    cTimes.clear();
    aTimes.clear();
    attribs.clear();
    _stream = null;
  }

  // WasFinished
  bool get wasFinished => processed.length == _numFiles;

  // Get_TotalSize_for_Coder
  int get totalSizeForCoder => _totalSizeForCoder;

  // ClearFileInfo
  void _clearFileInfo() {
    _pos = 0;
    _crc = 0xFFFFFFFF;
    _sizeDefined = false;
    _timesDefined = false;
    _size = 0;
    _mTime = 0;
    _cTime = 0;
    _aTime = 0;
    _attrib = 0;
  }

  // OpenStream
  void _openStream() {
    while (processed.length < _numFiles) {
      final stream =
          _updateCallback.getStream(_indexes[_indexStart + processed.length]);
      _stream = stream;
      if (stream != null) {
        if (stream is StreamGetProps) {
          final p = stream as StreamGetProps;
          final size = p.size;
          if (size != null) {
            _size = size;
            if (needCTime) _cTime = p.cTime ?? 0;
            if (needATime) _aTime = p.aTime ?? 0;
            if (needMTime) _mTime = p.mTime ?? 0;
            if (needAttrib) _attrib = p.attrib ?? 0;
            _sizeDefined = true;
            _timesDefined = true;
          }
          return;
        }
        if (stream is StreamGetSize) {
          final size = (stream as StreamGetSize).streamSize;
          if (size != null) {
            _size = size;
            _sizeDefined = true;
          }
        }
        return;
      }
      _addFileInfo(false);
    }
  }

  // AddFileInfo
  void _addFileInfo(bool isProcessed) {
    processed.add(isProcessed);
    sizes.add(_pos);
    crcs.add(_crc ^ 0xFFFFFFFF);
    if (needAttrib) attribs.add(_attrib);
    timesDefined.add(_timesDefined);
    if (needMTime) mTimes.add(_mTime);
    if (needCTime) cTimes.add(_cTime);
    if (needATime) aTimes.add(_aTime);
    _clearFileInfo();
    _updateCallback.setOperationResult(0);
  }

  @override
  int read(Uint8List data, int off, int size) {
    while (size != 0) {
      final s = _stream;
      if (s != null) {
        var cur = size;
        const kMax = 1 << 20;
        if (cur > kMax) cur = kMax;
        cur = s.read(data, off, cur);
        if (cur != 0) {
          _crc = crc32Update(_crc, data, off, off + cur);
          _pos += cur;
          _totalSizeForCoder += cur;
          return cur;
        }
        _stream = null;
        releaseStream(s);
        _addFileInfo(true);
      }
      if (processed.length >= _numFiles) break;
      _openStream();
    }
    return 0;
  }

  /// GetSubStreamSize: size of sub stream [subStream] (null when unknown).
  int? getSubStreamSize(int subStream) {
    if (subStream > sizes.length) return null;
    if (subStream < sizes.length) return sizes[subStream];
    if (!_sizeDefined) return null;
    return _pos > _size ? _pos : _size;
  }
}
