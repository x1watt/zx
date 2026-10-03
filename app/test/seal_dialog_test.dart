// Writing seals from the app (dialogs/seal_dialog.dart): activating with
// a key, and signing a generation that adds a maintainer, both through
// browser_page.dart's manageSeal and the status bar badge that follows.

import 'dart:async';
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
  final admin = Uint8List.fromList(List.generate(32, (i) => i + 11));
  final maint = Uint8List.fromList(List.generate(32, (i) => i + 61));

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_sealwrite_');
    tree = p.join(tmp.path, 'input', 'demo');
    Directory(tree).createSync(recursive: true);
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

  testWidgets('Seal... activates sealing and the badge follows', (
    tester,
  ) async {
    final a = (await tester.runAsync(
      () => ZxArchive.create(p.join(tmp.path, 'plain.zx'), [
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
    final st = key.currentState!;
    st.showArchive(a);
    await tester.pump();
    expect(find.byKey(const Key('seal-badge')), findsNothing);

    unawaited(st.manageSeal());
    await settle(tester, find.byKey(const Key('manage-seal-dialog')));
    expect(find.text('Activate'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('seal-key')),
      nsecEncode(admin),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('seal-submit')));
    await tester.pump();

    await settle(tester, find.byKey(const Key('seal-badge')));
    expect(find.text('Sealed'), findsOneWidget);

    final seals = await tester.runAsync(() => a.seals());
    expect(seals!.single.policy!.admin, publicKeyOf(admin));
    await tester.runAsync(() => a.close());
  });

  testWidgets('Seal... adds a maintainer in one signed generation', (
    tester,
  ) async {
    final a = (await tester.runAsync(
      () => ZxArchive.create(
        p.join(tmp.path, 'sealed.zx'),
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

    unawaited(st.manageSeal());
    await settle(tester, find.byKey(const Key('manage-seal-dialog')));
    expect(find.text('Sign'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('seal-key')),
      nsecEncode(admin),
    );
    await tester.enterText(
      find.byKey(const Key('seal-add-maintainer')),
      npubEncode(publicKeyOf(maint)),
    );
    await tester.tap(find.byKey(const Key('seal-add-maintainer-go')));
    await tester.pump();
    expect(
      find.textContaining(npubEncode(publicKeyOf(maint)).substring(0, 12)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('seal-submit')));
    await tester.pump();
    await settle(tester, find.text('Sealed generation 2'));

    final seals = await tester.runAsync(() => a.seals());
    expect(seals!.last.policy!.maintainers.single, publicKeyOf(maint));
    await tester.runAsync(() => a.close());
  });

  testWidgets('Seal... removes a maintainer', (tester) async {
    final a = (await tester.runAsync(
      () => ZxArchive.create(
        p.join(tmp.path, 'withmaint.zx'),
        [ZxSource(tree)],
        options: ZxOptions(signKey: nsecEncode(admin)),
        overwrite: true,
      ),
    ))!;
    // sets up a maintainer directly through the engine: the UI test below
    // only has to prove it can remove one, not add it again
    await tester.runAsync(
      () => a.sign(
        nsecEncode(admin),
        addMaintainers: [npubEncode(publicKeyOf(maint))],
      ),
    );
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

    unawaited(st.manageSeal());
    await settle(tester, find.byKey(const Key('manage-seal-dialog')));
    final maintTile = find.byKey(
      Key('seal-maintainer-${npubEncode(publicKeyOf(maint))}'),
    );
    expect(maintTile, findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('seal-key')),
      nsecEncode(admin),
    );
    await tester.tap(
      find.descendant(of: maintTile, matching: find.byIcon(Icons.close)),
    );
    await tester.pump();
    expect(maintTile, findsNothing);
    expect(find.text('none'), findsOneWidget);

    await tester.tap(find.byKey(const Key('seal-submit')));
    await tester.pump();
    await settle(tester, find.text('Sealed generation 3'));

    final seals = await tester.runAsync(() => a.seals());
    expect(seals!.last.policy!.maintainers, isEmpty);
    await tester.runAsync(() => a.close());
  });

  testWidgets('Seal... hands over the admin role to a key it holds', (
    tester,
  ) async {
    final newAdmin = Uint8List.fromList(List.generate(32, (i) => i + 111));
    final a = (await tester.runAsync(
      () => ZxArchive.create(
        p.join(tmp.path, 'handover.zx'),
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

    unawaited(st.manageSeal());
    await settle(tester, find.byKey(const Key('manage-seal-dialog')));
    // the admin section only shows while sealing is active
    expect(find.byKey(const Key('seal-new-admin')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('seal-key')),
      nsecEncode(admin),
    );
    await tester.enterText(
      find.byKey(const Key('seal-new-admin')),
      npubEncode(publicKeyOf(newAdmin)),
    );
    await tester.enterText(
      find.byKey(const Key('seal-new-admin-key')),
      nsecEncode(newAdmin),
    );
    await tester.tap(find.byKey(const Key('seal-submit')));
    await tester.pump();
    await settle(tester, find.text('Sealed generation 2'));

    final seals = await tester.runAsync(() => a.seals(full: true));
    expect(seals!.last.policy!.admin, publicKeyOf(newAdmin));
    await tester.runAsync(() => a.close());
  });
}
