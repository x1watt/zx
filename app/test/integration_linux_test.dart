// The Linux desktop integration against a temporary home: desktop entry,
// defaults in mimeapps.list (and giving the old ones back), the Nautilus
// script, the switch file of the native Nautilus extension, the Thunar
// action merged into existing actions; per user and from the package.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx_app/src/formats.dart';
import 'package:zx_app/src/integration.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  late LinuxIntegration li;
  final commands = <String>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zx_integ_');
    commands.clear();
    final sys = Directory(p.join(tmp.path, 'etc', 'xdg', 'Thunar'))
      ..createSync(recursive: true);
    File(p.join(sys.path, 'uca.xml')).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<actions>
<action>
	<icon>utilities-terminal</icon>
	<name>Open Terminal Here</name>
	<unique-id>1-1</unique-id>
	<command>exo-open --working-directory %f --launch TerminalEmulator</command>
	<patterns>*</patterns>
	<directories/>
</action>
</actions>
''');
    final icons = Directory(p.join(tmp.path, 'icons'))..createSync();
    File(p.join(icons.path, 'zx.svg')).writeAsStringSync('<svg/>');
    File(p.join(icons.path, 'zx-48.png')).writeAsBytesSync([1, 2, 3]);
    li = LinuxIntegration(
      testPaths(tmp.path),
      '/opt/zx app/zx_app',
      runner: (exe, args) async {
        commands.add('$exe ${args.join(' ')}');
        return ProcessResult(0, 0, '', '');
      },
      systemConfigDirs: [p.join(tmp.path, 'etc', 'xdg')],
      iconSource: icons.path,
      nautilusExtensionDirs: [p.join(tmp.path, 'extensions-4')],
    );
  });

  /// The integration of the app installed by the package.
  LinuxIntegration packaged() => LinuxIntegration(
    testPaths(tmp.path),
    '/opt/zx/zx_app',
    runner: (exe, args) async {
      commands.add('$exe ${args.join(' ')}');
      return ProcessResult(0, 0, '', '');
    },
    systemConfigDirs: [p.join(tmp.path, 'etc', 'xdg')],
    nautilusExtensionDirs: [p.join(tmp.path, 'extensions-4')],
  );

  void installNativeExtension() {
    Directory(p.join(tmp.path, 'extensions-4')).createSync();
    File(p.join(tmp.path, 'extensions-4', kNautilusExtensionName))
        .writeAsBytesSync([0]);
  }

  tearDown(() => tmp.deleteSync(recursive: true));

  test('register writes the desktop entry and the icons', () async {
    await li.register();
    final d = File(li.desktopFile).readAsStringSync();
    expect(d, contains('Exec="/opt/zx app/zx_app" %F'));
    expect(d, contains('MimeType=application/x-7z-compressed;'));
    for (final t in kPrimaryMimeTypes) {
      expect(d, contains('$t;'));
    }
    expect(d, contains('Icon=zx'));
    expect(
      File(p.join(li.iconsDir, 'scalable', 'apps', 'zx.svg')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(li.iconsDir, '48x48', 'apps', 'zx.png')).existsSync(),
      isTrue,
    );
    expect(
      commands.any((c) => c.startsWith('update-desktop-database')),
      isTrue,
    );
    // application/x-zx for .zx files
    expect(File(li.zxMimeFile).readAsStringSync(), kZxMimeXml);
    expect(commands.any((c) => c.startsWith('update-mime-database')), isTrue);
    final s = await li.status();
    expect(s.registered, isTrue);
    expect(s.associations, isFalse);
    expect(s.contextMenu, isFalse);
  });

  test('associations are set and the old defaults come back', () async {
    final mime = File(li.mimeappsFile)..parent.createSync(recursive: true);
    mime.writeAsStringSync('''
[Added Associations]
text/html=firefox.desktop;

[Default Applications]
application/zip=org.gnome.FileRoller.desktop
text/plain=org.gnome.TextEditor.desktop
''');
    await li.setAssociations(true);
    var t = mime.readAsStringSync();
    expect(t, contains('application/zip=zx.desktop'));
    expect(t, contains('application/x-7z-compressed=zx.desktop'));
    expect(t, contains('text/plain=org.gnome.TextEditor.desktop'));
    expect(t, contains('text/html=firefox.desktop;'));
    expect(
      t,
      contains('application/vnd.rar=zx.desktop;'),
      reason: 'added association',
    );
    expect((await li.status()).associations, isTrue);
    expect(File(li.desktopFile).existsSync(), isTrue);

    await li.setAssociations(false);
    t = mime.readAsStringSync();
    expect(t, contains('application/zip=org.gnome.FileRoller.desktop'));
    expect(t, isNot(contains('zx.desktop')));
    expect(t, contains('text/plain=org.gnome.TextEditor.desktop'));
    expect((await li.status()).associations, isFalse);
  });

  test(
    'context menu: Nautilus script, switch file and Thunar action',
    () async {
      expect(li.packaged, isFalse);
      final legacy = File(
        p.join(
          li.paths.dataHome,
          'nautilus-python',
          'extensions',
          'zx_extract.py',
        ),
      )..createSync(recursive: true);
      await li.setContextMenu(true);
      expect(legacy.existsSync(), isFalse, reason: 'old python extension');
      final script = File(li.nautilusScript);
      expect(script.existsSync(), isTrue);
      expect(
        script.readAsStringSync(),
        contains("exec '/opt/zx app/zx_app' --extract-to-folder \"\$@\""),
      );
      expect(script.statSync().mode & 0x40, isNonZero, reason: 'executable');
      expect(File(li.contextMenuDisabledFile).existsSync(), isFalse);
      final uca = File(li.thunarActions).readAsStringSync();
      expect(
        uca,
        contains('Open Terminal Here'),
        reason: 'system actions kept',
      );
      expect(uca, contains('<unique-id>zx-extract-to-folder</unique-id>'));
      expect(
        uca,
        contains(
          "<command>'/opt/zx app/zx_app' --extract-to-folder %F</command>",
        ),
      );
      var st = await li.status();
      expect(st.contextMenu, isTrue);
      expect(
        st.notes.single,
        contains('Scripts'),
        reason: 'no native extension',
      );
      installNativeExtension();
      expect((await li.status()).notes, isEmpty);

      // installing again does not duplicate the action
      await li.setContextMenu(true);
      final again = File(li.thunarActions).readAsStringSync();
      expect('zx-extract-to-folder'.allMatches(again).length, 1);

      await li.setContextMenu(false);
      expect(File(li.nautilusScript).existsSync(), isFalse);
      expect(
        File(li.contextMenuDisabledFile).existsSync(),
        isTrue,
        reason: 'switches the native extension off',
      );
      final after = File(li.thunarActions).readAsStringSync();
      expect(after, contains('Open Terminal Here'));
      expect(after, isNot(contains('zx-extract-to-folder')));
      expect((await li.status()).contextMenu, isFalse);
    },
  );

  test('an existing uca.xml keeps its actions and gets a backup', () async {
    final f = File(li.thunarActions)..parent.createSync(recursive: true);
    f.writeAsStringSync(
      '<?xml version="1.0"?>\n<actions>\n<action>\n\t<name>Mine</name>\n\t<unique-id>9</unique-id>\n</action>\n</actions>\n',
    );
    await li.setContextMenu(true);
    final t = f.readAsStringSync();
    expect(t, contains('<name>Mine</name>'));
    expect(t, contains('zx-extract-to-folder'));
    expect(File('${f.path}.zx-backup').existsSync(), isTrue);
  });

  test('removeAll leaves nothing behind', () async {
    await li.register();
    await li.setAssociations(true);
    await li.setContextMenu(true);
    await li.removeAll();
    expect(File(li.desktopFile).existsSync(), isFalse);
    expect(File(li.nautilusScript).existsSync(), isFalse);
    expect(
      File(p.join(li.iconsDir, 'scalable', 'apps', 'zx.svg')).existsSync(),
      isFalse,
    );
    expect(File(li.contextMenuDisabledFile).existsSync(), isFalse);
    expect(File(li.zxMimeFile).existsSync(), isFalse);
    final s = await li.status();
    expect(s.associations || s.contextMenu || s.registered, isFalse);
  });

  test('from the package: no desktop entry per user, the switch file drives '
      'the native extension', () async {
    final pk = packaged();
    expect(pk.packaged, isTrue);
    installNativeExtension();
    // a script left from a per user install
    File(pk.nautilusScript)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');

    var st = await pk.status();
    expect(st.registered, isTrue, reason: 'the system desktop entry');
    expect(st.contextMenu, isTrue, reason: 'the extension is on by default');
    expect(st.notes, isEmpty);

    await pk.register();
    await pk.setAssociations(true);
    expect(File(pk.desktopFile).existsSync(), isFalse);
    expect(
      File(pk.mimeappsFile).readAsStringSync(),
      contains('application/zip=zx.desktop'),
    );

    await pk.setContextMenu(false);
    expect(File(pk.contextMenuDisabledFile).existsSync(), isTrue);
    expect(File(pk.nautilusScript).existsSync(), isFalse);
    expect((await pk.status()).contextMenu, isFalse);

    await pk.setContextMenu(true);
    expect(File(pk.contextMenuDisabledFile).existsSync(), isFalse);
    expect(File(pk.nautilusScript).existsSync(), isFalse, reason: 'no script');
    expect(
      File(pk.thunarActions).readAsStringSync(),
      contains("<command>/opt/zx/zx_app --extract-to-folder %F</command>"),
    );
    st = await pk.status();
    expect(st.contextMenu, isTrue);

    await pk.removeAll();
    expect(File(pk.contextMenuDisabledFile).existsSync(), isTrue);
    expect((await pk.status()).contextMenu, isFalse);
  });

  test(
    'from the package without Nautilus: the Thunar action decides',
    () async {
      final pk = packaged();
      expect((await pk.status()).contextMenu, isFalse);
      await pk.setContextMenu(true);
      expect((await pk.status()).contextMenu, isTrue);
    },
  );
}
