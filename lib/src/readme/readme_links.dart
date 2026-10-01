// Where a link or an image of an archive README may point (docs/readme.md).
//
// Everything needed to show a README comes from the archive: an image is
// shown only when it is an entry of the archive, never fetched from
// elsewhere. Links to other places (a homepage) are allowed, as links the
// reader chooses to follow: http, https and mailto. Relative paths are
// taken from the folder of the README, "/" paths from the top of the
// archive, and a path may not leave the archive with "..".

import 'markdown.dart';

/// What a link or an image of a README points to.
sealed class ReadmeTarget {
  final String url;
  const ReadmeTarget(this.url);
}

/// A heading of the same document ("#usage").
class ReadmeAnchor extends ReadmeTarget {
  final String fragment;
  const ReadmeAnchor(super.url, this.fragment);
}

/// An entry (or folder) of the archive.
class ReadmeInternal extends ReadmeTarget {
  /// The path in the archive, '/' separated, without a leading '/'; empty
  /// for the top of the archive.
  final String path;

  /// The heading of a README it points to, when given ("docs/a.md#x").
  final String? fragment;
  const ReadmeInternal(super.url, this.path, this.fragment);
}

/// A place outside the archive, for a link only (never for an image).
class ReadmeExternal extends ReadmeTarget {
  const ReadmeExternal(super.url);
}

enum ReadmeBlockReason {
  /// An image from outside the archive.
  externalImage,

  /// A scheme that is not http, https or mailto (file:, data:,
  /// javascript:...).
  scheme,

  /// A path that leaves the archive with "..".
  escapesArchive,

  /// No destination.
  empty,
}

/// A link or an image that is not followed or shown.
class ReadmeBlocked extends ReadmeTarget {
  final ReadmeBlockReason reason;
  const ReadmeBlocked(super.url, this.reason);
}

const _externalSchemes = {'http', 'https', 'mailto'};
final _scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*):');

/// What [url] points to, for a README in the folder [baseDir] ('' for the
/// top of the archive). [isImage]: [url] is the source of an image, which
/// must be inside the archive.
ReadmeTarget classifyReadmeUrl(String url,
    {required String baseDir, required bool isImage}) {
  final u = url.trim();
  if (u.isEmpty) return ReadmeBlocked(url, ReadmeBlockReason.empty);
  if (u.startsWith('#')) {
    if (isImage) return ReadmeBlocked(url, ReadmeBlockReason.empty);
    return ReadmeAnchor(url, _decode(u.substring(1)));
  }
  final sm = _scheme.firstMatch(u);
  if (sm != null || u.startsWith('//')) {
    final scheme = sm == null ? 'https' : sm.group(1)!.toLowerCase();
    if (!_externalSchemes.contains(scheme)) {
      return ReadmeBlocked(url, ReadmeBlockReason.scheme);
    }
    if (isImage) return ReadmeBlocked(url, ReadmeBlockReason.externalImage);
    return ReadmeExternal(u);
  }
  var p = u;
  String? fragment;
  final h = p.indexOf('#');
  if (h >= 0) {
    fragment = _decode(p.substring(h + 1));
    p = p.substring(0, h);
  }
  final q = p.indexOf('?');
  if (q >= 0) p = p.substring(0, q);
  p = _decode(p).replaceAll('\\', '/');
  final parts = <String>[];
  if (!p.startsWith('/') && baseDir.isNotEmpty) {
    parts.addAll(baseDir.split('/').where((s) => s.isNotEmpty));
  }
  for (final s in p.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (parts.isEmpty) {
        return ReadmeBlocked(url, ReadmeBlockReason.escapesArchive);
      }
      parts.removeLast();
      continue;
    }
    parts.add(s);
  }
  if (isImage && parts.isEmpty) {
    return ReadmeBlocked(url, ReadmeBlockReason.empty);
  }
  return ReadmeInternal(url, parts.join('/'),
      fragment == null || fragment.isEmpty ? null : fragment);
}

String _decode(String s) {
  if (!s.contains('%')) return s;
  try {
    return Uri.decodeComponent(s);
  } on ArgumentError {
    return s;
  }
}

enum ReadmeIssueKind {
  /// An image from outside the archive (it is not shown).
  externalImage,

  /// A link or image with a scheme other than http, https, mailto.
  blockedScheme,

  /// A path that leaves the archive.
  escapesArchive,

  /// A path to an entry the archive does not have.
  missingEntry,

  /// A "#heading" the document does not have.
  missingAnchor,

  /// A link or image without a destination.
  empty,
}

/// A link or image of a README that can not work.
class ReadmeIssue {
  final ReadmeIssueKind kind;
  final String url;

  /// True for an image, false for a link.
  final bool image;
  const ReadmeIssue(this.kind, this.url, {required this.image});

  String get message => switch (kind) {
        ReadmeIssueKind.externalImage =>
          'image from outside the archive (not shown)',
        ReadmeIssueKind.blockedScheme => 'scheme not allowed',
        ReadmeIssueKind.escapesArchive => 'path leaves the archive',
        ReadmeIssueKind.missingEntry => 'not in the archive',
        ReadmeIssueKind.missingAnchor => 'no such heading',
        ReadmeIssueKind.empty => 'no destination',
      };

  @override
  String toString() => '${image ? 'image' : 'link'} "$url": $message';
}

/// Calls [f] for every link and image of [doc] (image: true for images).
void forEachReadmeUrl(MdDocument doc, void Function(String url, bool image) f) {
  void inl(List<MdInline> l) {
    for (final i in l) {
      switch (i) {
        case MdLink(:final url, :final children):
          f(url, false);
          inl(children);
        case MdImage(:final url):
          f(url, true);
        case MdEmphasis(:final children):
        case MdStrong(:final children):
        case MdStrike(:final children):
          inl(children);
        case MdText() || MdCode() || MdBreak():
          break;
      }
    }
  }

  void blocks(List<MdBlock> l) {
    for (final b in l) {
      switch (b) {
        case MdHeading(:final text):
        case MdParagraph(:final text):
          inl(text);
        case MdQuote(blocks: final c):
          blocks(c);
        case MdList(:final items):
          for (final it in items) {
            blocks(it.blocks);
          }
        case MdTable(:final header, :final rows):
          for (final c in header) {
            inl(c);
          }
          for (final r in rows) {
            for (final c in r) {
              inl(c);
            }
          }
        case MdCodeBlock() || MdRule():
          break;
      }
    }
  }

  blocks(doc.blocks);
}

/// The anchors (heading slugs) of [doc].
Set<String> readmeAnchors(MdDocument doc) {
  final out = <String>{};
  void blocks(List<MdBlock> l) {
    for (final b in l) {
      switch (b) {
        case MdHeading(:final slug):
          out.add(slug);
        case MdQuote(blocks: final c):
          blocks(c);
        case MdList(:final items):
          for (final it in items) {
            blocks(it.blocks);
          }
        default:
          break;
      }
    }
  }

  blocks(doc.blocks);
  return out;
}

/// The links and images of [doc] (a README in the folder [baseDir]) that
/// can not work: images from outside the archive, blocked schemes, paths
/// that leave the archive, entries that [exists] does not know (it gets
/// an archive path, '' never asked), missing headings.
List<ReadmeIssue> checkReadme(
    MdDocument doc, String baseDir, bool Function(String path) exists) {
  final issues = <ReadmeIssue>[];
  Set<String>? anchors;
  final seen = <(String, bool)>{};
  forEachReadmeUrl(doc, (url, image) {
    if (!seen.add((url, image))) return;
    final t = classifyReadmeUrl(url, baseDir: baseDir, isImage: image);
    switch (t) {
      case ReadmeBlocked(:final reason):
        issues.add(ReadmeIssue(
            switch (reason) {
              ReadmeBlockReason.externalImage => ReadmeIssueKind.externalImage,
              ReadmeBlockReason.scheme => ReadmeIssueKind.blockedScheme,
              ReadmeBlockReason.escapesArchive =>
                ReadmeIssueKind.escapesArchive,
              ReadmeBlockReason.empty => ReadmeIssueKind.empty,
            },
            url,
            image: image));
      case ReadmeInternal(:final path):
        if (path.isNotEmpty && !exists(path)) {
          issues.add(
              ReadmeIssue(ReadmeIssueKind.missingEntry, url, image: image));
        }
      case ReadmeAnchor(:final fragment):
        anchors ??= readmeAnchors(doc);
        if (!anchors!.contains(fragment.toLowerCase())) {
          issues.add(
              ReadmeIssue(ReadmeIssueKind.missingAnchor, url, image: image));
        }
      case ReadmeExternal():
        break;
    }
  });
  return issues;
}
