// Full-text index over the metadata tables (docs/zxdb-design.md 1.2): the
// file name, title, description and tags of zx_meta and the text of every
// zx_layers row (subtitles are searchable), one document per file
// (SHA-256), with arca's field-prefixed terms (whitepaper Appendix A:
// tag:dipole-antenna, transcript:word, lang:pt) and BM25 ranking.
//
// Trees (through the storage contract, in the database's transaction):
//   zx_fts_post   key (term TEXT, field INT, sha256 BLOB), value [tf]
//   zx_fts_docs   key sha256, value [len of each field..., then the
//                 (term, field, tf) triples of the document]
//   zx_fts_stats  key (field): [documents with the field, total length];
//                 key ('N'): [documents]; key ('stem'): [0 or 1]
// Keys use keycodec.dart, so one term's postings are one key range and a
// prefix query (word*) is a range over the term bytes.
//
// Maintenance is incremental: every write of zx_meta or zx_layers through
// ZxMetaDb reindexes that file's document (its old terms come from
// zx_fts_docs, so nothing is re-read), in the same transaction.
//
// Tokenizer (fts_text.dart, shared with the fts5 tables of SQL): Unicode
// letters and digits, lowercase, common diacritics folded.
// Optional light stemming (English plurals), fixed per
// index when it is created. Subtitle text (SRT, WebVTT) loses its cue
// numbers, time lines and tags first.
//
// Query language: words are ANDed; `a OR b`; `-word` excludes; `word*`
// matches a prefix; `field:word` limits a word to a field; "quoted
// words" are ANDed (no positions are kept). Fields: name, title,
// description, tag, subtitles, transcript (speech: transcript, subtitles
// and captions), ocr, caption, chapters, lyrics, text, layer (any layer),
// lang (a filter: files with a layer in that language, 'pt' matches
// 'pt-BR'). tag: matches whole tags (tag:dipole-antenna); the words of
// tags are a field of their own that plain words search. A word without
// a field searches every field but lang, with weights (title and tag 3,
// name and tag words 2, description 1, chapters 0.8, other layers 0.5).

import 'dart:typed_data';

import '../fts_text.dart';
import '../keycodec.dart';
import '../record.dart';
import '../storage_api.dart';
import '../system/sys_vtab.dart';
import 'meta_store.dart';

export '../fts_text.dart' show ftsFold, ftsStem, ftsTokenize;

const List<String> ftsFields = [
  'name', 'title', 'description', 'tag', 'subtitles', 'transcript', //
  'ocr', 'caption', 'chapters', 'lyrics', 'text', 'lang', 'tagword',
];
const List<double> _weights = [
  2, 3, 1, 3, 0.5, 0.5, 0.5, 0.5, 0.8, 0.5, 0.5, 0, 2,
];
const int _fLang = 11;
const int _fTagWord = 12;
const int _nFields = 13;

const Map<String, List<int>> _prefixFields = {
  'name': [0],
  'file': [0],
  'title': [1],
  'description': [2],
  'desc': [2],
  'tag': [3],
  'tags': [3],
  'subtitles': [4],
  'subtitle': [4],
  'srt': [4],
  'transcript': [4, 5, 7],
  'ocr': [6],
  'caption': [7],
  'captions': [7],
  'chapters': [8],
  'chapter': [8],
  'lyrics': [9],
  'text': [10],
  'layer': [4, 5, 6, 7, 8, 9, 10],
  'lang': [_fLang],
  'language': [_fLang],
};

const List<int> _defaultFields = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12];

/// The field of a layer kind.
int ftsFieldOfKind(String? kind) => switch (kind?.toLowerCase()) {
      'subtitles' || 'subtitle' => 4,
      'transcript' || 'transcription' => 5,
      'ocr' => 6,
      'caption' || 'captions' => 7,
      'chapters' || 'chapter' || 'outline' => 8,
      'lyrics' => 9,
      'description' => 2,
      _ => 10,
    };

// ---------------------------------------------------------------------------
// subtitles

final RegExp _timeLine = RegExp(r'-->');
final RegExp _cueNumber = RegExp(r'^\s*\d+\s*$');
final RegExp _markup = RegExp(r'<[^>]*>|\{\\[^}]*\}');

/// The spoken text of SubRip or WebVTT subtitles: without cue numbers,
/// time lines, the WEBVTT header and formatting tags. Other text is
/// returned as it is.
String ftsSubtitleText(String s) {
  if (!_timeLine.hasMatch(s)) return s;
  final out = StringBuffer();
  for (final line in s.split(RegExp(r'\r?\n'))) {
    if (line.contains('-->') ||
        _cueNumber.hasMatch(line) ||
        line.startsWith('WEBVTT') ||
        line.startsWith('NOTE')) {
      continue;
    }
    out.writeln(line.replaceAll(_markup, ''));
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// the index

class _Doc {
  final List<int> lengths = List<int>.filled(_nFields, 0);

  /// (field, term): tf
  final Map<(int, String), int> terms = {};

  void add(int field, String term) {
    terms.update((field, term), (n) => n + 1, ifAbsent: () => 1);
    lengths[field]++;
  }

  bool get isEmpty => terms.isEmpty;

  Uint8List encode() {
    final v = <Object?>[...lengths];
    for (final e in terms.entries) {
      v
        ..add(e.key.$2)
        ..add(e.key.$1)
        ..add(e.value);
    }
    return encodeRecord(v);
  }

  static _Doc decode(Uint8List b) {
    final r = decodeRecord(b);
    final d = _Doc();
    for (var i = 0; i < _nFields; i++) {
      d.lengths[i] = r[i] as int;
    }
    for (var i = _nFields; i + 2 < r.length; i += 3) {
      d.terms[(r[i + 1] as int, r[i] as String)] = r[i + 2] as int;
    }
    return d;
  }
}

/// One hit of [ZxFts.search].
class ZxFtsHit {
  final Uint8List sha256;
  final double score;
  const ZxFtsHit(this.sha256, this.score);
  @override
  String toString() => '${sha256.sublist(0, 4)} $score';
}

class _Atom {
  final List<int> fields;
  final String term;
  final bool prefix;
  _Atom(this.fields, this.term, this.prefix);
}

class _Clause {
  final bool negated;
  final List<_Atom> atoms; // alternatives (OR)
  _Clause(this.negated, this.atoms);
}

class ZxFts {
  static const postTree = 'zx_fts_post';
  static const docsTree = 'zx_fts_docs';
  static const statsTree = 'zx_fts_stats';

  static const double k1 = ftsK1, b = ftsB;

  /// Longest expansion of a prefix query.
  static int maxPrefixTerms = 256;

  final ZxMetaDb db;
  ZxFts(this.db);

  ZxSnapshot get _s => db.s;

  static void createTrees(ZxWriteTxn t, {bool stem = false}) {
    if (t.tree(postTree) == null) t.createTree(postTree);
    if (t.tree(docsTree) == null) t.createTree(docsTree);
    if (t.tree(statsTree) == null) {
      t.createTree(statsTree).put(encodeKey(['stem']), encodeRecord([stem ? 1 : 0]));
    }
  }

  bool? _stem;
  bool get stemming {
    final s = _stem;
    if (s != null) return s;
    final v = _s.tree(statsTree)?.get(encodeKey(['stem']));
    return _stem = v != null && decodeRecord(v)[0] == 1;
  }

  List<String> _tok(String s) => ftsTokenize(s, stem: stemming);

  /// The document of [sha256] from its zx_meta and zx_layers rows.
  _Doc _build(Uint8List sha256) {
    final d = _Doc();
    final m = db.meta(sha256);
    if (m != null) {
      final path = m[ZxMetaSchema.mPath];
      if (path is String && path.isNotEmpty) {
        for (final w in _tok(path.split('/').last)) {
          d.add(0, w);
        }
      }
      final title = m[ZxMetaSchema.mTitle];
      if (title is String) {
        for (final w in _tok(title)) {
          d.add(1, w);
        }
      }
      final desc = m[ZxMetaSchema.mDescription];
      if (desc is String) {
        for (final w in _tok(desc)) {
          d.add(2, w);
        }
      }
      for (final tag in ZxMetaDb.tagsOf(m[ZxMetaSchema.mTags])) {
        final whole = ftsFold(tag.trim());
        if (whole.isEmpty) continue;
        d.add(3, whole);
        final words = _tok(tag);
        if (words.length != 1 || words[0] != whole) {
          for (final w in words) {
            d.add(_fTagWord, w);
          }
        }
      }
    }
    for (final l in db.layersOf(sha256)) {
      final lang = l[ZxMetaSchema.lLanguage];
      if (lang is String && lang.isNotEmpty) {
        final code = lang.toLowerCase().replaceAll('_', '-');
        d.terms.putIfAbsent((_fLang, code), () => 1);
        final base = code.split('-').first;
        if (base != code) d.terms.putIfAbsent((_fLang, base), () => 1);
      }
      final c = l[ZxMetaSchema.lContent];
      if (c is! String || c.isEmpty) continue;
      final f = ftsFieldOfKind(l[ZxMetaSchema.lKind] as String?);
      for (final w in _tok(ftsSubtitleText(c))) {
        d.add(f, w);
      }
    }
    return d;
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

  /// Brings the document of [sha256] up to date with its rows.
  void reindex(Uint8List sha256) {
    final t = db.s as ZxWriteTxn;
    createTrees(t);
    final post = t.tree(postTree)!,
        docs = t.tree(docsTree)!,
        stats = t.tree(statsTree)!;
    final oldBytes = docs.get(sha256);
    final old = oldBytes == null ? null : _Doc.decode(oldBytes);
    final cur = _build(sha256);
    if (old != null) {
      for (final e in old.terms.entries) {
        final k = e.key;
        if (cur.terms[k] == e.value) continue;
        if (!cur.terms.containsKey(k)) {
          post.delete(encodeKey([k.$2, k.$1, sha256]));
        }
      }
    }
    for (final e in cur.terms.entries) {
      final k = e.key;
      if (old != null && old.terms[k] == e.value) continue;
      post.put(encodeKey([k.$2, k.$1, sha256]), encodeRecord([e.value]));
    }
    for (var f = 0; f < _nFields; f++) {
      final had = old != null && old.lengths[f] > 0;
      final has = cur.lengths[f] > 0;
      final dl = cur.lengths[f] - (old?.lengths[f] ?? 0);
      final dd = (has ? 1 : 0) - (had ? 1 : 0);
      if (dl != 0 || dd != 0) _addStat(stats, f, dd, dl);
    }
    final dn = (cur.isEmpty ? 0 : 1) - (old == null ? 0 : 1);
    if (dn != 0) _addStat(stats, 'N', dn, 0);
    if (cur.isEmpty) {
      if (old != null) docs.delete(sha256);
    } else {
      docs.put(sha256, cur.encode());
    }
  }

  /// Rebuilds the whole index from the tables.
  void rebuild() {
    final t = db.s as ZxWriteTxn;
    for (final n in [postTree, docsTree]) {
      if (t.tree(n) != null) t.tree(n)!.deleteRange();
    }
    final st = t.tree(statsTree);
    if (st != null) {
      final stem = st.get(encodeKey(['stem']));
      st.deleteRange();
      if (stem != null) st.put(encodeKey(['stem']), stem);
    }
    final shas = <String>{};
    for (final spec in [ZxMetaSchema.meta, ZxMetaSchema.layers]) {
      for (final r in db.scan(spec)) {
        shas.add(String.fromCharCodes(r[0] as Uint8List));
      }
    }
    for (final s in shas) {
      reindex(Uint8List.fromList(s.codeUnits));
    }
  }

  /// Documents in the index.
  int get documentCount {
    final t = _s.tree(statsTree);
    return t == null ? 0 : _stat(t, 'N').$1;
  }

  // ---- queries

  List<_Clause> _parse(String q) {
    final out = <_Clause>[];
    final parts = <String>[];
    // split on spaces, keeping "quoted words" together
    final re = RegExp(r'(-?)(?:([\p{L}\p{N}_]+):)?"([^"]*)"|\S+', unicode: true);
    for (final m in re.allMatches(q)) {
      parts.add(m[0]!);
    }
    var orNext = false;
    for (final raw in parts) {
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
      var fields = _defaultFields;
      var fieldGiven = false;
      final colon = p.indexOf(':');
      if (colon > 0) {
        final f = _prefixFields[p.substring(0, colon).toLowerCase()];
        if (f != null) {
          fields = f;
          fieldGiven = true;
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
      final atoms = <_Atom>[];
      if (fieldGiven && (fields.contains(3) || fields.contains(_fLang)) &&
          fields.length == 1) {
        // tags and languages are whole terms
        var t = ftsFold(p.trim());
        if (fields[0] == _fLang) t = t.replaceAll('_', '-');
        if (t.isNotEmpty) atoms.add(_Atom(fields, t, prefix));
      } else {
        final words = ftsTokenize(p, stem: stemming && !prefix);
        for (var i = 0; i < words.length; i++) {
          atoms.add(_Atom(fields, words[i], prefix && i == words.length - 1));
        }
      }
      if (atoms.isEmpty) continue;
      if (atoms.length == 1) {
        if (orNext && !neg) {
          out.last.atoms.add(atoms[0]);
        } else {
          out.add(_Clause(neg, [atoms[0]]));
        }
      } else {
        // several words from one token: each is its own AND clause
        for (final a in atoms) {
          out.add(_Clause(neg, [a]));
        }
      }
      orNext = false;
    }
    return out;
  }

  /// The postings of [a]: doc key to the list of (field, tf).
  Map<String, List<(int, int)>> _postings(_Atom a) {
    final t = _s.tree(postTree);
    final out = <String, List<(int, int)>>{};
    if (t == null) return out;
    final fset = a.fields.toSet();
    void scanTerm(Uint8List from, Uint8List? to) {
      final c = t.scan(from: from, to: to);
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
          final sha = k[2] as Uint8List;
          final tf = decodeRecord(c.value)[0] as int;
          (out[String.fromCharCodes(sha)] ??= []).add((f, tf));
        }
      } finally {
        c.close();
      }
    }

    final (from, to) = ftsTermRange(const [], a.term, prefix: a.prefix);
    scanTerm(from, to);
    return out;
  }

  Map<String, double> _score(_Atom a, int n, List<double> avg) {
    final p = _postings(a);
    final out = <String, double>{};
    if (p.isEmpty) return out;
    final df = p.length;
    final idf = ftsIdfPositive(n, df);
    final docs = _s.tree(docsTree);
    for (final e in p.entries) {
      var score = 0.0;
      List<int>? lens;
      for (final (f, tf) in e.value) {
        final w = _weights[f];
        if (w == 0) {
          score += 0; // a filter field
          continue;
        }
        lens ??= _lengthsOf(docs, e.key);
        final dl = lens[f];
        score += avg[f] <= 0
            ? w * ftsBm25(idf, tf, 1, 1.0)
            : w * ftsBm25(idf, tf, dl, avg[f]);
      }
      out[e.key] = score;
    }
    return out;
  }

  List<int> _lengthsOf(ZxTree? docs, String key) {
    if (docs == null) return List<int>.filled(_nFields, 0);
    final v = docs.get(Uint8List.fromList(key.codeUnits));
    if (v == null) return List<int>.filled(_nFields, 0);
    final r = decodeRecord(v);
    return [for (var i = 0; i < _nFields; i++) r[i] as int];
  }

  /// Documents matching [query] with their BM25 score.
  Map<String, double> _run(String query) {
    final clauses = _parse(query);
    final stats = _s.tree(statsTree);
    if (stats == null || clauses.isEmpty) return const {};
    final n = _stat(stats, 'N').$1;
    final avg = [
      for (var f = 0; f < _nFields; f++)
        () {
          final (d, l) = _stat(stats, f);
          return d == 0 ? 0.0 : l / d;
        }()
    ];
    Map<String, double>? acc;
    final excluded = <String>{};
    // positive clauses with the fewest postings first would be better; the
    // clause count is small
    for (final c in clauses) {
      final m = <String, double>{};
      for (final a in c.atoms) {
        for (final e in _score(a, n, avg).entries) {
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
          final s = m[e.key];
          if (s != null) next[e.key] = e.value + s;
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

  /// The best [n] files for [query], best first.
  List<ZxFtsHit> search(String query, int n) {
    final m = _run(query);
    final l = m.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return [
      for (final e in l.take(n))
        ZxFtsHit(Uint8List.fromList(e.key.codeUnits), e.value)
    ];
  }

  /// The SHA-256 of every file matching [query] (as String of its bytes).
  Set<String> matching(String query) => _run(query).keys.toSet();

  /// Whether the file [sha256] matches [query].
  bool matches(Uint8List sha256, String query) =>
      _run(query).containsKey(String.fromCharCodes(sha256));
}

// ---------------------------------------------------------------------------
// SQL exposure

/// `fts_search(query, n)`: the n best files for a query, with path, title
/// and BM25 score, best first.
class ZxFtsSearchTable extends SysVTable {
  final ZxMetaAccess access;
  ZxFtsSearchTable(this.access);

  static const _columns = [
    SysColumn('sha256', 'BLOB'),
    SysColumn('path', 'TEXT'),
    SysColumn('title', 'TEXT'),
    SysColumn('score', 'REAL'),
    SysColumn('query', 'TEXT', hidden: true),
    SysColumn('n', 'INTEGER', hidden: true),
  ];

  @override
  String get name => 'fts_search';
  @override
  List<SysColumn> get columns => _columns;

  @override
  void bestIndex(SysIndexInfo info) {
    final roles = <String>[];
    for (final col in [4, 5]) {
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
    info.orderByConsumed = ob.length == 1 && ob[0].column == 3 && ob[0].desc;
  }

  @override
  SysCursor open(SysIndexInfo info, List<Object?> args, {SysAsOf? asOf}) {
    final roles =
        info.idxStr.isEmpty ? const <String>[] : info.idxStr.split(' ');
    String? query;
    var n = 20;
    for (var k = 0; k < roles.length; k++) {
      if (roles[k] == 'query' && args[k] is String) query = args[k] as String;
      if (roles[k] == 'n' && args[k] is int) n = args[k] as int;
    }
    if (query == null) return SysListCursor(const []);
    final (s, release) = access.read(asOf);
    try {
      final db = ZxMetaDb(s);
      return SysListCursor([
        for (final h in db.fts.search(query, n))
          () {
            final m = db.meta(h.sha256);
            return [
              h.sha256,
              m?[ZxMetaSchema.mPath],
              m?[ZxMetaSchema.mTitle],
              h.score,
              query,
              n
            ];
          }()
      ]);
    } finally {
      release();
    }
  }
}

/// `fts_match(sha256, query)`: 1 when the file matches the query, else 0.
/// The matching set of a query is computed once per statement (cached by
/// query text until [reset]).
class ZxFtsMatchFunction {
  final ZxMetaAccess access;
  final Map<String, Set<String>> _cache = {};
  ZxFtsMatchFunction(this.access);

  void reset() => _cache.clear();

  Object? call(List<Object?> args) {
    final sha = args[0], q = args[1];
    if (sha is! Uint8List || q is! String) return null;
    final set = _cache[q] ??= () {
      final (s, release) = access.read(null);
      try {
        return ZxMetaDb(s).fts.matching(q);
      } finally {
        release();
      }
    }();
    return set.contains(String.fromCharCodes(sha)) ? 1 : 0;
  }
}
