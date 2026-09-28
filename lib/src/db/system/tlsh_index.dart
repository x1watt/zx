// TLSH band index: sublinear similarity search over the TLSH digests of an
// archive (docs/zxdb-design.md 1.1, arca whitepaper Appendix C).
//
// Scheme. A TLSH digest (docs/zx-format.md 6.3) has a 3 byte header
// (checksum, length class, quartile ratios) and a 32 byte body of 128
// two-bit bucket codes. Its distance is the sum of the per-bucket
// differences (0, 1, 2, or 6 for 0 against 3) plus header terms. The body
// is cut into 16 bands of 2 bytes (8 buckets each); each band value
// (band number, 16 bits) is a term. A digest is a candidate for a query
// when it shares at least one band value with the query or, with
// multi-probe (the default, level 1), with one of the up to 16 variants of
// the query's band in which one bucket moves by one step (the changes
// that cost 1 in the distance). Candidates are then ranked by the exact
// distance. The quartile coding makes bucket values close to uniform, so
// a band value holds about N / 65536 digests: 1M digests give about 250
// candidates without probes and about 4000 with them.
//
// Recall: a near duplicate whose differing buckets leave one band intact
// (or change it by one step in one bucket) is always found. For two
// digests at body distance d with the differences spread at random, the
// chance of missing is about (1 - (1 - 8/128)^d')^16 over the d' changed
// buckets; at d' = 20 it is under 1% with probes. The search is exact
// ("similar(q, n, 'exact')" or exact: true) by a linear scan with a
// per-query 16-bit table (16 lookups per digest).
//
// Two forms:
//   - in memory, built lazily per archive generation from its TLSH list:
//     per band, a counting sort of the digest numbers by band value
//     (offsets[65537] and ids[n], 4 bytes per digest per band);
//   - persisted in the database, keyed by content (SHA-256), so one index
//     serves every generation (AS OF filters the hits by the SHA-256 table
//     of that generation): tree zx_tlsh_bands holds
//     key [band][value hi][value lo][sha256], empty value, and zx_tlsh_digests
//     maps sha256 to the 35 byte binary digest; zx_tlsh_state holds the last
//     generation indexed. [ZxTlshStore.sync] adds the content of newer
//     generations (called when a database transaction commits).
// ZxSimilarity uses the persisted form when the database has it and it is
// up to date for the generation asked, the lazy form otherwise.

import 'dart:convert';
import 'dart:typed_data';

import '../../util/tlsh.dart';
import '../storage_api.dart';
import 'archive_view.dart';
import 'sys_vtab.dart';

/// Bytes of a binary digest: checksum, length class, quartiles (q1 low
/// nibble, q2 high nibble), 32 body bytes.
const int tlshBinSize = 35;
const int tlshBands = 16;

/// The binary form of a digest text, or null when it does not parse.
Uint8List? tlshToBinary(String s) {
  final d = TlshDigest.parse(s);
  if (d == null) return null;
  final b = Uint8List(tlshBinSize);
  b[0] = d.checksum;
  b[1] = d.lValue;
  b[2] = d.q1Ratio | (d.q2Ratio << 4);
  b.setRange(3, 35, d.code);
  return b;
}

final Uint8List _pairByte = () {
  final t = Uint8List(65536);
  for (var a = 0; a < 256; a++) {
    for (var b = 0; b < 256; b++) {
      var d = 0;
      for (var k = 0; k < 8; k += 2) {
        final x = ((a >> k) & 3) - ((b >> k) & 3);
        final ax = x < 0 ? -x : x;
        d += ax == 3 ? 6 : ax;
      }
      t[(a << 8) | b] = d;
    }
  }
  return t;
}();

int _modDiff(int x, int y, int r) {
  final dl = y > x ? y - x : x - y;
  final dr = r - dl;
  return dl > dr ? dr : dl;
}

int _headerDiff(Uint8List a, int ao, Uint8List b, int bo) {
  final ld = _modDiff(a[ao + 1], b[bo + 1], 256);
  var diff = ld <= 1 ? ld : ld * 12;
  final q1 = _modDiff(a[ao + 2] & 15, b[bo + 2] & 15, 16);
  diff += q1 <= 1 ? q1 : (q1 - 1) * 12;
  final q2 = _modDiff(a[ao + 2] >> 4, b[bo + 2] >> 4, 16);
  diff += q2 <= 1 ? q2 : (q2 - 1) * 12;
  if (a[ao] != b[bo]) diff++;
  return diff;
}

/// The TLSH distance of two binary digests at [ao] and [bo] (the same as
/// [tlshDistance] of their texts).
int tlshBinDistance(Uint8List a, int ao, Uint8List b, int bo) {
  var d = _headerDiff(a, ao, b, bo);
  final t = _pairByte;
  for (var i = 3; i < tlshBinSize; i++) {
    d += t[(a[ao + i] << 8) | b[bo + i]];
  }
  return d;
}

int _bandValue(Uint8List d, int o, int band) =>
    (d[o + 3 + 2 * band] << 8) | d[o + 4 + 2 * band];

/// The band values probed for [v]: itself, then (level >= 1) every value
/// with one bucket moved by one step.
List<int> tlshProbes(int v, int level) {
  final out = [v];
  if (level < 1) return out;
  for (var p = 0; p < 16; p += 2) {
    final x = (v >> p) & 3;
    if (x > 0) out.add(v - (1 << p));
    if (x < 3) out.add(v + (1 << p));
  }
  return out;
}

/// Keeps the [k] smallest (distance, id) pairs.
class _TopK {
  final int k;
  final List<int> dist = [];
  final List<int> ids = [];
  _TopK(this.k);

  int get worst => dist.length < k ? 1 << 30 : dist.last;

  void add(int id, int d) {
    if (dist.length >= k && d >= dist.last) return;
    var i = dist.length;
    while (i > 0 && (dist[i - 1] > d || (dist[i - 1] == d && ids[i - 1] > id))) {
      i--;
    }
    dist.insert(i, d);
    ids.insert(i, id);
    if (dist.length > k) {
      dist.removeLast();
      ids.removeLast();
    }
  }
}

/// The in-memory band index over [count] binary digests.
class TlshBandIndex {
  /// count x 35 bytes.
  final Uint8List digests;
  final int count;
  final List<Uint32List> _offsets;
  final List<Uint32List> _ids;
  final Uint32List _seen;
  int _stamp = 0;

  TlshBandIndex._(this.digests, this.count, this._offsets, this._ids)
      : _seen = Uint32List(count);

  /// Builds the index over [digests] (count x 35 bytes).
  factory TlshBandIndex.build(Uint8List digests) {
    final n = digests.length ~/ tlshBinSize;
    final offsets = <Uint32List>[];
    final ids = <Uint32List>[];
    for (var band = 0; band < tlshBands; band++) {
      final off = Uint32List(65537);
      for (var i = 0; i < n; i++) {
        off[_bandValue(digests, i * tlshBinSize, band) + 1]++;
      }
      for (var v = 0; v < 65536; v++) {
        off[v + 1] += off[v];
      }
      final fill = Uint32List.fromList(off.sublist(0, 65536));
      final l = Uint32List(n);
      for (var i = 0; i < n; i++) {
        l[fill[_bandValue(digests, i * tlshBinSize, band)]++] = i;
      }
      offsets.add(off);
      ids.add(l);
    }
    return TlshBandIndex._(digests, n, offsets, ids);
  }

  /// Builds the index over digest texts (callers pass texts that parse;
  /// one that does not gets an all-zero digest).
  factory TlshBandIndex.fromTexts(List<String> texts) {
    final d = Uint8List(texts.length * tlshBinSize);
    for (var i = 0; i < texts.length; i++) {
      final b = tlshToBinary(texts[i]);
      if (b != null) d.setRange(i * tlshBinSize, (i + 1) * tlshBinSize, b);
    }
    return TlshBandIndex.build(d);
  }

  /// Bytes the index holds (digests and band arrays).
  int get memoryBytes =>
      digests.length + tlshBands * (65537 * 4 + count * 4) + count * 4;

  /// The [k] nearest digests to [q] among the band candidates, nearest
  /// first, as (id, distance); [maxDistance] drops the farther ones and
  /// [skip] excludes ids. [probeLevel] 0 looks up the exact band values
  /// only, 1 (default) also their one-step variants.
  List<(int, int)> query(Uint8List q, int k,
      {int? maxDistance, int probeLevel = 1, bool Function(int id)? skip}) {
    final top = _TopK(k);
    if (k <= 0) return const [];
    var stamp = ++_stamp;
    if (stamp == 0x7FFFFFFF) {
      _seen.fillRange(0, count, 0);
      stamp = _stamp = 1;
    }
    final seen = _seen;
    final d = digests;
    final limit = maxDistance ?? 1 << 30;
    for (var band = 0; band < tlshBands; band++) {
      final off = _offsets[band], ids = _ids[band];
      for (final v in tlshProbes(_bandValue(q, 0, band), probeLevel)) {
        final end = off[v + 1];
        for (var j = off[v]; j < end; j++) {
          final id = ids[j];
          if (seen[id] == stamp) continue;
          seen[id] = stamp;
          if (skip != null && skip(id)) continue;
          final dist = tlshBinDistance(q, 0, d, id * tlshBinSize);
          if (dist <= limit && dist < top.worst) top.add(id, dist);
        }
      }
    }
    return [for (var i = 0; i < top.ids.length; i++) (top.ids[i], top.dist[i])];
  }

  /// The exact [k] nearest by a linear scan with a per-query table of the
  /// distance of each 16-bit body word (16 lookups per digest).
  List<(int, int)> exact(Uint8List q, int k,
      {int? maxDistance, bool Function(int id)? skip}) =>
      tlshExactScan(digests, count, q, k, maxDistance: maxDistance, skip: skip);
}

/// Linear exact k-nearest search over [count] binary digests.
List<(int, int)> tlshExactScan(Uint8List d, int count, Uint8List q, int k,
    {int? maxDistance, bool Function(int id)? skip}) {
  if (k <= 0) return const [];
  // per word w: dist of the query word against every 16-bit value
  final table = Uint8List(16 * 65536);
  final pb = _pairByte;
  for (var w = 0; w < 16; w++) {
    final qh = q[3 + 2 * w] << 8, ql = q[4 + 2 * w] << 8;
    final base = w << 16;
    for (var hi = 0; hi < 256; hi++) {
      final dh = pb[qh | hi];
      final row = base | (hi << 8);
      for (var lo = 0; lo < 256; lo++) {
        table[row | lo] = dh + pb[ql | lo];
      }
    }
  }
  final top = _TopK(k);
  final limit = maxDistance ?? 1 << 30;
  var worst = top.worst;
  for (var i = 0, o = 0; i < count; i++, o += tlshBinSize) {
    var dist = _headerDiff(q, 0, d, o);
    if (dist > worst || dist > limit) continue;
    for (var w = 0; w < 16; w++) {
      dist += table[(w << 16) | (d[o + 3 + 2 * w] << 8) | d[o + 4 + 2 * w]];
    }
    if (dist > limit || dist >= worst) continue;
    if (skip != null && skip(i)) continue;
    top.add(i, dist);
    worst = top.worst;
  }
  return [for (var i = 0; i < top.ids.length; i++) (top.ids[i], top.dist[i])];
}

// ---------------------------------------------------------------------------
// persisted form

class ZxTlshStore {
  static const bandsTree = 'zx_tlsh_bands';
  static const digestsTree = 'zx_tlsh_digests';
  static const stateTree = 'zx_tlsh_state';
  static final Uint8List _genKey = Uint8List.fromList(utf8.encode('generation'));

  /// The last archive generation indexed in [s], or null when [s] has no
  /// band index.
  static int? indexedGeneration(ZxSnapshot s) {
    final t = s.tree(stateTree);
    if (t == null || s.tree(bandsTree) == null) return null;
    final v = t.get(_genKey);
    if (v == null || v.length != 8) return null;
    return ByteData.sublistView(v).getInt64(0);
  }

  /// Adds to the index in [txn] the TLSH digests of the content written
  /// by the generations of [a] after the last one indexed (creates the
  /// trees on first use). Returns the number of new digests.
  static int sync(ZxWriteTxn txn, ZxArchiveView a) {
    final bands = txn.tree(bandsTree) ?? txn.createTree(bandsTree);
    final digests = txn.tree(digestsTree) ?? txn.createTree(digestsTree);
    final state = txn.tree(stateTree) ?? txn.createTree(stateTree);
    final v = state.get(_genKey);
    final done = v == null || v.length != 8
        ? 0
        : ByteData.sublistView(v).getInt64(0);
    var added = 0;
    for (final g in a.generations) {
      if (g.number <= done) continue;
      final idx = a.indexOf(g);
      for (final (text, entry) in idx.tlshList) {
        final e = idx.entries[entry];
        final sha = e.sha256;
        if (sha == null) continue;
        if (done > 0 && (e.since ?? g.number) <= done) continue;
        if (digests.get(sha) != null) continue;
        final b = tlshToBinary(text);
        if (b == null) continue;
        addDigest(bands, digests, sha, b);
        added++;
      }
    }
    final out = Uint8List(8);
    ByteData.sublistView(out).setInt64(0, a.latest.number);
    state.put(_genKey, out);
    return added;
  }

  /// Adds one digest [b] for content [sha] (sha256, 32 bytes).
  static void addDigest(ZxWritableTree bands, ZxWritableTree digests,
      Uint8List sha, Uint8List b) {
    digests.put(sha, b);
    for (var band = 0; band < tlshBands; band++) {
      bands.put(bandKey(band, _bandValue(b, 0, band), sha), Uint8List(0));
    }
  }

  static Uint8List bandKey(int band, int value, [Uint8List? sha]) {
    final k = Uint8List(3 + (sha?.length ?? 0));
    k[0] = band;
    k[1] = value >> 8;
    k[2] = value & 255;
    if (sha != null) k.setRange(3, 3 + sha.length, sha);
    return k;
  }

  /// Candidates of [q] with their exact distance, nearest first:
  /// (sha256, distance), at most [limit] of them when given.
  static List<(Uint8List, int)> query(ZxSnapshot s, Uint8List q,
      {int? maxDistance, int probeLevel = 1, int? limit}) {
    final bands = s.tree(bandsTree), digests = s.tree(digestsTree);
    if (bands == null || digests == null) return const [];
    final seen = <String>{};
    final out = <(Uint8List, int)>[];
    final max = maxDistance ?? 1 << 30;
    for (var band = 0; band < tlshBands; band++) {
      for (final v in tlshProbes(_bandValue(q, 0, band), probeLevel)) {
        final from = bandKey(band, v);
        final to = v == 65535 ? bandKey(band + 1, 0) : bandKey(band, v + 1);
        final c = bands.scan(from: from, to: to);
        while (c.moveNext()) {
          final sha = Uint8List.sublistView(c.key, 3);
          final key = String.fromCharCodes(sha);
          if (!seen.add(key)) continue;
          final b = digests.get(sha);
          if (b == null) continue;
          final d = tlshBinDistance(q, 0, b, 0);
          if (d <= max) out.add((Uint8List.fromList(sha), d));
        }
        c.close();
      }
    }
    out.sort((a, b) {
      final c = a.$2 - b.$2;
      return c != 0 ? c : sysCompareBytes(a.$1, b.$1);
    });
    if (limit != null && out.length > limit) return out.sublist(0, limit);
    return out;
  }
}

// ---------------------------------------------------------------------------
// the similarity search over an archive

/// One hit of [ZxSimilarity.similar].
class ZxSimilarHit {
  final String path;
  final int entry;
  final Uint8List? sha256;
  final String tlsh;
  final int distance;
  const ZxSimilarHit(
      this.path, this.entry, this.sha256, this.tlsh, this.distance);
  @override
  String toString() => '$path ($distance)';
}

class ZxSimilarity {
  final ZxArchiveView archive;

  /// The database, when the archive has one (persisted band index).
  SysDbAccess? database;

  final Map<int, (TlshBandIndex, List<(String, int)>)> _lazy = {};

  /// Which form the last query used: 'persisted', 'lazy' or 'exact'.
  String lastMode = '';

  ZxSimilarity(this.archive, {this.database});

  /// The lazy in-memory index of generation [g] (built on first use).
  (TlshBandIndex, List<(String, int)>) lazyIndex(ZxIndexView v) {
    final n = v.generation.number;
    final hit = _lazy[n];
    if (hit != null) return hit;
    final list = [
      for (final t in v.tlshList)
        if (TlshDigest.parse(t.$1) != null) t
    ];
    final r = (TlshBandIndex.fromTexts([for (final t in list) t.$1]), list);
    if (_lazy.length >= 4) _lazy.remove(_lazy.keys.first);
    return _lazy[n] = r;
  }

  /// Resolves a query: a TLSH digest text, or a path of the archive at
  /// [v] (then that entry is excluded from the hits). Null when the query
  /// has no digest.
  (Uint8List, int?)? _queryDigest(Object query, ZxIndexView v) {
    if (query is String) {
      final b = tlshToBinary(query);
      if (b != null) return (b, null);
      final i = v.entryOf(query);
      if (i == null) return null;
      final t = v.entries[i].tlsh;
      final tb = t == null ? null : tlshToBinary(t);
      return tb == null ? null : (tb, i);
    }
    if (query is Uint8List && query.length == 32) {
      final l = v.findBySha256(query);
      for (final i in l) {
        final t = v.entries[i].tlsh;
        final tb = t == null ? null : tlshToBinary(t);
        if (tb != null) return (tb, null);
      }
    }
    return null;
  }

  /// The [n] nearest files of the archive (as of [asOf]) to [query] (a
  /// digest, a path, or a SHA-256 blob), nearest first.
  List<ZxSimilarHit> similar(Object query, int n,
      {SysAsOf? asOf, int? maxDistance, bool exact = false, int probeLevel = 1}) {
    final v = archive.at(asOf);
    final q = _queryDigest(query, v);
    if (q == null || n <= 0) return const [];
    final (qb, self) = q;
    final access = exact ? null : database;
    if (access != null) {
      final (db, release) = access.read(null);
      try {
        final ig = ZxTlshStore.indexedGeneration(db);
        if (ig != null && ig >= v.generation.number) {
          return _persisted(db, v, qb, self, n, maxDistance, probeLevel);
        }
      } finally {
        release();
      }
    }
    final (idx, list) = lazyIndex(v);
    bool skip(int id) => list[id].$2 == self;
    final hits = exact
        ? idx.exact(qb, n, maxDistance: maxDistance, skip: skip)
        : idx.query(qb, n,
            maxDistance: maxDistance, probeLevel: probeLevel, skip: skip);
    lastMode = exact ? 'exact' : 'lazy';
    return [
      for (final (id, d) in hits)
        ZxSimilarHit(v.entries[list[id].$2].path, list[id].$2,
            v.entries[list[id].$2].sha256, list[id].$1, d)
    ];
  }
}

extension on ZxSimilarity {
  List<ZxSimilarHit> _persisted(ZxSnapshot db, ZxIndexView v, Uint8List qb,
      int? self, int n, int? maxDistance, int probeLevel) {
    lastMode = 'persisted';
    final out = <ZxSimilarHit>[];
    for (final (sha, d) in ZxTlshStore.query(db, qb,
        maxDistance: maxDistance, probeLevel: probeLevel)) {
      for (final i in v.findBySha256(sha)) {
        if (i == self) continue;
        final e = v.entries[i];
        out.add(ZxSimilarHit(e.path, i, e.sha256, e.tlsh ?? '', d));
        if (out.length >= n) return out;
      }
    }
    return out;
  }
}

/// The table-valued function `similar(query, n [, mode])`: the n nearest
/// files to a TLSH digest, a path or a SHA-256, with their distance.
/// mode: 'band' (default), 'exact' (linear scan), or a number used as the
/// maximum distance.
class ZxSimilarTable extends SysVTable {
  final ZxSimilarity similarity;
  ZxSimilarTable(this.similarity);

  static const _columns = [
    SysColumn('path', 'TEXT'),
    SysColumn('sha256', 'BLOB'),
    SysColumn('tlsh', 'TEXT'),
    SysColumn('distance', 'INTEGER'),
    SysColumn('query', 'TEXT', hidden: true),
    SysColumn('n', 'INTEGER', hidden: true),
    SysColumn('mode', 'TEXT', hidden: true),
  ];

  @override
  String get name => 'similar';
  @override
  List<SysColumn> get columns => _columns;

  @override
  void bestIndex(SysIndexInfo info) {
    // args in the order query, n, mode (idxStr lists the ones given)
    final roles = <String>[];
    for (final col in [4, 5, 6]) {
      for (var i = 0; i < info.constraints.length; i++) {
        final c = info.constraints[i];
        if (c.usable && c.column == col && c.op == SysOp.eq) {
          info.use(i);
          roles.add(_columns[col].name);
          break;
        }
      }
    }
    info.idxStr = roles.join(' ');
    info.estimatedCost = roles.contains('query') ? 100 : 1e12;
    final ob = info.orderBy;
    info.orderByConsumed = ob.length == 1 && ob[0].column == 3 && !ob[0].desc;
  }

  @override
  SysCursor open(SysIndexInfo info, List<Object?> args, {SysAsOf? asOf}) {
    final roles = info.idxStr.isEmpty ? const <String>[] : info.idxStr.split(' ');
    Object? query;
    var n = 10;
    Object? mode;
    for (var k = 0; k < roles.length; k++) {
      switch (roles[k]) {
        case 'query':
          query = args[k];
        case 'n':
          if (args[k] is int) n = args[k] as int;
        case 'mode':
          mode = args[k];
      }
    }
    if (query == null) return SysListCursor(const []);
    final exact = mode == 'exact';
    final max = mode is int ? mode : null;
    final hits = similarity.similar(query, n,
        asOf: asOf, exact: exact, maxDistance: max);
    return SysListCursor([
      for (final h in hits) [h.path, h.sha256, h.tlsh, h.distance, query, n, mode]
    ]);
  }
}
