// The time series of zxdb (docs/zxdb-design.md 2.3 and section 12):
// definitions, the write buffer, sealing into column segments, retention,
// full-text postings and the scan. Everything works on the trees of a
// snapshot or of the write transaction (storage_api.dart), so AS OF and
// the transaction rules come from the store.
//
// Trees of series "logs":
//   zx$ts            key name: the definition (JSON); key 0x00 + name:
//                    the counters (next buffer block, next segment id)
//   ts:logs:buf      key block id (8 bytes): a block of appended rows
//                    (count, min ts, max ts, then per row ts and tagged
//                    values); tree policy 'fast'
//   ts:logs:dir      key partition start (8) + segment id (8): the
//                    segment header (rows, time range, column sizes,
//                    Bloom filters of the tag columns); 'fast'
//   ts:logs:seg      key segment id (8) + column (2): the column blob
//                    (ts_codec.dart), already coded; 'store'
//   ts:logs:fts      key segment id (8) + term: the rows of the segment
//                    holding the term (varint deltas); 'fast'
// Ids and partition starts are 8 bytes big endian, sign flipped.
//
// Row order: by time, then by append order. Segments of one partition
// are numbered in seal order and a seal only merges the partition's last
// segment with newer rows, so (ts, segment id, row) is that order and the
// buffer's rows come after every sealed row of the same time.

import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../format/zx/zx_codecs.dart';
import '../../format/zx/zx_format.dart' show ZxCoder;
import '../../format/zx/zx_memory.dart';
import '../../sync_pool.dart';
import '../engine/compression.dart';
import '../meta/fts.dart' show ftsTokenize;
import '../sql/datetime.dart' show parseDateTimeToNs;
import '../storage_api.dart';
import 'ts_codec.dart';

/// The tree of the series definitions.
const String zxTsMetaTree = r'zx$ts';

String zxTsBufTree(String s) => 'ts:$s:buf';
String zxTsDirTree(String s) => 'ts:$s:dir';
String zxTsSegTree(String s) => 'ts:$s:seg';
String zxTsFtsTree(String s) => 'ts:$s:fts';

/// The hot tier: LZ4 copies of the columns with coded text of the
/// segments of recent partitions (option hot_days).
String zxTsHotTree(String s) => 'ts:$s:hot';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

const int _nsHour = 3600 * 1000000000;
const int _nsDay = 24 * _nsHour;

int _floorDiv(int a, int b) {
  final q = a ~/ b;
  return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
}

/// Partition units.
enum ZxTsPartition { hour, day, week, month }

ZxTsPartition zxTsParsePartition(String? s) {
  switch ((s ?? 'day').toLowerCase()) {
    case 'hour':
      return ZxTsPartition.hour;
    case 'day':
      return ZxTsPartition.day;
    case 'week':
      return ZxTsPartition.week;
    case 'month':
      return ZxTsPartition.month;
  }
  throw ZxDbException('PARTITION BY $s (HOUR, DAY, WEEK or MONTH)',
      ZxDbError.syntax);
}

/// Start of the partition holding [ns].
int zxTsPartStart(ZxTsPartition p, int ns) {
  switch (p) {
    case ZxTsPartition.hour:
      return _floorDiv(ns, _nsHour) * _nsHour;
    case ZxTsPartition.day:
      return _floorDiv(ns, _nsDay) * _nsDay;
    case ZxTsPartition.week:
      // weeks start on Monday (1970-01-01 was a Thursday)
      final d = _floorDiv(ns, _nsDay);
      return (_floorDiv(d + 3, 7) * 7 - 3) * _nsDay;
    case ZxTsPartition.month:
      final t = DateTime.fromMicrosecondsSinceEpoch(_floorDiv(ns, 1000),
          isUtc: true);
      return DateTime.utc(t.year, t.month).microsecondsSinceEpoch * 1000;
  }
}

/// End (exclusive) of the partition starting at [start].
int zxTsPartEnd(ZxTsPartition p, int start) {
  switch (p) {
    case ZxTsPartition.hour:
      return start + _nsHour;
    case ZxTsPartition.day:
      return start + _nsDay;
    case ZxTsPartition.week:
      return start + 7 * _nsDay;
    case ZxTsPartition.month:
      final t = DateTime.fromMicrosecondsSinceEpoch(start ~/ 1000,
          isUtc: true);
      return DateTime.utc(t.year, t.month + 1).microsecondsSinceEpoch * 1000;
  }
}

/// Parses a duration ('400d', '12h', '30m', '10s', '500ms', '2w', '1y',
/// or seconds) to ms.
int zxTsParseDurationMs(Object? v) {
  if (v is int) return v * 1000;
  final m = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w|y)?\s*$')
      .firstMatch('$v'.toLowerCase());
  if (m == null) throw ZxDbException('bad duration "$v"', ZxDbError.syntax);
  final n = double.parse(m[1]!);
  final ms = switch (m[2]) {
    'ms' => n,
    'm' => n * 60000,
    'h' => n * 3600000,
    'd' => n * 86400000,
    'w' => n * 604800000,
    'y' => n * 365 * 86400000,
    _ => n * 1000,
  };
  if (ms <= 0) throw ZxDbException('bad duration "$v"', ZxDbError.syntax);
  return ms.round();
}

/// How a column's values are converted on append.
enum ZxTsType { datetime, integer, real, text, json, boolean, any }

ZxTsType zxTsTypeOf(String? t) {
  final u = (t ?? '').toUpperCase();
  if (u == 'DATETIME' || u == 'TIMESTAMP') return ZxTsType.datetime;
  if (u.startsWith('JSON')) return ZxTsType.json;
  if (u == 'BOOLEAN' || u == 'BOOL') return ZxTsType.boolean;
  if (u.contains('INT')) return ZxTsType.integer;
  if (u.contains('CHAR') || u.contains('CLOB') || u.contains('TEXT')) {
    return ZxTsType.text;
  }
  if (u.contains('REAL') || u.contains('FLOA') || u.contains('DOUB')) {
    return ZxTsType.real;
  }
  return ZxTsType.any;
}

/// A column of a series.
class ZxTsColumn {
  final String name;
  final String type;
  const ZxTsColumn(this.name, this.type);
  ZxTsType get kind => zxTsTypeOf(type);
}

/// A time series definition.
class ZxTsDef {
  final String name;
  final List<ZxTsColumn> columns;
  final int tsCol;
  final ZxTsPartition partition;
  final int? retentionMs;

  /// The policy of the text sections (TreeOptions names or a chain).
  final String compression;

  /// The column of the full-text index, or -1.
  final int ftsCol;
  final List<int> tags;

  /// Rows per segment at most.
  final int segmentRows;

  /// Buffered rows that make an append seal.
  final int sealRows;

  /// A random id (cache keys of decoded columns).
  final int uid;

  /// Days of the hot tier (0: none; 1 by default at creation): segments
  /// of partitions that end less than this many days before now also
  /// keep their text columns coded with LZ4 when the series' compression
  /// is slower than that (not fast or store), and scans read that copy.
  final int hotDays;

  /// The conversion of each column.
  late final List<ZxTsType> kinds = [for (final c in columns) c.kind];

  ZxTsDef(this.name, this.columns, this.tsCol, this.partition,
      this.retentionMs, this.compression, this.ftsCol, this.tags,
      this.segmentRows, this.sealRows, this.uid, {this.hotDays = 0});

  int columnIndex(String name) {
    final l = name.toLowerCase();
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].name.toLowerCase() == l) return i;
    }
    return -1;
  }

  Map<String, Object?> toJson() => {
        'columns': [
          for (final c in columns) [c.name, c.type]
        ],
        'ts': tsCol,
        'partition': partition.name,
        'retention': retentionMs,
        'compression': compression,
        'fts': ftsCol,
        'tags': tags,
        'segmentRows': segmentRows,
        'sealRows': sealRows,
        'uid': uid,
        if (hotDays > 0) 'hotDays': hotDays,
      };

  static ZxTsDef fromJson(String name, Map<String, Object?> j) => ZxTsDef(
      name,
      [
        for (final c in j['columns'] as List)
          ZxTsColumn((c as List)[0] as String, c[1] as String)
      ],
      j['ts'] as int,
      ZxTsPartition.values.byName(j['partition'] as String),
      j['retention'] as int?,
      j['compression'] as String,
      j['fts'] as int,
      (j['tags'] as List).cast<int>(),
      j['segmentRows'] as int,
      j['sealRows'] as int,
      j['uid'] as int,
      hotDays: (j['hotDays'] as int?) ?? 0);

  /// Builds a definition from CREATE TIMESERIES parts.
  static ZxTsDef create(String name, List<ZxTsColumn> columns,
      {String? partitionBy,
      Object? retention,
      Map<String, Object?> options = const {}}) {
    if (name.isEmpty || name.contains(':')) {
      throw ZxDbException('bad time series name "$name"', ZxDbError.constraint);
    }
    if (columns.isEmpty) {
      throw const ZxDbException('a time series needs columns', ZxDbError.syntax);
    }
    final o = {for (final e in options.entries) e.key.toLowerCase(): e.value};
    final seen = <String>{};
    for (final c in columns) {
      if (!seen.add(c.name.toLowerCase())) {
        throw ZxDbException('duplicate column ${c.name}', ZxDbError.constraint);
      }
    }
    var ts = -1;
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].kind == ZxTsType.datetime &&
          columns[i].name.toLowerCase() == 'ts') {
        ts = i;
      }
    }
    if (ts < 0) {
      for (var i = 0; i < columns.length && ts < 0; i++) {
        if (columns[i].kind == ZxTsType.datetime) ts = i;
      }
    }
    if (ts < 0) {
      throw const ZxDbException(
          'a time series needs a DATETIME column', ZxDbError.syntax);
    }
    final comp = (o['compression'] as String?) ?? 'max';
    zxDbCheckCompression(comp);
    int col(Object? n) {
      final i = columns.indexWhere(
          (c) => c.name.toLowerCase() == '$n'.trim().toLowerCase());
      if (i < 0) throw ZxDbException('no column $n', ZxDbError.syntax);
      return i;
    }

    var fts = -1;
    final f = o['fts'];
    if (f != null && f != false && '$f'.toLowerCase() != 'off' && f != 0) {
      if (f == true || f == 1 || '$f'.toLowerCase() == 'on') {
        fts = columns.indexWhere((c) => c.name.toLowerCase() == 'message');
        if (fts < 0) {
          fts = columns.indexWhere((c) => c.kind == ZxTsType.text);
        }
        if (fts < 0) {
          throw const ZxDbException(
              'fts = on needs a TEXT column', ZxDbError.syntax);
        }
      } else {
        fts = col(f);
      }
    }
    final tags = <int>[];
    final t = o['tags'];
    if (t != null) {
      final parts = t is List
          ? t
          : '$t'.replaceAll(RegExp(r'[()]'), '').split(',');
      for (final p in parts) {
        if ('$p'.trim().isEmpty) continue;
        tags.add(col(p));
      }
    }
    final rnd = math.Random();
    return ZxTsDef(
        name,
        columns,
        ts,
        zxTsParsePartition(partitionBy),
        retention == null ? null : zxTsParseDurationMs(retention),
        comp,
        fts,
        tags,
        _intOpt(o['segment_rows']) ?? (1 << 17),
        _intOpt(o['seal_rows']) ?? (1 << 20),
        (rnd.nextInt(1 << 30) << 30) ^ rnd.nextInt(1 << 30) ^
            DateTime.now().microsecondsSinceEpoch,
        // one day by default: see docs/zxdb-design.md 12.3 (the hot tier)
        hotDays: o.containsKey('hot_days') ? _hotDaysOpt(o['hot_days']) : 1);
  }
}

// hot_days: a number of days or a duration ('36h' is 2 days)
int _hotDaysOpt(Object? v) {
  if (v == null || v == false) return 0;
  if (v is int) {
    if (v < 0) throw ZxDbException('bad hot_days "$v"', ZxDbError.syntax);
    return v;
  }
  final s = '$v'.trim();
  if (s == '0' || s.toLowerCase() == 'off') return 0;
  final n = int.tryParse(s);
  if (n != null && n >= 0) return n;
  final ms = zxTsParseDurationMs(s);
  return (ms + 86400000 - 1) ~/ 86400000;
}

int? _intOpt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  final n = int.tryParse('$v'.trim());
  if (n == null || n <= 0) throw ZxDbException('bad number "$v"', ZxDbError.syntax);
  return n;
}

// ---------------------------------------------------------- definitions

/// The definition of series [name] at [s], or null.
ZxTsDef? zxTsDef(ZxSnapshot s, String name) {
  final m = s.tree(zxTsMetaTree);
  final v = m?.get(_utf8(name));
  if (v == null) return null;
  return ZxTsDef.fromJson(
      name, jsonDecode(utf8.decode(v)) as Map<String, Object?>);
}

/// The names of the series at [s].
List<String> zxTsNames(ZxSnapshot s) {
  final m = s.tree(zxTsMetaTree);
  if (m == null) return const [];
  final out = <String>[];
  final c = m.scan();
  while (c.moveNext()) {
    if (c.key.isNotEmpty && c.key[0] != 0) out.add(utf8.decode(c.key));
  }
  c.close();
  return out;
}

ZxTsDef _need(ZxSnapshot s, String name) {
  final d = zxTsDef(s, name);
  if (d == null) {
    throw ZxDbException('no time series "$name"', ZxDbError.notFound);
  }
  return d;
}

/// Creates series [def] in [t]. Returns false when it exists and
/// [ifNotExists].
bool zxTsCreate(ZxWriteTxn t, ZxTsDef def, {bool ifNotExists = false}) {
  final m = t.tree(zxTsMetaTree) ?? t.createTree(zxTsMetaTree);
  final k = _utf8(def.name);
  if (m.get(k) != null) {
    if (ifNotExists) return false;
    throw ZxDbException(
        'time series "${def.name}" exists', ZxDbError.constraint);
  }
  m.put(k, _utf8(jsonEncode(def.toJson())));
  t.createTree(zxTsBufTree(def.name),
      const TreeOptions(compression: 'fast', pageSize: 65536));
  t.createTree(zxTsDirTree(def.name), const TreeOptions(compression: 'fast'));
  t.createTree(zxTsSegTree(def.name), const TreeOptions(compression: 'store'));
  if (def.ftsCol >= 0) {
    t.createTree(zxTsFtsTree(def.name), const TreeOptions(compression: 'fast'));
  }
  _putState(t, def.name, const _State(1, 1, 0, 0));
  return true;
}

/// Drops series [name] (and its rollups, through [dropRollups]).
bool zxTsDrop(ZxWriteTxn t, String name, {bool ifExists = false}) {
  final m = t.tree(zxTsMetaTree);
  final k = _utf8(name);
  if (m == null || m.get(k) == null) {
    if (ifExists) return false;
    throw ZxDbException('no time series "$name"', ZxDbError.notFound);
  }
  final def = zxTsDef(t, name)!;
  m.delete(k);
  m.delete(_stateKey(name));
  for (final tn in [
    zxTsBufTree(name),
    zxTsDirTree(name),
    zxTsSegTree(name),
    if (def.ftsCol >= 0) zxTsFtsTree(name),
    zxTsHotTree(name),
  ]) {
    if (t.tree(tn) != null) t.dropTree(tn);
  }
  return true;
}

class _State {
  final int nextBlock;
  final int nextSeg;
  final int bufferedRows;
  final int bufferBlocks;
  const _State(
      this.nextBlock, this.nextSeg, this.bufferedRows, this.bufferBlocks);
}

Uint8List _stateKey(String name) {
  final u = utf8.encode(name);
  return Uint8List(u.length + 1)..setRange(1, u.length + 1, u);
}

_State _getState(ZxSnapshot s, String name) {
  final v = s.tree(zxTsMetaTree)?.get(_stateKey(name));
  if (v == null) return const _State(1, 1, 0, 0);
  final r = TsReader(v);
  return _State(r.varint(), r.varint(), r.varint(), r.varint());
}

void _putState(ZxWriteTxn t, String name, _State st) {
  final w = TsWriter(32)
    ..varint(st.nextBlock)
    ..varint(st.nextSeg)
    ..varint(st.bufferedRows)
    ..varint(st.bufferBlocks);
  t.tree(zxTsMetaTree)!.put(_stateKey(name), w.copy());
}

/// Rows in the write buffer of series [name] at [s].
int zxTsBufferedRows(ZxSnapshot s, String name) =>
    _getState(s, name).bufferedRows;

Uint8List _key8(int v) {
  final k = Uint8List(8);
  tsPutKeyInt(k, 0, v);
  return k;
}

Uint8List _key16(int a, int b) {
  final k = Uint8List(16);
  tsPutKeyInt(k, 0, a);
  tsPutKeyInt(k, 8, b);
  return k;
}

// ---------------------------------------------------------- values

/// Converts [v] for a column of kind [k] (ZxTsDef.kinds; append and
/// INSERT).
Object? zxTsCoerce(ZxTsType k, Object? v) {
  if (v == null) return null;
  // the common cases first
  if (v is String) {
    if (k == ZxTsType.text || k == ZxTsType.any || k == ZxTsType.json) {
      return v;
    }
  } else if (v is int) {
    if (k != ZxTsType.real) return v;
  } else if (v is double) {
    if (k == ZxTsType.real || k == ZxTsType.any || k == ZxTsType.text) {
      return v;
    }
  }
  switch (k) {
    case ZxTsType.datetime:
      return zxTsTimeNs(v);
    case ZxTsType.json:
      if (v is String || v is num) return v is String ? v : jsonEncode(v);
      if (v is Map || v is List || v is bool) return jsonEncode(v);
    case ZxTsType.boolean:
      if (v is bool) return v ? 1 : 0;
      if (v is String) {
        final l = v.toLowerCase();
        if (l == 'true') return 1;
        if (l == 'false') return 0;
      }
    case ZxTsType.integer:
      if (v is double && v == v.truncateToDouble() && v.abs() < 9e18) {
        return v.toInt();
      }
      if (v is String) return int.tryParse(v.trim()) ?? v;
    case ZxTsType.real:
      if (v is int) return v.toDouble();
      if (v is String) return double.tryParse(v.trim()) ?? v;
    default:
  }
  if (v is bool) return v ? 1 : 0;
  if (v is DateTime) return v.microsecondsSinceEpoch * 1000;
  if (v is Map || v is List && v is! Uint8List) return jsonEncode(v);
  return v;
}

/// A time value as ns since 1970 UTC: int ns, DateTime, a REAL (rounded
/// ns) or date/time text.
int zxTsTimeNs(Object? v) {
  if (v is int) return v;
  if (v is DateTime) return v.microsecondsSinceEpoch * 1000;
  if (v is double) return v.round();
  if (v is String) {
    final n = parseDateTimeToNs(v);
    if (n != null) return n;
    final d = DateTime.tryParse(v);
    if (d != null) return d.microsecondsSinceEpoch * 1000;
  }
  throw ZxDbException('bad time value "$v"', ZxDbError.constraint);
}

// ---------------------------------------------------------- appends

/// Appends [rows] (values in column order, already coerced, time never
/// NULL) to the write buffer of [def] in [t], in blocks of about 15 KiB:
/// small enough to stay inline in the leaves of the buffer tree (64 KiB
/// pages), which keeps them out of the overflow pages and their hashing.
void zxTsAppendRows(ZxWriteTxn t, ZxTsDef def, List<List<Object?>> rows) {
  if (rows.isEmpty) return;
  final buf = t.tree(zxTsBufTree(def.name))!;
  var st = _getState(t, def.name);
  final nc = def.columns.length;
  final tc = def.tsCol;
  var nextBlock = st.nextBlock;
  var blocks = st.bufferBlocks;
  final w = TsWriter(1 << 15);
  final h = TsWriter(32);
  final key = Uint8List(8);
  var i = 0;
  while (i < rows.length) {
    w.n = 0;
    var lo = 0, hi = 0, cnt = 0;
    while (i < rows.length && (cnt == 0 || w.n < _blockBytes)) {
      final r = rows[i++];
      final ts = r[tc] as int;
      if (cnt == 0 || ts < lo) lo = ts;
      if (cnt == 0 || ts > hi) hi = ts;
      w.zigzag(ts);
      for (var c = 0; c < nc; c++) {
        if (c != tc) tsWriteValue(w, r[c]);
      }
      cnt++;
    }
    h.n = 0;
    h
      ..varint(cnt)
      ..zigzag(lo)
      ..zigzag(hi)
      ..bytes(w.take());
    tsPutKeyInt(key, 0, nextBlock++);
    buf.put(key, h.copy());
    blocks++;
  }
  st = _State(nextBlock, st.nextSeg, st.bufferedRows + rows.length, blocks);
  _putState(t, def.name, st);
  if (blocks > 1024 && st.bufferedRows < blocks * 8) {
    // many tiny blocks (row by row INSERTs): write them again as big ones
    final all = _readBuffer(buf, def, null, null);
    buf.deleteRange();
    _putState(t, def.name, _State(nextBlock, st.nextSeg, 0, 0));
    zxTsAppendRows(t, def, all);
  }
}

const int _blockBytes = 12 << 10;

// reads the buffered rows (block order), limited to [from, to) by the
// block headers only
List<List<Object?>> _readBuffer(ZxTree buf, ZxTsDef def, int? from, int? to) {
  final out = <List<Object?>>[];
  final c = buf.scan();
  while (c.moveNext()) {
    out.addAll(_decodeBlock(c.value, def, from, to));
  }
  c.close();
  return out;
}

/// The rows of the write buffer of [def] at [s] with times in [from, to)
/// (append order; blocks outside the range are not decoded).
List<List<Object?>> zxTsBufferRows(ZxSnapshot s, ZxTsDef def,
    {int? from, int? to}) {
  final buf = s.tree(zxTsBufTree(def.name));
  if (buf == null) return const [];
  final tc = def.tsCol;
  return [
    for (final r in _readBuffer(buf, def, from, to))
      if ((from == null || (r[tc] as int) >= from) &&
          (to == null || (r[tc] as int) < to))
        r
  ];
}

List<List<Object?>> _decodeBlock(Uint8List b, ZxTsDef def, int? from, int? to) {
  final r = TsReader(b);
  final n = r.varint();
  final lo = r.zigzag();
  final hi = r.zigzag();
  if (from != null && hi < from || to != null && lo >= to) return const [];
  final nc = def.columns.length;
  final tc = def.tsCol;
  final out = List<List<Object?>>.filled(n, const []);
  for (var i = 0; i < n; i++) {
    final row = List<Object?>.filled(nc, null);
    row[tc] = r.zigzag();
    for (var c = 0; c < nc; c++) {
      if (c != tc) row[c] = tsReadValue(r);
    }
    out[i] = row;
  }
  return out;
}

// ---------------------------------------------------------- segments

class _SegHead {
  final int part;
  final int id;
  final int rows;
  final int minTs;
  final int maxTs;
  final List<int> colBytes;
  final Map<int, Uint8List> blooms;
  _SegHead(this.part, this.id, this.rows, this.minTs, this.maxTs,
      this.colBytes, this.blooms);

  Uint8List encode() {
    final w = TsWriter(64);
    w.byte(1);
    w.varint(rows);
    w.zigzag(minTs);
    w.zigzag(maxTs);
    w.varint(colBytes.length);
    for (final b in colBytes) {
      w.varint(b);
    }
    w.varint(blooms.length);
    for (final e in blooms.entries) {
      w.varint(e.key);
      w.varint(e.value.length);
      w.bytes(e.value);
    }
    return w.copy();
  }

  static _SegHead decode(Uint8List key, Uint8List v) {
    final r = TsReader(v);
    if (r.byte() != 1) throw const ZxDbException('segment version', ZxDbError.corrupt);
    final rows = r.varint();
    final lo = r.zigzag();
    final hi = r.zigzag();
    final nc = r.varint();
    final cb = [for (var i = 0; i < nc; i++) r.varint()];
    final nb = r.varint();
    final bl = <int, Uint8List>{};
    for (var i = 0; i < nb; i++) {
      final c = r.varint();
      bl[c] = Uint8List.fromList(r.bytes(r.varint()));
    }
    return _SegHead(tsGetKeyInt(key, 0), tsGetKeyInt(key, 8), rows, lo, hi,
        cb, bl);
  }
}

List<_SegHead> _segments(ZxTree dir, {int? fromPart, int? toPart}) {
  final out = <_SegHead>[];
  final c = dir.scan(
      from: fromPart == null ? null : _key16(fromPart, -(1 << 63)),
      to: toPart == null ? null : _key16(toPart, -(1 << 63)));
  while (c.moveNext()) {
    out.add(_SegHead.decode(c.key, c.value));
  }
  c.close();
  return out;
}

// a segment's column key
Uint8List _colKey(int seg, int col) {
  final k = Uint8List(10);
  tsPutKeyInt(k, 0, seg);
  k[8] = col >> 8;
  k[9] = col & 0xFF;
  return k;
}

/// Decoded columns, shared by the process (segments never change once
/// written: an id is never reused, a merge writes a new one).
class _ColumnCache {
  final LinkedHashMap<String, TsColumn> _m = LinkedHashMap();
  int _bytes = 0;
  int budget = 256 << 20;

  TsColumn get(String key, TsColumn Function() load) {
    final c = _m.remove(key);
    if (c != null) {
      _m[key] = c;
      return c;
    }
    final n = load();
    _m[key] = n;
    _bytes += n.bytes;
    while (_bytes > budget && _m.length > 1) {
      final k = _m.keys.first;
      _bytes -= _m.remove(k)!.bytes;
    }
    return n;
  }

  void clear() {
    _m.clear();
    _bytes = 0;
  }
}

final _ColumnCache _cache = _ColumnCache();

/// Drops the decoded columns of the process (benchmarks: cold reads).
void zxTsClearCache() => _cache.clear();

/// Sets the memory budget of the decoded column cache.
set zxTsCacheBudget(int bytes) => _cache.budget = bytes;

TsColumn _column(ZxTree seg, ZxTsDef def, int segId, int col,
        [ZxTree? hot]) =>
    _cache.get('${def.uid}:$segId:$col', () {
      final k = _colKey(segId, col);
      final b = hot?.get(k) ?? seg.get(k);
      if (b == null) {
        throw ZxDbException(
            'time series ${def.name}: missing column $col of segment $segId',
            ZxDbError.corrupt);
      }
      return TsColumn.decode(b);
    });

// the section coding job (a worker isolate)
SyncJobResult _codeJob(Object? arg) {
  final a = arg as (Uint8List, List<ZxCoderSpec>);
  final r = tsCode(a.$1, a.$2);
  if (r == null) return SyncJobResult(Uint8List(0));
  final w = TsWriter(64);
  w.byte(r.$2.length);
  for (final c in r.$2) {
    w.varint(c.codecId);
    w.varint(c.props.length);
    w.bytes(c.props);
  }
  return SyncJobResult(r.$1, w.copy());
}

/// Codes the sections of [drafts]: text sections with [textSpecs], the
/// others with LZ4, in worker isolates.
void _codeSections(List<TsColumnDraft> drafts, List<ZxCoderSpec> textSpecs,
    int threads) {
  final jobs = <(TsSection, List<ZxCoderSpec>)>[];
  var maxLen = 0;
  for (final d in drafts) {
    for (final s in d.sections) {
      final specs = s.text ? textSpecs : zxDbFastChain;
      if (specs.isEmpty || s.raw.length < 64) continue;
      jobs.add((s, specs));
      if (s.raw.length > maxLen) maxLen = s.raw.length;
    }
  }
  if (jobs.isEmpty) return;
  // big and slow first
  jobs.sort((a, b) => b.$1.raw.length - a.$1.raw.length);
  final per = zxWorkerMemory(textSpecs, maxLen);
  var th = zxWorkersFor(threads, per, zxDefaultMemoryLimit());
  var heavy = 0;
  for (final j in jobs) {
    if (j.$1.text && j.$1.raw.length > 32768) heavy++;
  }
  if (heavy < 2) th = 1;
  if (th > heavy) th = math.max(1, heavy);
  final pool = SyncJobPool(th);
  try {
    final tickets = <int>[];
    var next = 0;
    for (var i = 0; i < jobs.length; i++) {
      while (next < jobs.length && next - i < pool.threads) {
        final j = jobs[next++];
        // small fast sections run inline
        if (!j.$1.text || j.$1.raw.length <= 32768 || pool.threads == 1) {
          tickets.add(-1);
          _apply(j.$1, _codeJob((j.$1.raw, j.$2)));
        } else {
          tickets.add(pool.submit(_codeJob, (j.$1.raw, j.$2)));
        }
      }
      if (tickets[i] >= 0) _apply(jobs[i].$1, pool.take(tickets[i]));
    }
  } finally {
    pool.close();
  }
}

void _apply(TsSection s, SyncJobResult r) {
  if (r.meta.isEmpty) return;
  final rd = TsReader(r.meta);
  final n = rd.byte();
  final cs = <ZxCoder>[];
  for (var i = 0; i < n; i++) {
    final id = rd.varint();
    cs.add(ZxCoder(id, Uint8List.fromList(rd.bytes(rd.varint()))));
  }
  s.payload = r.data;
  s.coders = cs;
}

class _NewSeg {
  final int part;
  final int id;
  final List<List<Object?>> rows;
  final List<TsColumnDraft> drafts;
  final _SegHead head;
  final Map<String, List<int>>? postings;
  _NewSeg(this.part, this.id, this.rows, this.drafts, this.head, this.postings);
}

/// Options of a seal.
class ZxTsSealOptions {
  /// Worker isolates for the text sections.
  final int threads;
  const ZxTsSealOptions({this.threads = 4});
}

/// What a seal did.
class ZxTsSealResult {
  final int rows;
  final int segments;
  final int partitionsDropped;
  final int bytes;
  const ZxTsSealResult(
      this.rows, this.segments, this.partitionsDropped, this.bytes);
  @override
  String toString() =>
      'ZxTsSealResult(rows $rows, segments $segments, dropped $partitionsDropped, $bytes bytes)';
}

/// Called with the rows being sealed (the rollups), before retention.
typedef ZxTsSealListener = void Function(
    ZxWriteTxn t, ZxTsDef def, List<List<Object?>> rows, int nowMs);

/// Seals the write buffer of series [name] into column segments (one per
/// partition, the partition's last small segment merged in), then drops
/// the partitions past the retention (relative to [nowMs]).
ZxTsSealResult zxTsSeal(ZxWriteTxn t, String name,
    {required int nowMs,
    ZxTsSealListener? listener,
    ZxTsSealOptions options = const ZxTsSealOptions()}) {
  final def = _need(t, name);
  final buf = t.tree(zxTsBufTree(name))!;
  final dir = t.tree(zxTsDirTree(name))!;
  final seg = t.tree(zxTsSegTree(name))!;
  final fts = def.ftsCol >= 0 ? t.tree(zxTsFtsTree(name)) : null;
  final hotOn = def.hotDays > 0 && _hotUseful(def);
  var hot = t.tree(zxTsHotTree(name));
  if (hot == null && hotOn) {
    hot = t.createTree(
        zxTsHotTree(name), const TreeOptions(compression: 'store'));
  }
  var st = _getState(t, name);
  final rows = _readBuffer(buf, def, null, null);
  final cutoffNs = def.retentionMs == null
      ? null
      : (nowMs - def.retentionMs!) * 1000000;
  // partitions ending after this are hot
  final hotNs = (nowMs - def.hotDays * 86400000) * 1000000;
  if (rows.isNotEmpty) listener?.call(t, def, rows, nowMs);
  final tc = def.tsCol;
  // group by partition, keeping the append order
  final byPart = SplayTreeMap<int, List<List<Object?>>>();
  for (final r in rows) {
    final p = zxTsPartStart(def.partition, r[tc] as int);
    if (cutoffNs != null && zxTsPartEnd(def.partition, p) <= cutoffNs) {
      continue;
    }
    (byPart[p] ??= []).add(r);
  }
  var nextSeg = st.nextSeg;
  final made = <_NewSeg>[];
  for (final e in byPart.entries) {
    final part = e.key;
    var prows = e.value;
    // merge the partition's last segment when it is small
    final ex = _segments(dir, fromPart: part, toPart: part + 1);
    if (ex.isNotEmpty && ex.last.rows < def.segmentRows ~/ 2) {
      final last = ex.last;
      final old = _segmentRows(seg, def, last, hot);
      _deleteSegment(dir, seg, fts, last, hot);
      prows = [...old, ...prows];
    }
    // sort by time, stable
    final n = prows.length;
    final order = List<int>.generate(n, (i) => i);
    final tsv = Int64List(n);
    var sorted = true;
    for (var i = 0; i < n; i++) {
      tsv[i] = prows[i][tc] as int;
      if (i > 0 && tsv[i] < tsv[i - 1]) sorted = false;
    }
    if (!sorted) {
      order.sort((a, b) {
        final d = tsv[a].compareTo(tsv[b]);
        return d != 0 ? d : a - b;
      });
      prows = [for (final i in order) prows[i]];
    }
    for (var s = 0; s < n; s += def.segmentRows) {
      final chunk = prows.sublist(s, math.min(n, s + def.segmentRows));
      made.add(_buildSegment(def, part, nextSeg++, chunk));
    }
  }
  final textSpecs = zxDbChainFor(def.compression, groupBytes: 1 << 20);
  _codeSections([for (final m in made) ...m.drafts], textSpecs, options.threads);
  var bytes = 0;
  for (final m in made) {
    for (var c = 0; c < m.drafts.length; c++) {
      final b = m.drafts[c].build();
      m.head.colBytes[c] = b.length;
      bytes += b.length;
      seg.put(_colKey(m.id, c), b);
      if (hotOn && zxTsPartEnd(def.partition, m.part) > hotNs) {
        final hb = _hotBlob(m.drafts[c]);
        if (hb != null) hot!.put(_colKey(m.id, c), hb);
      }
    }
    dir.put(_key16(m.part, m.id), m.head.encode());
    final p = m.postings;
    if (p != null && fts != null) {
      for (final e in p.entries) {
        final tb = utf8.encode(e.key);
        final k = Uint8List(8 + tb.length);
        tsPutKeyInt(k, 0, m.id);
        k.setRange(8, k.length, tb);
        final w = TsWriter(e.value.length + 4);
        var prev = 0;
        for (final r in e.value) {
          w.varint(r - prev);
          prev = r;
        }
        fts.put(k, w.copy());
      }
    }
  }
  if (rows.isNotEmpty) buf.deleteRange();
  // retention
  var dropped = 0;
  if (cutoffNs != null) {
    final segs = _segments(dir);
    final parts = <int>{};
    for (final h in segs) {
      if (zxTsPartEnd(def.partition, h.part) <= cutoffNs) {
        _deleteSegment(dir, seg, fts, h, hot);
        parts.add(h.part);
      }
    }
    dropped = parts.length;
  }
  // the hot tier: copies of partitions that aged out go (all of them when
  // the option is off)
  if (hot != null) {
    for (final h in _segments(dir)) {
      if (!hotOn || zxTsPartEnd(def.partition, h.part) <= hotNs) {
        hot.deleteRange(from: _colKey(h.id, 0), to: _colKey(h.id + 1, 0));
      }
    }
  }
  st = _State(st.nextBlock, nextSeg, 0, 0);
  _putState(t, name, st);
  return ZxTsSealResult(rows.length, made.length, dropped, bytes);
}

void _deleteSegment(ZxWritableTree dir, ZxWritableTree seg,
    ZxWritableTree? fts, _SegHead h, ZxWritableTree? hot) {
  dir.delete(_key16(h.part, h.id));
  seg.deleteRange(from: _colKey(h.id, 0), to: _colKey(h.id + 1, 0));
  fts?.deleteRange(from: _key8(h.id), to: _key8(h.id + 1));
  hot?.deleteRange(from: _colKey(h.id, 0), to: _colKey(h.id + 1, 0));
}

// A hot tier pays off only when the text is coded with something slower
// than LZ4.
bool _hotUseful(ZxTsDef def) {
  final c = def.compression.toLowerCase();
  return c != 'fast' && c != 'store';
}

// The column [d] with its coded text sections coded again with LZ4, or
// null when it has none (numbers and time are LZ4 already).
Uint8List? _hotBlob(TsColumnDraft d) {
  var any = false;
  final secs = <TsSection>[];
  for (final s in d.sections) {
    if (!s.text || s.coders == null) {
      secs.add(s);
      continue;
    }
    any = true;
    final n = TsSection(s.raw, true);
    final r = tsCode(s.raw, zxDbFastChain);
    if (r != null) {
      n.payload = r.$1;
      n.coders = r.$2;
    }
    secs.add(n);
  }
  return any ? TsColumnDraft(d.head, secs).build() : null;
}

List<List<Object?>> _segmentRows(ZxTree seg, ZxTsDef def, _SegHead h,
    [ZxTree? hot]) {
  final nc = def.columns.length;
  final cols = [for (var c = 0; c < nc; c++) _column(seg, def, h.id, c, hot)];
  return [
    for (var i = 0; i < h.rows; i++) [for (var c = 0; c < nc; c++) cols[c].value(i)]
  ];
}

_NewSeg _buildSegment(
    ZxTsDef def, int part, int id, List<List<Object?>> rows) {
  final n = rows.length;
  final nc = def.columns.length;
  final tc = def.tsCol;
  final drafts = <TsColumnDraft>[];
  final ts = Int64List(n);
  for (var i = 0; i < n; i++) {
    ts[i] = rows[i][tc] as int;
  }
  final blooms = <int, Uint8List>{};
  for (var c = 0; c < nc; c++) {
    if (c == tc) {
      drafts.add(tsEncodeTsColumn(ts));
      continue;
    }
    final vals = List<Object?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      vals[i] = rows[i][c];
    }
    drafts.add(tsEncodeColumn(vals));
    if (def.tags.contains(c)) {
      final hs = <int>{};
      for (final v in vals) {
        if (v != null) hs.add(tsHashValue(v));
      }
      blooms[c] = tsBloomBuild(hs, hs.length);
    }
  }
  Map<String, List<int>>? postings;
  if (def.ftsCol >= 0) {
    postings = {};
    final fc = def.ftsCol;
    for (var i = 0; i < n; i++) {
      final v = rows[i][fc];
      if (v is! String) continue;
      for (final term in ftsTokenize(v).toSet()) {
        (postings[term] ??= []).add(i);
      }
    }
  }
  final head = _SegHead(part, id, n, n == 0 ? 0 : ts.reduce(math.min),
      n == 0 ? 0 : ts.reduce(math.max), List<int>.filled(nc, 0), blooms);
  return _NewSeg(part, id, rows, drafts, head, postings);
}

/// Sizes of series [name]: (rows sealed, segments, bytes of the column
/// blobs, buffered rows).
({int rows, int segments, int bytes, int buffered, int partitions})
    zxTsStats(ZxSnapshot s, String name) {
  _need(s, name);
  final dir = s.tree(zxTsDirTree(name))!;
  var rows = 0, bytes = 0;
  final parts = <int>{};
  final segs = _segments(dir);
  for (final h in segs) {
    rows += h.rows;
    parts.add(h.part);
    for (final b in h.colBytes) {
      bytes += b;
    }
  }
  return (
    rows: rows,
    segments: segs.length,
    bytes: bytes,
    buffered: _getState(s, name).bufferedRows,
    partitions: parts.length
  );
}

// ---------------------------------------------------------- scans

/// What a scan reads.
class ZxTsScanSpec {
  /// Time range [from, to) in ns (null: open).
  final int? from;
  final int? to;
  final bool descending;

  /// Columns the caller reads (null: all). Only these are decoded.
  final Set<int>? columns;

  /// Equality on columns: segments whose Bloom filter (tag columns) says
  /// no are skipped; with [filterRows] rows are tested too.
  final Map<int, Object?> equals;
  final bool filterRows;

  /// Full-text query: words that must all occur (word* for a prefix).
  final String? match;

  /// Includes the write buffer (false: sealed rows only).
  final bool buffer;

  const ZxTsScanSpec(
      {this.buffer = true,
      this.from,
      this.to,
      this.descending = false,
      this.columns,
      this.equals = const {},
      this.filterRows = true,
      this.match});
}

class _Src {
  final _SegHead? head; // null: buffered rows
  final List<List<Object?>>? rows;
  final List<TsColumn?> cols;
  final TsColumn? ts;
  _Src(this.head, this.rows, this.cols, this.ts);
}

/// A scan of a series at a snapshot: rows in time order (then append
/// order), partition by partition.
class ZxTsScan {
  final ZxSnapshot snap;
  final ZxTsDef def;
  final ZxTsScanSpec spec;
  late final ZxTree _seg;
  late final ZxTree? _fts;
  late final ZxTree? _hot;
  final List<int> _parts = [];
  final Map<int, List<_SegHead>> _segsByPart = {};
  final Map<int, List<List<Object?>>> _bufByPart = {};
  int _pi = -1;

  // the current partition: sources and the row order
  List<_Src> _srcs = const [];
  Int32List _oSrc = Int32List(0);
  Int32List _oRow = Int32List(0);
  int _n = 0;
  int _i = -1;
  _Src? _cs;
  int _cr = 0;
  late final List<String>? _words;

  ZxTsScan(this.snap, this.def, this.spec) {
    final name = def.name;
    _seg = snap.tree(zxTsSegTree(name))!;
    _hot = def.hotDays > 0 ? snap.tree(zxTsHotTree(name)) : null;
    _fts = def.ftsCol >= 0 ? snap.tree(zxTsFtsTree(name)) : null;
    final m = spec.match;
    _words = m == null
        ? null
        : [
            for (final w in m.split(RegExp(r'\s+')))
              if (w.isNotEmpty) ...(w.endsWith('*')
                  ? ['${ftsTokenize(w.substring(0, w.length - 1)).join()}*']
                  : ftsTokenize(w))
          ];
    final from = spec.from, to = spec.to;
    final dir = snap.tree(zxTsDirTree(name))!;
    final segs = _segments(dir,
        fromPart: from == null ? null : zxTsPartStart(def.partition, from),
        toPart: to);
    final parts = SplayTreeSet<int>();
    for (final h in segs) {
      if (from != null && h.maxTs < from) continue;
      if (to != null && h.minTs >= to) continue;
      if (!_bloomOk(h)) continue;
      (_segsByPart[h.part] ??= []).add(h);
      parts.add(h.part);
    }
    final buf = snap.tree(zxTsBufTree(name))!;
    final c = buf.scan();
    while (spec.buffer && c.moveNext()) {
      for (final r in _decodeBlock(c.value, def, from, to)) {
        final ts = r[def.tsCol] as int;
        if (from != null && ts < from || to != null && ts >= to) continue;
        final p = zxTsPartStart(def.partition, ts);
        (_bufByPart[p] ??= []).add(r);
        parts.add(p);
      }
    }
    c.close();
    _parts.addAll(spec.descending ? parts.toList().reversed : parts);
  }

  bool _bloomOk(_SegHead h) {
    for (final e in spec.equals.entries) {
      final f = h.blooms[e.key];
      final v = e.value;
      if (f == null || v == null) continue;
      if (v is! String && v is! int) continue;
      if (!tsBloomMay(f, tsHashValue(v))) return false;
    }
    return true;
  }

  // rows of segment [h] holding every word, or null for all
  Set<int>? _ftsRows(_SegHead h) {
    final ws = _words;
    final f = _fts;
    if (ws == null || f == null) return null;
    Set<int>? acc;
    for (final w in ws) {
      final got = <int>{};
      final prefix = w.endsWith('*');
      final tb = utf8.encode(prefix ? w.substring(0, w.length - 1) : w);
      final k = Uint8List(8 + tb.length);
      tsPutKeyInt(k, 0, h.id);
      k.setRange(8, k.length, tb);
      void add(Uint8List v) {
        final r = TsReader(v);
        var x = 0;
        while (!r.atEnd) {
          x += r.varint();
          got.add(x);
        }
      }

      if (prefix) {
        final c = f.scan(from: k, to: _prefixEnd(k));
        while (c.moveNext()) {
          add(c.value);
        }
        c.close();
      } else {
        final v = f.get(k);
        if (v != null) add(v);
      }
      acc = acc == null ? got : acc.intersection(got);
      if (acc.isEmpty) break;
    }
    return acc ?? <int>{};
  }

  bool _textMatches(Object? v) {
    final ws = _words!;
    if (v is! String) return ws.isEmpty;
    final toks = ftsTokenize(v).toSet();
    for (final w in ws) {
      if (w.endsWith('*')) {
        final p = w.substring(0, w.length - 1);
        if (!toks.any((t) => t.startsWith(p))) return false;
      } else if (!toks.contains(w)) {
        return false;
      }
    }
    return true;
  }

  bool _need(int c) => spec.columns == null || spec.columns!.contains(c);

  bool _loadPart() {
    while (true) {
      _pi++;
      if (_pi >= _parts.length) return false;
      final p = _parts[_pi];
      final srcs = <_Src>[];
      final from = spec.from, to = spec.to;
      final eq = spec.equals;
      final nc = def.columns.length;
      final segs = _segsByPart[p] ?? const <_SegHead>[];
      final br = _bufByPart[p];
      var cap = br?.length ?? 0;
      for (final h in segs) {
        cap += h.rows;
      }
      // (ts, source, row) of the rows that pass
      final tsA = Int64List(cap);
      final srcA = Int32List(cap);
      final rowA = Int32List(cap);
      var k = 0;
      var sorted = true;
      var last = -(1 << 63);
      for (final h in segs) {
        final allow = _ftsRows(h);
        if (allow != null && allow.isEmpty) continue;
        final tcol = _column(_seg, def, h.id, def.tsCol, _hot);
        final cols = List<TsColumn?>.filled(nc, null);
        for (var c = 0; c < nc; c++) {
          if (c == def.tsCol) {
            cols[c] = tcol;
          } else if (_need(c)) {
            cols[c] = _column(_seg, def, h.id, c, _hot);
          }
        }
        final eqCols = <TsColumn>[];
        final eqVals = <Object?>[];
        if (spec.filterRows) {
          for (final e in eq.entries) {
            eqCols.add(cols[e.key] ?? _column(_seg, def, h.id, e.key, _hot));
            eqVals.add(e.value);
          }
        }
        final ne = eqCols.length;
        final si = srcs.length;
        srcs.add(_Src(h, null, cols, tcol));
        final tv = tcol.ints!;
        // the rows in range (a segment is sorted by time)
        var lo = 0, hi = h.rows;
        if (from != null) lo = _lowerBound(tv, from);
        if (to != null) hi = _lowerBound(tv, to);
        if (lo < hi && tv[lo] < last) sorted = false;
        for (var r = lo; r < hi; r++) {
          if (allow != null && !allow.contains(r)) continue;
          var ok = true;
          for (var e = 0; e < ne; e++) {
            if (eqCols[e].value(r) != eqVals[e]) {
              ok = false;
              break;
            }
          }
          if (!ok) continue;
          tsA[k] = tv[r];
          srcA[k] = si;
          rowA[k] = r;
          k++;
        }
        if (k > 0) last = tsA[k - 1];
      }
      if (br != null) {
        final si = srcs.length;
        srcs.add(_Src(null, br, const [], null));
        final tc = def.tsCol;
        for (var r = 0; r < br.length; r++) {
          final row = br[r];
          var ok = true;
          if (spec.filterRows) {
            for (final e in eq.entries) {
              if (row[e.key] != e.value) {
                ok = false;
                break;
              }
            }
          }
          if (ok && _words != null && !_textMatches(row[def.ftsCol])) ok = false;
          if (!ok) continue;
          final ts = row[tc] as int;
          if (ts < last) sorted = false;
          last = ts;
          tsA[k] = ts;
          srcA[k] = si;
          rowA[k] = r;
          k++;
        }
      }
      final n = k;
      if (n == 0) continue;
      final os = Int32List(n), orr = Int32List(n);
      if (sorted) {
        os.setRange(0, n, srcA);
        orr.setRange(0, n, rowA);
      } else {
        // by time, then source (seal order, the buffer last), then row
        final idx = List<int>.generate(n, (i) => i);
        idx.sort((a, b) {
          final d = tsA[a].compareTo(tsA[b]);
          if (d != 0) return d;
          final s = srcA[a] - srcA[b];
          return s != 0 ? s : rowA[a] - rowA[b];
        });
        for (var i = 0; i < n; i++) {
          os[i] = srcA[idx[i]];
          orr[i] = rowA[idx[i]];
        }
      }
      _srcs = srcs;
      _oSrc = os;
      _oRow = orr;
      _n = n;
      _i = spec.descending ? n : -1;
      return true;
    }
  }

  /// Advances to the next row; false at the end.
  bool moveNext() {
    while (true) {
      if (_n > 0) {
        if (spec.descending) {
          if (_i > 0) {
            _i--;
            break;
          }
        } else if (_i + 1 < _n) {
          _i++;
          break;
        }
        _n = 0;
      }
      if (!_loadPart()) return false;
    }
    _cs = _srcs[_oSrc[_i]];
    _cr = _oRow[_i];
    return true;
  }

  /// The time of the current row.
  int get ts {
    final s = _cs!;
    final rows = s.rows;
    if (rows != null) return rows[_cr][def.tsCol] as int;
    return s.ts!.ints![_cr];
  }

  /// Column [c] of the current row.
  Object? value(int c) {
    final s = _cs!;
    final rows = s.rows;
    if (rows != null) return rows[_cr][c];
    var col = s.cols[c];
    if (col == null) {
      col = _column(_seg, def, s.head!.id, c, _hot);
      s.cols[c] = col;
    }
    return col.value(_cr);
  }

  /// The current row (all columns).
  List<Object?> row() =>
      [for (var c = 0; c < def.columns.length; c++) value(c)];
}

int _lowerBound(Int64List v, int x) {
  var lo = 0, hi = v.length;
  while (lo < hi) {
    final m = (lo + hi) >> 1;
    if (v[m] < x) {
      lo = m + 1;
    } else {
      hi = m;
    }
  }
  return lo;
}

Uint8List? _prefixEnd(Uint8List p) {
  final k = Uint8List.fromList(p);
  for (var i = k.length - 1; i >= 0; i--) {
    if (k[i] != 0xFF) {
      k[i]++;
      return Uint8List.sublistView(k, 0, i + 1);
    }
  }
  return null;
}

/// Bytes of the hot tier of series [name] (LZ4 copies of recent text
/// columns; 0 when it has none).
int zxTsHotBytes(ZxSnapshot s, String name) {
  final h = s.tree(zxTsHotTree(name));
  if (h == null) return 0;
  var n = 0;
  final c = h.scan();
  while (c.moveNext()) {
    n += c.value.length;
  }
  c.close();
  return n;
}

/// The sealed segments of series [name] at [s]: partition start, segment
/// id and rows (read from the directory only; used by HISTORY OF).
List<({int part, int id, int rows})> zxTsSegmentList(ZxSnapshot s, String name) {
  final dir = s.tree(zxTsDirTree(name));
  if (dir == null) return const [];
  return [
    for (final h in _segments(dir)) (part: h.part, id: h.id, rows: h.rows)
  ];
}
