// The README of an archive (docs/readme.md): a file named README.md (or
// README.markdown, README.txt, README) in a folder of the archive
// describes that folder, the one at the top describes the archive. It is
// an ordinary entry: any format can carry it, and the generations of a
// .zx archive keep its versions.

import 'dart:convert';
import 'dart:typed_data';

import 'markdown.dart';

/// The names a README may have, best first (compared ignoring case).
const readmeNames = ['readme.md', 'readme.markdown', 'readme.txt', 'readme'];

/// The README to show among the file [names] of one folder (names, not
/// paths), or null.
String? pickReadme(Iterable<String> names) {
  String? best;
  var rank = readmeNames.length;
  for (final n in names) {
    final r = readmeNames.indexOf(n.toLowerCase());
    if (r < 0) continue;
    // the same name in other cases: the upper case one ("README.md")
    if (r < rank || (r == rank && n.compareTo(best!) < 0)) {
      best = n;
      rank = r;
    }
  }
  return best;
}

/// True when [name] is a markdown file name.
bool isMarkdownName(String name) {
  final l = name.toLowerCase();
  return l.endsWith('.md') || l.endsWith('.markdown');
}

/// The folder of the archive path [path] ('' at the top).
String readmeDirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// Parses the README [bytes] of the file [name] (UTF-8): markdown for a
/// markdown name, the text as it is otherwise. [truncated]: the bytes are
/// the start of the file only (the document is marked so, and a character
/// cut at the end is dropped).
MdDocument parseReadme(String name, Uint8List bytes, {bool truncated = false}) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (truncated) {
    final nl = text.lastIndexOf('\n');
    if (nl > 0) text = text.substring(0, nl);
  }
  final doc =
      isMarkdownName(name) ? parseMarkdown(text) : plainTextDocument(text);
  return truncated && !doc.truncated
      ? MdDocument(doc.blocks, truncated: true)
      : doc;
}
