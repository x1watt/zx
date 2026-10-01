// The README of an archive folder (docs/readme.md): rendered below the
// items, images only from the archive, links inside the archive navigate,
// links to other places open only after a confirmation.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/app.dart';
import 'package:zx_app/src/services.dart';
import 'package:zx_app/src/ui/browser_page.dart';

import 'helpers.dart';

// a 1x1 GIF
final _gif = base64.decode(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
);

void main() {
  late Directory tmp;
  late String tree;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_readme_');
    tree = p.join(tmp.path, 'input', 'demo');
    void f(String rel, Object data) {
      final file = File(p.join(tree, rel));
      file.parent.createSync(recursive: true);
      data is String
          ? file.writeAsStringSync(data)
          : file.writeAsBytesSync(data as List<int>);
    }

    f(
      'README.md',
      '# Demo title\n\n'
          'Intro text.\n\n'
          '![anim](img/demo.gif)\n\n'
          '![remote](https://example.com/remote.png)\n\n'
          'See [the docs](docs/) and [home page](https://example.com/home).\n',
    );
    f('img/demo.gif', _gif);
    f('docs/guide.txt', 'guide\n');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<BrowserPageState> pumpApp(WidgetTester tester, AppServices s) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<BrowserPageState>();
    await tester.pumpWidget(ZxApp(services: s, browserKey: key));
    await tester.pump();
    return key.currentState!;
  }

  Future<void> settle(WidgetTester tester, Finder until) async {
    for (var i = 0; i < 100 && until.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('README of a folder: archive images only, links', (tester) async {
    final a = (await tester.runAsync(
      () => ZxArchive.create(p.join(tmp.path, 'r.zx'), [
        ZxSource(tree),
      ], overwrite: true),
    ))!;
    final launcher = FakeLauncher();
    final s = testServices(tmp.path, launcher: launcher);
    final st = await pumpApp(tester, s);
    st.showArchive(a);
    await tester.pump();

    // the top of the archive has no README
    expect(find.byKey(const Key('readme-toggle')), findsNothing);
    st.model!.navigate('demo');
    await tester.pump();
    expect(find.byKey(const Key('readme-toggle')), findsOneWidget);
    await settle(tester, find.text('Intro text.'));
    expect(find.text('Intro text.'), findsOneWidget);

    // the image of the archive is shown, the remote one is not fetched
    await settle(tester, find.byKey(const Key('readme-image')));
    expect(find.byKey(const Key('readme-image')), findsOneWidget);
    expect(find.byKey(const Key('readme-image-blocked')), findsOneWidget);
    expect(
      find.textContaining('remote (image from outside the archive)'),
      findsOneWidget,
    );

    // a link to another place asks first
    await tester.tapOnText(find.textRange.ofSubstring('home page'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('readme-link-url')), findsOneWidget);
    await tester.tap(find.byKey(const Key('readme-link-open')));
    await tester.pumpAndSettle();
    expect(launcher.urls, ['https://example.com/home']);

    // a link to a folder of the archive opens it
    await tester.tapOnText(find.textRange.ofSubstring('the docs'));
    await tester.pump();
    expect(st.model!.dir, 'demo/docs');
    expect(find.byKey(const Key('readme-toggle')), findsNothing);

    // the panel can be hidden in the settings
    st.model!.navigate('demo');
    await tester.pump();
    expect(find.byKey(const Key('readme-toggle')), findsOneWidget);
    s.settings.showReadme = false;
    await tester.pump();
    expect(find.byKey(const Key('readme-toggle')), findsNothing);

    await tester.runAsync(() => a.close());
  });

  test('no network code renders a README', () {
    // images come from the archive only: nothing here may fetch
    final root = Directory.current.path;
    final files = [
      File(p.join(root, 'lib', 'src', 'ui', 'readme_view.dart')),
      ...Directory(p.join(root, '..', 'lib', 'src', 'readme'))
          .listSync()
          .whereType<File>(),
    ];
    for (final f in files) {
      final src = f.readAsStringSync();
      for (final bad in [
        'Image.network',
        'NetworkImage',
        'HttpClient',
        'dart:io',
        'package:http',
      ]) {
        expect(src.contains(bad), isFalse, reason: '${f.path}: $bad');
      }
    }
  });
}
