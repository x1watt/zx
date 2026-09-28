// Widget tests of the explorer on temporary folders: navigation, the path
// typed in the path bar, hidden files, entering archives as folders,
// copy and paste between the file system and the archives (extract, add),
// the conflict dialog, rename, the trash, the recursive search and the
// phone layout. The file work runs in worker isolates, so the tests wait
// for it in tester.runAsync.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/app.dart';
import 'package:zx_app/src/db_session.dart' show nsDateText;
import 'package:zx_app/src/fs/fs_model.dart';
import 'package:zx_app/src/fs/fs_ops.dart';
import 'package:zx_app/src/services.dart';
import 'package:zx_app/src/ui/browser_page.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  late String root;
  late String tree;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zx_explorer_');
    root = tmp.path;
    tree = makeTree(p.join(root, 'src'));
    void f(String rel, String text) {
      final file = File(p.join(root, rel));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }

    f('docs/a.txt', 'alpha\n');
    f('docs/b.txt', 'beta\n');
    f('sub/deep/needle.txt', 'found me\n');
    f('.hidden', 'secret\n');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> make(WidgetTester tester, String name, {String? format}) async {
    await tester.runAsync(
      () => ZxArchive.create(
        p.join(root, name),
        [ZxSource(tree)],
        format: format,
        overwrite: true,
      ).then((a) => a.close()),
    );
  }

  /// Lets the worker isolates run until [done] (or 20 seconds).
  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(done(), isTrue, reason: 'timed out');
  }

  /// Waits until the folder is read (the listing runs in a worker).
  Future<void> settle(WidgetTester tester, BrowserPageState st) async {
    await tester.pump();
    await waitFor(tester, () => !st.fs.loading);
    await tester.pump();
  }

  Future<BrowserPageState> pumpApp(
    WidgetTester tester,
    AppServices s, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<BrowserPageState>();
    await tester.pumpWidget(ZxApp(services: s, browserKey: key));
    await tester.pump();
    final st = key.currentState!;
    await settle(tester, st);
    return st;
  }

  List<String> fsRows(BrowserPageState st) => [
    for (final e in st.fs.rows) e.name,
  ];

  Future<void> doubleTap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.tap(f);
    await tester.pump();
  }

  Future<void> key(
    WidgetTester tester,
    LogicalKeyboardKey k, {
    bool ctrl = false,
    bool shift = false,
  }) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(k);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('start: the home folder, the places, the free space', (
    tester,
  ) async {
    final s = testServices(root);
    s.settings.addRecent('/x/old.7z');
    final st = await pumpApp(tester, s);
    expect(st.fs.dir, root);
    expect(fsRows(st), ['docs', 'src', 'sub', 'tmp']);
    // the left pane shows the folder tree by default
    expect(find.byKey(const Key('fs-folder-tree')), findsOneWidget);
    // the places are one selector away
    s.settings.leftPane = 'places';
    await tester.pump();
    await waitFor(
      tester,
      () => find.byKey(Key('place:$root')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('recent:/x/old.7z')), findsOneWidget);
    s.settings.leftPane = 'tree';
    await tester.pump();
    await waitFor(
      tester,
      () => find.textContaining('250 GB free').evaluate().isNotEmpty,
    );
    expect(find.textContaining('4 items'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('navigate: folders, back, up, crumbs, typed path, hidden', (
    tester,
  ) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    await doubleTap(tester, find.byKey(ValueKey('fsrow:$root/docs')));
    await settle(tester, st);
    expect(st.fs.dir, p.join(root, 'docs'));
    expect(fsRows(st), ['a.txt', 'b.txt']);

    await key(tester, LogicalKeyboardKey.backspace);
    await settle(tester, st);
    expect(st.fs.dir, root);
    expect(st.fs.selection, {p.join(root, 'docs')});

    await tester.tap(find.byKey(const Key('nav-back')));
    await settle(tester, st);
    expect(st.fs.dir, p.join(root, 'docs'));

    // a crumb of the path
    await tester.tap(find.byKey(Key('fscrumb:$root')));
    await settle(tester, st);
    expect(st.fs.dir, root);

    // Ctrl+L: the path as text
    await key(tester, LogicalKeyboardKey.keyL, ctrl: true);
    expect(find.byKey(const Key('path-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('path-field')),
      p.join(root, 'sub', 'deep'),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await waitFor(tester, () => st.fs.dir == p.join(root, 'sub', 'deep'));
    await settle(tester, st);
    expect(fsRows(st), ['needle.txt']);

    // hidden files
    await tester.tap(find.byKey(Key('fscrumb:$root')));
    await settle(tester, st);
    expect(fsRows(st), isNot(contains('.hidden')));
    await key(tester, LogicalKeyboardKey.keyH, ctrl: true);
    expect(fsRows(st), contains('.hidden'));
    expect(s.settings.showHidden, isTrue);

    // sort by size: the folders keep their name order, the files follow
    // by their own size
    await tester.tap(find.byKey(const Key('fscol-size')));
    await tester.pump();
    expect(st.fs.sort, FsSort.size);
    expect(fsRows(st).take(4), ['docs', 'src', 'sub', 'tmp']);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('archives open as folders; the crumbs go on inside', (
    tester,
  ) async {
    await make(tester, 'arc.7z');
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    await doubleTap(tester, find.byKey(ValueKey('fsrow:$root/arc.7z')));
    await waitFor(tester, () => st.model != null);
    expect(st.model!.displayName, 'arc.7z');
    // the folders of the file system lead to the archive
    expect(find.byKey(Key('fscrumb:$root')), findsOneWidget);
    expect(find.byKey(const Key('crumb:')), findsOneWidget);
    await doubleTap(tester, find.byKey(const ValueKey('row:project')));
    expect(st.model!.dir, 'project');
    expect(find.byKey(const Key('crumb:project')), findsOneWidget);

    // Back to the top of the archive, then out of it, the archive selected
    await tester.tap(find.byKey(const Key('nav-back')));
    await tester.pump();
    expect(st.model!.dir, '');
    await tester.tap(find.byKey(const Key('nav-back')));
    await settle(tester, st);
    expect(st.model, isNull);
    expect(st.fs.dir, root);
    expect(st.fs.selection, {p.join(root, 'arc.7z')});

    // a typed path that goes on inside an archive
    await key(tester, LogicalKeyboardKey.keyL, ctrl: true);
    await tester.enterText(
      find.byKey(const Key('path-field')),
      p.join(root, 'arc.7z', 'project', 'docs'),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await waitFor(tester, () => st.model != null);
    expect(st.model!.dir, 'project/docs');

    // a crumb of the file system leaves the archive
    await tester.tap(find.byKey(Key('fscrumb:$root')));
    await settle(tester, st);
    expect(st.model, isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('copy from an archive, paste in a folder: extract', (
    tester,
  ) async {
    await make(tester, 'arc.7z');
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    await doubleTap(tester, find.byKey(ValueKey('fsrow:$root/arc.7z')));
    await waitFor(tester, () => st.model != null);
    await doubleTap(tester, find.byKey(const ValueKey('row:project')));
    await tester.tap(find.byKey(const ValueKey('row:project/docs')));
    await tester.pump(const Duration(milliseconds: 500));
    await key(tester, LogicalKeyboardKey.keyC, ctrl: true);
    expect(st.clipboard!.items, ['project/docs']);
    expect(st.clipboard!.relDir, 'project');

    // out of the archive (its handle stays open for the clipboard)
    st.closeArchive();
    await settle(tester, st);
    expect(st.model, isNull);
    await key(tester, LogicalKeyboardKey.keyV, ctrl: true);
    await waitFor(
      tester,
      () => File(p.join(root, 'docs', 'guide.txt')).existsSync(),
    );
    expect(File(p.join(root, 'docs', 'deep', 'x.txt')).existsSync(), isTrue);
    // docs existed: the files merge into it
    expect(File(p.join(root, 'docs', 'a.txt')).existsSync(), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('copy and paste files: keep both, cut moves', (tester) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    await doubleTap(tester, find.byKey(ValueKey('fsrow:$root/docs')));
    await settle(tester, st);
    await tester.tap(find.byKey(ValueKey('fsrow:$root/docs/a.txt')));
    await tester.pump(const Duration(milliseconds: 500));
    await key(tester, LogicalKeyboardKey.keyC, ctrl: true);
    await key(tester, LogicalKeyboardKey.backspace);
    await settle(tester, st);

    expect(st.clipboard?.fsPaths, [p.join(root, 'docs', 'a.txt')]);
    expect(st.fs.dir, root);
    await key(tester, LogicalKeyboardKey.keyV, ctrl: true);
    await waitFor(
      tester,
      () => st.fs.selection.contains(p.join(root, 'a.txt')),
    );

    // again: the name exists
    await key(tester, LogicalKeyboardKey.keyV, ctrl: true);
    await waitFor(
      tester,
      () => find.byKey(const Key('conflict-dialog')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const Key('conflict-rename')));
    await tester.pump();
    await waitFor(tester, () => File(p.join(root, 'a (2).txt')).existsSync());

    // cut and paste in another folder: a move
    await waitFor(
      tester,
      () => st.fs.selection.contains(p.join(root, 'a (2).txt')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(ValueKey('fsrow:$root/a.txt')));
    await tester.pump(const Duration(milliseconds: 500));
    await key(tester, LogicalKeyboardKey.keyX, ctrl: true);
    expect(st.clipboard!.cut, isTrue);
    await doubleTap(tester, find.byKey(ValueKey('fsrow:$root/sub')));
    await settle(tester, st);
    await key(tester, LogicalKeyboardKey.keyV, ctrl: true);
    await waitFor(
      tester,
      () => File(p.join(root, 'sub', 'a.txt')).existsSync(),
    );
    expect(File(p.join(root, 'a.txt')).existsSync(), isFalse);
    await waitFor(tester, () => st.clipboard == null);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('paste files into an archive: add, replace', (tester) async {
    await make(tester, 'w.zip', format: 'zip');
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    await tester.tap(find.byKey(ValueKey('fsrow:$root/docs')));
    await tester.pump(const Duration(milliseconds: 500));
    await key(tester, LogicalKeyboardKey.keyC, ctrl: true);
    await doubleTap(tester, find.byKey(ValueKey('fsrow:$root/w.zip')));
    await waitFor(tester, () => st.model != null);
    await key(tester, LogicalKeyboardKey.keyV, ctrl: true);
    await waitFor(tester, () => st.model!.archive['docs/a.txt'] != null);
    expect(st.model!.selection, {'docs'});

    // again: the folder exists in the archive
    await key(tester, LogicalKeyboardKey.keyV, ctrl: true);
    await waitFor(
      tester,
      () => find.byKey(const Key('conflict-dialog')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('conflict-rename')), findsNothing);
    await tester.tap(find.byKey(const Key('conflict-skip')));
    await tester.pump();
    expect(st.model!.archive['docs/b.txt'], isNotNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('rename (F2), new folder, move to the trash', (tester) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    await doubleTap(tester, find.byKey(ValueKey('fsrow:$root/docs')));
    await settle(tester, st);
    await tester.tap(find.byKey(ValueKey('fsrow:$root/docs/a.txt')));
    await tester.pump(const Duration(milliseconds: 500));
    await key(tester, LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'z.txt');
    await tester.tap(find.text('Rename').last);
    await tester.pump();
    await waitFor(
      tester,
      () => st.fs.selection.contains(p.join(root, 'docs', 'z.txt')),
    );

    await key(tester, LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to trash'));
    await tester.pump();
    final trash = p.join(root, '.local', 'share', 'Trash');
    await waitFor(
      tester,
      () => File(p.join(trash, 'files', 'z.txt')).existsSync(),
    );
    expect(File(p.join(root, 'docs', 'z.txt')).existsSync(), isFalse);
    final info = File(p.join(trash, 'info', 'z.txt.trashinfo'));
    expect(info.readAsStringSync(), contains('Path=$root/docs/z.txt'));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('recursive search below the folder', (tester) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    await tester.tap(find.byKey(const Key('search-recursive')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('filter')), 'needle');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await waitFor(tester, () => st.fs.inSearch && !st.fs.searching);
    expect(fsRows(st), ['needle.txt']);
    expect(find.text(p.join('sub', 'deep', 'needle.txt')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(st.fs.inSearch, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('phone: drawer, long press selection, paste bar', (tester) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s, size: const Size(400, 800));
    expect(find.byKey(const Key('tile-list')), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('place:$root')), findsOneWidget);
    await tester.tap(find.byKey(Key('place:$root')));
    await tester.pumpAndSettle();
    await settle(tester, st);

    await tester.longPress(find.byKey(ValueKey('row:$root/docs')));
    await tester.pump();
    expect(find.byKey(const Key('selection-bar')), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sel-copy')));
    await tester.pump();
    // a tap in the selection mode adds to it; clearing leaves it
    expect(find.byKey(const Key('selection-bar')), findsOneWidget);
    st.fs.clearSelection();
    await tester.pump();
    expect(find.byKey(const Key('paste-here')), findsOneWidget);

    // a tap opens
    await tester.tap(find.byKey(ValueKey('row:$root/sub')));
    await settle(tester, st);
    expect(st.fs.dir, p.join(root, 'sub'));
    await tester.tap(find.byKey(const Key('paste-here')));
    await tester.pump();
    await waitFor(
      tester,
      () => File(p.join(root, 'sub', 'docs', 'a.txt')).existsSync(),
    );
    await tester.pump(const Duration(seconds: 5));
  });

  test('file operations: copy with conflicts, delete', () async {
    final dst = Directory(p.join(root, 'out'))..createSync();
    File(p.join(dst.path, 'a.txt')).writeAsStringSync('old');
    final asked = <String>[];
    final r = await runFsOp(
      FsOpKind.copy,
      [p.join(root, 'docs')],
      destDir: dst.path,
      onConflict: (c) async {
        asked.add(p.basename(c.target));
        return const FsConflictAnswer(FsConflictAction.overwrite);
      },
    );
    expect(r.ok, isTrue);
    expect(asked, isEmpty); // docs did not exist in out
    final r2 = await runFsOp(
      FsOpKind.copy,
      [p.join(root, 'docs', 'a.txt')],
      destDir: dst.path,
      onConflict: (c) async {
        asked.add(p.basename(c.target));
        return const FsConflictAnswer(FsConflictAction.overwrite);
      },
    );
    expect(r2.done, 1);
    expect(asked, ['a.txt']);
    expect(File(p.join(dst.path, 'a.txt')).readAsStringSync(), 'alpha\n');
    final r3 = await runFsOp(FsOpKind.delete, [dst.path]);
    expect(r3.done, 1);
    expect(dst.existsSync(), isFalse);
    expect(await sha256OfFile(p.join(root, 'docs', 'a.txt')), hasLength(64));
    expect(compareNames('file2', 'file10'), lessThan(0));
  });

  test('DATETIME values are shown in local time', () {
    const ns = 1790000000123000000;
    final d = DateTime.fromMicrosecondsSinceEpoch(ns ~/ 1000);
    String two(int x) => x.toString().padLeft(2, '0');
    expect(
      nsDateText(ns),
      '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}.123',
    );
  });
}
