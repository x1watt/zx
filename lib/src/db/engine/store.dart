// The zxdb store inside a .zx archive (docs/zxdb-design.md, phase 1; the
// format in docs/zx-format.md section 16).
//
// Every commit appends one archive generation: the page blocks (type 7)
// of the pages the transaction wrote, the map pages that changed, then an
// Index (the last Index with a new database root, record 0x49) and a
// Footer. File entries of the archive are carried unchanged, and updates
// of the files (zx_handler.dart) carry the database root, so both kinds
// of generations interleave; the writer lock (zx_lock.dart) keeps one
// writer at a time. A crash before the Footer leaves the previous
// generation current, and the next commit cuts the partial one.
//
// Synchronous: the async API runs it in a worker isolate (zxdb_async.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../codec/lzma/lzma2_dec.dart' show lzma2DictSizeFromProp;
import '../../crypto/sha256.dart';
import '../../format/zx/zx_blocks.dart';
import '../../format/zx/zx_codecs.dart';
import '../../format/zx/zx_crypto.dart';
import '../../format/zx/zx_format.dart';
import '../../format/zx/zx_lock.dart';
import '../../format/zx/zx_reader.dart';
import '../../format/zx/zx_writer.dart';
import '../../io/streams.dart';
import '../../pool.dart' show defaultThreads;
import '../../sync_pool.dart';
import '../../version.dart' show zxVersion;
import '../storage_api.dart';
import 'btree.dart';
import 'compression.dart';
import 'dbfile.dart';
import 'page.dart';

/// Settings of a [ZxDbStore].
class ZxDbStoreOptions {
  /// Budget of decoded pages kept in memory, bytes.
  int pageCacheBytes;

  /// Budget of decoded page blocks kept in memory, bytes (a block holds
  /// several pages; a cold read of a page decodes its whole block).
  int blockCacheBytes;

  /// Page size of trees that do not set one.
  int pageSize;

  /// Compression of trees that do not set one (docs/zxdb-design.md 3).
  String compression;

  /// Flush the file to the disk at each commit (fsync).
  bool durable;

  /// ZxDatabase folds (in the background with the async API) when the
  /// write buffer holds more than this many bytes after a commit (0: only
  /// an explicit fold()). The store itself folds only when asked.
  int autoFoldBytes;

  /// Unpacked size of the page blocks written by a fold (the unit a cold
  /// read decodes: larger compresses better, reads slower).
  int foldGroupBytes;

  /// Unpacked size of the page blocks written at commit.
  int commitGroupBytes;

  /// A write transaction whose changed pages exceed about this many bytes
  /// writes them to the file before its commit (they become part of the
  /// generation it appends; a rollback cuts them), so a large import does
  /// not hold every changed page in memory.
  int txnMemoryBytes;

  /// Worker isolates of a fold (their memory is kept under [memoryLimit]).
  int threads;
  int? memoryLimit;

  /// The check of page blocks (xxHash64).
  int checkType;

  /// Reads look for commits of other writers (processes, isolates) at
  /// most this often, in microseconds (a stat of the file). Writes always
  /// start from the last generation.
  int refreshMicros;

  /// The clock of the generations (ns since epoch); tests may fix it.
  int Function()? clock;

  ZxDbStoreOptions(
      {this.pageCacheBytes = 128 << 20,
      this.blockCacheBytes = 32 << 20,
      this.pageSize = 16384,
      this.compression = 'max',
      this.durable = true,
      this.autoFoldBytes = 16 << 20,
      this.foldGroupBytes = 256 << 10,
      this.commitGroupBytes = 64 << 10,
      this.txnMemoryBytes = 128 << 20,
      int? threads,
      this.memoryLimit,
      this.checkType = ZxCheck.xxh64,
      this.refreshMicros = 1000,
      this.clock})
      : threads = threads ?? defaultThreads();
}

/// What a fold did.
class ZxDbFoldResult {
  final int pages;
  final int bytesIn;
  final int bytesOut;
  final int? generation;
  const ZxDbFoldResult(this.pages, this.bytesIn, this.bytesOut, this.generation);
}

/// A tree of the catalog: its number (the tag of its pages), its root
/// page, its entry count and options.
class TreeMeta {
  final String name;
  final int id;
  int root;
  int count;
  TreeOptions options;
  TreeMeta(this.name, this.id, this.root, this.count, this.options);

  int get tag => id < 0xFFFF ? id : 0xFFFF;

  // vint version 1, vint id, vint root, vint count, vint page size (0:
  // default), vint 1 then string compression, or vint 0
  Uint8List encode() {
    final w = ZxBytes(32);
    w.vint(1);
    w.vint(id);
    w.vint(root);
    w.vint(count);
    w.vint(options.pageSize ?? 0);
    final c = options.compression;
    if (c == null) {
      w.vint(0);
    } else {
      w.vint(1);
      w.string(c);
    }
    return w.toBytes();
  }

  static TreeMeta decode(String name, Uint8List b) {
    try {
      final r = ZxRead(b);
      if (r.vint() != 1) {
        throw const ZxDbException(
            'unsupported catalog record', ZxDbError.unsupported);
      }
      final id = r.vint(), root = r.vint(), count = r.vint();
      final ps = r.vint();
      final c = r.vint() == 1 ? r.string() : null;
      return TreeMeta(name, id, root, count,
          TreeOptions(compression: c, pageSize: ps == 0 ? null : ps));
    } on SevenZipException catch (e) {
      throw ZxDbException('damaged catalog: ${e.message}', ZxDbError.corrupt);
    }
  }
}

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

// the state of the archive's last generation
class _Head {
  final ZxIndex index;
  final ZxIndexLoc loc;
  final int end;

  /// Every generation, the last one located.
  final List<ZxGeneration> gens;
  final DbView view;
  _Head(this.index, this.loc, this.end, this.gens, this.view);

  int get number => gens.last.number;
  int get time => gens.last.time;
}

/// The database store of one .zx archive ([ZxStore]).
class ZxDbStore implements ZxStore {
  final String path;
  final ZxDbStoreOptions options;
  final bool readOnly;
  final String? _password;

  late DbFile _file;
  late _Head _head;
  final List<DbFile> _oldFiles = [];
  final Map<int, ZxIndex> _indexes = {};
  _DbTxn? _txn;
  bool _closed = false;
  int _statSize = -1;
  DateTime? _statTime;

  /// Messages about damage that was worked around (an interrupted commit).
  final List<String> warnings = [];

  /// Called by every commit of a transaction that wrote something, before
  /// it is written, with the transaction (ZxDatabase sets it: the
  /// metadata tables of a new database, the TLSH band index). It may
  /// write to the transaction.
  void Function(ZxWriteTxn txn)? beforeCommit;

  /// Called after every commit that appended a generation, with its
  /// number (ZxDatabaseAsync folds in the background from it).
  void Function(int generation)? afterCommit;

  ZxDbStore._(this.path, this.options, this.readOnly, this._password);

  /// Opens the store of the archive at [path]; with [create] a missing
  /// archive is made (empty, generation 1). With [password] the archive's
  /// data (and by default its Index) is encrypted: the pages too.
  static ZxDbStore open(String path,
      {String? password,
      bool readOnly = false,
      bool create = false,
      ZxDbStoreOptions? options}) {
    final s = ZxDbStore._(path, options ?? ZxDbStoreOptions(), readOnly,
        password == null || password.isEmpty ? null : password);
    if (!File(path).existsSync()) {
      if (!create || readOnly) {
        throw ZxDbException('no archive at $path', ZxDbError.notFound);
      }
      s._createArchive();
    }
    s._openFile();
    return s;
  }

  void _createArchive() {
    final tmp = '$path.zx-part';
    final o = ZxWriteOptions()
      ..password = _password
      ..threads = 1
      ..generationComment = 'database created';
    final clock = options.clock;
    if (clock != null) o.time = clock();
    final f = FileOutStream.create(tmp);
    try {
      ZxWriter.create(o, (h) => ZxStreamSink(f)).finish();
      f.flush();
    } catch (_) {
      f.close();
      try {
        File(tmp).deleteSync();
      } on FileSystemException {
        // ignore
      }
      rethrow;
    }
    f.close();
    if (File(path).existsSync()) {
      File(tmp).deleteSync();
    } else {
      File(tmp).renameSync(path);
    }
  }

  // opens (or opens again) the file and reads its last generation
  void _openFile({DbFile? reuse}) {
    final raf = reuse?.raf ?? File(path).openSync();
    try {
      final st = FileStat.statSync(path);
      final ZxArchiveReader? r;
      try {
        r = ZxArchiveReader.open(FileInStream(raf),
            ZxOpenParams(path: path, password: () => _password));
      } on ZxNeedPasswordException {
        throw const ZxDbException(
            'the archive is encrypted: a password is needed',
            ZxDbError.generic);
      } on SevenZipException catch (e) {
        if (e.kind == SevenZipError.wrongPassword) {
          throw const ZxDbException('wrong password', ZxDbError.generic);
        }
        throw ZxDbException(e.message, ZxDbError.corrupt);
      }
      if (r == null) {
        throw ZxDbException('$path is not a .zx archive', ZxDbError.corrupt);
      }
      if (r.header.multiVolume) {
        throw const ZxDbException(
            'a database can not live in a multi-volume archive',
            ZxDbError.unsupported);
      }
      warnings.addAll(r.warnings);
      ZxKeys? keys;
      try {
        keys = r.header.kdf == null ? null : r.keysFor(() => _password);
      } on ZxNeedPasswordException {
        throw const ZxDbException(
            'the archive is encrypted: a password is needed',
            ZxDbError.generic);
      } on SevenZipException {
        throw const ZxDbException('wrong password', ZxDbError.generic);
      }
      final file = reuse ??
          DbFile(path, raf, r.header, keys,
              pageCacheBytes: options.pageCacheBytes,
              blockCacheBytes: options.blockCacheBytes);
      file.addChains(r.lastIndex.chains);
      final gens = List<ZxGeneration>.of(r.generations);
      gens[gens.length - 1] = gens.last.at(r.lastIndexLoc);
      _file = file;
      _indexes.clear();
      _head = _Head(r.lastIndex, r.lastIndexLoc, r.validEnd, gens,
          DbView(file, r.lastIndex.database));
      _statSize = st.size;
      _statTime = st.modified;
    } catch (_) {
      if (reuse == null) raf.closeSync();
      rethrow;
    }
  }

  // when the file was last checked for commits of other writers
  final Stopwatch _sinceCheck = Stopwatch();

  // reads the last generation again when another writer changed the file;
  // the file is checked at most every refreshMicros unless [force]
  void _refresh({bool force = false}) {
    if (!force &&
        _sinceCheck.isRunning &&
        _sinceCheck.elapsedMicroseconds < options.refreshMicros) {
      return;
    }
    _sinceCheck
      ..reset()
      ..start();
    final st = FileStat.statSync(path);
    if (st.type == FileSystemEntityType.notFound) {
      throw ZxDbException('the archive $path is gone', ZxDbError.notFound);
    }
    if (st.size == _statSize && st.modified == _statTime) return;
    final same = _file.length == st.size;
    if (same && st.size > _head.end && !_footerAtEnd(st.size)) {
      // pages of a transaction in progress (spilled), or a partial
      // commit: the last generation is the same
      _statSize = st.size;
      _statTime = st.modified;
      return;
    }
    if (same) {
      _openFile(reuse: _file);
    } else {
      // replaced (a compaction by another process): a new file; open
      // snapshots keep reading the old one
      _oldFiles.add(_file);
      _openFile();
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('the store is closed');
  }

  bool _footerAtEnd(int size) {
    if (size < zxFooterSize) return false;
    final b = _file.readAt(size - zxFooterSize, zxFooterSize);
    return ZxFooter.tryParse(b, 0) != null;
  }

  /// The number of the last generation.
  int get lastGeneration {
    _checkOpen();
    _refresh();
    return _head.number;
  }

  /// The page cache (hits and misses, for tests and statistics).
  ({int hits, int misses, int bytes}) get pageCacheStats => (
        hits: _file.pages.hits,
        misses: _file.pages.misses,
        bytes: _file.pages.bytes
      );

  /// Drops every cached page and block (tests of cold reads).
  void clearCaches() {
    _file.pages.clear();
    _file.blocks.clear();
    _file.maps.clear();
    _head = _Head(_head.index, _head.loc, _head.end, _head.gens,
        DbView(_file, _head.index.database));
  }

  /// Bytes of pages in the write buffer (not folded).
  int get unfoldedBytes {
    _checkOpen();
    return _head.index.database?.unfoldedBytes ?? 0;
  }

  /// The archive generations (with the counts of record 0x44: entries
  /// added, deleted, bytes written), oldest first.
  List<ZxGeneration> get archiveGenerations {
    _checkOpen();
    _refresh();
    return List.unmodifiable(_head.gens);
  }

  /// The database root of the last generation (null before the first
  /// commit), for tools and tests.
  ZxDbRoot? get root => _head.index.database;

  ZxIndex _indexOf(ZxGeneration g) {
    if (g.number == _head.number) return _head.index;
    final hit = _indexes[g.number];
    if (hit != null) return hit;
    ZxIndex idx;
    final loc = g.index;
    if (loc != null) {
      idx = _file.readIndex(loc);
    } else {
      idx = _head.index;
      while ((idx.generation?.number ?? 0) > g.number) {
        final p = idx.previous;
        if (p == null) break;
        idx = _file.readIndex(p);
      }
      if (idx.generation?.number != g.number) {
        throw ZxDbException(
            'the Index of generation ${g.number} is not found',
            ZxDbError.corrupt);
      }
    }
    if (_indexes.length > 32) _indexes.remove(_indexes.keys.first);
    _indexes[g.number] = idx;
    return idx;
  }

  @override
  ZxSnapshot snapshot({int? generation, int? atTimeNs}) {
    _checkOpen();
    _refresh();
    final gens = _head.gens;
    ZxGeneration? g;
    if (generation != null) {
      for (final x in gens) {
        if (x.number == generation) g = x;
      }
      if (g == null) {
        throw ZxDbException('no generation $generation', ZxDbError.notFound);
      }
    } else if (atTimeNs != null) {
      for (final x in gens) {
        if (x.time <= atTimeNs) g = x;
      }
      if (g == null) {
        throw ZxDbException(
            'no generation at or before $atTimeNs', ZxDbError.notFound);
      }
    } else {
      return _DbSnapshot(_head.number, _head.time, _head.view);
    }
    if (g.number == _head.number) {
      return _DbSnapshot(g.number, g.time, _head.view);
    }
    final idx = _indexOf(g);
    return _DbSnapshot(g.number, g.time, DbView(_file, idx.database));
  }

  @override
  ZxWriteTxn begin({int waitMs = 5000}) {
    _checkOpen();
    if (readOnly) {
      throw const ZxDbException('the store is read only', ZxDbError.readOnly);
    }
    if (_txn != null) {
      throw const ZxDbException(
          'a write transaction of this store is open', ZxDbError.busy);
    }
    final lock = ZxWriteLock.tryAcquire(path, waitMs: waitMs);
    if (lock == null) {
      throw const ZxDbException(
          'another writer holds the archive', ZxDbError.busy);
    }
    try {
      _refresh(force: true);
    } catch (_) {
      lock.release();
      rethrow;
    }
    return _txn = _DbTxn(this, lock, _head);
  }

  @override
  List<({int generation, int timeNs, String? comment})> get generations {
    _checkOpen();
    _refresh();
    return [
      for (final g in _head.gens)
        (
          generation: g.number,
          timeNs: g.time,
          comment: g.comment.isEmpty ? null : g.comment
        )
    ];
  }

  @override
  void close() {
    if (_closed) return;
    final t = _txn;
    if (t != null && !t._closed) t.rollback();
    _closed = true;
    _file.close();
    for (final f in _oldFiles) {
      f.close();
    }
  }

  int _now() {
    final c = options.clock;
    var t = c != null ? c() : DateTime.now().microsecondsSinceEpoch * 1000;
    if (t < _head.time) t = _head.time;
    return t;
  }

  // ---- writing a generation

  // a writer of blocks after the last valid Footer; an interrupted
  // commit left bytes after it: they are cut (dart:io's append mode
  // positions at the end once, at open)
  _GenWriter _openWriter() {
    final end = _head.end;
    final raf = File(path).openSync(mode: FileMode.append);
    try {
      if (raf.lengthSync() > end) raf.truncateSync(end);
      raf.setPositionSync(end);
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
    return _GenWriter(this, raf, end);
  }

  /// Appends a generation whose database root is made by [build] (which
  /// writes the page blocks through the [_GenWriter] it gets). Called
  /// with the writer lock held.
  int _appendGeneration(
      String? comment, ZxDbRoot Function(_GenWriter w) build,
      {_GenWriter? writer}) {
    final head = _head;
    final w = writer ?? _openWriter();
    final raf = w.raf;
    try {
      final root = build(w);
      final number = head.number + 1;
      final time = _now();
      final idx = ZxIndex();
      final last = head.index;
      idx.chains.addAll(last.chains);
      idx.chains.addAll(w.newChains);
      idx.blocks = last.blocks;
      idx.entries = last.entries;
      idx.shaTable = last.shaTable;
      idx.tlshList = last.tlshList;
      idx.chunkTable = last.chunkTable;
      final runs = last.chunkRunsValid;
      if (runs != null) idx.chunkRuns = ZxChunkRuns(0, runs.runs);
      idx.volumes = last.volumes;
      idx.other.addAll(last.other);
      idx.previous = head.loc;
      final gen = ZxGeneration(
          number, time, comment ?? '', null, 0, 0, w.pos - head.end);
      idx.generation = gen;
      idx.generations = [...head.gens, gen];
      var mr = last.minReaderVersion ?? (0, 5, 0);
      final (cv, exp) = zxChainRequirements(
          [for (final c in idx.chains.values) ...c.coders]);
      final need = exp ? zxVersion : cv;
      if (zxCompareVersions(need, mr) > 0) mr = need;
      idx.minReaderVersion = mr;
      idx.requiredFeatures = last.requiredFeatures |
          ZxFeature.appendable |
          ZxFeature.database |
          (_file.keys != null ? ZxFeature.encryption : 0);
      idx.optionalFeatures = last.optionalFeatures;
      idx.database = root;
      final start = w.pos;
      w.writeIndex(idx.encode(multiVolume: false));
      // the runs are valid for the block table just encoded
      if (runs != null) {
        idx.chunkRuns = ZxChunkRuns(idx.blockTableHash, runs.runs);
      }
      final size = w.pos - start;
      w.write(ZxFooter(start, size, idx.blocks.length).encode());
      w.flush();
      if (options.durable) raf.flushSync();
      final loc = ZxIndexLoc(0, start, size);
      _file.addChains(idx.chains);
      final gens = [...head.gens, gen.at(loc)];
      _head = _Head(idx, loc, w.pos, gens, DbView(_file, root));
      final st = FileStat.statSync(path);
      _statSize = st.size;
      _statTime = st.modified;
      return number;
    } finally {
      raf.closeSync();
    }
  }

  // the map pages of [base] with the pages of [locs] placed and the ids
  // of [freed] cleared, written as page blocks; the new map list and the
  // change of the write buffer bytes
  (List<ZxDbLoc?>, int) _writeMaps(_GenWriter w, ZxDbRoot? base,
      Map<int, ZxDbLoc> locs, Iterable<int> freed, int nextPageId) {
    final byMap = <int, List<int>>{};
    for (final id in locs.keys) {
      (byMap[id >> ZxDbRoot.mapPageLog2] ??= []).add(id);
    }
    for (final id in freed) {
      (byMap[id >> ZxDbRoot.mapPageLog2] ??= []).add(-id);
    }
    final count = nextPageId <= 1
        ? 0
        : ((nextPageId - 1) >> ZxDbRoot.mapPageLog2) + 1;
    final maps = List<ZxDbLoc?>.filled(count, null);
    if (base != null) {
      for (var k = 0; k < base.maps.length && k < count; k++) {
        maps[k] = base.maps[k];
      }
    }
    var unfolded = 0;
    final keys = byMap.keys.toList()..sort();
    final pages = <(int, Uint8List)>[];
    for (final k in keys) {
      final old = k < (base?.maps.length ?? 0) ? base!.maps[k] : null;
      final m = old == null
          ? Uint8List(mapPageBytes)
          : Uint8List.fromList(_file.mapPage(old));
      for (final sid in byMap[k]!) {
        final id = sid < 0 ? -sid : sid;
        final off = (id & (ZxDbRoot.mapPageEntries - 1)) * ZxDbLoc.entrySize;
        final prev = ZxDbLoc.readEntry(m, off);
        if (prev != null && prev.isUnfolded) unfolded -= prev.length;
        if (sid < 0) {
          m.fillRange(off, off + ZxDbLoc.entrySize, 0);
        } else {
          final loc = locs[id]!;
          loc.writeEntry(m, off);
          if (loc.isUnfolded) unfolded += loc.length;
        }
      }
      pages.add((k, m));
    }
    // map pages go into page blocks with the fast chain
    final groups = <List<(int, Uint8List)>>[];
    var cur = <(int, Uint8List)>[];
    var bytes = 0;
    for (final p in pages) {
      if (cur.isNotEmpty && bytes + p.$2.length > (256 << 10)) {
        groups.add(cur);
        cur = [];
        bytes = 0;
      }
      cur.add(p);
      bytes += p.$2.length;
    }
    if (cur.isNotEmpty) groups.add(cur);
    for (final g in groups) {
      final placed =
          w.writeGroup([for (final p in g) p.$2], zxDbFastChain, 0);
      for (var i = 0; i < g.length; i++) {
        maps[g[i].$1] = placed[i];
      }
    }
    return (maps, unfolded);
  }

  /// Folds the write buffer: the pages of trees whose compression is not
  /// 'store' or 'fast' that were written with the fast codec at commit
  /// are coded again with their tree's chain, in blocks of
  /// [ZxDbStoreOptions.foldGroupBytes], by worker isolates. The coding
  /// runs without the writer lock (a fold can take long with zcm); the
  /// lock is taken to write the blocks, and pages that a commit changed
  /// meanwhile keep their new version. One generation (comment "fold")
  /// per [roundBytes] of pages. [all] recodes every page, not only the
  /// buffer (vacuum's recompression), and [override] replaces the chain of
  /// the trees whose compression is 'balanced', 'max' or 'ultra' ('ultra'
  /// for VACUUM ULTRA).
  ZxDbFoldResult fold(
      {int waitMs = 5000,
      bool all = false,
      String? override,
      int roundBytes = 64 << 20}) {
    _checkOpen();
    if (readOnly) {
      throw const ZxDbException('the store is read only', ZxDbError.readOnly);
    }
    if (_txn != null) {
      throw const ZxDbException(
          'a write transaction of this store is open', ZxDbError.busy);
    }
    var pages = 0, bytesIn = 0, bytesOut = 0;
    int? gen;
    final done = <int>{};
    for (;;) {
      _refresh(force: true);
      final plan = _foldPlan(all, override, roundBytes, done);
      if (plan == null) break;
      final lock = ZxWriteLock.tryAcquire(path, waitMs: waitMs);
      if (lock == null) {
        throw const ZxDbException(
            'another writer holds the archive', ZxDbError.busy);
      }
      try {
        _refresh(force: true);
        final r = _foldApply(plan);
        pages += r.pages;
        bytesIn += r.bytesIn;
        bytesOut += r.bytesOut;
        gen = r.generation ?? gen;
      } finally {
        lock.release();
      }
      if (!plan.more) break;
    }
    return ZxDbFoldResult(pages, bytesIn, bytesOut, gen);
  }

  // the fold with the lock held (vacuum)
  void _foldLocked(bool all, String? override) {
    final done = <int>{};
    for (;;) {
      final plan = _foldPlan(all, override, 64 << 20, done);
      if (plan == null) return;
      _foldApply(plan);
      if (!plan.more) return;
    }
  }

  // the pages of one fold round and their coded groups; [done] holds the
  // page ids of earlier rounds (skipped)
  _FoldPlan? _foldPlan(
      bool all, String? override, int roundBytes, Set<int> done) {
    final base = _head.index.database;
    if (base == null || (!all && base.unfoldedBytes == 0)) return null;
    final view = _head.view;
    // the compression of each tree, by tag
    final comp = <int, String?>{};
    final cur = TreeCursor(() => view, () => view.catalogRoot, () {});
    while (cur.moveNext()) {
      final m = TreeMeta.decode(utf8.decode(cur.key), cur.value);
      var c = m.options.compression;
      if (override != null) {
        final l = (c ?? options.compression).toLowerCase();
        if (l == 'balanced' || l == 'max' || l == 'ultra') c = override;
      }
      comp[m.tag] = c;
    }
    // the pages to code again, by tree, up to [roundBytes]
    final byTag = <int, List<(int, ZxDbLoc)>>{};
    var total = 0;
    var more = false;
    for (var k = 0; k < base.maps.length && !more; k++) {
      final ml = base.maps[k];
      if (ml == null) continue;
      final m = _file.mapPage(ml);
      for (var i = 0; i < ZxDbRoot.mapPageEntries; i++) {
        final loc = ZxDbLoc.readEntry(m, i * ZxDbLoc.entrySize);
        if (loc == null) continue;
        final tag = loc.treeTag;
        if (tag == 0) continue; // the catalog stays fast
        final id = (k << ZxDbRoot.mapPageLog2) + i;
        if (done.contains(id)) continue;
        // with [all] every page is coded again with its tree's current
        // chain (a tree whose policy changed gets it everywhere)
        if (!loc.isUnfolded && !all) continue;
        if (total >= roundBytes) {
          more = true;
          break;
        }
        (byTag[tag] ??= []).add((id, loc));
        done.add(id);
        total += loc.length;
      }
    }
    if (byTag.isEmpty) return null;
    final groupMax = options.foldGroupBytes.clamp(4096, 2 << 20);
    final groups = <_FoldGroup>[];
    for (final tag in byTag.keys.toList()..sort()) {
      final specs = zxDbChainFor(comp[tag],
          fallback: options.compression, groupBytes: groupMax);
      final list = byTag[tag]!..sort((a, b) => a.$1 - b.$1);
      var g = <(int, ZxDbLoc)>[];
      var bytes = 0;
      for (final e in list) {
        if (g.isNotEmpty && bytes + e.$2.length > groupMax) {
          groups.add(_FoldGroup(tag, specs, g));
          g = [];
          bytes = 0;
        }
        g.add(e);
        bytes += e.$2.length;
      }
      if (g.isNotEmpty) groups.add(_FoldGroup(tag, specs, g));
    }
    // code the groups in worker isolates, as many as fit in the memory
    final limit = options.memoryLimit ?? zxDefaultMemoryLimit();
    var per = 0;
    for (final g in groups) {
      final m = zxWorkerMemory(g.specs, groupMax);
      if (m > per) per = m;
    }
    final pool = SyncJobPool(zxWorkersFor(options.threads, per, limit));
    final k = _file.keys;
    try {
      final tickets = <int>[];
      var next = 0;
      for (var i = 0; i < groups.length; i++) {
        while (next < groups.length && next - i <= pool.threads) {
          final g = groups[next++];
          final parts = [for (final e in g.pages) _file.pageBytes(e.$2)];
          var n = 0;
          for (final p in parts) {
            n += p.length;
          }
          final data = Uint8List(n);
          var o = 0;
          for (final p in parts) {
            data.setRange(o, o + p.length, p);
            o += p.length;
          }
          tickets.add(pool.submit(
              zxEncodeBlockJob,
              ZxEncodeArg(
                  data, g.specs, options.checkType, k?.aesKey, k?.macKey)));
        }
        groups[i].encoded = ZxEncodedBlock.fromResult(pool.take(tickets[i]));
      }
    } finally {
      pool.close();
    }
    return _FoldPlan(groups, more);
  }

  // writes the coded groups of [plan] in one generation, for the pages
  // still where the plan found them
  ZxDbFoldResult _foldApply(_FoldPlan plan) {
    final base = _head.index.database;
    if (base == null) return const ZxDbFoldResult(0, 0, 0, null);
    final view = _head.view;
    bool same(int id, ZxDbLoc a) {
      final b = view.locOf(id);
      return b != null &&
          b.blockOffset == a.blockOffset &&
          b.inOffset == a.inOffset &&
          b.length == a.length;
    }

    final live = [
      for (final g in plan.groups)
        if (g.pages.any((e) => same(e.$1, e.$2))) g
    ];
    if (live.isEmpty) return const ZxDbFoldResult(0, 0, 0, null);
    var pagesDone = 0, bytesIn = 0, bytesOut = 0;
    final gen = _appendGeneration('fold', (w) {
      final locs = <int, ZxDbLoc>{};
      for (final g in live) {
        final placed = w.placeEncoded(
            g.encoded!, [for (final e in g.pages) e.$2.length], g.tag, false);
        bytesOut += placed.first.blockSize;
        for (var j = 0; j < g.pages.length; j++) {
          final (id, old) = g.pages[j];
          if (!same(id, old)) continue;
          locs[id] = placed[j];
          bytesIn += old.length;
          pagesDone++;
        }
      }
      final (maps, delta) =
          _writeMaps(w, base, locs, const [], base.nextPageId);
      var unf = base.unfoldedBytes + delta;
      if (unf < 0) unf = 0;
      return ZxDbRoot(
          nextPageId: base.nextPageId,
          catalogRoot: base.catalogRoot,
          nextTreeId: base.nextTreeId,
          unfoldedBytes: unf,
          maps: maps,
          free: base.free);
    });
    return ZxDbFoldResult(pagesDone, bytesIn, bytesOut, gen);
  }

  /// Compacts the archive (docs/zx-format.md section 9.2) keeping the
  /// last [keep] generations, the database included: with [recompress]
  /// every page is coded again with its tree's chain first, and [ultra]
  /// makes that the strongest (VACUUM ULTRA). The archive is written
  /// again next to itself and renamed over it. Returns the bytes freed.
  int vacuum(
      {int keep = 1,
      bool recompress = false,
      bool ultra = false,
      int waitMs = 5000}) {
    _checkOpen();
    if (readOnly) {
      throw const ZxDbException('the store is read only', ZxDbError.readOnly);
    }
    if (_txn != null) {
      throw const ZxDbException(
          'a write transaction of this store is open', ZxDbError.busy);
    }
    final lock = ZxWriteLock.tryAcquire(path, waitMs: waitMs);
    if (lock == null) {
      throw const ZxDbException(
          'another writer holds the archive', ZxDbError.busy);
    }
    try {
      _refresh(force: true);
      _foldLocked(recompress || ultra, ultra ? 'ultra' : null);
      final before = File(path).lengthSync();
      final tmp = '$path.zx-compact';
      final raf = File(path).openSync();
      try {
        final r = ZxArchiveReader.open(FileInStream(raf),
            ZxOpenParams(path: path, password: () => _password))!;
        final f = FileOutStream.create(tmp);
        try {
          final o = ZxWriteOptions()
            ..threads = options.threads
            ..memoryLimit = options.memoryLimit;
          zxCompact(r, keep, (h) => ZxStreamSink(f),
              password: _password, options: o);
          f.flush();
        } catch (_) {
          f.close();
          try {
            File(tmp).deleteSync();
          } on FileSystemException {
            // ignore
          }
          rethrow;
        }
        f.close();
      } finally {
        raf.closeSync();
      }
      final after = File(tmp).lengthSync();
      _oldFiles.add(_file);
      File(tmp).renameSync(path);
      _openFile();
      return before - after;
    } on SevenZipException catch (e) {
      throw ZxDbException('vacuum failed: ${e.message}', ZxDbError.generic);
    } finally {
      lock.release();
    }
  }
}

// one group of pages of a fold, coded with the chain of its tree
class _FoldGroup {
  final int tag;
  final List<ZxCoderSpec> specs;
  final List<(int, ZxDbLoc)> pages;
  ZxEncodedBlock? encoded;
  _FoldGroup(this.tag, this.specs, this.pages);
}

class _FoldPlan {
  final List<_FoldGroup> groups;

  /// More pages wait for the next round.
  final bool more;
  _FoldPlan(this.groups, this.more);
}

// writes the blocks of one generation after the last valid Footer
class _GenWriter {
  final ZxDbStore s;
  final RandomAccessFile raf;
  int pos;
  final Map<int, ZxChain> newChains = {};
  final BytesBuilder _buf = BytesBuilder(copy: false);

  _GenWriter(this.s, this.raf, this.pos);

  ZxKeys? get keys => s._file.keys;

  void write(Uint8List b) {
    _buf.add(b);
    pos += b.length;
    if (_buf.length >= (1 << 20)) flush();
  }

  void flush() {
    if (_buf.isEmpty) return;
    raf.writeFromSync(_buf.takeBytes());
  }

  int chainIdFor(List<ZxCoder> coders) {
    if (coders.isEmpty) return 0;
    for (final c in s._file.chains.values) {
      if (c.sameCoders(coders)) return c.id;
    }
    for (final c in newChains.values) {
      if (c.sameCoders(coders)) return c.id;
    }
    var id = 2; // after the metadata chain
    for (final k in s._file.chains.keys) {
      if (k >= id) id = k + 1;
    }
    for (final k in newChains.keys) {
      if (k >= id) id = k + 1;
    }
    final meta = s._file.header.metaChain;
    if (meta != null && meta.id >= id) id = meta.id + 1;
    newChains[id] = ZxChain(id, coders);
    s._file.chains[id] = newChains[id]!;
    return id;
  }

  ZxEncodeArg encodeArg(List<Uint8List> pages, List<ZxCoderSpec> specs) {
    var n = 0;
    for (final p in pages) {
      n += p.length;
    }
    final data = Uint8List(n);
    var o = 0;
    for (final p in pages) {
      data.setRange(o, o + p.length, p);
      o += p.length;
    }
    final k = keys;
    return ZxEncodeArg(data, specs, s.options.checkType, k?.aesKey, k?.macKey);
  }

  /// Writes an encoded group of pages of [lengths]; returns their places.
  List<ZxDbLoc> placeEncoded(
      ZxEncodedBlock enc, List<int> lengths, int tag, bool unfolded) {
    final chainId = chainIdFor(enc.coders);
    final hdr = ZxBlockHeader.encode(ZxBlockType.dbPages, chainId,
        enc.unpackedSize, enc.payload.length, enc.checkType, enc.check);
    final k = keys;
    if (k != null) k.mac(ZxBlockHeader.macPart(hdr), enc.payload);
    final at = pos;
    final size = hdr.length + enc.payload.length;
    write(hdr);
    write(enc.payload);
    final flags = (unfolded ? ZxDbLoc.unfolded : 0) | (tag << 16);
    final out = <ZxDbLoc>[];
    var off = 0;
    for (final l in lengths) {
      out.add(ZxDbLoc(at, size, off, l, flags));
      off += l;
    }
    return out;
  }

  /// Codes [pages] with [specs] here and writes them as one block.
  List<ZxDbLoc> writeGroup(List<Uint8List> pages, List<ZxCoderSpec> specs,
      int tag,
      {bool unfolded = false}) {
    final enc = zxEncodeBlock(encodeArg(pages, specs));
    return placeEncoded(enc, [for (final p in pages) p.length], tag, unfolded);
  }

  /// Writes the Index blocks of [content]: stored when small, else with
  /// the Header's metadata chain (LZMA2) at a fast level.
  void writeIndex(Uint8List content) {
    final header = s._file.header;
    final k = header.encryptedMetadata ? keys : null;
    const maxPart = 16 << 20;
    var off = 0;
    do {
      var n = content.length - off;
      if (n > maxPart) n = maxPart;
      final part =
          Uint8List.fromList(Uint8List.sublistView(content, off, off + n));
      off += n;
      final meta = header.metaChain;
      var specs = const <ZxCoderSpec>[];
      if (meta != null &&
          n > (64 << 10) &&
          meta.coders.length == 1 &&
          meta.coders[0].codecId == ZxCodecId.lzma2 &&
          meta.coders[0].props.length == 1) {
        final dict = lzma2DictSizeFromProp(meta.coders[0].props[0]);
        specs = [
          ZxCoderSpec(ZxCodecId.lzma2,
              ZxCoderConfig(level: 1, params: 'd=${dict >> 10}k'))
        ];
      }
      var enc = zxEncodeBlock(
          ZxEncodeArg(part, specs, ZxCheck.crc32c, k?.aesKey, k?.macKey));
      var chainId = 0;
      if (enc.coders.isNotEmpty) {
        if (meta != null && meta.sameCoders(enc.coders)) {
          chainId = meta.id;
        } else {
          enc = zxEncodeBlock(ZxEncodeArg(
              part, const [], ZxCheck.crc32c, k?.aesKey, k?.macKey));
        }
      }
      final hdr = ZxBlockHeader.encode(ZxBlockType.index, chainId,
          enc.unpackedSize, enc.payload.length, enc.checkType, enc.check);
      if (k != null) k.mac(ZxBlockHeader.macPart(hdr), enc.payload);
      write(hdr);
      write(enc.payload);
    } while (off < content.length);
  }
}

// ---------------------------------------------------------------------------
// snapshots

class _DbSnapshot implements ZxSnapshot {
  @override
  final int generation;
  @override
  final int timeNs;
  final DbView view;
  bool _closed = false;
  final Map<String, _DbTree?> _trees = {};

  _DbSnapshot(this.generation, this.timeNs, this.view);

  void _check() {
    if (_closed) throw StateError('the snapshot is closed');
  }

  @override
  List<String> get treeNames {
    _check();
    final out = <String>[];
    final c = TreeCursor(() => view, () => view.catalogRoot, _check);
    while (c.moveNext()) {
      out.add(utf8.decode(c.key));
    }
    return out;
  }

  @override
  ZxTree? tree(String name) {
    _check();
    if (_trees.containsKey(name)) return _trees[name];
    final v = treeGet(view, view.catalogRoot, _utf8(name));
    final t = v == null
        ? null
        : _DbTree(this, TreeMeta.decode(name, resolveValue(view, v)));
    return _trees[name] = t;
  }

  @override
  void close() {
    _closed = true;
    _trees.clear();
  }
}

class _DbTree implements ZxTree {
  final _DbSnapshot snap;
  final TreeMeta meta;
  _DbTree(this.snap, this.meta);

  @override
  String get name => meta.name;

  @override
  TreeOptions get options => meta.options;

  @override
  int get length => meta.count;

  @override
  Uint8List? get(Uint8List key) {
    snap._check();
    final v = treeGet(snap.view, meta.root, key);
    return v == null ? null : resolveValue(snap.view, v);
  }

  @override
  ZxCursor scan({Uint8List? from, Uint8List? to, bool reverse = false}) {
    snap._check();
    return TreeCursor(() => snap.view, () => meta.root, snap._check,
        from: from, to: to, reverse: reverse);
  }
}

// ---------------------------------------------------------------------------
// the write transaction

/// The tree of the shared overflow values (whole-value deduplication):
/// key 's' + SHA-256 of a value, value its first page id as a 'p' key;
/// key 'p' + u64 first page id, value vint references, vint length, vint
/// page count, the page ids, 32 bytes SHA-256.
const String zxDbBlobTree = r'zx$blob';

class _DbTxn implements ZxWriteTxn, PageWriter, BlobStore {
  final ZxDbStore store;
  final ZxWriteLock lock;
  final _Head head;
  final DbView view;
  bool _closed = false;
  bool _touched = false;

  final Map<int, Node> dirty = {};
  final Set<int> freed = {};
  int nextPageId;
  final List<int> freeRuns;
  int nextTreeId;

  // trees: loaded metas (null: known absent), the ones changed
  final Map<String, TreeMeta?> metas = {};
  final Set<String> changed = {};
  final Map<String, _TxnTree> handles = {};
  late final TreeWriter catalog;

  _DbTxn(this.store, this.lock, this.head)
      : view = head.view,
        nextPageId = head.view.root?.nextPageId ?? 1,
        freeRuns = List.of(head.view.root?.free ?? const []),
        nextTreeId = head.view.root?.nextTreeId ?? 1 {
    catalog = TreeWriter(this, view.catalogRoot, 0, 16384, 0);
  }

  void _check() {
    if (_closed) throw StateError('the transaction is closed');
  }

  // ---- PageWriter

  @override
  Node read(int id) {
    final d = dirty[id];
    if (d != null) return d;
    final sp = spilled[id];
    if (sp != null) return store._file.node(sp);
    return view.page(id);
  }

  @override
  Node write(int id) {
    final d = dirty[id];
    if (d != null) return d;
    final n = read(id).copy();
    dirty[id] = n;
    _dirtyBytes += n.bytes < 4096 ? 4096 : n.bytes;
    return n;
  }

  @override
  int alloc(Node n) {
    _dirtyBytes += n.bytes < 4096 ? 4096 : n.bytes;
    int id;
    if (freeRuns.isNotEmpty) {
      id = freeRuns[0];
      freeRuns[0]++;
      if (--freeRuns[1] == 0) freeRuns.removeRange(0, 2);
    } else {
      id = nextPageId++;
    }
    dirty[id] = n;
    return id;
  }

  @override
  void free(int id) {
    dirty.remove(id);
    spilled.remove(id);
    freed.add(id);
  }

  // ---- spilling changed pages before the commit

  /// Pages written to the file before the commit (by [_spill]).
  final Map<int, ZxDbLoc> spilled = {};
  int _dirtyBytes = 0;

  // tree operations in progress (a spill waits until they end)
  int _depth = 0;
  _GenWriter? _writer;

  // after a write: spill when the changed pages use too much memory
  void _maybeSpill() {
    if (_dirtyBytes > store.options.txnMemoryBytes) _spill();
  }

  void _spill() {
    final w = _writer ??= store._openWriter();
    spilled.addAll(_writePages(w));
    // readable now (the pages are read again through the page cache)
    w.flush();
    dirty.clear();
    _dirtyBytes = 0;
  }

  // writes the changed pages as page blocks: the pages of 'store' and
  // 'fast' trees with their chain, the others with the fast chain of the
  // write buffer; returns their places
  Map<int, ZxDbLoc> _writePages(_GenWriter w) {
    final o = store.options;
    final finalOf = <int, bool>{0: true};
    final chainOf = <int, List<ZxCoderSpec>>{0: zxDbFastChain};
    for (final m in metas.values) {
      if (m == null) continue;
      final c = m.options.compression;
      final fin = zxDbFinalAtCommit(c, fallback: o.compression);
      finalOf[m.tag] = fin;
      chainOf[m.tag] =
          fin ? zxDbChainFor(c, fallback: o.compression) : zxDbFastChain;
    }
    final ids = dirty.keys.toList()..sort();
    final byTag = <int, List<int>>{};
    for (final id in ids) {
      (byTag[dirty[id]!.tree] ??= []).add(id);
    }
    final locs = <int, ZxDbLoc>{};
    for (final tag in byTag.keys.toList()..sort()) {
      final fin = finalOf[tag] ?? false;
      final specs = chainOf[tag] ?? zxDbFastChain;
      var parts = <Uint8List>[];
      var partIds = <int>[];
      var bytes = 0;
      void flushGroup() {
        if (parts.isEmpty) return;
        final placed = w.writeGroup(parts, specs, tag, unfolded: !fin);
        for (var i = 0; i < partIds.length; i++) {
          locs[partIds[i]] = placed[i];
        }
        parts = [];
        partIds = [];
        bytes = 0;
      }

      for (final id in byTag[tag]!) {
        final b = dirty[id]!.encode();
        if (parts.isNotEmpty && bytes + b.length > o.commitGroupBytes) {
          flushGroup();
        }
        parts.add(b);
        partIds.add(id);
        bytes += b.length;
      }
      flushGroup();
    }
    return locs;
  }

  // ---- shared overflow values

  _TxnTree get _blobTree =>
      (tree(zxDbBlobTree) ??
          createTree(zxDbBlobTree, const TreeOptions(compression: 'fast')))
          as _TxnTree;

  static Uint8List _pageKey(int id) {
    final k = Uint8List(9);
    k[0] = 0x70; // 'p'
    for (var i = 0; i < 8; i++) {
      k[8 - i] = (id >> (8 * i)) & 0xFF;
    }
    return k;
  }

  @override
  Overflow storeBlob(Uint8List value, int tag) {
    final sha = Sha256.hash(value);
    final t = _blobTree;
    final sk = Uint8List(33)
      ..[0] = 0x73 // 's'
      ..setRange(1, 33, sha);
    final first = t.get(sk);
    if (first != null) {
      final pk = Uint8List.fromList(first);
      final rec = t.get(pk);
      if (rec != null) {
        final r = ZxRead(rec);
        final refs = r.vint(), len = r.vint(), n = r.vint();
        final ids = [for (var i = 0; i < n; i++) r.vint()];
        if (len == value.length) {
          t.put(pk, _blobRecord(refs + 1, len, ids, sha));
          return Overflow(len, ids);
        }
      }
    }
    final o = TreeWriter.storePieces(this, value, tag);
    final pk = _pageKey(o.pages[0]);
    t.put(sk, pk);
    t.put(pk, _blobRecord(1, o.length, o.pages, sha));
    return o;
  }

  static Uint8List _blobRecord(int refs, int len, List<int> ids, Uint8List sha) {
    final w = ZxBytes(16 + 5 * ids.length + 32);
    w.vint(refs);
    w.vint(len);
    w.vint(ids.length);
    for (final id in ids) {
      w.vint(id);
    }
    w.bytes(sha);
    return w.toBytes();
  }

  @override
  void releaseBlob(Overflow o) {
    if (o.pages.isEmpty) return;
    final t = tree(zxDbBlobTree) as _TxnTree?;
    final pk = _pageKey(o.pages[0]);
    final rec = t?.get(pk);
    if (t == null || rec == null) {
      // not shared: its own pages
      o.pages.forEach(free);
      return;
    }
    final r = ZxRead(rec);
    final refs = r.vint(), len = r.vint(), n = r.vint();
    final ids = [for (var i = 0; i < n; i++) r.vint()];
    final sha = Uint8List.fromList(r.bytes(32));
    if (refs > 1) {
      t.put(pk, _blobRecord(refs - 1, len, ids, sha));
      return;
    }
    t.delete(pk);
    t.delete(Uint8List(33)
      ..[0] = 0x73
      ..setRange(1, 33, sha));
    ids.forEach(free);
  }

  // ---- trees

  TreeMeta? _meta(String name) {
    if (metas.containsKey(name)) return metas[name];
    final v = treeGet(this, catalog.root, _utf8(name));
    final m = v == null ? null : TreeMeta.decode(name, resolveValue(this, v));
    metas[name] = m;
    return m;
  }

  @override
  int get generation => head.number;

  @override
  int get timeNs => head.time;

  @override
  List<String> get treeNames {
    _check();
    final names = <String>{};
    final c = TreeCursor(() => this, () => catalog.root, _check);
    while (c.moveNext()) {
      names.add(utf8.decode(c.key));
    }
    metas.forEach((n, m) {
      if (m == null) {
        names.remove(n);
      } else {
        names.add(n);
      }
    });
    return names.toList()..sort();
  }

  @override
  ZxWritableTree? tree(String name) {
    _check();
    final h = handles[name];
    if (h != null) return h;
    final m = _meta(name);
    if (m == null) return null;
    return handles[name] = _TxnTree(this, m);
  }

  @override
  ZxWritableTree createTree(String name,
      [TreeOptions options = const TreeOptions()]) {
    _check();
    if (name.isEmpty) {
      throw const ZxDbException('empty tree name', ZxDbError.constraint);
    }
    if (utf8.encode(name).length > zxMaxKeyLength) {
      throw const ZxDbException('tree name too long', ZxDbError.constraint);
    }
    if (_meta(name) != null) {
      throw ZxDbException('tree "$name" exists', ZxDbError.constraint);
    }
    zxDbCheckPageSize(options.pageSize);
    zxDbCheckCompression(options.compression);
    final m = TreeMeta(name, nextTreeId++, 0, 0, options);
    metas[name] = m;
    changed.add(name);
    _touched = true;
    return handles[name] = _TxnTree(this, m);
  }

  @override
  void dropTree(String name) {
    _check();
    final m = _meta(name);
    if (m == null) {
      throw ZxDbException('no tree "$name"', ZxDbError.notFound);
    }
    final h = handles[name];
    final w = h?._w ??
        TreeWriter(this, m.root, m.count, 16384, m.tag,
            blobs: name == zxDbBlobTree ? null : this);
    _depth++;
    try {
      w.drop();
    } finally {
      _depth--;
    }
    handles.remove(name);
    h?._dropped = true;
    metas[name] = null;
    changed.add(name);
    _touched = true;
  }

  @override
  void setTreeOptions(String name, TreeOptions options) {
    _check();
    final m = _meta(name);
    if (m == null) {
      throw ZxDbException('no tree "$name"', ZxDbError.notFound);
    }
    zxDbCheckPageSize(options.pageSize);
    zxDbCheckCompression(options.compression);
    m.options = options;
    changed.add(name);
    _touched = true;
  }

  // ---- end

  void _end() {
    _closed = true;
    store._txn = null;
    final w = _writer;
    _writer = null;
    if (w != null) {
      // a rollback: the spilled pages are cut, and the caches forget what
      // was read from them (a later commit writes other blocks there)
      try {
        w.raf.truncateSync(head.end);
        w.raf.closeSync();
      } on FileSystemException {
        // the next commit cuts them
      }
    }
    if (spilled.isNotEmpty) {
      final f = store._file;
      f.pages.clear();
      f.blocks.clear();
      f.maps.clear();
    }
    lock.release();
  }

  @override
  int commit({String? comment}) {
    _check();
    try {
      if (!_touched) return head.number;
      store.beforeCommit?.call(this);
      final gen = _commit(comment);
      spilled.clear();
      _end();
      store.afterCommit?.call(gen);
      return gen;
    } finally {
      if (!_closed) _end();
    }
  }

  int _commit(String? comment) {
    // the catalog
    for (final name in changed) {
      final m = metas[name];
      final k = _utf8(name);
      if (m == null) {
        catalog.delete(k);
      } else {
        catalog.put(k, m.encode());
      }
    }
    final base = view.root;
    final spillWriter = _writer;
    _writer = null;
    late Map<int, ZxDbLoc> written;
    final gen = store._appendGeneration(comment, (w) {
      written = _writePages(w);
      final locs = <int, ZxDbLoc>{...spilled, ...written};
      // free ids: the runs left and the ids freed here
      final free = _mergeFree(freeRuns, freed);
      final (maps, delta) = store._writeMaps(w, base, locs, freed, nextPageId);
      var unf = (base?.unfoldedBytes ?? 0) + delta;
      if (unf < 0) unf = 0;
      return ZxDbRoot(
          nextPageId: nextPageId,
          catalogRoot: catalog.root,
          nextTreeId: nextTreeId,
          unfoldedBytes: unf,
          maps: maps,
          free: free);
    }, writer: spillWriter);
    // the pages just written are decoded already: they go to the page
    // cache as they are (the transaction is over, nothing changes them)
    final cache = store._file.pages;
    written.forEach((id, loc) {
      final n = dirty[id];
      if (n != null) cache.put(loc.cacheKey, n);
    });
    return gen;
  }

  static List<int> _mergeFree(List<int> runs, Set<int> freed) {
    if (freed.isEmpty) return runs;
    final ids = <int>[];
    for (var i = 0; i < runs.length; i += 2) {
      for (var k = 0; k < runs[i + 1]; k++) {
        ids.add(runs[i] + k);
      }
    }
    ids.addAll(freed);
    ids.sort();
    final out = <int>[];
    for (final id in ids) {
      if (out.isNotEmpty && out[out.length - 2] + out[out.length - 1] == id) {
        out[out.length - 1]++;
      } else if (out.isEmpty || out[out.length - 2] + out[out.length - 1] < id) {
        out
          ..add(id)
          ..add(1);
      }
    }
    return out;
  }

  @override
  void rollback() {
    _check();
    _end();
  }

  @override
  void close() {
    if (!_closed) rollback();
  }
}

class _TxnTree implements ZxWritableTree {
  final _DbTxn txn;
  final TreeMeta meta;
  TreeWriter? _writer;
  int _mods = 0;
  bool _dropped = false;

  _TxnTree(this.txn, this.meta);

  void _check() {
    txn._check();
    if (_dropped) throw StateError('the tree "${meta.name}" was dropped');
  }

  TreeWriter get _w => _writer ??= TreeWriter(
      txn,
      meta.root,
      meta.count,
      meta.options.pageSize ?? txn.store.options.pageSize,
      meta.tag,
      blobs: meta.name == zxDbBlobTree ? null : txn);

  int get _root => _writer?.root ?? meta.root;

  @override
  String get name => meta.name;

  @override
  TreeOptions get options => meta.options;

  @override
  int get length => _writer?.count ?? meta.count;

  @override
  Uint8List? get(Uint8List key) {
    _check();
    final v = treeGet(txn, _root, key);
    return v == null ? null : resolveValue(txn, v);
  }

  @override
  ZxCursor scan({Uint8List? from, Uint8List? to, bool reverse = false}) {
    _check();
    return TreeCursor(() => txn, () => _root, _check,
        mods: () => _mods, from: from, to: to, reverse: reverse);
  }

  void _changed() {
    final w = _w;
    meta.root = w.root;
    meta.count = w.count;
    _mods++;
    txn.changed.add(meta.name);
    txn._touched = true;
    // not inside another tree's operation (the shared values tree is
    // written in the middle of a put): its pages are held by it
    if (txn._depth == 0) txn._maybeSpill();
  }

  @override
  void put(Uint8List key, Uint8List value) {
    _check();
    if (key.length > zxMaxKeyLength) {
      throw ZxDbException(
          'key of ${key.length} bytes (at most $zxMaxKeyLength)',
          ZxDbError.constraint);
    }
    txn._depth++;
    try {
      _w.put(key, value);
    } finally {
      txn._depth--;
    }
    _changed();
  }

  @override
  bool delete(Uint8List key) {
    _check();
    bool had;
    txn._depth++;
    try {
      had = _w.delete(key);
    } finally {
      txn._depth--;
    }
    if (had) _changed();
    return had;
  }

  @override
  int deleteRange({Uint8List? from, Uint8List? to}) {
    _check();
    var n = 0;
    for (;;) {
      final batch = <Uint8List>[];
      final c = TreeCursor(() => txn, () => _root, _check, from: from, to: to);
      while (batch.length < 1024 && c.moveNext()) {
        batch.add(c.key);
      }
      if (batch.isEmpty) break;
      txn._depth++;
      try {
        for (final k in batch) {
          if (_w.delete(k)) n++;
        }
      } finally {
        txn._depth--;
      }
      _changed();
    }
    return n;
  }
}
