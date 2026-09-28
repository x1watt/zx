// Import helpers of the time series: JSON lines, CSV, syslog lines (RFC
// 3164 and RFC 5424) and journald's JSON export (`journalctl -o json`).
// Each parser gives a Map of fields; zxTsImport appends such maps to a
// series (fields named like a column go there, the others into a JSON
// column named `fields` when the series has one).
//
// Parsed fields: syslog and journald give ts (ns), host, app, pid,
// level ('emerg', 'alert', 'crit', 'err', 'warning', 'notice', 'info',
// 'debug'), facility (a number), message; journald's other fields
// (without the leading underscores' trusted marks removed) go to fields.

import 'dart:convert';

import '../storage_api.dart';
import 'ts_api.dart';
import 'ts_store.dart';

const List<String> zxSyslogLevels = [
  'emerg', 'alert', 'crit', 'err', 'warning', 'notice', 'info', 'debug', //
];

const _months = {
  'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6, //
  'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
};

final RegExp _pri = RegExp(r'^<(\d{1,3})>');
final RegExp _rfc5424 = RegExp(
    r'^(\d{1,2}) (\S+) (\S+) (\S+) (\S+) (\S+) (-|(?:\[.*?\])+)(?: (.*))?$',
    dotAll: true);
final RegExp _rfc3164 = RegExp(
    r'^([A-Z][a-z]{2}) {1,2}(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\S+) (.*)$',
    dotAll: true);
final RegExp _tag = RegExp(r'^([^:\[\s]{1,64})(?:\[(\d+)\])?: ?(.*)$', dotAll: true);

/// Parses a syslog line (RFC 5424 or RFC 3164, with or without the `<PRI>`
/// part). RFC 3164 has no year: [year] (default: the current one).
/// Returns null for a line that is neither.
Map<String, Object?>? zxTsParseSyslog(String line, {int? year}) {
  var s = line.trimRight();
  int? pri;
  final pm = _pri.firstMatch(s);
  if (pm != null) {
    pri = int.parse(pm[1]!);
    s = s.substring(pm.end);
  }
  final out = <String, Object?>{};
  if (pri != null) {
    out['level'] = zxSyslogLevels[pri & 7];
    out['facility'] = pri >> 3;
  }
  final m5 = _rfc5424.firstMatch(s);
  if (m5 != null && pri != null) {
    final ts = m5[2]!;
    if (ts != '-') {
      final d = DateTime.tryParse(ts);
      if (d == null) return null;
      out['ts'] = d.microsecondsSinceEpoch * 1000;
    }
    if (m5[3] != '-') out['host'] = m5[3];
    if (m5[4] != '-') out['app'] = m5[4];
    if (m5[5] != '-') out['pid'] = int.tryParse(m5[5]!) ?? m5[5];
    if (m5[6] != '-') out['msgid'] = m5[6];
    if (m5[7] != '-') out['sd'] = m5[7];
    var msg = m5[8] ?? '';
    if (msg.startsWith('﻿')) msg = msg.substring(1);
    out['message'] = msg;
    return out;
  }
  final m3 = _rfc3164.firstMatch(s);
  if (m3 == null) return null;
  final mon = _months[m3[1]];
  if (mon == null) return null;
  final y = year ?? DateTime.now().toUtc().year;
  out['ts'] = DateTime.utc(y, mon, int.parse(m3[2]!), int.parse(m3[3]!),
              int.parse(m3[4]!), int.parse(m3[5]!))
          .microsecondsSinceEpoch *
      1000;
  out['host'] = m3[6];
  final rest = m3[7]!;
  final tm = _tag.firstMatch(rest);
  if (tm != null) {
    out['app'] = tm[1];
    if (tm[2] != null) out['pid'] = int.parse(tm[2]!);
    out['message'] = tm[3];
  } else {
    out['message'] = rest;
  }
  return out;
}

/// Parses one entry of `journalctl -o json`: ts from
/// __REALTIME_TIMESTAMP (us), host, app (SYSLOG_IDENTIFIER or _COMM),
/// pid, level (PRIORITY), facility, message, and the other fields in
/// `fields` (a Map). Returns null for a line that is not a JSON object.
Map<String, Object?>? zxTsParseJournal(String line) {
  Object? j;
  try {
    j = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (j is! Map<String, Object?>) return null;
  final out = <String, Object?>{};
  final rt = int.tryParse('${j['__REALTIME_TIMESTAMP']}');
  if (rt != null) out['ts'] = rt * 1000;
  final fields = <String, Object?>{};
  for (final e in j.entries) {
    switch (e.key) {
      case '__REALTIME_TIMESTAMP':
      case '__MONOTONIC_TIMESTAMP':
      case '__CURSOR':
      case '__SEQNUM':
      case '__SEQNUM_ID':
        break;
      case '_HOSTNAME':
        out['host'] = e.value;
      case 'SYSLOG_IDENTIFIER':
        out['app'] = e.value;
      case '_PID':
        out['pid'] = int.tryParse('${e.value}') ?? e.value;
      case 'PRIORITY':
        final p = int.tryParse('${e.value}');
        if (p != null && p >= 0 && p < 8) out['level'] = zxSyslogLevels[p];
      case 'SYSLOG_FACILITY':
        out['facility'] = int.tryParse('${e.value}') ?? e.value;
      case 'MESSAGE':
        // binary messages come as arrays of bytes
        final v = e.value;
        out['message'] = v is List
            ? utf8.decode(v.cast<int>(), allowMalformed: true)
            : v;
      default:
        fields[e.key] = e.value;
    }
  }
  out['app'] ??= fields['_COMM'];
  if (fields.isNotEmpty) out['fields'] = fields;
  return out;
}

/// Parses a JSON line (an object); the time is the field [tsField] when
/// present. Returns null for a line that is not a JSON object.
Map<String, Object?>? zxTsParseJsonLine(String line, {String tsField = 'ts'}) {
  Object? j;
  try {
    j = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (j is! Map<String, Object?>) return null;
  if (tsField != 'ts' && j.containsKey(tsField)) {
    j['ts'] = j.remove(tsField);
  }
  return j;
}

/// Parses CSV text (RFC 4180: quotes, doubled quotes, line breaks inside
/// quotes); the first record names the fields. Values stay text.
Iterable<Map<String, Object?>> zxTsParseCsv(String text,
    {String separator = ','}) sync* {
  final sep = separator.codeUnitAt(0);
  List<String>? header;
  var fields = <String>[];
  final cur = StringBuffer();
  var quoted = false;
  var i = 0;
  final n = text.length;
  Map<String, Object?>? emit() {
    fields.add(cur.toString());
    cur.clear();
    final f = fields;
    fields = <String>[];
    if (f.length == 1 && f[0].isEmpty) return null;
    if (header == null) {
      header = f;
      return null;
    }
    final h = header!;
    return {
      for (var k = 0; k < h.length && k < f.length; k++) h[k]: f[k]
    };
  }

  while (i < n) {
    final c = text.codeUnitAt(i);
    if (quoted) {
      if (c == 0x22) {
        if (i + 1 < n && text.codeUnitAt(i + 1) == 0x22) {
          cur.writeCharCode(0x22);
          i += 2;
          continue;
        }
        quoted = false;
      } else {
        cur.writeCharCode(c);
      }
      i++;
      continue;
    }
    if (c == 0x22 && cur.isEmpty) {
      quoted = true;
    } else if (c == sep) {
      fields.add(cur.toString());
      cur.clear();
    } else if (c == 0x0A || c == 0x0D) {
      if (c == 0x0D && i + 1 < n && text.codeUnitAt(i + 1) == 0x0A) i++;
      final r = emit();
      if (r != null) yield r;
    } else {
      cur.writeCharCode(c);
    }
    i++;
  }
  if (cur.isNotEmpty || fields.isNotEmpty) {
    final r = emit();
    if (r != null) yield r;
  }
}

/// Appends parsed records to [series] in transactions of [batch] rows:
/// fields named like a column go there (case does not matter), the others
/// into a JSON column named `fields` when there is one (else they are
/// dropped). Records without a time get [defaultTs] (else they are
/// skipped). Returns the number of rows appended.
int zxTsImport(ZxSeries series, Iterable<Map<String, Object?>> records,
    {int batch = 50000, Object? defaultTs}) {
  final d = series.def;
  final lower = {
    for (var i = 0; i < d.columns.length; i++) d.columns[i].name.toLowerCase(): i
  };
  final fieldsCol = lower['fields'] ?? -1;
  final tsName = d.columns[d.tsCol].name.toLowerCase();
  var n = 0;
  final rows = <List<Object?>>[];
  void flush() {
    if (rows.isEmpty) return;
    series.appendAll(rows);
    n += rows.length;
    rows.clear();
  }

  for (final r in records) {
    final row = List<Object?>.filled(d.columns.length, null);
    Map<String, Object?>? extra;
    for (final e in r.entries) {
      var k = e.key.toLowerCase();
      if (k == 'ts' && !lower.containsKey('ts')) k = tsName;
      final i = lower[k];
      if (i != null && i != fieldsCol) {
        row[i] = e.value;
      } else if (fieldsCol >= 0) {
        if (i == fieldsCol && e.value is Map) {
          (extra ??= {}).addAll((e.value as Map).cast<String, Object?>());
        } else {
          (extra ??= {})[e.key] = e.value;
        }
      }
    }
    if (extra != null) row[fieldsCol] = jsonEncode(extra);
    row[d.tsCol] ??= defaultTs;
    if (row[d.tsCol] == null) continue;
    try {
      zxTsTimeNs(row[d.tsCol]);
    } on ZxDbException {
      continue;
    }
    rows.add(row);
    if (rows.length >= batch) flush();
  }
  flush();
  return n;
}
