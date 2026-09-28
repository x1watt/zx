// The Dart API of the time series (docs/zxdb-design.md 2.3):
//
//   db.createSeries('logs', [ZxTsColumn('ts', 'DATETIME'), ...],
//       partitionBy: 'day', retention: '400d', tags: ['host']);
//   final s = db.series('logs');
//   s.appendAll(rows);           // one transaction, one buffer block
//   s.seal();                    // column segments, rollups, retention
//   for (final r in s.query(from: a, to: b, where: {'host': 'web1'})) ...
//
// Rows are Lists in column order or Maps by column name. Times are ns
// since 1970 UTC (int), DateTime or date/time text.

import '../zxdb.dart';
import 'ts_rollup.dart';
import 'ts_store.dart';

export 'ts_import.dart';
export 'ts_rollup.dart' show ZxRollupDef, zxRollupRows;
export 'ts_store.dart'
    show
        ZxTsColumn,
        ZxTsDef,
        ZxTsScan,
        ZxTsScanSpec,
        ZxTsSealResult,
        ZxTsSealOptions,
        zxTsClearCache,
        zxTsCacheBudget,
        zxTsHotBytes;

/// A time series of a database.
class ZxSeries {
  final ZxDatabase db;
  final String name;

  /// A snapshot to read (AS OF), or null for the current state.
  final ZxSnapshot? at;
  ZxSeries(this.db, this.name, {this.at});

  ZxTsDef get def {
    final d = zxTsDef(at ?? db.readSnapshot(), name);
    if (d == null) {
      throw ZxDbException('no time series "$name"', ZxDbError.notFound);
    }
    return d;
  }

  List<Object?> _row(ZxTsDef d, Object row) {
    final n = d.columns.length;
    final out = List<Object?>.filled(n, null);
    if (row is List) {
      for (var i = 0; i < n && i < row.length; i++) {
        out[i] = zxTsCoerce(d.kinds[i], row[i]);
      }
    } else if (row is Map) {
      for (final e in row.entries) {
        final i = d.columnIndex('${e.key}');
        if (i < 0) {
          throw ZxDbException('no column ${e.key} in $name', ZxDbError.constraint);
        }
        out[i] = zxTsCoerce(d.kinds[i], e.value);
      }
    } else {
      throw ArgumentError('a row is a List or a Map');
    }
    if (out[d.tsCol] == null) {
      throw ZxDbException('the time of a row of $name is NULL', ZxDbError.constraint);
    }
    return out;
  }

  /// Appends one row (its own transaction; use [appendAll] for many).
  void append(Object row) => appendAll([row]);

  /// Appends [rows] in one transaction. Seals when the buffer holds the
  /// series' seal_rows or more.
  void appendAll(Iterable<Object> rows) {
    if (at != null) {
      throw const ZxDbException('a series AS OF is read only', ZxDbError.readOnly);
    }
    db.transaction((t) {
      final d = zxTsDef(t, name);
      if (d == null) {
        throw ZxDbException('no time series "$name"', ZxDbError.notFound);
      }
      final list = [for (final r in rows) _row(d, r)];
      zxTsAppendRows(t, d, list);
      if (zxTsBufferedRows(t, name) >= d.sealRows) {
        zxTsSeal(t, name, nowMs: db.nowMs(), listener: zxRollupsOnSeal);
      }
    });
  }

  /// Seals the write buffer into column segments, feeds the rollups and
  /// drops the partitions past the retention.
  ZxTsSealResult seal({ZxTsSealOptions options = const ZxTsSealOptions()}) =>
      db.transaction((t) => zxTsSeal(t, name,
          nowMs: db.nowMs(), listener: zxRollupsOnSeal, options: options));

  /// A scan in time order: rows with times in [from, to) (ns, DateTime or
  /// text), only [columns] (names; null: all) decoded, [where] equality
  /// on columns (tag columns skip segments by their Bloom filters), and
  /// [match] full-text words (word* for a prefix). The scan reads the
  /// snapshot of the moment it starts.
  ZxTsScan scan(
      {Object? from,
      Object? to,
      List<String>? columns,
      Map<String, Object?> where = const {},
      String? match,
      bool descending = false}) {
    final s = at ?? db.readSnapshot();
    final d = zxTsDef(s, name);
    if (d == null) {
      throw ZxDbException('no time series "$name"', ZxDbError.notFound);
    }
    int col(String c) {
      final i = d.columnIndex(c);
      if (i < 0) throw ZxDbException('no column $c in $name', ZxDbError.notFound);
      return i;
    }

    return ZxTsScan(
        s,
        d,
        ZxTsScanSpec(
            from: from == null ? null : zxTsTimeNs(from),
            to: to == null ? null : zxTsTimeNs(to),
            descending: descending,
            columns: columns == null ? null : {for (final c in columns) col(c)},
            equals: {
              for (final e in where.entries)
                col(e.key): zxTsCoerce(d.kinds[col(e.key)], e.value)
            },
            match: match));
  }

  /// The rows of [scan] as Lists of [columns] (all by default).
  List<List<Object?>> query(
      {Object? from,
      Object? to,
      List<String>? columns,
      Map<String, Object?> where = const {},
      String? match,
      bool descending = false,
      int? limit}) {
    final sc = scan(
        from: from,
        to: to,
        columns: columns,
        where: where,
        match: match,
        descending: descending);
    final d = sc.def;
    final idx = columns == null
        ? [for (var i = 0; i < d.columns.length; i++) i]
        : [for (final c in columns) d.columnIndex(c)];
    final out = <List<Object?>>[];
    while ((limit == null || out.length < limit) && sc.moveNext()) {
      out.add([for (final i in idx) sc.value(i)]);
    }
    return out;
  }

  /// Rows sealed, segments, partitions, bytes of the segments, buffered
  /// rows.
  ({int rows, int segments, int bytes, int buffered, int partitions})
      get stats => zxTsStats(at ?? db.readSnapshot(), name);

  /// The rollups of this series.
  List<ZxRollupDef> get rollups =>
      zxRollups(at ?? db.readSnapshot(), series: name);
}

/// Time series of [ZxDatabase].
extension ZxDatabaseSeries on ZxDatabase {
  /// Series [name] now, or at a generation or time (read only).
  ZxSeries series(String name, {int? generation, int? atTimeNs}) {
    final at = generation == null && atTimeNs == null
        ? null
        : snapshot(generation: generation, atTimeNs: atTimeNs);
    final s = ZxSeries(this, name, at: at);
    s.def;
    return s;
  }

  /// The names of the time series.
  List<String> get seriesNames => zxTsNames(readSnapshot());

  /// Creates a series. [partitionBy]: hour, day (default), week, month;
  /// [retention]: '400d'...; [compression] of the text columns ('max' by
  /// default); [fts]: a TEXT column with a full-text index; [tags]:
  /// columns with Bloom filters per segment; [hotDays]: keep an LZ4 copy
  /// of the text columns of partitions younger than that many days (the
  /// hot tier, for `max` and other slow chains; 0 is off).
  ZxSeries createSeries(String name, List<ZxTsColumn> columns,
      {String? partitionBy,
      String? retention,
      String? compression,
      String? fts,
      List<String> tags = const [],
      int? segmentRows,
      int? sealRows,
      int? hotDays}) {
    final def = ZxTsDef.create(name, columns,
        partitionBy: partitionBy,
        retention: retention,
        options: {
          if (compression != null) 'compression': compression,
          if (fts != null) 'fts': fts,
          if (tags.isNotEmpty) 'tags': tags,
          if (segmentRows != null) 'segment_rows': segmentRows,
          if (sealRows != null) 'seal_rows': sealRows,
          if (hotDays != null) 'hot_days': hotDays,
        });
    transaction((t) => zxTsCreate(t, def));
    return ZxSeries(this, name);
  }

  /// Drops series [name], its data and its rollups.
  void dropSeries(String name) {
    transaction((t) {
      for (final r in zxRollups(t, series: name)) {
        zxRollupDrop(t, r.name);
      }
      zxTsDrop(t, name);
    });
  }

  /// Seals every series (VACUUM does this first): segments, rollups and
  /// retention.
  void sealAllSeries() {
    final names = seriesNames;
    if (names.isEmpty) return;
    transaction((t) {
      for (final n in names) {
        zxTsSeal(t, n, nowMs: nowMs(), listener: zxRollupsOnSeal);
      }
    });
  }
}
