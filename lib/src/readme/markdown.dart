// A small markdown parser for the README of an archive (docs/readme.md):
// the CommonMark blocks and inlines that READMEs use, plus the GitHub
// extensions (tables, task lists, strikethrough, bare links). The result
// is a tree of plain objects (no rendering here), so it can be built in a
// background isolate and sent back.
//
// Raw HTML is never interpreted: tags are dropped, except <img>, which
// becomes an [MdImage] (and so goes through the same link policy as a
// markdown image, see readme_links.dart), and <br>, which becomes a line
// break. Nothing here reads files or the network.

/// A parsed markdown document.
class MdDocument {
  final List<MdBlock> blocks;

  /// True when the text was cut at the size limit.
  final bool truncated;
  const MdDocument(this.blocks, {this.truncated = false});
}

// ---------------------------------------------------------------------------
// Blocks

sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  /// 1 to 6.
  final int level;
  final List<MdInline> text;

  /// The anchor of the heading as GitHub makes it ("my-title", "my-title-1"
  /// for the second one with the same text).
  final String slug;
  const MdHeading(this.level, this.text, this.slug);
}

class MdParagraph extends MdBlock {
  final List<MdInline> text;
  const MdParagraph(this.text);
}

class MdCodeBlock extends MdBlock {
  /// The info string of a fenced block ("dart"), null when there is none.
  final String? info;
  final String code;
  const MdCodeBlock(this.info, this.code);
}

class MdQuote extends MdBlock {
  final List<MdBlock> blocks;
  const MdQuote(this.blocks);
}

class MdList extends MdBlock {
  final bool ordered;

  /// The number of the first item of an ordered list.
  final int start;

  /// A tight list shows its paragraphs without the space between them.
  final bool tight;
  final List<MdListItem> items;
  const MdList(this.ordered, this.start, this.tight, this.items);
}

class MdListItem {
  /// For a task list item ("- [x] done"): whether it is checked. null for
  /// a normal item.
  final bool? checked;
  final List<MdBlock> blocks;
  const MdListItem(this.checked, this.blocks);
}

class MdRule extends MdBlock {
  const MdRule();
}

enum MdAlign { none, left, center, right }

class MdTable extends MdBlock {
  final List<MdAlign> aligns;
  final List<List<MdInline>> header;

  /// Every row has as many cells as [header].
  final List<List<List<MdInline>>> rows;
  const MdTable(this.aligns, this.header, this.rows);
}

// ---------------------------------------------------------------------------
// Inlines

sealed class MdInline {
  const MdInline();
}

class MdText extends MdInline {
  final String text;
  const MdText(this.text);
}

class MdCode extends MdInline {
  final String code;
  const MdCode(this.code);
}

class MdEmphasis extends MdInline {
  final List<MdInline> children;
  const MdEmphasis(this.children);
}

class MdStrong extends MdInline {
  final List<MdInline> children;
  const MdStrong(this.children);
}

class MdStrike extends MdInline {
  final List<MdInline> children;
  const MdStrike(this.children);
}

class MdLink extends MdInline {
  /// The destination as written (see readme_links.dart for what it may
  /// point to).
  final String url;
  final String? title;
  final List<MdInline> children;
  const MdLink(this.url, this.title, this.children);
}

class MdImage extends MdInline {
  /// The source as written; only a path inside the archive is shown (see
  /// readme_links.dart).
  final String url;
  final String? title;
  final String alt;

  /// The width and height of an HTML <img>, when given in pixels.
  final int? width;
  final int? height;
  const MdImage(this.url, this.title, this.alt, {this.width, this.height});
}

/// A line break inside a paragraph: [hard] for "\" or two spaces at the
/// end of the line and <br>, a soft one is shown as a space.
class MdBreak extends MdInline {
  final bool hard;
  const MdBreak(this.hard);
}

/// The plain text of [inlines] (for image descriptions and anchors).
String mdPlainText(List<MdInline> inlines) {
  final b = StringBuffer();
  void walk(List<MdInline> l) {
    for (final i in l) {
      switch (i) {
        case MdText(:final text):
          b.write(text);
        case MdCode(:final code):
          b.write(code);
        case MdEmphasis(:final children):
        case MdStrong(:final children):
        case MdStrike(:final children):
        case MdLink(:final children):
          walk(children);
        case MdImage(:final alt):
          b.write(alt);
        case MdBreak():
          b.write(' ');
      }
    }
  }

  walk(inlines);
  return b.toString();
}

/// The default size limit of [parseMarkdown], in characters.
const int mdMaxChars = 1 << 20;

/// Parses [text] (at most [maxChars] characters are read; the document
/// is then marked truncated).
MdDocument parseMarkdown(String text, {int maxChars = mdMaxChars}) {
  var truncated = false;
  if (text.length > maxChars) {
    final cut = text.lastIndexOf('\n', maxChars);
    text = text.substring(0, cut > 0 ? cut : maxChars);
    truncated = true;
  }
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final lines = _splitLines(text);
  final p = _BlockParser();
  final raw = p.parse(lines);
  final b = _Builder(p.refs);
  return MdDocument(b.blocks(raw), truncated: truncated);
}

/// A document showing [text] as it is (a README that is not markdown).
MdDocument plainTextDocument(String text, {int maxChars = mdMaxChars}) {
  var truncated = false;
  if (text.length > maxChars) {
    text = text.substring(0, maxChars);
    truncated = true;
  }
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return MdDocument([MdCodeBlock(null, text.replaceAll('\r\n', '\n'))],
      truncated: truncated);
}

// ---------------------------------------------------------------------------
// Lines

/// The lines of [text], with the tabs of their indentation turned into
/// spaces (tab stops of 4).
List<String> _splitLines(String text) {
  final out = <String>[];
  for (var l in text.split('\n')) {
    if (l.endsWith('\r')) l = l.substring(0, l.length - 1);
    if (l.contains('\t')) {
      final b = StringBuffer();
      var col = 0;
      var i = 0;
      for (; i < l.length; i++) {
        final c = l.codeUnitAt(i);
        if (c == 0x20) {
          b.writeCharCode(c);
          col++;
        } else if (c == 0x09) {
          final n = 4 - (col & 3);
          for (var k = 0; k < n; k++) {
            b.writeCharCode(0x20);
          }
          col += n;
        } else {
          break;
        }
      }
      b.write(l.substring(i));
      l = b.toString();
    }
    out.add(l);
  }
  return out;
}

int _indent(String l) {
  var i = 0;
  while (i < l.length && l.codeUnitAt(i) == 0x20) {
    i++;
  }
  return i;
}

bool _isBlank(String l) => l.trim().isEmpty;

/// [l] without up to [n] leading spaces.
String _dedent(String l, int n) {
  final i = _indent(l);
  return l.substring(i < n ? i : n);
}

final _atx = RegExp(r'^(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$');
final _fenceOpen = RegExp(r'^(`{3,}|~{3,})[ \t]*(.*)$');
final _rule = RegExp(r'^(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$');
final _bullet = RegExp(r'^([-+*])( +|$)');
final _ordered = RegExp(r'^(\d{1,9})([.)])( +|$)');
final _setext1 = RegExp(r'^=+[ \t]*$');
final _setext2 = RegExp(r'^-+[ \t]*$');
final _tableDelim =
    RegExp(r'^\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$');
final _refDef = RegExp(
    r'''^\[((?:[^\]\\]|\\.)+)\]:[ \t]*(<[^>\n]*>|\S+)(?:[ \t]+("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^)\\]|\\.)*\)))?[ \t]*$''');
final _task = RegExp(r'^\[([ xX])\](?:[ \t]+|$)');

// ---------------------------------------------------------------------------
// Blocks, first pass: the structure with the raw text of the inlines

sealed class _Raw {}

class _RHeading extends _Raw {
  final int level;
  final String text;
  _RHeading(this.level, this.text);
}

class _RPara extends _Raw {
  final String text;
  _RPara(this.text);
}

class _RCode extends _Raw {
  final String? info;
  final String code;
  _RCode(this.info, this.code);
}

class _RQuote extends _Raw {
  final List<_Raw> blocks;
  _RQuote(this.blocks);
}

class _RList extends _Raw {
  final bool ordered;
  final int start;
  bool tight = true;
  final List<(bool?, List<_Raw>)> items = [];
  _RList(this.ordered, this.start);
}

class _RRule extends _Raw {}

class _RTable extends _Raw {
  final List<MdAlign> aligns;
  final List<String> header;
  final List<List<String>> rows;
  _RTable(this.aligns, this.header, this.rows);
}

class _Ref {
  final String url;
  final String? title;
  const _Ref(this.url, this.title);
}

/// A list item marker: (ordered, bullet char or delimiter, number, the
/// width of the marker and its spaces, the item text is empty).
typedef _Marker = (bool, String, int, int, bool);

class _BlockParser {
  final Map<String, _Ref> refs = {};
  int _depth = 0;

  List<_Raw> parse(List<String> lines) {
    // deep nesting of quotes and lists: the rest is text
    if (_depth > 32) {
      return [_RCode(null, lines.join('\n'))];
    }
    _depth++;
    try {
      return _parse(lines);
    } finally {
      _depth--;
    }
  }

  List<_Raw> _parse(List<String> lines) {
    final out = <_Raw>[];
    final n = lines.length;
    var i = 0;
    while (i < n) {
      final line = lines[i];
      if (_isBlank(line)) {
        i++;
        continue;
      }
      final ind = _indent(line);
      if (ind >= 4) {
        // indented code
        final code = <String>[];
        while (i < n && (_isBlank(lines[i]) || _indent(lines[i]) >= 4)) {
          code.add(_isBlank(lines[i]) ? '' : lines[i].substring(4));
          i++;
        }
        while (code.isNotEmpty && code.last.isEmpty) {
          code.removeLast();
        }
        out.add(_RCode(null, code.join('\n')));
        continue;
      }
      final t = line.substring(ind);

      final fence = _fenceOpen.firstMatch(t);
      if (fence != null &&
          !(fence.group(1)![0] == '`' && fence.group(2)!.contains('`'))) {
        final f = fence.group(1)!;
        final close =
            RegExp('^ {0,3}${RegExp.escape(f[0])}{${f.length},}[ \t]*\$');
        final code = <String>[];
        i++;
        while (i < n && !close.hasMatch(lines[i])) {
          code.add(_dedent(lines[i], ind));
          i++;
        }
        if (i < n) i++; // the closing fence
        final info = fence.group(2)!.trim();
        out.add(_RCode(info.isEmpty ? null : _unescape(info.split(' ').first),
            code.join('\n')));
        continue;
      }

      final atx = _atx.firstMatch(t);
      if (atx != null) {
        out.add(_RHeading(atx.group(1)!.length, (atx.group(2) ?? '').trim()));
        i++;
        continue;
      }

      if (_rule.hasMatch(t)) {
        out.add(_RRule());
        i++;
        continue;
      }

      if (t.startsWith('>')) {
        final inner = <String>[];
        var lazyOk = false;
        while (i < n) {
          final l = lines[i];
          final li = _indent(l);
          if (li < 4 && l.substring(li).startsWith('>')) {
            var s = l.substring(li + 1);
            if (s.startsWith(' ')) s = s.substring(1);
            inner.add(s);
            lazyOk = !_isBlank(s);
            i++;
          } else if (lazyOk && !_isBlank(l) && !_startsBlock(l)) {
            inner.add(l);
            i++;
          } else {
            break;
          }
        }
        out.add(_RQuote(parse(inner)));
        continue;
      }

      final m = _marker(t);
      if (m != null) {
        i = _list(lines, i, out);
        continue;
      }

      if (t.contains('|') &&
          i + 1 < n &&
          _indent(lines[i + 1]) < 4 &&
          _tableDelim.hasMatch(lines[i + 1].trim())) {
        final header = _cells(t);
        final delims = _cells(lines[i + 1].trim());
        if (header.length == delims.length) {
          final aligns = [
            for (final d in delims)
              d.startsWith(':') && d.endsWith(':')
                  ? MdAlign.center
                  : d.endsWith(':')
                      ? MdAlign.right
                      : d.startsWith(':')
                          ? MdAlign.left
                          : MdAlign.none
          ];
          i += 2;
          final rows = <List<String>>[];
          while (i < n && !_isBlank(lines[i]) && !_startsBlock(lines[i])) {
            final c = _cells(lines[i].trim());
            rows.add([
              for (var k = 0; k < header.length; k++) k < c.length ? c[k] : ''
            ]);
            i++;
          }
          out.add(_RTable(aligns, header, rows));
          continue;
        }
      }

      // a paragraph (or a setext heading)
      final para = <String>[];
      while (i < n) {
        final l = lines[i];
        if (_isBlank(l)) break;
        if (para.isNotEmpty) {
          final li = _indent(l);
          if (li < 4) {
            final lt = l.substring(li);
            if (_setext1.hasMatch(lt) || _setext2.hasMatch(lt)) {
              final level = lt.startsWith('=') ? 1 : 2;
              final text = _takeRefs(para);
              if (text.isNotEmpty) {
                out.add(_RHeading(level, text));
                para.clear();
              } else {
                // only definitions: the line starts something else
                para.clear();
                break;
              }
              i++;
              break;
            }
          }
          if (_startsBlock(l, inParagraph: true)) break;
        }
        para.add(l.trimLeft());
        i++;
      }
      if (para.isNotEmpty) {
        final text = _takeRefs(para);
        if (text.isNotEmpty) out.add(_RPara(text));
      }
    }
    return out;
  }

  /// Parses a list starting at line [i]; returns the line after it.
  int _list(List<String> lines, int i, List<_Raw> out) {
    final n = lines.length;
    final first = _marker(lines[i].substring(_indent(lines[i])))!;
    final list = _RList(first.$1, first.$3);
    while (i < n) {
      final line = lines[i];
      final ind = _indent(line);
      if (ind >= 4) break;
      final m = _marker(line.substring(ind));
      if (m == null || m.$1 != first.$1 || m.$2 != first.$2) break;
      final contentIndent = ind + m.$4;
      final item = <String>[
        m.$5
            ? ''
            : line.substring(
                contentIndent < line.length ? contentIndent : line.length)
      ];
      i++;
      while (i < n) {
        final l = lines[i];
        if (_isBlank(l)) {
          // an item that starts empty ends at a blank line
          if (item.length == 1 && item.first.isEmpty) break;
          item.add('');
          i++;
          continue;
        }
        final li = _indent(l);
        if (li >= contentIndent) {
          item.add(l.substring(contentIndent));
          i++;
          continue;
        }
        if (item.last.isNotEmpty && !_startsBlock(l, inParagraph: true)) {
          // lazy continuation of a paragraph
          item.add(l.trim());
          i++;
          continue;
        }
        break;
      }
      var trailing = 0;
      while (item.length > 1 && item.last.isEmpty) {
        item.removeLast();
        trailing++;
      }
      // a blank line between the blocks of an item makes the list loose
      for (var k = 1; k < item.length - 1; k++) {
        if (item[k].isEmpty &&
            item[k + 1].isNotEmpty &&
            _indent(item[k + 1]) == 0 &&
            _marker(item[k + 1]) == null) {
          list.tight = false;
          break;
        }
      }
      bool? checked;
      final tm = _task.firstMatch(item.first);
      if (tm != null) {
        checked = tm.group(1) != ' ';
        item[0] = item.first.substring(tm.end);
      }
      list.items.add((checked, parse(item)));
      if (trailing > 0 && i < n) {
        final l = lines[i];
        final li = _indent(l);
        final nm = li < 4 ? _marker(l.substring(li)) : null;
        if (nm != null && nm.$1 == first.$1 && nm.$2 == first.$2) {
          list.tight = false;
        }
      }
    }
    out.add(list);
    return i;
  }

  /// Takes the link reference definitions at the start of [para]; returns
  /// the rest of the text.
  String _takeRefs(List<String> para) {
    var k = 0;
    while (k < para.length) {
      final m = _refDef.firstMatch(para[k]);
      if (m == null) break;
      final label = _normLabel(m.group(1)!);
      var url = m.group(2)!;
      if (url.startsWith('<')) url = url.substring(1, url.length - 1);
      final t = m.group(3);
      refs.putIfAbsent(
          label,
          () => _Ref(_unescape(url),
              t == null ? null : _unescape(t.substring(1, t.length - 1))));
      k++;
    }
    return para.sublist(k).join('\n').trimRight();
  }
}

/// The list item marker at the start of [t] (no indentation).
_Marker? _marker(String t) {
  final b = _bullet.firstMatch(t);
  if (b != null) {
    if (_rule.hasMatch(t)) return null;
    final sp = b.group(2)!.length;
    final empty = t.length == b.end;
    final w = empty || sp > 4 ? 2 : 1 + sp;
    return (false, b.group(1)!, 1, w, empty);
  }
  final o = _ordered.firstMatch(t);
  if (o != null) {
    final sp = o.group(3)!.length;
    final empty = t.length == o.end;
    final mw = o.group(1)!.length + 1;
    final w = empty || sp > 4 ? mw + 1 : mw + sp;
    return (true, o.group(2)!, int.parse(o.group(1)!), w, empty);
  }
  return null;
}

/// True when [l] starts a block that ends a paragraph.
bool _startsBlock(String l, {bool inParagraph = false}) {
  final ind = _indent(l);
  if (ind >= 4) return false;
  final t = l.substring(ind);
  if (t.isEmpty) return false;
  if (t.startsWith('>')) return true;
  if (_atx.hasMatch(t)) return true;
  if (_rule.hasMatch(t)) return true;
  final f = _fenceOpen.firstMatch(t);
  if (f != null && !(f.group(1)![0] == '`' && f.group(2)!.contains('`'))) {
    return true;
  }
  final m = _marker(t);
  if (m != null) {
    // only "1." and non-empty items interrupt a paragraph
    if (inParagraph && (m.$5 || (m.$1 && m.$3 != 1))) return false;
    return true;
  }
  return false;
}

/// The cells of a table row.
List<String> _cells(String row) {
  var r = row.trim();
  if (r.startsWith('|')) r = r.substring(1);
  if (r.endsWith('|') && !r.endsWith('\\|')) r = r.substring(0, r.length - 1);
  final cells = <String>[];
  final b = StringBuffer();
  for (var i = 0; i < r.length; i++) {
    final c = r[i];
    if (c == '\\' && i + 1 < r.length && r[i + 1] == '|') {
      b.write('|');
      i++;
    } else if (c == '|') {
      cells.add(b.toString().trim());
      b.clear();
    } else {
      b.write(c);
    }
  }
  cells.add(b.toString().trim());
  return cells;
}

String _normLabel(String s) =>
    s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

bool _isAsciiPunct(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x60) ||
    (c >= 0x7B && c <= 0x7E);

/// [s] with its backslash escapes and entities resolved.
String _unescape(String s) {
  if (!s.contains('\\') && !s.contains('&')) return s;
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x5C && i + 1 < s.length && _isAsciiPunct(s.codeUnitAt(i + 1))) {
      b.writeCharCode(s.codeUnitAt(i + 1));
      i++;
    } else if (c == 0x26) {
      final e = _entity(s, i);
      if (e != null) {
        b.write(e.$1);
        i = e.$2 - 1;
      } else {
        b.write('&');
      }
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}

const _entities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00A0',
  'copy': '\u00A9',
  'reg': '\u00AE',
  'trade': '\u2122',
  'hellip': '\u2026',
  'middot': '\u00B7',
  'times': '\u00D7',
  'deg': '\u00B0',
  'laquo': '\u00AB',
  'raquo': '\u00BB',
  'euro': '\u20AC',
};

final _entityRe = RegExp(
    r'&(?:#[xX]([0-9a-fA-F]{1,6})|#(\d{1,7})|([A-Za-z][A-Za-z0-9]{1,31}));');

/// The entity at [i] of [s]: (its text, the index after it).
(String, int)? _entity(String s, int i) {
  final m = _entityRe.matchAsPrefix(s, i);
  if (m == null) return null;
  if (m.group(3) != null) {
    final t = _entities[m.group(3)!];
    return t == null ? null : (t, m.end);
  }
  var code = m.group(1) != null
      ? int.parse(m.group(1)!, radix: 16)
      : int.parse(m.group(2)!);
  if (code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
    code = 0xFFFD;
  }
  return (String.fromCharCode(code), m.end);
}

// ---------------------------------------------------------------------------
// Blocks, second pass: the inlines

class _Builder {
  final Map<String, _Ref> refs;
  final Map<String, int> _slugs = {};
  _Builder(this.refs);

  List<MdBlock> blocks(List<_Raw> raw) {
    final out = <MdBlock>[];
    for (final r in raw) {
      switch (r) {
        case _RHeading(:final level, :final text):
          final inl = _InlineParser(text, refs).parse();
          out.add(MdHeading(level, inl, _slug(mdPlainText(inl))));
        case _RPara(:final text):
          final inl = _InlineParser(text, refs).parse();
          if (inl.isNotEmpty) out.add(MdParagraph(inl));
        case _RCode(:final info, :final code):
          out.add(MdCodeBlock(info, code));
        case _RQuote(blocks: final b):
          out.add(MdQuote(blocks(b)));
        case _RList():
          out.add(MdList(r.ordered, r.start, r.tight,
              [for (final (c, b) in r.items) MdListItem(c, blocks(b))]));
        case _RRule():
          out.add(const MdRule());
        case _RTable(:final aligns, :final header, :final rows):
          out.add(MdTable(aligns, [
            for (final h in header) _InlineParser(h, refs).parse()
          ], [
            for (final row in rows)
              [for (final c in row) _InlineParser(c, refs).parse()]
          ]));
      }
    }
    return out;
  }

  static final _slugDrop = RegExp(r'[^\p{L}\p{N}\p{M} _-]', unicode: true);

  String _slug(String text) {
    final base = text
        .trim()
        .toLowerCase()
        .replaceAll(_slugDrop, '')
        .replaceAll(' ', '-');
    final k = _slugs[base];
    _slugs[base] = (k ?? -1) + 1;
    return k == null ? base : '$base-${k + 1}';
  }
}

/// The GitHub anchor of a heading text (without the numbering of
/// duplicates).
String mdSlug(String text) => _Builder({})._slug(text);

// ---------------------------------------------------------------------------
// Inlines

/// A run of * _ ~ that may open or close emphasis.
class _Delim {
  final int char;
  final int origCount;
  int count;
  final bool canOpen;
  final bool canClose;
  _Delim(this.char, this.count, this.canOpen, this.canClose)
      : origCount = count;
}

/// A [ or ![ that may start a link or an image.
class _Bracket {
  final bool image;

  /// The index in the text after the bracket.
  final int textStart;

  /// The index of this marker in the item list.
  int itemIndex;
  bool active = true;
  _Bracket(this.image, this.textStart, this.itemIndex);
}

final _autolinkUri =
    RegExp(r'<([A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\x00-\x20]*)>');
final _autolinkEmail = RegExp(r'<([a-zA-Z0-9.!#$%&'
    "'"
    r'*+/=?^_`{|}~\-]+@[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*)>');
final _htmlTag = RegExp(
    r'''<(/?)([A-Za-z][A-Za-z0-9\-]*)((?:\s+[A-Za-z_:][A-Za-z0-9_.:\-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*)\s*(/?)>''');
final _htmlComment = RegExp(r'<!--[\s\S]*?-->');
final _htmlAttr = RegExp(
    r'''([A-Za-z_:][A-Za-z0-9_.:\-]*)(?:\s*=\s*(?:([^\s"'=<>`]+)|'([^']*)'|"([^"]*)"))?''');
final _bareUrl = RegExp(r'(?:https?://|www\.)[^\s<]*', caseSensitive: false);
final _unicodePunct = RegExp(r'[\p{P}\p{S}]', unicode: true);

bool _isWs(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0xA0;

bool _isPunct(int c) {
  if (c < 0x80) return _isAsciiPunct(c);
  return _unicodePunct.hasMatch(String.fromCharCode(c));
}

class _InlineParser {
  final String s;
  final Map<String, _Ref> refs;

  /// MdInline, _Delim or _Bracket.
  final List<Object> items = [];
  final List<_Bracket> brackets = [];
  final StringBuffer _text = StringBuffer();

  _InlineParser(this.s, this.refs);

  void _flush() {
    if (_text.isEmpty) return;
    items.add(MdText(_text.toString()));
    _text.clear();
  }

  List<MdInline> parse() {
    final n = s.length;
    var i = 0;
    while (i < n) {
      final c = s.codeUnitAt(i);
      switch (c) {
        case 0x5C: // backslash
          if (i + 1 < n && s.codeUnitAt(i + 1) == 0x0A) {
            _flush();
            items.add(const MdBreak(true));
            i += 2;
            i = _skipSpaces(i);
          } else if (i + 1 < n && _isAsciiPunct(s.codeUnitAt(i + 1))) {
            _text.writeCharCode(s.codeUnitAt(i + 1));
            i += 2;
          } else {
            _text.write('\\');
            i++;
          }
        case 0x60: // `
          i = _codeSpan(i);
        case 0x2A || 0x5F || 0x7E: // * _ ~
          i = _delimRun(i, c);
        case 0x21: // !
          if (i + 1 < n && s.codeUnitAt(i + 1) == 0x5B) {
            _flush();
            brackets.add(_Bracket(true, i + 2, items.length));
            items.add(brackets.last);
            i += 2;
          } else {
            _text.write('!');
            i++;
          }
        case 0x5B: // [
          _flush();
          brackets.add(_Bracket(false, i + 1, items.length));
          items.add(brackets.last);
          i++;
        case 0x5D: // ]
          i = _closeBracket(i);
        case 0x3C: // <
          i = _angle(i);
        case 0x26: // &
          final e = _entity(s, i);
          if (e != null) {
            _text.write(e.$1);
            i = e.$2;
          } else {
            _text.write('&');
            i++;
          }
        case 0x0A: // line break
          final t = _text.toString();
          var k = t.length;
          while (k > 0 && t.codeUnitAt(k - 1) == 0x20) {
            k--;
          }
          final hard = t.length - k >= 2;
          _text.clear();
          _text.write(t.substring(0, k));
          _flush();
          items.add(MdBreak(hard));
          i = _skipSpaces(i + 1);
        case 0x68 || 0x48 || 0x77 || 0x57: // h H w W
          i = _bare(i);
        default:
          _text.writeCharCode(c);
          i++;
      }
    }
    _flush();
    _emphasis(0);
    return _finish(items);
  }

  int _skipSpaces(int i) {
    while (i < s.length && s.codeUnitAt(i) == 0x20) {
      i++;
    }
    return i;
  }

  int _codeSpan(int i) {
    final n = s.length;
    var j = i;
    while (j < n && s.codeUnitAt(j) == 0x60) {
      j++;
    }
    final run = j - i;
    var k = j;
    while (k < n) {
      if (s.codeUnitAt(k) != 0x60) {
        k++;
        continue;
      }
      var e = k;
      while (e < n && s.codeUnitAt(e) == 0x60) {
        e++;
      }
      if (e - k == run) {
        var code = s.substring(j, k).replaceAll('\n', ' ');
        if (code.length >= 2 &&
            code.startsWith(' ') &&
            code.endsWith(' ') &&
            code.trim().isNotEmpty) {
          code = code.substring(1, code.length - 1);
        }
        _flush();
        items.add(MdCode(code));
        return e;
      }
      k = e;
    }
    _text.write(s.substring(i, j));
    return j;
  }

  int _delimRun(int i, int c) {
    final n = s.length;
    var j = i;
    while (j < n && s.codeUnitAt(j) == c) {
      j++;
    }
    final count = j - i;
    if (c == 0x7E && count > 2) {
      _text.write(s.substring(i, j));
      return j;
    }
    final before = i == 0 ? 0x20 : s.codeUnitAt(i - 1);
    final after = j >= n ? 0x20 : s.codeUnitAt(j);
    final bWs = _isWs(before), aWs = _isWs(after);
    final bP = _isPunct(before), aP = _isPunct(after);
    final left = !aWs && (!aP || bWs || bP);
    final right = !bWs && (!bP || aWs || aP);
    bool open, close;
    if (c == 0x5F) {
      open = left && (!right || bP);
      close = right && (!left || aP);
    } else {
      open = left;
      close = right;
    }
    _flush();
    items.add(_Delim(c, count, open, close));
    return j;
  }

  int _closeBracket(int i) {
    if (brackets.isEmpty) {
      _text.write(']');
      return i + 1;
    }
    final op = brackets.last;
    if (!op.active) {
      brackets.removeLast();
      _text.write(']');
      return i + 1;
    }
    _flush();
    final label = s.substring(op.textStart, i);
    String? url;
    String? title;
    var end = i + 1;
    final inl = _inlineDest(i + 1);
    if (inl != null) {
      (url, title, end) = inl;
    } else {
      // reference: [text][label], [text][] or [text]
      String? key;
      if (i + 1 < s.length && s.codeUnitAt(i + 1) == 0x5B) {
        final close = s.indexOf(']', i + 2);
        if (close > 0) {
          final l = s.substring(i + 2, close);
          key = l.trim().isEmpty ? label : l;
          end = close + 1;
        }
      }
      key ??= label;
      final r = refs[_normLabel(key)];
      if (r != null) {
        url = r.url;
        title = r.title;
      } else {
        end = i + 1;
      }
    }
    if (url == null) {
      brackets.removeLast();
      _text.write(']');
      return i + 1;
    }
    brackets.removeLast();
    _emphasis(op.itemIndex + 1);
    final children = _finish(items.sublist(op.itemIndex + 1));
    items.removeRange(op.itemIndex, items.length);
    if (op.image) {
      items.add(MdImage(url, title, mdPlainText(children)));
    } else {
      items.add(MdLink(url, title, children));
      // no links in links
      for (final b in brackets) {
        if (!b.image) b.active = false;
      }
    }
    return end;
  }

  /// An inline destination "(url "title")" at [i]: (url, title, the index
  /// after it).
  (String, String?, int)? _inlineDest(int i) {
    final n = s.length;
    if (i >= n || s.codeUnitAt(i) != 0x28) return null;
    var j = i + 1;
    while (j < n && _isWs(s.codeUnitAt(j))) {
      j++;
    }
    String url;
    if (j < n && s.codeUnitAt(j) == 0x3C) {
      final e = s.indexOf('>', j + 1);
      if (e < 0 || s.substring(j + 1, e).contains('\n')) return null;
      url = s.substring(j + 1, e);
      j = e + 1;
    } else {
      final st = j;
      var depth = 0;
      while (j < n) {
        final c = s.codeUnitAt(j);
        if (c == 0x5C && j + 1 < n) {
          j += 2;
          continue;
        }
        if (_isWs(c) || c < 0x20) break;
        if (c == 0x28) depth++;
        if (c == 0x29) {
          if (depth == 0) break;
          depth--;
        }
        j++;
      }
      url = s.substring(st, j);
    }
    final ws = j;
    while (j < n && _isWs(s.codeUnitAt(j))) {
      j++;
    }
    String? title;
    if (j < n && j > ws) {
      final q = s.codeUnitAt(j);
      final closeQ = q == 0x22
          ? 0x22
          : q == 0x27
              ? 0x27
              : q == 0x28
                  ? 0x29
                  : -1;
      if (closeQ >= 0) {
        var k = j + 1;
        while (k < n && s.codeUnitAt(k) != closeQ) {
          if (s.codeUnitAt(k) == 0x5C) k++;
          k++;
        }
        if (k >= n) return null;
        title = _unescape(s.substring(j + 1, k));
        j = k + 1;
        while (j < n && _isWs(s.codeUnitAt(j))) {
          j++;
        }
      }
    }
    if (j >= n || s.codeUnitAt(j) != 0x29) return null;
    return (_unescape(url), title, j + 1);
  }

  int _angle(int i) {
    final u = _autolinkUri.matchAsPrefix(s, i);
    if (u != null) {
      _flush();
      final url = u.group(1)!;
      items.add(MdLink(url, null, [MdText(url)]));
      return u.end;
    }
    final e = _autolinkEmail.matchAsPrefix(s, i);
    if (e != null) {
      _flush();
      final mail = e.group(1)!;
      items.add(MdLink('mailto:$mail', null, [MdText(mail)]));
      return e.end;
    }
    final cm = _htmlComment.matchAsPrefix(s, i);
    if (cm != null) return cm.end;
    final t = _htmlTag.matchAsPrefix(s, i);
    if (t != null) {
      final name = t.group(2)!.toLowerCase();
      if (t.group(1)!.isEmpty && name == 'img') {
        final a = _attrs(t.group(3)!);
        final src = a['src'];
        if (src != null) {
          _flush();
          items.add(MdImage(src, a['title'], a['alt'] ?? '',
              width: int.tryParse(a['width'] ?? ''),
              height: int.tryParse(a['height'] ?? '')));
        }
      } else if (name == 'br') {
        _flush();
        items.add(const MdBreak(true));
      }
      // any other tag is dropped (never interpreted)
      return t.end;
    }
    _text.write('<');
    return i + 1;
  }

  static Map<String, String> _attrs(String s) {
    final out = <String, String>{};
    for (final m in _htmlAttr.allMatches(s)) {
      out.putIfAbsent(m.group(1)!.toLowerCase(),
          () => _unescape(m.group(2) ?? m.group(3) ?? m.group(4) ?? ''));
    }
    return out;
  }

  /// A bare URL (GitHub autolink) at [i].
  int _bare(int i) {
    final c = s.codeUnitAt(i);
    final prev = i == 0 ? 0x20 : s.codeUnitAt(i - 1);
    final boundary = _isWs(prev) ||
        prev == 0x2A ||
        prev == 0x5F ||
        prev == 0x7E ||
        prev == 0x28;
    if (!boundary || _inLink()) {
      _text.writeCharCode(c);
      return i + 1;
    }
    final m = _bareUrl.matchAsPrefix(s, i);
    if (m == null) {
      _text.writeCharCode(c);
      return i + 1;
    }
    var url = m.group(0)!;
    // trailing punctuation is not part of it, nor an unbalanced ')'
    while (url.isNotEmpty) {
      final last = url[url.length - 1];
      if ('?!.,:*_~\'"'.contains(last)) {
        url = url.substring(0, url.length - 1);
      } else if (last == ')' &&
          ')'.allMatches(url).length > '('.allMatches(url).length) {
        url = url.substring(0, url.length - 1);
      } else {
        break;
      }
    }
    final host = url.toLowerCase().startsWith('www.')
        ? url.substring(4)
        : url.substring(url.indexOf('//') + 2);
    if (!host.contains('.') && !url.toLowerCase().startsWith('http')) {
      _text.writeCharCode(c);
      return i + 1;
    }
    if (host.isEmpty) {
      _text.writeCharCode(c);
      return i + 1;
    }
    _flush();
    final href = url.toLowerCase().startsWith('www.') ? 'http://$url' : url;
    items.add(MdLink(href, null, [MdText(url)]));
    return i + url.length;
  }

  bool _inLink() {
    for (final b in brackets) {
      if (!b.image && b.active) return true;
    }
    return false;
  }

  /// The emphasis of the items from [bottom] (CommonMark's "process
  /// emphasis", with ~ for strikethrough).
  void _emphasis(int bottom) {
    final openersBottom = <int, int>{};
    var i = bottom;
    while (i < items.length) {
      final d = items[i];
      if (d is! _Delim || !d.canClose || d.count == 0) {
        i++;
        continue;
      }
      final floor = openersBottom[d.char] ?? bottom;
      var found = -1;
      for (var j = i - 1; j >= floor; j--) {
        final o = items[j];
        if (o is! _Delim || o.char != d.char || !o.canOpen || o.count == 0) {
          continue;
        }
        if (d.char == 0x7E) {
          if (o.count != d.count) continue;
        } else if ((o.canClose || d.canOpen) &&
            (o.origCount + d.origCount) % 3 == 0 &&
            !(o.origCount % 3 == 0 && d.origCount % 3 == 0)) {
          continue;
        }
        found = j;
        break;
      }
      if (found < 0) {
        openersBottom[d.char] = i;
        i++;
        continue;
      }
      final o = items[found] as _Delim;
      final use =
          d.char == 0x7E ? o.count : (o.count >= 2 && d.count >= 2 ? 2 : 1);
      final children = _finish(items.sublist(found + 1, i));
      final node = d.char == 0x7E
          ? MdStrike(children)
          : use == 2
              ? MdStrong(children)
              : MdEmphasis(children);
      o.count -= use;
      d.count -= use;
      items.replaceRange(found + 1, i, [node]);
      i = found + 2;
      if (o.count == 0) {
        items.removeAt(found);
        i--;
      }
      if (d.count == 0) items.removeAt(i);
    }
  }

  /// [list] as inlines: the delimiters and brackets left are text, and the
  /// texts next to each other are joined.
  static List<MdInline> _finish(List<Object> list) {
    final out = <MdInline>[];
    final b = StringBuffer();
    void flush() {
      if (b.isEmpty) return;
      out.add(MdText(b.toString()));
      b.clear();
    }

    for (final o in list) {
      switch (o) {
        case MdText(:final text):
          b.write(text);
        case _Delim():
          b.write(String.fromCharCode(o.char) * o.count);
        case _Bracket():
          b.write(o.image ? '![' : '[');
        case MdInline():
          flush();
          out.add(o);
      }
    }
    flush();
    // no break at the end of a block
    while (out.isNotEmpty && out.last is MdBreak) {
      out.removeLast();
    }
    return out;
  }
}
