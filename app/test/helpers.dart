// Fakes of the outside world for the widget and integration tests: the
// launcher records what it would open, the picker answers from queues, the
// paths point into a temporary folder so the real desktop is never
// touched.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zx/src/db/sql/zx_sql.dart' show ZxSqlResult;
import 'package:zx/src/db/zxdb.dart';
import 'package:zx_app/src/db_session.dart';
import 'package:zx_app/src/integration.dart';
import 'package:zx_app/src/platform/places.dart';
import 'package:zx_app/src/services.dart';
import 'package:zx_app/src/settings.dart';

class FakeLauncher implements Launcher {
  final files = <String>[];
  final folders = <String>[];

  @override
  Future<void> openFile(String path) async => files.add(path);

  @override
  Future<void> openFolder(String path) async => folders.add(path);

  final urls = <String>[];

  @override
  Future<bool> openUrl(String url) async {
    urls.add(url);
    return true;
  }
}

class FakePicker implements FilePicker {
  final archives = <String?>[];
  final fileLists = <List<String>>[];
  final folderAnswers = <String?>[];
  final saveAnswers = <String?>[];

  @override
  Future<String?> openArchive({String? initialDirectory}) async =>
      archives.isEmpty ? null : archives.removeAt(0);

  @override
  Future<List<String>> pickFiles({String? initialDirectory}) async =>
      fileLists.isEmpty ? const [] : fileLists.removeAt(0);

  @override
  Future<String?> pickFolder({String? initialDirectory, String? title}) async =>
      folderAnswers.isEmpty ? null : folderAnswers.removeAt(0);

  @override
  Future<String?> saveFile({
    String? initialDirectory,
    String? suggestedName,
  }) async => saveAnswers.isEmpty ? null : saveAnswers.removeAt(0);
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

/// Places under the test's temporary folder (no real volumes).
class FakePlaces implements PlatformPlaces {
  final String home;
  final opened = <String>[];
  final shared = <List<String>>[];
  FakePlaces(this.home);

  @override
  Future<List<Place>> places() async => [Place('Home', home, PlaceKind.home)];

  @override
  Future<List<Place>> volumes() async => const [];

  @override
  Future<SpaceInfo?> space(String path) async =>
      const SpaceInfo(total: 1000 << 30, free: 250 << 30);

  @override
  Future<bool> ensureAccess() async => true;

  @override
  Future<bool> openWithChooser(String path) async => false;

  @override
  Future<List<AppChoice>> appsFor(String path) async => const [
    AppChoice('viewer.desktop', 'Viewer'),
  ];

  @override
  Future<void> openWith(AppChoice app, String path) async =>
      opened.add('${app.id}:$path');

  @override
  bool get canShare => true;

  @override
  Future<void> share(List<String> paths) async => shared.add(paths);
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
  DbOpener? dbOpener,
}) {
  final paths = testPaths(root);
  return AppServices(
    paths: paths,
    settings: settings ?? (Settings()..showPreview = false),
    launcher: launcher ?? FakeLauncher(),
    picker: picker ?? FakePicker(),
    integration: integration ?? FakeIntegration(),
    dbOpener: dbOpener ?? syncDbOpener,
    places: FakePlaces(paths.home),
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

/// A [DbConnection] that runs ZxDatabase on the test's isolate
/// (synchronously, so the widget tests need no runAsync for the queries).
class SyncDbConnection implements DbConnection {
  final ZxDatabase db;
  final calls = <String>[];
  SyncDbConnection(this.db);

  @override
  Future<ZxSqlResult> execute(String sql, [Object? params]) async {
    calls.add(sql);
    return db.sql.execute(sql, params);
  }

  @override
  Future<List<String>> kvStores() async => db.kvStores;

  @override
  Future<List<String>> seriesNames() async => db.seriesNames;

  @override
  Future<void> resetSql() async => db.resetSql();

  @override
  Future<void> close() async => db.close();
}

/// The connections the tests opened (closed by [closeTestDbs]).
final openTestDbs = <SyncDbConnection>[];

Future<DbConnection?> syncDbOpener(
  String path, {
  String? password,
  bool readOnly = false,
  bool create = false,
}) async {
  if (!create) {
    final s = ZxDbStore.open(path, password: password, readOnly: true);
    final has = s.root != null;
    s.close();
    if (!has) return null;
  }
  final c = SyncDbConnection(
    ZxDatabase.open(
      path,
      password: password,
      readOnly: readOnly,
      create: create,
    ),
  );
  openTestDbs.add(c);
  return c;
}

Future<void> closeTestDbs() async {
  for (final c in openTestDbs) {
    try {
      c.db.close();
    } on StateError {
      // closed
    }
  }
  openTestDbs.clear();
}
