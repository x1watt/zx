// The calls of the web engine that the native API has no counterpart for
// (docs/architecture.md section 20): adding uploaded files and URLs as
// sources, the library in browser storage, and the database of a .zx
// archive. Typed wrappers over ZxEngine.call; dart2js-safe.

import 'dart:js_interop';

import '../db/sql/sql_result.dart';
import '../zx_types.dart';
import 'engine_client.dart';
import 'wire.dart';

/// How the archive at a URL can be read (see the engine's probe).
enum ZxUrlAccess {
  /// In place, with range requests: [ZxUrlInfo.path] opens it.
  range,

  /// Only by downloading it whole (the server ignores ranges).
  full,

  /// Not at all from this page (no CORS headers, not found, no network).
  blocked,
}

class ZxUrlInfo {
  final ZxUrlAccess access;

  /// The engine path of the archive (for [ZxUrlAccess.range]).
  final String? path;

  /// The file name taken from the URL.
  final String name;
  final int? size;

  /// Why the URL can not be read in place (an HTTP status, the browser's
  /// message).
  final String? problem;
  const ZxUrlInfo(this.access, this.path, this.name, this.size, this.problem);
}

/// An archive of the library (browser storage).
class ZxLibraryEntry {
  final String name;
  final int size;
  final DateTime modified;
  const ZxLibraryEntry(this.name, this.size, this.modified);

  static ZxLibraryEntry _of(Object? j) {
    final m = j as Map;
    return ZxLibraryEntry(m['name'] as String, m['size'] as int,
        DateTime.fromMillisecondsSinceEpoch(m['modified'] as int));
  }
}

class ZxLibraryUsage {
  /// Bytes used by this site and available to it (null when unknown).
  final int? usage;
  final int? quota;

  /// The browser keeps the data under storage pressure.
  final bool persisted;
  const ZxLibraryUsage(this.usage, this.quota, this.persisted);
}

extension ZxWebSources on ZxEngine {
  /// Adds picked or dropped files (File objects of the page); their engine
  /// paths, in order. The files of one call share a folder, so the volumes
  /// of a set find each other.
  Future<List<String>> addFiles(JSArray<JSObject> files) async {
    final r = await call('upload', files: files);
    return [for (final p in r.json as List) p as String];
  }

  /// Lets the engine drop the sources whose paths start with [prefix].
  Future<void> forget(String prefix) =>
      call('forget', args: {'prefix': prefix});

  /// Probes [url] and, when it can be read in place, adds it as a source.
  Future<ZxUrlInfo> addUrl(String url) async {
    final m = (await call('url', args: {'url': url})).json as Map;
    return ZxUrlInfo(
        ZxUrlAccess.values.byName(m['access'] as String),
        m['path'] as String?,
        m['name'] as String,
        m['size'] as int?,
        m['problem'] as String?);
  }

  /// The requests made and bytes fetched for the URL source [path].
  Future<(int, int)?> urlStats(String path) async {
    final m = (await call('urlStats', args: {'path': path})).json as Map?;
    return m == null ? null : (m['requests'] as int, m['bytes'] as int);
  }

  // ---- the library

  Future<(List<ZxLibraryEntry>, ZxLibraryUsage)> library() async {
    final m = (await call('library.list')).json as Map;
    final u = m['usage'] as Map;
    return (
      [for (final e in m['entries'] as List) ZxLibraryEntry._of(e)],
      ZxLibraryUsage(
          u['usage'] as int?, u['quota'] as int?, u['persisted'] as bool),
    );
  }

  /// The engine path of the library archive [name].
  Future<String> libraryPath(String name) async =>
      (await call('library.open', args: {'name': name})).json as String;

  /// Copies the uploaded file at [path] into the library as [name] (or a
  /// free variant of it).
  Future<ZxLibraryEntry> keep(String path, String name,
          {void Function(ZxProgress)? onProgress}) async =>
      ZxLibraryEntry._of((await call('library.import',
              args: {'path': path, 'name': name}, onProgress: onProgress))
          .json);

  /// Downloads [url] whole into the library as [name].
  Future<ZxLibraryEntry> download(String url, String name,
          {int? size,
          void Function(ZxProgress)? onProgress,
          ZxCancelToken? cancel}) async =>
      ZxLibraryEntry._of((await call('library.download',
              args: {'url': url, 'name': name, 'size': size},
              onProgress: onProgress,
              cancel: cancel))
          .json);

  Future<void> removeFromLibrary(String name) =>
      call('library.remove', args: {'name': name});

  /// Asks the browser to keep the library under storage pressure.
  Future<bool> persistLibrary() async =>
      (await call('library.persist')).json as bool;

  // ---- databases (read only)

  /// The database of the .zx archive at [path], or null when it has none.
  Future<ZxWebDatabase?> openDatabase(String path, {String? password}) async {
    final id =
        (await call('db.open', args: {'path': path, 'password': password})).json
            as int?;
    return id == null ? null : ZxWebDatabase._(this, id);
  }
}

/// The database of a .zx archive in the engine, read only.
class ZxWebDatabase {
  final ZxEngine _engine;
  final int _id;
  ZxWebDatabase._(this._engine, this._id);

  Future<ZxSqlResult> execute(String sql, [Object? params]) async {
    final r = await _engine.call('db.sql', args: {
      'db': _id,
      'sql': sql,
      'params': sqlParamsToWire(params),
    });
    return sqlResultFromWire((r.json as Map).cast());
  }

  Future<List<String>> kvStores() async => [
        for (final s in (await _engine.call('db.stores', args: {'db': _id}))
            .json as List)
          s as String
      ];

  Future<List<String>> seriesNames() async => [
        for (final s in (await _engine.call('db.series', args: {'db': _id}))
            .json as List)
          s as String
      ];

  Future<void> resetSql() => _engine.call('db.reset', args: {'db': _id});

  Future<void> close() => _engine.call('db.close', args: {'db': _id});
}
