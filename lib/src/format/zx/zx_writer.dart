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

/// Free bytes on the disk of [dir], or null when unknown (df on POSIX
/// systems, the drive's free space on Windows).
int? zxFreeSpace(String dir) {
  try {
    if (Platform.isWindows) {
      final r = Process.runSync('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-Item -LiteralPath "$dir").PSDrive.Free'
      ]);
      return int.tryParse((r.stdout as String).trim());
    }
    final r = Process.runSync('df', ['-Pk', dir]);
    if (r.exitCode != 0) return null;
    final lines = (r.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    final f = lines.last.trim().split(RegExp(r'\s+'));
    if (f.length < 4) return null;
    final k = int.tryParse(f[3]);
    return k == null ? null : k * 1024;
  } on Object {
    return null;
  }
}

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
    var want = _sizeOf(_vol);
    String? dir;
    for (var i = 0; i < dirs.length; i++) {
      final d = dirs[i];
      var cap = want;
      final b = d.budget;
      if (b != null) {
        final left = b - (_usedInDir[i] ?? 0);
        if (left < cap) cap = left;
      }
      if (d.untilFull) {
        final free = zxFreeSpace(d.path);
        if (free != null && free - (1 << 20) < cap) cap = free - (1 << 20);
      }
      if (cap >= header.size + 4 * zxFooterSize + 4096) {
        dir = d.path;
        want = cap;
        _usedInDir[i] = (_usedInDir[i] ?? 0) + cap;
        break;
      }
    }
    if (dirs.isEmpty) {
      final f = File(baseName);
      dir = f.parent.path;
    }
    if (dir == null) {
      throw SevenZipException(
          'zx: no destination folder has room for volume ${_vol + 1}',
          SevenZipError.io);
    }
    final name = _name(_vol).split(Platform.pathSeparator).last;
    final path = '$dir${Platform.pathSeparator}$name';
    onFile?.call(path);
    Directory(dir).createSync(recursive: true);
    _f = File(path).openSync(mode: FileMode.write);
    _path = path;
    _written.add(path);
    _limit = want;
    _pos = 0;
    header.volumeNumber = _vol;
    header.volumeCount = null;
    _raw(header.encode());
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
  int? get room => _limit - _pos - zxFooterSize;
  @override
  int? get emptyRoom => _sizeOf(_vol + 1) - header.size - zxFooterSize;

  @override
  void write(Uint8List b) => _raw(b);

  void _closeCurrent() {
    _drain();
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

/// The largest file read whole for the whole-file dedup check.
const int _wholeFileLimit = 64 << 20;

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
  // the chunk table of the last generation, carried when dedup is off
  ZxChunkTable? _carried;
  int _dupBytes = 0, _storedChunks = 0, _reusedChunks = 0, _reusedFiles = 0;

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
      .._loadOld(last);
  }

  // the chunks and the files of the last generation, which new data can
  // reuse (dedup); the chunks that do not fit the block table are left out
  void _loadOld(ZxIndex last) {
    final t = last.chunksValid;
    final clear = keys != null && !header.encryptedMetadata;
    if (!_dedupOn) {
      _carried = clear ? null : t;
      return;
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

  // a file with dedup: a file identical to one stored (same size and
  // SHA-256) reuses its extents; otherwise its chunks are looked up and
  // only the new ones are stored
  int _addDedup(ZxEntry e, InStream data, int? knownSize) {
    final nd = _NewData(e);
    _new.add(nd);
    final sha = Sha256();
    final tl = o.tlsh ? Tlsh() : null;
    var src = data;
    if (knownSize != null &&
        knownSize > 0 &&
        knownSize <= _wholeFileLimit &&
        _sizes.contains(knownSize)) {
      // one more byte than the size tells a file that grew
      final buf = Uint8List(knownSize + 1);
      final n = readFully(data, buf, 0, buf.length);
      final view = Uint8List.sublistView(buf, 0, n);
      if (n == knownSize) {
        final h = Sha256.hash(view);
        final hit = _findWhole(h, n);
        if (hit != null) {
          nd.pieces.addAll(hit);
          nd.length = n;
          e.size = n;
          e.sha256 = h;
          e.tlsh = tl == null ? null : (tl..update(view)).digest();
          _dupBytes += n;
          _reusedFiles++;
          _addWhole(h, n, nd);
          return n;
        }
      }
      src = n > knownSize
          ? ConcatInStream([MemoryInStream(view), data])
          : MemoryInStream(view);
    }
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
        final n = src.read(cb, fill, want);
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
    e.size = nd.length;
    e.sha256 = sha.digest();
    e.tlsh = tl?.digest();
    if (nd.length > 0) _addWhole(e.sha256!, nd.length, nd);
    return nd.length;
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
    ix.add(_digest, -1, pos, len);
    _storedChunks++;
    zxAddExtent(nd.pieces, -1, pos, len);
    if (_fill == o.blockSize) _flushBlock();
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

  // the chunk table of the new Index: the chunks known, placed; a chunk
  // that a volume cut split between two blocks is left out
  ZxChunkTable? _chunkTable() {
    final ix = _chunks;
    if (ix == null) return _carried;
    final n = ix.length;
    final locs = Int64List(3 * n);
    final sha = Uint8List(32 * n);
    var k = 0;
    var sorted = true;
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
      if (k > 0 &&
          (locs[3 * k - 3] > b ||
              (locs[3 * k - 3] == b && locs[3 * k - 2] > off))) {
        sorted = false;
      }
      locs[3 * k] = b;
      locs[3 * k + 1] = off;
      locs[3 * k + 2] = len;
      sha.setRange(32 * k, 32 * k + 32, ix.shaOf(id));
      k++;
    }
    if (!sorted) {
      final order = List<int>.generate(k, (i) => i)
        ..sort((x, y) {
          final d = locs[3 * x] - locs[3 * y];
          return d != 0 ? d : locs[3 * x + 1] - locs[3 * y + 1];
        });
      final l2 = Int64List(3 * k);
      final s2 = Uint8List(32 * k);
      for (var i = 0; i < k; i++) {
        final o = order[i];
        l2.setRange(3 * i, 3 * i + 3, locs, 3 * o);
        s2.setRange(32 * i, 32 * i + 32, sha, 32 * o);
      }
      return ZxChunkTable(0, l2, s2);
    }
    return ZxChunkTable(0, Int64List.sublistView(locs, 0, 3 * k),
        Uint8List.sublistView(sha, 0, 32 * k));
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
    }
    _computeExtents();

    final idx = ZxIndex();
    idx.chains.addAll(_chains);
    idx.blocks = _blocks;
    // a clear Index of an encrypted archive holds no content hashes
    final clearOfEncrypted = keys != null && !header.encryptedMetadata;
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
    // the chunk table holds SHA-256 values: not in a clear Index of an
    // encrypted archive
    if (!clearOfEncrypted) idx.chunkTable = _chunkTable();
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
    if (!repack || covered >= last.blocks[b].unpackedSize) {
      whole.add(b);
    } else {
      part.add(b);
    }
  }

  // every chain declared in a kept generation; repacked blocks may add one
  final chains = <int, ZxChain>{...last.chains};
  for (final idx in indexes) {
    for (final c in idx.chains.values) {
      chains.putIfAbsent(c.id, () => c);
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
    final t = src.chunksValid;
    if (t != null) idx.chunkTable = _remapChunks(t, remapChunk);
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

// the chunks of [t] still used, at their new places, sorted
ZxChunkTable _remapChunks(
    ZxChunkTable t, (int, int)? Function(int b, int off, int len) remap) {
  final keep = <(int, int, int, int)>[]; // block, offset, length, index
  for (var i = 0; i < t.length; i++) {
    final len = t.locs[3 * i + 2];
    final p = remap(t.locs[3 * i], t.locs[3 * i + 1], len);
    if (p != null) keep.add((p.$1, p.$2, len, i));
  }
  keep.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  final locs = Int64List(3 * keep.length);
  final sha = Uint8List(32 * keep.length);
  for (var k = 0; k < keep.length; k++) {
    final (b, off, len, i) = keep[k];
    locs[3 * k] = b;
    locs[3 * k + 1] = off;
    locs[3 * k + 2] = len;
    sha.setRange(32 * k, 32 * k + 32, t.sha, 32 * i);
  }
  return ZxChunkTable(0, locs, sha);
}

/// Encodes a string as UTF-8 bytes.
Uint8List zxUtf8(String s) => Uint8List.fromList(utf8.encode(s));
