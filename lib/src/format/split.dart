// Split volumes: port of CPP/7zip/Archive/SplitHandler.cpp (name.001,
// name.002 ... read as one stream), CPP/7zip/Archive/Common/MultiStream.cpp
// (CMultiStream: a seekable stream over several volumes) and
// CPP/7zip/Common/MultiOutStream.cpp (CMultiOutStream: the -v switch output,
// name.7z.001, name.7z.002 ...) of the LZMA SDK 26.01.

import 'dart:io';
import 'dart:typed_data';

import '../io/streams.dart';
import 'archive_types.dart';

/// IStreamSetRestriction: an output stream that can be told which region
/// may still be rewritten (the archive writers call setRestriction(0, 0)
/// when they will not seek back, so finished volumes can be closed).
abstract interface class StreamSetRestriction {
  void setRestriction(int begin, int end);
}

// ---------------------------------------------------------------------------
// CMultiStream

/// CMultiStream::CSubStreamInfo
class _SubStreamInfo {
  final SeekableInStream stream;
  final int size;
  int globalOffset = 0;
  int localPos = 0;
  _SubStreamInfo(this.stream, this.size);
}

/// CMultiStream: the concatenation of seekable streams of known sizes, as
/// one seekable stream (used to read split archives).
class MultiInStream implements SeekableInStream {
  final List<_SubStreamInfo> _streams = [];
  int _streamIndex = 0;
  int _pos = 0;
  int _totalLength = 0;

  /// [streams] with their sizes (the part of each stream that belongs to
  /// the concatenation starts at its position 0).
  MultiInStream(List<(SeekableInStream, int)> streams) {
    for (final (s, size) in streams) {
      _streams.add(_SubStreamInfo(s, size));
    }
    _init();
  }

  /// Opens split volume files: [firstVolumePath] (name.001, name.aa ...)
  /// and the next names while they exist, as SplitHandler finds them.
  /// Returns null when the name is not a volume name.
  static MultiInStream? openFiles(String firstVolumePath) {
    final h = SplitHandler();
    if (!h.openFiles(firstVolumePath)) return null;
    return h.getStream(0);
  }

  // CMultiStream::Init
  void _init() {
    var total = 0;
    for (final s in _streams) {
      s.globalOffset = total;
      total += s.size;
      s.localPos = 0;
      s.stream.position = 0;
    }
    _totalLength = total;
    _pos = 0;
    _streamIndex = 0;
  }

  // CMultiStream::Read
  @override
  int read(Uint8List data, int off, int size) {
    if (size == 0) return 0;
    if (_pos >= _totalLength) return 0;

    {
      var left = 0, mid = _streamIndex, right = _streams.length;
      for (;;) {
        final m = _streams[mid];
        if (_pos < m.globalOffset) {
          right = mid;
        } else if (_pos >= m.globalOffset + m.size) {
          left = mid + 1;
        } else {
          break;
        }
        mid = (left + right) ~/ 2;
      }
      _streamIndex = mid;
    }

    final s = _streams[_streamIndex];
    final localPos = _pos - s.globalOffset;
    if (localPos != s.localPos) {
      s.stream.position = localPos;
      s.localPos = localPos;
    }
    {
      final rem = s.size - localPos;
      if (size > rem) size = rem;
    }
    final n = s.stream.read(data, off, size);
    _pos += n;
    s.localPos += n;
    return n;
  }

  // CMultiStream::Seek
  @override
  int get position => _pos;

  @override
  set position(int v) {
    if (v < 0) {
      throw const SevenZipException('Negative seek', SevenZipError.io);
    }
    _pos = v;
  }

  @override
  int get length => _totalLength;

  /// Closes the volumes that are [FileInStream]s.
  void close() {
    for (final s in _streams) {
      final st = s.stream;
      if (st is FileInStream) st.close();
    }
  }
}

// ---------------------------------------------------------------------------
// SplitHandler

/// CSeqName
class _SeqName {
  String unchangedPart = '';
  List<int> changedPart = [];
  bool splitStyle = false;

  // GetNextName
  String? getNextName() {
    {
      var i = changedPart.length;
      for (;;) {
        var c = changedPart[--i];

        if (splitStyle) {
          if (c == 0x7A) {
            // 'z'
            changedPart[i] = 0x61; // 'a'
            if (i == 0) return null;
            continue;
          } else if (c == 0x5A) {
            // 'Z'
            changedPart[i] = 0x41; // 'A'
            if (i == 0) return null;
            continue;
          }
        } else {
          if (c == 0x39) {
            // '9'
            changedPart[i] = 0x30; // '0'
            if (i == 0) {
              changedPart.insert(0, 0x31); // '1'
              break;
            }
            continue;
          }
        }

        c++;
        changedPart[i] = c;
        break;
      }
    }

    return unchangedPart + String.fromCharCodes(changedPart);
  }
}

/// Opens the next volume by name (IArchiveOpenVolumeCallback::GetStream):
/// null when it does not exist (S_FALSE).
typedef VolumeOpener = SeekableInStream? Function(String name);

/// NArchive::NSplit::CHandler
class SplitHandler {
  final List<SeekableInStream> _streams = [];
  final List<int> _sizes = [];
  String _subName = '';
  int _totalSize = 0;

  /// kProps
  static const List<int> itemPropIds = [Kpid.path, Kpid.size];

  /// kArcProps
  static const List<int> archivePropIds = [Kpid.numVolumes, Kpid.totalPhySize];

  /// IInArchive::GetArchiveProperty
  Object? getArchiveProperty(int propID) {
    switch (propID) {
      case Kpid.mainSubfile:
        return 0;
      case Kpid.phySize:
        return _sizes.isNotEmpty ? _sizes[0] : null;
      case Kpid.totalPhySize:
        return _totalSize;
      case Kpid.numVolumes:
        return _streams.length;
    }
    return null;
  }

  /// Number of volumes found.
  int get numVolumes => _streams.length;

  /// Sizes of the volumes.
  List<int> get volumeSizes => List.unmodifiable(_sizes);

  // CHandler::Open2. [name] is the name of the first volume (kpidName of
  // the volume callback).
  bool _open2(SeekableInStream stream, String name, VolumeOpener getStream,
      ArchiveProgress? callback) {
    close();

    final dotPos = name.lastIndexOf('.');
    final prefix = name.substring(0, dotPos + 1);
    final ext = name.substring(dotPos + 1);
    final ext2 = ext.toLowerCase();

    final seqName = _SeqName();

    var numLetters = 2;
    var splitStyle = false;

    if (ext2.length >= 2 && ext2.endsWith('aa')) {
      splitStyle = true;
      while (numLetters < ext2.length) {
        if (ext2[ext2.length - numLetters - 1] != 'a') break;
        numLetters++;
      }
    } else if (ext2.length >= 2 &&
        (ext2.endsWith('01') || ext2.endsWith('00'))) {
      while (numLetters < ext2.length) {
        if (ext2[ext2.length - numLetters - 1] != '0') break;
        numLetters++;
      }
      if (numLetters != ext2.length) return false;
    } else {
      return false;
    }

    seqName.unchangedPart = prefix + ext.substring(0, ext2.length - numLetters);
    seqName.changedPart =
        ext.substring(ext.length - numLetters).codeUnits.toList();
    seqName.splitStyle = splitStyle;

    if (prefix.isEmpty) {
      _subName = 'file';
    } else {
      _subName = prefix.substring(0, prefix.length - 1);
    }

    // InStream_AtBegin_GetSize
    var size = stream.length;
    stream.position = 0;

    _totalSize += size;
    _sizes.add(size);
    _streams.add(stream);

    callback?.setCompleted(_streams.length);

    for (;;) {
      final fullName = seqName.getNextName();
      if (fullName == null) break;
      final nextStream = getStream(fullName);
      if (nextStream == null) break;
      size = nextStream.length;
      nextStream.position = 0;
      _totalSize += size;
      _sizes.add(size);
      _streams.add(nextStream);
      callback?.setCompleted(_streams.length);
    }

    if (_streams.length == 1) {
      if (splitStyle) return false;
    }
    return true;
  }

  /// IInArchive::Open: [stream] is the first volume and [name] its file
  /// name (with the volume extension, for example "a.7z.001" or "x.aa").
  /// [getStream] opens the following volumes by name. Returns false when
  /// the name is not a volume name (S_FALSE).
  bool open(SeekableInStream stream, String name, VolumeOpener getStream,
      {ArchiveProgress? callback}) {
    final res = _open2(stream, name, getStream, callback);
    if (!res) close();
    return res;
  }

  /// [open] for files: the volumes are opened as [FileInStream]s next to
  /// [firstVolumePath].
  bool openFiles(String firstVolumePath) {
    final first = FileInStream.open(firstVolumePath);
    final dir = File(firstVolumePath).parent.path;
    final name = firstVolumePath.substring(firstVolumePath.length -
        File(firstVolumePath).uri.pathSegments.last.length);
    final ok = open(first, name, (n) {
      final path = '$dir${Platform.pathSeparator}$n';
      if (!File(path).existsSync()) return null;
      return FileInStream.open(path);
    });
    if (!ok) first.close();
    return ok;
  }

  /// IInArchive::Close
  void close() {
    _totalSize = 0;
    _subName = '';
    _streams.clear();
    _sizes.clear();
  }

  /// IInArchive::GetNumberOfItems
  int get numberOfItems => _streams.isEmpty ? 0 : 1;

  /// IInArchive::GetProperty
  Object? getProperty(int index, int propID) {
    switch (propID) {
      case Kpid.path:
        return _subName;
      case Kpid.size:
      case Kpid.packSize:
        return _totalSize;
    }
    return null;
  }

  /// IInArchive::Extract: copies all volumes to the output.
  void extract(List<int>? indices, bool testMode,
      ArchiveExtractCallback extractCallback) {
    if (indices != null) {
      if (indices.isEmpty) return;
      if (indices.length != 1 || indices[0] != 0) {
        throw const SevenZipException(
            'split: E_INVALIDARG', SevenZipError.unsupported);
      }
    }

    var currentTotalSize = 0;
    extractCallback.setTotal(_totalSize);
    final askMode = testMode ? AskMode.test : AskMode.extract;
    final outStream = extractCallback.getStream(0, askMode);
    if (!testMode && outStream == null) return;
    extractCallback.prepareOperation(askMode);

    final out = outStream ?? NullOutStream();
    for (var i = 0;; i++) {
      extractCallback.setCompleted(currentTotalSize);
      if (i == _streams.length) break;
      final inStream = _streams[i];
      inStream.position = 0;
      currentTotalSize += copyStream(inStream, out);
    }
    out.flush();
    extractCallback.setOperationResult(OperationResult.ok);
  }

  /// IInArchiveGetStream::GetStream: all volumes as one seekable stream.
  MultiInStream getStream(int index) {
    if (index != 0) {
      throw const SevenZipException(
          'split: E_INVALIDARG', SevenZipError.unsupported);
    }
    return MultiInStream([
      for (var i = 0; i < _streams.length; i++) (_streams[i], _sizes[i]),
    ]);
  }
}

// ---------------------------------------------------------------------------
// CMultiOutStream

// k_NumVols_MAX
const int _kNumVolsMax = ((1 << 31) - 1) - 1;

// Get_File_OPEN_MAX_Reduced_for_3_tasks with the usual limit of 1024 open
// files (sysconf is not available from Dart).
const int _numOpenFilesAllowedMax = (1024 - 10) ~/ 3;

/// CMultiOutStream::CVolStream
class _VolStream {
  RandomAccessFile? stream;
  int start = 0; // start pos of current Stream in global stream
  int pos = 0; // pos in current Stream
  int realSize = 0;
  int next = -1; // next older
  int prev = -1; // prev newer
  String postfix = '';

  // SetSize2
  void setSize2(int size) {
    stream!.truncateSync(size);
    realSize = size;
  }
}

/// CMultiOutStream: a seekable output split into volume files
/// [prefix]001, [prefix]002 ... of the given sizes (the -v switch). Each
/// volume is written as `name.tmp` and renamed when it is complete. The
/// last size repeats. Call [finalFlushAndCloseFiles] at the end, or
/// [destruct] to delete everything after an error.
class MultiOutStream implements SeekableOutStream, StreamSetRestriction {
  int _streamIndex = 0;
  int _offsetPos = 0;
  int _absPos = 0;
  int _length = 0;
  int _absLimit = -1;

  final List<_VolStream> _streams = [];
  List<int> _sizes = [];

  int _restrictBegin = 0;
  int _restrictEnd = -1;
  int _restrictGlobal = 0;

  // ----- Double Linked List -----

  int _numListItems = 0;
  int _head = -1; // newest
  // ignore: unused_field
  int _tail = -1; // oldest

  /// Path prefix of the volumes, for example "/tmp/a.7z." (the volume
  /// number 001, 002 ... is appended).
  String prefix;

  /// The modification time to set on the volumes when they are closed.
  DateTime? mTime;
  bool finalVolWasReopen = false;

  /// When true (the default), [destruct] deletes the volume files.
  bool needDelete = true;

  MultiOutStream(this.prefix, List<int> sizes) {
    init(sizes);
  }

  // Unsigned comparisons for the (UInt64)(Int64)-1 values.
  static bool _ult(int a, int b) =>
      (a ^ 0x8000000000000000) < (b ^ 0x8000000000000000);

  void _initLinkedList() {
    _head = -1;
    _tail = -1;
    _numListItems = 0;
  }

  void _insertToLinkedList(int index) {
    {
      final node = _streams[index];
      node.next = _head;
      node.prev = -1;
    }
    if (_head != -1) {
      _streams[_head].prev = index;
    } else {
      _tail = index;
    }
    _head = index;
    _numListItems++;
  }

  void _removeFromLinkedList(int index) {
    final s = _streams[index];
    if (s.next != -1) {
      _streams[s.next].prev = s.prev;
    } else {
      _tail = s.prev;
    }
    if (s.prev != -1) {
      _streams[s.prev].next = s.next;
    } else {
      _head = s.next;
    }
    s.next = -1;
    s.prev = -1;
    _numListItems--;
  }

  int _getVolSizeForStream(int i) {
    final last = _sizes.length - 1;
    return _sizes[i < last ? i : last];
  }

  int _getGlobalOffsetForNewStream() => _streams.isEmpty
      ? 0
      : _streams.last.start + _getVolSizeForStream(_streams.length - 1);

  bool _isRestrictedEmpty(_VolStream s) {
    // (s) must be stream that has (VolSize == 0).
    // we treat empty stream as restricted, if next byte is restricted.
    if (_ult(s.start, _restrictGlobal)) return true;
    return _restrictBegin != _restrictEnd &&
        !_ult(s.start, _restrictBegin) &&
        (_restrictBegin == s.start || _ult(s.start, _restrictEnd));
  }

  /// Destruct: closes the files and deletes them when [needDelete] is set.
  void destruct() {
    Object? error;
    while (_streams.isNotEmpty) {
      try {
        if (needDelete) {
          _closeStreamAndDeleteFile(_streams.length - 1);
        } else {
          _closeStream(_streams.length - 1);
        }
      } on Object catch (e) {
        error ??= e;
      }
      {
        final s = _streams.last;
        if (s.stream != null) {
          try {
            s.stream!.closeSync();
          } on Object {
            // ignore
          }
          s.stream = null;
          _removeFromLinkedList(_streams.length - 1);
        }
      }
      _streams.removeLast();
    }
    if (error != null) throw error;
  }

  // CMultiOutStream::Init
  void init(List<int> sizes) {
    _streams.clear();
    _initLinkedList();
    _sizes = List.of(sizes);
    needDelete = true;
    mTime = null;
    finalVolWasReopen = false;
    _streamIndex = 0;
    _offsetPos = 0;
    _absPos = 0;
    _length = 0;
    _absLimit = -1;
    _restrictBegin = 0;
    _restrictEnd = -1;
    _restrictGlobal = 0;
    var sum = 0;
    var i = 0;
    for (i = 0; i < _sizes.length; i++) {
      if (i >= _kNumVolsMax) {
        _absLimit = sum;
        break;
      }
      final size = _sizes[i];
      final next = sum + size;
      if (_ult(next, sum)) break;
      sum = next;
    }
    if (_sizes.isEmpty) {
      throw const SevenZipException(
          'no volume sizes', SevenZipError.unsupported);
    }
    final size = _sizes.last;
    if (size == 0) {
      throw const SevenZipException(
          'zero size last volume', SevenZipError.unsupported);
    }
    if (i == _sizes.length) {
      // (_absLimit - sum) / size >= (k_NumVols_MAX - i), in UInt64
      final absLimit = BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16);
      final q = (absLimit - BigInt.from(sum)) ~/ BigInt.from(size);
      if (q >= BigInt.from(_kNumVolsMax - i)) {
        _absLimit = sum + (_kNumVolsMax - i) * size;
      }
    }
  }

  // IsRestricted
  bool _isRestricted(_VolStream s) {
    if (_ult(s.start, _restrictGlobal)) return true;
    if (_restrictBegin == _restrictEnd) return false;
    if (!_ult(s.start, _restrictBegin)) return _ult(s.start, _restrictEnd);
    return _ult(_restrictBegin, s.start + s.realSize);
  }

  // GetFilePath
  String _getFilePath(int index) {
    var name = '${index + 1}';
    while (name.length < 3) {
      name = '0$name';
    }
    return prefix + name;
  }

  // CloseStream: we close stream, but we still keep item in Streams[]
  void _closeStream(int index) {
    final s = _streams[index];
    final f = s.stream;
    if (f != null) {
      f.closeSync();
      s.stream = null;
      _removeFromLinkedList(index);
    }
  }

  // CloseStream_and_DeleteFile
  void _closeStreamAndDeleteFile(int index) {
    _closeStream(index);
    final path = _getFilePath(index) + _streams[index].postfix;
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }

  // CloseStream_and_FinalRename
  void _closeStreamAndFinalRename(int index) {
    final s = _streams[index];
    _closeStream(index);
    final path = _getFilePath(index);
    final tempPath = path + s.postfix;
    final mt = mTime;
    if (mt != null) {
      try {
        File(tempPath).setLastModifiedSync(mt);
      } on Object {
        // we can ignore set_mtime error
      }
    }
    if (s.postfix.isEmpty) return; // the path is already final
    File(tempPath).renameSync(path);
    // we clear CVolStream::Postfix. So we will not use Temp path anymore for
    // this stream, and we will work only with final path
    s.postfix = '';
  }

  // PrepareToOpenNew
  void _prepareToOpenNew() {
    if (_numListItems < _numOpenFilesAllowedMax) return;
    // when we create zip archive: in most cases we need only starting data
    // of restricted region for rewriting zip's local header. So here we
    // close latest created volume (from Head), and we try to keep oldest
    // volumes that will be used for header rewriting later.
    final index = _head;
    if (index == -1) throw const SevenZipException('E_FAIL');
    _closeStream(index);
  }

  // CreateNewStream
  void _createNewStream(int newSize) {
    if (_streams.length >= _kNumVolsMax) {
      throw const SevenZipException(
          'too many volumes', SevenZipError.unsupported);
    }
    _prepareToOpenNew();
    final s = _VolStream();
    final path = _getFilePath(_streams.length);
    if (File(path).existsSync()) {
      throw SevenZipException('The file exists: $path', SevenZipError.io);
    }
    // CreateTempFile2(path, false, postfix, file): the first try is
    // "<path>.tmp"
    var postfix = '.tmp';
    var n = 0;
    while (File(path + postfix).existsSync()) {
      if (++n >= 100) {
        throw SevenZipException(
            'Can not create the file: $path', SevenZipError.io);
      }
      postfix = '.${n.toRadixString(16).toUpperCase().padLeft(8, '0')}.tmp';
    }
    s.postfix = postfix;
    s.stream = File(path + postfix).openSync(mode: FileMode.write);
    s.start = _getGlobalOffsetForNewStream();
    s.pos = 0;
    s.realSize = 0;
    _streams.add(s);
    _insertToLinkedList(_streams.length - 1);
    if (newSize != 0) s.setSize2(newSize);
  }

  // CreateStreams_If_Required
  void _createStreamsIfRequired(int streamIndex) {
    for (;;) {
      final numStreamsBefore = _streams.length;
      if (streamIndex < numStreamsBefore) return;
      int newSize;
      if (streamIndex == numStreamsBefore) {
        // it's final volume that will be used for real writing.
        newSize = 0;
      } else {
        // it's intermediate volume. So we need full volume size
        newSize = _getVolSizeForStream(numStreamsBefore);
      }
      _createNewStream(newSize);
      if (numStreamsBefore + 1 != _streams.length) {
        throw const SevenZipException('E_FAIL');
      }
      if (streamIndex != numStreamsBefore) {
        // it's intermediate volume. So we can close it, if it's
        // non-restricted
        final s = _streams[numStreamsBefore];
        final isRestricted =
            newSize == 0 ? _isRestrictedEmpty(s) : _isRestricted(s);
        if (!isRestricted) _closeStreamAndFinalRename(numStreamsBefore);
      }
    }
  }

  // ReOpenStream
  void _reOpenStream(int streamIndex) {
    _prepareToOpenNew();
    final s = _streams[streamIndex];
    final path = _getFilePath(streamIndex) + s.postfix;
    s.pos = 0;
    final RandomAccessFile f;
    try {
      f = File(path).openSync(mode: FileMode.append);
    } on FileSystemException catch (e) {
      throw SevenZipException('Can not reopen $path: $e', SevenZipError.io);
    }
    if (s.postfix.isEmpty) {
      // it's unexpected case that we open finished volume. It can mean that
      // the code for restriction is incorrect
      finalVolWasReopen = true;
    }
    final realSize = f.lengthSync();
    if (realSize == s.realSize) {
      f.setPositionSync(0);
      s.stream = f;
      _insertToLinkedList(streamIndex);
      return;
    }
    // file size was changed between Close() and ReOpen()
    f.closeSync();
    throw const SevenZipException('E_FAIL: volume size changed');
  }

  // OptReOpen_and_SetSize
  void _optReOpenAndSetSize(int index, int size) {
    final s = _streams[index];
    if (size == s.realSize) return;
    if (s.stream == null) _reOpenStream(index);
    s.setSize2(size);
  }

  // Normalize_finalMode
  void _normalizeFinalMode(bool finalMode) {
    var i = _streams.length;
    var offset = 0;

    while (i != 0) {
      offset = _streams[--i].start; // it's last item in Streams[]
      // we don't want to remove first volume
      if (_ult(offset, _length) || i == 0) {
        final volSize = _getVolSizeForStream(i);
        var size = _length - offset; // (size != 0) here
        if (_ult(volSize, size)) size = volSize;
        _optReOpenAndSetSize(i, size);
        if (!_ult(volSize, _length - offset)) return;
        // _length - offset > volSize
        offset += volSize;
        // _length > offset
        break;
      }
      // we Set Size of stream to zero even for (finalMode==true), although
      // that stream will be deleted in next commands
      _optReOpenAndSetSize(i, 0);
      if (finalMode) {
        _closeStreamAndDeleteFile(i);
        _streams.removeLast();
      }
    }

    // now we create new zero-filled streams to cover all data up to _length
    if (_length == 0) return;
    // (offset) is start offset of next stream after existing Streams[]
    for (;;) {
      // _length > offset
      final volSize = _getVolSizeForStream(_streams.length);
      var size = _length - offset; // (size != 0) here
      if (_ult(volSize, size)) size = volSize;
      _createNewStream(size);
      if (!_ult(volSize, _length - offset)) return;
      offset += volSize;
    }
  }

  /// FinalFlush_and_CloseFiles: removes unused volumes after the end,
  /// closes and renames all volumes. Returns the number of volumes.
  int finalFlushAndCloseFiles() {
    Object? error;
    try {
      _normalizeFinalMode(true);
    } on Object catch (e) {
      error = e;
    }
    final numTotalVolumes = _streams.length;
    for (var i = 0; i < _streams.length; i++) {
      try {
        _closeStreamAndFinalRename(i);
      } on Object catch (e) {
        error ??= e;
      }
    }
    if (_numListItems != 0 && error == null) {
      error = const SevenZipException('E_FAIL');
    }
    if (error != null) throw error;
    return numTotalVolumes;
  }

  /// SetMTime_Final
  bool setMTimeFinal(DateTime t) {
    if (!finalVolWasReopen && mTime != null && mTime == t) return true;
    var res = true;
    for (var i = 0; i < _streams.length; i++) {
      final s = _streams[i];
      try {
        File(_getFilePath(i) + s.postfix).setLastModifiedSync(t);
      } on Object {
        res = false;
      }
    }
    return res;
  }

  /// The volume paths written so far.
  List<String> get volumePaths =>
      [for (var i = 0; i < _streams.length; i++) _getFilePath(i)];

  // CMultiOutStream::SetSize
  @override
  void truncate(int newSize) {
    if (newSize < 0) throw const SevenZipException('Negative seek');
    if (_ult(_absLimit, newSize)) {
      // big seek value was sent to SetSize() or to Seek()+Write().
      throw const SevenZipException(
          'Too many volumes', SevenZipError.unsupported);
    }
    if (newSize > _length) {
      // we don't expect such case. So we just define global restriction
      _restrictGlobal = newSize;
    } else if (newSize < _restrictGlobal) {
      _restrictGlobal = newSize;
    }
    _length = newSize;
    _normalizeFinalMode(false);
  }

  // CMultiOutStream::Write
  @override
  void write(Uint8List data, int off, int size) {
    if (size == 0) return;

    if (_absPos > _length) {
      // it create data only up to _absPos. but we still can need additional
      // new streams, if _absPos at range of volume
      truncate(_absPos);
    }

    while (size != 0) {
      int volSize;
      {
        if (_streamIndex < _sizes.length - 1) {
          volSize = _sizes[_streamIndex];
          if (_offsetPos >= volSize) {
            _offsetPos -= volSize;
            _streamIndex++;
            continue;
          }
        } else {
          volSize = _sizes[_sizes.length - 1];
          if (_offsetPos >= volSize) {
            final v = _offsetPos ~/ volSize;
            if (v >= 0xFFFFFFFF - _streamIndex) {
              throw const SevenZipException(
                  'Too many volumes', SevenZipError.unsupported);
            }
            _streamIndex += v;
            _offsetPos -= v * volSize;
          }
          if (_streamIndex >= _kNumVolsMax) {
            throw const SevenZipException(
                'Too many volumes', SevenZipError.unsupported);
          }
        }
      }

      // (_offsetPos < volSize) here
      _createStreamsIfRequired(_streamIndex);

      final s = _streams[_streamIndex];

      if (s.stream == null) _reOpenStream(_streamIndex);
      final f = s.stream!;
      if (_offsetPos != s.pos) {
        f.setPositionSync(_offsetPos);
        s.pos = _offsetPos;
      }

      var curSize = size;
      {
        final rem = volSize - _offsetPos;
        if (curSize > rem) curSize = rem;
      }
      f.writeFromSync(data, off, off + curSize);
      final realProcessed = curSize;
      off += realProcessed;
      size -= realProcessed;
      s.pos += realProcessed;
      _offsetPos += realProcessed;
      _absPos += realProcessed;
      if (_length < _absPos) _length = _absPos;
      if (s.realSize < _offsetPos) s.realSize = _offsetPos;
      if (s.pos == volSize) {
        final isRestricted =
            volSize == 0 ? _isRestrictedEmpty(s) : _isRestricted(s);
        if (!isRestricted) _closeStreamAndFinalRename(_streamIndex);
        _streamIndex++;
        _offsetPos = 0;
      }
    }
  }

  @override
  void flush() {}

  // CMultiOutStream::Seek
  @override
  int get position => _absPos;

  @override
  set position(int offset) {
    if (offset < 0) throw const SevenZipException('Negative seek');
    if (offset != _absPos) {
      _absPos = offset;
      _offsetPos = offset;
      _streamIndex = 0;
    }
  }

  /// GetSize: the virtual length.
  @override
  int get length => _length;

  // GetStreamIndex_for_Offset: returns (index, relOffset); the index
  // saturates to 0xFFFFFFFF.
  (int, int) _getStreamIndexForOffset(int offset) {
    final last = _sizes.length - 1;
    for (var i = 0; i < last; i++) {
      final size = _sizes[i];
      if (_ult(offset, size)) return (i, offset);
      offset -= size;
    }
    final size = _sizes[last];
    final v = offset ~/ size;
    if (v >= 0xFFFFFFFF - last) return (0xFFFFFFFF, 0); // saturation
    return (last + v, offset - v * size);
  }

  // CMultiOutStream::SetRestriction
  @override
  void setRestriction(int begin, int end) {
    if (_ult(end, begin)) {
      throw const SevenZipException('E_FAIL: bad restriction');
    }
    var b = _restrictBegin;
    var e = _restrictEnd;
    _restrictBegin = begin;
    _restrictEnd = end;

    if (b == e) return; // no work to derestrict now.

    // [b, e) is previous restricted region. So all volumes that intersect
    // that [b, e) region are candidates for derestriction
    if (begin != end) {
      if (b == begin) b = end;
      if (e == end) e = begin;
    }

    if (_ult(e, b)) return;

    // Here we close finished volumes that are not restricted anymore.
    // We close (low number) volumes at first.
    var (index, _) = _getStreamIndexForOffset(b);
    for (; index < _streams.length; index++) {
      {
        final s = _streams[index];
        // we don't close streams after _length
        if (!_ult(s.start, _length)) break;
        final volSize = _getVolSizeForStream(index);
        if (volSize == 0) {
          if (_ult(e, s.start)) break;
          // we don't close empty stream, if next byte [s.Start, s.Start] is
          // restricted
          if (_isRestrictedEmpty(s)) continue;
        } else {
          if (!_ult(s.start, e)) break;
          // we don't close non full streams
          if (_ult(_length - s.start, volSize)) break;
          if (_isRestricted(s)) continue;
        }
      }
      _closeStreamAndFinalRename(index);
    }
  }
}
