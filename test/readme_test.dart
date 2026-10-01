// Tests of the archive README (docs/readme.md): the markdown parser, the
// link policy (everything shown comes from the archive), the lookup in
// ZxArchive and the `zx readme` command.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/main.dart';
import 'package:zx/zx.dart';

List<MdBlock> md(String s) => parseMarkdown(s).blocks;

List<MdInline> para(String s) => (md(s).single as MdParagraph).text;

ReadmeTarget img(String url, [String base = '']) =>
    classifyReadmeUrl(url, baseDir: base, isImage: true);

ReadmeTarget link(String url, [String base = '']) =>
    classifyReadmeUrl(url, baseDir: base, isImage: false);

void main() {
  group('markdown blocks', () {
    test('headings and slugs', () {
      final b = md('# Hello *World*\n\nSub\n---\n\n## Hello World\n');
      final h = b.whereType<MdHeading>().toList();
      expect([for (final x in h) x.level], [1, 2, 2]);
      expect(
          [for (final x in h) x.slug], ['hello-world', 'sub', 'hello-world-1']);
      expect(mdPlainText(h.first.text), 'Hello World');
    });

    test('code blocks', () {
      final b = md('```dart\nmain() {}\n```\n\n    indented\n');
      expect((b[0] as MdCodeBlock).info, 'dart');
      expect((b[0] as MdCodeBlock).code, 'main() {}');
      expect((b[1] as MdCodeBlock).info, isNull);
      expect((b[1] as MdCodeBlock).code, 'indented');
    });

    test('lists, tasks and quotes', () {
      final b = md('- a\n- [x] b\n  - c\n\n1. one\n\n2. two\n\n> q\nlazy\n');
      final ul = b[0] as MdList;
      expect(ul.ordered, isFalse);
      expect(ul.tight, isTrue);
      expect(ul.items[1].checked, isTrue);
      expect(ul.items[1].blocks.last, isA<MdList>());
      final ol = b[1] as MdList;
      expect(ol.ordered, isTrue);
      expect(ol.tight, isFalse);
      final q = b[2] as MdQuote;
      expect(mdPlainText((q.blocks.single as MdParagraph).text), 'q lazy');
    });

    test('tables', () {
      final t =
          md('| a | b |\n|:--|--:|\n| 1 | **2** |\n| 3 |\n').single as MdTable;
      expect(t.aligns, [MdAlign.left, MdAlign.right]);
      expect(t.rows.length, 2);
      expect(t.rows[1].length, 2);
      expect(t.rows[0][1].single, isA<MdStrong>());
    });

    test('rule and size limit', () {
      expect(md('***\n').single, isA<MdRule>());
      final d = parseMarkdown('a\n' * 100, maxChars: 50);
      expect(d.truncated, isTrue);
    });
  });

  group('markdown inlines', () {
    test('emphasis, code, strike', () {
      final p = para('*a* **b** _c_ ~~d~~ `e` a*b*c snake_case_name');
      expect(p.whereType<MdEmphasis>().length, 3);
      expect(p.whereType<MdStrong>().length, 1);
      expect(p.whereType<MdStrike>().length, 1);
      expect(p.whereType<MdCode>().single.code, 'e');
      expect(mdPlainText(p), contains('snake_case_name'));
    });

    test('links, images, references, autolinks', () {
      final p = para('[a](x.md "t") ![i](img/p.gif) [r] <https://h.io> '
          'see https://example.com/x).\n\n[r]: https://ref.io');
      final links = p.whereType<MdLink>().toList();
      expect([for (final l in links) l.url],
          ['x.md', 'https://ref.io', 'https://h.io', 'https://example.com/x']);
      expect(links.first.title, 't');
      final i = p.whereType<MdImage>().single;
      expect(i.url, 'img/p.gif');
      expect(i.alt, 'i');
    });

    test('raw HTML is not interpreted, <img> and <br> are kept', () {
      final p = para('<p align="center"><b>x</b><br>'
          '<img src="logo.png" alt="L" width="120"><script>y</script></p>');
      expect(mdPlainText(p), 'x Ly');
      final i = p.whereType<MdImage>().single;
      expect(i.url, 'logo.png');
      expect(i.width, 120);
      expect(p.whereType<MdBreak>().single.hard, isTrue);
    });

    test('escapes, entities and hard breaks', () {
      final p = para('\\*no\\* &amp; &copy; a  \nb\\\nc');
      expect(mdPlainText(p), '*no* & \u00A9 a b c');
      expect(p.whereType<MdBreak>().where((b) => b.hard).length, 2);
    });
  });

  group('link policy', () {
    test('paths inside the archive', () {
      final a = img('img/x.gif', 'docs') as ReadmeInternal;
      expect(a.path, 'docs/img/x.gif');
      expect((img('/img/x.gif', 'docs') as ReadmeInternal).path, 'img/x.gif');
      expect((img('../x.gif', 'docs') as ReadmeInternal).path, 'x.gif');
      expect((img('a%20b.png') as ReadmeInternal).path, 'a b.png');
      final l = link('docs/README.md#use') as ReadmeInternal;
      expect(l.path, 'docs/README.md');
      expect(l.fragment, 'use');
      expect((link('./') as ReadmeInternal).path, '');
    });

    test('nothing outside the archive is shown', () {
      for (final u in [
        'https://x.org/a.png',
        'http://x.org/a.gif',
        '//cdn.x/a.png',
        'data:image/png;base64,AAAA',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'C:/a.png',
      ]) {
        expect(img(u), isA<ReadmeBlocked>(), reason: u);
      }
      expect((img('../a.png') as ReadmeBlocked).reason,
          ReadmeBlockReason.escapesArchive);
    });

    test('external links are links only', () {
      expect(link('https://example.com'), isA<ReadmeExternal>());
      expect(link('mailto:a@b.c'), isA<ReadmeExternal>());
      expect(link('file:///etc'), isA<ReadmeBlocked>());
      expect(link('javascript:x'), isA<ReadmeBlocked>());
      expect(link('#usage'), isA<ReadmeAnchor>());
    });

    test('checkReadme', () {
      final doc = parseMarkdown('# Use\n![a](a.gif) ![b](https://x/b.png) '
          '[c](c.txt) [d](#use) [e](#nope) [f](https://home) [g](../../x)');
      final issues = checkReadme(doc, 'sub', (p) => p == 'sub/a.gif');
      expect([
        for (final i in issues) i.kind
      ], [
        ReadmeIssueKind.externalImage,
        ReadmeIssueKind.missingEntry,
        ReadmeIssueKind.missingAnchor,
        ReadmeIssueKind.escapesArchive,
      ]);
    });

    test('pickReadme', () {
      expect(pickReadme(['a.txt', 'readme', 'Readme.md']), 'Readme.md');
      expect(pickReadme(['README.txt', 'readme.markdown']), 'readme.markdown');
      expect(pickReadme(['readme.md', 'README.md']), 'README.md');
      expect(pickReadme(['notes.md']), isNull);
    });
  });

  group('archives', () {
    late Directory tmp;
    late String arc;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('zx_readme_');
      final p = Directory('${tmp.path}/proj')..createSync();
      Directory('${p.path}/img').createSync();
      Directory('${p.path}/docs').createSync();
      File('${p.path}/README.md')
          .writeAsStringSync('# Demo\n\n![demo](img/demo.gif)\n[docs](docs/) '
              '[home](https://example.com)\n');
      File('${p.path}/img/demo.gif')
          .writeAsBytesSync(ascii.encode('GIF89a') + Uint8List(10));
      File('${p.path}/docs/readme.MD')
          .writeAsStringSync('Docs\n\n![x](https://x.org/x.png)\n');
      arc = '${tmp.path}/a.zx';
      await ZxArchive.create(arc, [
        ZxSource('${p.path}/README.md'),
        ZxSource('${p.path}/img'),
        ZxSource('${p.path}/docs'),
      ]);
    });

    tearDownAll(() => tmp.deleteSync(recursive: true));

    test('ZxArchive.readme', () async {
      final a = await ZxArchive.open(arc);
      try {
        expect(a.readmeIn('')?.path, 'README.md');
        expect(a.readmeIn('docs')?.path, 'docs/readme.MD');
        expect(a.readmeIn('img'), isNull);
        final r = (await a.readme())!;
        expect(r.baseDir, '');
        expect(r.issues, isEmpty);
        expect(r.doc.blocks.first, isA<MdHeading>());
        final d = (await a.readme(dir: 'docs'))!;
        expect(d.baseDir, 'docs');
        expect(d.issues.single.kind, ReadmeIssueKind.externalImage);
      } finally {
        await a.close();
      }
    });

    Future<(int, String)> run(List<String> args) async {
      final out = BytesBuilder();
      final code = await runSevenZipCli(args,
          stdout: out.add, stderr: out.add, workingDirectory: tmp.path);
      return (code, utf8.decode(out.takeBytes()));
    }

    test('zx readme', () async {
      var (code, out) = await run(['readme', 'a.zx']);
      expect(code, 0);
      expect(out, startsWith('# Demo\n'));
      (code, out) = await run(['readme', 'a.zx', 'docs']);
      expect(code, 0);
      expect(out, startsWith('Docs\n'));
      (code, out) = await run(['readme', 'a.zx', 'img']);
      expect(code, 1);
      expect(out, contains('no README'));
    });

    test('zx readme -check', () async {
      var (code, out) = await run(['readme', '-check', 'a.zx']);
      expect(code, 0);
      expect(out, 'README.md: ok\n');
      (code, out) = await run(['readme', '-check', '-all', 'a.zx']);
      expect(code, 1);
      expect(out, contains('docs/readme.MD: image "https://x.org/x.png"'));
    });
  });
}
