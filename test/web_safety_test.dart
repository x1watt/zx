// The import graphs of the web version (docs/architecture.md section 20):
//   the UI (app/lib/main_web.dart) reaches the library only through
//     package:zx/zx_client.dart and package:zx/zx_web.dart, which hold no
//     engine code, so the Flutter web build (dart2js and dart2wasm) can
//     compile it;
//   those two, as compiled for the browser, import neither dart:isolate nor
//     package:zx/zx.dart nor the codecs (dart:io only through the shim
//     lib/src/host/io_web.dart, which dart2js compiles), and compile with
//     dart2js (no 64-bit integer literals).
// The graph follows the dart.library.js_interop branch of conditional
// imports and exports, as a browser build does.

import 'dart:io';

import 'package:test/test.dart';

final _root = Directory.current.path;

final _directive = RegExp(
    r'''^\s*(import|export)\s+'([^']+)'((?:\s+if\s*\([^)]*\)\s*'[^']+')*)''',
    multiLine: true);
final _cond =
    RegExp(r'''if\s*\(\s*dart\.library\.js_interop\s*\)\s*'([^']+)'\s*''');

/// The file of [uri] imported from [from], or null for a dart: library or
/// another package.
String? _resolve(String from, String uri) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:zx/')) {
    return '$_root/lib/${uri.substring('package:zx/'.length)}';
  }
  if (uri.startsWith('package:zx_app/')) {
    return '$_root/app/lib/${uri.substring('package:zx_app/'.length)}';
  }
  if (uri.startsWith('package:')) return null;
  return File(from).parent.uri.resolve(uri).toFilePath();
}

/// Every file and dart: library reachable from [start] in a browser build:
/// file path (or 'dart:x') to the file that imports it first.
Map<String, String> _graph(String start) {
  final seen = <String, String>{start: ''};
  final todo = [start];
  while (todo.isNotEmpty) {
    final f = todo.removeLast();
    final text = File(f).readAsStringSync();
    for (final m in _directive.allMatches(text)) {
      var uri = m[2]!;
      final c = _cond.firstMatch(m[3] ?? '');
      if (c != null) uri = c[1]!;
      if (uri.startsWith('dart:')) {
        seen.putIfAbsent(uri, () => f);
        continue;
      }
      final r = _resolve(f, uri);
      if (r == null || seen.containsKey(r)) {
        if (uri.startsWith('package:') && r == null) {
          seen.putIfAbsent(uri.split('/').first, () => f);
        }
        continue;
      }
      seen[r] = f;
      todo.add(r);
    }
  }
  return seen;
}

String _rel(String p) =>
    p.startsWith(_root) ? p.substring(_root.length + 1) : p;

void main() {
  test('the web UI reaches the library only through its client API', () {
    final g = _graph('$_root/app/lib/main_web.dart');
    final lib = '$_root/lib/';
    final allowed = {'${lib}zx_client.dart', '${lib}zx_web.dart'};
    final bad = [
      for (final e in g.entries)
        if (e.key.startsWith(lib) &&
            !allowed.contains(e.key) &&
            allowed.contains(e.value) == false &&
            !e.value.startsWith(lib))
          '${_rel(e.key)} (from ${_rel(e.value)})'
    ];
    expect(bad, isEmpty);
    expect(g.keys, isNot(contains('${lib}zx.dart')));
  });

  test('the client API holds no engine code', () {
    for (final start in ['zx_client.dart', 'zx_web.dart']) {
      final g = _graph('$_root/lib/$start');
      for (final k in ['dart:isolate', '$_root/lib/zx.dart']) {
        expect(g.containsKey(k), isFalse,
            reason: '$start reaches $k through ${_rel(g[k] ?? '')}');
      }
      for (final f in g.keys) {
        expect(f.contains('/codec/') || f.contains('/format/sevenz/'), isFalse,
            reason: '$start reaches ${_rel(f)}');
      }
    }
  });

  test('the web UI imports no desktop-only file of the app', () {
    final g = _graph('$_root/app/lib/main_web.dart');
    for (final f in g.keys) {
      final r = _rel(f);
      expect(
          r.contains('app/lib/src/fs/') ||
              r.contains('app/lib/src/platform/') ||
              r == 'app/lib/src/services.dart' ||
              r == 'app/lib/src/ui/browser_page.dart' ||
              r == 'app/lib/src/db_native.dart',
          isFalse,
          reason: '$r (from ${_rel(g[f]!)})');
    }
  });

  test('the client API compiles with dart2js', () {
    final dir = Directory.systemTemp.createTempSync('zx_web_safety_');
    try {
      final src = File('$_root/tool/web_check/.client_stub.dart')
        ..writeAsStringSync('''
import 'package:zx/zx_client.dart';
import 'package:zx/zx_web.dart';
void main() async {
  final e = await ZxEngine.start('x.js');
  final a = await ZxArchive.open('/upload/1/a.zx');
  print([a.items.length, await e.library(), zxSealSummary(await a.seals())]);
}
''');
      try {
        final r = Process.runSync(Platform.resolvedExecutable,
            ['compile', 'js', '-o', '${dir.path}/out.js', src.path]);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      } finally {
        src.deleteSync();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
