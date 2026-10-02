// The browser side of the web version (lib/main_web.dart): picking and
// dropping files, links, the remembered URLs (localStorage), the address
// parameter ?url=, and the database connection through the engine.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:zx/zx_client.dart';
import 'package:zx/zx_web.dart';

import '../db_session.dart';
import '../services_base.dart';

@JS('document')
external JSObject get _document;

@JS('window')
external JSObject get _window;

@JS('localStorage')
external JSObject? get _localStorage;

/// Files picked with the browser's file dialog (File objects), null when
/// the dialog was cancelled.
Future<JSArray<JSObject>?> pickFiles() {
  final done = Completer<JSArray<JSObject>?>();
  final input =
      _document.callMethod<JSObject>('createElement'.toJS, 'input'.toJS)
        ..['type'] = 'file'.toJS
        ..['multiple'] = true.toJS;
  input['onchange'] = ((JSObject _) {
    if (!done.isCompleted) done.complete(_fileList(input['files'] as JSObject));
  }).toJS;
  input['oncancel'] = ((JSObject _) {
    if (!done.isCompleted) done.complete(null);
  }).toJS;
  input.callMethod<JSAny?>('click'.toJS);
  return done.future;
}

JSArray<JSObject> _fileList(JSObject files) {
  final n = (files['length'] as JSNumber).toDartInt;
  return [
    for (var i = 0; i < n; i++) files.callMethod<JSObject>('item'.toJS, i.toJS),
  ].toJS;
}

/// Calls [onFiles] with the files dropped anywhere on the page, and
/// [onHover] when a drag of files enters or leaves it.
void listenForDrops(
  void Function(JSArray<JSObject> files) onFiles,
  void Function(bool hover) onHover,
) {
  bool hasFiles(JSObject e) {
    final dt = e['dataTransfer'] as JSObject?;
    final types = dt?['types'] as JSObject?;
    if (types == null) return false;
    return types.callMethod<JSBoolean>('includes'.toJS, 'Files'.toJS).toDart;
  }

  _window['ondragover'] = ((JSObject e) {
    if (!hasFiles(e)) return;
    e.callMethod<JSAny?>('preventDefault'.toJS);
    onHover(true);
  }).toJS;
  _window['ondragleave'] = ((JSObject e) {
    if (e['relatedTarget'] == null) onHover(false);
  }).toJS;
  _window['ondrop'] = ((JSObject e) {
    if (!hasFiles(e)) return;
    e.callMethod<JSAny?>('preventDefault'.toJS);
    onHover(false);
    final files = _fileList(
      (e['dataTransfer'] as JSObject)['files'] as JSObject,
    );
    if (files.length > 0) onFiles(files);
  }).toJS;
}

/// The name of a File of the page.
String fileName(JSObject file) => (file['name'] as JSString).toDart;

/// The parameters of a link to the page (docs/app.md "Links"): `url`, the
/// address of an archive, and `path`, a folder of it to show or a file to
/// select.
({String? url, String? path}) linkParameters() {
  final href = ((_window['location'] as JSObject)['href'] as JSString).toDart;
  final q = Uri.tryParse(href)?.queryParameters ?? const {};
  String? get(String k) {
    final v = q[k];
    return v == null || v.isEmpty ? null : v;
  }

  return (url: get('url'), path: get('path'));
}

/// A link that opens the archive at [url] on this page, at [path] when
/// given.
String shareLink(String url, {String? path}) {
  final href = ((_window['location'] as JSObject)['href'] as JSString).toDart;
  final page = Uri.parse(href).replace(query: '', fragment: '');
  final base = page.toString().replaceAll(RegExp(r'[?#]+$'), '');
  return Uri.parse(base)
      .replace(queryParameters: {'url': url, 'path': ?path})
      .toString();
}

/// Puts the link of what is shown ([shareLink]) into the address without
/// loading the page again, so the address bar can be copied; a null [url]
/// removes it.
void setLinkParameters(String? url, {String? path}) {
  final href = ((_window['location'] as JSObject)['href'] as JSString).toDart;
  final next = url == null
      ? Uri.parse(href)
            .replace(query: '')
            .toString()
            .replaceAll(RegExp(r'\?$'), '')
      : shareLink(url, path: path);
  if (next == href) return;
  (_window['history'] as JSObject).callMethod<JSAny?>(
    'replaceState'.toJS,
    null,
    ''.toJS,
    next.toJS,
  );
}

// ---------------------------------------------------------------------------
// Remembered URLs

const _kRecentKey = 'zx.recentUrls';

List<String> recentUrls() {
  try {
    final v = _localStorage?.callMethod<JSString?>(
      'getItem'.toJS,
      _kRecentKey.toJS,
    );
    if (v == null) return const [];
    return [for (final s in jsonDecode(v.toDart) as List) s as String];
  } catch (_) {
    return const [];
  }
}

void rememberUrl(String url) {
  final l = [url, ...recentUrls().where((u) => u != url)].take(12).toList();
  _saveRecent(l);
}

void forgetUrl(String url) =>
    _saveRecent(recentUrls().where((u) => u != url).toList());

void _saveRecent(List<String> l) {
  try {
    _localStorage?.callMethod<JSAny?>(
      'setItem'.toJS,
      _kRecentKey.toJS,
      jsonEncode(l).toJS,
    );
  } catch (_) {
    // storage blocked: nothing is remembered
  }
}

// ---------------------------------------------------------------------------
// The services of the shared views

/// Links open in a new tab.
class WebLauncher implements Launcher {
  const WebLauncher();

  @override
  Future<void> openFile(String path) async {}

  @override
  Future<void> openFolder(String path) async {}

  @override
  Future<bool> openUrl(String url) async {
    _window.callMethod<JSAny?>(
      'open'.toJS,
      url.toJS,
      '_blank'.toJS,
      'noopener'.toJS,
    );
    return true;
  }
}

/// Only saving exists in a browser: the name becomes a download.
class WebFilePicker implements FilePicker {
  const WebFilePicker();

  @override
  Future<String?> openArchive({String? initialDirectory}) async => null;

  @override
  Future<List<String>> pickFiles({String? initialDirectory}) async => const [];

  @override
  Future<String?> pickFolder({String? initialDirectory, String? title}) async =>
      null;

  @override
  Future<String?> saveFile({
    String? initialDirectory,
    String? suggestedName,
  }) async => suggestedName ?? 'export';
}

class _WebDb implements DbConnection {
  final ZxWebDatabase db;
  _WebDb(this.db);

  @override
  Future<ZxSqlResult> execute(String sql, [Object? params]) =>
      db.execute(sql, params);

  @override
  Future<List<String>> kvStores() => db.kvStores();

  @override
  Future<List<String>> seriesNames() => db.seriesNames();

  @override
  Future<void> resetSql() => db.resetSql();

  @override
  Future<void> close() => db.close();
}

/// The [DbOpener] of the web version: the engine opens the database read
/// only.
Future<DbConnection?> webDbOpener(
  String path, {
  String? password,
  bool readOnly = true,
  bool create = false,
}) async {
  if (create) {
    throw const ZxDbException(
      'databases can not be created in the browser version',
      ZxDbError.readOnly,
    );
  }
  final db = await ZxEngine.instance.openDatabase(path, password: password);
  return db == null ? null : _WebDb(db);
}
