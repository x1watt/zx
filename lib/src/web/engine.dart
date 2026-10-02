// The engine of the web version (docs/architecture.md section 20): the
// library compiled with dart2wasm, running in a module Web Worker. The UI
// (engine_client.dart) sends requests {id, op, args}; the engine answers
// each with {id, ok, json[, bytes]} or {id, error}, and sends progress and
// questions (passwords) as events of the request on the way. Archives are
// read through [hostFiles] from three kinds of sources, by path:
//   /upload/N/NAME  a File the user picked or dropped (FileReaderSync)
//   /url/N/NAME     a URL read with range requests (HttpRangeInStream)
//   /opfs/NAME      an archive of the library (Library, read as a Blob)
// The operations are those of the isolates of the native API
// (zx_worker.dart: workerOpen, workerReadBytesRaw, workerProbe,
// workerExtract) with a ZxOps that talks to the UI through postMessage,
// and the database calls of ZxDatabase, read only.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../api_types.dart' show SevenZipProgress;
import '../cli/open_archive.dart' show cliCurrentDirectory;
import '../cli/nest.dart' show NestNodeSpec;
import '../db/zxdb.dart';
import '../format/zx/zx_seal.dart' show zxCheckSealsOfFile;
import '../io/streams.dart';
import '../readme/readme.dart' show parseReadme;
import '../version.dart';
import '../zx_api.dart';
import '../zx_worker.dart';
import 'blob_stream.dart';
import 'js_bindings.dart';
import 'library.dart';
import 'range_stream.dart';
import 'url_source.dart';
import 'wire.dart';

// ---------------------------------------------------------------------------
// Sources

/// A stream of its own position over a stream shared by every reader of
/// the source (its block cache stays warm between the operations).
class _View implements ClosableInStream {
  final SeekableInStream inner;
  @override
  int position = 0;
  _View(this.inner);

  @override
  int get length => inner.length;

  @override
  int read(Uint8List buf, int off, int len) {
    inner.position = position;
    final n = inner.read(buf, off, len);
    position += n;
    return n;
  }

  @override
  void close() {}
}

class _Source {
  final SeekableInStream stream;

  /// The File of an upload or a library archive (for Keep in library).
  final JSBlob? blob;
  _Source(this.stream, [this.blob]);
}

class _Files implements HostFiles {
  final Map<String, _Source> sources = {};

  @override
  int? sizeOf(String path) => sources[path]?.stream.length;

  @override
  ClosableInStream open(String path) {
    final s = sources[path];
    if (s == null) {
      throw SevenZipException('$path is not open', SevenZipError.io);
    }
    return _View(s.stream);
  }
}

/// The last component of a URL's path, for the name of the archive.
String urlFileName(String url) {
  var p = Uri.tryParse(url)?.path ?? url;
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  final n = Uri.decodeComponent(p.substring(p.lastIndexOf('/') + 1));
  return libraryName(n.isEmpty ? 'archive' : n);
}

// ---------------------------------------------------------------------------
// Requests

class EngineRequest {
  final int id;
  final Stopwatch _sw = Stopwatch()..start();
  int _last = -1000;
  EngineRequest(this.id);
}

final Map<int, Completer<Object?>> _answers = {};

/// Posts a message to the UI: [json] as JSON text (the UI parses it with
/// the browser's JSON.parse), the other fields as they are.
void _post(Map<String, Object?> m, [Uint8List? bytes]) {
  final o = JSObject();
  m.forEach((k, v) {
    o[k] = switch (v) {
      _ when k == 'json' => jsonEncode(v).toJS,
      null => null,
      int() => v.toJS,
      String() => v.toJS,
      bool() => v.toJS,
      _ => jsonEncode(v).toJS,
    };
  });
  if (bytes != null) {
    final buffer = (bytes.toJS as JSObject)['buffer'] as JSObject;
    o['bytes'] = buffer;
    jsPostMessage(o, [buffer].toJS);
  } else {
    jsPostMessage(o);
  }
}

/// [ZxOps] of a request: progress and questions go to the UI as events of
/// the request. Nothing is written to files, so nothing is registered.
class WebOps extends ZxOps {
  final EngineRequest r;
  WebOps(this.r);

  @override
  void progress(int done, int total, {String? file, bool force = false}) {
    final t = r._sw.elapsedMilliseconds;
    if (!force && t - r._last < 100) return;
    r._last = t;
    _post({
      'id': r.id,
      'event': 'progress',
      'json': progressToWire(SevenZipProgress(done, total, file)),
    });
  }

  @override
  Future<Object?> ask(Object request) {
    if (request is! ZxPasswordRequest) {
      return Future.value(null);
    }
    final c = Completer<Object?>();
    _answers[r.id] = c;
    _post({
      'id': r.id,
      'event': 'ask',
      'json': passwordRequestToWire(request),
    });
    return c.future;
  }

  @override
  void registerFile(String path) {}
  @override
  void unregisterFile(String path) {}
  @override
  void registerDir(String path) {}
  @override
  void unregisterDir(String path) {}
}

// ---------------------------------------------------------------------------
// Open archives

class _Handle {
  /// The archive file (the outermost one).
  final String path;
  String base;
  List<int> chain;
  List<NestNodeSpec>? layout;
  final bool flattened;
  final int maxDepth;
  final int? version;
  final bool nested;
  String? password;
  ZxListing listing;
  _Handle(this.path, this.base, this.chain, this.layout, this.flattened,
      this.maxDepth, this.version, this.nested, this.password, this.listing);

  int? get baseVersion => base == path ? version : null;
  ZxNest? get nest => flattened ? ZxNest(maxDepth, layout) : null;
}

class Engine {
  final _Files _files = _Files();
  final Library library = Library();
  final Map<int, _Handle> _handles = {};
  final Map<int, ZxDatabase> _dbs = {};
  int _next = 1;

  void start() {
    hostFiles = _files;
    // the engine's paths are absolute: no current folder to ask for
    cliCurrentDirectory = '/';
    jsOnMessage = ((JSMessageEvent e) => _onMessage(e.data as JSObject)).toJS;
    _post({
      'event': 'ready',
      'json': {'version': zxVersionString, 'library': Library.available},
    });
  }

  void _onMessage(JSObject m) {
    final id = (m['id'] as JSNumber).toDartInt;
    final op = (m['op'] as JSString).toDart;
    final a = m['args'];
    final args = a == null
        ? const <String, Object?>{}
        : (jsonDecode((a as JSString).toDart) as Map).cast<String, Object?>();
    if (op == 'answer') {
      _answers.remove(id)?.complete(args['answer']);
      return;
    }
    _run(id, op, args, m);
  }

  Future<void> _run(
      int id, String op, Map<String, Object?> args, JSObject m) async {
    final r = EngineRequest(id);
    try {
      final (json, bytes) = await _dispatch(r, op, args, m);
      _post({'id': id, 'ok': true, 'json': json}, bytes);
    } catch (e, st) {
      final w = errorToWire(e);
      if (w['type'] == 'other') w['message'] = '$e\n$st';
      _post({'id': id, 'ok': false, 'json': w});
    } finally {
      _answers.remove(id);
    }
  }

  _Handle _handle(Map<String, Object?> args) {
    final h = _handles[args['h'] as int];
    if (h == null) throw StateError('the archive is closed');
    return h;
  }

  int _add(_Handle h) {
    final n = _next++;
    _handles[n] = h;
    return n;
  }

  Map<String, Object?> _opened(int n, _Handle h) =>
      {'h': n, 'listing': listingToWire(h.listing)};

  ZxExtractRequest _request(_Handle h, ZxExtractMode mode,
          {List<int>? indices,
          List<String>? paths,
          int? maxBytes,
          bool canAsk = true}) =>
      ZxExtractRequest(
          archivePath: h.base,
          chain: h.chain,
          nest: h.nest,
          password: h.password,
          canAsk: canAsk,
          items: h.listing.sequential ? h.listing.items : null,
          mode: mode,
          paths: paths,
          indices: indices,
          maxBytes: maxBytes,
          version: h.baseVersion);

  void _remember(_Handle h, String? pw) {
    if (pw != null) h.password = pw;
  }

  Future<(Object?, Uint8List?)> _dispatch(
      EngineRequest r, String op, Map<String, Object?> args, JSObject m) async {
    final ops = WebOps(r);
    switch (op) {
      case 'upload':
        // one folder per upload: the volumes of a set are found by name
        final n = _next++;
        final list = (m['files'] as JSArray<JSFile>).toDart;
        final paths = <String>[];
        for (final f in list) {
          final p = '/upload/$n/${libraryName(f.name)}';
          _files.sources[p] = _Source(BlobInStream(f), f);
          paths.add(p);
        }
        return (paths, null);

      case 'forget':
        final prefix = args['prefix'] as String;
        _files.sources.removeWhere((k, _) => k.startsWith(prefix));
        return (null, null);

      case 'url':
        final url = args['url'] as String;
        final p = await probeUrl(url);
        final out = p.toJson();
        if (p.access == UrlAccess.range) {
          final path = '/url/${_next++}/${urlFileName(url)}';
          final s =
              HttpRangeInStream(XhrRangeTransport(url), p.size!, etag: p.etag)
                ..prefetch();
          _files.sources[path] = _Source(s);
          out['path'] = path;
        }
        out['name'] = urlFileName(url);
        return (out, null);

      case 'urlStats':
        final s = _files.sources[args['path'] as String]?.stream;
        if (s is! HttpRangeInStream) return (null, null);
        return ({'requests': s.requests, 'bytes': s.bytesFetched}, null);

      case 'library.list':
        final l = await library.list();
        return (
          {
            'entries': [for (final e in l) e.toJson()],
            'usage': await library.usage(),
          },
          null
        );

      case 'library.open':
        final name = args['name'] as String;
        final f = await library.file(name);
        final path = '/opfs/$name';
        _files.sources[path] = _Source(BlobInStream(f), f);
        return (path, null);

      case 'library.import':
        final src = _files.sources[args['path'] as String];
        final blob = src?.blob;
        if (blob == null) throw StateError('only an uploaded file is kept');
        final name = await library.freeName(args['name'] as String);
        final e = await library.importBlob(blob, name,
            progress: (d, t) => ops.progress(d, t, file: name));
        return (e.toJson(), null);

      case 'library.download':
        final name = await library.freeName(args['name'] as String);
        final e = await library.download(args['url'] as String, name,
            size: args['size'] as int?,
            progress: (d, t) => ops.progress(d, t, file: name));
        return (e.toJson(), null);

      case 'library.remove':
        final name = args['name'] as String;
        _files.sources.remove('/opfs/$name');
        await library.remove(name);
        return (null, null);

      case 'library.persist':
        return ((await jsStorage.persist().toDart).toDart, null);

      case 'open':
        final path = args['path'] as String;
        final flatten = args['flatten'] as bool? ?? false;
        final maxDepth = args['maxDepth'] as int? ?? 4;
        final version = args['version'] as int?;
        final res = await workerOpen(
            ZxOpenRequest(path, args['password'] as String?,
                args['canAsk'] as bool? ?? false,
                nest: flatten ? ZxNest(maxDepth) : null,
                version: version,
                versionDate: version == null ? args['date'] as String? : null),
            ops) as ZxOpenResult;
        final h = _Handle(path, res.base, res.chain, res.layout, flatten,
            maxDepth, version, false, res.listing.password, res.listing);
        return (_opened(_add(h), h), null);

      case 'openNested':
        final p = _handle(args);
        final flatten = args['flatten'] as bool? ?? false;
        final maxDepth = args['maxDepth'] as int? ?? 4;
        final chain = [
          ...p.chain,
          for (final x in args['chain'] as List) x as int
        ];
        final res = await workerOpen(
            ZxOpenRequest(p.base, p.password, args['canAsk'] as bool? ?? false,
                chain: chain,
                nest: flatten ? ZxNest(maxDepth) : null,
                readOnly: true,
                version: p.baseVersion),
            ops) as ZxOpenResult;
        final h = _Handle(p.path, res.base, res.chain, res.layout, flatten,
            maxDepth, p.version, true, res.listing.password, res.listing);
        return (_opened(_add(h), h), null);

      case 'reload':
        final h = _handle(args);
        final res = await workerOpen(
            ZxOpenRequest(h.base, h.password, args['canAsk'] as bool? ?? false,
                chain: h.chain,
                nest: h.flattened ? ZxNest(h.maxDepth) : null,
                readOnly: true,
                version: h.baseVersion),
            ops) as ZxOpenResult;
        h
          ..base = res.base
          ..chain = res.chain
          ..layout = res.layout
          ..listing = res.listing;
        _remember(h, res.listing.password);
        return (listingToWire(res.listing), null);

      case 'close':
        _handles.remove(args['h'] as int);
        return (null, null);

      case 'readBytes':
        final h = _handle(args);
        final (data, pw) = await workerReadBytesRaw(
            _request(h, ZxExtractMode.memory,
                indices: [args['index'] as int],
                maxBytes: args['maxBytes'] as int?,
                canAsk: args['canAsk'] as bool? ?? false),
            ops);
        _remember(h, pw);
        return ({'password': pw}, data);

      case 'readme':
        // the README is parsed here, off the UI's thread
        final h = _handle(args);
        final (data, pw) = await workerReadBytesRaw(
            _request(h, ZxExtractMode.memory,
                indices: [args['index'] as int],
                maxBytes: readmeMaxBytes,
                canAsk: args['canAsk'] as bool? ?? false),
            ops);
        _remember(h, pw);
        final doc = parseReadme(args['name'] as String, data,
            truncated: data.length >= readmeMaxBytes);
        return ({'doc': markdownToWire(doc), 'password': pw}, null);

      case 'probeNested':
        final h = _handle(args);
        final (name, pw) = await workerProbe(
            _request(h, ZxExtractMode.memory,
                indices: [args['index'] as int],
                canAsk: args['canAsk'] as bool? ?? false),
            ops) as (String?, String?);
        _remember(h, pw);
        return ({'format': name, 'password': pw}, null);

      case 'test':
        final h = _handle(args);
        final (res, pw) = await workerExtract(
            _request(h, ZxExtractMode.test,
                indices: (args['indices'] as List?)?.cast<int>(),
                paths: (args['paths'] as List?)?.cast<String>(),
                canAsk: args['canAsk'] as bool? ?? false),
            ops) as (ZxExtractResult, String?);
        _remember(h, pw);
        return ({'result': extractResultToWire(res), 'password': pw}, null);

      case 'seals':
        final h = _handle(args);
        final full = args['full'] as bool? ?? false;
        return (sealsToWire(zxCheckSealsOfFile(h.path, full: full)), null);

      case 'db.has':
        final db = _openDb(args);
        if (db == null) return (false, null);
        db.close();
        return (true, null);

      case 'db.open':
        final db = _openDb(args);
        if (db == null) return (null, null);
        final n = _next++;
        _dbs[n] = db;
        return (n, null);

      case 'db.sql':
        final res = _db(args)
            .sql
            .execute(args['sql'] as String, sqlParamsFromWire(args['params']));
        return (sqlResultToWire(res), null);

      case 'db.stores':
        return (_db(args).kvStores, null);

      case 'db.series':
        return (_db(args).seriesNames, null);

      case 'db.reset':
        _db(args).resetSql();
        return (null, null);

      case 'db.close':
        _dbs.remove(args['db'] as int)?.close();
        return (null, null);
    }
    throw ArgumentError('unknown request $op');
  }

  ZxDatabase _db(Map<String, Object?> args) {
    final db = _dbs[args['db'] as int];
    if (db == null) throw StateError('the database is closed');
    return db;
  }

  /// The database of a .zx archive, read only; null when it has none.
  ZxDatabase? _openDb(Map<String, Object?> args) {
    final db = ZxDatabase.open(args['path'] as String,
        password: args['password'] as String?, readOnly: true);
    if (db.store.root == null) {
      db.close();
      return null;
    }
    return db;
  }
}
