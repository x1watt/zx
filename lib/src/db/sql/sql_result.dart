// The result of a SQL statement and the formatting of its DATETIME values,
// as the callers of ZxSql hold them. Plain Dart: the web client compiles
// them with dart2js and receives results from the engine worker.

/// Result of [ZxSql.execute].
class ZxSqlResult {
  final List<String> columns;
  final List<List<Object?>> rows;

  /// Rows inserted, updated or deleted by the (last) statement.
  final int changes;
  final int lastInsertRowid;

  /// Per column, the declared type of the column it reads when the result
  /// column is a column reference (also through views and subqueries),
  /// else null; empty when unknown (statements other than SELECT). UIs use
  /// it to show DATETIME values (ns since 1970 UTC) as dates: see
  /// [isDatetime] and [zxFormatDatetimeNs].
  final List<String?> types;
  const ZxSqlResult(this.columns, this.rows, this.changes, this.lastInsertRowid,
      {this.types = const []});

  /// True when column [i] holds DATETIME values (ns since 1970 UTC).
  bool isDatetime(int i) =>
      zxIsDatetimeType(i < types.length ? types[i] : null);

  bool get isEmpty => rows.isEmpty;

  /// Rows as maps from column name to value.
  List<Map<String, Object?>> get maps => [
        for (final r in rows)
          {for (var i = 0; i < columns.length; i++) columns[i]: r[i]}
      ];

  /// The first column of the first row (or null).
  Object? get scalar => rows.isEmpty || rows[0].isEmpty ? null : rows[0][0];

  @override
  String toString() => 'ZxSqlResult($columns, $rows, changes: $changes)';
}

/// True for the declared types whose values are ns since 1970 UTC
/// (DATETIME, TIMESTAMP), as kindOfType of value.dart.
bool zxIsDatetimeType(String? type) {
  if (type == null) return false;
  final t = type.toUpperCase();
  return t == 'DATETIME' || t == 'TIMESTAMP';
}

/// A DATETIME value (ns since 1970 UTC) as ISO-8601 text in UTC:
/// `YYYY-MM-DD HH:MM:SS`, with the fraction of a second when it is not
/// zero (3, 6 or 9 digits). Values that are not integers come back as
/// text unchanged.
String zxFormatDatetimeNs(Object? v) {
  if (v is! int) return v == null ? '' : '$v';
  final sec = v ~/ 1000000000 - (v % 1000000000 != 0 && v < 0 ? 1 : 0);
  final frac = v - sec * 1000000000;
  final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true);
  String two(int x) => x.toString().padLeft(2, '0');
  var out =
      '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  if (frac != 0) {
    var f = frac.toString().padLeft(9, '0');
    if (f.endsWith('000000')) {
      f = f.substring(0, 3);
    } else if (f.endsWith('000')) {
      f = f.substring(0, 6);
    }
    out = '$out.$f';
  }
  return out;
}
