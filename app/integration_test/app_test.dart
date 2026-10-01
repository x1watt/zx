// End to end tests of the real Linux app against real archives: the work
// runs in the background isolates of ZxArchive exactly as in use. The
// file dialogs and the launcher are fakes, the settings, the temporary
// files and the desktop integration live in a temporary home.
//
// Run: ~/bin/android-build-locked flutter test integration_test -d linux

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/app.dart';
import 'package:zx_app/src/formats.dart';
import 'package:zx_app/src/integration.dart';
import 'package:zx_app/src/services.dart';
import 'package:zx_app/src/settings.dart';
import 'package:zx_app/src/ui/browser_page.dart';

import '../test/helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String tree;
  late FakeLauncher launcher;
  late FakePicker picker;
  late AppServices services;
  late GlobalKey<BrowserPageState> key;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zx_it_');
    tree = makeTree(tmp.path);
    launcher = FakeLauncher();
    picker = FakePicker();
    final paths = testPaths(tmp.path);
    services = AppServices(
      paths: paths,
      settings: Settings()..showPreview = false,
      launcher: launcher,
      picker: picker,
      integration: LinuxIntegration(
        paths,
        '/opt/zx/zx-gui',
        runner: (e, a) async => ProcessResult(0, 0, '', ''),
        systemConfigDirs: const [],
        packaged: false,
      ),
    );
    key = GlobalKey<BrowserPageState>();
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // a file still open
    }
  });

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 60),
    String? what,
  }) async {
    final end = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(end)) {
        fail('timed out waiting for ${what ?? 'a condition'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await tester.pump();
    }
    await tester.pump();
  }

  /// Waits for [f], then for the route animations to end.
  Future<void> pumpFor(WidgetTester tester, Finder f, {String? what}) async {
    await pumpUntil(
      tester,
      () => f.evaluate().isNotEmpty,
      what: what ?? f.describeMatch(Plurality.one),
    );
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await tester.pump();
    }
  }

  Future<void> pumpGone(WidgetTester tester, Finder f) => pumpUntil(
    tester,
    () => f.evaluate().isEmpty,
    what: 'no ${f.describeMatch(Plurality.one)}',
  );

  Future<BrowserPageState> start(WidgetTester tester) async {
    await tester.pumpWidget(ZxApp(services: services, browserKey: key));
    await tester.pump();
    return key.currentState!;
  }

  List<String> rows(WidgetTester tester) => [
    for (final e
        in find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key as ValueKey<String>).value.startsWith('row:'),
            )
            .evaluate())
      p.basename((e.widget.key as ValueKey<String>).value.substring(4)),
  ];

  Finder row(String path) => find.byKey(ValueKey('row:$path'));

  /// Picks [key] in the header menu (in its [submenu]).
  Future<void> menu(WidgetTester tester, String key, {String? submenu}) async {
    await tester.tap(find.byKey(const Key('app-menu')));
    await tester.pumpAndSettle();
    if (submenu != null) {
      await tester.tap(find.text(submenu));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(Key(key)).last);
  }

  Future<void> click(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pump();
    // so that the next click on the same row is not a double click
    await Future<void>.delayed(const Duration(milliseconds: 450));
  }

  Future<void> doubleClick(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.tap(f);
    await tester.pump();
  }

  Future<ZxArchive> makeArchive(
    String name, {
    String? format,
    ZxOptions options = const ZxOptions(),
  }) => ZxArchive.create(
    p.join(tmp.path, name),
    [ZxSource(tree)],
    format: format,
    options: options,
  );

  Future<BrowserPageState> openWithDialog(
    WidgetTester tester,
    String path,
  ) async {
    final st = await start(tester);
    picker.archives.add(path);
    await menu(tester, 'tool-open');
    await pumpUntil(tester, () => st.model != null, what: 'the archive');
    return st;
  }

  testWidgets('open, navigate, sort, filter, preview, open a file', (
    tester,
  ) async {
    final a = await makeArchive('t.7z');
    final st = await openWithDialog(tester, a.path);
    expect(rows(tester), ['project']);
    expect(find.textContaining('7z  |  LZMA2'), findsOneWidget);

    await doubleClick(tester, row('project'));
    await pumpUntil(tester, () => st.model!.dir == 'project');
    expect(rows(tester), ['docs', 'img', 'src', 'notes.txt', 'README.md']);

    await tester.tap(find.byKey(const Key('col-size')));
    await tester.pump();
    expect(rows(tester).sublist(3), ['README.md', 'notes.txt']);
    await tester.tap(find.byKey(const Key('col-name')));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('filter')), 'READ');
    await tester.pump();
    expect(rows(tester), ['README.md']);
    await tester.enterText(find.byKey(const Key('filter')), '');
    await tester.pump();

    // preview of a text file, read in a background isolate
    services.settings.showPreview = true;
    await tester.pump();
    await click(tester, row('project/README.md'));
    await pumpFor(tester, find.byKey(const Key('preview-text')));
    expect(find.textContaining('Hello from zx'), findsOneWidget);
    services.settings.showPreview = false;
    await tester.pump();

    // double click a file: extracted to the temporary folder and opened
    await doubleClick(tester, row('project/README.md'));
    await pumpUntil(tester, () => launcher.files.isNotEmpty, what: 'launcher');
    final opened = launcher.files.single;
    expect(p.basename(opened), 'README.md');
    expect(p.isWithin(services.paths.openTempDir, opened), isTrue);
    expect(File(opened).readAsStringSync(), contains('Hello from zx'));

    // Enter on a folder enters it, Backspace goes up
    await click(tester, row('project/docs'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(st.model!.dir, 'project/docs');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(st.model!.dir, 'project');
  });

  testWidgets('extract all with overwrite questions, then a selection', (
    tester,
  ) async {
    final a = await makeArchive('x.zip');
    final st = await openWithDialog(tester, a.path);
    final out = p.join(tmp.path, 'out');
    File(p.join(out, 'project', 'README.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('old');

    Future<void> extractAllTo(String dest) async {
      await tester.tap(find.byKey(const Key('tool-extract')));
      await pumpFor(tester, find.byKey(const Key('extract-dialog')));
      expect(
        find.text(p.join(tmp.path, 'x')),
        findsOneWidget,
        reason: 'default: a folder named after the archive',
      );
      await tester.enterText(find.byKey(const Key('extract-dest')), dest);
      await tester.tap(find.byKey(const Key('extract-all')));
      await tester.tap(find.byKey(const Key('extract-ok')));
      await tester.pump();
    }

    // "No": the existing file stays, the others are written
    await extractAllTo(out);
    await pumpFor(tester, find.byKey(const Key('ow-no')));
    expect(find.text(p.join(out, 'project', 'README.md')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ow-no')));
    await pumpUntil(
      tester,
      () => File(p.join(out, 'project', 'docs', 'deep', 'x.txt')).existsSync(),
    );
    await pumpGone(tester, find.byKey(const Key('progress-dialog')));
    expect(File(p.join(out, 'project', 'README.md')).readAsStringSync(), 'old');
    expect(
      File(p.join(out, 'project', 'src', 'main.dart')).existsSync(),
      isTrue,
    );

    // "Keep both": the new file gets another name
    await extractAllTo(out);
    await pumpFor(tester, find.byKey(const Key('ow-rename')));
    await tester.tap(find.byKey(const Key('ow-rename')));
    await tester.pump();
    // the other files exist too now: rename for each of them
    while (true) {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump();
      }
      final f = find.byKey(const Key('ow-rename'));
      if (f.evaluate().isEmpty) break;
      await tester.tap(f.last);
    }
    await pumpUntil(
      tester,
      () =>
          Directory(p.join(out, 'project'))
              .listSync()
              .any((e) => p.basename(e.path).startsWith('README_')),
    );
    expect(File(p.join(out, 'project', 'README.md')).readAsStringSync(), 'old');

    // "Yes to all"
    await extractAllTo(out);
    await pumpFor(tester, find.byKey(const Key('ow-yes-all')));
    await tester.tap(find.byKey(const Key('ow-yes-all')));
    await pumpUntil(
      tester,
      () =>
          File(p.join(out, 'project', 'README.md')).readAsStringSync() != 'old',
    );
    expect(
      File(p.join(out, 'project', 'README.md')).readAsStringSync(),
      contains('Hello from zx'),
    );
    await pumpGone(tester, find.byKey(const Key('progress-dialog')));

    // "Cancel" writes nothing
    File(p.join(out, 'project', 'notes.txt')).writeAsStringSync('mine');
    await extractAllTo(out);
    await pumpFor(tester, find.byKey(const Key('ow-cancel')));
    await tester.tap(find.byKey(const Key('ow-cancel')));
    await pumpFor(tester, find.textContaining('cancelled'));
    expect(
      File(p.join(out, 'project', 'notes.txt')).readAsStringSync(),
      'mine',
    );

    // a selection, relative to the current folder, without paths
    await doubleClick(tester, row('project'));
    await pumpUntil(tester, () => st.model!.dir == 'project');
    await click(tester, row('project/docs'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(row('project/notes.txt'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final sel = p.join(tmp.path, 'sel');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpFor(tester, find.byKey(const Key('extract-dialog')));
    expect(find.text('Selected items (2)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('extract-dest')), sel);
    await tester.tap(find.byKey(const Key('extract-ok')));
    await pumpUntil(
      tester,
      () => File(p.join(sel, 'docs', 'deep', 'x.txt')).existsSync(),
    );
    await pumpGone(tester, find.byKey(const Key('progress-dialog')));
    expect(File(p.join(sel, 'notes.txt')).existsSync(), isTrue);
    expect(Directory(p.join(sel, 'project')).existsSync(), isFalse);
    expect(Directory(p.join(sel, 'src')).existsSync(), isFalse);

    // flat: every file into the destination itself
    final flat = p.join(tmp.path, 'flat');
    await tester.tap(find.byKey(const Key('tool-extract')));
    await pumpFor(tester, find.byKey(const Key('extract-dialog')));
    await tester.enterText(find.byKey(const Key('extract-dest')), flat);
    await tester.tap(find.byKey(const Key('extract-keep-paths')));
    await tester.tap(find.byKey(const Key('extract-open-folder')));
    await tester.tap(find.byKey(const Key('extract-ok')));
    await pumpUntil(tester, () => File(p.join(flat, 'x.txt')).existsSync());
    await pumpUntil(tester, () => launcher.folders.isNotEmpty);
    expect(launcher.folders.single, flat);
    expect(File(p.join(flat, 'guide.txt')).existsSync(), isTrue);
  });

  testWidgets('add, new folder, rename, delete, test, comment', (tester) async {
    final a = await makeArchive('u.zip');
    final st = await openWithDialog(tester, a.path);
    await doubleClick(tester, row('project'));
    await pumpUntil(tester, () => st.model!.dir == 'project');

    // add a file through the dialog into the current folder
    final extra = File(p.join(tmp.path, 'extra.txt'))
      ..writeAsStringSync('extra');
    picker.fileLists.add([extra.path]);
    await tester.tap(find.byKey(const Key('tool-add')));
    await pumpFor(tester, find.byKey(const Key('add-dialog')));
    await tester.tap(find.byKey(const Key('src-add-files')));
    await pumpFor(tester, find.text('extra.txt'));
    await tester.tap(find.byKey(const Key('add-ok')));
    await pumpFor(tester, row('project/extra.txt'));
    expect(st.model!.selection, {'project/extra.txt'});

    // new folder
    await menu(tester, 'tool-folder');
    await pumpFor(tester, find.byKey(const Key('text-input')));
    await tester.enterText(find.byKey(const Key('text-input')), 'fresh');
    await tester.tap(find.byKey(const Key('text-input-ok')));
    await pumpFor(tester, row('project/fresh'));

    // rename with F2
    await click(tester, row('project/extra.txt'));
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await pumpFor(tester, find.byKey(const Key('text-input')));
    await tester.enterText(find.byKey(const Key('text-input')), 'renamed.txt');
    await tester.tap(find.byKey(const Key('text-input-ok')));
    await pumpFor(tester, row('project/renamed.txt'));
    expect(row('project/extra.txt'), findsNothing);

    // delete with the Delete key and the confirmation
    await click(tester, row('project/renamed.txt'));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await pumpFor(tester, find.byKey(const Key('confirm-ok')));
    await tester.tap(find.byKey(const Key('confirm-ok')));
    await pumpGone(tester, row('project/renamed.txt'));
    expect(st.model!.archive['project/renamed.txt'], isNull);

    // the archive on disk has the changes
    final again = await ZxArchive.open(a.path);
    expect(again['project/fresh'], isNotNull);
    expect(again['project/renamed.txt'], isNull);

    // test
    await tester.tap(find.byKey(const Key('tool-test')));
    await pumpFor(tester, find.byKey(const Key('test-result')));
    expect(find.text('No errors found.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('result-close')));
    await tester.pumpAndSettle();

    // the zip comment
    await tester.tap(find.byKey(const Key('tool-info')));
    await pumpFor(tester, find.byKey(const Key('info-dialog')));
    await tester.enterText(
      find.byKey(const Key('info-comment')),
      'hello comment',
    );
    await tester.tap(find.byKey(const Key('info-save-comment')));
    await pumpGone(tester, find.byKey(const Key('info-dialog')));
    expect((await ZxArchive.open(a.path)).comment, 'hello comment');
  });

  testWidgets('dropped files: open an archive, add files', (tester) async {
    final a = await makeArchive('d.7z');
    final st = await start(tester);
    unawaited(st.handleDrop([a.path]));
    await pumpUntil(tester, () => st.model != null, what: 'dropped archive');
    expect(rows(tester), ['project']);
    final f = File(p.join(tmp.path, 'dropped.txt'))..writeAsStringSync('drop');
    unawaited(st.handleDrop([f.path]));
    await pumpFor(tester, find.byKey(const Key('add-dialog')));
    expect(find.text('dropped.txt'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-ok')));
    await pumpFor(tester, row('dropped.txt'));
    expect((await ZxArchive.open(a.path))['dropped.txt']?.size, 4);
  });

  testWidgets('encrypted archives: wrong password, retry, extract', (
    tester,
  ) async {
    final a = await makeArchive(
      's.7z',
      options: const ZxOptions(password: 'right', encryptHeaders: true),
    );
    final st = await start(tester);
    unawaited(st.openArchive(a.path));
    await pumpFor(tester, find.byKey(const Key('password-field')));
    await tester.enterText(find.byKey(const Key('password-field')), 'wrong');
    await tester.tap(find.byKey(const Key('password-ok')));
    await pumpFor(tester, find.byKey(const Key('wrong-password')));
    await tester.enterText(find.byKey(const Key('password-field')), 'right');
    await tester.tap(find.byKey(const Key('password-ok')));
    await pumpUntil(tester, () => st.model != null);
    expect(rows(tester), ['project']);
    expect(find.textContaining('encrypted'), findsWidgets);

    // the password is known now: extracting asks nothing
    final out = p.join(tmp.path, 'sout');
    await tester.tap(find.byKey(const Key('tool-extract')));
    await pumpFor(tester, find.byKey(const Key('extract-dialog')));
    await tester.enterText(find.byKey(const Key('extract-dest')), out);
    await tester.tap(find.byKey(const Key('extract-ok')));
    await pumpUntil(
      tester,
      () => File(p.join(out, 'project', 'README.md')).existsSync(),
    );

    // a zip with encrypted data only: opening a file asks
    final z = await makeArchive(
      'z.zip',
      options: const ZxOptions(password: 'zz', switches: {'em': 'AES256'}),
    );
    unawaited(st.openArchive(z.path));
    await pumpUntil(tester, () => st.model?.archive.path == z.path);
    await doubleClick(tester, row('project'));
    await pumpUntil(tester, () => st.model!.dir == 'project');
    expect(find.byIcon(Icons.lock_rounded), findsWidgets);
    await doubleClick(tester, row('project/notes.txt'));
    await pumpFor(tester, find.byKey(const Key('password-field')));
    await tester.enterText(find.byKey(const Key('password-field')), 'zz');
    await tester.tap(find.byKey(const Key('password-ok')));
    await pumpUntil(tester, () => launcher.files.isNotEmpty);
    expect(
      File(launcher.files.single).readAsStringSync(),
      startsWith('some notes'),
    );
  });

  testWidgets('new archive in every format', (tester) async {
    final st = await start(tester);
    final single = File(p.join(tmp.path, 'single.txt'))
      ..writeAsStringSync('single file\n' * 50);
    for (final f in kNewFormats) {
      if (f.singleFile) {
        picker.fileLists.add([single.path]);
      } else {
        picker.folderAnswers.add(tree);
      }
      await menu(tester, 'tool-new');
      await pumpFor(tester, find.byKey(const Key('new-dialog')));
      await tester.enterText(find.byKey(const Key('new-folder')), tmp.path);
      await tester.tap(find.byKey(const Key('new-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(f.label).last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key(f.singleFile ? 'src-add-files' : 'src-add-folder')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('new-name')),
        'made_${f.id.replaceAll('.', '_')}',
      );
      await tester.tap(find.byKey(const Key('new-ok')));
      final path = p.join(
        tmp.path,
        'made_${f.id.replaceAll('.', '_')}.${f.extension}',
      );
      await pumpUntil(
        tester,
        () => st.model?.archive.path == path,
        what: 'the new ${f.id} archive',
      );
      final a = st.model!.archive;
      if (f.singleFile) {
        expect(a.items.where((i) => !i.isDir).length, 1, reason: f.id);
      } else {
        expect(a['project/README.md'], isNotNull, reason: f.id);
        expect(a['project/docs/deep/x.txt']?.size, 5000, reason: f.id);
      }
      // every format reads back what it wrote
      final r = await a.test();
      expect(r.ok, isTrue, reason: '${f.id}: ${r.errors}');
      await pumpGone(tester, find.byKey(const Key('new-dialog')));
    }
    // the password and encrypted names of a new 7z
    picker.folderAnswers.add(tree);
    await menu(tester, 'tool-new');
    await pumpFor(tester, find.byKey(const Key('new-dialog')));
    await tester.enterText(find.byKey(const Key('new-folder')), tmp.path);
    await tester.tap(find.byKey(const Key('new-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7z').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('src-add-folder')));
    await tester.enterText(find.byKey(const Key('new-name')), 'locked');
    await tester.enterText(find.byKey(const Key('opt-password')), 'pw');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('opt-encrypt-names')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opt-encrypt-names')));
    await tester.tap(find.byKey(const Key('new-ok')));
    final locked = p.join(tmp.path, 'locked.7z');
    await pumpUntil(tester, () => st.model?.archive.path == locked);
    expect(st.model!.archive.encryptedHeaders, isTrue);
    await expectLater(
      ZxArchive.open(locked),
      throwsA(isA<SevenZipException>()),
    );
  });

  testWidgets('settings: integration toggles in a temporary home', (
    tester,
  ) async {
    await start(tester);
    await menu(tester, 'tool-settings');
    await pumpFor(tester, find.byKey(const Key('set-assoc')));
    final integ = services.integration as LinuxIntegration;
    await pumpUntil(
      tester,
      () =>
          tester
              .widget<SwitchListTile>(find.byKey(const Key('set-assoc')))
              .onChanged !=
          null,
    );

    await tester.tap(find.byKey(const Key('set-assoc')));
    await pumpUntil(
      tester,
      () => tester
          .widget<SwitchListTile>(find.byKey(const Key('set-assoc')))
          .value,
    );
    final mime = File(integ.mimeappsFile).readAsStringSync();
    expect(mime, contains('application/x-7z-compressed=zx.desktop'));
    expect(
      File(integ.desktopFile).readAsStringSync(),
      contains('Exec=/opt/zx/zx-gui %F'),
    );

    await tester.tap(find.byKey(const Key('set-menu')));
    await pumpUntil(
      tester,
      () => tester
          .widget<SwitchListTile>(find.byKey(const Key('set-menu')))
          .value,
    );
    expect(File(integ.nautilusScript).existsSync(), isTrue);
    expect(File(integ.contextMenuDisabledFile).existsSync(), isFalse);
    expect(
      File(integ.thunarActions).readAsStringSync(),
      contains('zx-extract-to-folder'),
    );

    await tester.tap(find.byKey(const Key('set-menu')));
    await pumpUntil(
      tester,
      () => !tester
          .widget<SwitchListTile>(find.byKey(const Key('set-menu')))
          .value,
    );
    expect(File(integ.nautilusScript).existsSync(), isFalse);
    expect(File(integ.contextMenuDisabledFile).existsSync(), isTrue);
    await tester.tap(find.byKey(const Key('set-assoc')));
    await pumpUntil(
      tester,
      () => !tester
          .widget<SwitchListTile>(find.byKey(const Key('set-assoc')))
          .value,
    );
    expect(
      File(integ.mimeappsFile).readAsStringSync(),
      isNot(contains('zx.desktop')),
    );

    // the theme switch
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byKey(const Key('set-assoc')))).brightness,
      Brightness.dark,
    );
  });

  testWidgets('extract to folder mode', (tester) async {
    final a = await makeArchive('pack.tar.gz');
    final b = await makeArchive('pack2.7z');
    Directory(p.join(tmp.path, 'pack2')).createSync(); // taken: pack2 (2)
    final done = Completer<int>();
    await tester.pumpWidget(
      ExtractToFolderApp(
        services: services,
        archives: [a.path, b.path],
        onDone: (c) {
          if (!done.isCompleted) done.complete(c);
        },
      ),
    );
    await pumpUntil(tester, () => done.isCompleted, what: 'extract to folder');
    expect(await done.future, 0);
    expect(
      File(p.join(tmp.path, 'pack', 'project', 'README.md')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(tmp.path, 'pack2 (2)', 'project', 'docs', 'deep', 'x.txt'))
          .existsSync(),
      isTrue,
    );
    expect(Directory(p.join(tmp.path, 'pack2')).listSync(), isEmpty);
  });

  // The real firmware of a Reolink doorbell, opened read-only (skipped
  // when the file is not on this machine): pak > rootfs (a UBI image with
  // one UBIFS volume) > etc/init.d, a text preview, a folder extracted,
  // the container details and the inner file systems view.
  const pak =
      '/home/brito/code/xprs/firmware/models/reolink-d340w/firmware/stock/'
      'DB_566128M5MP_W.4662_2508071282.Reolink-Video-Doorbell-WiFi.OV05A10.'
      '5MP.WIFI8812.REOLINK.pak';
  testWidgets('real firmware: nested levels, preview, extract, flattened', (
    tester,
  ) async {
    final st = await openWithDialog(tester, pak);
    final root = st.model!;
    expect(root.archive.format, 'Pak');
    expect(
      rows(tester),
      containsAll(['loader', 'fdt', 'uboot', 'kernel', 'rootfs', 'app']),
    );

    // the container details: the MTD table of the pak
    await tester.tap(find.byKey(const Key('tool-info')));
    await pumpFor(tester, find.byKey(const Key('info-dialog')));
    expect(find.text('Container details'), findsOneWidget);
    expect(find.textContaining('mtd part rootfs'), findsWidgets);
    await tester.tap(find.byKey(const Key('info-close')));
    await pumpGone(tester, find.byKey(const Key('info-dialog')));

    // rootfs: the UBI image shows the files of its UBIFS volume
    await doubleClick(tester, row('rootfs'));
    await pumpUntil(tester, () => st.model != root, what: 'rootfs');
    final fs = st.model!;
    expect(fs.parent, same(root));
    expect(fs.formats, ['Ubi', 'UbiFs']);
    expect(BrowserPageState.titleOf(fs), '${p.basename(pak)} > rootfs');
    expect(rows(tester), containsAll(['bin', 'etc', 'lib', 'usr']));
    expect(find.byKey(const Key('nest-boundary-1')), findsOneWidget);
    expect(find.byKey(const Key('tool-add')), findsNothing);
    expect(
      tester.widget<Tooltip>(find.byKey(const Key('read-only'))).message,
      'Inside a nested archive (read-only)',
    );

    await doubleClick(tester, row('etc'));
    await pumpUntil(tester, () => fs.dir == 'etc');
    await doubleClick(tester, row('etc/init.d'));
    await pumpUntil(tester, () => fs.dir == 'etc/init.d');
    expect(rows(tester), contains('rcS'));
    expect(find.byKey(const Key('crumb:etc/init.d')), findsOneWidget);

    // preview of a text file of the UBIFS volume
    services.settings.showPreview = true;
    await tester.pump();
    await click(tester, row('etc/init.d/rcS'));
    await pumpFor(tester, find.byKey(const Key('preview-text')));
    final text =
        tester
            .widget<SelectableText>(find.byKey(const Key('preview-text')))
            .data ??
        '';
    expect(text, contains('/'));
    services.settings.showPreview = false;
    await tester.pump();

    // extract the folder init.d (relative to etc)
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(fs.dir, 'etc');
    await click(tester, row('etc/init.d'));
    final out = p.join(tmp.path, 'fw_out');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpFor(tester, find.byKey(const Key('extract-dialog')));
    await tester.enterText(find.byKey(const Key('extract-dest')), out);
    await tester.tap(find.byKey(const Key('extract-ok')));
    await pumpUntil(
      tester,
      () => File(p.join(out, 'init.d', 'rcS')).existsSync(),
      what: 'init.d extracted',
    );
    await pumpGone(tester, find.byKey(const Key('progress-dialog')));
    expect(Directory(p.join(out, 'init.d')).listSync().length, greaterThan(3));

    // up and out of the nested level, back to the pak with rootfs selected
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(fs.dir, '');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(st.model, same(root));
    expect(root.selection, {'rootfs'});

    // the inner file systems as folders
    await menu(tester, 'menu-show-inner', submenu: 'View');
    await pumpUntil(
      tester,
      () => st.model?.archive.flattened ?? false,
      what: 'the flattened view',
    );
    final flat = st.model!;
    expect(flat.archive['rootfs']!.isDir, isTrue);
    expect(flat.archive['rootfs/etc/init.d/rcS'], isNotNull);
    expect(flat.archive['app']!.isDir, isTrue);
    await doubleClick(tester, row('rootfs'));
    await pumpUntil(tester, () => flat.dir == 'rootfs');
    expect(rows(tester), containsAll(['bin', 'etc']));
    services.settings.showInnerFilesystems = false;
    st.closeArchive();
    await tester.pump();
  }, skip: !File(pak).existsSync());
}
