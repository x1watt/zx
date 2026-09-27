// Fakes of the outside world for the widget and integration tests: the
// launcher records what it would open, the picker answers from queues, the
// paths point into a temporary folder so the real desktop is never
// touched.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zx_app/src/integration.dart';
import 'package:zx_app/src/services.dart';
import 'package:zx_app/src/settings.dart';

class FakeLauncher implements Launcher {
  final files = <String>[];
  final folders = <String>[];

  @override
  Future<void> openFile(String path) async => files.add(path);

  @override
  Future<void> openFolder(String path) async => folders.add(path);
}

class FakePicker implements FilePicker {
  final archives = <String?>[];
  final fileLists = <List<String>>[];
  final folderAnswers = <String?>[];

  @override
  Future<String?> openArchive({String? initialDirectory}) async =>
      archives.isEmpty ? null : archives.removeAt(0);

  @override
  Future<List<String>> pickFiles({String? initialDirectory}) async =>
      fileLists.isEmpty ? const [] : fileLists.removeAt(0);

  @override
  Future<String?> pickFolder({String? initialDirectory, String? title}) async =>
      folderAnswers.isEmpty ? null : folderAnswers.removeAt(0);
}

class FakeIntegration implements DesktopIntegration {
  bool associations = false;
  bool contextMenu = false;
  final calls = <String>[];

  @override
  bool get supported => true;
  @override
  String get unsupportedReason => '';

  @override
  Future<IntegrationStatus> status() async => IntegrationStatus(
    associations: associations,
    contextMenu: contextMenu,
    registered: associations || contextMenu,
  );

  @override
  Future<void> register() async => calls.add('register');

  @override
  Future<void> setAssociations(bool on) async {
    calls.add('assoc:$on');
    associations = on;
  }

  @override
  Future<void> setContextMenu(bool on) async {
    calls.add('menu:$on');
    contextMenu = on;
  }

  @override
  Future<void> removeAll() async {
    calls.add('removeAll');
    associations = contextMenu = false;
  }
}

/// Paths under [root]: home, .config, .local/share and tmp.
AppPaths testPaths(String root) {
  final pth = AppPaths(
    home: root,
    configHome: p.join(root, '.config'),
    dataHome: p.join(root, '.local', 'share'),
    temp: p.join(root, 'tmp'),
  );
  Directory(pth.temp).createSync(recursive: true);
  return pth;
}

AppServices testServices(
  String root, {
  DesktopIntegration? integration,
  FakeLauncher? launcher,
  FakePicker? picker,
  Settings? settings,
}) {
  final paths = testPaths(root);
  return AppServices(
    paths: paths,
    settings: settings ?? (Settings()..showPreview = false),
    launcher: launcher ?? FakeLauncher(),
    picker: picker ?? FakePicker(),
    integration: integration ?? FakeIntegration(),
  );
}

/// A tree of small files to archive:
/// project/{README.md, notes.txt, docs/guide.txt, docs/deep/x.txt,
/// src/main.dart, src/util.dart, img/logo.png(bytes)}.
String makeTree(String root) {
  final base = p.join(root, 'input', 'project');
  void f(String rel, String text) {
    final file = File(p.join(base, rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  f('README.md', '# Project\n\nHello from zx.\n');
  f('notes.txt', 'some notes\n' * 40);
  f('docs/guide.txt', 'guide\n' * 200);
  f('docs/deep/x.txt', 'x' * 5000);
  f('src/main.dart', 'void main() => print("hi");\n');
  f('src/util.dart', '// util\n' * 30);
  File(p.join(base, 'img', 'logo.bin'))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(List.generate(3000, (i) => (i * 7) & 0xFF));
  return base;
}
