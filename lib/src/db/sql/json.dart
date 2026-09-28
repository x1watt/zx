// JSON support (SQLite json1 semantics): parsing, rendering, paths and the
// json_* functions. JSON values are held as Dart objects: Map (insertion
// ordered), List, String, int, double, bool and null.

import 'dart:typed_data';

import '../storage_api.dart';
import 'value.dart';

ZxDbException _malformed() => const ZxDbException('malformed JSON');

/// Marker for "no value" (a path that does not exist).
const Object missing = _Missing();

class _Missing {
  const _Missing();
}

class _JsonParser {
  final String s;
  int p = 0;
  _JsonParser(this.s);

  void ws() {
    while (p < s.length) {
      final c = s.codeUnitAt(p);
      if (c == 32 || c == 9 || c == 10 || c == 13) {
        p++;
      } else {
        break;
      }
    }
  }

  Object? value() {
    ws();
    if (p >= s.length) throw _malformed();
    final c = s.codeUnitAt(p);
    if (c == 123) {
      p++;
      final m = <String, Object?>{};
      ws();
      if (p < s.length && s.codeUnitAt(p) == 125) {
        p++;
        return m;
      }
      while (true) {
        ws();
        if (p >= s.length || s.codeUnitAt(p) != 34) throw _malformed();
        final k = string();
        ws();
        if (p >= s.length || s.codeUnitAt(p) != 58) throw _malformed();
        p++;
        m[k] = value();
        ws();
        if (p >= s.length) throw _malformed();
        final d = s.codeUnitAt(p++);
        if (d == 125) return m;
        if (d != 44) throw _malformed();
      }
    }
    if (c == 91) {
      p++;
      final l = <Object?>[];
      ws();
      if (p < s.length && s.codeUnitAt(p) == 93) {
        p++;
        return l;
      }
      while (true) {
        l.add(value());
        ws();
        if (p >= s.length) throw _malformed();
        final d = s.codeUnitAt(p++);
        if (d == 93) return l;
        if (d != 44) throw _malformed();
      }
    }
    if (c == 34) return string();
    if (s.startsWith('true', p)) {
      p += 4;
      return true;
    }
    if (s.startsWith('false', p)) {
      p += 5;
      return false;
    }
    if (s.startsWith('null', p)) {
      p += 4;
      return null;
    }
    final m = RegExp(r'-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?').matchAsPrefix(s, p);
    if (m == null || m.end == p) throw _malformed();
    p = m.end;
    final t = m.group(0)!;
    if (m.group(2) == null && m.group(3) == null) {
      final v = int.tryParse(t);
      if (v != null) return v;
    }
    return double.parse(t);
  }

  String string() {
    p++; // opening quote
    final b = StringBuffer();
    while (true) {
      if (p >= s.length) throw _malformed();
      final c = s.codeUnitAt(p++);
      if (c == 34) break;
      if (c < 32) throw _malformed();
      if (c != 92) {
        b.writeCharCode(c);
        continue;
      }
      if (p >= s.length) throw _malformed();
      final e = s.codeUnitAt(p++);
      switch (e) {
        case 34:
          b.write('"');
        case 92:
          b.write('\\');
        case 47:
          b.write('/');
        case 98:
          b.write('\b');
        case 102:
          b.write('\f');
        case 110:
          b.write('\n');
        case 114:
          b.write('\r');
        case 116:
          b.write('\t');
        case 117:
          if (p + 4 > s.length) throw _malformed();
          final h = int.tryParse(s.substring(p, p + 4), radix: 16);
          if (h == null) throw _malformed();
          b.writeCharCode(h);
          p += 4;
        default:
          throw _malformed();
      }
    }
    return b.toString();
  }
}

/// Parses JSON text; throws ZxDbException('malformed JSON').
Object? parseJson(String s) {
  final ps = _JsonParser(s);
  final v = ps.value();
  ps.ws();
  if (ps.p != s.length) throw _malformed();
  return v;
}

bool isValidJson(String s) {
  try {
    parseJson(s);
    return true;
  } on ZxDbException {
    return false;
  }
}

/// Renders a JSON value (minified, SQLite style).
String renderJson(Object? v) {
  final b = StringBuffer();
  _render(v, b);
  return b.toString();
}

void _render(Object? v, StringBuffer b) {
  if (v == null) {
    b.write('null');
  } else if (v is bool) {
    b.write(v ? 'true' : 'false');
  } else if (v is int) {
    b.write(v);
  } else if (v is double) {
    if (v.isInfinite) {
      b.write(v > 0 ? '9.0e+999' : '-9.0e+999');
    } else if (v.isNaN) {
      b.write('null');
    } else {
      b.write(realToText(v));
    }
  } else if (v is String) {
    quoteJsonString(v, b);
  } else if (v is List) {
    b.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) b.write(',');
      _render(v[i], b);
    }
    b.write(']');
  } else if (v is Map) {
    b.write('{');
    var first = true;
    v.forEach((k, x) {
      if (!first) b.write(',');
      first = false;
      quoteJsonString(k as String, b);
      b.write(':');
      _render(x, b);
    });
    b.write('}');
  } else {
    throw ArgumentError('not JSON: $v');
  }
}

void quoteJsonString(String s, StringBuffer b) {
  b.write('"');
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    switch (c) {
      case 34:
        b.write(r'\"');
      case 92:
        b.write(r'\\');
      case 8:
        b.write(r'\b');
      case 12:
        b.write(r'\f');
      case 10:
        b.write(r'\n');
      case 13:
        b.write(r'\r');
      case 9:
        b.write(r'\t');
      default:
        if (c < 32) {
          b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(c);
        }
    }
  }
  b.write('"');
}

/// SQL value of a JSON value (json_extract, ->>).
Object? jsonToSql(Object? v) {
  if (v == null || v is int || v is double || v is String) return v;
  if (v is bool) return v ? 1 : 0;
  return renderJson(v);
}

/// JSON value of a SQL argument. Text is a JSON string unless [isJson]
/// (the argument came from a JSON function or a JSON column).
Object? sqlToJson(Object? v, bool isJson) {
  if (v == null || v is int) return v;
  if (v is double) return v;
  if (v is String) return isJson ? parseJson(v) : v;
  if (v is Uint8List) {
    throw const ZxDbException('JSON cannot hold BLOB values');
  }
  return v;
}

/// Parses the JSON document argument of json_* functions.
Object? docArg(Object? v) {
  if (v is Uint8List) throw _malformed();
  if (v is num) return v;
  return parseJson(toText(v)!);
}

/// JSON type name (json_type).
String jsonTypeName(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is int) return 'integer';
  if (v is double) return 'real';
  if (v is String) return 'text';
  if (v is List) return 'array';
  return 'object';
}

// ------------------------------------------------------------ paths

/// One path step: a String key or an int index (negative: from the end,
/// as in [#-1]); `appendIndex` for [#].
class PathStep {
  final String? key;
  final int? index;
  final bool fromEnd;
  final bool append;
  const PathStep.key(this.key)
      : index = null,
        fromEnd = false,
        append = false;
  const PathStep.index(this.index, {this.fromEnd = false})
      : key = null,
        append = false;
  const PathStep.append()
      : key = null,
        index = null,
        fromEnd = false,
        append = true;
}

List<PathStep> parsePath(String path) {
  if (!path.startsWith(r'$')) {
    throw ZxDbException('JSON path error near \'$path\'');
  }
  final out = <PathStep>[];
  var i = 1;
  ZxDbException bad() =>
      ZxDbException('JSON path error near \'${path.substring(i)}\'');
  while (i < path.length) {
    final c = path[i];
    if (c == '.') {
      i++;
      if (i < path.length && path[i] == '"') {
        final e = path.indexOf('"', i + 1);
        if (e < 0) throw bad();
        out.add(PathStep.key(path.substring(i + 1, e)));
        i = e + 1;
      } else {
        final st = i;
        while (i < path.length && path[i] != '.' && path[i] != '[') {
          i++;
        }
        if (i == st) throw bad();
        out.add(PathStep.key(path.substring(st, i)));
      }
    } else if (c == '[') {
      final e = path.indexOf(']', i);
      if (e < 0) throw bad();
      final inner = path.substring(i + 1, e).trim();
      if (inner == '#') {
        out.add(const PathStep.append());
      } else if (inner.startsWith('#-')) {
        final n = int.tryParse(inner.substring(2).trim());
        if (n == null) throw bad();
        out.add(PathStep.index(n, fromEnd: true));
      } else {
        final n = int.tryParse(inner);
        if (n == null || n < 0) throw bad();
        out.add(PathStep.index(n));
      }
      i = e + 1;
    } else {
      throw bad();
    }
  }
  return out;
}

/// Path for the right side of -> / ->>: text starting with '$' is a path,
/// other text is a key, an integer is an array index.
List<PathStep> arrowPath(Object? r) {
  if (r is int) {
    return r < 0 ? [PathStep.index(-r, fromEnd: true)] : [PathStep.index(r)];
  }
  final s = toText(r) ?? '';
  if (s.startsWith(r'$')) return parsePath(s);
  return [PathStep.key(s)];
}

Object? lookupPath(Object? doc, List<PathStep> steps) {
  var cur = doc;
  for (final st in steps) {
    if (st.key != null) {
      if (cur is! Map || !cur.containsKey(st.key)) return missing;
      cur = cur[st.key];
    } else {
      if (cur is! List || st.append) return missing;
      final idx = st.fromEnd ? cur.length - st.index! : st.index!;
      if (idx < 0 || idx >= cur.length) return missing;
      cur = cur[idx];
    }
  }
  return cur;
}

/// json_set / json_insert / json_replace on a (mutable copy of) doc.
/// mode: 0 set, 1 insert, 2 replace. Returns the new root.
Object? editPath(Object? doc, List<PathStep> steps, Object? value, int mode) {
  if (steps.isEmpty) {
    return mode == 1 ? doc : value;
  }
  Object? cur = doc;
  for (var i = 0; i < steps.length; i++) {
    final st = steps[i];
    final last = i == steps.length - 1;
    if (st.key != null) {
      if (cur is! Map) return doc;
      final m = cur as Map<String, Object?>;
      if (last) {
        final has = m.containsKey(st.key);
        if ((has && mode != 1) || (!has && mode != 2)) m[st.key!] = value;
        return doc;
      }
      if (!m.containsKey(st.key)) {
        if (mode == 2) return doc;
        m[st.key!] = _containerFor(steps[i + 1]);
      }
      cur = m[st.key];
    } else {
      if (cur is! List) return doc;
      final l = cur as List<Object?>;
      var idx = st.append
          ? l.length
          : (st.fromEnd ? l.length - st.index! : st.index!);
      if (idx < 0) return doc;
      if (last) {
        if (idx < l.length) {
          if (mode != 1) l[idx] = value;
        } else if (idx == l.length && mode != 2) {
          l.add(value);
        }
        return doc;
      }
      if (idx >= l.length) {
        if (mode == 2 || idx > l.length) return doc;
        l.add(_containerFor(steps[i + 1]));
        idx = l.length - 1;
      }
      cur = l[idx];
    }
  }
  return doc;
}

Object _containerFor(PathStep next) =>
    next.key != null ? <String, Object?>{} : <Object?>[];

Object? removePath(Object? doc, List<PathStep> steps) {
  if (steps.isEmpty) return missing;
  var cur = doc;
  for (var i = 0; i < steps.length - 1; i++) {
    cur = lookupPath(cur, [steps[i]]);
    if (identical(cur, missing)) return doc;
  }
  final st = steps.last;
  if (st.key != null) {
    if (cur is Map) cur.remove(st.key);
  } else if (cur is List && !st.append) {
    final idx = st.fromEnd ? cur.length - st.index! : st.index!;
    if (idx >= 0 && idx < cur.length) cur.removeAt(idx);
  }
  return doc;
}

/// Deep copy (so edits do not alias parsed constants).
Object? jsonCopy(Object? v) {
  if (v is Map) {
    return <String, Object?>{
      for (final e in v.entries) e.key as String: jsonCopy(e.value)
    };
  }
  if (v is List) return <Object?>[for (final x in v) jsonCopy(x)];
  return v;
}

/// RFC 7396 merge patch (json_patch).
Object? mergePatch(Object? target, Object? patch) {
  if (patch is! Map) return patch;
  final t = target is Map ? target as Map<String, Object?> : <String, Object?>{};
  patch.forEach((k, v) {
    if (v == null) {
      t.remove(k);
    } else {
      t[k as String] = mergePatch(t[k], v);
    }
  });
  return t;
}

/// One row of json_each / json_tree.
class JsonEachRow {
  final Object? key;
  final Object? value;
  final int id;
  final int? parent;
  final String fullkey;
  final String path;
  JsonEachRow(
      this.key, this.value, this.id, this.parent, this.fullkey, this.path);
}

String _keyPath(String base, Object key) {
  if (key is int) return '$base[$key]';
  final k = key as String;
  if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(k)) return '$base.$k';
  return '$base."$k"';
}

/// Rows of json_each (tree == false) or json_tree (tree == true).
List<JsonEachRow> jsonEach(Object? doc, String rootPath, bool tree) {
  final start = lookupPath(doc, parsePath(rootPath));
  final out = <JsonEachRow>[];
  if (identical(start, missing)) return out;
  var id = 0;
  if (!tree) {
    if (start is List) {
      for (var i = 0; i < start.length; i++) {
        out.add(JsonEachRow(
            i, start[i], ++id, null, _keyPath(rootPath, i), rootPath));
      }
    } else if (start is Map) {
      start.forEach((k, v) {
        out.add(JsonEachRow(
            k, v, ++id, null, _keyPath(rootPath, k as String), rootPath));
      });
    } else {
      out.add(JsonEachRow(null, start, ++id, null, rootPath, rootPath));
    }
    return out;
  }
  void walk(Object? key, Object? v, int? parent, String full, String path) {
    final my = ++id;
    out.add(JsonEachRow(key, v, my, parent, full, path));
    if (v is List) {
      for (var i = 0; i < v.length; i++) {
        walk(i, v[i], my, _keyPath(full, i), full);
      }
    } else if (v is Map) {
      v.forEach((k, x) => walk(k, x, my, _keyPath(full, k as String), full));
    }
  }

  // The root row has a null key and the path of its parent.
  final steps = parsePath(rootPath);
  Object? rootKey;
  var parentPath = rootPath;
  if (steps.isNotEmpty) {
    final l = steps.last;
    rootKey = l.key ?? l.index;
    final cut = rootPath.lastIndexOf(RegExp(r'[.\[]'));
    parentPath = cut > 0 ? rootPath.substring(0, cut) : r'$';
  }
  walk(rootKey, start, null, rootPath, parentPath);
  return out;
}
