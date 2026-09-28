// Widget tests of the nested archives, the inner file systems view and the
// zpaq versions, on real archives made with ZxArchive in a temporary
// folder: outer.tar holds inner.zip (the test tree), wrap.tar (a tar that
// holds only inner.zip) and note.txt. The isolate work runs in real time
// between the pumps (see waitFor).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/app.dart';
import 'package:zx_app/src/services.dart';
import 'package:zx_app/src/ui/browser_page.dart';
import 'package:zx_app/src/ui/format_utils.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  late String outer;
  late String zpaq;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('zx_nested_');
    final tree = makeTree(tmp.path);
    final inner = p.join(tmp.path, 'inner.zip');
    await ZxArchive.create(inner, [ZxSource(tree)]);
    final wrap = p.join(tmp.path, 'wrap.tar');
    await ZxArchive.create(wrap, [ZxSource(inner)]);
    final note = File(p.join(tmp.path, 'note.txt'))
      ..writeAsStringSync('just a note\n');
    outer = p.join(tmp.path, 'outer.tar');
    await ZxArchive.create(outer, [
      ZxSource(inner),
      ZxSource(wrap),
      ZxSource(note.path),
    ]);
    // a zpaq archive with two versions: the tree, then one more file
    zpaq = p.join(tmp.path, 'backup.zpaq');
    final z = await ZxArchive.create(zpaq, [ZxSource(tree)]);
    final extra = File(p.join(tmp.path, 'later.txt'))
      ..writeAsStringSync('added in version 2\n');
    await z.add([ZxSource(extra.path)]);
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

  /// Lets the background isolates run (real time) and pumps until [cond].
  Future<void> waitFor(WidgetTester tester, bool Function() cond) async {
    for (var i = 0; i < 200 && !cond(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    expect(cond(), isTrue, reason: 'timed out');
    await tester.pump();
  }

  List<String> rows(WidgetTester tester) {
    final out = <String>[];
    for (final e
        in find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key as ValueKey<String>).value.startsWith('row:'),
            )
            .evaluate()) {
      final v = (e.widget.key as ValueKey<String>).value.substring(4);
      out.add(v.substring(v.lastIndexOf('/') + 1));
    }
    return out;
  }

  /// Why the archive shown can not change (the read-only mark), or null.
  String? readOnly(WidgetTester tester) {
    final f = find.byKey(const Key('read-only'));
    if (f.evaluate().isEmpty) return null;
    return tester.widget<Tooltip>(f).message;
  }

  /// Opens the View part of the header menu.
  Future<void> viewMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('app-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View').last);
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, BrowserPageState st, String path) =>
      tester.runAsync(() async {
        final a = await ZxArchive.open(path);
        st.showArchive(a);
      });

  testWidgets('nested archives: in with Enter, read-only, back out', (
    tester,
  ) async {
    final launcher = FakeLauncher();
    final st = await pumpApp(
      tester,
      testServices(tmp.path, launcher: launcher),
    );
    await open(tester, st, outer);
    await tester.pump();
    expect(rows(tester), ['inner.zip', 'note.txt', 'wrap.tar']);
    final root = st.model!;
    expect(readOnly(tester), isNull);

    // Enter on inner.zip opens it as a nested level
    await tester.tap(find.byKey(const ValueKey('row:inner.zip')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitFor(tester, () => st.model != root);
    final nested = st.model!;
    expect(nested.parent, same(root));
    expect(nested.archive.format, 'zip');
    expect(rows(tester), ['project']);
    expect(BrowserPageState.titleOf(nested), 'outer.tar > inner.zip');
    // the path bar: the archive file, the boundary, the nested archive
    expect(find.byKey(const Key('crumb0:')), findsOneWidget);
    expect(find.byKey(const Key('nest-boundary-1')), findsOneWidget);
    expect(find.byKey(const Key('crumb:')), findsOneWidget);
    // read-only, with the reason
    expect(readOnly(tester), 'Inside a nested archive (read-only)');
    for (final id in ['add', 'delete', 'rename', 'folder']) {
      expect(find.byKey(Key('tool-$id')), findsNothing);
    }
    expect(find.byKey(const Key('tool-extract')), findsOneWidget);
    expect(find.textContaining('read-only'), findsWidgets);

    // folders of the nested archive, then Backspace up and out
    await tester.tap(find.byKey(const ValueKey('row:project')));
    await tester.tap(find.byKey(const ValueKey('row:project')));
    await tester.pump();
    expect(nested.dir, 'project');
    expect(find.byKey(const Key('crumb:project')), findsOneWidget);
    // a crumb of the parent level goes back there
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(nested.dir, '');
    expect(st.model, same(nested));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(st.model, same(root));
    expect(root.selection, {'inner.zip'});
    expect(find.byKey(const Key('nest-boundary-1')), findsNothing);

    // a file that is no archive opens with its program
    await tester.runAsync(() => st.openItem(root.archive['note.txt']!));
    await tester.pump();
    expect(st.model, same(root));
    expect(launcher.files, hasLength(1));
    expect(p.basename(launcher.files.single), 'note.txt');

    // a tar holding only a zip shows the files of the zip (one level)
    await tester.runAsync(() => st.openItem(root.archive['wrap.tar']!));
    await tester.pump();
    final wrap = st.model!;
    expect(wrap.parent, same(root));
    expect(wrap.formats, ['tar', 'zip']);
    expect(wrap.displayName, 'wrap.tar');
    expect(rows(tester), ['project']);
    // the Back button leaves it
    await tester.tap(find.byKey(const Key('nav-back')));
    await tester.pump();
    expect(st.model, same(root));
    expect(root.selection, {'wrap.tar'});

    // inside a nested level, a crumb of the archive file goes back there
    await tester.runAsync(() => st.openItem(root.archive['inner.zip']!));
    await tester.pump();
    expect(st.model!.parent, same(root));
    await tester.tap(find.byKey(const Key('crumb0:')));
    await tester.pump();
    expect(st.model, same(root));
    st.closeArchive();
    await tester.pump();
  });

  testWidgets('inner file systems as folders (View menu), read-only', (
    tester,
  ) async {
    final s = testServices(tmp.path);
    final st = await pumpApp(tester, s);
    await open(tester, st, outer);
    await tester.pump();
    expect(st.model!.archive.flattened, isFalse);

    await viewMenu(tester);
    await tester.tap(find.byKey(const Key('menu-show-inner')).last);
    await tester.pump();
    await waitFor(tester, () => st.model?.archive.flattened ?? false);
    expect(s.settings.showInnerFilesystems, isTrue);
    final m = st.model!;
    // the archives are folders now
    expect(m.archive['inner.zip']!.isDir, isTrue);
    expect(m.archive['inner.zip']!.nestedFormat, 'zip');
    expect(m.archive['wrap.tar/project/README.md'], isNotNull);
    expect(rows(tester), ['inner.zip', 'wrap.tar', 'note.txt']);
    expect(readOnly(tester), 'Inner filesystems are shown (read-only)');
    expect(find.byKey(const Key('tool-add')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('row:inner.zip')));
    await tester.tap(find.byKey(const ValueKey('row:inner.zip')));
    await tester.pump();
    expect(m.dir, 'inner.zip');
    expect(rows(tester), ['project']);

    // and back: the folder of a nested archive does not exist then
    await viewMenu(tester);
    await tester.tap(find.byKey(const Key('menu-show-inner')).last);
    await tester.pump();
    await waitFor(tester, () => !(st.model?.archive.flattened ?? true));
    expect(s.settings.showInnerFilesystems, isFalse);
    expect(st.model!.dir, '');
    expect(rows(tester), ['inner.zip', 'note.txt', 'wrap.tar']);
    st.closeArchive();
    await tester.pump();
  });

  testWidgets('zpaq: the version selector opens older versions read-only', (
    tester,
  ) async {
    final st = await pumpApp(tester, testServices(tmp.path));
    await open(tester, st, zpaq);
    await tester.pump();
    expect(rows(tester), ['project', 'later.txt']);
    expect(find.text('Version 2 of 2'), findsOneWidget);
    expect(readOnly(tester), isNull);

    await tester.tap(find.byKey(const Key('version-picker')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('version:1')), findsOneWidget);
    expect(find.byKey(const Key('version:2')), findsOneWidget);
    expect(find.textContaining('(latest)'), findsOneWidget);
    // the date as YYYY-MM-DD HH:MM
    expect(
      find.textContaining(RegExp(r'^Version \d   \d{4}-\d\d-\d\d \d\d:\d\d')),
      findsNWidgets(2),
    );
    await tester.tap(find.byKey(const Key('version:1')));
    await tester.pump();
    await waitFor(tester, () => st.model?.archive.version == 1);
    final m = st.model!;
    expect(rows(tester), ['project']);
    expect(find.text('Version 1 of 2 (read-only)'), findsOneWidget);
    expect(readOnly(tester), 'An older version is shown (read-only)');
    expect(BrowserPageState.titleOf(m), 'backup.zpaq (version 1 of 2)');
    expect(m.allVersions, hasLength(2));

    // back to the latest
    await tester.tap(find.byKey(const Key('version-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('version:2')));
    await tester.pump();
    await waitFor(tester, () => st.model?.archive.version == 2);
    expect(rows(tester), ['project', 'later.txt']);
    expect(find.text('Version 2 of 2'), findsOneWidget);
    st.closeArchive();
    await tester.pump();

    // with the inner file systems shown, an archive without nested ones
    // opens as itself: versions, and changes allowed
    st.widget.services.settings.showInnerFilesystems = true;
    await tester.runAsync(() => st.openArchive(zpaq));
    await tester.pump();
    expect(st.model!.archive.flattened, isFalse);
    expect(find.text('Version 2 of 2'), findsOneWidget);
    expect(readOnly(tester), isNull);
    st.closeArchive();
    await tester.pump();
  });

  test('icons of images and of the sections of a container', () {
    final cs = ColorScheme.fromSeed(seedColor: Colors.blue);
    const plain = ZxItem(index: 0, path: 'rootfs', isDir: false);
    expect(iconFor(plain, cs).$1, Icons.insert_drive_file_outlined);
    expect(iconFor(plain, cs, inContainer: true).$1, Icons.storage_rounded);
    const img = ZxItem(index: 0, path: 'a/disk.img', isDir: false);
    expect(iconFor(img, cs).$1, Icons.storage_rounded);
    const iso = ZxItem(index: 0, path: 'cd.iso', isDir: false);
    expect(iconFor(iso, cs).$1, Icons.album_outlined);
    const nested = ZxItem(
      index: -1,
      path: 'rootfs',
      isDir: true,
      nestedFormat: 'Ubi',
    );
    expect(iconFor(nested, cs).$1, Icons.snippet_folder_rounded);
  });
}
