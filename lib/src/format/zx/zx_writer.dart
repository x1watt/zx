// Writing .zx files (docs/zx-format.md): a new archive, a new generation
// appended to an existing one (in place, or after a copy of it), and the
// compaction of an archive into a new file. Data is packed into blocks of
// a fixed size (solid by default: entries share blocks, cut at the block
// size), the blocks are coded in worker isolates (sync_pool.dart) and
// written in order, each entry gets its SHA-256 and TLSH digest, and a
// multi-volume set is split at block boundaries. With dedup (the default)
// the data of each file is cut into chunks (zx_dedup.dart) and a chunk
// already stored, in this generation or an earlier one, is referenced
// instead of stored again. The number of workers is bounded by a memory
// budget (zx_memory.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../crypto/sha256.dart';
import '../../io/streams.dart';
import '../../pool.dart' show defaultThreads;
import '../../sync_pool.dart';
import '../../util/tlsh.dart';
import '../../version.dart';
import '../../codec/lzma/lzma_coder.dart' show lzma2PropForDictSize;
import 'zx_blocks.dart';
import 'zx_chunkrun.dart';
import 'zx_codecs.dart';
import 'zx_crypto.dart';
import 'zx_dedup.dart';
import 'zx_format.dart';
import 'zx_memory.dart';
import 'zx_reader.dart';

export 'zx_memory.dart'
    show zxWorkerMemory, zxDecodeMemory, zxWorkersFor, zxDefaultMemoryLimit;

/// The default block size (16 MiB).
const int zxDefaultBlockSize = 16 << 20;

/// The largest block size a writer uses (64 MiB).
const int zxMaxWriteBlockSize = 64 << 20;

/// The smallest block size (4 KiB; below 1 MiB is for special uses).
const int zxMinWriteBlockSize = 4 << 10;

/// The largest unpacked size of one metadata block.
const int _metaBlockSize = 16 << 20;

/// The chain id of the metadata chain declared in the Header.
const int _metaChainId = 1;

/// A destination folder of volumes (section 10.4): volumes go to it until
/// [budget] bytes are used, or, with [untilFull], until its disk has no
/// room for the next volume.
class ZxVolumeDir {
  final String path;
  final int? budget;
  final bool untilFull;
  const ZxVolumeDir(this.path, {this.budget, this.untilFull = false});

  /// Parses "DIR", "DIR:SIZE" (a size with k, m, g, t) or "DIR:full".
  static ZxVolumeDir parse(String s) {
    final c = s.lastIndexOf(':');
    if (c > 0 && c < s.length - 1) {
      final tail = s.substring(c + 1);
      if (tail.toLowerCase() == 'full') {
        return ZxVolumeDir(s.substring(0, c), untilFull: true);
      }
      final size = zxParseSize(tail);
      if (size != null) return ZxVolumeDir(s.substring(0, c), budget: size);
    }
    return ZxVolumeDir(s);
  }
}

/// A size with an optional suffix b, k, m, g, t (powers of 1024).
int? zxParseSize(String s) {
  final m = RegExp(r'^(\d+)([bBkKmMgGtT]?)$').firstMatch(s.trim());
  if (m == null) return null;
  final v = int.parse(m[1]!);
  return switch (m[2]!.toLowerCase()) {
    'k' => v << 10,
    'm' => v << 20,
    'g' => v << 30,
    't' => v << 40,
    _ => v,
  };
}

/// Free bytes on the disk of [dir], or null when unknown: [zxFreeSpaceTool]
/// (df on POSIX systems, PowerShell on Windows). When no tool answers, a
/// volume sink reserves the space of a volume as it writes it instead
/// ([zxPreallocWrite]).
int? zxFreeSpace(String dir) => zxFreeSpaceTool(dir);

/// The free space of a folder by a system tool, or null when the tool is
/// missing or fails. A variable so that tests can simulate a system
/// without the tool.
int? Function(String dir) zxFreeSpaceTool = _freeSpaceByTool;

int? _freeSpaceByTool(String dir) {
  try {
    if (Platform.isWindows) {
      final r = Process.runSync('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-Item -LiteralPath "$dir").PSDrive.Free'
      ]);
      if (r.exitCode != 0) return null;
      return int.tryParse((r.stdout as String).trim());
    }
    final r = Process.runSync('df', ['-Pk', dir]);
    if (r.exitCode != 0) return null;
    return zxParseDfOutput(r.stdout as String);
  } on Object {
    return null;
  }
}

/// The available bytes in the output of `df -Pk DIR` (POSIX format: a
/// header line, then a line whose fourth field is the available KiB), or
/// null.
int? zxParseDfOutput(String out) {
  final lines = out.trim().split('\n');
  if (lines.length < 2) return null;
  final f = lines.last.trim().split(RegExp(r'\s+'));
  if (f.length < 4) return null;
  final k = int.tryParse(f[3]);
  return k == null || k < 0 ? null : k * 1024;
}

/// Writes [len] zero bytes of [buf] at the position of [f]: how a volume
/// reserves disk space when the free space is unknown. A variable so that
/// tests can simulate a full disk (by throwing a [FileSystemException]).
void Function(RandomAccessFile f, Uint8List buf, int len) zxPreallocWrite =
    (f, buf, len) => f.writeFromSync(buf, 0, len);

/// How far ahead of the data a volume reserves its space (the largest
/// block, a run or an Index block fits in it).
const int _reserveAhead = 96 << 20;

/// What a writer uses.
class ZxWriteOptions {
  /// The coder chain of the data, in writing order (filters first).
  List<ZxCoderSpec> coders = [
    const ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 5))
  ];
  int level = 5;
  int blockSize = zxDefaultBlockSize;

  /// Entries share blocks (false: each file starts a new block).
  bool solid = true;
  int checkType = ZxCheck.xxh64;

  /// Entry records are also written inline (section 8); set for outputs
  /// that are not seekable.
  bool streamed = false;
  bool tlsh = true;
  bool hashTable = true;
  String? password;

  /// With a password: encrypt the Index and the inline records too (the
  /// default). Without it the Index is clear, and it then holds no SHA-256
  /// nor TLSH (they would identify the encrypted content).
  bool encryptMetadata = true;
  int scryptLog2N = zxDefaultScryptLog2N;
  int threads = defaultThreads();

  /// [threads] was set by the caller (-mmt): a warning says when the
  /// memory limit lowers it.
  bool threadsExplicit = false;

  /// The memory the block workers may use together, in bytes (-mmemuse;
  /// the estimate of [zxWorkerMemory] per worker). null: the default of
  /// [zxDefaultMemoryLimit], min(75% of the available memory, the
  /// available memory minus 1.5 GiB). The reader uses the same limit.
  int? memoryLimit;

  /// Old name of [memoryLimit].
  int get memoryBudget => memoryLimit ?? zxDefaultMemoryLimit();
  set memoryBudget(int v) => memoryLimit = v;

  /// Deduplication (section 6.4, -mdedup): identical chunks of data are
  /// stored once, also against the chunks of earlier generations, and a
  /// file identical to one already stored reuses its extents. Not used in
  /// streamed files (their entries' data is contiguous).
  bool dedup = true;

  /// log2 of the average chunk size of dedup, 12 to 22 (-mchunk; 16:
  /// 64 KiB, as zpaq). Chunks are at least 1/16 and at most 127/16 of it,
  /// and at most the block size.
  int chunkLog2 = zxDefaultChunkLog2;

  /// The coder chain was given by the caller (-m0, -mf): a compaction
  /// repacks partly used blocks with it (otherwise with the chain of each
  /// block).
  bool codersSet = false;
  String? archiveComment;
  String generationComment = '';

  /// Volume sizes (the last repeats); empty for one file.
  List<int> volumeSizes = [];
  List<ZxVolumeDir> volumeDirs = [];

  /// Fixed archive id and time (tests: identical output).
  Uint8List? archiveId;
  int? time;

  /// Warnings for the caller (an experimental codec...).
  final List<String> warnings = [];
}

/// Where the bytes go: one stream, or a set of volume files.
abstract class ZxSink {
  int get volume;
  int get position;
  bool get multi;

  /// Bytes left in the current volume, or null when unlimited.
  int? get room;

  /// Bytes available in an empty volume, or null when unlimited.
  int? get emptyRoom;
  void write(Uint8List b);

  /// Ends the current volume with a trailer and starts the next one.
  void nextVolume();

  /// The volume table (every volume, the current one with size 0).
  List<ZxVolumeInfo> volumeTable();

  /// Flushes and closes what it opened; returns the volume files written.
  List<String> close();
}

/// A sink over one output stream; [base] is the offset of its first byte
/// in the file (an append).
class ZxStreamSink implements ZxSink {
  final OutStream out;
  final int base;
  int _n = 0;
  ZxStreamSink(this.out, [this.base = 0]);

  @override
  int get volume => 0;
  @override
  int get position => base + _n;
  @override
  bool get multi => false;
  @override
  int? get room => null;
  @override
  int? get emptyRoom => null;
  @override
  void write(Uint8List b) {
    out.write(b, 0, b.length);
    _n += b.length;
  }

  @override
  void nextVolume() => throw StateError('not a volume set');
  @override
  List<ZxVolumeInfo> volumeTable() => const [];
  @override
  List<String> close() {
    out.flush();
    return const [];
  }
}

/// Writes volumes `base.001`, `base.002`... (section 10).
class ZxVolumeSink implements ZxSink {
  final String baseName;
  final List<int> sizes;
  final List<ZxVolumeDir> dirs;
  final ZxHeader header;

  /// Volumes of the set written before (an append).
  final List<ZxVolumeInfo> earlier;

  /// Called with each file before it is written (to delete it on failure).
  final void Function(String path)? onFile;

  int _vol;
  RandomAccessFile? _f;
  String? _path;
  int _pos = 0;
  int _limit = 0;
  final Map<int, int> _usedInDir = {};
  // "until full" without a known free space: the space of the volume is
  // reserved by writing zeros ahead of the data, up to _reserved; the
  // volume ends where a reservation fails
  bool _probe = false;
  int _reserved = 0;
  final Uint8List _zeros = Uint8List(1 << 20);
  final List<String> _written = [];
  final List<ZxVolumeInfo> _table = [];
  final Uint8List _buf = Uint8List(1 << 16);
  int _bufLen = 0;

  ZxVolumeSink(this.baseName, this.sizes, this.dirs, this.header,
      {required int firstVolume, this.earlier = const [], this.onFile})
      : _vol = firstVolume {
    _table.addAll(earlier);
    _open();
  }

  int _sizeOf(int v) {
    if (sizes.isEmpty) return 1 << 62;
    return sizes[v < sizes.length ? v : sizes.length - 1];
  }

  String _name(int v) => '$baseName.${'${v + 1}'.padLeft(3, '0')}';

  void _open() {
    final want = _sizeOf(_vol);
    final min = header.size + 4 * zxFooterSize + 4096;
    final name = _name(_vol).split(Platform.pathSeparator).last;
    String? dir;
    var cap = want;
    for (var i = 0; i < dirs.length; i++) {
      final d = dirs[i];
      cap = want;
      final b = d.budget;
      if (b != null) {
        final left = b - (_usedInDir[i] ?? 0);
        if (left < cap) cap = left;
      }
      var probe = false;
      if (d.untilFull) {
        final free = zxFreeSpace(d.path);
        if (free == null) {
          probe = true;
        } else if (free - (1 << 20) < cap) {
          cap = free - (1 << 20);
        }
      }
      if (cap < min) continue;
      if (probe) {
        // no tool gives the free space: the volume reserves its space as
        // it goes; a folder without room for the start of a volume is full
        final path = '${d.path}${Platform.pathSeparator}$name';
        onFile?.call(path);
        Directory(d.path).createSync(recursive: true);
        final f = File(path).openSync(mode: FileMode.write);
        _f = f;
        _limit = cap;
        _reserved = 0;
        _probe = true;
        _reserve(0);
        if (_limit < min) {
          f.closeSync();
          _f = null;
          _probe = false;
          try {
            File(path).deleteSync();
          } on FileSystemException {
            // ignore
          }
          continue;
        }
        _path = path;
        _written.add(path);
        _usedInDir[i] = (_usedInDir[i] ?? 0) + _limit;
        _pos = 0;
        header.volumeNumber = _vol;
        header.volumeCount = null;
        _raw(header.encode());
        return;
      }
      dir = d.path;
      _usedInDir[i] = (_usedInDir[i] ?? 0) + cap;
      break;
    }
    if (dirs.isEmpty) {
      final f = File(baseName);
      dir = f.parent.path;
      cap = want;
    }
    if (dir == null) {
      throw SevenZipException(
          'zx: no destination folder has room for volume ${_vol + 1}',
          SevenZipError.io);
    }
    final path = '$dir${Platform.pathSeparator}$name';
    onFile?.call(path);
    Directory(dir).createSync(recursive: true);
    _f = File(path).openSync(mode: FileMode.write);
    _path = path;
    _written.add(path);
    _limit = cap;
    _probe = false;
    _pos = 0;
    header.volumeNumber = _vol;
    header.volumeCount = null;
    _raw(header.encode());
  }

  // reserves the space up to [upTo] plus the look ahead (at most the
  // volume's limit) by writing zeros after the data; on a failure (a full
  // disk) the volume ends at what was reserved
  void _reserve(int upTo) {
    if (!_probe) return;
    var target = upTo + _reserveAhead;
    if (target > _limit) target = _limit;
    if (_reserved >= target) return;
    final f = _f!;
    final back = f.positionSync();
    try {
      f.setPositionSync(_reserved);
      while (_reserved < target) {
        var n = target - _reserved;
        if (n > _zeros.length) n = _zeros.length;
        zxPreallocWrite(f, _zeros, n);
        _reserved += n;
      }
    } on FileSystemException {
      // the disk is full: the volume holds what was reserved, with the
      // whole 4 KiB of a write cut short
      try {
        final got = f.lengthSync() & ~4095;
        if (got > _reserved) _reserved = got;
        f.truncateSync(_reserved);
      } on FileSystemException {
        // ignore
      }
      _limit = _reserved;
      _probe = false;
    }
    f.setPositionSync(back);
  }

  void _raw(Uint8List b) {
    if (_bufLen + b.length > _buf.length) _drain();
    if (b.length >= _buf.length) {
      _f!.writeFromSync(b);
    } else {
      _buf.setRange(_bufLen, _bufLen + b.length, b);
      _bufLen += b.length;
    }
    _pos += b.length;
  }

  void _drain() {
    if (_bufLen > 0) {
      _f!.writeFromSync(_buf, 0, _bufLen);
      _bufLen = 0;
    }
  }

  @override
  int get volume => _vol;
  @override
  int get position => _pos;
  @override
  bool get multi => true;
  @override
  int? get room {
    if (_probe) _reserve(_pos);
    return (_probe && _reserved < _limit ? _reserved : _limit) -
        _pos -
        zxFooterSize;
  }
  @override
  int? get emptyRoom => _sizeOf(_vol + 1) - header.size - zxFooterSize;

  @override
  void write(Uint8List b) => _raw(b);

  // the reserved zeros after the data are cut off
  void _unreserve() {
    if (_reserved > _pos) _f!.truncateSync(_pos);
    _reserved = 0;
    _probe = false;
  }

  void _closeCurrent() {
    _drain();
    _unreserve();
    _f!.closeSync();
    _f = null;
    final name = _path!.split(Platform.pathSeparator).last;
    _table.add(ZxVolumeInfo(_vol, name, _pos, zxFileXxh64(_path!)));
  }

  @override
  void nextVolume() {
    _raw(ZxVolumeTrailer(_vol, _pos, header.archiveId).encode());
    _closeCurrent();
    _vol++;
    _open();
  }

  @override
  List<ZxVolumeInfo> volumeTable() => [
        ..._table,
        ZxVolumeInfo(_vol, _path!.split(Platform.pathSeparator).last, 0, 0),
      ];

  @override
  List<String> close() {
    if (_f != null) {
      _drain();
      _unreserve();
      _f!.flushSync();
      _f!.closeSync();
      _f = null;
    }
    return _written;
  }

  /// Closes and deletes the files written (a failed write).
  void abort() {
    try {
      _f?.closeSync();
    } on Object {
      // ignore
    }
    _f = null;
    for (final p in _written) {
      try {
        File(p).deleteSync();
      } on FileSystemException {
        // ignore
      }
    }
  }
}

/// The result of a write.
class ZxWriteResult {
  final int generation;
  final int newBlocks;
  final int newBytes;
  final int packedBytes;
  final List<String> volumes;
  final int endPosition;

  /// Dedup: bytes of new files that were not stored because an identical
  /// chunk or file was stored already, chunks stored and chunks reused,
  /// and files that reused a whole stored file.
  final int dedupBytes;
  final int storedChunks;
  final int reusedChunks;
  final int reusedFiles;

  /// The number of block workers used (after the memory limit).
  final int workers;
  const ZxWriteResult(this.generation, this.newBlocks, this.newBytes,
      this.packedBytes, this.volumes, this.endPosition,
      {this.dedupBytes = 0,
      this.storedChunks = 0,
      this.reusedChunks = 0,
      this.reusedFiles = 0,
      this.workers = 1});
}

// a new entry's data: flat triples (block, offset, length), where block
// -1 is a position in the stream of new data (placed at the end)
class _NewData {
  final ZxEntry entry;
  final List<int> pieces = [];
  int length = 0;
  _NewData(this.entry);
}

/// The read size of the chunker.
const int _chunkRead = 1 << 16;

// a block in flight
class _Pending {
  final int ticket;
  final int start;
  final int length;
  final Uint8List? input; // for a re-split
  final int type;
  // entries whose records precede the block in streamed files
  final List<ZxEntry> inline;
  _Pending(
      this.ticket, this.start, this.length, this.input, this.type, this.inline);
}

/// Writes one generation of a .zx archive.
class ZxWriter {
  final ZxWriteOptions o;
  final ZxHeader header;
  final ZxSink sink;
  final ZxKeys? keys;
  final SyncJobPool _pool;

  // the state carried from the earlier generations
  final Map<int, ZxChain> _chains;
  final List<ZxBlockRef> _blocks;
  final List<(int, int)> _blockRange = []; // new blocks: stream start, length
  final int _firstNewBlock;
  final List<ZxGeneration> _gens;
  final ZxIndexLoc? _prev;
  final int _genNumber;
  final int _time;
  final List<ZxVolumeInfo> _earlierVolumes;

  final List<ZxEntry> _entries = [];
  final List<_NewData> _new = [];
  // the start of each new entry's data in the stream of new data
  final Map<ZxEntry, int> _startOf = Map.identity();
  // the chains declared in inline records (streamed files)
  final Set<int> _declaredInline = {};
  final Set<ZxEntry> _keptOld = {};

  final List<ZxCoderSpec> _coders;
  // the block being filled; it grows up to the block size, so a small
  // archive does not allocate a whole block
  late Uint8List _buf =
      Uint8List(o.blockSize < (256 << 10) ? o.blockSize : 256 << 10);
  int _fill = 0;
  int _streamPos = 0;
  int _blockStart = 0;
  // the entries with data in the block being filled
  int _contribs = 0;
  ZxEntry? _lastContrib;
  final List<ZxEntry> _inlineQueue = [];
  final List<_Pending> _pending = [];
  int _packed = 0;
  bool _finished = false;

  // dedup: the chunks known (old and new), the chunker and its buffer,
  // the files a new identical file reuses (by the first bytes of their
  // SHA-256: old entries or new _NewData), and the sizes among them
  final bool _dedupOn;
  ZxChunkIndex? _chunks;
  ZxChunker? _chunker;
  Uint8List? _cbuf;
  final Uint8List _digest = Uint8List(32);
  final Sha256 _chunkSha = Sha256();
  final Map<int, List<Object>> _whole = {};
  final Set<int> _sizes = {};
  // the chunk table (zx 0.5.0) and the chunk runs of the last
  // generation, carried when dedup is off
  ZxChunkTable? _carried;
  List<ZxChunkRunRef>? _carriedRuns;
  // the runs of the last generation opened for lookups (oldest first) and
  // the volumes they are read from
  final List<ZxChunkRun> _runs = [];
  ZxVolumes? _vols;
  int _dupBytes = 0, _storedChunks = 0, _reusedChunks = 0, _reusedFiles = 0;
  // the spill file of the new chunks of a file that may be a stored one
  // (see _addDedup): the lengths of its chunks, in order
  bool _spilling = false;
  RandomAccessFile? _spill;
  Directory? _spillDir;
  int _spillLen = 0;
  final List<int> _spillChunks = [];

  ZxWriter._(
      this.o,
      this.header,
      this.sink,
      this.keys,
      this._chains,
      this._blocks,
      this._gens,
      this._prev,
      this._genNumber,
      this._time,
      this._earlierVolumes)
      : _pool = SyncJobPool(_threadsFor(o)),
        _firstNewBlock = _blocks.length,
        _coders = o.level == 0 ? const [] : o.coders,
        _dedupOn = o.dedup && !o.streamed {
    if (o.blockSize < zxMinWriteBlockSize ||
        o.blockSize > zxMaxWriteBlockSize) {
      throw InvalidArgExceptionZx('zx: the block size must be 4 KiB to 64 MiB');
    }
    for (final c in _coders) {
      final info = zxCodecById(c.codecId);
      if (info != null && info.isExperimental) {
        o.warnings.add('zx: ${info.name} is an experimental codec: only zx '
            '$zxVersionString can read this archive');
      }
    }
    if (_dedupOn) {
      _chunks = ZxChunkIndex();
      final ch = _chunker = ZxChunker(o.chunkLog2, maxLimit: o.blockSize);
      _cbuf = Uint8List(ch.maxSize + _chunkRead);
    }
  }

  /// The number of block workers: [ZxWriteOptions.threads], fewer when
  /// their estimated memory ([zxWorkerMemory]) exceeds the limit.
  static int _threadsFor(ZxWriteOptions o) {
    final limit = o.memoryLimit ?? zxDefaultMemoryLimit();
    final per = zxWorkerMemory(o.level == 0 ? const [] : o.coders, o.blockSize);
    final t = zxWorkersFor(o.threads, per, limit);
    if (per > limit) {
      o.warnings.add('zx: one block worker needs about ${per >> 20} MiB, more '
          'than the memory limit of ${limit >> 20} MiB (-mmemuse)');
    } else if (t < o.threads && o.threadsExplicit) {
      o.warnings.add('zx: $t block worker${t == 1 ? '' : 's'} instead of '
          '${o.threads}: each needs about ${per >> 20} MiB and the memory '
          'limit is ${limit >> 20} MiB (-mmemuse)');
    }
    return t;
  }

  /// The number of block workers (after the memory limit).
  int get workers => _pool.threads;

  /// The time of a new generation: now, or the previous time when the
  /// clock is behind it (section 9.1).
  static int _genTime(ZxWriteOptions o, List<ZxGeneration> gens) {
    var t = o.time ?? DateTime.now().microsecondsSinceEpoch * 1000;
    if (gens.isNotEmpty && t < gens.last.time) t = gens.last.time;
    return t;
  }

  /// A new archive: writes the Header to [sink] (for a [ZxVolumeSink] the
  /// sink writes it with each volume: pass [makeSink]).
  static ZxWriter create(
      ZxWriteOptions o, ZxSink Function(ZxHeader h) makeSink) {
    final h = ZxHeader();
    h.archiveId = o.archiveId ?? zxRandomBytes(16);
    h.writerName = 'zx $zxVersionString (Dart)';
    final t = _genTime(o, const []);
    h.creationTime = t;
    h.comment = o.archiveComment;
    ZxKeys? keys;
    final pw = o.password;
    if (pw != null && pw.isNotEmpty) {
      final (kdf, k) = zxNewKdf(pw, log2N: o.scryptLog2N);
      h.kdf = kdf;
      keys = k;
      if (o.encryptMetadata) h.flags |= ZxHeaderFlag.encryptedMetadata;
    }
    if (o.streamed) h.flags |= ZxHeaderFlag.streamed;
    final multi = o.volumeSizes.isNotEmpty;
    if (multi) h.flags |= ZxHeaderFlag.multiVolume;
    if (o.level != 0) {
      h.metaChain = ZxChain(_metaChainId, [
        ZxCoder(ZxCodecId.lzma2,
            Uint8List.fromList([lzma2PropForDictSize(_metaBlockSize)]))
      ]);
    }
    h.required = ZxFeature.appendable |
        (keys != null ? ZxFeature.encryption : 0) |
        (multi ? ZxFeature.multiVolume : 0) |
        (o.solid ? ZxFeature.solid : 0) |
        (o.dedup && !o.streamed ? ZxFeature.dedup : 0);
    h.optional = (o.hashTable ? ZxOptFeature.hashTable : 0) |
        (o.tlsh ? ZxOptFeature.similarity : 0);
    h.minReaderVersion = _minReader(o.coders);
    final sink = makeSink(h);
    if (!multi) sink.write(h.encode());
    return ZxWriter._(o, h, sink, keys, {}, [], [], null, 1, t, const []);
  }

  static ZxVer _minReader(List<ZxCoderSpec> coders) {
    final (v, exp) = zxChainRequirements(
        [for (final c in coders) ZxCoder(c.codecId, Uint8List(0))]);
    if (exp) return zxVersion;
    return zxCompareVersions(v, (0, 5, 0)) > 0 ? v : (0, 5, 0);
  }

  /// A new generation after the current state of [r]; [sink] is positioned
  /// after its last valid Footer (the volume sink starts a new volume).
  static ZxWriter append(ZxArchiveReader r, ZxWriteOptions o, ZxSink sink) {
    final last = r.lastIndex;
    ZxKeys? keys;
    if (r.header.kdf != null) {
      keys = r.keysFor(() => o.password);
    }
    final gens = <ZxGeneration>[];
    final old = r.generations;
    for (var i = 0; i < old.length; i++) {
      final g = old[i];
      // the current one gets its location now
      gens.add(i == old.length - 1 ? g.at(r.lastIndexLoc) : g);
    }
    final number = (gens.isEmpty ? 0 : gens.last.number) + 1;
    final t = _genTime(o, gens);
    o.streamed = r.header.streamed;
    return ZxWriter._(
        o,
        r.header,
        sink,
        keys,
        Map.of(last.chains),
        List.of(last.blocks),
        gens,
        r.lastIndexLoc,
        number,
        t,
        last.volumes ?? const [])
      .._prevPaths = {for (final e in last.entries) e.path}
      .._vols = r.volumes
      .._loadOld(last);
  }

  // the chunks and the files of the last generation, which new data can
  // reuse (dedup): its chunk runs are opened (their fences and filters
  // are read, the records stay on disk), the chunks of a chunk table of
  // zx 0.5.0 are loaded (they go into the run of this generation); the
  // chunks that do not fit the block table are left out
  void _loadOld(ZxIndex last) {
    final t = last.chunksValid;
    final clear = keys != null && !header.encryptedMetadata;
    final runs = last.chunkRunsValid;
    if (!_dedupOn) {
      _carried = clear ? null : t;
      _carriedRuns = runs?.runs;
      return;
    }
    final vols = _vols;
    if (runs != null && vols != null) {
      for (final ref in runs.runs) {
        try {
          _runs.add(ZxChunkRun.open(vols, ref, keys));
        } on ZxNeedPasswordException {
          rethrow;
        } on SevenZipException catch (e) {
          o.warnings.add('zx: a chunk run of the archive can not be read '
              '(${e.message}): new data is not deduplicated against its '
              'chunks');
        }
      }
    }
    final ix = _chunks!;
    if (t != null) {
      for (var i = 0; i < t.length; i++) {
        final b = t.locs[3 * i], off = t.locs[3 * i + 1];
        final len = t.locs[3 * i + 2];
        if (b >= _blocks.length || off + len > _blocks[b].unpackedSize) {
          continue;
        }
        if (ix.find(t.sha, len, 32 * i) >= 0) continue;
        ix.add(t.sha, b, off, len, 32 * i);
      }
    }
    for (final e in last.entries) {
      final s = e.sha256;
      if (e.kind != ZxKind.file ||
          s == null ||
          e.size == 0 ||
          e.sparse != null ||
          e.unsupported != null) {
        continue;
      }
      var ok = true;
      for (var k = 0; k < e.extents.length; k += 3) {
        final b = e.extents[k];
        if (b >= _blocks.length ||
            e.extents[k + 1] + e.extents[k + 2] > _blocks[b].unpackedSize) {
          ok = false;
        }
      }
      if (ok) _addWhole(s, e.size, e);
    }
  }

  void _addWhole(Uint8List sha, int size, Object ref) {
    (_whole[ZxChunkIndex.keyOf(sha)] ??= []).add(ref);
    _sizes.add(size);
  }

  // the pieces of a stored file with [sha] and [size], or null
  List<int>? _findWhole(Uint8List sha, int size) {
    final l = _whole[ZxChunkIndex.keyOf(sha)];
    if (l == null) return null;
    for (final x in l) {
      if (x is ZxEntry) {
        if (x.size == size && _sameHash(x.sha256!, sha)) return x.extents;
      } else if (x is _NewData) {
        if (x.length == size && _sameHash(x.entry.sha256!, sha)) {
          return x.pieces;
        }
      }
    }
    return null;
  }

  static bool _sameHash(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  int get generation => _genNumber;

  /// Keeps [e] (an entry of the previous generation, its data in earlier
  /// blocks) in the new state.
  void addKept(ZxEntry e) {
    final c = e.copy();
    c.since ??= _genNumber - 1;
    _keptOld.add(c);
    _entries.add(c);
  }

  // the paths of the previous state (the deleted count)
  Set<String> _prevPaths = const {};

  /// Adds a new entry: [meta] gives its attributes; [data] its content
  /// (files; read to its end, or [knownSize] bytes in streamed files).
  /// Returns the number of bytes read.
  int addNew(ZxEntry meta, InStream? data, {int? knownSize}) {
    final e = meta;
    e.since = _genNumber;
    _entries.add(e);
    if (e.kind != ZxKind.file || data == null) {
      e.size = 0;
      e.extents = Int64List(0);
      if (e.kind == ZxKind.file) e.sha256 = Sha256.hash(Uint8List(0));
      if (o.streamed) _inlineQueue.add(e);
      return 0;
    }
    if (!o.solid && _fill > 0) _flushBlock();
    if (_dedupOn) return _addDedup(e, data, knownSize);
    if (o.streamed && knownSize == null && _fill > 0) _flushBlock();
    final nd = _NewData(e);
    final start = _streamPos;
    _new.add(nd);
    _startOf[e] = start;
    if (o.streamed) {
      // the inline record gives the size when it is known before
      e.size = knownSize ?? -1;
      _inlineQueue.add(e);
    }
    final sha = Sha256();
    final tl = o.tlsh ? Tlsh() : null;
    var total = 0;
    final limit = o.streamed ? knownSize : null;
    while (limit == null || total < limit) {
      final want = _room(limit == null ? o.blockSize : limit - total);
      final n = data.read(_buf, _fill, want);
      if (n <= 0) break;
      _took(e, n, sha, tl);
      total += n;
    }
    if (limit != null && total < limit) {
      // the file got shorter while it was read: zeros keep the size of
      // the inline record
      while (total < limit) {
        final k = _room(limit - total);
        _buf.fillRange(_fill, _fill + k, 0);
        _took(e, k, sha, tl);
        total += k;
      }
      o.warnings.add('zx: ${e.path} got shorter while it was read');
    }
    nd.length = total;
    if (total > 0) {
      nd.pieces
        ..add(-1)
        ..add(start)
        ..add(total);
    }
    e.size = total;
    e.sha256 = sha.digest();
    e.tlsh = tl?.digest();
    if (o.streamed && knownSize == null && _fill > 0) _flushBlock();
    return total;
  }

  // a file with dedup: its chunks are looked up and only the new ones are
  // stored, while the SHA-256 of the whole file is computed; a file
  // identical to one stored (same size and SHA-256) then reuses that
  // file's extents. The file is read once and never held whole: when its
  // size is that of a stored file, its new chunks wait in a spill file (on
  // disk) until the end, where they are dropped or stored; otherwise they
  // are stored at once, and dropped when the file turns out to be a stored
  // one and they are all still in the block being filled
  int _addDedup(ZxEntry e, InStream data, int? knownSize) {
    final nd = _NewData(e);
    _new.add(nd);
    final sha = Sha256();
    final tl = o.tlsh ? Tlsh() : null;
    final ix = _chunks!;
    final chunksAt = ix.length, streamAt = _streamPos;
    final dupAt = _dupBytes, reusedAt = _reusedChunks;
    final storedAt = _storedChunks;
    final candidate =
        knownSize != null && knownSize > 0 && _sizes.contains(knownSize);
    if (candidate) {
      _spilling = true;
      _spillLen = 0;
      _spillChunks.clear();
    }
    try {
      _chunkFile(nd, data, sha, tl);
    } finally {
      _spilling = false;
    }
    final n = nd.length;
    e.size = n;
    e.sha256 = sha.digest();
    e.tlsh = tl?.digest();
    final stored = ix.length > chunksAt;
    var whole = false;
    if (n > 0 && _sizes.contains(n)) {
      final hit = _findWhole(e.sha256!, n);
      // spilled chunks are dropped; chunks stored at once only while they
      // are all in the block being filled (no block written since)
      if (hit != null && (!stored || candidate || _blockStart <= streamAt)) {
        if (stored) {
          ix.truncate(chunksAt);
          if (!candidate) {
            _fill -= _streamPos - streamAt;
            _streamPos = streamAt;
          }
          _storedChunks = storedAt;
        }
        nd.pieces
          ..clear()
          ..addAll(hit);
        _dupBytes = dupAt + n;
        _reusedChunks = reusedAt;
        _reusedFiles++;
        whole = true;
      }
    }
    if (!whole && candidate && _spillChunks.isNotEmpty) {
      _commitSpill(nd, chunksAt);
    }
    if (n > 0) _addWhole(e.sha256!, n, nd);
    return n;
  }

  // cuts the data of a file into chunks (see _chunk)
  void _chunkFile(_NewData nd, InStream data, Sha256 sha, Tlsh? tl) {
    final ch = _chunker!;
    ch.reset();
    final cb = _cbuf!;
    var start = 0, scan = 0, fill = 0;
    for (;;) {
      if (scan == fill) {
        if (cb.length - fill < _chunkRead && start > 0) {
          cb.setRange(0, fill - start, cb, start);
          fill -= start;
          scan -= start;
          start = 0;
        }
        var want = cb.length - fill;
        if (want > _chunkRead) want = _chunkRead;
        final n = data.read(cb, fill, want);
        if (n <= 0) break;
        fill += n;
      }
      final cut = ch.scan(cb, scan, fill);
      if (cut < 0) {
        scan = fill;
        continue;
      }
      _chunk(nd, cb, start, cut - start, sha, tl);
      start = scan = cut;
    }
    if (fill > start) _chunk(nd, cb, start, fill - start, sha, tl);
  }

  // the chunk of [len] bytes with SHA-256 [sha] in a run of the last
  // generation, when it lies in a block of the table: (block, offset)
  (int, int)? _inRuns(Uint8List sha, int len) {
    for (var i = _runs.length - 1; i >= 0; i--) {
      final h = _runs[i].find(sha, 0);
      if (h == null || h.length != len) continue;
      final b = h.block;
      if (b >= _firstNewBlock || h.offset + len > _blocks[b].unpackedSize) {
        continue;
      }
      return (b, h.offset);
    }
    return null;
  }

  // one chunk of a file: referenced when known, else stored in the block
  // being filled (a chunk is never cut by a block boundary)
  void _chunk(
      _NewData nd, Uint8List b, int off, int len, Sha256 sha, Tlsh? tl) {
    sha.update(b, off, len);
    tl?.update(b, off, off + len);
    nd.length += len;
    _chunkSha
      ..update(b, off, len)
      ..finalTo(_digest);
    final ix = _chunks!;
    final id = ix.find(_digest, len);
    if (id >= 0) {
      zxAddExtent(nd.pieces, ix.block(id), ix.offset(id), len);
      _dupBytes += len;
      _reusedChunks++;
      return;
    }
    if (_runs.isNotEmpty) {
      final hit = _inRuns(_digest, len);
      if (hit != null) {
        zxAddExtent(nd.pieces, hit.$1, hit.$2, len);
        _dupBytes += len;
        _reusedChunks++;
        return;
      }
    }
    _storedChunks++;
    if (_spilling) {
      // a file that may be a stored one: its new chunks wait in the spill
      // file (block -2: an offset in it)
      final pos = _spillLen;
      _spillWrite(b, off, len);
      ix.add(_digest, -2, pos, len);
      _spillChunks.add(len);
      zxAddExtent(nd.pieces, -2, pos, len);
      return;
    }
    final pos = _store(b, off, len);
    ix.add(_digest, -1, pos, len);
    zxAddExtent(nd.pieces, -1, pos, len);
    if (_fill == o.blockSize) _flushBlock();
  }

  // puts [len] bytes of a new chunk into the block being filled (a chunk
  // is never cut by a block boundary); returns its position in the stream
  // of new data
  int _store(Uint8List b, int off, int len) {
    if (_fill + len > o.blockSize) _flushBlock();
    if (_fill + len > _buf.length) {
      var c = _buf.length * 2;
      if (c < _fill + len) c = _fill + len;
      if (c > o.blockSize) c = o.blockSize;
      _buf = Uint8List(c)..setRange(0, _fill, _buf);
    }
    _buf.setRange(_fill, _fill + len, b, off);
    final pos = _streamPos;
    _fill += len;
    _streamPos += len;
    return pos;
  }

  void _spillWrite(Uint8List b, int off, int len) {
    var f = _spill;
    if (f == null) {
      final dir = _spillDir = Directory.systemTemp.createTempSync('zx-dedup-');
      f = _spill = File('${dir.path}${Platform.pathSeparator}spill')
          .openSync(mode: FileMode.write);
    }
    f.setPositionSync(_spillLen);
    f.writeFromSync(b, off, off + len);
    _spillLen += len;
  }

  // the new chunks of the file of [nd] (ids from [firstId]) go from the
  // spill file into the blocks, in order: the spill offset o becomes the
  // stream position base + o
  void _commitSpill(_NewData nd, int firstId) {
    final ix = _chunks!;
    final f = _spill!;
    final buf = _cbuf!;
    final base = _streamPos;
    var pos = 0;
    for (final len in _spillChunks) {
      f.setPositionSync(pos);
      if (f.readIntoSync(buf, 0, len) != len) {
        throw const SevenZipException(
            'zx: the dedup spill file is cut', SevenZipError.io);
      }
      _store(buf, 0, len);
      if (_fill == o.blockSize) _flushBlock();
      pos += len;
    }
    for (var id = firstId; id < ix.length; id++) {
      if (ix.block(id) == -2) ix.setLocation(id, -1, base + ix.offset(id));
    }
    final p = nd.pieces;
    final out = <int>[];
    for (var i = 0; i < p.length; i += 3) {
      if (p[i] == -2) {
        zxAddExtent(out, -1, base + p[i + 1], p[i + 2]);
      } else {
        zxAddExtent(out, p[i], p[i + 1], p[i + 2]);
      }
    }
    p
      ..clear()
      ..addAll(out);
  }

  void _dropSpill() {
    try {
      _spill?.closeSync();
    } on FileSystemException {
      // ignore
    }
    _spill = null;
    try {
      _spillDir?.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
    _spillDir = null;
  }

  // makes room in the block for up to [want] bytes; returns how many
  int _room(int want) {
    var n = o.blockSize - _fill;
    if (n > want) n = want;
    if (_fill + n > _buf.length) {
      var c = _buf.length * 2;
      if (c < _fill + n) c = _fill + n;
      if (c > o.blockSize) c = o.blockSize;
      final nb = Uint8List(c);
      nb.setRange(0, _fill, _buf);
      _buf = nb;
    }
    return n;
  }

  // [n] bytes of [e] were stored at _buf[_fill]
  void _took(ZxEntry e, int n, Sha256 sha, Tlsh? tl) {
    sha.update(_buf, _fill, n);
    tl?.update(_buf, _fill, _fill + n);
    if (!identical(_lastContrib, e)) {
      _contribs++;
      _lastContrib = e;
    }
    _fill += n;
    _streamPos += n;
    if (_fill == o.blockSize) _flushBlock();
  }

  void _flushBlock() {
    if (_fill == 0) return;
    final data = Uint8List.fromList(Uint8List.sublistView(_buf, 0, _fill));
    final start = _blockStart;
    final len = _fill;
    final type = _dedupOn
        ? ZxBlockType.chunks
        : _contribs > 1
            ? ZxBlockType.solid
            : ZxBlockType.data;
    _blockStart += _fill;
    _fill = 0;
    _contribs = 0;
    _lastContrib = null;
    final inline = List<ZxEntry>.of(_inlineQueue);
    _inlineQueue.clear();
    while (_pool.running >= _pool.threads || _pending.length > _pool.threads) {
      _writeNext();
    }
    final arg =
        ZxEncodeArg(data, _coders, o.checkType, keys?.aesKey, keys?.macKey);
    final ticket = _pool.submit(zxEncodeBlockJob, arg);
    // keep the input for a re-split only when volumes may need one
    _pending.add(
        _Pending(ticket, start, len, sink.multi ? data : null, type, inline));
  }

  int _chainIdFor(List<ZxCoder> coders) {
    if (coders.isEmpty) return 0;
    for (final c in _chains.values) {
      if (c.sameCoders(coders)) return c.id;
    }
    var id = _metaChainId + 1;
    for (final k in _chains.keys) {
      if (k >= id) id = k + 1;
    }
    _chains[id] = ZxChain(id, coders);
    return id;
  }

  void _writeNext() {
    final p = _pending.removeAt(0);
    final enc = ZxEncodedBlock.fromResult(_pool.take(p.ticket));
    _placeBlock(enc, p.start, p.length, p.input, p.type, p.inline);
  }

  ZxEncodedBlock _encodePart(Uint8List input, int from, int to) =>
      zxEncodeBlock(ZxEncodeArg(
          Uint8List.fromList(Uint8List.sublistView(input, from, to)),
          _coders,
          o.checkType,
          keys?.aesKey,
          keys?.macKey));

  // writes an encoded block; in a volume set a block that does not fit is
  // cut (and coded again) so that its first part fills the volume, and
  // the rest goes to the next ones (section 10.1)
  void _placeBlock(ZxEncodedBlock enc, int start, int len, Uint8List? input,
      int type, List<ZxEntry> inline) {
    final chainId = _chainIdFor(enc.coders);
    final hdr = ZxBlockHeader.encode(type, chainId, enc.unpackedSize,
        enc.payload.length, enc.checkType, enc.check);
    final total = hdr.length + enc.payload.length;
    if (sink.multi && total > sink.room!) {
      const minCut = zxMinWriteBlockSize;
      // cuts the block so that its first part fits in [room]
      bool tryCut(int room) {
        if (input == null || len < 2 * minCut) return false;
        var cut = (len * room / total * 0.97).floor();
        for (var tries = 0; tries < 8 && cut >= minCut; tries++) {
          if (cut > len - minCut) cut = len - minCut;
          final a = _encodePart(input, 0, cut);
          final ha = ZxBlockHeader.encode(type, _chainIdFor(a.coders),
              a.unpackedSize, a.payload.length, a.checkType, a.check);
          if (ha.length + a.payload.length <= room) {
            // the inline records go with the part their data starts in
            final first = [
              for (final e in inline)
                if ((_startOf[e] ?? start) < start + cut) e
            ];
            final second = [
              for (final e in inline)
                if ((_startOf[e] ?? start) >= start + cut) e
            ];
            _placeBlock(a, start, cut, null, type, first);
            _placeBlock(_encodePart(input, cut, len), start + cut, len - cut,
                Uint8List.sublistView(input, cut), type, second);
            return true;
          }
          cut = (cut * 0.85).floor();
        }
        return false;
      }

      // the rest of this volume, when it is worth it
      final room = sink.room!;
      final empty = sink.emptyRoom!;
      final worth = room >= (empty ~/ 4 < (64 << 10) ? empty ~/ 4 : 64 << 10);
      if (worth && tryCut(room)) return;
      sink.nextVolume();
      if (total > sink.room!) {
        if (tryCut(sink.room!)) return;
        throw const SevenZipException(
            'zx: the volume size is too small for the data',
            SevenZipError.unsupported);
      }
    }
    // streamed files declare a chain before its first block
    if (inline.isNotEmpty ||
        (o.streamed && chainId != 0 && !_declaredInline.contains(chainId))) {
      _writeInline(inline, start);
    }
    // this block's position is known now
    final payload = enc.payload;
    if (keys != null) keys!.mac(ZxBlockHeader.macPart(hdr), payload);
    final ref = ZxBlockRef(
        sink.volume, sink.position, hdr.length, payload.length, len, chainId);
    sink.write(hdr);
    sink.write(payload);
    _blocks.add(ref);
    _blockRange.add((start, len));
    _packed += total;
  }

  // an inline metadata block of streamed files: the chains declared so far
  // and the records of the entries whose data starts in the next data
  // block (at [blockStart] of the new data), each with the start of its
  // data as one extent (block, offset, 0)
  void _writeInline(List<ZxEntry> entries, [int? blockStart]) {
    final w = ZxBytes(256);
    for (final c in _chains.values) {
      if (_declaredInline.add(c.id)) w.rec(ZxRec.chain, c.write);
    }
    for (final e in entries) {
      final st = _startOf[e];
      final x = e.copy()
        ..extents = st == null || blockStart == null
            ? Int64List(0)
            : Int64List.fromList([_blocks.length, st - blockStart, 0])
        ..sha256 = null
        ..tlsh = null;
      if (e.kind != ZxKind.file) x.size = 0;
      w.record(ZxRec.entry, x.encode(withSize: x.size >= 0));
    }
    _writeMeta(w.toBytes(), ZxBlockType.meta);
  }

  // metadata blocks (inline records, Index) with the Header's chain
  List<ZxBlockRef> _writeMeta(Uint8List content, int type) {
    final out = <ZxBlockRef>[];
    var off = 0;
    do {
      var n = content.length - off;
      if (n > _metaBlockSize) n = _metaBlockSize;
      final part =
          Uint8List.fromList(Uint8List.sublistView(content, off, off + n));
      off += n;
      final meta = header.metaChain;
      final useKeys = header.encryptedMetadata ? keys : null;
      final enc = zxEncodeBlock(ZxEncodeArg(
          part,
          meta == null
              ? const []
              : const [ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 5))],
          ZxCheck.crc32c,
          useKeys?.aesKey,
          useKeys?.macKey));
      final chainId = enc.coders.isEmpty ? 0 : _metaChainId;
      final hdr = ZxBlockHeader.encode(type, chainId, enc.unpackedSize,
          enc.payload.length, enc.checkType, enc.check);
      if (useKeys != null) useKeys.mac(ZxBlockHeader.macPart(hdr), enc.payload);
      final total = hdr.length + enc.payload.length;
      if (sink.multi && type == ZxBlockType.meta && total > sink.room!) {
        sink.nextVolume();
      }
      out.add(ZxBlockRef(sink.volume, sink.position, hdr.length,
          enc.payload.length, n, chainId));
      sink.write(hdr);
      sink.write(enc.payload);
    } while (off < content.length);
    return out;
  }

  // the extents of each new entry: its pieces, the positions in the stream
  // of new data placed in the blocks
  void _computeExtents() {
    for (final nd in _new) {
      final ext = <int>[];
      final p = nd.pieces;
      for (var i = 0; i < p.length; i += 3) {
        if (p[i] >= 0) {
          zxAddExtent(ext, p[i], p[i + 1], p[i + 2]);
        } else {
          _resolve(p[i + 1], p[i + 2], ext);
        }
      }
      nd.entry.extents = Int64List.fromList(ext);
    }
  }

  // the new block holding position [pos] of the stream of new data
  int _blockAt(int pos) {
    var lo = 0, hi = _blockRange.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_blockRange[mid].$1 <= pos) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  // the extents of [len] bytes at [pos] of the stream of new data
  void _resolve(int pos, int len, List<int> ext) {
    var j = _blockAt(pos);
    final end = pos + len;
    while (pos < end) {
      final (bs, bl) = _blockRange[j];
      final take = (bs + bl < end ? bs + bl : end) - pos;
      zxAddExtent(ext, _firstNewBlock + j, pos - bs, take);
      pos += take;
      j++;
    }
  }

  // the chunks known in memory (stored in this generation, and those of a
  // chunk table of zx 0.5.0), placed and sorted by SHA-256; a chunk that
  // a volume cut split between two blocks is left out
  ZxMemChunks _memChunks() {
    final ix = _chunks!;
    final n = ix.length;
    final locs = Int64List(3 * n);
    final sha = Uint8List(32 * n);
    var k = 0;
    for (var id = 0; id < n; id++) {
      var b = ix.block(id), off = ix.offset(id);
      final len = ix.size(id);
      if (b < 0) {
        final j = _blockAt(off);
        final (bs, bl) = _blockRange[j];
        if (off + len > bs + bl) continue;
        b = _firstNewBlock + j;
        off -= bs;
      }
      locs[3 * k] = b;
      locs[3 * k + 1] = off;
      locs[3 * k + 2] = len;
      sha.setRange(32 * k, 32 * k + 32, ix.shaOf(id));
      k++;
    }
    return ZxMemChunks.sort(sha, locs, k);
  }

  // the most records of one run: zxRunMaxRecords, and what an empty
  // volume holds (about 50 bytes a record with the fences and the filter)
  int _runCap() {
    var cap = zxRunMaxRecords;
    if (sink.multi) {
      final fit = (sink.emptyRoom! - 1024) ~/ 50;
      if (fit < cap) cap = fit;
    }
    return cap;
  }

  // the chunk runs of the new Index (section 6.4.1): the runs of the last
  // generation, and the chunks known in memory as a new run, merged with
  // the last runs of about its size (their records are read again and
  // written into the new runs; the old blocks stay until a compaction)
  List<ZxChunkRunRef>? _writeRuns() {
    if (!_dedupOn) return _carriedRuns;
    final mem = _memChunks();
    final old = _runs;
    final cap = _runCap();
    if (mem.length == 0) return [for (final r in old) r.ref];
    if (cap < zxRunPageRecords) {
      o.warnings.add('zx: the volumes are too small for the chunk runs: '
          'later generations do not deduplicate against this one');
      return null;
    }
    final k = zxRunsToMerge([for (final r in old) r.count], mem.length, cap);
    final merged = old.sublist(old.length - k);
    final out = [for (final r in old.sublist(0, old.length - k)) r.ref];
    final enc = keys != null;
    zxMergeRuns(
        () => [mem.cursor(), for (final r in merged.reversed) r.cursor()],
        (count) {
      final size = zxRunBlockSize(count, enc);
      if (sink.multi && size > sink.room!) sink.nextVolume();
      out.add(ZxChunkRunRef(sink.volume, sink.position, size, count));
      return ZxRunWriter(sink.write, count, keys);
    },
        // the records of old runs are checked against the block table
        map: merged.isEmpty
            ? null
            : (b, off, len) => b < _blocks.length &&
                    off + len <= _blocks[b].unpackedSize
                ? (b, off)
                : null,
        maxRecords: cap);
    return out;
  }

  (ZxVer, int) _requirements() {
    var required = ZxFeature.appendable |
        (keys != null ? ZxFeature.encryption : 0) |
        (sink.multi || header.multiVolume ? ZxFeature.multiVolume : 0) |
        zxSharingFeatures(_entries);
    final users = <int>{};
    for (var i = 0; i < _entries.length; i++) {
      final x = _entries[i].extents;
      for (var k = 0; k < x.length; k += 3) {
        users.add(x[k]);
      }
    }
    final used = <ZxCoder>[];
    for (final b in users) {
      if (b >= _blocks.length) continue;
      final c = _chains[_blocks[b].chainId];
      if (c != null) used.addAll(c.coders);
    }
    final (v, exp) = zxChainRequirements(used);
    ZxVer mr = exp ? zxVersion : v;
    if (zxCompareVersions(mr, (0, 5, 0)) < 0) mr = (0, 5, 0);
    return (mr, required);
  }

  /// Writes what is left, the Index and the Footer.
  ZxWriteResult finish() {
    if (_finished) throw StateError('finished');
    _finished = true;
    try {
      _flushBlock();
      while (_pending.isNotEmpty) {
        _writeNext();
      }
      if (_inlineQueue.isNotEmpty) {
        _writeInline(List.of(_inlineQueue));
        _inlineQueue.clear();
      }
    } finally {
      _pool.close();
      _dropSpill();
    }
    _computeExtents();
    // a clear Index of an encrypted archive holds no content hashes
    final clearOfEncrypted = keys != null && !header.encryptedMetadata;
    // the runs are blocks of their own (encrypted in an encrypted archive,
    // so a clear Index may list them), written before the Index
    final runs = _writeRuns();

    final idx = ZxIndex();
    idx.chains.addAll(_chains);
    idx.blocks = _blocks;
    idx.entries = clearOfEncrypted
        ? [
            for (final e in _entries)
              e.copy()
                ..sha256 = null
                ..tlsh = null
          ]
        : _entries;
    if (o.hashTable && !clearOfEncrypted) {
      final t = <(Uint8List, int)>[];
      for (var i = 0; i < _entries.length; i++) {
        final s = _entries[i].sha256;
        if (s != null && _entries[i].kind == ZxKind.file) t.add((s, i));
      }
      t.sort((a, b) {
        for (var k = 0; k < 32; k++) {
          final d = a.$1[k] - b.$1[k];
          if (d != 0) return d;
        }
        return a.$2 - b.$2;
      });
      idx.shaTable = t;
    }
    if (o.tlsh && !clearOfEncrypted) {
      idx.tlshList = [
        for (var i = 0; i < _entries.length; i++)
          if (_entries[i].tlsh != null) (_entries[i].tlsh!, i)
      ];
    }
    // a chunk table of zx 0.5.0 (SHA-256 values: not in a clear Index of an
    // encrypted archive) is carried when dedup is off; with dedup its
    // chunks went into a run
    if (!_dedupOn && !clearOfEncrypted) idx.chunkTable = _carried;
    if (runs != null && runs.isNotEmpty) idx.chunkRuns = ZxChunkRuns(0, runs);
    idx.previous = _prev;
    var added = 0;
    final now = <String>{};
    for (final e in _entries) {
      if (e.since == _genNumber) added++;
      now.add(e.path);
    }
    var deleted = 0;
    for (final p in _prevPaths) {
      if (!now.contains(p)) deleted++;
    }
    final gen = ZxGeneration(
        _genNumber, _time, o.generationComment, null, added, deleted, _packed);
    idx.generation = gen;
    idx.generations = [..._gens, gen];
    final (mr, req) = _requirements();
    idx.minReaderVersion = mr;
    idx.requiredFeatures = req;
    idx.optionalFeatures = (o.hashTable ? ZxOptFeature.hashTable : 0) |
        (o.tlsh ? ZxOptFeature.similarity : 0);
    if (sink.multi || header.multiVolume) {
      idx.volumes = sink.multi ? sink.volumeTable() : _earlierVolumes;
    }
    final content = idx.encode(multiVolume: header.multiVolume || sink.multi);
    // the Index and the Footer must be in one volume
    if (sink.multi) {
      final estimate = content.length + 1024 + zxFooterSize;
      if (estimate > sink.room! && estimate <= sink.emptyRoom!) {
        sink.nextVolume();
        idx.volumes = sink.volumeTable();
      }
    }
    final start = sink.position;
    final body = sink.multi ? idx.encode(multiVolume: true) : content;
    _writeMeta(body, ZxBlockType.index);
    final footer = ZxFooter(start, sink.position - start, _blocks.length);
    sink.write(footer.encode());
    final end = sink.position;
    final vols = sink.close();
    var newBytes = 0;
    for (final nd in _new) {
      newBytes += nd.length;
    }
    return ZxWriteResult(_genNumber, _blocks.length - _firstNewBlock, newBytes,
        _packed, vols, end,
        dedupBytes: _dupBytes,
        storedChunks: _storedChunks,
        reusedChunks: _reusedChunks,
        reusedFiles: _reusedFiles,
        workers: _pool.threads);
  }

  /// Stops the write (a failure): the workers' results are dropped.
  void abort() {
    _pool.close();
    _dropSpill();
  }
}

/// An invalid switch value for the zx writer.
class InvalidArgExceptionZx extends SevenZipException {
  const InvalidArgExceptionZx(String message)
      : super(message, SevenZipError.unsupported);
}

/// Compacts the archive of [r] into [makeSink]'s output, keeping the data
/// of the last [keep] generations: the blocks they use whole are copied as
/// they are (no recompression), the blocks they use in part (solid or
/// dedup chunk store blocks holding deleted data) are repacked with
/// [repack]: their used bytes are decoded, packed into new blocks and coded
/// again (with the chain of [ZxWriteOptions.coders] when
/// [ZxWriteOptions.codersSet], else with the chain of each block). Each
/// kept generation gets a fresh Index (and Footer) with its number and
/// time; its chunk table keeps the chunks still used, at their new places.
/// [options] gives the block size, the check, the threads and the memory
/// limit of the repacking.
ZxWriteResult zxCompact(
    ZxArchiveReader r, int keep, ZxSink Function(ZxHeader h) makeSink,
    {String? password,
    bool multi = false,
    ZxWriteOptions? options,
    bool repack = true}) {
  final o = options ?? ZxWriteOptions();
  final gens = r.generations;
  if (keep < 1) keep = 1;
  final kept = gens.length <= keep ? gens : gens.sublist(gens.length - keep);
  final keys = r.header.kdf != null ? r.keysFor(() => password) : null;
  final indexes = [for (final g in kept) r.indexOf(g)];
  final last = r.lastIndex;

  // every chain declared in a kept generation; repacked blocks may add one
  final chains = <int, ZxChain>{...last.chains};
  for (final idx in indexes) {
    for (final c in idx.chains.values) {
      chains.putIfAbsent(c.id, () => c);
    }
  }

  // the bytes of each block the kept generations use
  final live = _liveRanges(indexes);
  final order = live.keys.toList()..sort();
  final whole = <int>[];
  final part = <int>[];
  for (final b in order) {
    if (b >= last.blocks.length) zxDamaged('bad block number $b');
    final l = live[b]!;
    var covered = 0;
    for (var i = 0; i < l.length; i += 2) {
      covered += l[i + 1] - l[i];
    }
    final id = last.blocks[b].chainId;
    final chain = id == 0 ? const ZxChain(0, []) : chains[id];
    // a block whose method can not be rebuilt (zpaq without its method in
    // the props, written by zx 0.5.0) is copied whole unless -m0 is given
    final keepMethod = o.codersSet || chain == null || zxCanRepack(chain);
    if (!repack || !keepMethod || covered >= last.blocks[b].unpackedSize) {
      whole.add(b);
    } else {
      part.add(b);
    }
  }
  // the partly used blocks by chain, and the coders of their repacking
  final groups = <int, List<int>>{};
  for (final b in part) {
    (groups[last.blocks[b].chainId] ??= []).add(b);
  }
  final specs = <int, List<ZxCoderSpec>>{};
  var repackMin = (0, 5, 0);
  for (final id in groups.keys) {
    final chain = id == 0 ? const ZxChain(0, []) : chains[id];
    if (chain == null) zxDamaged('undeclared chain $id');
    final sp = o.level == 0
        ? const <ZxCoderSpec>[]
        : o.codersSet
            ? o.coders
            : zxSpecsFromChain(chain, o.level) ?? o.coders;
    specs[id] = sp;
    final (v, exp) = zxChainRequirements(
        [for (final c in sp) ZxCoder(c.codecId, Uint8List(0))]);
    final need = exp ? zxVersion : v;
    if (zxCompareVersions(need, repackMin) > 0) repackMin = need;
  }

  final h = ZxHeader()
    ..formatVersion = r.header.formatVersion
    ..minReaderVersion = r.header.minReaderVersion
    ..flags = r.header.flags
    ..required = r.header.required
    ..optional = r.header.optional
    ..archiveId = r.header.archiveId
    ..writerName = 'zx $zxVersionString (Dart)'
    ..creationTime = r.header.creationTime
    ..kdf = r.header.kdf
    ..comment = r.header.comment
    ..metaChain = r.header.metaChain;
  h.otherRecords.addAll(r.header.otherRecords);
  if (part.isNotEmpty) {
    // repacked blocks hold data of several entries
    h.required |= ZxFeature.solid;
    if (zxCompareVersions(repackMin, h.minReaderVersion) > 0) {
      h.minReaderVersion = repackMin;
    }
  }
  // the inline records are not copied: the new file is not streamed
  h.flags &= ~ZxHeaderFlag.streamed;
  if (multi) {
    h.flags |= ZxHeaderFlag.multiVolume;
    h.required |= ZxFeature.multiVolume;
  } else {
    h.flags &= ~ZxHeaderFlag.multiVolume;
    h.required &= ~ZxFeature.multiVolume;
  }
  final sink = makeSink(h);
  if (!multi) sink.write(h.encode());
  final blocks = <ZxBlockRef>[];
  var packed = 0;

  // the blocks used whole, copied
  final newOf = <int, int>{};
  for (final b in whole) {
    final raw = r.rawBlock(last, b);
    if (multi && raw.length > sink.room!) sink.nextVolume();
    final ref = last.blocks[b];
    newOf[b] = blocks.length;
    blocks.add(ZxBlockRef(sink.volume, sink.position, ref.headerSize,
        ref.packedSize, ref.unpackedSize, ref.chainId));
    sink.write(raw);
    packed += raw.length;
  }

  // the blocks used in part, repacked: per old block, the new places of
  // its used ranges as flat (start, end, new block, offset in new block)
  final segs = <int, List<int>>{};
  var workers = 1;
  if (part.isNotEmpty) {
    final limit = o.memoryLimit ?? zxDefaultMemoryLimit();
    var per = 0;
    for (final b in part) {
      final ref = last.blocks[b];
      final chain = ref.chainId == 0 ? const ZxChain(0, []) : chains[ref.chainId]!;
      final d = zxDecodeMemory(chain, ref.unpackedSize);
      final e = zxWorkerMemory(specs[ref.chainId]!, o.blockSize);
      if (d > per) per = d;
      if (e > per) per = e;
    }
    workers = zxWorkersFor(o.threads, per, limit);
    final pool = SyncJobPool(workers);
    int chainIdFor(List<ZxCoder> coders) {
      if (coders.isEmpty) return 0;
      for (final c in chains.values) {
        if (c.sameCoders(coders)) return c.id;
      }
      var id = _metaChainId + 1;
      for (final k in chains.keys) {
        if (k >= id) id = k + 1;
      }
      chains[id] = ZxChain(id, coders);
      return id;
    }

    void place(_Repacked rp, ZxEncodedBlock enc) {
      final chainId = chainIdFor(enc.coders);
      final hdr = ZxBlockHeader.encode(rp.type, chainId, enc.unpackedSize,
          enc.payload.length, enc.checkType, enc.check);
      final total = hdr.length + enc.payload.length;
      if (multi && total > sink.room!) sink.nextVolume();
      if (keys != null) keys.mac(ZxBlockHeader.macPart(hdr), enc.payload);
      final nb = blocks.length;
      blocks.add(ZxBlockRef(sink.volume, sink.position, hdr.length,
          enc.payload.length, enc.unpackedSize, chainId));
      sink.write(hdr);
      sink.write(enc.payload);
      packed += total;
      final s = rp.segs;
      for (var i = 0; i < s.length; i += 4) {
        (segs[s[i]] ??= <int>[])
          ..add(s[i + 1])
          ..add(s[i + 2])
          ..add(nb)
          ..add(s[i + 3]);
      }
    }

    try {
      for (final entry in groups.entries) {
        final list = entry.value;
        final coders = specs[entry.key]!;
        final bs = o.blockSize;
        final cur = Uint8List(bs);
        var fill = 0;
        var curSegs = <int>[];
        var curChunks = false;
        final ready = <_Repacked>[];
        final jobs = <(int, int, _Repacked?)>[]; // ticket, old block, block
        final isChunks = <int, bool>{};
        var nextDec = 0;

        void closeCur() {
          if (fill == 0) return;
          ready.add(_Repacked(
              Uint8List.fromList(Uint8List.sublistView(cur, 0, fill)),
              curSegs,
              curChunks ? ZxBlockType.chunks : ZxBlockType.solid));
          fill = 0;
          curSegs = <int>[];
          curChunks = false;
        }

        // the used ranges of old block [b] (decoded as [data]) go to the
        // new blocks; a range moves to the next block when it does not
        // fit, and is cut only when it is larger than a block
        void take(int b, Uint8List data) {
          final l = live[b]!;
          for (var i = 0; i < l.length; i += 2) {
            var s = l[i];
            final e = l[i + 1];
            if (e > data.length) zxDamaged('an extent beyond its block');
            while (s < e) {
              final room = bs - fill;
              final len = e - s;
              if (len > room && fill > 0 && len <= bs) {
                closeCur();
                continue;
              }
              final n = len < room ? len : room;
              cur.setRange(fill, fill + n, data, s);
              curSegs
                ..add(b)
                ..add(s)
                ..add(s + n)
                ..add(fill);
              if (isChunks[b] ?? false) curChunks = true;
              fill += n;
              s += n;
              if (fill == bs) closeCur();
            }
          }
        }

        for (;;) {
          if (ready.isNotEmpty && pool.inFlight < pool.threads) {
            final rp = ready.removeAt(0);
            final t = pool.submit(
                zxEncodeBlockJob,
                ZxEncodeArg(rp.data, coders, o.checkType, keys?.aesKey,
                    keys?.macKey));
            jobs.add((t, -1, rp));
            continue;
          }
          if (ready.isEmpty &&
              nextDec < list.length &&
              pool.inFlight < pool.threads) {
            final b = list[nextDec++];
            final arg = r.decodeArg(last, b);
            final bh = ZxBlockHeader.tryParse(arg.raw, 0, arg.raw.length);
            isChunks[b] = bh?.type == ZxBlockType.chunks;
            jobs.add((pool.submit(zxDecodeBlockJob, arg), b, null));
            continue;
          }
          if (jobs.isEmpty) {
            if (fill > 0) {
              closeCur();
              continue;
            }
            break;
          }
          final (t, b, rp) = jobs.removeAt(0);
          final res = pool.take(t);
          if (rp == null) {
            take(b, res.data);
          } else {
            place(rp, ZxEncodedBlock.fromResult(res));
          }
        }
      }
    } finally {
      pool.close();
    }
  }

  // the new place of b[off, off + len)
  void remap(int b, int off, int len, List<int> out) {
    final nb = newOf[b];
    if (nb != null) {
      zxAddExtent(out, nb, off, len);
      return;
    }
    final s = segs[b];
    if (s == null) zxDamaged('an extent of a block not copied');
    var p = off;
    final end = off + len;
    var i = 0;
    while (p < end) {
      while (i < s.length && s[i + 1] <= p) {
        i += 4;
      }
      if (i >= s.length || s[i] > p) zxDamaged('an extent not copied');
      final e = s[i + 1] < end ? s[i + 1] : end;
      zxAddExtent(out, s[i + 2], s[i + 3] + p - s[i], e - p);
      p = e;
    }
  }

  // the new place of a chunk, when it is used and in one block
  (int, int)? remapChunk(int b, int off, int len) {
    final nb = newOf[b];
    if (nb != null) return (nb, off);
    final s = segs[b];
    if (s == null) return null;
    for (var i = 0; i < s.length; i += 4) {
      if (s[i] <= off && off + len <= s[i + 1]) {
        return (s[i + 2], s[i + 3] + off - s[i]);
      }
    }
    return null;
  }

  // the chunk runs of the last kept generation: the chunks of the runs
  // (and of a chunk table of zx 0.5.0) of the last Index that lie whole in
  // bytes still used, at their new places; the earlier kept generations
  // get none (only the last Index serves a writer)
  List<ZxChunkRunRef>? newRuns;
  final lastSrc = indexes.isEmpty ? null : indexes.last;
  if (lastSrc != null) {
    final srcRuns = <ZxChunkRun>[];
    for (final ref in lastSrc.chunkRunsValid?.runs ?? const <ZxChunkRunRef>[]) {
      try {
        srcRuns.add(ZxChunkRun.open(r.volumes, ref, keys));
      } on SevenZipException catch (e) {
        o.warnings.add('zx: a chunk run can not be read (${e.message}): '
            'its chunks are left out');
      }
    }
    final legacy = lastSrc.chunksValid;
    final mem = legacy == null
        ? null
        : ZxMemChunks.sort(Uint8List.fromList(legacy.sha),
            Int64List.fromList(legacy.locs), legacy.length);
    if (srcRuns.isNotEmpty || mem != null) {
      var cap = zxRunMaxRecords;
      if (multi) {
        final fit = (sink.emptyRoom! - 1024) ~/ 50;
        if (fit < cap) cap = fit;
      }
      if (cap >= zxRunPageRecords) {
        final out = newRuns = <ZxChunkRunRef>[];
        final enc = keys != null;
        zxMergeRuns(
            () => [
                  if (mem != null) mem.cursor(),
                  for (final x in srcRuns.reversed) x.cursor(),
                ], (count) {
          final size = zxRunBlockSize(count, enc);
          if (multi && size > sink.room!) sink.nextVolume();
          out.add(ZxChunkRunRef(sink.volume, sink.position, size, count));
          return ZxRunWriter(sink.write, count, keys);
        }, map: remapChunk, maxRecords: cap);
      }
    }
  }

  final newGens = <ZxGeneration>[];
  ZxIndexLoc? prev;
  late ZxFooter footer;
  for (var gi = 0; gi < kept.length; gi++) {
    final g = kept[gi];
    final src = indexes[gi];
    final idx = ZxIndex();
    final chainIds = <int>{};
    for (final e in src.entries) {
      final c = e.copy();
      final x = <int>[];
      for (var i = 0; i < e.extents.length; i += 3) {
        remap(e.extents[i], e.extents[i + 1], e.extents[i + 2], x);
      }
      for (var i = 0; i < x.length; i += 3) {
        chainIds.add(blocks[x[i]].chainId);
      }
      c.extents = Int64List.fromList(x);
      idx.entries.add(c);
    }
    for (final id in chainIds) {
      final c = chains[id];
      if (c != null) idx.chains[id] = c;
    }
    idx.blocks = blocks;
    if (src.shaTable != null) {
      idx.shaTable = src.shaTable;
    }
    idx.tlshList = src.tlshList;
    final nr = newRuns;
    if (gi == kept.length - 1 && nr != null && nr.isNotEmpty) {
      idx.chunkRuns = ZxChunkRuns(0, nr);
    }
    idx.previous = prev;
    idx.generation = g;
    idx.generations = [...newGens, g.at(null)];
    var mr = src.minReaderVersion ?? (0, 5, 0);
    final (cv, exp) = zxChainRequirements([
      for (final id in chainIds) ...?chains[id]?.coders,
    ]);
    final need = exp ? zxVersion : cv;
    if (zxCompareVersions(need, mr) > 0) mr = need;
    idx.minReaderVersion = mr;
    idx.requiredFeatures = (src.requiredFeatures &
            ~(ZxFeature.multiVolume | ZxFeature.solid | ZxFeature.dedup)) |
        zxSharingFeatures(idx.entries) |
        (multi ? ZxFeature.multiVolume : 0);
    idx.optionalFeatures = src.optionalFeatures;
    idx.other.addAll(src.other);
    if (multi) idx.volumes = sink.volumeTable();
    final start = sink.position;
    final vol = sink.volume;
    final content = idx.encode(multiVolume: multi);
    // metadata blocks with the Header's chain
    var off = 0;
    do {
      var n = content.length - off;
      if (n > _metaBlockSize) n = _metaBlockSize;
      final part =
          Uint8List.fromList(Uint8List.sublistView(content, off, off + n));
      off += n;
      final useKeys = h.encryptedMetadata ? keys : null;
      final enc = zxEncodeBlock(ZxEncodeArg(
          part,
          h.metaChain == null
              ? const []
              : const [ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 5))],
          ZxCheck.crc32c,
          useKeys?.aesKey,
          useKeys?.macKey));
      final chainId = enc.coders.isEmpty ? 0 : _metaChainId;
      final hdr = ZxBlockHeader.encode(ZxBlockType.index, chainId,
          enc.unpackedSize, enc.payload.length, enc.checkType, enc.check);
      if (useKeys != null) {
        useKeys.mac(ZxBlockHeader.macPart(hdr), enc.payload);
      }
      sink.write(hdr);
      sink.write(enc.payload);
    } while (off < content.length);
    final size = sink.position - start;
    footer = ZxFooter(start, size, blocks.length);
    sink.write(footer.encode());
    prev = ZxIndexLoc(vol, start, size);
    newGens.add(g.at(prev));
  }
  final end = sink.position;
  final vols = sink.close();
  return ZxWriteResult(
      kept.isEmpty ? 0 : kept.last.number, blocks.length, 0, packed, vols, end,
      workers: workers);
}

// a repacked block before its coding: data, the ranges it holds as flat
// (old block, start, end, offset), its block type
class _Repacked {
  final Uint8List data;
  final List<int> segs;
  final int type;
  _Repacked(this.data, this.segs, this.type);
}

/// The bytes of each block that the entries of [indexes] use, as sorted
/// and merged flat (start, end) pairs, by block.
Map<int, Int64List> _liveRanges(List<ZxIndex> indexes) {
  final raw = <int, List<int>>{};
  for (final idx in indexes) {
    for (final e in idx.entries) {
      final x = e.extents;
      for (var i = 0; i < x.length; i += 3) {
        if (x[i + 2] == 0) continue;
        (raw[x[i]] ??= <int>[])
          ..add(x[i + 1])
          ..add(x[i + 1] + x[i + 2]);
      }
    }
  }
  final out = <int, Int64List>{};
  raw.forEach((b, l) {
    final n = l.length ~/ 2;
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, c) => l[2 * a] - l[2 * c]);
    final m = <int>[];
    for (final i in order) {
      final s = l[2 * i], e = l[2 * i + 1];
      if (m.isNotEmpty && s <= m[m.length - 1]) {
        if (e > m[m.length - 1]) m[m.length - 1] = e;
      } else {
        m
          ..add(s)
          ..add(e);
      }
    }
    out[b] = Int64List.fromList(m);
  });
  return out;
}

/// Encodes a string as UTF-8 bytes.
Uint8List zxUtf8(String s) => Uint8List.fromList(utf8.encode(s));
