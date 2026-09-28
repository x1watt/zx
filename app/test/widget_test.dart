// Widget tests of the main views on a real archive (made with ZxArchive in
// a temporary folder; the isolate work runs inside tester.runAsync).

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/app.dart';
import 'package:zx_app/src/dialogs/common_dialogs.dart';
import 'package:zx_app/src/dialogs/extract_dialog.dart';
import 'package:zx_app/src/services.dart';
import 'package:zx_app/src/settings.dart';
import 'package:zx_app/src/ui/browser_page.dart';
import 'package:zx_app/src/ui/settings_page.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  late String tree;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_widget_');
    tree = makeTree(tmp.path);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<ZxArchive> make(
    WidgetTester tester,
    String name, {
    String? format,
    ZxOptions options = const ZxOptions(),
  }) async {
    final a = await tester.runAsync(
      () => ZxArchive.create(
        p.join(tmp.path, name),
        [ZxSource(tree)],
        format: format,
        options: options,
        overwrite: true,
      ),
    );
    return a!;
  }

  Future<BrowserPageState> pumpApp(WidgetTester tester, AppServices s) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<BrowserPageState>();
    await tester.pumpWidget(ZxApp(services: s, browserKey: key));
    await tester.pump();
    return key.currentState!;
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

  testWidgets('list, navigate, sort, filter, select', (tester) async {
    final a = await make(tester, 'w.7z');
    final s = testServices(tmp.path);
    final st = await pumpApp(tester, s);
    st.showArchive(a);
    await tester.pump();
    expect(rows(tester), ['project']);
    expect(find.byKey(const Key('tree:project')), findsOneWidget);

    // double click enters the folder
    await tester.tap(find.byKey(const ValueKey('row:project')));
    await tester.tap(find.byKey(const ValueKey('row:project')));
    await tester.pump();
    expect(st.model!.dir, 'project');
    expect(rows(tester), ['docs', 'img', 'src', 'notes.txt', 'README.md']);
    expect(find.byKey(const Key('crumb:project')), findsOneWidget);

    // sort by size: folders first, then the files by size
    await tester.tap(find.byKey(const Key('col-size')));
    await tester.pump();
    expect(rows(tester).sublist(3), ['README.md', 'notes.txt']);
    await tester.tap(find.byKey(const Key('col-size')));
    await tester.pump();
    expect(rows(tester).sublist(3), ['notes.txt', 'README.md']);
    await tester.tap(find.byKey(const Key('col-name')));
    await tester.pump();

    // quick filter
    await tester.enterText(find.byKey(const Key('filter')), 'no');
    await tester.pump();
    expect(rows(tester), ['notes.txt']);
    await tester.enterText(find.byKey(const Key('filter')), '');
    await tester.pump();
    expect(rows(tester).length, 5);

    // click, ctrl click, shift click
    await tester.tap(find.byKey(const ValueKey('row:project/docs')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.byKey(const ValueKey('row:project/notes.txt')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(st.model!.selection, {'project/docs', 'project/notes.txt'});
    expect(find.textContaining('2 of 5 selected'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.byKey(const ValueKey('row:project/README.md')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(st.model!.selection, {'project/notes.txt', 'project/README.md'});

    // keyboard: Ctrl+A, Backspace goes up, back and forward
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(st.model!.selection.length, 5);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(st.model!.dir, '');
    expect(st.model!.selection, {'project'});
    await tester.tap(find.byKey(const Key('nav-back')));
    await tester.pump();
    expect(st.model!.dir, 'project');
    await tester.tap(find.byKey(const Key('nav-forward')));
    await tester.pump();
    expect(st.model!.dir, '');

    // tree navigation
    await tester.tap(find.byKey(const Key('tree:project')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tree:project/docs')));
    await tester.pump();
    expect(st.model!.dir, 'project/docs');
    expect(rows(tester), ['deep', 'guide.txt']);
  });

  testWidgets('context menu and disabled actions of a read only format', (
    tester,
  ) async {
    final src = File(p.join(tmp.path, 'one.txt'))..writeAsStringSync('one\n');
    final a = (await tester.runAsync(
      () => ZxArchive.create(p.join(tmp.path, 'one.txt.xz'), [
        ZxSource(src.path),
      ], overwrite: true),
    ))!;
    final st = await pumpApp(tester, testServices(tmp.path));
    st.showArchive(a);
    await tester.pump();
    Tooltip tip(String id) => tester.widget<Tooltip>(
      find
          .ancestor(
            of: find.byKey(Key('tool-$id')),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(tip('add').message, 'A xz file holds exactly one file');
    expect(tip('folder').message, 'A xz file holds exactly one file');
    expect(tip('delete').message, 'A xz file holds exactly one file');
    expect(tip('extract').message, isNot(contains('first')));

    final row = find.byKey(ValueKey('row:${a.items.first.path}'));
    await tester.tap(
      row,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu-open')), findsOneWidget);
    expect(find.byKey(const Key('menu-extract-here')), findsOneWidget);
    final del = tester.widget<PopupMenuItem<String>>(
      find.byKey(const Key('menu-delete')),
    );
    expect(del.enabled, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('password dialog: show, hide, retry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => showPasswordDialog(
                context,
                const ZxPasswordRequest(
                  '/a/s.7z',
                  ZxPasswordReason.open,
                  retry: true,
                ),
              ),
              child: const Text('go'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wrong-password')), findsOneWidget);
    EditableText field() => tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('password-field')),
        matching: find.byType(EditableText),
      ),
    );
    expect(field().obscureText, isTrue);
    await tester.tap(find.byKey(const Key('password-show')));
    await tester.pump();
    expect(field().obscureText, isFalse);
  });

  testWidgets('overwrite dialog answers', (tester) async {
    ZxOverwriteAnswer? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () async => got = await showOverwriteDialog(
                context,
                ZxOverwriteRequest(
                  '/out/a.txt',
                  'a.txt',
                  existingSize: 3,
                  newSize: 4,
                ),
              ),
              child: const Text('go'),
            );
          },
        ),
      ),
    );
    for (final (k, v) in [
      ('ow-yes', ZxOverwriteAnswer.overwrite),
      ('ow-no-all', ZxOverwriteAnswer.skipAll),
      ('ow-rename', ZxOverwriteAnswer.rename),
      ('ow-cancel', ZxOverwriteAnswer.cancel),
    ]) {
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('/out/a.txt'), findsOneWidget);
      await tester.tap(find.byKey(Key(k)));
      await tester.pumpAndSettle();
      expect(got, v);
    }
  });

  testWidgets('extract dialog defaults', (tester) async {
    ExtractOptions? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () async => got = await showExtractDialog(
                context,
                defaultDestination: '/home/u/photos',
                selectedCount: 2,
                openFolderDefault: false,
                picker: FakePicker(),
              ),
              child: const Text('go'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('/home/u/photos'), findsOneWidget);
    expect(find.text('Selected items (2)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('extract-ok')));
    await tester.pumpAndSettle();
    expect(got!.destination, '/home/u/photos');
    expect(got!.selectionOnly, isTrue);
    expect(got!.keepPaths, isTrue);
    expect(got!.overwrite, ZxOverwrite.ask);
  });

  testWidgets('settings page: theme and integration toggles', (tester) async {
    final integ = FakeIntegration();
    final s = testServices(tmp.path, integration: integ, settings: Settings());
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SettingsPage(services: s)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect(s.settings.theme, ThemeMode.dark);

    SwitchListTile sw(String k) =>
        tester.widget<SwitchListTile>(find.byKey(Key(k)));
    expect(sw('set-assoc').value, isFalse);
    await tester.tap(find.byKey(const Key('set-assoc')));
    await tester.pumpAndSettle();
    expect(integ.calls, ['assoc:true']);
    expect(sw('set-assoc').value, isTrue);
    await tester.tap(find.byKey(const Key('set-menu')));
    await tester.pumpAndSettle();
    expect(sw('set-menu').value, isTrue);
    await tester.tap(find.byKey(const Key('set-menu')));
    await tester.pumpAndSettle();
    expect(integ.calls, ['assoc:true', 'menu:true', 'menu:false']);
    expect(sw('set-menu').value, isFalse);

    await tester.tap(find.byKey(const Key('set-confirm-delete')));
    await tester.pump();
    expect(s.settings.confirmDelete, isFalse);
  });

  test('settings are saved and read back', () async {
    final f = p.join(tmp.path, 'cfg', 'settings.json');
    final s = await Settings.load(f);
    s.theme = ThemeMode.light;
    s.defaultFormat = 'zip';
    s.defaultLevel = 9;
    s.addRecent('/a.7z');
    s.addRecent('/b.zip');
    await s.flush();
    final r = await Settings.load(f);
    expect(r.theme, ThemeMode.light);
    expect(r.defaultFormat, 'zip');
    expect(r.defaultLevel, 9);
    expect(r.recent, ['/b.zip', '/a.7z']);
  });
}
