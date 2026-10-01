// Widget tests of the explorer on temporary folders: navigation, the path
// typed in the path bar, hidden files, entering archives as folders,
// copy and paste between the file system and the archives (extract, add),
// the conflict dialog, rename, the trash, the recursive search and the
// phone layout. The file work runs in worker isolates, so the tests wait
// for it in tester.runAsync.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/app.dart';
import 'package:zx_app/src/db_session.dart' show nsDateText;
import 'package:zx_app/src/fs/fs_model.dart';
import 'package:zx_app/src/fs/fs_ops.dart';
import 'package:zx_app/src/ui/thumbnail_cache.dart';
import 'package:zx_app/src/ui/views.dart';
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
    f('.hidden-folder/inside.txt', 'hidden folder contents\n');
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

  /// A press and a release with the mouse, the way a person clicks: a
  /// press, a frame or two, a hand that moves [drift] pixels and a
  /// release. Touch taps are not the same code path: a mouse drag starts
  /// after one pixel, a touch one waits for the slop.
  Future<void> mouseClick(
    WidgetTester tester,
    Finder f, {
    Offset drift = Offset.zero,
  }) async {
    final g = await tester.startGesture(
      tester.getCenter(f),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (drift != Offset.zero) {
      await g.moveBy(drift);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 30));
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

  testWidgets('a click moves nothing: the actions are in the context menu', (
    tester,
  ) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    final row = find.byKey(ValueKey('fsrow:$root/docs'));
    final before = tester.getTopLeft(row);
    // no action bar: one that pops in under the pointer pushes the rows
    // down, so the file under the cursor stops being the file clicked
    expect(find.byKey(const Key('selection-actions')), findsNothing);
    expect(find.byKey(const Key('clip-clear')), findsNothing);
    await tester.tap(row);
    await tester.pump();
    expect(st.fs.selection, {p.join(root, 'docs')});
    expect(find.byKey(const Key('selection-actions')), findsNothing);
    expect(
      tester.getTopLeft(row),
      before,
      reason: 'the rows must not move when a file is clicked',
    );

    // everything the bar had is in the right-click menu
    await tester.tapAt(
      tester.getCenter(row) + const Offset(2, 0),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    for (final id in [
      'cut',
      'copy',
      'paste',
      'compress',
      'rename',
      'delete',
      'properties',
    ]) {
      expect(find.byKey(Key('menu-$id')), findsOneWidget, reason: id);
    }
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a click with a shaky hand does not move a folder', (
    tester,
  ) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    final row = find.byKey(ValueKey('fsrow:$root/docs'));
    // a real click is never pixel perfect: a mouse drag starts after one
    // pixel, so the click must not be taken for a drop of the folder
    final g = await tester.startGesture(
      tester.getCenter(row),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await g.moveBy(const Offset(2, 1));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(Directory(p.join(root, 'docs')).existsSync(), isTrue);
    expect(File(p.join(root, 'docs/a.txt')).existsSync(), isTrue);
    expect(fsRows(st), contains('docs'));
    expect(st.fs.dir, root, reason: 'the click must not open the folder');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a click near the edge of a row drops nothing', (tester) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    // 'docs' has the folder 'src' under it. A press three pixels above
    // the bottom edge of the row, a hand that drifts four pixels down:
    // the release lands on 'src', and a mouse drag that starts after one
    // pixel would take 'docs' into it.
    final r = tester.getRect(find.byKey(ValueKey('fsrow:$root/docs')));
    final g = await tester.startGesture(
      Offset(r.left + 40, r.bottom - 3),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveBy(const Offset(0, 4));
    await tester.pump(const Duration(milliseconds: 30));
    await g.up();
    await tester.pumpAndSettle();
    expect(Directory(p.join(root, 'docs')).existsSync(), isTrue);
    expect(Directory(p.join(root, 'src', 'docs')).existsSync(), isFalse);
    expect(st.fs.dir, root, reason: 'the click must not open the folder');
    expect(fsRows(st), containsAll(['docs', 'src']));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a click on a selected row drops nothing', (tester) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    // The click that selects the row is a drag too, and the transfer of
    // it is built, so only the travelled distance keeps the click of a
    // shaky hand from taking the item where the release lands.
    await mouseClick(tester, find.byKey(ValueKey('fsrow:$root/docs')));
    expect(st.fs.selection, ['$root/docs'], reason: 'the click selected it');
    final r = tester.getRect(find.byKey(ValueKey('fsrow:$root/docs')));
    final g = await tester.startGesture(
      Offset(r.left + 40, r.bottom - 3),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveBy(const Offset(0, 4));
    await tester.pump(const Duration(milliseconds: 30));
    await g.up();
    await tester.pumpAndSettle();
    expect(Directory(p.join(root, 'docs')).existsSync(), isTrue);
    expect(Directory(p.join(root, 'src', 'docs')).existsSync(), isFalse);
    expect(fsRows(st), containsAll(['docs', 'src']));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a real drag of a row into the folder below still moves it', (
    tester,
  ) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    final from = tester.getCenter(find.byKey(ValueKey('fsrow:$root/docs')));
    final to = tester.getCenter(find.byKey(ValueKey('fsrow:$root/src')));
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 30));
    for (var i = 1; i <= 12; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    // The move runs in a worker and the tree follows, so both the moved
    // folder and its file, and the listing, are waited for.
    await waitFor(
      tester,
      () =>
          Directory(p.join(root, 'src', 'docs/a.txt')).existsSync() &&
          !Directory(p.join(root, 'docs')).existsSync() &&
          !fsRows(st).contains('docs'),
    );
    expect(Directory(p.join(root, 'docs')).existsSync(), isFalse);
    expect(Directory(p.join(root, 'src', 'docs/a.txt')).existsSync(), isTrue);
    expect(fsRows(st), containsAll(['src', 'sub']));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the mouse opens a folder on the second click, not a move', (
    tester,
  ) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    final row = find.byKey(ValueKey('fsrow:$root/docs'));
    await mouseClick(tester, row);
    await mouseClick(tester, row, drift: const Offset(1, 1));
    await settle(tester, st);
    expect(st.fs.dir, p.join(root, 'docs'));
    expect(fsRows(st), ['a.txt', 'b.txt']);
    // nothing was dropped into a neighbour on the way
    expect(Directory(p.join(root, 'src', 'docs')).existsSync(), isFalse);
    expect(fsRows(st), isNot(contains('docs')));
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
    expect(fsRows(st), isNot(contains('.hidden-folder')));
    await key(tester, LogicalKeyboardKey.keyH, ctrl: true);
    expect(fsRows(st), contains('.hidden'));
    expect(fsRows(st), contains('.hidden-folder'));
    expect(s.settings.showHidden, isTrue);
    await key(tester, LogicalKeyboardKey.keyH, ctrl: true);
    expect(fsRows(st), isNot(contains('.hidden')));
    expect(fsRows(st), isNot(contains('.hidden-folder')));
    expect(s.settings.showHidden, isFalse);

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

  testWidgets('filesystem tree only shows folders and honors hidden setting', (
    tester,
  ) async {
    final s = testServices(root);
    await pumpApp(tester, s);
    await waitFor(
      tester,
      () => find.byKey(Key('fs-tree:$root/docs')).evaluate().isNotEmpty,
    );
    expect(
      find.byKey(Key('fs-tree:${p.join(root, 'docs', 'a.txt')}')),
      findsNothing,
    );
    expect(
      find.byKey(Key('fs-tree:${p.join(root, 'docs', 'b.txt')}')),
      findsNothing,
    );
    expect(
      find.byKey(Key('fs-tree:${p.join(root, '.hidden-folder')}')),
      findsNothing,
    );

    await key(tester, LogicalKeyboardKey.keyH, ctrl: true);
    await waitFor(
      tester,
      () => find
          .byKey(Key('fs-tree:${p.join(root, '.hidden-folder')}'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(Key('fs-tree:${p.join(root, '.hidden-folder')}')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        Key('fs-tree:${p.join(root, '.hidden-folder', 'inside.txt')}'),
      ),
      findsNothing,
    );
  });

  testWidgets('filesystem tree context menu can rename its folder target', (
    tester,
  ) async {
    final s = testServices(root);
    final st = await pumpApp(tester, s);
    final folder = find.byKey(Key('fs-tree:${p.join(root, 'docs')}'));
    await waitFor(tester, () => folder.evaluate().isNotEmpty);

    await tester.tapAt(
      tester.getCenter(folder),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    for (final id in ['cut', 'copy', 'rename', 'delete']) {
      expect(find.byKey(Key('menu-$id')), findsOneWidget, reason: id);
    }

    await tester.tap(find.byKey(const Key('menu-rename')));
    await waitFor(
      tester,
      () => find.byKey(const Key('text-input')).evaluate().isNotEmpty,
    );
    await tester.enterText(find.byKey(const Key('text-input')), 'renamed-docs');
    await tester.tap(find.byKey(const Key('text-input-ok')));
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () => Directory(p.join(root, 'renamed-docs')).existsSync(),
    );
    final renamed = find.byKey(Key('fs-tree:${p.join(root, 'renamed-docs')}'));
    await waitFor(tester, () => renamed.evaluate().isNotEmpty);

    await tester.tapAt(
      tester.getCenter(renamed),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-cut')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(st.clipboard?.cut, isTrue);

    final destination = find.byKey(Key('fs-tree:${p.join(root, 'sub')}'));
    await tester.tapAt(
      tester.getCenter(destination),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump(const Duration(milliseconds: 300));
    final pasteMenu = tester.widget<PopupMenuItem<String>>(
      find.byKey(const Key('menu-paste')).last,
    );
    expect(pasteMenu.enabled, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(st.fs.dir, root);
  });

  test(
    'filesystem selection and lookup stay constant-time after rows build',
    () async {
      final entries = [
        for (var i = 0; i < 10000; i++)
          FsEntry(path: '/files/file$i', name: 'file$i', isDir: false, size: i),
      ];
      final model = FsModel('/files', lister: (_) async => entries);
      await model.reload();
      final rows = model.rows;
      expect(rows, hasLength(entries.length));
      for (var i = 0; i < 1000; i++) {
        final entry = entries[i * 9];
        expect(model.entry(entry.path), same(entry));
        model.click(entry);
        expect(model.cursorIndex, i * 9);
        expect(model.selectedBytes, entry.size);
      }
    },
  );

  testWidgets('grid/tile item handlers use their row data directly', (
    tester,
  ) async {
    final opened = <String>[];
    final clicked = <String>[];
    final item = ViewItem(
      id: 'item',
      name: 'item',
      isDir: false,
      icon: Icons.insert_drive_file,
      color: Colors.blue,
      source: 'source-value',
    );
    final handlers = ViewHandlers(
      onClick: (row, {ctrl = false, shift = false}) => clicked.add(row.id),
      onOpen: (row) => opened.add(row.id),
      onContextMenu: (_, _) {},
    );
    final widget = MaterialApp(
      home: Scaffold(
        body: TileList(
          items: [item],
          selection: const {},
          handlers: handlers,
          thumbnailCache: ThumbnailCache(
            archivePath: p.join(root, 'thumbs.zx'),
            tempDir: root,
          ),
        ),
      ),
    );
    await tester.pumpWidget(widget);
    await tester.tap(find.byKey(const ValueKey('row:item')));
    await tester.pump();
    expect(clicked, ['item']);
    await tester.tap(find.byKey(const ValueKey('row:item')));
    await tester.pump();
    expect(opened, ['item']);
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
