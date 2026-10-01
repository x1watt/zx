// The seals of a .zx archive in the app: the status bar badge, its dialog
// with the full check, and the admin in the README panel.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/app.dart';
import 'package:zx_app/src/ui/browser_page.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  late String tree;
  final admin = Uint8List.fromList(List.generate(32, (i) => i + 7));

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_sealui_');
    tree = p.join(tmp.path, 'input', 'demo');
    Directory(tree).createSync(recursive: true);
    File(p.join(tree, 'README.md')).writeAsStringSync('# Demo\n\nText.\n');
    File(p.join(tree, 'a.txt')).writeAsStringSync('hello\n' * 100);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester, Finder until) async {
    for (var i = 0; i < 100 && until.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('a sealed archive shows its seal and admin', (tester) async {
    final a = (await tester.runAsync(
      () => ZxArchive.create(
        p.join(tmp.path, 's.zx'),
        [ZxSource(tree)],
        options: ZxOptions(signKey: nsecEncode(admin)),
        overwrite: true,
      ),
    ))!;
    final s = testServices(tmp.path);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<BrowserPageState>();
    await tester.pumpWidget(ZxApp(services: s, browserKey: key));
    await tester.pump();
    final st = key.currentState!;
    st.showArchive(a);
    await tester.pump();

    await settle(tester, find.byKey(const Key('seal-badge')));
    expect(find.text('Sealed'), findsOneWidget);

    st.model!.navigate('demo');
    await tester.pump();
    await settle(tester, find.byKey(const Key('readme-admin')));
    final npub = npubEncode(publicKeyOf(admin));
    expect(
      find.textContaining('maintained by ${npub.substring(0, 12)}'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('seal-badge')));
    await settle(tester, find.byKey(const Key('seal-summary')));
    expect(find.byKey(const Key('seal-summary')), findsOneWidget);
    expect(find.textContaining('sealed by $npub'), findsOneWidget);
    await tester.tap(find.byKey(const Key('seal-full-check')));
    await settle(tester, find.text('Every stored byte was checked.'));
    expect(find.text('Every stored byte was checked.'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => a.close());
  });

  testWidgets('an archive that was never sealed has no badge', (tester) async {
    final a = (await tester.runAsync(
      () => ZxArchive.create(p.join(tmp.path, 'u.zx'), [
        ZxSource(tree),
      ], overwrite: true),
    ))!;
    final s = testServices(tmp.path);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<BrowserPageState>();
    await tester.pumpWidget(ZxApp(services: s, browserKey: key));
    await tester.pump();
    key.currentState!.showArchive(a);
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.byKey(const Key('seal-badge')), findsNothing);
    await tester.runAsync(() => a.close());
  });
}
