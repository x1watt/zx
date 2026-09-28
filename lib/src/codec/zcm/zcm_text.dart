// zcm: the text model of paq8px with its English stemmer.
//
// A port of paq8px's TextModel, Word, Segment, Sentence, Paragraph and
// EnglishStemmer (Marcio Pais, the paq8px authors; the stemmer is based
// on the Porter2 stemmer of Martin Porter): the text is parsed into words,
// segments (between commas and the like), sentences and paragraphs; each
// word is stemmed and classified (verb, noun, adjective, plural, past
// tense, negation and more), the language (English or unknown) follows
// from how many of the last 64 words the stemmer recognized, and 28
// hashed contexts combine the current and previous words and stems, the
// last verb, the first word of the segment and of the previous one, the
// punctuation, numbers, nesting, the column and the shape of the line.
// It also sets ten mixer weight set selectors.
//
// Left out: the French and German stemmers and the word embeddings of
// paq8px (they need english.emb); the embedding contexts see 0. Hashes are
// zcm's 32-bit ones (paq8px uses 64-bit hashes).

import 'dart:typed_data';

import 'zcm_components.dart';
import 'zcm_models.dart';
import 'zcm_tables.dart';
import 'zcm_words.dart' show zcmLlog;

const int _tab = 0x09, _newLine = 0x0A, _cr = 0x0D, _space = 0x20;
const int _quote = 0x22, _apostrophe = 0x27;

@pragma('vm:prefer-inline')
int _lower(int c) => c >= 0x41 && c <= 0x5A ? c + 32 : c;

/// ilog2 of a 32-bit value (0 for 0).
@pragma('vm:prefer-inline')
int _ilog2(int x) {
  x &= 0xFFFFFFFF;
  if (x == 0) return 0;
  return x.bitLength - 1;
}

@pragma('vm:prefer-inline')
int _comb(int h, int c) => hash2(h + 0x6A09E667, c + 0x100);

@pragma('vm:prefer-inline')
int _b(bool v) => v ? 1 : 0;

// English word types (paq8px Language and English flags).
abstract final class _T {
  static const verb = 1 << 0;
  static const noun = 1 << 1;
  static const adjective = 1 << 2;
  static const plural = 1 << 3;
  static const male = 1 << 4;
  static const female = 1 << 5;
  static const negation = 1 << 6;
  static const pastTense = (1 << 7) | verb;
  static const presentParticiple = (1 << 8) | verb;
  static const adjectiveSuperlative = (1 << 9) | adjective;
  static const adjectiveWithout = (1 << 10) | adjective;
  static const adjectiveFull = (1 << 11) | adjective;
  static const adverbOfManner = 1 << 12;
  static const suffixNess = 1 << 13;
  static const suffixIty = (1 << 14) | noun;
  static const suffixCapable = 1 << 15;
  static const suffixNce = 1 << 16;
  static const suffixNt = 1 << 17;
  static const suffixIon = 1 << 18;
  static const suffixAl = (1 << 19) | adjective;
  static const suffixIc = (1 << 20) | adjective;
  static const suffixIve = 1 << 21;
  static const suffixOus = (1 << 22) | adjective;
  static const prefixOver = 1 << 23;
  static const prefixUnder = 1 << 24;
}

const int _langUnknown = 0, _langEnglish = 1, _langCount = 2;

/// A word of the text (paq8px Word): up to 63 lowercase letters, the
/// hash of the word and of its stem, its type flags and language.
final class ZcmWord {
  static const int maxSize = 64;
  final Uint8List letters = Uint8List(maxSize);
  int start = 0;
  int end = 0;
  int hash0 = 0; // the word
  int hash1 = 0; // the stem
  int type = 0;
  int language = 0;

  void reset() {
    letters.fillRange(0, maxSize, 0);
    start = end = 0;
    hash0 = hash1 = 0;
    type = language = 0;
  }

  void copyFrom(ZcmWord w) {
    letters.setAll(0, w.letters);
    start = w.start;
    end = w.end;
    hash0 = w.hash0;
    hash1 = w.hash1;
    type = w.type;
    language = w.language;
  }

  // Word::operator==
  bool eq(String s) {
    final len = s.length;
    if (end - start + _b(letters[start] != 0) != len) return false;
    for (var i = 0; i < len; i++) {
      if (letters[start + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  // Word::operator+=
  void add(int c) {
    if (end < maxSize - 1) {
      end += _b(letters[end] > 0);
      letters[end] = _lower(c);
    }
  }

  /// Letter [i] from the start (0 when the word is shorter).
  int at(int i) => end - start >= i ? letters[start + i] : 0;

  /// Letter [i] from the end (0 when the word is shorter).
  int back(int i) => end - start >= i ? letters[end - i] : 0;

  int get length => letters[start] != 0 ? end - start + 1 : 0;

  int _hash() {
    var h = 0;
    for (var i = start; i <= end; i++) {
      h = _comb(h, letters[i]);
    }
    return h;
  }

  void calculateWordHash() {
    hash0 = hash1 = _hash();
  }

  void calculateStemHash() {
    hash1 = _hash();
  }

  bool _matchAt(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      if (letters[off + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  bool changeSuffix(String oldSuffix, String newSuffix) {
    final len = oldSuffix.length;
    if (length > len && _matchAt(end - len + 1, oldSuffix)) {
      final n = newSuffix.length;
      if (n > 0) {
        final lim = end + n < maxSize - 1 ? end + n : maxSize - 1;
        final count = lim - end;
        final at = end - len + 1;
        for (var i = 0; i < count; i++) {
          letters[at + i] = newSuffix.codeUnitAt(i);
        }
        final e = end - len + n;
        end = e < maxSize - 1 ? e : maxSize - 1;
      } else {
        end -= len;
      }
      return true;
    }
    return false;
  }

  bool matchesAny(List<String> a) {
    final len = length;
    for (final s in a) {
      if (s.length == len && _matchAt(start, s)) return true;
    }
    return false;
  }

  bool endsWith(String suffix) {
    final len = suffix.length;
    return length > len && _matchAt(end - len + 1, suffix);
  }

  bool startsWith(String prefix) {
    final len = prefix.length;
    return length > len && _matchAt(start, prefix);
  }
}

/// A ring of the last [n] (a power of two) objects (paq8px Cache).
final class _Ring<T> {
  final List<T> data;
  final int mask;
  int index = 0;
  _Ring(this.data) : mask = data.length - 1;

  @pragma('vm:prefer-inline')
  T at(int i) => data[(index - i) & mask];
}

final class _Segment {
  final ZcmWord firstWord = ZcmWord();
  int wordCount = 0;
  int numCount = 0;

  void clear() {
    firstWord.reset();
    wordCount = numCount = 0;
  }
}

final class _Sentence extends _Segment {
  int type = 0; // 0: declarative, 1: interrogative, 2: exclamative
  int segmentCount = 0;
  int verbIndex = 0;
  int nounIndex = 0;
  int capitalIndex = 0;
  final ZcmWord lastVerb = ZcmWord();
  final ZcmWord lastNoun = ZcmWord();
  final ZcmWord lastCapital = ZcmWord();

  @override
  void clear() {
    super.clear();
    type = segmentCount = verbIndex = nounIndex = capitalIndex = 0;
    lastVerb.reset();
    lastNoun.reset();
    lastCapital.reset();
  }
}

final class _Paragraph {
  int sentenceCount = 0;
  final Int32List typeCount = Int32List(3);
  int typeMask = 0;

  void clear() {
    sentenceCount = 0;
    typeCount.fillRange(0, 3, 0);
    typeMask = 0;
  }
}

/// The English stemmer of paq8px (an affix stemmer based on Porter2) that
/// also classifies the word.
final class ZcmEnglishStemmer {
  static const String _vowels = 'aeiouy';
  static const String _doubles = 'bdfgmnprt';
  static const String _liEndings = 'cdeghkmnrt';
  static const String _nonShortConsonants = 'wxY';
  static const List<String> _maleWords = [
    'he', 'him', 'his', 'himself', 'man', 'men', 'boy', 'husband', 'actor' //
  ];
  static const List<String> _femaleWords = [
    'she', 'her', 'herself', 'woman', 'women', 'girl', 'wife', 'actress' //
  ];
  static const List<String> _commonWords = [
    'the', 'be', 'to', 'of', 'and', 'in', 'that', 'you', 'have', 'with', //
    'from', 'but'
  ];
  static const List<String> _suffixesStep0 = ["'s'", "'s", "'"];
  static const List<String> _suffixesStep1B = [
    'eedly', 'eed', 'ed', 'edly', 'ing', 'ingly' //
  ];
  static const List<int> _typesStep1B = [
    _T.adverbOfManner,
    0,
    _T.pastTense,
    _T.adverbOfManner | _T.pastTense,
    _T.presentParticiple,
    _T.adverbOfManner | _T.presentParticiple
  ];
  static const List<String> _step2From = [
    'ization', 'ational', 'ousness', 'iveness', 'fulness', 'tional', //
    'lessli', 'biliti', 'entli', 'ation', 'alism', 'aliti', 'fulli',
    'ousli', 'iviti', 'enci', 'anci', 'abli', 'izer', 'ator', 'alli', 'bli'
  ];
  static const List<String> _step2To = [
    'ize', 'ate', 'ous', 'ive', 'ful', 'tion', 'less', 'ble', 'ent', //
    'ate', 'al', 'al', 'ful', 'ous', 'ive', 'ence', 'ance', 'able', 'ize',
    'ate', 'al', 'ble'
  ];
  static const List<int> _typesStep2 = [
    _T.suffixIon,
    _T.suffixIon | _T.suffixAl,
    _T.suffixNess,
    _T.suffixNess,
    _T.suffixNess,
    _T.suffixIon | _T.suffixAl,
    _T.adverbOfManner,
    _T.adverbOfManner | _T.suffixIty,
    _T.adverbOfManner,
    _T.suffixIon,
    0,
    _T.suffixIty,
    _T.adverbOfManner,
    _T.adverbOfManner,
    _T.suffixIty,
    0,
    0,
    _T.adverbOfManner,
    0,
    0,
    _T.adverbOfManner,
    _T.adverbOfManner
  ];
  static const List<String> _step3From = [
    'ational', 'tional', 'alize', 'icate', 'iciti', 'ical', 'ful', 'ness' //
  ];
  static const List<String> _step3To = [
    'ate', 'tion', 'al', 'ic', 'ic', 'ic', '', '' //
  ];
  static const List<int> _typesStep3 = [
    _T.suffixIon | _T.suffixAl,
    _T.suffixIon | _T.suffixAl,
    0,
    0,
    _T.suffixIty,
    _T.suffixAl,
    _T.adjectiveFull,
    _T.suffixNess
  ];
  static const List<String> _suffixesStep4 = [
    'al', 'ance', 'ence', 'er', 'ic', 'able', 'ible', 'ant', 'ement', //
    'ment', 'ent', 'ou', 'ism', 'ate', 'iti', 'ous', 'ive', 'ize', 'sion',
    'tion'
  ];
  static const List<int> _typesStep4 = [
    _T.suffixAl,
    _T.suffixNce,
    _T.suffixNce,
    0,
    _T.suffixIc,
    _T.suffixCapable,
    _T.suffixCapable,
    _T.suffixNt,
    0,
    0,
    _T.suffixNt,
    0,
    0,
    0,
    _T.suffixIty,
    _T.suffixOus,
    _T.suffixIve,
    0,
    _T.suffixIon,
    _T.suffixIon
  ];
  static const List<String> _exceptionsRegion1 = ['gener', 'arsen', 'commun'];
  static const List<String> _exceptions1From = [
    'skis', 'skies', 'dying', 'lying', 'tying', 'idly', 'gently', 'ugly', //
    'early', 'only', 'singly', 'sky', 'news', 'howe', 'atlas', 'cosmos',
    'bias', 'andes', 'texas'
  ];
  static const List<String> _exceptions1To = [
    'ski', 'sky', 'die', 'lie', 'tie', 'idl', 'gentl', 'ugli', 'earli', //
    'onli', 'singl', 'sky', 'news', 'howe', 'atlas', 'cosmos', 'bias',
    'andes', 'texas'
  ];
  static const List<int> _typesExceptions1 = [
    _T.noun | _T.plural,
    _T.noun | _T.plural | _T.verb,
    _T.presentParticiple,
    _T.presentParticiple,
    _T.presentParticiple,
    _T.adverbOfManner,
    _T.adverbOfManner,
    _T.adjective,
    _T.adjective | _T.adverbOfManner,
    0,
    _T.adverbOfManner,
    _T.noun,
    _T.noun,
    0,
    _T.noun,
    _T.noun,
    _T.noun,
    _T.noun | _T.plural,
    _T.noun
  ];
  static const List<String> _exceptions2 = [
    'inning', 'outing', 'canning', 'herring', 'earring', 'proceed', //
    'exceed', 'succeed'
  ];
  static const List<int> _typesExceptions2 = [
    _T.noun, _T.noun, _T.noun, _T.noun, _T.noun, _T.verb, _T.verb, _T.verb //
  ];

  static bool _in(int c, String a) {
    for (var i = 0; i < a.length; i++) {
      if (a.codeUnitAt(i) == c) return true;
    }
    return false;
  }

  bool isVowel(int c) => _in(c, _vowels);
  bool _isConsonant(int c) => !isVowel(c);
  static bool _isShortConsonant(int c) => !_in(c, _nonShortConsonants);
  static bool _isDouble(int c) => _in(c, _doubles);
  static bool _isLiEnding(int c) => _in(c, _liEndings);

  // Stemmer::getRegion
  int _getRegion(ZcmWord w, int from) {
    var hasVowel = false;
    for (var i = w.start + from; i <= w.end; i++) {
      if (isVowel(w.letters[i])) {
        hasVowel = true;
        continue;
      }
      if (hasVowel) return i - w.start + 1;
    }
    return w.start + w.length;
  }

  // Stemmer::suffixInRn (the unsigned difference of C++ wraps to a large
  // value when the suffix is longer than the word).
  static bool _suffixInRn(ZcmWord w, int rn, String suffix) {
    final d = w.length - suffix.length;
    return w.start != w.end && (d < 0 || rn <= d);
  }

  int _getRegion1(ZcmWord w) {
    for (final e in _exceptionsRegion1) {
      if (w.startsWith(e)) return e.length;
    }
    return _getRegion(w, 0);
  }

  bool _endsInShortSyllable(ZcmWord w) {
    if (w.end == w.start) return false;
    if (w.end == w.start + 1) {
      return isVowel(w.back(1)) && _isConsonant(w.back(0));
    }
    return _isConsonant(w.back(2)) &&
        isVowel(w.back(1)) &&
        _isConsonant(w.back(0)) &&
        _isShortConsonant(w.back(0));
  }

  bool _isShortWord(ZcmWord w) =>
      _endsInShortSyllable(w) && _getRegion1(w) == w.length;

  bool _hasVowels(ZcmWord w) {
    for (var i = w.start; i <= w.end; i++) {
      if (isVowel(w.letters[i])) return true;
    }
    return false;
  }

  static bool _trimApostrophes(ZcmWord w) {
    var result = false;
    var cnt = 0;
    while (w.start != w.end && w.at(0) == _apostrophe) {
      result = true;
      w.start++;
      cnt++;
    }
    while (w.start != w.end && w.back(0) == _apostrophe) {
      if (cnt == 0) break;
      w.end--;
      cnt--;
    }
    return result;
  }

  void _markYsAsConsonants(ZcmWord w) {
    if (w.at(0) == 0x79) w.letters[w.start] = 0x59;
    for (var i = w.start + 1; i <= w.end; i++) {
      if (isVowel(w.letters[i - 1]) && w.letters[i] == 0x79) {
        w.letters[i] = 0x59;
      }
    }
  }

  static bool _processPrefixes(ZcmWord w) {
    if (w.startsWith('irr') &&
        w.length > 5 &&
        (w.at(3) == 0x61 || w.at(3) == 0x65)) {
      w.start += 2;
      w.type |= _T.negation;
    } else if (w.startsWith('over') && w.length > 5) {
      w.start += 4;
      w.type |= _T.prefixOver;
    } else if (w.startsWith('under') && w.length > 6) {
      w.start += 5;
      w.type |= _T.prefixUnder;
    } else if (w.startsWith('unn') && w.length > 5) {
      w.start += 2;
      w.type |= _T.negation;
    } else if (w.startsWith('non') && w.length > 5 + _b(w.at(3) == 0x2D)) {
      w.start += 2 + _b(w.at(3) == 0x2D);
      w.type |= _T.negation;
    } else {
      return false;
    }
    return true;
  }

  bool _lettersAre(ZcmWord w, int off, String s) {
    for (var i = 0; i < s.length; i++) {
      if (w.letters[off + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  bool _processSuperlatives(ZcmWord w) {
    if (w.endsWith('est') && w.length > 4) {
      final i = w.end;
      w.end -= 3;
      w.type |= _T.adjectiveSuperlative;
      if (w.back(0) == w.back(1) &&
          w.back(0) != 0x72 &&
          !(w.length >= 4 && _lettersAre(w, w.end - 3, 'sugg'))) {
        final b0 = w.back(0);
        w.end -= _b(((b0 != 0x66 && b0 != 0x6C && b0 != 0x73) ||
                (w.length > 4 &&
                    w.back(1) == 0x6C &&
                    (w.back(2) == 0x75 ||
                        w.back(3) == 0x75 ||
                        w.back(3) == 0x76))) &&
            !(w.length == 3 && w.back(1) == 0x64 && w.back(2) == 0x6F));
        if (w.length == 2 && (w.at(0) != 0x69 || w.at(1) != 0x6E)) {
          w.end = i;
          w.type &= ~_T.adjectiveSuperlative;
        }
      } else {
        switch (w.back(0)) {
          case 0x64: // d
          case 0x6B: // k
          case 0x6D: // m
          case 0x79: // y
            break;
          case 0x67: // g
            if (!(w.length > 3 &&
                (w.back(1) == 0x6E || w.back(1) == 0x72) &&
                !_lettersAre(w, w.end - 3, 'cong'))) {
              w.end = i;
              w.type &= ~_T.adjectiveSuperlative;
            } else {
              w.end += _b(w.back(2) == 0x61);
            }
          case 0x69: // i
            w.letters[w.end] = 0x79;
          case 0x6C: // l
            if (w.end == w.start + 1 || _lettersAre(w, w.end - 2, 'mo')) {
              w.end = i;
              w.type &= ~_T.adjectiveSuperlative;
            } else {
              w.end += _b(_isConsonant(w.back(1)));
            }
          case 0x6E: // n
            if (w.length < 3 ||
                _isConsonant(w.back(1)) ||
                _isConsonant(w.back(2))) {
              w.end = i;
              w.type &= ~_T.adjectiveSuperlative;
            }
          case 0x72: // r
            if (w.length > 3 && isVowel(w.back(1)) && isVowel(w.back(2))) {
              w.end += _b(w.back(2) == 0x75 &&
                  (w.back(1) == 0x61 || w.back(1) == 0x69));
            } else {
              w.end = i;
              w.type &= ~_T.adjectiveSuperlative;
            }
          case 0x73: // s
            w.end++;
          case 0x77: // w
            if (!(w.length > 2 && isVowel(w.back(1)))) {
              w.end = i;
              w.type &= ~_T.adjectiveSuperlative;
            }
          case 0x68: // h
            if (!(w.length > 2 && _isConsonant(w.back(1)))) {
              w.end = i;
              w.type &= ~_T.adjectiveSuperlative;
            }
          default:
            w.end += 3;
            w.type &= ~_T.adjectiveSuperlative;
        }
      }
    }
    return (w.type & _T.adjectiveSuperlative) != 0;
  }

  static bool _step0(ZcmWord w) {
    for (final s in _suffixesStep0) {
      if (w.endsWith(s)) {
        w.end -= s.length;
        w.type |= _T.plural;
        return true;
      }
    }
    return false;
  }

  bool _step1A(ZcmWord w) {
    if (w.endsWith('sses')) {
      w.end -= 2;
      w.type |= _T.plural;
      return true;
    }
    if (w.endsWith('ied') || w.endsWith('ies')) {
      w.type |= w.back(0) == 0x64 ? _T.pastTense : _T.plural;
      w.end -= w.length > 4 ? 2 : 1;
      return true;
    }
    if (w.endsWith('us') || w.endsWith('ss')) return false;
    if (w.back(0) == 0x73 && w.length > 2) {
      for (var i = w.start; i <= w.end - 2; i++) {
        if (isVowel(w.letters[i])) {
          w.end--;
          w.type |= _T.plural;
          return true;
        }
      }
    }
    if (w.endsWith("n't") && w.length > 4) {
      switch (w.back(3)) {
        case 0x61: // a
          if (w.back(4) == 0x63) {
            w.end -= 2; // can't -> can
          } else {
            w.changeSuffix("n't", 'll'); // shan't -> shall
          }
        case 0x69: // i
          w.changeSuffix("in't", 'm'); // ain't -> am
        case 0x6F: // o
          if (w.back(4) == 0x77) {
            w.changeSuffix("on't", 'ill'); // won't -> will
          } else {
            w.end -= 3; // don't -> do
          }
        default:
          w.end -= 3;
      }
      w.type |= _T.negation;
      return true;
    }
    if (w.endsWith('hood') && w.length > 7) {
      w.end -= 4;
      return true;
    }
    return false;
  }

  bool _step1B(ZcmWord w, int r1) {
    for (var i = 0; i < _suffixesStep1B.length; i++) {
      final suf = _suffixesStep1B[i];
      if (!w.endsWith(suf)) continue;
      if (i <= 1) {
        if (_suffixInRn(w, r1, suf)) w.end -= 1 + i * 2;
      } else {
        final j = w.end;
        w.end -= suf.length;
        if (_hasVowels(w)) {
          if (w.endsWith('at') ||
              w.endsWith('bl') ||
              w.endsWith('iz') ||
              _isShortWord(w)) {
            w.add(0x65);
          } else if (w.length > 2) {
            if (w.back(0) == w.back(1) && _isDouble(w.back(0))) {
              w.end--;
            } else if (i == 2 || i == 3) {
              _step1BPast(w);
            } else if (i >= 4) {
              _step1BIng(w);
            }
          }
        } else {
          w.end = j;
          return false;
        }
      }
      w.type |= _typesStep1B[i];
      return true;
    }
    return false;
  }

  void _step1BPast(ZcmWord w) {
    switch (w.back(0)) {
      case 0x63: // c
      case 0x73: // s
      case 0x76: // v
        w.end += _b(!(w.endsWith('ss') || w.endsWith('ias')));
      case 0x64: // d
        final b2 = w.back(2);
        w.end += _b(isVowel(w.back(1)) &&
            !(b2 == 0x61 || b2 == 0x65 || b2 == 0x69 || b2 == 0x6F));
      case 0x6B: // k
        w.end += _b(w.endsWith('uak'));
      case 0x6C: // l
        w.end += _b(_in(w.back(1), 'bcdfgkptyz') ||
            (_in(w.back(1), 'aiou') && _isConsonant(w.back(2))));
    }
  }

  void _step1BIng(ZcmWord w) {
    switch (w.back(0)) {
      case 0x64: // d
        if (isVowel(w.back(1)) &&
            w.back(2) != 0x61 &&
            w.back(2) != 0x65 &&
            w.back(2) != 0x6F) {
          w.add(0x65);
        }
      case 0x67: // g
        final b1 = w.back(1), b2 = w.back(2), b3 = w.back(3);
        if (_in(b1, 'adeilru') ||
            (b1 == 0x6E &&
                (b2 == 0x65 ||
                    (b2 == 0x75 && b3 != 0x62 && b3 != 0x64) ||
                    (b2 == 0x61 &&
                        (b3 == 0x72 || (b3 == 0x68 && w.back(4) == 0x63))) ||
                    (w.endsWith('ring') &&
                        (w.back(4) == 0x63 || w.back(4) == 0x66))))) {
          w.add(0x65);
        }
      case 0x6C: // l
        final b1 = w.back(1);
        if (!(b1 == 0x6C ||
            b1 == 0x72 ||
            b1 == 0x77 ||
            (isVowel(b1) && isVowel(w.back(2))))) {
          w.add(0x65);
        }
        if (w.endsWith('uell') && w.length > 4 && w.back(4) != 0x71) {
          w.end--;
        }
      case 0x72: // r
        final b1 = w.back(1), b2 = w.back(2), b3 = w.back(3);
        if (((b1 == 0x69 && b2 != 0x61 && b2 != 0x65 && b2 != 0x6F) ||
                (b1 == 0x61 &&
                    !(b2 == 0x65 ||
                        b2 == 0x6F ||
                        (b2 == 0x6C && b3 == 0x6C))) ||
                (b1 == 0x6F && !(b2 == 0x6F || (b2 == 0x74 && b3 != 0x73))) ||
                b1 == 0x63 ||
                b1 == 0x74) &&
            !w.endsWith('str')) {
          w.add(0x65);
        }
      case 0x74: // t
        final b2 = w.back(2);
        if (w.back(1) == 0x6F &&
            b2 != 0x67 &&
            b2 != 0x6C &&
            b2 != 0x69 &&
            b2 != 0x6F) {
          w.add(0x65);
        }
      case 0x75: // u
        if (!(w.length > 3 && isVowel(w.back(1)) && isVowel(w.back(2)))) {
          w.add(0x65);
        }
      case 0x7A: // z
        if (w.endsWith('izz') &&
            w.length > 3 &&
            (w.back(3) == 0x68 || w.back(3) == 0x75)) {
          w.end--;
        } else if (w.back(1) != 0x74 && w.back(1) != 0x7A) {
          w.add(0x65);
        }
      case 0x6B: // k
        if (w.endsWith('uak')) w.add(0x65);
      case 0x62: // b
      case 0x63: // c
      case 0x73: // s
      case 0x76: // v
        if (!((w.back(0) == 0x62 && (w.back(1) == 0x6D || w.back(1) == 0x72)) ||
            w.endsWith('ss') ||
            w.endsWith('ias') ||
            w.eq('zinc'))) {
          w.add(0x65);
        }
    }
  }

  static bool _step1C(ZcmWord w) {
    final b0 = w.back(0);
    if (w.length > 2 &&
        (b0 == 0x79 || b0 == 0x59) &&
        !_in(w.back(1), _vowels)) {
      w.letters[w.end] = 0x69;
      return true;
    }
    return false;
  }

  bool _step2(ZcmWord w, int r1) {
    for (var i = 0; i < _step2From.length; i++) {
      final s = _step2From[i];
      if (w.endsWith(s) && _suffixInRn(w, r1, s)) {
        w.changeSuffix(s, _step2To[i]);
        w.type |= _typesStep2[i];
        return true;
      }
    }
    if (w.endsWith('logi') && _suffixInRn(w, r1, 'ogi')) {
      w.end--;
      return true;
    }
    if (w.endsWith('li')) {
      if (_suffixInRn(w, r1, 'li') && _isLiEnding(w.back(2))) {
        w.end -= 2;
        w.type |= _T.adverbOfManner;
        return true;
      }
      if (w.length > 3) {
        switch (w.back(2)) {
          case 0x62: // b
            w.letters[w.end] = 0x65;
            w.type |= _T.adverbOfManner;
            return true;
          case 0x69: // i
            if (w.length > 4) {
              w.end -= 2;
              w.type |= _T.adverbOfManner;
              return true;
            }
          case 0x6C: // l
            if (w.length > 5 && (w.back(3) == 0x61 || w.back(3) == 0x75)) {
              w.end -= 2;
              w.type |= _T.adverbOfManner;
              return true;
            }
          case 0x73: // s
            w.end -= 2;
            w.type |= _T.adverbOfManner;
            return true;
          case 0x65: // e
          case 0x67: // g
          case 0x6D: // m
          case 0x6E: // n
          case 0x72: // r
          case 0x77: // w
            if (w.length > 4 + _b(w.back(2) == 0x72)) {
              w.end -= 2;
              w.type |= _T.adverbOfManner;
              return true;
            }
        }
      }
    }
    return false;
  }

  bool _step3(ZcmWord w, int r1, int r2) {
    var res = false;
    for (var i = 0; i < _step3From.length; i++) {
      final s = _step3From[i];
      if (w.endsWith(s) && _suffixInRn(w, r1, s)) {
        w.changeSuffix(s, _step3To[i]);
        w.type |= _typesStep3[i];
        res = true;
        break;
      }
    }
    if (w.endsWith('ative') && _suffixInRn(w, r2, 'ative')) {
      w.end -= 5;
      w.type |= _T.suffixIve;
      return true;
    }
    if (w.length > 5 && w.endsWith('less')) {
      w.end -= 4;
      w.type |= _T.adjectiveWithout;
      return true;
    }
    return res;
  }

  bool _step4(ZcmWord w, int r2) {
    var res = false;
    for (var i = 0; i < _suffixesStep4.length; i++) {
      final s = _suffixesStep4[i];
      if (w.endsWith(s) && _suffixInRn(w, r2, s)) {
        w.end -= s.length - _b(i > 17);
        if (!(i == 10 && w.back(0) == 0x6D)) w.type |= _typesStep4[i];
        if (i == 0 && w.endsWith('nti')) {
          w.end--;
          res = true;
          continue;
        }
        return true;
      }
    }
    return res;
  }

  bool _step5(ZcmWord w, int r1, int r2) {
    if (w.back(0) == 0x65 && !w.eq('here')) {
      if (_suffixInRn(w, r2, 'e')) {
        w.end--;
      } else if (_suffixInRn(w, r1, 'e')) {
        w.end--;
        w.end += _b(_endsInShortSyllable(w));
      } else {
        return false;
      }
      return true;
    }
    if (w.length > 1 &&
        w.back(0) == 0x6C &&
        _suffixInRn(w, r2, 'l') &&
        w.back(1) == 0x6C) {
      w.end--;
      return true;
    }
    return false;
  }

  /// Stems [w] in place (the stem hash and the type flags); true when the
  /// word looks English.
  bool stem(ZcmWord w) {
    if (w.length < 2) {
      w.calculateStemHash();
      return false;
    }
    var res = _trimApostrophes(w);
    res = _processPrefixes(w) || res;
    res = _processSuperlatives(w) || res;
    for (var i = 0; i < _exceptions1From.length; i++) {
      if (w.eq(_exceptions1From[i])) {
        if (i < 11) {
          final to = _exceptions1To[i];
          for (var k = 0; k < to.length; k++) {
            w.letters[w.start + k] = to.codeUnitAt(k);
          }
          w.end = w.start + to.length - 1;
        }
        w.calculateStemHash();
        w.type |= _typesExceptions1[i];
        w.language = _langEnglish;
        return i < 11;
      }
    }
    _markYsAsConsonants(w);
    final r1 = _getRegion1(w);
    final r2 = _getRegion(w, r1);
    res = _step0(w) || res;
    res = _step1A(w) || res;
    for (var i = 0; i < _exceptions2.length; i++) {
      if (w.eq(_exceptions2[i])) {
        w.calculateStemHash();
        w.type |= _typesExceptions2[i];
        w.language = _langEnglish;
        return res;
      }
    }
    res = _step1B(w, r1) || res;
    res = _step1C(w) || res;
    res = _step2(w, r1) || res;
    res = _step3(w, r1, r2) || res;
    res = _step4(w, r2) || res;
    res = _step5(w, r1, r2) || res;
    for (var i = w.start; i <= w.end; i++) {
      if (w.letters[i] == 0x59) w.letters[i] = 0x79;
    }
    if (w.type == 0 || w.type == _T.plural) {
      if (w.matchesAny(_maleWords)) {
        res = true;
        w.type |= _T.male;
      } else if (w.matchesAny(_femaleWords)) {
        res = true;
        w.type |= _T.female;
      }
    }
    if (!res) res = w.matchesAny(_commonWords);
    w.calculateStemHash();
    if (res) w.language = _langEnglish;
    return res;
  }
}

// TextModel::asciiGroup
const List<int> _asciiGroup = [
  0, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4, 5, 5, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, //
  5, 5, 5, 5, 5, 5, 5, 5, 5, 6, 7, 8, 17, 17, 9, 17, 10, 11, 12, 17, 17,
  13, 14, 15, 16, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 18, 19, 20, 23, 21, 22,
  23, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 24, 27, 25, 27, 26, 27, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 28, 30, 29, 30, 30
];

// Shared::update asciiGroup (the group of a partial byte).
final Uint8List _partialGroup = Uint8List.fromList(const [
  0, 10, 0, 1, 10, 10, 0, 4, 2, 3, 10, 10, 10, 10, 0, 0, 5, 4, 2, 2, 3, //
  3, 10, 10, 10, 10, 10, 10, 10, 10, 0, 0, 0, 0, 5, 5, 9, 4, 2, 2, 2, 2,
  3, 3, 3, 3, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  10, 0, 0, 0, 0, 0, 0, 0, 0, 5, 8, 8, 5, 9, 9, 6, 5, 2, 2, 2, 2, 2, 2, 2,
  8, 3, 3, 3, 3, 3, 3, 3, 8, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  10, 10, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7, 8, 8, 8,
  8, 8, 5, 5, 9, 9, 9, 9, 9, 7, 8, 5, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 8, 8, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 8, 8, 10, 10, 10,
  10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  10, 10, 10, 10, 10, 10, 10, 10
]);

/// The character group of the partial byte [c0] at [bpos] (paq8px
/// State.Text.characterGroup).
@pragma('vm:prefer-inline')
int zcmCharacterGroup(int c0, int bpos) =>
    bpos > 0 ? _partialGroup[(1 << bpos) - 2 + (c0 & ((1 << bpos) - 1))] : 0;

// Parser states (TextModel::Parse).
abstract final class _P {
  static const unknown = 0;
  static const readingWord = 1;
  static const possibleHyphenation = 2;
  static const wasAbbreviation = 3;
  static const afterComma = 4;
  static const afterQuote = 5;
  static const afterAbbreviation = 6;
  static const expectDigit = 7;
}

/// paq8px TextModel: 28 contexts with run and byte history inputs and ten
/// mixer weight set selectors (fewer with [mixerSets]).
final class TextModel implements ZcmModel, ZcmMixerContexts {
  static const int nCM = 28;
  static const int _minRecognizedWords = 4;
  static const List<int> _setSizes = [
    16 * 8, 2048, 2048, 4096, 4096, 2048, 2048, 4096, 8192, 2048 //
  ];

  final ContextMap _cm;
  final int mixerSets;
  final ZcmEnglishStemmer _stemmer = ZcmEnglishStemmer();
  final List<_Ring<ZcmWord>> _words = [
    for (var i = 0; i < _langCount; i++)
      _Ring<ZcmWord>([for (var j = 0; j < 8; j++) ZcmWord()])
  ];
  final _Ring<_Segment> _segments =
      _Ring<_Segment>([for (var j = 0; j < 4; j++) _Segment()]);
  final _Ring<_Sentence> _sentences =
      _Ring<_Sentence>([for (var j = 0; j < 4; j++) _Sentence()]);
  final _Ring<_Paragraph> _paragraphs =
      _Ring<_Paragraph>([for (var j = 0; j < 2; j++) _Paragraph()]);
  final Uint32List _wordPos = Uint32List(0x10000);
  final Uint32List _bytePos = Uint32List(256);
  late ZcmWord _cWord, _pWord;
  late _Segment _cSegment;
  late _Sentence _cSentence;
  late _Paragraph _cParagraph;
  int _state = _P.unknown, _pState = _P.unknown;
  // Lang
  int _langCountEn = 0;
  int _langMaskEn = 0;
  int _langId = _langUnknown, _langPId = _langUnknown;
  // Info
  final Int64List _numbers = Int64List(2);
  final Int32List _numHashes = Int32List(2);
  final Int32List _numLength = Int32List(2);
  int _numMask = 0, _numDiff = 0;
  int _lastUpper = 0, _maskUpper = 0, _lastLetter = 0, _lastDigit = 0;
  int _lastPunctuation = 0, _lastNewLine = 0, _prevNewLine = 0;
  int _wordGap = 0, _spaces = 0, _commas = 0;
  int _quoteLength = 0, _maskPunctuation = 0, _nestHash = 0, _lastNest = 0;
  final Int32List _masks = Int32List(5);
  final Int32List _wordLength = Int32List(2);
  int _utf8Remaining = 0;
  int _firstLetter = 0, _firstChar = 0;
  final ZcmWord _topicDescriptor = ZcmWord();
  int _parseCtx = 0;
  int _order = 0;

  final Int8List _slot = Int8List(nCM);

  TextModel(int bytes, {this.mixerSets = 10, List<int>? contexts})
      : _cm = ContextMap(bytes, contexts == null ? nCM : contexts.length,
            rich: false, bh: true) {
    if (contexts == null) {
      for (var i = 0; i < nCM; i++) {
        _slot[i] = i;
      }
    } else {
      _slot.fillRange(0, nCM, -1);
      for (var i = 0; i < contexts.length; i++) {
        _slot[contexts[i]] = i;
      }
    }
    _cWord = _words[_langId].at(0);
    _pWord = _words[_langId].at(1);
    _cSegment = _segments.at(0);
    _cSentence = _sentences.at(0);
    _cParagraph = _paragraphs.at(0);
  }

  @override
  int get inputs => _cm.nCtx * _cm.inputsPerContext;

  @override
  List<int> get mixerContextSizes => _setSizes.sublist(0, mixerSets);

  /// Contexts with statistics (0 to 15), for the SSE stage.
  int get order => _order;

  /// The low bits of the word shape mask, for the SSE stage.
  int get mask => _masks[1] & 0xFF;

  /// The first letter of the current word, for the SSE stage.
  int get firstLetter => _firstLetter;

  _Segment _nextSegment() {
    _segments.index++;
    final s = _segments.at(0);
    s.clear();
    return s;
  }

  _Sentence _nextSentence() {
    _sentences.index++;
    final s = _sentences.at(0);
    s.clear();
    return s;
  }

  _Paragraph _nextParagraph() {
    _paragraphs.index++;
    final s = _paragraphs.at(0);
    s.clear();
    return s;
  }

  // TextModel::update
  void _update(ZcmState st) {
    _lastUpper = _lastUpper + 1 < 0xFF ? _lastUpper + 1 : 0xFF;
    _maskUpper = (_maskUpper << 1) & 0xFFFFFFFF;
    _lastLetter = _lastLetter + 1 < 0x1F ? _lastLetter + 1 : 0x1F;
    _lastDigit = _lastDigit + 1 < 0xFF ? _lastDigit + 1 : 0xFF;
    _lastPunctuation =
        _lastPunctuation + 1 < 0x3F ? _lastPunctuation + 1 : 0x3F;
    _lastNewLine = (_lastNewLine + 1) & 0xFFFFFFFF;
    _prevNewLine = (_prevNewLine + 1) & 0xFFFFFFFF;
    _lastNest = (_lastNest + 1) & 0xFFFFFFFF;
    _spaces = (_spaces << 1) & 0xFFFFFFFF;
    final masks = _masks;
    masks[0] <<= 2;
    masks[1] <<= 2;
    masks[2] <<= 4;
    masks[3] <<= 3;
    _pState = _state;

    var c = st.c4 & 255;
    final lc = _lower(c);
    final g = c < 0x80 ? _asciiGroup[c] : 31;
    if (g > 4 || g != (masks[4] & 0x1F)) {
      masks[4] = (masks[4] << 5) | g;
    }
    final pos = st.pos;
    _bytePos[c] = pos;
    if (c != lc) {
      c = lc;
      _lastUpper = 0;
      _maskUpper |= 1;
    }
    final pC = st.back(2);
    _state = _P.unknown;
    _parseCtx = hash4(
        _state,
        _pWord.hash0,
        c,
        hash2((_ilog2(_lastNewLine) + 1) * _b(_lastNewLine * 3 > _prevNewLine),
            masks[1] & 0xFC));

    if ((c >= 0x61 && c <= 0x7A) || c == _apostrophe || c == 0x2D || c > 0x7F) {
      if (_wordLength[0] == 0) {
        // Hyphenation with "+" (book1 of the Calgary corpus).
        if (pC == _newLine &&
            ((_lastLetter == 3 && st.back(3) == 0x2B) ||
                (_lastLetter == 4 &&
                    st.back(3) == _cr &&
                    st.back(4) == 0x2B))) {
          _wordLength[0] = _wordLength[1];
          for (var i = _langUnknown; i < _langCount; i++) {
            _words[i].index--;
          }
          _cWord = _pWord;
          _pWord = _words[_langPId].at(1);
          _cWord.reset();
          for (var i = 0; i < _wordLength[0]; i++) {
            _cWord.add(st.back(_wordLength[0] - i + _lastLetter));
          }
          _wordLength[1] = _pWord.length;
          _cSegment.wordCount--;
          _cSentence.wordCount--;
        } else {
          _wordGap = _lastLetter;
          _firstLetter = c;
        }
      }
      _lastLetter = 0;
      _wordLength[0]++;
      masks[0] += _langId != _langUnknown ? 1 + _b(_stemmer.isVowel(c)) : 1;
      masks[1]++;
      masks[3] += masks[0] & 3;
      if (c == _apostrophe) {
        masks[2] += 12;
        if (_wordLength[0] == 1) {
          if (_quoteLength == 0 && pC == _space) {
            _quoteLength = 1;
          } else if (_quoteLength > 0 && _lastPunctuation == 1) {
            _quoteLength = 0;
            _state = _P.afterQuote;
            _parseCtx = hash2(_state, pC);
          }
        }
      }
      _cWord.add(c);
      _cWord.calculateWordHash();
      _state = _P.readingWord;
      _parseCtx = hash2(_state, _cWord.hash0);
    } else {
      if (_cWord.length > 0) _endWord(pos);
      _punctuation(st, c, pC);
      _digits(st, c);
    }
    if (_lastNewLine == 1) {
      _firstChar = _langId != _langUnknown ? c : (c < 96 ? c : 96);
    }
    if (_lastNest > 512) _nestHash = 0;
    var leadingBitsSet = 0;
    while (leadingBitsSet < 8 && ((c >> (7 - leadingBitsSet)) & 1) != 0) {
      leadingBitsSet++;
    }
    if (_utf8Remaining > 0 && leadingBitsSet == 1) {
      _utf8Remaining--;
    } else {
      _utf8Remaining = leadingBitsSet != 1
          ? ((c != 0xC0 && c != 0xC1 && c < 0xF5)
              ? leadingBitsSet - _b(leadingBitsSet > 0)
              : -1)
          : 0;
    }
    final bp = _bytePos;
    final comma = bp[0x2C];
    _maskPunctuation = _b(comma > bp[0x2E]) |
        _b(comma > bp[0x21]) << 1 |
        _b(comma > bp[0x3F]) << 2 |
        _b(comma > bp[0x3A]) << 3 |
        _b(comma > bp[0x3B]) << 4;
  }

  // The end of a word: stemming, language detection, the words of the
  // segment and sentence.
  void _endWord(int pos) {
    final cWord = _cWord;
    if (_langId != _langUnknown) _words[_langUnknown].at(0).copyFrom(cWord);
    // Only English is detected (paq8px also has French and German).
    _langCountEn -= (_langMaskEn >> 63) & 1;
    _langMaskEn <<= 1;
    if (_langId != _langEnglish) _words[_langEnglish].at(0).copyFrom(cWord);
    if (_stemmer.stem(_words[_langEnglish].at(0))) {
      _langCountEn++;
      _langMaskEn |= 1;
    }
    _langId = _langUnknown;
    var best = _minRecognizedWords;
    if (_langCountEn >= best) {
      best = _langCountEn + _b(_langPId == _langEnglish);
      _langId = _langEnglish;
    }
    _words[_langEnglish].index++;
    _words[_langUnknown].index++;
    _langPId = _langId;
    _pWord = _words[_langId].at(1);
    _cWord = _words[_langId].at(0);
    _cWord.reset();
    final pWord = _pWord;
    _wordPos[pWord.hash0 & 0xFFFF] = pos;
    if (_cSegment.wordCount == 0) _cSegment.firstWord.copyFrom(pWord);
    _cSegment.wordCount++;
    final sen = _cSentence;
    if (sen.wordCount == 0) sen.firstWord.copyFrom(pWord);
    sen.wordCount++;
    _wordLength[1] = _wordLength[0];
    _wordLength[0] = 0;
    _quoteLength += _b(_quoteLength > 0);
    if (_quoteLength > 0x1F) _quoteLength = 0;
    sen.verbIndex++;
    sen.nounIndex++;
    sen.capitalIndex++;
    if ((pWord.type & _T.verb) != 0) {
      sen.verbIndex = 0;
      sen.lastVerb.copyFrom(pWord);
    }
    if ((pWord.type & _T.noun) != 0) {
      sen.nounIndex = 0;
      sen.lastNoun.copyFrom(pWord);
    }
    if (sen.wordCount > 1 && _lastUpper < _wordLength[1]) {
      sen.capitalIndex = 0;
      sen.lastCapital.copyFrom(pWord);
    }
  }

  static const List<String> _abbreviations = [
    'mr',
    'mrs',
    'ms',
    'dr',
    'st',
    'jr'
  ];

  void _punctuation(ZcmState st, int c, int pC) {
    final masks = _masks;
    // The switch of TextModel::update with its fall throughs.
    var sentenceEnd = false;
    var segmentEnd = false;
    if (c == 0x2E) {
      if (_langId != _langUnknown &&
          _lastUpper == _wordLength[1] &&
          _pWord.matchesAny(_abbreviations)) {
        _state = _P.wasAbbreviation;
        _parseCtx = hash2(_state, _pWord.hash0);
        return;
      }
      sentenceEnd = true;
    } else if (c == 0x3F || c == 0x21) {
      sentenceEnd = true;
    } else if (c == 0x2C || c == 0x3B || c == 0x3A) {
      segmentEnd = true;
    }
    if (sentenceEnd) {
      final sen = _cSentence;
      sen.type = c == 0x2E ? 0 : (c == 0x3F ? 1 : 2);
      sen.segmentCount++;
      final par = _cParagraph;
      par.sentenceCount++;
      par.typeCount[sen.type]++;
      par.typeMask = ((par.typeMask << 2) | sen.type) & 0xFFFFFFFF;
      _cSentence = _nextSentence();
      masks[3] += 3;
    }
    if (sentenceEnd || segmentEnd) {
      if (c == 0x2C) {
        _commas++;
        _state = _P.afterComma;
        _parseCtx = hash4(
            _state,
            _ilog2(_quoteLength + 1),
            _ilog2(_lastNewLine),
            _b(_lastUpper < _lastLetter + _wordLength[1]));
      } else if (c == 0x3A) {
        _topicDescriptor.copyFrom(_pWord);
      }
      if (!sentenceEnd) {
        _cSentence.segmentCount++;
        masks[3] += 4;
      }
      _lastPunctuation = 0;
      masks[0] += 3;
      masks[1] += 2;
      masks[2] += 15;
      _cSegment = _nextSegment();
      return;
    }
    var space = false;
    switch (c) {
      case _newLine:
        _prevNewLine = _lastNewLine;
        _lastNewLine = 0;
        _commas = 0;
        if (_prevNewLine == 1 || (_prevNewLine == 2 && pC == _cr)) {
          _cParagraph = _nextParagraph();
        } else if ((_lastLetter == 2 && pC == 0x2B) ||
            (_lastLetter == 3 && pC == _cr && st.back(3) == 0x2B)) {
          _parseCtx = hash2(_P.readingWord, _pWord.hash0);
          _state = _P.possibleHyphenation;
        }
        space = true;
      case _tab:
      case _cr:
      case _space:
        space = true;
      case 0x28: // (
        masks[2] += 1;
        masks[3] += 6;
        _nestHash += 31;
        _lastNest = 0;
      case 0x5B: // [
        masks[2] += 2;
        _nestHash += 11;
        _lastNest = 0;
      case 0x7B: // {
        masks[2] += 3;
        _nestHash += 17;
        _lastNest = 0;
      case 0x3C: // <
        masks[2] += 4;
        _nestHash += 23;
        _lastNest = 0;
      case 0xAB:
        masks[2] += 5;
      case 0x29: // )
        masks[2] += 6;
        _nestHash -= 31;
        _lastNest = 0;
      case 0x5D: // ]
        masks[2] += 7;
        _nestHash -= 11;
        _lastNest = 0;
      case 0x7D: // }
        masks[2] += 8;
        _nestHash -= 17;
        _lastNest = 0;
      case 0x3E: // >
        masks[2] += 9;
        _nestHash -= 23;
        _lastNest = 0;
      case 0xBB:
        masks[2] += 10;
      case _quote:
        masks[2] += 11;
        if (_quoteLength == 0) {
          _quoteLength = 1;
        } else {
          _quoteLength = 0;
          _state = _P.afterQuote;
          _parseCtx = hash2(_state, 0x100 | pC);
        }
      case 0x2F:
      case 0x2D:
      case 0x2B:
      case 0x2A:
      case 0x3D:
      case 0x25:
        masks[2] += 13;
      case 0x5C:
      case 0x7C:
      case 0x5F:
      case 0x40:
      case 0x26:
      case 0x5E:
        masks[2] += 14;
    }
    _nestHash &= 0xFFFFFFFF;
    if (space) {
      _spaces |= 1;
      masks[1] += 3;
      masks[3] += 5;
      if (c == _space && _pState == _P.wasAbbreviation) {
        _state = _P.afterAbbreviation;
        _parseCtx = hash2(_state, _pWord.hash0);
      }
    }
  }

  void _digits(ZcmState st, int c) {
    final nums = _numbers;
    final nl = _numLength;
    if (c >= 0x30 && c <= 0x39) {
      nums[0] = nums[0] * 10 + (c & 0x0F);
      nl[0] = nl[0] + 1 < 19 ? nl[0] + 1 : 19;
      _numHashes[0] = _comb(_numHashes[0], c);
      if (nl[0] < nl[1] &&
          (_pState == _P.expectDigit || ((_numDiff & 3) == 0 && nl[0] <= 1))) {
        final expectedNum = nums[1] + (_numMask & 3) - 2;
        var placeDivisor = 1;
        for (var i = 0; i < nl[1] - nl[0]; i++) {
          placeDivisor *= 10;
        }
        if (_udiv(expectedNum, placeDivisor) == nums[0]) {
          _state = _P.expectDigit;
        }
      } else {
        final d = st.back(nl[0] + 2);
        if (nl[0] < 3 && st.back(nl[0] + 1) == 0x2C && d >= 0x30 && d <= 0x39) {
          _state = _P.expectDigit;
        }
      }
      _lastDigit = 0;
      _masks[3] += 7;
    } else if (nums[0] != 0) {
      final a = nums[0], b = nums[1];
      final ge = _ucmp(a, b) >= 0, gt = _ucmp(a, b) > 0;
      _numMask = ((_numMask << 2) | (1 + _b(ge) + _b(gt))) & 0xFFFFFFFF;
      var diff = (a - b).toSigned(32);
      if (diff < 0) diff = -diff;
      final ld = _ilog2(diff);
      _numDiff = ((_numDiff << 2) | (ld < 3 ? ld : 3)) & 0xFFFFFFFF;
      nums[1] = a;
      nums[0] = 0;
      _numHashes[1] = _numHashes[0];
      _numHashes[0] = 0;
      nl[1] = nl[0];
      nl[0] = 0;
      _cSegment.numCount++;
      _cSentence.numCount++;
    }
  }

  // Unsigned 64-bit comparison and division.
  static int _ucmp(int a, int b) {
    final x = a ^ 0x8000000000000000, y = b ^ 0x8000000000000000;
    return x < y ? -1 : (x > y ? 1 : 0);
  }

  static int _udiv(int a, int b) {
    if (a >= 0) return a ~/ b;
    // a >= 2^63 as unsigned.
    final q = ((a >>> 1) ~/ b) << 1;
    final r = a - q * b;
    return _ucmp(r, b) >= 0 ? q + 1 : q;
  }

  // TextModel::setContexts
  void _setContexts(ZcmState st) {
    final c = st.c4 & 255;
    final lc = _lower(c);
    final masks = _masks;
    final m2 = masks[2] & 0x0F;
    final column = _lastNewLine < 0xFF ? _lastNewLine : 0xFF;
    final cWord = _cWord, pWord = _pWord;
    final w = _state == _P.readingWord ? cWord.hash0 : pWord.hash0;
    final cWordHash0 = cWord.hash0;
    final pWordHash0 = pWord.hash0;
    final pWordHash1 = pWord.hash1;
    final wl0 = _wordLength[0], wl1 = _wordLength[1];
    final words = _words[_langPId];
    final seg = _cSegment;
    final sen = _cSentence;
    var i = _state * 64;
    var k = 0;
    _put(k++, _parseCtx);
    _put(
        k++,
        hash4(++i, cWordHash0, pWordHash0,
            _b(_lastUpper < wl0) | _b(_lastDigit < wl0 + _wordGap) << 1));
    final nl = _ilog2(_numbers[0] & 0xFFFFFFFF);
    _put(
        k++,
        hash4(
            hash2(++i, cWordHash0),
            words.at(2).hash0,
            nl < 10 ? nl : 10,
            _b(_lastUpper < _lastLetter + wl1) |
                _b(_lastLetter > 3) << 1 |
                _b(_lastLetter > 0 && wl1 < 3) << 2));
    _put(
        k++,
        hash4(
            hash2(++i, cWordHash0),
            masks[1] & 0x3FF,
            words.at(3).hash1,
            _b(_lastDigit < wl0 + _wordGap) |
                _b(_lastUpper < _lastLetter + wl1) << 1 |
                (_spaces & 0x7F) << 2));
    _put(k++, hash3(++i, cWordHash0, pWordHash1));
    _put(k++, hash4(++i, cWordHash0, pWordHash1, words.at(2).hash1));
    _put(k++, hash4(++i, w, words.at(2).hash0, words.at(3).hash0));
    _put(
        k++,
        hash4(++i, cWordHash0, c,
            sen.verbIndex < sen.wordCount ? sen.lastVerb.hash0 : 0));
    _put(k++, hash4(hash2(++i, pWordHash1), masks[1] & 0xFC, lc, _wordGap));
    final swc = _ilog2(seg.wordCount + 1);
    _put(
        k++,
        hash4(hash2(++i, _lastLetter == 0 ? cWordHash0 : pWordHash0), c,
            seg.firstWord.hash1, swc < 3 ? swc : 3));
    _put(k++, hash4(++i, cWordHash0, c, _segments.at(1).firstWord.hash1));
    _put(
        k++,
        hash4(
            hash2(++i, lc > 31 ? lc : 31),
            masks[1] & 0xFFC,
            (_spaces & 0xFE) | _b(_lastPunctuation < _lastLetter),
            (_maskUpper & 0xFF) | ((0x100 | _firstLetter) * _b(wl0 > 1)) << 8));
    final lu = _ilog2(_lastUpper + 1);
    _put(
        k++, hash4(++i, column, lu < 7 ? lu : 7, _ilog2(_lastPunctuation + 1)));
    _put(
        k++,
        hash2(
            ++i,
            (column & 0xF8) |
                (masks[1] & 3) |
                _b(_prevNewLine - _lastNewLine > 63) << 2 |
                (_lastLetter < 3 ? _lastLetter : 3) << 8 |
                _firstChar << 10 |
                _b(_commas > 4) << 18 |
                _b(m2 >= 1 && m2 <= 5) << 19 |
                _b(m2 >= 6 && m2 <= 10) << 20 |
                _b(m2 == 11 || m2 == 12) << 21 |
                _b(_lastUpper < column) << 22 |
                _b(_lastDigit < column) << 23 |
                _b(column < _prevNewLine - _lastNewLine) << 24));
    final lp = _lastPunctuation;
    _put(
        k++,
        hash4(
            hash2(++i, (2 * column) ~/ 3),
            (lp < 13 ? lp : 13) +
                _b(lp > 16) +
                _b(lp > 32) +
                _maskPunctuation * 16,
            _ilog2(_lastUpper + 1),
            hash2(_ilog2(_prevNewLine - _lastNewLine),
                _b((masks[1] & 3) == 0) | _b(m2 < 6) << 1 | _b(m2 < 11) << 2)));
    _put(k++, hash3(++i, column >> 1, _spaces & 0x0F));
    final wlq = wl0 < 8 ? ((wl0 > 3 ? wl0 : 3) - 2) : 0;
    _put(
        k++,
        hash4(
            hash2(++i, masks[3] & 0x3F),
            hash2(wlq < 3 ? wlq : 3, _firstLetter * _b(wl0 < 5)),
            w,
            _b(c == st.back(2)) |
                _b(masks[2] != 0) << 1 |
                _b(lp < wl0 + _wordGap) << 2 |
                _b(_lastUpper < wl0) << 3 |
                _b(_lastDigit < wl0 + _wordGap) << 4 |
                _b(lp < 2 + wl0 + _wordGap + wl1) << 5));
    _put(k++, hash4(++i, w, c, _numHashes[1]));
    final pos = st.pos;
    _put(
        k++,
        hash4(++i, w, c,
            zcmLlog((pos - _wordPos[w & 0xFFFF]) & 0xFFFFFFFF) >> 1));
    _put(k++, hash4(++i, w, c, _topicDescriptor.hash0));
    _put(k++, hash4(++i, _numLength[0], c, _topicDescriptor.hash0));
    _put(
        k++,
        hash4(++i, _lastLetter > 0 ? c : 0x100, masks[1] & 0xFFC,
            _nestHash & 0x7FF));
    _put(
        k++,
        hash4(
            hash2(++i, w),
            c,
            masks[3] & 0x1FF,
            _b(sen.verbIndex == 0 && sen.lastVerb.length > 0) << 6 |
                _b(wl1 > 3) << 5 |
                _b(seg.wordCount == 0) << 4 |
                _b(sen.segmentCount == 0 && sen.wordCount < 2) << 3 |
                _b(lp >= _lastLetter + wl1 + _wordGap) << 2 |
                _b(_lastUpper < _lastLetter + wl1) << 1 |
                _b(_lastUpper < wl0 + _wordGap + wl1)));
    _put(
        k++,
        hash4(
            hash2(++i, c),
            pWordHash1,
            _firstLetter * _b(wl0 < 6),
            _b(lp < wl0 + _wordGap) << 1 |
                _b(lp >= _lastLetter + wl1 + _wordGap)));
    final ww = words.at(1 + _b(wl0 == 0));
    _put(
        k++,
        hash4(hash2(++i, w), c, ww.letters[ww.start],
            _firstLetter * _b(wl0 < 7)));
    _put(k++, hash4(++i, column, _spaces & 7, _nestHash & 0x7FF));
    _put(
        k++,
        hash4(
            ++i,
            cWordHash0,
            _b(_lastUpper < column) | _b(_lastUpper < wl0) << 1,
            wl0 < 5 ? wl0 : 5));
    _put(
        k++,
        hash4(hash2(++i, _langId), w, 0,
            _b(_lastUpper < wl0) | _b(seg.wordCount == 0) << 1));
    assert(k == nCM);
  }

  @pragma('vm:prefer-inline')
  void _put(int k, int h) {
    final j = _slot[k];
    if (j >= 0) _cm.set(j, h);
  }

  @override
  void mix(ZcmState s, Mixer m) {
    if (s.bpos == 0) {
      _update(s);
      _setContexts(s);
    }
    _cm.mix(m, s.y, s.bpos, s.c0, s.c4 & 255);
    final o = _cm.hits - (_cm.nCtx - 15);
    _order = o < 0 ? 0 : o;
  }

  @override
  void setMixerContexts(ZcmState s, Mixer m) {
    final bpos = s.bpos;
    final c0 = s.c0;
    final c1 = s.c4 & 255;
    final masks = _masks;
    final wl0 = _wordLength[0], wl1 = _wordLength[1];
    final lu = _lastUpper, ll = _lastLetter, lp = _lastPunctuation;
    final g = zcmCharacterGroup(c0, bpos);
    final n = mixerSets;
    if (n >= 1) m.set(_order << 3 | bpos);
    if (n >= 2) {
      m.set(hash3(_langId != _langUnknown ? 1 + _b(_stemmer.isVowel(c1)) : 0,
              masks[1] & 0xFF, c0) >>
          21);
    }
    if (n >= 3) {
      final il = _ilog2(wl0 + 1);
      m.set(hash3(
              il,
              c0,
              _b(_lastDigit < wl0 + _wordGap) |
                  _b(lu < ll + wl1) << 1 |
                  _b(lp < wl0 + _wordGap) << 2 |
                  _b(lu < wl0) << 3) >>
          21);
    }
    if (n >= 4) {
      m.set(hash4(masks[1] & 0x3FF, g, _b(lu < wl0), _b(lu < ll + wl1)) >> 20);
    }
    if (n >= 5) {
      m.set(hash3(
              _spaces & 0x1FF,
              g,
              _b(lu < wl0) |
                  _b(lu < ll + wl1) << 1 |
                  _b(lp < ll) << 2 |
                  _b(lp < wl0 + _wordGap) << 3 |
                  _b(lp < ll + wl1 + _wordGap) << 4) >>
          20);
    }
    if (n >= 6) {
      m.set(hash3(_firstLetter * _b(wl0 < 4), wl0 < 6 ? wl0 : 6, c0) >> 21);
    }
    if (n >= 7) {
      final p = _pWord;
      m.set(hash4(p.at(0), p.back(0), wl0 < 4 ? wl0 : 4, _b(lp < ll)) >> 21);
    }
    if (n >= 8) {
      m.set(hash4(
              wl0 < 4 ? wl0 : 4,
              g,
              _b(lu < wl0),
              _nestHash > 0
                  ? _nestHash & 0xFF
                  : 0x100 | (_firstLetter * _b(wl0 > 0 && wl0 < 4))) >>
          20);
    }
    if (n >= 9) {
      m.set(hash3(g, masks[4] & 0x1F, (masks[4] >> 5) & 0x1F) >> 19);
    }
    if (n >= 10) m.set(hash4(g, 0, _langId, _state) >> 21);
  }
}
