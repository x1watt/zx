// A named full-text index for application data (docs/zxdb-design.md 10.4,
// generalised): the documents are whatever the program puts under a key,
// with fields it names and weights it gives, ranked by BM25. The metadata
// tables' index (meta/fts.dart) is the same machinery bound to zx_meta.
//
// Trees, through the storage contract, in the caller's transaction:
//   fts:<name>:post   key (term TEXT, field INT, doc TEXT), value [tf]
//   fts:<name>:docs   key doc (UTF-8), value [len per field..., then the
//                     (term, field, tf) triples]: a re-put or a remove
//                     deletes the old postings without reading anything else
//   fts:<name>:stats  key (field): [documents with it, total length];
//                     key ('N'): [documents]
// One term's postings are one key range; a prefix (word*) is a range over
// the term bytes.
//
// Query language, as meta/fts.dart: words are ANDed; `a OR b`; `-word`
// excludes; `word*` is a prefix; `"a b"` ANDs its words (no positions);
// `field:word` limits a word to a field. Words are lowercased with Latin and
// Greek accents folded (ftsTokenize).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'keycodec.dart';
import 'meta/fts.dart' show ftsTokenize;
import 'record.dart';
import 'storage_api.dart';

/// One hit of [ZxTextIndex.search].
class ZxTextHit {
  const ZxTextHit(this.key, this.score);
  final String key;
  final double score;
  @override
  String toString() => '$key $score';
}

class _Atom {
  _Atom(this.fields, this.term, this.prefix);
  final List<int> fields;
  final String term;
  final bool prefix;
}

class _Clause {
  _Clause(this.negated, this.atoms);
  final bool negated;
  final List<_Atom> atoms; // alternatives (OR)
}

/// A full-text index named [name] over documents with [fields] (name to
/// weight; a weight of 0 makes a field a filter that matches but does not
/// rank). The field list is the index's: keep it fixed for one name.
class ZxTextIndex {
  ZxTextIndex(this.name, Map<String, double> fields)
      : fieldNames = fields.keys.toList(),
        weights = fields.values.toList();

  final String name;
  final List<String> fieldNames;
  final List<double> weights;

  static const double k1 = 1.2, b = 0.75;

  /// Longest expansion of a prefix query.
  static int maxPrefixTerms = 256;

  String get postTree => 'fts:$name:post';
  String get docsTree => 'fts:$name:docs';
  String get statsTree => 'fts:$name:stats';

  int get _n => fieldNames.length;

  void _create(ZxWriteTxn t) {
    if (t.tree(postTree) == null) t.createTree(postTree);
    if (t.tree(docsTree) == null) t.createTree(docsTree);
    if (t.tree(statsTree) == null) t.createTree(statsTree);
  }

  static Uint8List _docKey(String key) => Uint8List.fromList(utf8.encode(key));

  (List<int>, Map<(int, String), int>) _build(Map<String, String?> fields) {
    final lengths = List<int>.filled(_n, 0);
    final terms = <(int, String), int>{};
    for (final e in fields.entries) {
      final f = fieldNames.indexOf(e.key);
      if (f < 0) {
        throw ArgumentError('index $name has no field ${e.key}');
      }
      for (final w in ftsTokenize(e.value ?? '')) {
        terms.update((f, w), (n) => n + 1, ifAbsent: () => 1);
        lengths[f]++;
      }
    }
    return (lengths, terms);
  }

  (List<int>, Map<(int, String), int>)? _read(ZxTree docs, Uint8List k) {
    final v = docs.get(k);
    if (v == null) return null;
    final r = decodeRecord(v);
    final lengths = [for (var i = 0; i < _n; i++) r[i] as int];
    final terms = <(int, String), int>{};
    for (var i = _n; i + 2 < r.length; i += 3) {
      terms[(r[i + 1] as int, r[i] as String)] = r[i + 2] as int;
    }
    return (lengths, terms);
  }

  (int, int) _stat(ZxTree t, Object key) {
    final v = t.get(encodeKey([key]));
    if (v == null) return (0, 0);
    final r = decodeRecord(v);
    return (r[0] as int, r.length > 1 ? r[1] as int : 0);
  }

  void _addStat(ZxWritableTree t, Object key, int docs, int len) {
    final (d0, l0) = _stat(t, key);
    final d = d0 + docs, l = l0 + len;
    if (d == 0 && l == 0) {
      t.delete(encodeKey([key]));
    } else {
      t.put(encodeKey([key]), encodeRecord([d, l]));
    }
  }

  /// Puts (or replaces) document [key] with [fields] (field name to text;
  /// fields left out are empty). Writes only what changed.
  void put(ZxWriteTxn t, String key, Map<String, String?> fields) =>
      _apply(t, key, _build(fields));

  /// Removes document [key] (nothing when it is not there).
  void remove(ZxWriteTxn t, String key) =>
      _apply(t, key, (List<int>.filled(_n, 0), const {}));

  void _apply(ZxWriteTxn t, String key,
      (List<int>, Map<(int, String), int>) cur) {
    _create(t);
    final post = t.tree(postTree)!,
        docs = t.tree(docsTree)!,
        stats = t.tree(statsTree)!;
    final dk = _docKey(key);
    final old = _read(docs, dk);
    final (lengths, terms) = cur;
    if (old != null) {
      for (final e in old.$2.entries) {
        if (!terms.containsKey(e.key)) {
          post.delete(encodeKey([e.key.$2, e.key.$1, key]));
        }
      }
    }
    for (final e in terms.entries) {
      if (old != null && old.$2[e.key] == e.value) continue;
      post.put(encodeKey([e.key.$2, e.key.$1, key]), encodeRecord([e.value]));
    }
    for (var f = 0; f < _n; f++) {
      final had = old != null && old.$1[f] > 0;
      final has = lengths[f] > 0;
      final dl = lengths[f] - (old?.$1[f] ?? 0);
      final dd = (has ? 1 : 0) - (had ? 1 : 0);
      if (dl != 0 || dd != 0) _addStat(stats, f, dd, dl);
    }
    final empty = terms.isEmpty;
    final dn = (empty ? 0 : 1) - (old == null ? 0 : 1);
    if (dn != 0) _addStat(stats, 'N', dn, 0);
    if (empty) {
      if (old != null) docs.delete(dk);
    } else {
      final v = <Object?>[...lengths];
      for (final e in terms.entries) {
        v
          ..add(e.key.$2)
          ..add(e.key.$1)
          ..add(e.value);
      }
      docs.put(dk, encodeRecord(v));
    }
  }

  /// Documents in the index (at snapshot [s]).
  int length(ZxSnapshot s) {
    final t = s.tree(statsTree);
    return t == null ? 0 : _stat(t, 'N').$1;
  }

  /// Whether document [key] is in the index.
  bool contains(ZxSnapshot s, String key) =>
      s.tree(docsTree)?.get(_docKey(key)) != null;

  List<_Clause> _parse(String q) {
    final out = <_Clause>[];
    final re = RegExp(r'(-?)(?:([\p{L}\p{N}_]+):)?"([^"]*)"\*?|\S+', unicode: true);
    var orNext = false;
    final all = List<int>.generate(_n, (i) => i);
    for (final m in re.allMatches(q)) {
      final raw = m[0]!;
      if (raw == 'OR') {
        orNext = out.isNotEmpty;
        continue;
      }
      if (raw == 'AND') continue;
      var p = raw;
      var neg = false;
      if (p.startsWith('-') && p.length > 1) {
        neg = true;
        p = p.substring(1);
      }
      var fields = all;
      final colon = p.indexOf(':');
      if (colon > 0 && !p.startsWith('"')) {
        final f = fieldNames.indexOf(p.substring(0, colon).toLowerCase());
        if (f >= 0) {
          fields = [f];
          p = p.substring(colon + 1);
        }
      }
      var prefix = false;
      if (p.endsWith('*')) {
        prefix = true;
        p = p.substring(0, p.length - 1);
      }
      if (p.startsWith('"') && p.endsWith('"') && p.length >= 2) {
        p = p.substring(1, p.length - 1);
      }
      final words = ftsTokenize(p);
      final atoms = [
        for (var i = 0; i < words.length; i++)
          _Atom(fields, words[i], prefix && i == words.length - 1)
      ];
      if (atoms.isEmpty) continue;
      if (atoms.length == 1 && orNext && !neg) {
        out.last.atoms.add(atoms[0]);
      } else {
        for (final a in atoms) {
          out.add(_Clause(neg, [a]));
        }
      }
      orNext = false;
    }
    return out;
  }

  Map<String, List<(int, int)>> _postings(ZxSnapshot s, _Atom a) {
    final t = s.tree(postTree);
    final out = <String, List<(int, int)>>{};
    if (t == null) return out;
    final fset = a.fields.toSet();
    final full = encodeKey([a.term]);
    // a prefix: the text component without its terminator covers every term
    // starting with it
    final from = a.prefix ? Uint8List.sublistView(full, 0, full.length - 2) : full;
    final c = t.scan(from: from, to: prefixEnd(from));
    var terms = 0;
    String? lastTerm;
    try {
      while (c.moveNext()) {
        final k = decodeKey(c.key);
        final term = k[0] as String;
        if (a.prefix && term != lastTerm) {
          lastTerm = term;
          if (++terms > maxPrefixTerms) break;
        }
        final f = k[1] as int;
        if (!fset.contains(f)) continue;
        (out[k[2] as String] ??= []).add((f, decodeRecord(c.value)[0] as int));
      }
    } finally {
      c.close();
    }
    return out;
  }

  Map<String, double> _run(ZxSnapshot s, String query) {
    final clauses = _parse(query);
    final stats = s.tree(statsTree);
    if (stats == null || clauses.isEmpty) return const {};
    final n = _stat(stats, 'N').$1;
    final avg = [
      for (var f = 0; f < _n; f++)
        () {
          final (d, l) = _stat(stats, f);
          return d == 0 ? 0.0 : l / d;
        }()
    ];
    final docs = s.tree(docsTree);
    final lens = <String, List<int>>{};
    List<int> lengthsOf(String key) => lens.putIfAbsent(key, () {
          final r = docs == null ? null : _read(docs, _docKey(key));
          return r?.$1 ?? List<int>.filled(_n, 0);
        });
    Map<String, double> score(_Atom a) {
      final p = _postings(s, a);
      final out = <String, double>{};
      if (p.isEmpty) return out;
      final idf = math.log(1 + (n - p.length + 0.5) / (p.length + 0.5));
      for (final e in p.entries) {
        var sc = 0.0;
        for (final (f, tf) in e.value) {
          final w = weights[f];
          if (w == 0) continue;
          final norm = avg[f] <= 0 ? 1.0 : lengthsOf(e.key)[f] / avg[f];
          sc += w * idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * norm));
        }
        out[e.key] = sc;
      }
      return out;
    }

    Map<String, double>? acc;
    final excluded = <String>{};
    for (final c in clauses) {
      final m = <String, double>{};
      for (final a in c.atoms) {
        for (final e in score(a).entries) {
          m[e.key] = (m[e.key] ?? 0) + e.value;
        }
      }
      if (c.negated) {
        excluded.addAll(m.keys);
        continue;
      }
      if (acc == null) {
        acc = m;
      } else {
        final next = <String, double>{};
        for (final e in acc.entries) {
          final x = m[e.key];
          if (x != null) next[e.key] = e.value + x;
        }
        acc = next;
      }
      if (acc.isEmpty) return const {};
    }
    if (acc == null) return const {};
    for (final x in excluded) {
      acc.remove(x);
    }
    return acc;
  }

  /// The best [limit] documents for [query], best first (ties by key).
  List<ZxTextHit> search(ZxSnapshot s, String query, {int limit = 50}) {
    final l = _run(s, query).entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return [for (final e in l.take(limit)) ZxTextHit(e.key, e.value)];
  }
}
