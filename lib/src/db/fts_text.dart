// Full-text building blocks shared by the metadata index (meta/fts.dart)
// and the fts5 virtual tables of SQL (sql/fts5.dart): the tokenizer, the
// BM25 term weight and the key range of a term prefix.
//
// Tokenizer: Unicode letters and digits ([\p{L}\p{N}]+ after folding),
// lowercase with the common Latin (and Greek) diacritics folded (a with
// accents to a, c cedilla to c, sharp s to ss), so "Informacao" finds the
// word written with its accents. Optional light stemming (English
// plurals).

import 'dart:math' as math;
import 'dart:typed_data';

import 'keycodec.dart';

final Map<int, String> _fold = () {
  final m = <int, String>{};
  void put(String from, String to) {
    for (final r in from.runes) {
      m[r] = to;
    }
  }

  put('àáâãäåāăąǎ', 'a');
  put('çćĉċč', 'c');
  put('ďđ', 'd');
  put('èéêëēĕėęě', 'e');
  put('ĝğġģ', 'g');
  put('ĥħ', 'h');
  put('ìíîïĩīĭįı', 'i');
  put('ĵ', 'j');
  put('ķ', 'k');
  put('ĺļľŀł', 'l');
  put('ñńņňŉ', 'n');
  put('òóôõöøōŏő', 'o');
  put('ŕŗř', 'r');
  put('śŝşšș', 's');
  put('ţťŧț', 't');
  put('ùúûüũūŭůűų', 'u');
  put('ŵ', 'w');
  put('ýÿŷ', 'y');
  put('źżž', 'z');
  put('ß', 'ss');
  put('æ', 'ae');
  put('œ', 'oe');
  put('þ', 'th');
  put('ð', 'd');
  put('άᾶ', 'α');
  put('έ', 'ε');
  put('ή', 'η');
  put('ίϊΐ', 'ι');
  put('ό', 'ο');
  put('ύϋΰ', 'υ');
  put('ώ', 'ω');
  return m;
}();

final RegExp _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// Lowercases [s] and folds the common Latin diacritics.
String ftsFold(String s) {
  final l = s.toLowerCase();
  StringBuffer? sb;
  var i = 0;
  for (final r in l.runes) {
    final f = r < 0xC0 ? null : _fold[r];
    if (f != null && sb == null) {
      sb = StringBuffer(l.substring(0, i));
    }
    if (sb != null) {
      if (f != null) {
        sb.write(f);
      } else {
        sb.writeCharCode(r);
      }
    }
    i += r > 0xFFFF ? 2 : 1;
  }
  return sb?.toString() ?? l;
}

/// Light plural stemming (English): ies to y, sses to ss, and a final s
/// dropped (not after s, u or i) in words of more than 3 letters.
String ftsStem(String w) {
  if (w.length <= 3) return w;
  if (w.endsWith('ies') && w.length > 4) {
    return '${w.substring(0, w.length - 3)}y';
  }
  if (w.endsWith('sses')) return w.substring(0, w.length - 2);
  if (w.endsWith('s') &&
      !w.endsWith('ss') &&
      !w.endsWith('us') &&
      !w.endsWith('is')) {
    return w.substring(0, w.length - 1);
  }
  return w;
}

/// The words of [text], folded (and stemmed when [stem]), in order. Words
/// longer than [maxLength] are left out (null: none).
List<String> ftsTokenize(String text, {bool stem = false, int? maxLength = 64}) {
  final f = ftsFold(text);
  return [
    for (final m in _word.allMatches(f))
      if (maxLength == null || m[0]!.length <= maxLength)
        stem ? ftsStem(m[0]!) : m[0]!
  ];
}

// ---------------------------------------------------------------------------
// BM25

/// BM25 parameters (the usual ones, also SQLite fts5's).
const double ftsK1 = 1.2, ftsB = 0.75;

/// The BM25 weight of a term found [tf] times in a document of length
/// [dl] when the average is [avgdl]: idf * (tf * (k1 + 1) /
/// (tf + k1 * (1 - b + b * dl / avgdl))), in SQLite fts5's order of
/// operations (so equal inputs give its exact doubles).
double ftsBm25(double idf, num tf, num dl, double avgdl) =>
    idf * ((tf * (ftsK1 + 1.0)) / (tf + ftsK1 * (1 - ftsB + ftsB * dl / avgdl)));

/// Lucene's IDF (always positive): ln(1 + (n - df + 0.5) / (df + 0.5)).
double ftsIdfPositive(int n, int df) =>
    math.log(1 + (n - df + 0.5) / (df + 0.5));

/// SQLite fts5's IDF: ln((n - df + 0.5) / (df + 0.5)), at least 1e-6.
double ftsIdfFts5(int n, int df) {
  final idf = math.log((n - df + 0.5) / (df + 0.5));
  return idf <= 0 ? 1e-6 : idf;
}

// ---------------------------------------------------------------------------
// keys

/// The key range (from, to) of the keys `encodeKey([...lead, term, ...])`
/// whose text component [term] starts with [prefix] (when [prefix] is
/// true) or equals it.
(Uint8List, Uint8List?) ftsTermRange(List<Object?> lead, String term,
    {bool prefix = false}) {
  final full = encodeKey([...lead, term]);
  // without its 0x00 0x00 terminator, the text component is a prefix of
  // every longer text
  final from =
      prefix ? Uint8List.sublistView(full, 0, full.length - 2) : full;
  return (from, prefixEnd(from));
}
