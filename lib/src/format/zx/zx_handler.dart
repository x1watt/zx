// The .zx handler (not in 7-Zip): IInArchive and IOutArchive over the
// reader and writer of this folder, for the command line tool and
// ZxArchive (lib/src/cli/arc_zx.dart adapts it).
//
// Items are the entries of the generation shown (the last one, or the one
// set with the "version" property: a number or a date). With the
// "timeline" property the items are the versions of one path in every
// generation, with "generations" the generations themselves. Extraction
// decodes each block once, in worker isolates (sync_pool.dart), while the
// items that need it are written in order; damaged blocks only fail the
// items that use them. Updates append a generation: in place
// ([updateFile]), or after a copy of the old archive ([updateItems] into a
// new stream); "compact" rewrites the archive with the blocks of the last
// generations only.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../crypto/sha256.dart';
import '../../io/streams.dart';
import '../../pool.dart' show defaultThreads;
import '../../sync_pool.dart';
import '../../util/tlsh.dart';
import '../archive_types.dart';
import '../handler_out.dart' show getRamSize, parseSizeString;
import 'zx_blocks.dart';
import 'zx_codecs.dart';
import 'zx_crypto.dart';
import 'zx_dedup.dart' show zxMinChunkLog2, zxMaxChunkLog2;
import 'zx_format.dart';
import 'zx_lock.dart';
import 'zx_reader.dart';
import 'zx_writer.dart';

/// POSIX file type bits.
abstract final class _Ifmt {
  static const reg = 0x8000;
  static const dir = 0x4000;
  static const lnk = 0xA000;
  static const chr = 0x2000;
  static const blk = 0x6000;
  static const fifo = 0x1000;
  static const sock = 0xC000;
  static const mask = 0xF000;
}

int _typeBits(int kind) => switch (kind) {
      ZxKind.directory => _Ifmt.dir,
      ZxKind.symlink => _Ifmt.lnk,
      ZxKind.charDevice => _Ifmt.chr,
      ZxKind.blockDevice => _Ifmt.blk,
      ZxKind.fifo => _Ifmt.fifo,
      ZxKind.socket => _Ifmt.sock,
      _ => _Ifmt.reg,
    };

int _kindOfTypeBits(int t) => switch (t & _Ifmt.mask) {
      _Ifmt.dir => ZxKind.directory,
      _Ifmt.lnk => ZxKind.symlink,
      _Ifmt.chr => ZxKind.charDevice,
      _Ifmt.blk => ZxKind.blockDevice,
      _Ifmt.fifo => ZxKind.fifo,
      _Ifmt.sock => ZxKind.socket,
      _ => ZxKind.file,
    };

/// Opens the archive at [path] for an append in place. dart:io opens files
/// on Windows with FILE_SHARE_READ and FILE_SHARE_WRITE, so the reader of
/// this process (and other readers that share writing) do not block it; a
/// program holding the file without sharing writing (an antivirus, a
/// backup or indexing tool) makes it fail, and the update then writes the
/// archive again next to it and renames it ([zxReplaceFile]). A variable
/// so that tests can simulate a locked file.
RandomAccessFile Function(String path) zxOpenForAppend =
    (path) => File(path).openSync(mode: FileMode.append);

/// Replaces [to] by [from] (a rename over it; on Windows MoveFileEx with
/// MOVEFILE_REPLACE_EXISTING, which fails while another program holds
/// [to] without sharing deletion). A variable so that tests can simulate
/// a locked file.
void Function(String from, String to) zxReplaceFile =
    (from, to) => File(from).renameSync(to);

/// How often and how long [ZxHandler.updateFile] tries [zxReplaceFile]
/// (locks of scanners are short).
int zxReplaceTries = 20;
Duration zxReplaceWait = const Duration(milliseconds: 150);

/// The largest pipe [ZxHandler.openSeq] keeps in memory (16 MiB); a
/// longer one is copied to a temporary file.
int zxPipeMemory = 16 << 20;

/// How long an update or a compaction waits for the writer lock of an
/// archive (zx_lock.dart) held by a database writer.
int zxWriterLockWaitMs = 30000;

/// The writer lock of [path] for an update or a compaction of [r]: taken
/// when the archive has a database or its lock file exists (a database
/// writer may be at work); then the archive must still end where [r]
/// found its last Footer, else another writer appended a generation since
/// it was opened. Null when no lock is needed.
ZxWriteLock? zxLockForUpdate(String path, ZxArchiveReader r) {
  if (r.lastIndex.database == null &&
      !File(ZxWriteLock.lockPathOf(path)).existsSync()) {
    return null;
  }
  final lock = ZxWriteLock.acquire(path, waitMs: zxWriterLockWaitMs);
  try {
    if (!r.header.multiVolume && zxChangedSince(path, r.validEnd)) {
      throw const SevenZipException(
          'zx: the archive was changed by another writer after it was '
          'opened; open it again',
          SevenZipError.io);
    }
  } catch (_) {
    lock.release();
    rethrow;
  }
  return lock;
}

/// Whether the file at [path] holds a generation after [validEnd] (or was
/// replaced by a shorter one): its last 32 bytes are a valid Footer past
/// [validEnd]. Bytes after [validEnd] without a Footer are an interrupted
/// update.
bool zxChangedSince(String path, int validEnd) {
  final f = File(path).openSync();
  try {
    final len = f.lengthSync();
    if (len < validEnd) return true;
    if (len == validEnd) return false;
    if (len - zxFooterSize < validEnd) return false;
    f.setPositionSync(len - zxFooterSize);
    final b = f.readSync(zxFooterSize);
    return ZxFooter.tryParse(b, 0) != null;
  } finally {
    f.closeSync();
  }
}

/// One version of a path in the timeline (section 9.1.1).
class ZxTimelineVersion {
  final String path;

  /// The generation that wrote this version, and its time (ns since 1970).
  final int generation;
  final int time;
  final int size;
  final Uint8List? sha256;

  /// The generation in which this version was replaced or deleted, and
  /// whether it was deleted (not replaced); null while it is current.
  final int? endGeneration;
  final int? endTime;
  final bool deleted;
  final ZxEntry entry;
  const ZxTimelineVersion(this.path, this.generation, this.time, this.size,
      this.sha256, this.endGeneration, this.endTime, this.deleted, this.entry);
}

/// How the items are shown.
enum ZxListMode { entries, timeline, generations }

/// The -m settings of the zx handler.
class ZxHandlerOptions {
  final ZxWriteOptions write = ZxWriteOptions();
  ZxGenerationSelector? generation;
  String? timeline;
  bool listGenerations = false;
  final List<String> searchDirs = [];

  /// Compact after the update: keep this many generations (null: no).
  int? compactKeep;

  /// A pipe (openSeq) is read in one pass, every version of every
  /// generation in stream order (-mpipe=onepass), instead of being copied
  /// to a temporary file first and read as a file (-mpipe=spool, the
  /// default: the state of the last or of the chosen generation).
  bool pipeOnePass = false;

  /// Where a pipe is copied (null: the system's temporary folder).
  String? pipeTempDir;
  int? threads;

  /// The memory the block workers may use together, when reading and
  /// writing (-mmemuse; null: [zxDefaultMemoryLimit]).
  int? memoryLimit;
  bool methodSet = false;
  final List<String> _filters = [];
  final Map<int, String> _methods = {};
}

class _Cache {
  final Uint8List data;
  int uses;
  _Cache(this.data, this.uses);
}

/// The zx handler.
class ZxHandler {
  ZxArchiveReader? _r;
  ZxSeqReader? _seq;
  final ZxHandlerOptions options = ZxHandlerOptions();
  ZxListMode _mode = ZxListMode.entries;
  List<ZxTimelineVersion> _timeline = const [];
  List<ZxGeneration> _genItems = const [];
  String? Function()? _password;
  String? _archivePath;
  SeekableInStream? _seqStream;
  String? _seqWarning;
  // the entries of the pipe or damaged file that are items (null: every
  // inline entry, in stream order), and notes of the pass that found them
  List<int>? _seqItems;
  final List<String> _seqNotes = [];
  // a pipe copied to a temporary folder (deleted by close)
  FileInStream? _spoolFile;
  Directory? _spoolDir;
  bool _fromPipe = false;
  int _phySize = 0;
  int _totalSize = 0;

  ZxArchiveReader? get reader => _r;

  /// The path of the file opened (for volumes and in place updates).
  String? get archivePath => _archivePath;

  List<ZxEntry> get _entries => _r?.index.entries ?? _seq?.entries ?? const [];

  // the inline entry of item [i] of a sequential read
  int _seqEntryOf(int i) {
    final m = _seqItems;
    return m == null ? i : (i >= 0 && i < m.length ? m[i] : -1);
  }

  /// IInArchive::Open. [path] is the file's full path when known;
  /// [password] is asked when the Index is encrypted.
  bool open(SeekableInStream stream,
      {String? path, String? Function()? password}) {
    close();
    _archivePath = path;
    _password = password;
    ZxArchiveReader? r;
    try {
      r = ZxArchiveReader.open(
          stream,
          ZxOpenParams(
              path: path,
              searchDirs: options.searchDirs,
              password: password,
              generation: options.generation));
    } on SevenZipException catch (e) {
      // a streamed file without a valid Index: its inline records give the
      // entries (read in one pass)
      if (e.kind != SevenZipError.headers) rethrow;
      final h = ZxArchiveReader.readHeader(stream);
      if (h == null || !h.streamed || options.generation != null) rethrow;
      stream.position = 0;
      _seq = ZxSeqReader.open(stream, password: password);
      _seqStream = stream;
      _seqWarning = 'zx: the Index is damaged or missing: the entries are '
          'read from the inline records';
      return _seq != null;
    }
    if (r == null) return false;
    _r = r;
    // the file opened (a volume of a set counts alone, as ArchiveLink
    // compares it with the file)
    _phySize = stream.length;
    _totalSize = _phySize;
    if (r.header.multiVolume) {
      _totalSize = 0;
      for (final n in r.volumes.numbers) {
        try {
          _totalSize += r.volumes.lengthOf(n);
        } on SevenZipException {
          // missing
        }
      }
    }
    final t = options.timeline;
    if (t != null) {
      _mode = ZxListMode.timeline;
      _timeline = timeline(t);
    } else if (options.listGenerations) {
      _mode = ZxListMode.generations;
      _genItems = r.generations;
    }
    return true;
  }

  /// IArchiveOpenSeq::OpenSeq (a pipe). By default the input is copied to
  /// a temporary file (in memory up to [zxPipeMemory]) and opened as a
  /// file: the
  /// items are the entries of the last generation (or of -mversion), so
  /// entries deleted or replaced by a later generation are not extracted.
  /// A one pass reader can not know that before the end of the input,
  /// since a generation never changes the bytes of the earlier ones
  /// (docs/zx-format.md, section 8.1). With [ZxHandlerOptions.pipeOnePass]
  /// a streamed file is read in one pass without a copy: every version of
  /// every generation in stream order.
  bool openSeq(InStream stream, {String? Function()? password}) {
    close();
    if (options.pipeOnePass) {
      if (options.generation != null) {
        throw const SevenZipException(
            'zx: -mversion needs the whole input (not -mpipe=onepass)',
            SevenZipError.unsupported);
      }
      final s = ZxSeqReader.open(stream, password: password);
      if (s == null) return false;
      _seq = s;
      return true;
    }
    final (sp, file, dir) = _spool(stream);
    try {
      if (!open(sp, password: password)) {
        _dropSpool(file, dir);
        return false;
      }
    } catch (_) {
      _dropSpool(file, dir);
      rethrow;
    }
    _spoolFile = file;
    _spoolDir = dir;
    _fromPipe = true;
    return true;
  }

  // copies a pipe: in memory up to zxPipeMemory bytes, else to a
  // temporary file
  (SeekableInStream, FileInStream?, Directory?) _spool(InStream s) {
    final inMemory = zxPipeMemory;
    final got = BytesBuilder(copy: false);
    final buf = Uint8List(1 << 20);
    var end = false;
    while (got.length < inMemory) {
      var want = inMemory - got.length;
      if (want > buf.length) want = buf.length;
      final k = readFully(s, buf, 0, want);
      if (k > 0) got.add(Uint8List.fromList(Uint8List.sublistView(buf, 0, k)));
      if (k < want) {
        end = true;
        break;
      }
    }
    if (end) return (MemoryInStream(got.takeBytes()), null, null);
    final head = got.takeBytes();
    final n = head.length;
    final base = options.pipeTempDir;
    final dir = (base == null ? Directory.systemTemp : Directory(base))
        .createTempSync('zx-pipe-');
    final path = '${dir.path}${Platform.pathSeparator}input.zx';
    try {
      final out = File(path).openSync(mode: FileMode.write);
      try {
        out.writeFromSync(head, 0, n);
        for (;;) {
          final k = s.read(buf, 0, buf.length);
          if (k <= 0) break;
          out.writeFromSync(buf, 0, k);
        }
      } finally {
        out.closeSync();
      }
      final f = FileInStream.open(path);
      return (f, f, dir);
    } catch (_) {
      _dropSpool(null, dir);
      rethrow;
    }
  }

  static void _dropSpool(FileInStream? f, Directory? dir) {
    try {
      f?.close();
    } on FileSystemException {
      // ignore
    }
    try {
      dir?.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  }

  void close() {
    _r?.close();
    _r = null;
    _seq = null;
    _seqStream = null;
    _seqWarning = null;
    _seqItems = null;
    _seqNotes.clear();
    _fromPipe = false;
    if (_spoolFile != null || _spoolDir != null) {
      _dropSpool(_spoolFile, _spoolDir);
      _spoolFile = null;
      _spoolDir = null;
    }
    _mode = ZxListMode.entries;
    _timeline = const [];
    _genItems = const [];
  }

  int get numberOfItems {
    switch (_mode) {
      case ZxListMode.timeline:
        return _timeline.length;
      case ZxListMode.generations:
        return _genItems.length;
      case ZxListMode.entries:
        final s = _seq;
        if (s != null) {
          s.readAllRecords();
          // a complete pass: the items are the current entries (a one pass
          // extraction already gave every version)
          if (_seqItems == null && !s.extracted) {
            _seqItems = s.currentEntries();
          }
          return _seqItems?.length ?? s.entries.length;
        }
        return _entries.length;
    }
  }

  static const List<int> itemPropIds = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.aTime,
    Kpid.attrib,
    Kpid.posixAttrib,
    Kpid.user,
    Kpid.group,
    Kpid.userId,
    Kpid.groupId,
    Kpid.symLink,
    Kpid.hardLink,
    Kpid.encrypted,
    Kpid.method,
    Kpid.block,
    Kpid.sha256,
    ZxKpid.tlsh,
    ZxKpid.version,
    ZxKpid.deletedIn,
    Kpid.comment,
  ];

  static const List<int> archivePropIds = [
    Kpid.totalPhySize,
    Kpid.method,
    Kpid.solid,
    Kpid.numBlocks,
    Kpid.numVolumes,
    Kpid.encrypted,
    Kpid.comment,
    ZxKpid.numVersions,
    ZxKpid.version,
    ZxKpid.wasted,
    ZxKpid.minReader,
  ];

  // ---- properties

  static int? _ft(int? ns) => ns == null ? null : zxFileTimeOfNs(ns);

  int? _posix(ZxEntry e) {
    final m = e.mode;
    if (m == null) return null;
    return _typeBits(e.kind) | (m & 0xFFF);
  }

  int? _attrib(ZxEntry e) {
    final w = e.winAttrib;
    if (w != null) return w | (e.isDir ? FileAttrib.directory : 0);
    final p = _posix(e);
    if (p != null) {
      return (p << 16) |
          FileAttrib.unixExtension |
          (e.isDir ? FileAttrib.directory : 0);
    }
    return e.isDir ? FileAttrib.directory : null;
  }

  int _dataSize(ZxEntry e) => e.kind == ZxKind.symlink
      ? utf8.encode(e.linkTarget ?? '').length
      : e.size;

  int? _packSizeOf(ZxEntry e) {
    final r = _r;
    if (r == null || e.extents.isEmpty) return e.kind == ZxKind.file ? 0 : null;
    var p = 0.0;
    final idx = r.index;
    for (var i = 0; i < e.extents.length; i += 3) {
      final b = e.extents[i];
      if (b >= idx.blocks.length) continue;
      final ref = idx.blocks[b];
      if (ref.unpackedSize == 0) continue;
      p += e.extents[i + 2] * ref.totalSize / ref.unpackedSize;
    }
    return p.round();
  }

  Object? getProperty(int index, int propId) {
    switch (_mode) {
      case ZxListMode.timeline:
        return _timelineProp(index, propId);
      case ZxListMode.generations:
        return _generationProp(index, propId);
      case ZxListMode.entries:
        break;
    }
    final s = _seq;
    if (s != null) {
      index = _seqEntryOf(index);
      if (index < 0 || !s.ensureEntry(index)) return null;
    }
    final list = _entries;
    if (index < 0 || index >= list.length) return null;
    final e = list[index];
    switch (propId) {
      case Kpid.path:
        return e.path;
      case Kpid.isDir:
        return e.isDir;
      case Kpid.size:
        return e.isDir ? null : _dataSize(e);
      case Kpid.packSize:
        return e.isDir ? null : _packSizeOf(e);
      case Kpid.mTime:
        return _ft(e.mTime);
      case Kpid.cTime:
        return _ft(e.birthTime);
      case Kpid.aTime:
        return _ft(e.aTime);
      case Kpid.changeTime:
        return _ft(e.cTime);
      case Kpid.attrib:
        return _attrib(e);
      case Kpid.posixAttrib:
        return _posix(e);
      case Kpid.user:
        return e.user;
      case Kpid.group:
        return e.group;
      case Kpid.userId:
        return e.uid;
      case Kpid.groupId:
        return e.gid;
      case Kpid.symLink:
        return e.kind == ZxKind.symlink ? e.linkTarget : null;
      case Kpid.hardLink:
        return e.kind == ZxKind.hardlink ? e.linkTarget : null;
      case Kpid.deviceMajor:
        return e.devMajor;
      case Kpid.deviceMinor:
        return e.devMinor;
      case Kpid.encrypted:
        final h = _r?.header ?? _seq?.header;
        return h?.kdf != null && e.kind == ZxKind.file;
      case Kpid.method:
        final r = _r;
        if (r == null || e.extents.isEmpty) return null;
        return r.methodOf(r.index,
            [for (var i = 0; i < e.extents.length; i += 3) e.extents[i]]);
      case Kpid.block:
        return e.extents.isEmpty ? null : e.extents[0];
      case Kpid.sha256:
        final h = e.sha256;
        return h == null ? null : zxHex(h);
      case ZxKpid.tlsh:
        return e.tlsh;
      case ZxKpid.version:
        return e.since;
      case Kpid.comment:
        return e.comment;
    }
    return null;
  }

  Object? _timelineProp(int index, int propId) {
    if (index < 0 || index >= _timeline.length) return null;
    final v = _timeline[index];
    switch (propId) {
      case Kpid.path:
        return v.path;
      case Kpid.isDir:
        return v.entry.isDir;
      case Kpid.size:
        return v.entry.isDir ? null : v.size;
      case Kpid.mTime:
        // the date of the generation that wrote this version
        return _ft(v.time);
      case Kpid.sha256:
        final h = v.sha256;
        return h == null ? null : zxHex(h);
      case ZxKpid.version:
        return v.generation;
      case ZxKpid.deletedIn:
        return v.deleted ? v.endGeneration : null;
      case Kpid.comment:
        final sb = StringBuffer('generation ${v.generation}');
        if (v.endGeneration != null) {
          sb.write(v.deleted
              ? ', deleted in generation ${v.endGeneration}'
              : ', replaced in generation ${v.endGeneration}');
        }
        return sb.toString();
      case Kpid.attrib:
        return _attrib(v.entry);
    }
    return null;
  }

  Object? _generationProp(int index, int propId) {
    if (index < 0 || index >= _genItems.length) return null;
    final g = _genItems[index];
    switch (propId) {
      case Kpid.path:
        return 'generation ${g.number}';
      case Kpid.isDir:
        return false;
      case Kpid.mTime:
        return _ft(g.time);
      case ZxKpid.version:
        return g.number;
      case Kpid.comment:
        return g.comment.isEmpty ? null : g.comment;
    }
    return null;
  }

  Object? getArchiveProperty(int propId) {
    final r = _r;
    final h = r?.header ?? _seq?.header;
    switch (propId) {
      case Kpid.phySize:
        // a pipe has no size to compare with (as the one pass reader)
        return r == null || _fromPipe ? null : _phySize;
      case Kpid.totalPhySize:
        return r == null || !r.header.multiVolume ? null : _totalSize;
      case Kpid.method:
        if (r == null) return null;
        return r.methodOf(
            r.index, [for (var i = 0; i < r.index.blocks.length; i++) i]);
      case Kpid.solid:
        return r == null
            ? null
            : ((r.index.requiredFeatures | r.header.required) &
                    ZxFeature.solid) !=
                0;
      case Kpid.numBlocks:
        return r?.index.blocks.length;
      case Kpid.numVolumes:
        return r != null && r.header.multiVolume ? r.volumes.count : null;
      case Kpid.encrypted:
        return h?.kdf != null;
      case Kpid.comment:
        return h?.comment;
      case ZxKpid.numVersions:
        return r?.generations.length;
      case ZxKpid.version:
        return r?.shownGeneration;
      case ZxKpid.wasted:
        return r?.wastedBytes();
      case ZxKpid.minReader:
        final v = r?.index.minReaderVersion ?? h?.minReaderVersion;
        return v == null ? null : zxVersionText(v);
      case Kpid.warning:
        final w = [
          ...?r?.warnings,
          if (_seqWarning != null) _seqWarning!,
          ..._seqNotes,
          ...?_seq?.warnings,
        ];
        return w.isEmpty ? null : w.join('\n');
      case Kpid.errorFlags:
        return null;
    }
    return null;
  }

  // ---- extraction

  /// IInArchive::Extract. [password] gives the password of encrypted data.
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb,
      {String? Function()? password}) {
    var s = _seq;
    if (s != null) {
      final ss = _seqStream;
      final pw = password ?? _password;
      if (ss != null) {
        // a file: the records first (the current entries), then a new pass
        // for the data
        if (_seqItems == null) {
          ss.position = 0;
          final r0 = ZxSeqReader.open(ss, password: pw)!;
          r0.readAllRecords();
          _seqItems = r0.currentEntries();
          _seqNotes.addAll(r0.warnings);
        }
        ss.position = 0;
        s = ZxSeqReader.open(ss, password: pw)!;
        _seq = s;
      }
      _extractSeq(s, _seqItems, indices, testMode, cb);
      return;
    }
    final r = _r!;
    if (_mode != ZxListMode.entries) {
      // the timeline and the generation list are listings only
      final ix = indices ?? [for (var i = 0; i < numberOfItems; i++) i];
      for (final i in ix) {
        cb.getStream(i, testMode ? AskMode.test : AskMode.extract);
        cb.prepareOperation(testMode ? AskMode.test : AskMode.extract);
        cb.setOperationResult(OperationResult.unsupportedMethod);
      }
      return;
    }
    final list = r.index.entries;
    final ix = indices ?? [for (var i = 0; i < list.length; i++) i];
    var total = 0;
    for (final i in ix) {
      total += _dataSize(list[i]);
    }
    cb.setTotal(total);

    // the keys of encrypted data
    var keyError = OperationResult.ok;
    if (r.header.kdf != null) {
      try {
        r.keysFor(password ?? _password);
      } on ZxNeedPasswordException {
        keyError = OperationResult.wrongPassword;
      } on SevenZipException catch (e) {
        keyError = e.kind == SevenZipError.wrongPassword
            ? OperationResult.wrongPassword
            : OperationResult.unsupportedMethod;
      }
    }

    // the blocks in the order the items need them, with their use counts
    final uses = <int, int>{};
    final order = <int>[];
    for (final i in ix) {
      final e = list[i];
      for (var k = 0; k < e.extents.length; k += 3) {
        final b = e.extents[k];
        final u = uses[b];
        if (u == null) order.add(b);
        uses[b] = (u ?? 0) + 1;
      }
    }
    final threads = options.threads ?? defaultThreads();
    final pool = SyncJobPool(order.length > 1 ? threads : 1);
    final cache = <int, _Cache>{};
    final errors = <int, SevenZipException>{};
    final tickets = <int, int>{};
    var next = 0;
    // the memory guard: the decoders in flight together stay under the
    // limit (one is always allowed); the estimate comes from each block's
    // chain (the zcm budget and the PPMd size are in its props)
    final memLimit = options.memoryLimit ?? zxDefaultMemoryLimit();
    final memOf = <int, int>{};
    var memInFlight = 0;
    int estimate(int b) {
      final ref = r.index.blocks[b];
      final id = ref.chainId;
      final chain = id == 0 ? const ZxChain(0, []) : r.index.chains[id];
      return chain == null ? 0 : zxDecodeMemory(chain, ref.unpackedSize);
    }

    // [force]: the next block is needed now (submitted whatever its size)
    void submitAhead({bool force = false}) {
      while (next < order.length && pool.inFlight < pool.threads) {
        final b = order[next];
        final m = b < r.index.blocks.length ? estimate(b) : 0;
        if (!force && pool.inFlight > 0 && memInFlight + m > memLimit) break;
        force = false;
        next++;
        try {
          tickets[b] = pool.submit(zxDecodeBlockJob, r.decodeArg(r.index, b));
          memOf[b] = m;
          memInFlight += m;
        } on SevenZipException catch (e) {
          errors[b] = e;
        }
      }
    }

    // the blocks are needed in [order]: when an item asks for one, the
    // earlier ones were taken already
    Uint8List? block(int b) {
      final c = cache[b];
      if (c != null) return c.data;
      if (errors.containsKey(b)) return null;
      var t = tickets.remove(b);
      if (t == null) {
        submitAhead(force: next < order.length && order[next] == b);
        t = tickets.remove(b);
      }
      if (t == null) return null;
      memInFlight -= memOf.remove(b) ?? 0;
      try {
        final d = pool.take(t).data;
        cache[b] = _Cache(d, uses[b] ?? 1);
        return d;
      } on SevenZipException catch (e) {
        errors[b] = e;
        return null;
      } finally {
        submitAhead();
      }
    }

    void release(int b) {
      final c = cache[b];
      if (c != null && --c.uses <= 0) cache.remove(b);
    }

    var done = 0;
    try {
      if (keyError == OperationResult.ok) submitAhead();
      for (final i in ix) {
        final e = list[i];
        var askMode = testMode ? AskMode.test : AskMode.extract;
        final out = cb.getStream(i, askMode);
        if (!testMode && out == null && !e.isDir) askMode = AskMode.skip;
        cb.prepareOperation(askMode);
        if (e.unsupported != null) {
          // its blocks are taken all the same (the jobs of the pool)
          for (var k = 0; k < e.extents.length; k += 3) {
            block(e.extents[k]);
            release(e.extents[k]);
          }
          cb.setOperationResult(OperationResult.unsupportedMethod);
          continue;
        }
        if (e.kind == ZxKind.symlink) {
          final t = Uint8List.fromList(utf8.encode(e.linkTarget ?? ''));
          out?.write(t, 0, t.length);
          out?.flush();
          cb.setOperationResult(OperationResult.ok);
          continue;
        }
        if (e.kind != ZxKind.file) {
          cb.setOperationResult(OperationResult.ok);
          continue;
        }
        if (keyError != OperationResult.ok && e.extents.isNotEmpty) {
          cb.setOperationResult(keyError);
          continue;
        }
        var res = OperationResult.ok;
        final sha = e.sha256 != null ? Sha256() : null;
        final sparse = e.sparse;
        var written = 0;
        for (var k = 0; k < e.extents.length; k += 3) {
          final b = e.extents[k];
          final data = block(b);
          if (res != OperationResult.ok) {
            release(b);
            continue;
          }
          if (data == null) {
            if (res == OperationResult.ok) {
              final err = errors[b];
              res = err == null ? OperationResult.dataError : _opResultOf(err);
            }
            release(b);
            continue;
          }
          final off = e.extents[k + 1], len = e.extents[k + 2];
          if (off + len > data.length) {
            res = OperationResult.dataError;
            release(b);
            continue;
          }
          if (sparse == null) {
            out?.write(data, off, len);
          }
          sha?.update(data, off, len);
          written += len;
          release(b);
          done += len;
          cb.setCompleted(done);
        }
        if (sparse != null && res == OperationResult.ok) {
          // the data ranges, zeros between them
          res = _writeSparse(e, out, this, r, written);
        }
        out?.flush();
        if (res == OperationResult.ok && sha != null && sparse == null) {
          if (!_same(sha.digest(), e.sha256!)) res = OperationResult.crcError;
        }
        cb.setOperationResult(res);
      }
    } finally {
      pool.close();
    }
  }

  static int _opResultOf(SevenZipException e) => switch (e.kind) {
        SevenZipError.crc => OperationResult.crcError,
        SevenZipError.unsupportedMethod ||
        SevenZipError.unsupported =>
          OperationResult.unsupportedMethod,
        SevenZipError.unavailable => OperationResult.unavailable,
        SevenZipError.unexpectedEnd => OperationResult.unexpectedEnd,
        SevenZipError.wrongPassword => OperationResult.wrongPassword,
        _ => OperationResult.dataError,
      };

  // a sparse file: the extents hold the data ranges; the rest is zeros
  static int _writeSparse(
      ZxEntry e, OutStream? out, ZxHandler h, ZxArchiveReader r, int dataLen) {
    final s = h.getStream(h._entries.indexOf(e));
    if (s == null) return OperationResult.dataError;
    final buf = Uint8List(1 << 16);
    var left = e.size;
    try {
      while (left > 0) {
        final n = s.read(buf, 0, left < buf.length ? left : buf.length);
        if (n == 0) return OperationResult.unexpectedEnd;
        out?.write(buf, 0, n);
        left -= n;
      }
    } on SevenZipException catch (x) {
      return _opResultOf(x);
    }
    return OperationResult.ok;
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // [items]: the inline entries that are items (null: all of them, in one
  // pass); [indices]: the items wanted (null: all)
  void _extractSeq(ZxSeqReader s, List<int>? items, List<int>? indices,
      bool testMode, ArchiveExtractCallback cb) {
    final itemOf = items == null
        ? null
        : {for (var k = 0; k < items.length; k++) items[k]: k};
    final want = indices?.toSet();
    final buf = Uint8List(1 << 16);
    for (var j = 0;; j++) {
      if (want != null && want.isEmpty) break;
      if (itemOf != null && itemOf.isEmpty) break;
      if (!s.ensureEntry(j)) break;
      final i = itemOf == null ? j : itemOf.remove(j);
      if (i == null || (want != null && !want.remove(i))) {
        s.skipData(j);
        continue;
      }
      final e = s.entries[j];
      var askMode = testMode ? AskMode.test : AskMode.extract;
      final out = cb.getStream(i, askMode);
      if (!testMode && out == null && !e.isDir) askMode = AskMode.skip;
      cb.prepareOperation(askMode);
      var res = OperationResult.ok;
      try {
        if (e.kind == ZxKind.symlink) {
          final t = Uint8List.fromList(utf8.encode(e.linkTarget ?? ''));
          out?.write(t, 0, t.length);
        } else if (e.kind == ZxKind.file) {
          final sha = Sha256();
          for (;;) {
            final n = s.readData(j, buf, 0, buf.length);
            if (n == 0) break;
            sha.update(buf, 0, n);
            out?.write(buf, 0, n);
          }
          s.shaOf[j] = sha.digest();
        }
      } on SevenZipException catch (x) {
        res = _opResultOf(x);
      }
      out?.flush();
      try {
        s.skipData(j);
      } on SevenZipException catch (x) {
        if (res == OperationResult.ok) res = _opResultOf(x);
      }
      cb.setOperationResult(res);
    }
    if (items == null) {
      // one pass: every version was given; say what the last generation
      // changed
      s.extracted = true;
      s.readAllRecords();
      if (s.generations > 1) {
        final cur = s.currentEntries().length;
        final old = s.entries.length - cur;
        if (old > 0) {
          s.warnings.add('zx: the input holds ${s.generations} generations '
              'read in one pass (-mpipe=onepass): $old entr'
              '${old == 1 ? 'y' : 'ies'} replaced or deleted by a later '
              'generation were extracted too');
        }
      }
    }
  }


  // ---- random access

  /// The data of item [index] as a random access stream, decoded a block at
  /// a time; null for items without data.
  SeekableInStream? getStream(int index) {
    final r = _r;
    if (r == null || _mode != ZxListMode.entries) return null;
    final list = r.index.entries;
    if (index < 0 || index >= list.length) return null;
    final e = list[index];
    if (e.kind != ZxKind.file || e.unsupported != null) return null;
    if (r.header.kdf != null) {
      try {
        r.keysFor(_password);
      } on SevenZipException {
        return null;
      }
    }
    return ZxEntryStream(r, r.index, e);
  }

  // ---- timeline

  /// Every distinct version of [path] (different SHA-256) across the
  /// generations, oldest first (section 9.1.1).
  List<ZxTimelineVersion> timeline(String path) {
    final r = _r;
    if (r == null) return const [];
    final gens = r.generations;
    final p = _normPath(path);
    final byNumber = {for (var i = 0; i < gens.length; i++) gens[i].number: i};
    final out = <ZxTimelineVersion>[]; // newest first
    // walk back from the last generation; a version whose entry says it
    // was written in generation s (attribute 0x76) stayed the same from s
    // on, so the generations between are skipped
    var gi = gens.length - 1;
    while (gi >= 0) {
      final g = gens[gi];
      ZxEntry? e;
      for (final x in r.indexOf(g).entries) {
        if (x.path == p) e = x;
      }
      if (e == null) {
        gi--;
        continue;
      }
      var si = byNumber[e.since ?? g.number] ?? gi;
      if (si > gi) si = gi;
      final start = gens[si];
      final after = gi + 1 < gens.length ? gens[gi + 1] : null;
      final later = out.isEmpty ? null : out.last;
      final replaced = after != null && later?.generation == after.number;
      if (replaced &&
          later!.sha256 != null &&
          e.sha256 != null &&
          _same(later.sha256!, e.sha256!)) {
        // the same content written again: one version
        out[out.length - 1] = ZxTimelineVersion(
            p,
            start.number,
            start.time,
            e.size,
            e.sha256,
            later.endGeneration,
            later.endTime,
            later.deleted,
            later.entry);
      } else {
        out.add(ZxTimelineVersion(p, start.number, start.time, e.size, e.sha256,
            after?.number, after?.time, after != null && !replaced, e));
      }
      gi = si - 1;
    }
    return out.reversed.toList();
  }

  static String _normPath(String p) {
    var s = p.replaceAll('\\', '/');
    while (s.startsWith('./')) {
      s = s.substring(2);
    }
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    while (s.endsWith('/') && s.length > 1) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  // ---- lookups

  /// The entries (of the generation shown) whose content has the SHA-256
  /// [sha256], by the lookup table (binary search) when present.
  List<int> findBySha256(Uint8List sha256) {
    final r = _r;
    if (r == null) return const [];
    final t = r.index.shaTable;
    if (t == null) {
      return [
        for (var i = 0; i < r.index.entries.length; i++)
          if (r.index.entries[i].sha256 != null &&
              _same(r.index.entries[i].sha256!, sha256))
            i
      ];
    }
    int cmp(Uint8List a) {
      for (var k = 0; k < 32; k++) {
        final d = a[k] - sha256[k];
        if (d != 0) return d;
      }
      return 0;
    }

    var lo = 0, hi = t.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cmp(t[mid].$1) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final out = <int>[];
    for (var i = lo; i < t.length && cmp(t[i].$1) == 0; i++) {
      out.add(t[i].$2);
    }
    return out;
  }

  /// The entries whose TLSH digest is within [maxDistance] of [digest],
  /// nearest first, as (entry number, distance).
  List<(int, int)> findSimilar(String digest, {int maxDistance = 100}) {
    final r = _r;
    if (r == null) return const [];
    final list = r.index.tlshList ??
        [
          for (var i = 0; i < r.index.entries.length; i++)
            if (r.index.entries[i].tlsh != null) (r.index.entries[i].tlsh!, i)
        ];
    final out = <(int, int)>[];
    for (final (t, n) in list) {
      final d = tlshDistance(digest, t);
      if (d != null && d <= maxDistance) out.add((n, d));
    }
    out.sort((a, b) => a.$2 != b.$2 ? a.$2 - b.$2 : a.$1 - b.$1);
    return out;
  }

  // ---- ISetProperties

  void setProperties(List<MapEntry<String, PropVariant>> props) {
    final o = options;
    final w = o.write;
    var level = -1;
    for (final p in props) {
      final name = p.key.toLowerCase();
      final v = p.value;
      String str() => v.vt == VarType.bstr
          ? v.stringValue
          : (v.vt == VarType.ui4 || v.vt == VarType.ui8 ? '${v.intValue}' : '');
      bool flag() {
        if (v.vt == VarType.empty) return true;
        if (v.vt == VarType.bool_) return v.boolValue;
        final s = str().toLowerCase();
        if (s == '' || s == 'on' || s == '+' || s == 'true') return true;
        if (s == 'off' || s == '-' || s == 'false') return false;
        invalidArg('zx: bad value for ${p.key}');
      }

      if (name == 'version' || name == 'ver' || name == 'gen') {
        o.generation = ZxGenerationSelector.parse(str());
        continue;
      }
      if (name == 'timeline') {
        final t = str();
        if (t.isEmpty) invalidArg('zx: -mtimeline needs a path');
        o.timeline = t;
        continue;
      }
      if (name == 'generations' || name == 'gens') {
        o.listGenerations = flag();
        continue;
      }
      if (name == 'compact') {
        final s = str();
        if (s.isEmpty || s.toLowerCase() == 'on') {
          o.compactKeep = 1;
        } else {
          final n = int.tryParse(s);
          if (n == null || n < 1) invalidArg('zx: -mcompact=N needs N >= 1');
          o.compactKeep = n;
        }
        continue;
      }
      if (name == 'pipe') {
        o.pipeOnePass = switch (str().toLowerCase()) {
          '' || 'spool' || 'temp' => false,
          'onepass' || 'stream' => true,
          _ => invalidArg('zx: -mpipe=spool|onepass'),
        };
        continue;
      }
      if (name == 'pipetemp' || name == 'pipetmp') {
        final d = str();
        if (d.isEmpty) invalidArg('zx: -mpipetemp needs a folder');
        o.pipeTempDir = d;
        continue;
      }
      if (name == 'vsearch') {
        o.searchDirs.addAll(str().split(';').where((s) => s.isNotEmpty));
        continue;
      }
      if (name == 'vdir') {
        for (final d in str().split(';')) {
          if (d.isNotEmpty) w.volumeDirs.add(ZxVolumeDir.parse(d));
        }
        continue;
      }
      if (name == 'vsizes' || name == 'v') {
        for (final s in str().split(',')) {
          final n = zxParseSize(s);
          if (n == null || n <= 0) invalidArg('zx: bad volume size $s');
          w.volumeSizes.add(n);
        }
        continue;
      }
      if (name.startsWith('x')) {
        level = parsePropToUInt32(name.substring(1), v, 5);
        if (level > 9) level = 9;
        continue;
      }
      if (name.startsWith('mt')) {
        final t = parsePropToUInt32(name.substring(2), v, defaultThreads());
        o.threads = t < 1 ? 1 : t;
        continue;
      }
      if (name == 'bs' || name == 'block') {
        final n = zxParseSize(str());
        if (n == null || n < zxMinWriteBlockSize || n > zxMaxWriteBlockSize) {
          invalidArg('zx: the block size must be 4k to 64m');
        }
        w.blockSize = n;
        continue;
      }
      if (name == 's') {
        final s = str().toLowerCase();
        if (s == '' || s == 'on' || s == '+') {
          w.solid = true;
        } else if (s == 'off' || s == '-') {
          w.solid = false;
        } else {
          final n = zxParseSize(s);
          if (n == null) invalidArg('zx: -ms=on|off|<block size>');
          w.solid = true;
          if (n < zxMinWriteBlockSize || n > zxMaxWriteBlockSize) {
            invalidArg('zx: the block size must be 4k to 64m');
          }
          w.blockSize = n;
        }
        continue;
      }
      if (name == 'check' || name == 'crc') {
        w.checkType = switch (str().toLowerCase()) {
          'none' || 'off' => ZxCheck.none,
          'crc32c' || 'crc32' || 'crc' => ZxCheck.crc32c,
          'xxh64' || 'xxhash64' || 'xxhash' || '' => ZxCheck.xxh64,
          'sha256' || 'sha-256' => ZxCheck.sha256,
          'blake2sp' || 'blake2' => ZxCheck.blake2sp,
          _ => invalidArg('zx: -mcheck=none|crc32c|xxh64|sha256|blake2sp'),
        };
        continue;
      }
      if (name == 'he') {
        w.encryptMetadata = flag();
        continue;
      }
      if (name == 'kdf' || name == 'scrypt') {
        final n = parsePropToUInt32('', v, zxDefaultScryptLog2N);
        if (n < 10 || n > 22) invalidArg('zx: -mkdf=10..22 (log2 of N)');
        w.scryptLog2N = n;
        continue;
      }
      if (name == 'stream' || name == 'streamed') {
        w.streamed = flag();
        continue;
      }
      if (name == 'tlsh') {
        w.tlsh = flag();
        continue;
      }
      if (name == 'hashtable' || name == 'shatable') {
        w.hashTable = flag();
        continue;
      }
      if (name == 'gc' || name == 'gcomment') {
        w.generationComment = str();
        continue;
      }
      if (name == 'comment' || name == 'cm') {
        w.archiveComment = str();
        continue;
      }
      if (name == 'f' || name == 'filter') {
        final s = str();
        if (s.toLowerCase() == 'off' || s == '-') {
          o._filters.clear();
        } else {
          o._filters.add(s);
        }
        continue;
      }
      if (name == 'm' || RegExp(r'^\d+$').hasMatch(name)) {
        final i = name == 'm' ? 0 : int.parse(name);
        o._methods[i] = str();
        o.methodSet = true;
        continue;
      }
      if (name.startsWith('memuse')) {
        final m = parseSizeString(
            name.substring(6), v, getRamSize() ?? zxDefaultMemoryLimit());
        if (m == null || m <= 0) {
          invalidArg('zx: -mmemuse=SIZE (4g, 512m) or p<percent of the RAM>');
        }
        o.memoryLimit = m;
        w.memoryLimit = m;
        continue;
      }
      if (name == 'dedup') {
        final s = str().toLowerCase();
        if (s == '' || s == 'on' || s == '+' || s == 'true') {
          w.dedup = true;
        } else if (s == 'off' || s == '-' || s == 'false') {
          w.dedup = false;
        } else {
          w.dedup = true;
          w.chunkLog2 = _chunkLog2(s);
        }
        continue;
      }
      if (name == 'chunk' || name == 'dedupchunk') {
        w.chunkLog2 = _chunkLog2(str());
        continue;
      }
      if (name == 'tm' ||
          name == 'tc' ||
          name == 'ta' ||
          name == 'hc' ||
          name == 'qs') {
        continue;
      }
      invalidArg('zx: unknown property ${p.key}');
    }
    if (level >= 0) w.level = level;
    // the chain: -mf filters, then -m0, -m1... in writing order
    final coders = <ZxCoderSpec>[];
    for (final f in o._filters) {
      final c = zxParseCoder(f, w.level);
      if (!(zxCodecById(c.codecId)?.isFilter ?? false)) {
        invalidArg('zx: $f is not a filter');
      }
      coders.add(c);
    }
    final keys = o._methods.keys.toList()..sort();
    for (final k in keys) {
      final m = o._methods[k]!;
      if (m.toLowerCase() == 'store' || m.toLowerCase() == 'copy') continue;
      coders.add(zxParseCoder(m, w.level));
    }
    if (o._methods.isEmpty) {
      coders.add(ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: w.level)));
    }
    w.coders = coders;
    if (o._methods.values.any(
            (m) => m.toLowerCase() == 'store' || m.toLowerCase() == 'copy') &&
        coders.every((c) => zxCodecById(c.codecId)?.isFilter ?? false)) {
      w.coders = coders;
      if (coders.isEmpty) w.level = 0;
    }
    if (o.threads != null) {
      w.threads = o.threads!;
      w.threadsExplicit = true;
    }
    w.codersSet = o.methodSet || o._filters.isNotEmpty;
  }

  // the average chunk size of -mdedup=SIZE and -mchunk=SIZE: a power of
  // two from 4k to 4m (other sizes are rounded down)
  static int _chunkLog2(String s) {
    final n = zxParseSize(s);
    if (n == null || n < (1 << zxMinChunkLog2) || n > (1 << zxMaxChunkLog2)) {
      invalidArg('zx: the dedup chunk size must be 4k to 4m');
    }
    var l = 0;
    while ((2 << l) <= n) {
      l++;
    }
    return l;
  }

  // ---- update

  /// IOutArchive::UpdateItems into a new stream [out]: a new archive, or
  /// the old one copied and a generation appended (not for volume sets).
  void updateItems(OutStream out, int numItems, ArchiveUpdateCallback cb,
      {String? newPassword}) {
    final r = _r;
    final o = options.write;
    if (out is! SeekableOutStream) o.streamed = true;
    if (r == null) {
      final wr = ZxWriter.create(
          _withPassword(o, newPassword), (h) => ZxStreamSink(out));
      _feed(wr, null, numItems, cb);
      wr.finish();
      return;
    }
    if (r.header.multiVolume) {
      throw const SevenZipException(
          'zx: a volume set is updated in place', SevenZipError.unsupported);
    }
    _checkLatest(r);
    // copy the old archive up to its last valid Footer
    final src = r.volumes.stream(0);
    src.position = 0;
    copyStream(src, out, limit: r.validEnd);
    final wr = ZxWriter.append(
        r,
        _withPassword(o, newPassword ?? _password?.call()),
        ZxStreamSink(out, r.validEnd));
    _feed(wr, r, numItems, cb);
    wr.finish();
  }

  ZxWriteOptions _withPassword(ZxWriteOptions o, String? pw) {
    if (pw != null && pw.isNotEmpty) o.password = pw;
    return o;
  }

  void _checkLatest(ZxArchiveReader r) {
    if (!r.isLatest) {
      throw const SevenZipException(
          'zx: the archive is open as of an older generation (-mversion) '
          'and can not be updated',
          SevenZipError.unsupported);
    }
  }

  /// Writes the update of [path] itself: a new archive (a file or, with
  /// volume sizes, a set), or a generation appended in place (after the
  /// last valid Footer; a volume set gets new volumes). Returns the files
  /// written. [onFile] sees each new file first.
  ///
  /// When the file can not be opened for appending (another program holds
  /// it), the archive is written again as `path.zx-part` (its bytes up to
  /// the last valid Footer, then the new generation, the same bytes an
  /// append gives) and renamed over [path]; [releaseInput] closes the
  /// caller's handle of the archive first (Windows does not rename a file
  /// that is open without sharing deletion, as dart:io opens files).
  ZxUpdateFileResult updateFile(
      String path, int numItems, ArchiveUpdateCallback cb,
      {List<int> volumeSizes = const [],
      String? newPassword,
      void Function(String path)? onFile,
      void Function()? releaseInput}) {
    final o = _withPassword(options.write, newPassword);
    if (volumeSizes.isNotEmpty) o.volumeSizes = volumeSizes;
    final r = _r;
    ZxWriteResult res;
    final written = <String>[];
    if (r == null) {
      if (o.volumeSizes.isNotEmpty) {
        final base =
            path.endsWith('.001') ? path.substring(0, path.length - 4) : path;
        ZxVolumeSink? vs;
        final wr = ZxWriter.create(o, (h) {
          return vs = ZxVolumeSink(base, o.volumeSizes, o.volumeDirs, h,
              firstVolume: 0, onFile: onFile);
        });
        try {
          _feed(wr, null, numItems, cb);
          res = wr.finish();
        } catch (_) {
          wr.abort();
          vs?.abort();
          rethrow;
        }
        written.addAll(res.volumes);
      } else {
        onFile?.call(path);
        final f = FileOutStream.create(path);
        try {
          final wr = ZxWriter.create(o, (h) => ZxStreamSink(f));
          try {
            _feed(wr, null, numItems, cb);
            res = wr.finish();
          } catch (_) {
            wr.abort();
            rethrow;
          }
          f.flush();
        } finally {
          f.close();
        }
        written.add(path);
      }
    } else {
      _checkLatest(r);
      final lock = zxLockForUpdate(path, r);
      try {
        res = _updateExisting(path, r, o, numItems, cb, written,
            onFile: onFile, releaseInput: releaseInput);
      } finally {
        lock?.release();
      }
    }
    return ZxUpdateFileResult(written, res, o.warnings);
  }

  // the update of an existing archive (under the writer lock when needed)
  ZxWriteResult _updateExisting(String path, ZxArchiveReader r,
      ZxWriteOptions o, int numItems, ArchiveUpdateCallback cb,
      List<String> written,
      {void Function(String path)? onFile, void Function()? releaseInput}) {
    ZxWriteResult res;
    {
      // new data uses the key of the archive: its password
      if (r.header.kdf != null && r.keys == null) {
        o.password ??= _password?.call();
      }
      if (r.header.multiVolume) {
        // new volumes after the last one; the old ones are not touched
        final lastPath = r.volumes.pathOf(r.lastVolume) ?? path;
        final m = RegExp(r'^(.*)\.(\d{3,})$').firstMatch(lastPath);
        final base = m != null ? m[1]! : lastPath;
        final sizes = o.volumeSizes.isNotEmpty
            ? o.volumeSizes
            : [
                for (final v in r.lastIndex.volumes ?? const <ZxVolumeInfo>[])
                  if (v.size > 0) v.size
              ];
        if (sizes.isEmpty) sizes.add(r.volumes.lengthOf(r.lastVolume));
        ZxVolumeSink? vs;
        final header = r.header;
        final wr = ZxWriter.append(r, o, _LazySink(() {
          return vs = ZxVolumeSink(base, sizes, o.volumeDirs, header,
              firstVolume: r.lastVolume + 1,
              earlier: [
                for (final v in r.lastIndex.volumes ?? const <ZxVolumeInfo>[])
                  if (v.number < r.lastVolume) v,
                ZxVolumeInfo(
                    r.lastVolume,
                    (r.volumes.pathOf(r.lastVolume) ?? lastPath)
                        .split(Platform.pathSeparator)
                        .last,
                    r.volumes.lengthOf(r.lastVolume),
                    zxFileXxh64(r.volumes.pathOf(r.lastVolume) ?? lastPath)),
              ],
              onFile: onFile);
        }));
        try {
          _feed(wr, r, numItems, cb);
          res = wr.finish();
        } catch (_) {
          wr.abort();
          vs?.abort();
          rethrow;
        }
        written.addAll(res.volumes);
      } else {
        FileOutStream f;
        try {
          f = _openAppend(path, r.validEnd);
        } on FileSystemException catch (e) {
          return _appendByRewrite(path, r, o, numItems, cb, e,
              onFile: onFile, releaseInput: releaseInput);
        }
        try {
          final wr = ZxWriter.append(r, o, ZxStreamSink(f, r.validEnd));
          try {
            _feed(wr, r, numItems, cb);
            res = wr.finish();
          } catch (_) {
            wr.abort();
            rethrow;
          }
          f.flush();
        } finally {
          f.close();
        }
      }
    }
    return res;
  }

  // the archive opened for an append at [end]: garbage after the last
  // valid Footer (an interrupted update) is cut
  static FileOutStream _openAppend(String path, int end) {
    final raf = zxOpenForAppend(path);
    try {
      final f = FileOutStream(raf);
      if (f.length > end) f.truncate(end);
      f.position = end;
      return f;
    } catch (_) {
      try {
        raf.closeSync();
      } on FileSystemException {
        // ignore
      }
      rethrow;
    }
  }

  // the append when the file can not be opened for writing: the archive
  // up to its last valid Footer and the new generation go into
  // path.zx-part, which then replaces the archive (tried a few times, as
  // the program holding the file may let it go)
  ZxWriteResult _appendByRewrite(String path, ZxArchiveReader r,
      ZxWriteOptions o, int numItems, ArchiveUpdateCallback cb,
      FileSystemException why,
      {void Function(String path)? onFile, void Function()? releaseInput}) {
    final tmp = '$path.zx-part';
    onFile?.call(tmp);
    ZxWriteResult res;
    final f = FileOutStream.create(tmp);
    try {
      final src = r.volumes.stream(0);
      src.position = 0;
      copyStream(src, f, limit: r.validEnd);
      final wr = ZxWriter.append(r, o, ZxStreamSink(f, r.validEnd));
      try {
        _feed(wr, r, numItems, cb);
        res = wr.finish();
      } catch (_) {
        wr.abort();
        rethrow;
      }
      f.flush();
    } catch (_) {
      _closeQuietly(f);
      _deleteQuietly(tmp);
      rethrow;
    }
    f.close();
    // the handles of the old file go first (a rename over an open file
    // fails on Windows)
    r.close();
    _r = null;
    releaseInput?.call();
    FileSystemException? last;
    for (var i = 0; i < zxReplaceTries; i++) {
      try {
        zxReplaceFile(tmp, path);
        last = null;
        break;
      } on FileSystemException catch (e) {
        last = e;
        if (i + 1 < zxReplaceTries) sleep(zxReplaceWait);
      }
    }
    if (last != null) {
      _deleteQuietly(tmp);
      throw SevenZipException(
          'zx: the archive is locked by another program and was not '
          'changed (${last.osError?.message ?? last.message})',
          SevenZipError.io);
    }
    o.warnings.add('zx: the archive could not be opened for appending '
        '(${why.osError?.message ?? why.message}): it was written again '
        'and renamed');
    return res;
  }

  static void _closeQuietly(FileOutStream f) {
    try {
      f.close();
    } on Object {
      // closed
    }
  }

  static void _deleteQuietly(String p) {
    try {
      File(p).deleteSync();
    } on FileSystemException {
      // ignore
    }
  }

  // feeds the items of the update callback to the writer
  void _feed(
      ZxWriter wr, ZxArchiveReader? r, int numItems, ArchiveUpdateCallback cb) {
    final opCb = cb is ArchiveUpdateCallbackFile
        ? cb as ArchiveUpdateCallbackFile
        : null;
    final old = r?.lastIndex.entries ?? const <ZxEntry>[];
    var total = 0;
    final infos = <UpdateItemInfo>[];
    for (var i = 0; i < numItems; i++) {
      final info = cb.getUpdateItemInfo(i);
      infos.add(info);
      if (info.newData) {
        final s = cb.getProperty(i, Kpid.size);
        if (s is int) total += s;
      }
      if (!info.newData &&
          (info.indexInArchive < 0 || info.indexInArchive >= old.length)) {
        invalidArg('Bad index in archive');
      }
    }
    cb.setTotal(total);
    var completed = 0;
    for (var i = 0; i < numItems; i++) {
      final info = infos[i];
      if (!info.newData) {
        final e = old[info.indexInArchive];
        opCb?.reportOperation(EventIndexType.inArcIndex, info.indexInArchive,
            UpdateNotifyOp.replicate);
        if (info.newProps) {
          final c = e.copy();
          final p = cb.getProperty(i, Kpid.path);
          if (p is String) {
            final np = _normPath(p);
            if (np != c.path) {
              c.path = np;
              c.since = wr.generation;
            }
          }
          wr.addKept(c);
        } else {
          wr.addKept(e);
        }
        continue;
      }
      if (cb.getProperty(i, Kpid.isAnti) == true) continue;
      final meta = _entryFromCallback(cb, i);
      opCb?.reportOperation(EventIndexType.outArcIndex, i,
          meta.kind == ZxKind.file ? UpdateNotifyOp.add : UpdateNotifyOp.add);
      if (meta.kind == ZxKind.directory ||
          meta.kind == ZxKind.hardlink ||
          meta.kind == ZxKind.charDevice ||
          meta.kind == ZxKind.blockDevice ||
          meta.kind == ZxKind.fifo ||
          meta.kind == ZxKind.socket) {
        wr.addNew(meta, null);
        cb.setOperationResult(0);
        continue;
      }
      final stream = cb.getStream(i);
      if (stream == null) continue; // S_FALSE: left out
      try {
        if (meta.kind == ZxKind.symlink) {
          meta.linkTarget ??=
              utf8.decode(readAll(stream), allowMalformed: true);
          wr.addNew(meta, null);
        } else {
          final known = cb.getProperty(i, Kpid.size);
          final progress = _ProgressIn(stream, (n) {
            cb.setCompleted(completed + n);
          });
          final n =
              wr.addNew(meta, progress, knownSize: known is int ? known : null);
          completed += n;
        }
      } finally {
        releaseStream(stream);
      }
      cb.setOperationResult(0);
      cb.setCompleted(completed);
    }
  }

  ZxEntry _entryFromCallback(ArchiveUpdateCallback cb, int i) {
    final pathProp = cb.getProperty(i, Kpid.path);
    if (pathProp is! String) invalidArg('Bad path property');
    final path = _normPath(pathProp);
    if (!zxIsValidPath(path)) invalidArg('zx: bad path "$pathProp"');
    var isDir = cb.getProperty(i, Kpid.isDir) == true;
    int? posix;
    int? win;
    final pa = cb.getProperty(i, Kpid.posixAttrib);
    final a = cb.getProperty(i, Kpid.attrib);
    if (pa is int) {
      posix = pa & 0xFFFF;
    } else if (a is int) {
      if ((a & FileAttrib.unixExtension) != 0) {
        posix = (a >> 16) & 0xFFFF;
      } else {
        win = a & ~FileAttrib.directory;
        if ((a & FileAttrib.directory) != 0) isDir = true;
      }
    }
    var kind = ZxKind.file;
    if (isDir) {
      kind = ZxKind.directory;
    } else if (posix != null) {
      kind = _kindOfTypeBits(posix);
      if (kind == ZxKind.directory) kind = ZxKind.file;
    }
    final sl = cb.getProperty(i, Kpid.symLink);
    final hl = cb.getProperty(i, Kpid.hardLink);
    String? target;
    if (!isDir && hl is String && hl.isNotEmpty) {
      kind = ZxKind.hardlink;
      target = _normPath(hl);
    } else if (!isDir && sl is String && sl.isNotEmpty) {
      kind = ZxKind.symlink;
      target = sl;
    }
    final e = ZxEntry(path, kind);
    e.linkTarget = target;
    if (posix != null) e.mode = posix & 0xFFF;
    if (win != null && win != 0) e.winAttrib = win;
    int? t(int id) {
      final v = cb.getProperty(i, id);
      return v is int && v != 0 ? zxNsOfFileTime(v) : null;
    }

    e.mTime = t(Kpid.mTime);
    e.aTime = t(Kpid.aTime);
    e.birthTime = t(Kpid.cTime);
    e.cTime = t(Kpid.changeTime);
    final user = cb.getProperty(i, Kpid.user);
    if (user is String && user.isNotEmpty) e.user = user;
    final group = cb.getProperty(i, Kpid.group);
    if (group is String && group.isNotEmpty) e.group = group;
    final uid = cb.getProperty(i, Kpid.userId);
    if (uid is int && uid >= 0) e.uid = uid;
    final gid = cb.getProperty(i, Kpid.groupId);
    if (gid is int && gid >= 0) e.gid = gid;
    final dmaj = cb.getProperty(i, Kpid.deviceMajor);
    final dmin = cb.getProperty(i, Kpid.deviceMinor);
    if (dmaj is int) e.devMajor = dmaj;
    if (dmin is int) e.devMinor = dmin;
    final c = cb.getProperty(i, Kpid.comment);
    if (c is String && c.isNotEmpty) e.comment = c;
    return e;
  }

  // ---- compaction

  // the options of the repacking: the -m settings, with the threads
  // and the memory limit
  ZxWriteOptions _compactOptions() {
    final w = options.write;
    if (options.threads != null) w.threads = options.threads!;
    if (options.memoryLimit != null) w.memoryLimit = options.memoryLimit;
    return w;
  }

  /// Rewrites the archive at [path] (the file opened) keeping the blocks of
  /// the last [keep] generations; returns the bytes freed. A volume set is
  /// written again with the same volume sizes (or [volumeSizes]).
  int compact(String path, int keep,
      {List<int> volumeSizes = const [],
      String? password,
      void Function(String path)? onFile}) {
    final r = _r;
    if (r == null) throw StateError('not open');
    final lock = zxLockForUpdate(path, r);
    try {
      return _compact(path, r, keep,
          volumeSizes: volumeSizes, password: password, onFile: onFile);
    } finally {
      lock?.release();
    }
  }

  int _compact(String path, ZxArchiveReader r, int keep,
      {List<int> volumeSizes = const [],
      String? password,
      void Function(String path)? onFile}) {
    final pw = password ?? _password?.call();
    final before = r.header.multiVolume ? _totalSize : _phySize;
    if (!r.header.multiVolume) {
      final tmp = '$path.zx-compact';
      onFile?.call(tmp);
      final f = FileOutStream.create(tmp);
      try {
        zxCompact(r, keep, (h) => ZxStreamSink(f),
            password: pw, options: _compactOptions());
        f.flush();
      } catch (_) {
        f.close();
        try {
          File(tmp).deleteSync();
        } on FileSystemException {
          // ignore
        }
        rethrow;
      } finally {
        try {
          f.close();
        } on Object {
          // closed
        }
      }
      final after = File(tmp).lengthSync();
      r.close();
      File(tmp).renameSync(path);
      _r = null;
      return before - after;
    }
    // a volume set: new volumes with temporary names, then renamed
    final oldPaths = r.volumes.paths;
    final lastPath = r.volumes.pathOf(r.lastVolume) ?? path;
    final m = RegExp(r'^(.*)\.(\d{3,})$').firstMatch(lastPath);
    final base = m != null ? m[1]! : lastPath;
    final sizes = volumeSizes.isNotEmpty
        ? volumeSizes
        : options.write.volumeSizes.isNotEmpty
            ? options.write.volumeSizes
            : [
                for (final v in r.lastIndex.volumes ?? const <ZxVolumeInfo>[])
                  if (v.size > 0) v.size
              ];
    if (sizes.isEmpty) sizes.add(1 << 40);
    final tmpBase = '$base.zx-compact';
    ZxVolumeSink? vs;
    ZxWriteResult res;
    try {
      res = zxCompact(r, keep, (h) {
        return vs = ZxVolumeSink(tmpBase, sizes, options.write.volumeDirs, h,
            firstVolume: 0, onFile: onFile);
      }, password: pw, multi: true, options: _compactOptions());
    } catch (_) {
      vs?.abort();
      rethrow;
    }
    var after = 0;
    for (final p in res.volumes) {
      after += File(p).lengthSync();
    }
    r.close();
    _r = null;
    for (final p in oldPaths) {
      try {
        File(p).deleteSync();
      } on FileSystemException {
        // ignore
      }
    }
    for (final p in res.volumes) {
      final np = p.replaceFirst('.zx-compact.', '.');
      File(p).renameSync(np);
    }
    return before - after;
  }
}

/// The files an update wrote.
class ZxUpdateFileResult {
  final List<String> files;
  final ZxWriteResult result;
  final List<String> warnings;
  const ZxUpdateFileResult(this.files, this.result, this.warnings);
}

// a sink made on first use (the volumes of an append start only when the
// first byte is written)
class _LazySink implements ZxSink {
  final ZxSink Function() make;
  ZxSink? _s;
  _LazySink(this.make);
  ZxSink get s => _s ??= make();
  @override
  int get volume => s.volume;
  @override
  int get position => s.position;
  @override
  bool get multi => true;
  @override
  int? get room => s.room;
  @override
  int? get emptyRoom => s.emptyRoom;
  @override
  void write(Uint8List b) => s.write(b);
  @override
  void nextVolume() => s.nextVolume();
  @override
  List<ZxVolumeInfo> volumeTable() => s.volumeTable();
  @override
  List<String> close() => s.close();
}

// reports the bytes read
class _ProgressIn implements InStream {
  final InStream base;
  final void Function(int n) onRead;
  int _n = 0;
  int _next = 1 << 20;
  _ProgressIn(this.base, this.onRead);
  @override
  int read(Uint8List buf, int off, int len) {
    final n = base.read(buf, off, len);
    _n += n;
    if (_n >= _next) {
      _next = _n + (1 << 20);
      onRead(_n);
    }
    return n;
  }
}

/// The data of an entry, decoded a block at a time.
class ZxEntryStream implements SeekableInStream {
  final ZxArchiveReader r;
  final ZxIndex idx;
  final ZxEntry e;
  int _pos = 0;
  int _cachedBlock = -1;
  Uint8List? _cache;
  // start of each extent in the entry's data
  final Int64List _starts;

  ZxEntryStream(this.r, this.idx, this.e)
      : _starts = Int64List(e.numExtents + 1) {
    var p = 0;
    for (var i = 0; i < e.numExtents; i++) {
      _starts[i] = p;
      p += e.extents[3 * i + 2];
    }
    _starts[e.numExtents] = p;
  }

  int get _dataLen => _starts[e.numExtents];

  @override
  int get length => e.size;
  @override
  int get position => _pos;
  @override
  set position(int v) => _pos = v;

  // the data byte at [p] of the extents (without the sparse map)
  int _readData(int p, Uint8List buf, int off, int len) {
    if (p >= _dataLen) return 0;
    var lo = 0, hi = e.numExtents - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_starts[mid] <= p) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final b = e.extents[3 * lo];
    final bo = e.extents[3 * lo + 1];
    final el = e.extents[3 * lo + 2];
    final inExt = p - _starts[lo];
    if (_cachedBlock != b) {
      _cache = r.readBlock(idx, b);
      _cachedBlock = b;
    }
    var n = el - inExt;
    if (n > len) n = len;
    buf.setRange(off, off + n, _cache!, bo + inExt);
    return n;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (_pos >= e.size || len <= 0) return 0;
    if (_pos + len > e.size) len = e.size - _pos;
    final sp = e.sparse;
    if (sp == null) {
      final n = _readData(_pos, buf, off, len);
      _pos += n;
      return n;
    }
    // sparse: find the range holding _pos
    var dataOff = 0;
    for (var i = 0; i < sp.length; i += 2) {
      final start = sp[i], l = sp[i + 1];
      if (_pos < start) {
        final z = start - _pos < len ? start - _pos : len;
        buf.fillRange(off, off + z, 0);
        _pos += z;
        return z;
      }
      if (_pos < start + l) {
        var k = start + l - _pos;
        if (k > len) k = len;
        final n = _readData(dataOff + (_pos - start), buf, off, k);
        _pos += n;
        return n;
      }
      dataOff += l;
    }
    final z = len;
    buf.fillRange(off, off + z, 0);
    _pos += z;
    return z;
  }
}

// ---------------------------------------------------------------------------
// sequential reading of streamed files (section 8)

/// Reads a streamed file in one pass (a pipe): the inline records give
/// the entries and where their data starts (a block number and an offset),
/// the data blocks follow in order. After a damaged block the reader scans
/// for the next block marker with a valid header CRC (section 4.1); the
/// entries whose data was in the lost part fail, the next inline records
/// place the following ones again.
///
/// An appended file holds its generations one after the other, and the
/// inline records of a generation are only its new or changed entries
/// (section 8.1): the reader numbers the generations by their Footers and
/// decodes the Index blocks it meets, so that after a complete pass
/// [currentEntries] gives the state of the last generation (the last
/// version of each path, without the deleted ones).
class ZxSeqReader {
  final InStream _s;
  final ZxHeader header;
  final String? Function()? _password;
  ZxKeys? _keys;
  final Map<int, ZxChain> _chains = {};
  final List<ZxEntry> entries = [];

  /// The generation of each entry, counted from 1 in stream order (the
  /// Footers passed plus 1).
  final List<int> entryGeneration = [];

  /// The Footers passed, the last Index decoded and the Footers passed
  /// before it (its generation is that count plus 1).
  int footers = 0;
  ZxIndex? lastIndex;
  int _lastIndexAt = -1;
  final List<Uint8List> _indexParts = [];

  /// SHA-256 of the entries extracted.
  final Map<int, Uint8List> shaOf = {};

  /// Messages about the damage found.
  final List<String> warnings = [];

  // bytes read ahead (a resynchronization looks at them again)
  final List<int> _back = [];

  // the data block in hand and its number (-1: none; -2: unknown)
  Uint8List? _blk;
  int _blkNo = -1;
  int _blkPos = 0;
  // the number of the next data block (null: unknown after damage)
  int? _nextNo = 0;
  bool _end = false;

  // the entry whose data is read, and its bytes left (-1: until the next
  // metadata block)
  int _cur = -1;
  int _left = 0;
  bool _failed = false;

  ZxSeqReader._(this._s, this.header, this._password);

  static ZxSeqReader? open(InStream s, {String? Function()? password}) {
    final fixed = Uint8List(zxHeaderFixedSize);
    if (readFully(s, fixed, 0, zxHeaderFixedSize) != zxHeaderFixedSize) {
      return null;
    }
    if (!ZxHeader.hasMagic(fixed)) return null;
    final rs = getUint32LE(fixed, 56);
    if (rs > 1 << 24) zxDamaged('bad header size');
    final rec = Uint8List(rs);
    readExactly(s, rec, 0, rs);
    final h = ZxHeader.decode(fixed, rec);
    if (!h.streamed) {
      throw const SevenZipException(
          'zx: this archive was not written in streamed mode and can not be '
          'read in one pass',
          SevenZipError.unsupported);
    }
    return ZxSeqReader._(s, h, password);
  }

  ZxKeys? _getKeys() {
    if (_keys != null) return _keys;
    final kdf = header.kdf;
    if (kdf == null) return null;
    final pw = _password?.call();
    if (pw == null) throw const ZxNeedPasswordException();
    final k = zxCheckPassword(pw, kdf);
    if (k == null) {
      throw const SevenZipException(
          'zx: wrong password', SevenZipError.wrongPassword);
    }
    return _keys = k;
  }

  // reads [n] bytes (the read ahead first); fewer at the end
  int _read(Uint8List b, int off, int n) {
    var done = 0;
    while (done < n && _back.isNotEmpty) {
      b[off + done++] = _back.removeAt(0);
    }
    if (done < n) done += readFully(_s, b, off + done, n - done);
    return done;
  }

  // the next block's header and payload: (header, raw bytes), a Footer
  // (null, empty), or null at the end; damaged parts are skipped
  (ZxBlockHeader?, Uint8List)? _readRaw() {
    final b4 = Uint8List(4);
    var n = _read(b4, 0, 4);
    if (n == 0) return null;
    var resynced = false;
    for (;;) {
      if (n < 4) return null;
      final word = getUint32LE(b4, 0);
      if (word == zxBlockMarker) {
        // the header size, the fields and the CRC
        final head = Uint8List(4 + 10 + 256 + 4);
        head.setRange(0, 4, b4);
        var got = 4 + _read(head, 4, 10);
        final r = ZxRead(head, 4, got);
        int? hs;
        try {
          hs = r.vint();
        } on SevenZipException {
          hs = null;
        }
        if (hs != null && hs <= 256) {
          final need = r.pos + hs + 4;
          if (need > got) got += _read(head, got, need - got);
          final h = ZxBlockHeader.tryParse(head, 0, got);
          if (h != null && h.packedSize <= zxMaxBlockSize) {
            // the bytes read past the header belong to the payload
            final extra = got - h.headerSize;
            final raw = Uint8List(h.headerSize + h.packedSize);
            raw.setRange(0, h.headerSize, head);
            var have = h.headerSize;
            if (extra > 0) {
              final k = extra < h.packedSize ? extra : h.packedSize;
              raw.setRange(have, have + k, head, h.headerSize);
              have += k;
              for (var i = h.headerSize + k; i < got; i++) {
                _back.add(head[i]);
              }
            }
            if (_read(raw, have, raw.length - have) != raw.length - have) {
              warnings.add('zx: the last block is cut');
              return null;
            }
            if (resynced) _resynced();
            return (h, raw);
          }
        }
        // not a valid header: look again from the next byte
        for (var i = 4; i < got; i++) {
          _back.add(head[i]);
        }
      } else if (getUint32LE(b4, 0) != zxBlockMarker && !resynced) {
        // a Footer?
        final f = Uint8List(32);
        f.setRange(0, 4, b4);
        final k = _read(f, 4, 28);
        if (k == 28 && ZxFooter.tryParse(f, 0) != null) {
          return (null, Uint8List(0));
        }
        for (var i = 4; i < 4 + k; i++) {
          _back.add(f[i]);
        }
      }
      // damage: move one byte and look for the marker
      if (!resynced) {
        resynced = true;
        warnings.add('zx: damaged data skipped (resynchronized at the '
            'next block)');
      }
      b4.setRange(0, 3, b4, 1);
      final one = Uint8List(1);
      if (_read(one, 0, 1) == 0) return null;
      b4[3] = one[0];
      n = 4;
    }
  }

  // after damage: the data in hand and the current entry are lost
  void _resynced() {
    _nextNo = null;
    _blk = null;
    _blkNo = -2;
    if (_cur >= 0 && (_left != 0)) _failed = true;
  }

  // reads the next block (or Footer); false at the end of the input
  bool _nextBlock() {
    if (_end) return false;
    final x = _readRaw();
    if (x == null) {
      _end = true;
      if (_left < 0) _left = 0;
      return false;
    }
    final (h, raw) = x;
    if (h == null) {
      // a Footer: the end of a generation, with its Index just before
      if (_left < 0) _left = 0;
      _endGeneration();
      return true;
    }
    switch (h.type) {
      case ZxBlockType.meta:
        Uint8List data;
        try {
          final chain = ZxArchiveReader.metaChainOf(header, h.chainId);
          final k = header.encryptedMetadata ? _getKeys() : null;
          data = zxDecodeBlock(ZxDecodeArg(raw, chain, k?.aesKey, k?.macKey));
        } on ZxNeedPasswordException {
          rethrow;
        } on SevenZipException catch (e) {
          if (e.kind == SevenZipError.wrongPassword) rethrow;
          warnings.add('zx: damaged inline records skipped');
          _resynced();
          return true;
        }
        var hadEntry = false;
        for (final rec in zxRecords(data)) {
          if (rec.type == ZxRec.chain) {
            final c = ZxChain.read(ZxRead(rec.payload));
            _chains[c.id] = c;
          } else if (rec.type == ZxRec.entry) {
            final e = ZxEntry.decode(rec.payload, inline: true);
            entries.add(e);
            entryGeneration.add(footers + 1);
            hadEntry = true;
            if (e.extents.isNotEmpty && _nextNo == null) {
              _nextNo = e.extents[0];
            }
          }
        }
        // an entry without size ends where the next entries start
        if (_left < 0 && hadEntry) _left = 0;
        return true;
      case ZxBlockType.data:
      case ZxBlockType.solid:
      case ZxBlockType.chunks:
        final no = _nextNo;
        _blkNo = no ?? -2;
        _nextNo = no == null ? null : no + 1;
        final id = h.chainId;
        final chain = id == 0 ? const ZxChain(0, []) : _chains[id];
        try {
          if (chain == null) zxDamaged('undeclared chain $id');
          final k = header.kdf != null ? _getKeys() : null;
          _blk = zxDecodeBlock(ZxDecodeArg(raw, chain, k?.aesKey, k?.macKey));
        } on ZxNeedPasswordException {
          rethrow;
        } on SevenZipException catch (e) {
          if (e.kind == SevenZipError.wrongPassword) rethrow;
          warnings.add('zx: a damaged data block (${e.message})');
          _blk = null;
          if (_cur >= 0 && _left != 0) _failed = true;
        }
        _blkPos = 0;
        return true;
      case ZxBlockType.index:
        // kept to learn the state of the generation at its Footer
        if (_left < 0) _left = 0;
        try {
          final chain = ZxArchiveReader.metaChainOf(header, h.chainId);
          final k = header.encryptedMetadata ? _getKeys() : null;
          _indexParts.add(
              zxDecodeBlock(ZxDecodeArg(raw, chain, k?.aesKey, k?.macKey)));
        } on ZxNeedPasswordException {
          rethrow;
        } on SevenZipException {
          _indexParts
            ..clear()
            ..add(Uint8List(0));
          _indexBad = true;
        }
        return true;
      default:
        // padding, chunk runs and the rest; they end an entry without size
        // too
        if (_left < 0) _left = 0;
        return true;
    }
  }

  bool _indexBad = false;

  // at a Footer: the Index blocks before it give the state of the
  // generation
  void _endGeneration() {
    if (_indexParts.isNotEmpty && !_indexBad) {
      final all = BytesBuilder(copy: false);
      for (final p in _indexParts) {
        all.add(p);
      }
      try {
        lastIndex =
            ZxIndex.decode(all.toBytes(), multiVolume: header.multiVolume);
        _lastIndexAt = footers;
      } on SevenZipException {
        // a damaged Index: the state of this generation is not known
      }
    }
    _indexParts.clear();
    _indexBad = false;
    footers++;
  }

  /// The generations met (the last one may have no Footer: an interrupted
  /// update or a damaged end).
  int get generations {
    final g = entryGeneration.isEmpty ? 0 : entryGeneration.last;
    return g > footers ? g : footers;
  }

  /// After a complete pass: the entries of the state of the last
  /// generation, in stream order. A path written again in a later
  /// generation takes its last version; the paths that the Index of the
  /// last generation does not list were deleted. Notes about what could
  /// not be applied go to [warnings].
  List<int> currentEntries() {
    final latest = <String, int>{};
    for (var i = 0; i < entries.length; i++) {
      latest[entries[i].path] = i;
    }
    Set<String>? listed;
    final idx = lastIndex;
    final last = generations;
    if (idx != null && _lastIndexAt + 1 == last) {
      listed = {for (final e in idx.entries) e.path};
      var missing = 0;
      for (final p in listed) {
        if (!latest.containsKey(p)) missing++;
      }
      if (missing > 0) {
        warnings.add('zx: $missing entr${missing == 1 ? 'y' : 'ies'} of the '
            'last generation have no inline record (renamed): they are only '
            'read from a seekable file');
      }
    } else if (last > 1) {
      warnings.add('zx: the Index of the last generation is missing or '
          'damaged: entries it deleted can not be told apart');
    }
    return [
      for (var i = 0; i < entries.length; i++)
        if (latest[entries[i].path] == i &&
            (listed == null || listed.contains(entries[i].path)))
          i
    ];
  }

  /// Set after a one pass extraction (the items were every version).
  bool extracted = false;

  /// Reads the records up to the end (the listing of a pipe).
  void readAllRecords() {
    while (_nextBlock()) {}
  }

  /// Makes entry [i] known (reading blocks); false at the end.
  bool ensureEntry(int i) {
    while (i >= entries.length) {
      if (!_nextBlock()) return false;
    }
    return true;
  }

  // starts reading the data of entry [i]
  void _start(int i) {
    if (_cur >= 0 && _cur < i && _left != 0) _drain();
    _cur = i;
    _failed = false;
    final e = entries[i];
    _left = e.kind == ZxKind.file ? (e.size >= 0 ? e.size : -1) : 0;
    if (_left == 0) return;
    if (e.extents.length >= 2) {
      // its data starts in block n at offset o
      final n = e.extents[0], o = e.extents[1];
      while (_blkNo != n) {
        if (_blkNo >= 0 && _blkNo > n) {
          _failed = true;
          return;
        }
        if (!_nextBlock()) {
          _failed = true;
          return;
        }
      }
      if (_blk == null) {
        _failed = true;
        return;
      }
      _blkPos = o;
    }
  }

  void _drain() {
    final buf = Uint8List(1 << 16);
    try {
      while (_readData(buf, 0, buf.length) > 0) {}
    } on SevenZipException {
      // the entry is skipped
    }
  }

  int _readData(Uint8List buf, int off, int len) {
    if (_left == 0) return 0;
    if (_failed) {
      throw const SevenZipException(
          'zx: the data of this entry is damaged', SevenZipError.data);
    }
    for (;;) {
      final b = _blk;
      if (b != null && _blkPos < b.length) {
        var n = b.length - _blkPos;
        if (n > len) n = len;
        if (_left > 0 && n > _left) n = _left;
        buf.setRange(off, off + n, b, _blkPos);
        _blkPos += n;
        if (_left > 0) _left -= n;
        return n;
      }
      final wasFailed = _failed;
      if (!_nextBlock()) {
        if (_left > 0) {
          throw const SevenZipException(
              'zx: unexpected end of the stream', SevenZipError.unexpectedEnd);
        }
        _left = 0;
        return 0;
      }
      if (_failed && !wasFailed) {
        throw const SevenZipException(
            'zx: the data of this entry is damaged', SevenZipError.data);
      }
      if (_left == 0) return 0;
    }
  }

  /// Reads the data of entry [i] (entries are read in order).
  int readData(int i, Uint8List buf, int off, int len) {
    if (i != _cur) _start(i);
    return _readData(buf, off, len);
  }

  /// Skips what is left of the data of entry [i].
  void skipData(int i) {
    if (i != _cur) _start(i);
    _drain();
  }
}
