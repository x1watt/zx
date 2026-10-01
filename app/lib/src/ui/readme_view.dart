// The README of an archive folder (docs/readme.md), rendered: the markdown
// parsed by package:zx (in a background isolate) shown as widgets. Every
// image comes from the archive itself, read with ZxArchive.readBytes; an
// image from anywhere else is never fetched and shows its description
// instead. Links to other places are followed only when the reader taps
// them (see onExternal), links to entries of the archive navigate in it.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:zx/zx.dart';

import 'format_utils.dart';

/// The largest image read from the archive for a README.
const int readmeMaxImageBytes = 16 << 20;

class ReadmeView extends StatefulWidget {
  final ZxArchive archive;

  /// The README (or any markdown file) of [archive].
  final ZxItem item;

  /// A link to an entry or folder of the archive was tapped.
  final void Function(ReadmeInternal target)? onInternal;

  /// A link to another place (http, https, mailto) was tapped.
  final void Function(String url)? onExternal;

  /// Padding around the document.
  final EdgeInsets padding;

  const ReadmeView({
    super.key,
    required this.archive,
    required this.item,
    this.onInternal,
    this.onExternal,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 16),
  });

  @override
  State<ReadmeView> createState() => _ReadmeViewState();
}

class _ReadmeViewState extends State<ReadmeView> {
  ZxReadme? _readme;
  String? _error;
  ZxCancelToken? _cancel;
  final _recognizers = <TapGestureRecognizer>[];
  final _anchors = <String, GlobalKey>{};
  final _images = _ImageCache();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ReadmeView old) {
    super.didUpdateWidget(old);
    if (old.archive != widget.archive || old.item.path != widget.item.path) {
      if (old.archive != widget.archive) _images.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _disposeRecognizers();
    _images.clear();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _load() async {
    _cancel?.cancel();
    final cancel = ZxCancelToken();
    _cancel = cancel;
    final item = widget.item;
    setState(() {
      _readme = null;
      _error = null;
    });
    try {
      final r = await widget.archive.readmeOf(item, cancel: cancel);
      if (!mounted || cancel.isCancelled || widget.item.path != item.path) {
        return;
      }
      setState(() => _readme = r);
    } catch (e) {
      if (!mounted || cancel.isCancelled || widget.item.path != item.path) {
        return;
      }
      setState(() => _error = errorText(e));
    }
  }

  void _follow(String url) {
    final r = _readme;
    if (r == null) return;
    final t = classifyReadmeUrl(url, baseDir: r.baseDir, isImage: false);
    switch (t) {
      case ReadmeAnchor(:final fragment):
        _scrollTo(fragment);
      case ReadmeInternal(:final path, :final fragment):
        if (path == r.item.path && fragment != null) {
          _scrollTo(fragment);
        } else {
          widget.onInternal?.call(t);
        }
      case ReadmeExternal(:final url):
        widget.onExternal?.call(url);
      case ReadmeBlocked(:final reason):
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Link not followed: ${_why(reason)}')),
        );
    }
  }

  void _scrollTo(String fragment) {
    final ctx = _anchors[fragment.toLowerCase()]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = _readme;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: TextStyle(color: cs.error)),
        ),
      );
    }
    if (r == null) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    _disposeRecognizers();
    final b = _Renderer(this, Theme.of(context), r.baseDir);
    final children = <Widget>[
      ...b.blocks(r.doc.blocks),
      if (r.doc.truncated)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            'Only the start of ${r.item.name} is shown.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
    ];
    return SelectionArea(
      child: Scrollbar(
        child: SingleChildScrollView(
          key: const Key('readme-scroll'),
          padding: widget.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

String _why(ReadmeBlockReason r) => switch (r) {
  ReadmeBlockReason.externalImage => 'image from outside the archive',
  ReadmeBlockReason.scheme => 'this kind of link is not allowed',
  ReadmeBlockReason.escapesArchive => 'the path leaves the archive',
  ReadmeBlockReason.empty => 'no destination',
};

/// Images read from the archive, kept while the view lives.
class _ImageCache {
  final Map<String, Future<Uint8List>> _data = {};
  final List<ZxCancelToken> _tokens = [];

  Future<Uint8List> get(ZxArchive archive, ZxItem item) => _data.putIfAbsent(
    item.path,
    () {
      final c = ZxCancelToken();
      _tokens.add(c);
      return archive.readBytes(item, maxBytes: readmeMaxImageBytes, cancel: c);
    },
  );

  void clear() {
    for (final t in _tokens) {
      t.cancel();
    }
    _tokens.clear();
    _data.clear();
  }
}

/// Builds the widgets of a document.
class _Renderer {
  final _ReadmeViewState s;
  final ThemeData theme;
  final String baseDir;
  _Renderer(this.s, this.theme, this.baseDir);

  ColorScheme get cs => theme.colorScheme;
  TextStyle get body => theme.textTheme.bodyMedium!.copyWith(height: 1.45);

  TextStyle get _code => kMonoStyle.copyWith(
    fontSize: (body.fontSize ?? 14) * 0.92,
    backgroundColor: cs.surfaceContainerHighest,
  );

  List<Widget> blocks(List<MdBlock> list, {bool tight = false}) {
    final out = <Widget>[];
    for (var i = 0; i < list.length; i++) {
      final gap = i == list.length - 1 ? 0.0 : (tight ? 2.0 : 10.0);
      out.add(
        Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: block(list[i], tight: tight),
        ),
      );
    }
    return out;
  }

  Widget block(MdBlock b, {bool tight = false}) {
    switch (b) {
      case MdHeading(:final level, :final text, :final slug):
        final key = s._anchors.putIfAbsent(slug, GlobalKey.new);
        final tt = theme.textTheme;
        final style = switch (level) {
          1 => tt.headlineSmall!,
          2 => tt.titleLarge!,
          3 => tt.titleMedium!,
          _ => tt.titleSmall!,
        }.copyWith(fontWeight: FontWeight.w600);
        final t = Text.rich(TextSpan(children: inlines(text, style)));
        return Padding(
          key: key,
          padding: EdgeInsets.only(top: level <= 2 ? 8 : 4),
          child: level <= 2
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    t,
                    const SizedBox(height: 4),
                    Divider(height: 1, color: cs.outlineVariant),
                  ],
                )
              : t,
        );
      case MdParagraph(:final text):
        return Text.rich(TextSpan(children: inlines(text, body)));
      case MdCodeBlock(:final code):
        return Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.all(10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(code, style: kMonoStyle.copyWith(fontSize: 12.5)),
          ),
        );
      case MdQuote(blocks: final c):
        return Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: cs.outlineVariant, width: 3),
            ),
          ),
          padding: const EdgeInsets.only(left: 12),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: cs.onSurfaceVariant),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: blocks(c),
            ),
          ),
        );
      case MdList():
        return _list(b);
      case MdRule():
        return Divider(height: 9, thickness: 2, color: cs.outlineVariant);
      case MdTable():
        return _table(b);
    }
  }

  Widget _list(MdList l) {
    final rows = <Widget>[];
    for (var i = 0; i < l.items.length; i++) {
      final it = l.items[i];
      Widget marker;
      if (it.checked != null) {
        marker = Icon(
          it.checked!
              ? Icons.check_box_outlined
              : Icons.check_box_outline_blank,
          size: 18,
          color: cs.onSurfaceVariant,
        );
      } else {
        marker = l.ordered
            ? Text('${l.start + i}.', style: body)
            : Padding(
                padding: EdgeInsets.only(
                  top: (body.fontSize ?? 14) * (body.height ?? 1.2) / 2 - 2.5,
                  left: 4,
                ),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: body.color ?? cs.onSurface,
                    shape: BoxShape.circle,
                  ),
                ),
              );
      }
      rows.add(
        Padding(
          padding: EdgeInsets.only(
            bottom: i == l.items.length - 1 ? 0 : (l.tight ? 2 : 8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: l.ordered ? 28 : 20,
                child: Align(alignment: Alignment.topLeft, child: marker),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: blocks(it.blocks, tight: l.tight),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  Widget _table(MdTable t) {
    TextAlign align(int c) => switch (t.aligns[c]) {
      MdAlign.center => TextAlign.center,
      MdAlign.right => TextAlign.right,
      _ => TextAlign.left,
    };
    Widget cell(List<MdInline> text, int c, {bool head = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text.rich(
        TextSpan(
          children: inlines(
            text,
            head ? body.copyWith(fontWeight: FontWeight.w600) : body,
          ),
        ),
        textAlign: align(c),
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: cs.outlineVariant),
        children: [
          TableRow(
            decoration: BoxDecoration(color: cs.surfaceContainerLow),
            children: [
              for (var c = 0; c < t.header.length; c++)
                cell(t.header[c], c, head: true),
            ],
          ),
          for (final row in t.rows)
            TableRow(
              children: [for (var c = 0; c < row.length; c++) cell(row[c], c)],
            ),
        ],
      ),
    );
  }

  List<InlineSpan> inlines(
    List<MdInline> list,
    TextStyle style, {
    String? link,
  }) {
    final out = <InlineSpan>[];
    TapGestureRecognizer? tap() {
      if (link == null) return null;
      final r = TapGestureRecognizer()..onTap = () => s._follow(link);
      s._recognizers.add(r);
      return r;
    }

    for (final i in list) {
      switch (i) {
        case MdText(:final text):
          out.add(TextSpan(text: text, style: style, recognizer: tap()));
        case MdCode(:final code):
          out.add(
            TextSpan(
              text: code,
              style: _code.merge(
                TextStyle(
                  color: style.color,
                  decoration: style.decoration,
                  fontSize: (style.fontSize ?? 14) * 0.92,
                ),
              ),
              recognizer: tap(),
            ),
          );
        case MdEmphasis(:final children):
          out.addAll(
            inlines(
              children,
              style.copyWith(fontStyle: FontStyle.italic),
              link: link,
            ),
          );
        case MdStrong(:final children):
          out.addAll(
            inlines(
              children,
              style.copyWith(fontWeight: FontWeight.w700),
              link: link,
            ),
          );
        case MdStrike(:final children):
          out.addAll(
            inlines(
              children,
              style.copyWith(decoration: TextDecoration.lineThrough),
              link: link,
            ),
          );
        case MdLink(:final url, :final title, :final children):
          final ls = style.copyWith(
            color: cs.primary,
            decoration: TextDecoration.underline,
            decorationColor: cs.primary.withValues(alpha: 0.5),
          );
          final spans = inlines(children, ls, link: url);
          out.add(
            TextSpan(
              children: spans,
              mouseCursor: SystemMouseCursors.click,
              semanticsLabel: title,
            ),
          );
        case MdImage():
          out.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _image(i, link),
            ),
          );
        case MdBreak(:final hard):
          out.add(TextSpan(text: hard ? '\n' : ' ', style: style));
      }
    }
    return out;
  }

  Widget _image(MdImage i, String? link) {
    final t = classifyReadmeUrl(i.url, baseDir: baseDir, isImage: true);
    Widget w;
    switch (t) {
      case ReadmeInternal(:final path):
        final item = s.widget.archive[path];
        w = item == null || item.isDir
            ? _placeholder(i, Icons.broken_image_outlined, 'not in the archive')
            : (item.size ?? 0) > readmeMaxImageBytes
            ? _placeholder(i, Icons.image_not_supported_outlined, 'too large')
            : _ArchiveImage(
                key: ValueKey(path),
                future: s._images.get(s.widget.archive, item),
                image: i,
                placeholder: (why) =>
                    _placeholder(i, Icons.broken_image_outlined, why),
              );
      case ReadmeBlocked(:final reason):
        w = _placeholder(i, Icons.block_rounded, _why(reason));
      default:
        w = _placeholder(i, Icons.block_rounded, 'not an image');
    }
    if (link == null) return w;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => s._follow(link), child: w),
    );
  }

  Widget _placeholder(MdImage i, IconData icon, String why) => Tooltip(
    message: '${i.url}\n$why',
    child: Container(
      key: const Key('readme-image-blocked'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              i.alt.isEmpty ? why : '${i.alt} ($why)',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}

/// An image of the archive (animated GIFs play).
class _ArchiveImage extends StatelessWidget {
  final Future<Uint8List> future;
  final MdImage image;
  final Widget Function(String why) placeholder;
  const _ArchiveImage({
    super.key,
    required this.future,
    required this.image,
    required this.placeholder,
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: future,
    builder: (context, snap) {
      if (snap.hasError) return placeholder('can not be read');
      final data = snap.data;
      final w = image.width?.toDouble();
      final h = image.height?.toDouble();
      if (data == null) {
        return SizedBox(width: w ?? 24, height: h ?? 24);
      }
      return Semantics(
        label: image.alt,
        image: true,
        child: Tooltip(
          message: image.title ?? image.alt,
          child: Image.memory(
            data,
            key: const Key('readme-image'),
            width: w,
            height: h,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder('not an image'),
          ),
        ),
      );
    },
  );
}
