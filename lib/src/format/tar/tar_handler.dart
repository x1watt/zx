// The tar archive handler: IInArchive (Open, OpenSeq, GetProperty, Extract,
// GetStream) and IOutArchive (UpdateItems, SetProperties) over the reader
// of tar_in.dart and the writer of tar_out.dart.
//
// The headers are parsed as libarchive's archive_read_support_format_tar.c
// does (BSD 2-clause, see LICENSE). The item properties, the error flags and
// the update rules (kept items copied byte for byte, new items written in
// GNU or pax form, -mm, -mtm, -mtc, -mta, -mtp) follow what 7-Zip shows and
// writes for tar archives; the 7-Zip tar handler itself is LGPL and was not
// used (docs/architecture.md, section 10).

import 'dart:convert';
import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import '../handler_out.dart';
import 'tar_header.dart';
import 'tar_in.dart';
import 'tar_out.dart';

/// k_PropVar_TimePrec_Base + 7 (100 ns, FILETIME).
const int _kTimePrec100ns = 16 + 7;

/// The tar handler.
class TarHandler {
  SeekableInStream? _stream;
  TarReader? _seqReader;
  final List<TarItem> items = [];

  bool _isArc = false;
  bool _unexpectedEnd = false;
  bool _headersError = false;
  bool _warning = false;
  int _phySize = 0;
  bool _phySizeDefined = false;
  int _headersSize = 0;

  // OpenSeq state: the item whose data the reader is at, and whether the
  // last header was read
  int _seqDataItem = -1;
  bool _seqEnd = false;

  /// Format for new items (-mm=gnu, -mm=pax or -mm=posix).
  TarWriteFormat writeFormat = TarWriteFormat.gnu;
  final HandlerTimeOptions timeOptions = HandlerTimeOptions();

  // IInArchive

  /// IInArchive::Open. false (S_FALSE) when [stream] does not start with a
  /// tar header.
  bool open(SeekableInStream stream) {
    close();
    stream.position = 0;
    final first = Uint8List(kTarBlockSize);
    if (readFully(stream, first, 0, kTarBlockSize) != kTarBlockSize) {
      return false;
    }
    if (!_isArcStart(first, stream.length)) return false;
    stream.position = 0;
    _stream = stream;
    _isArc = true;
    final reader = TarReader(stream);
    final length = stream.length;
    for (;;) {
      final item = TarItem();
      final r = reader.readItem(item);
      if (r == TarReadResult.item) {
        items.add(item);
        if (item.endPos > length) {
          item.truncated = item.dataPos + item.packSize > length;
          _unexpectedEnd = true;
          _phySize = length;
          break;
        }
        reader.seekTo(item.endPos);
        continue;
      }
      _finishRead(r, reader, item);
      break;
    }
    _phySizeDefined = true;
    _warning = reader.warning;
    _computeHeadersSize();
    return true;
  }

  // a zero block alone (an empty archive) is accepted, like GNU tar does,
  // only when the whole file is zeros of whole blocks up to 10 KiB
  static bool _isArcStart(Uint8List first, int length) {
    final bid = tarBid(first);
    if (bid == 0) return false;
    if (bid > 10) return true;
    return length >= 1024 && length <= 10240 && (length & 511) == 0;
  }

  void _finishRead(TarReadResult r, TarReader reader, TarItem item) {
    switch (r) {
      case TarReadResult.end:
        _phySize = reader.pos;
      case TarReadResult.eof:
        // no end marker
        _unexpectedEnd = true;
        _phySize = reader.pos;
      case TarReadResult.unexpectedEnd:
        // the partial block or the unfinished header sequence is not part
        // of the archive
        _unexpectedEnd = true;
        _phySize = item.headerPos < reader.pos ? item.headerPos : reader.pos;
      case TarReadResult.headersError:
        _headersError = true;
        _phySize = item.headerPos;
      case TarReadResult.item:
        break;
    }
  }

  void _computeHeadersSize() {
    var data = 0;
    for (final it in items) {
      if (!it.truncated) data += it.packSizeAligned;
    }
    _headersSize = _phySize - data;
    if (_headersSize < 0) _headersSize = 0;
  }

  /// IArchiveOpenSeq::OpenSeq: reads the first header. false when the
  /// stream does not start with a tar header.
  bool openSeq(InStream stream) {
    close();
    final reader = TarReader(stream);
    _seqReader = reader;
    final item = TarItem();
    final r = reader.readItem(item);
    if (r == TarReadResult.headersError) {
      _seqReader = null;
      return false;
    }
    _isArc = true;
    if (r == TarReadResult.item) {
      items.add(item);
      _seqDataItem = 0;
    } else {
      _finishRead(r, reader, item);
      _seqEnd = true;
      _phySizeDefined = true;
    }
    return true;
  }

  // reads the next header in OpenSeq mode, skipping the data of the
  // current item; false at the end
  bool _seqNext() {
    final reader = _seqReader!;
    if (_seqEnd) return false;
    if (items.isNotEmpty) {
      final last = items.last;
      final toSkip = last.endPos - reader.pos;
      if (toSkip > 0 && reader.skip(toSkip) != toSkip) {
        last.truncated = true;
        _unexpectedEnd = true;
        _phySize = reader.pos;
        _seqEnd = true;
        _phySizeDefined = true;
        _seqDataItem = -1;
        _warning = reader.warning;
        _computeHeadersSize();
        return false;
      }
    }
    _seqDataItem = -1;
    final item = TarItem();
    final r = reader.readItem(item);
    if (r == TarReadResult.item) {
      items.add(item);
      _seqDataItem = items.length - 1;
      return true;
    }
    _finishRead(r, reader, item);
    _seqEnd = true;
    _phySizeDefined = true;
    _warning = reader.warning;
    _computeHeadersSize();
    return false;
  }

  // the item [index] in OpenSeq mode (headers are read as needed)
  bool _seqEnsure(int index) {
    while (index >= items.length) {
      if (!_seqNext()) return false;
    }
    return true;
  }

  /// IInArchive::Close.
  void close() {
    _stream = null;
    _seqReader = null;
    items.clear();
    _isArc = false;
    _unexpectedEnd = false;
    _headersError = false;
    _warning = false;
    _phySize = 0;
    _phySizeDefined = false;
    _headersSize = 0;
    _seqDataItem = -1;
    _seqEnd = false;
  }

  /// GetNumberOfItems. In OpenSeq mode this reads all the remaining
  /// headers (skipping the data), as listing needs.
  int get numberOfItems {
    if (_seqReader != null) {
      while (_seqNext()) {}
    }
    return items.length;
  }

  /// kProps: the item properties in 7-Zip's listing order.
  static const List<int> itemPropIds = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.aTime,
    Kpid.posixAttrib,
    Kpid.user,
    Kpid.group,
    Kpid.userId,
    Kpid.groupId,
    Kpid.symLink,
    Kpid.hardLink,
    Kpid.characts,
    Kpid.deviceMajor,
    Kpid.deviceMinor,
  ];

  /// kArcProps.
  static const List<int> archivePropIds = [
    Kpid.headersSize,
    Kpid.codePage,
    Kpid.characts,
  ];

  bool get _anyFractionTimes {
    for (final it in items) {
      for (final t in [it.mTime, it.aTime, it.cTime]) {
        if (t != null && t.ns != 0) return true;
      }
    }
    return false;
  }

  /// The precision of the time properties: 100 ns when a pax time has a
  /// fraction, else whole seconds (k_PropVar_TimePrec_Unix).
  int get timePrec => _anyFractionTimes ? _kTimePrec100ns : FileTimeType.unix;

  int get errorFlags {
    var v = 0;
    if (!_isArc) v |= ErrorFlags.isNotArc;
    if (_unexpectedEnd) v |= ErrorFlags.unexpectedEnd;
    if (_headersError) v |= ErrorFlags.headersError;
    return v;
  }

  // GetArchiveProperty
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.phySize:
        return _phySizeDefined ? _phySize : null;
      case Kpid.headersSize:
        return _phySizeDefined ? _headersSize : null;
      case Kpid.errorFlags:
        return errorFlags;
      case Kpid.warningFlags:
        return _warning ? ErrorFlags.headersError : null;
      case Kpid.codePage:
        return 'UTF-8';
      case Kpid.characts:
        return _archiveCharacts();
    }
    return null;
  }

  String _archiveCharacts() {
    final tokens = <String>[];
    void add(String s) {
      if (!tokens.contains(s)) tokens.add(s);
    }

    for (final it in items) {
      for (final t in _itemTokens(it)) {
        add(t);
      }
    }
    return tokens.join(' ');
  }

  static List<String> _itemTokens(TarItem it) {
    final t = <String>[];
    switch (it.format) {
      case TarFormat.gnu:
        t.add('GNU');
      case TarFormat.ustar:
        t.add('POSIX');
      case TarFormat.pax:
        t.add('POSIX');
        t.add('PAX');
      case TarFormat.v7:
        break;
    }
    if (it.gnuLongName) t.add('LongName');
    if (it.gnuLongLink) t.add('LongLink');
    if (it.sparse != null) t.add('SPARSE');
    for (final k in it.paxKeys) {
      if (k.startsWith('GNU.sparse')) continue;
      if (!t.contains(k)) t.add(k);
    }
    if (it.nameIsAscii) {
      t.add('ASCII');
    } else if (it.nameIsUtf8) {
      t.add('UTF8');
    }
    return t;
  }

  static String _typeFlagString(int c) {
    if (c > 0x20 && c < 0x7F) return String.fromCharCode(c);
    return '[${c.toRadixString(16).toUpperCase().padLeft(2, '0')}]';
  }

  /// The mode with the file type bits (kpidPosixAttrib).
  static int posixAttribOf(TarItem it) => (it.mode & 0xFFF) | it.fileType;

  static String _stripSlash(String s) {
    var n = s.length;
    while (n > 1 && s.codeUnitAt(n - 1) == 0x2F) {
      n--;
    }
    return s.substring(0, n);
  }

  // GetProperty
  Object? getProperty(int index, int propId) {
    if (_seqReader != null && !_seqEnsure(index)) return null;
    if (index >= items.length) return null;
    final it = items[index];
    switch (propId) {
      case Kpid.path:
        return _stripSlash(it.name);
      case Kpid.isDir:
        return it.isDir;
      case Kpid.size:
        if (it.isSymLink) return utf8.encode(it.linkName).length;
        return it.size;
      case Kpid.packSize:
        return it.packSizeAligned;
      case Kpid.mTime:
        return it.mTime?.toFileTime();
      case Kpid.cTime:
        return it.cTime?.toFileTime();
      case Kpid.aTime:
        return it.aTime?.toFileTime();
      case Kpid.posixAttrib:
        return posixAttribOf(it);
      case Kpid.user:
        return it.user.isEmpty ? null : it.user;
      case Kpid.group:
        return it.group.isEmpty ? null : it.group;
      case Kpid.userId:
        return it.uid;
      case Kpid.groupId:
        return it.gid;
      case Kpid.symLink:
        return it.isSymLink && it.linkName.isNotEmpty ? it.linkName : null;
      case Kpid.hardLink:
        return it.isHardLink && it.linkName.isNotEmpty ? it.linkName : null;
      case Kpid.characts:
        return [_typeFlagString(it.typeFlag), ..._itemTokens(it)].join(' ');
      case Kpid.deviceMajor:
        return it.devMajor >= 0 ? it.devMajor : null;
      case Kpid.deviceMinor:
        return it.devMinor >= 0 ? it.devMinor : null;
    }
    return null;
  }

  /// IInArchiveGetStream::GetStream: random access to the data of a
  /// regular, not sparse item of an archive opened with [open].
  SeekableInStream? getStream(int index) {
    final s = _stream;
    if (s == null || index >= items.length) return null;
    final it = items[index];
    if (it.isDir || it.isSymLink || it.sparse != null || it.truncated) {
      return null;
    }
    return _ItemInStream(s, it.dataPos, it.packSize);
  }

  // the data of an item: the stored bytes (expanded when sparse), or the
  // link target of a symbolic link
  InStream _itemData(TarItem it, InStream raw) {
    if (it.isSymLink) {
      return MemoryInStream(Uint8List.fromList(utf8.encode(it.linkName)));
    }
    final sparse = it.sparse;
    if (sparse != null) {
      return TarSparseInStream(
          LimitedInStream(raw, it.packSize), sparse, it.size);
    }
    return LimitedInStream(raw, it.packSize);
  }

  int _itemUnpackSize(TarItem it) =>
      it.isSymLink ? utf8.encode(it.linkName).length : it.size;

  /// IInArchive::Extract. [indices] null means all items.
  void extract(List<int>? indices, bool testMode,
      ArchiveExtractCallback extractCallback) {
    if (_seqReader != null) {
      _extractSeq(indices, testMode, extractCallback);
      return;
    }
    final allFilesMode = indices == null;
    final ix = indices ?? [for (var i = 0; i < items.length; i++) i];
    var totalSize = 0;
    for (final i in ix) {
      totalSize += _itemUnpackSize(items[i]);
    }
    extractCallback.setTotal(totalSize);
    var completed = 0;
    final buf = Uint8List(1 << 16);
    for (final index in ix) {
      extractCallback.setCompleted(completed);
      final it = items[index];
      final opRes = _extractItem(
          index,
          it,
          testMode,
          extractCallback,
          buf,
          () => WindowInStream(_stream!, it.dataPos, it.packSize),
          (done) => extractCallback.setCompleted(completed + done));
      completed += _itemUnpackSize(it);
      extractCallback.setOperationResult(opRes);
      if (allFilesMode && it.truncated) break;
    }
    extractCallback.setCompleted(completed);
  }

  int _extractItem(
      int index,
      TarItem it,
      bool testMode,
      ArchiveExtractCallback cb,
      Uint8List buf,
      InStream Function() raw,
      void Function(int) progress) {
    var askMode = testMode ? AskMode.test : AskMode.extract;
    final realOutStream = cb.getStream(index, askMode);
    if (!testMode && realOutStream == null && !it.isDir) {
      askMode = AskMode.skip;
    }
    cb.prepareOperation(askMode);
    if (it.isDir) return OperationResult.ok;
    final size = _itemUnpackSize(it);
    final src = _itemData(it, raw());
    var done = 0;
    try {
      while (done < size) {
        var want = size - done;
        if (want > buf.length) want = buf.length;
        final n = src.read(buf, 0, want);
        if (n == 0) break;
        realOutStream?.write(buf, 0, n);
        done += n;
        if ((done & 0xFFFFF) < n) progress(done);
      }
    } on SevenZipException catch (e) {
      if (e.kind != SevenZipError.unexpectedEnd) rethrow;
    }
    realOutStream?.flush();
    if (done < size || it.truncated) return OperationResult.unexpectedEnd;
    return OperationResult.ok;
  }

  // Extract in OpenSeq mode: the items in archive order, each once
  void _extractSeq(
      List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    final reader = _seqReader!;
    final buf = Uint8List(1 << 16);
    var completed = 0;
    var k = 0;
    cb.setCompleted(0);
    for (var index = 0;; index++) {
      if (indices != null) {
        if (k >= indices.length) break;
        if (indices[k] != index) {
          if (!_seqEnsure(index)) break;
          continue;
        }
        k++;
      }
      if (!_seqEnsure(index)) break;
      final it = items[index];
      if (_seqDataItem != index) {
        // the data was skipped already (headers read for a listing)
        final askMode = testMode ? AskMode.test : AskMode.extract;
        cb.getStream(index, askMode);
        cb.prepareOperation(askMode);
        cb.setOperationResult(
            it.isDir ? OperationResult.ok : OperationResult.unavailable);
        continue;
      }
      final opRes = _extractItem(
          index,
          it,
          testMode,
          cb,
          buf,
          () => _ReaderInStream(reader),
          (done) => cb.setCompleted(completed + done));
      completed += it.packSizeAligned;
      cb.setOperationResult(opRes);
      cb.setCompleted(reader.pos);
      if (it.truncated) break;
    }
  }

  // IOutArchive

  /// IOutArchive::GetFileTimeType: whole seconds unless -mtp asks for more.
  int getFileTimeType() {
    final p = timeOptions.prec;
    if (p == -1) return FileTimeType.unix;
    return p;
  }

  /// ISetProperties::SetProperties: m (gnu, pax, posix), tm, ta, tc, tp;
  /// x, mt, memuse and cp are accepted and have no effect.
  void setProperties(List<MapEntry<String, PropVariant>> props) {
    writeFormat = TarWriteFormat.gnu;
    timeOptions.init();
    for (final p in props) {
      final name = p.key.toLowerCase();
      final value = p.value;
      if (name.isEmpty) invalidArg();
      if (name == 'm') {
        if (value.vt != VarType.bstr) invalidArg();
        switch (value.stringValue.toLowerCase()) {
          case 'gnu':
            writeFormat = TarWriteFormat.gnu;
          case 'pax':
          case 'posix':
            writeFormat = TarWriteFormat.pax;
          default:
            invalidArg('Unsupported tar format: ${value.stringValue}');
        }
        continue;
      }
      if (timeOptions.parse(name, value)) continue;
      if (name == 'cp' ||
          name.startsWith('x') ||
          name.startsWith('mt') ||
          name.startsWith('memuse')) {
        continue;
      }
      invalidArg();
    }
  }

  // the digits of the fraction of a second written for -mtp
  int _timeDigits() {
    final p = timeOptions.prec;
    switch (p) {
      case FileTimeType.windows:
        return 7; // 100 ns
      case FileTimeType.unix1ns:
      case TimePrec.highPrec:
        return 9;
    }
    if (p >= TimePrec.base && p <= TimePrec.base + 9) {
      return p - TimePrec.base;
    }
    return 0; // default, unix and dos: whole seconds
  }

  /// IOutArchive::UpdateItems: writes a new archive to [outStream] with
  /// only sequential writes. Kept items are copied from the open archive
  /// byte for byte; renamed ones get new headers and their old data; new
  /// items are written in the [writeFormat] (pax when -mtc, -mta or a
  /// sub-second -mtp needs pax records).
  void updateItems(
      OutStream outStream, int numItems, ArchiveUpdateCallback updateCallback) {
    for (final _ in updateItemsSteps(outStream, numItems, updateCallback)) {}
  }

  /// [updateItems] in steps: each step writes at most one buffer of data
  /// (64 KiB) or the headers of one item to [outStream]. A caller that
  /// needs the archive as a pull stream (a tar written into a compressor,
  /// arc_compound.dart) runs one step whenever it needs more bytes.
  Iterable<void> updateItemsSteps(OutStream outStream, int numItems,
      ArchiveUpdateCallback updateCallback) sync* {
    if (_seqReader != null) {
      throw const SevenZipException(
          'tar: an archive read as a stream can not be updated',
          SevenZipError.unsupported);
    }
    final to = timeOptions;
    final times = TarTimeOptions()
      ..numDigits = _timeDigits()
      ..writeMTime = to.writeMTime.def ? to.writeMTime.val : true
      ..writeATime = to.writeATime.def && to.writeATime.val
      ..writeCTime = to.writeCTime.def && to.writeCTime.val;
    var format = writeFormat;
    if (format == TarWriteFormat.gnu &&
        (times.writeATime || times.writeCTime || times.numDigits > 0)) {
      format = TarWriteFormat.pax;
    }
    final writer = TarWriter(outStream, format: format, times: times);
    final opCallback = updateCallback is ArchiveUpdateCallbackFile
        ? updateCallback as ArchiveUpdateCallbackFile
        : null;

    final infos = <UpdateItemInfo>[];
    var total = 0;
    for (var i = 0; i < numItems; i++) {
      final info = updateCallback.getUpdateItemInfo(i);
      infos.add(info);
      if (info.indexInArchive >= 0 &&
          (_stream == null || info.indexInArchive >= items.length)) {
        invalidArg('Bad index in archive');
      }
      if (info.newData) {
        final s = updateCallback.getProperty(i, Kpid.size);
        if (s is int) total += s;
      } else if (info.indexInArchive >= 0) {
        final it = items[info.indexInArchive];
        total += info.newProps ? it.packSizeAligned : it.endPos - it.headerPos;
      }
    }
    updateCallback.setTotal(total);

    var completed = 0;
    final buf = Uint8List(1 << 16);
    for (var i = 0; i < numItems; i++) {
      updateCallback.setCompleted(completed);
      final info = infos[i];
      if (!info.newData) {
        final it = items[info.indexInArchive];
        opCallback?.reportOperation(EventIndexType.inArcIndex,
            info.indexInArchive, UpdateNotifyOp.replicate);
        if (!info.newProps) {
          yield* _copyRangeSteps(writer, buf, it.headerPos, it.endPos);
          completed += it.endPos - it.headerPos;
          continue;
        }
        final oi = _outItemFromOld(it);
        final p = updateCallback.getProperty(i, Kpid.path);
        if (p is String) oi.name = _toUnixSlashes(p);
        if (it.sparse != null) {
          // written as a plain file of the expanded data
          oi.size = it.size;
          writer.writeHeader(oi);
          final src =
              _itemData(it, WindowInStream(_stream!, it.dataPos, it.packSize));
          yield* _copyDataSteps(writer, src, buf, (n) {});
        } else {
          writer.writeHeader(oi);
          if (writer.entryRemaining > 0) {
            yield* _copyDataSteps(writer,
                WindowInStream(_stream!, it.dataPos, it.packSize), buf, (n) {});
          }
        }
        writer.finishEntry();
        completed += it.packSizeAligned;
        continue;
      }

      // new data
      final oi = _outItemFromCallback(updateCallback, i);
      if (oi == null) continue;
      if (oi.isDir) {
        opCallback?.reportOperation(
            EventIndexType.outArcIndex, i, UpdateNotifyOp.add);
        writer.writeHeader(oi);
        writer.finishEntry();
        yield null;
        continue;
      }
      final stream = updateCallback.getStream(i);
      if (stream == null) continue; // S_FALSE: the item is left out
      try {
        if (oi.fileType == PosixMode.symLink && oi.symLink == null) {
          // the link target is the data (POSIX links stored by 7-Zip)
          final t = readAll(stream);
          oi.symLink = utf8.decode(t, allowMalformed: true);
          oi.size = 0;
        }
        if (oi.symLink != null || oi.hardLink != null) {
          oi.size = 0;
          writer.writeHeader(oi);
        } else {
          if (stream is StreamGetSize) {
            final sz = (stream as StreamGetSize).streamSize;
            if (sz != null) oi.size = sz;
          }
          writer.writeHeader(oi);
          final base = completed;
          yield* _copyDataSteps(writer, stream, buf,
              (n) => updateCallback.setCompleted(base + n));
          completed += oi.size;
        }
        writer.finishEntry();
      } finally {
        releaseStream(stream);
      }
      yield null;
      updateCallback.setOperationResult(0); // NUpdate::NOperationResult::kOK
    }
    writer.close();
    updateCallback.setCompleted(completed);
  }

  static String _toUnixSlashes(String s) => s.replaceAll('\\', '/');

  // copies the old archive bytes [from, to), zeros past its end; one step
  // per buffer
  Iterable<void> _copyRangeSteps(
      TarWriter w, Uint8List buf, int from, int to) sync* {
    final s = _stream!;
    s.position = from;
    var left = to - from;
    while (left > 0) {
      final want = left < buf.length ? left : buf.length;
      final n = s.read(buf, 0, want);
      if (n == 0) {
        final z = Uint8List(want);
        w.writeRaw(z, 0, want);
        left -= want;
        yield null;
        continue;
      }
      w.writeRaw(buf, 0, n);
      left -= n;
      yield null;
    }
  }

  static void _copyData(
      TarWriter w, InStream src, Uint8List buf, void Function(int) progress) {
    for (final _ in _copyDataSteps(w, src, buf, progress)) {}
  }

  // the data of an entry from [src]; one step per buffer
  static Iterable<void> _copyDataSteps(TarWriter w, InStream src,
      Uint8List buf, void Function(int) progress) sync* {
    var done = 0;
    while (w.entryRemaining > 0) {
      var want = w.entryRemaining;
      if (want > buf.length) want = buf.length;
      final n = src.read(buf, 0, want);
      if (n == 0) break;
      w.writeData(buf, 0, n);
      done += n;
      progress(done);
      yield null;
    }
  }

  static TarOutItem _outItemFromOld(TarItem it) {
    final t = it.typeFlag;
    return TarOutItem(it.name,
        symLink: it.isSymLink ? it.linkName : null,
        hardLink: it.isHardLink ? it.linkName : null,
        mode: it.mode & 0xFFF,
        fileType: it.fileType,
        size: it.isSymLink ? 0 : it.packSize,
        uid: it.uid,
        gid: it.gid,
        user: it.user,
        group: it.group,
        mTime: it.mTime,
        aTime: it.aTime,
        cTime: it.cTime,
        devMajor: it.devMajor < 0 ? 0 : it.devMajor,
        devMinor: it.devMinor < 0 ? 0 : it.devMinor)
      ..regularTypeFlag = it.sparse == null &&
              (t == TarType.regularOld || t == TarType.contiguous)
          ? t
          : null;
  }

  static TarTime? _timeProp(ArchiveUpdateCallback cb, int i, int propId) {
    final p = cb.getProperty(i, propId);
    if (p == null) return null;
    if (p is! int) invalidArg('Bad time property');
    final (s, ns) = fileTimeToTarTime(p);
    return TarTime(s, ns);
  }

  // the header fields of a new item from the update callback properties;
  // null for items that tar can not store (anti items)
  TarOutItem? _outItemFromCallback(ArchiveUpdateCallback cb, int i) {
    final anti = cb.getProperty(i, Kpid.isAnti);
    if (anti == true) return null;
    final pathProp = cb.getProperty(i, Kpid.path);
    if (pathProp is! String) invalidArg('Bad path property');
    var isDir = false;
    final dirProp = cb.getProperty(i, Kpid.isDir);
    if (dirProp is bool) isDir = dirProp;

    int? posix;
    final pa = cb.getProperty(i, Kpid.posixAttrib);
    if (pa is int) {
      posix = pa & 0xFFFF;
    } else {
      final a = cb.getProperty(i, Kpid.attrib);
      if (a is int) {
        if ((a & FileAttrib.unixExtension) != 0) {
          posix = (a >> 16) & 0xFFFF;
        } else {
          if ((a & FileAttrib.directory) != 0) isDir = true;
          posix = (a & FileAttrib.readOnly) != 0 ? 0x124 : 0x1A4; // 0444, 0644
          if (isDir) posix |= 0x49; // x bits
        }
      }
    }
    var fileType = posix != null ? posix & PosixMode.typeMask : 0;
    var mode = posix != null ? posix & 0xFFF : (isDir ? 0x1ED : 0x1A4);
    if (isDir) {
      fileType = PosixMode.directory;
    } else if (fileType == 0 || fileType == PosixMode.directory) {
      fileType = PosixMode.regular;
    }
    if (fileType == PosixMode.socket) fileType = PosixMode.regular;

    final item =
        TarOutItem(_toUnixSlashes(pathProp), mode: mode, fileType: fileType);
    final sl = cb.getProperty(i, Kpid.symLink);
    if (sl is String && sl.isNotEmpty && !isDir) {
      item.symLink = sl;
      item.fileType = PosixMode.symLink;
    }
    final hl = cb.getProperty(i, Kpid.hardLink);
    if (hl is String && hl.isNotEmpty && !isDir) {
      item.hardLink = _toUnixSlashes(hl);
      item.symLink = null;
      item.fileType = PosixMode.regular;
    }
    if (!isDir) {
      final s = cb.getProperty(i, Kpid.size);
      if (s is int) item.size = s;
    }
    item.mTime = _timeProp(cb, i, Kpid.mTime);
    item.aTime = _timeProp(cb, i, Kpid.aTime);
    item.cTime = _timeProp(cb, i, Kpid.cTime);
    final user = cb.getProperty(i, Kpid.user);
    if (user is String) item.user = user;
    final group = cb.getProperty(i, Kpid.group);
    if (group is String) item.group = group;
    final uid = cb.getProperty(i, Kpid.userId);
    if (uid is int && uid >= 0) item.uid = uid;
    final gid = cb.getProperty(i, Kpid.groupId);
    if (gid is int && gid >= 0) item.gid = gid;
    final dmaj = cb.getProperty(i, Kpid.deviceMajor);
    if (dmaj is int) item.devMajor = dmaj;
    final dmin = cb.getProperty(i, Kpid.deviceMinor);
    if (dmin is int) item.devMinor = dmin;
    return item;
  }
}

/// The data of an item as a random access stream (GetStream).
class _ItemInStream implements SeekableInStream {
  final SeekableInStream _base;
  final int _start;
  final int _size;
  int _pos = 0;
  _ItemInStream(this._base, this._start, this._size);

  @override
  int read(Uint8List buf, int off, int len) {
    final left = _size - _pos;
    if (left <= 0 || len <= 0) return 0;
    if (len > left) len = left;
    _base.position = _start + _pos;
    final n = _base.read(buf, off, len);
    _pos += n;
    return n;
  }

  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;
  @override
  int get length => _size;
}

/// The item data of an OpenSeq reader.
class _ReaderInStream implements InStream {
  final TarReader _r;
  _ReaderInStream(this._r);
  @override
  int read(Uint8List buf, int off, int len) => _r.readData(buf, off, len);
}

/// A tar archive in memory or in a stream, for library use: the items of
/// [TarHandler] with their properties, and [TarArchiveWriter] for writing.
class TarArchiveReader {
  final TarHandler handler = TarHandler();

  TarArchiveReader._();

  /// Opens a random access archive; throws [SevenZipException] (isNotArc)
  /// when it is not a tar archive.
  static TarArchiveReader open(SeekableInStream stream) {
    final r = TarArchiveReader._();
    if (!r.handler.open(stream)) {
      throw const SevenZipException(
          'Not a tar archive', SevenZipError.isNotArc);
    }
    return r;
  }

  List<TarItem> get items => handler.items;
}

/// Writes a tar archive to any [OutStream] (only sequential writes), for
/// example into a compressor: [add] each entry, then [close].
class TarArchiveWriter {
  final TarWriter _w;
  TarArchiveWriter(OutStream out,
      {TarWriteFormat format = TarWriteFormat.pax, TarTimeOptions? times})
      : _w = TarWriter(out, format: format, times: times);

  /// Writes [item] and, for a regular file, [item].size bytes of [data]
  /// (missing bytes are written as zeros).
  void add(TarOutItem item, [InStream? data]) {
    _w.writeHeader(item);
    if (data != null && _w.entryRemaining > 0) {
      TarHandler._copyData(_w, data, Uint8List(1 << 16), (n) {});
    }
    _w.finishEntry();
  }

  /// The end of archive marker; flushes [OutStream].
  void close() => _w.close();

  int get position => _w.position;
}
