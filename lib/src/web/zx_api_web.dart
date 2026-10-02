// ZxArchive of the web version (docs/architecture.md section 20): the same
// members as the native one (zx_api.dart) for reading, each a request to
// the engine worker (engine_client.dart). lib/zx_client.dart exports it in
// place of the native class when compiled for the browser, so the widgets
// of the app use either unchanged. Archives are read only here: the
// operations that write, and extracting to a folder, throw
// [SevenZipError.unsupported].
//
// Paths are those of the engine: /upload/N/NAME, /url/N/NAME,
// /opfs/NAME (see engine.dart).

import 'dart:async';
import 'dart:typed_data';

import '../format/zx/zx_seal_types.dart';
import '../io/streams.dart' show SevenZipException, SevenZipError;
import '../readme/readme.dart';
import '../readme/readme_links.dart' show checkReadme;
import '../util/tlsh.dart' show tlshDistance;
import '../zx_types.dart';
import 'engine_client.dart';
import 'wire.dart';

/// An archive of any supported format, read by the engine worker.
class ZxArchive {
  /// The archive (for a nested archive: the outermost one).
  final String path;

  /// Asked for passwords (see [ZxPasswordRequest]); may be set at any time.
  ZxPasswordCallback? onPassword;

  /// The archive this nested archive was opened from, null for an
  /// archive file.
  final ZxArchive? parent;

  /// The paths of the items from the outermost archive to this nested
  /// archive, empty for an archive file.
  final List<String> nestPath;

  /// The archive is shown as one tree with its nested archives.
  final bool flattened;

  /// .zx: the folders searched for the volumes of a set (none on the web).
  final List<String> searchDirs = const [];

  final int _h;
  ZxListing _listing;
  Map<String, ZxItem>? _byPath;
  Map<String, List<ZxItem>>? _children;
  bool _closed = false;

  ZxArchive._(this.path, this._h, this._listing, this.onPassword,
      {this.parent, this.nestPath = const [], this.flattened = false});

  static ZxEngine get _engine => ZxEngine.instance;

  /// Opens [path] (a path of the engine). See the native ZxArchive.open;
  /// [searchDirs] is ignored.
  static Future<ZxArchive> open(String path,
      {String? password,
      ZxPasswordCallback? onPassword,
      ZxCancelToken? cancel,
      bool flatten = false,
      int maxDepth = 4,
      int? version,
      String? date,
      List<String> searchDirs = const []}) async {
    if (version != null && version < 1) {
      throw ArgumentError.value(version, 'version', 'must be 1 or more');
    }
    final r = await _engine.call('open',
        args: {
          'path': path,
          'password': password,
          'canAsk': onPassword != null,
          'flatten': flatten,
          'maxDepth': maxDepth,
          'version': version,
          'date': date,
        },
        onPassword: onPassword,
        cancel: cancel);
    final m = r.json as Map;
    return ZxArchive._(path, m['h'] as int,
        listingFromWire((m['listing'] as Map).cast()), onPassword,
        flattened: flatten);
  }

  /// Opens the file [item] (a [ZxItem], a path or an index) as an archive
  /// of its own (see the native ZxArchive.openNested).
  Future<ZxArchive> openNested(Object item,
      {bool flatten = false, int maxDepth = 4, ZxCancelToken? cancel}) async {
    final it = _resolveFile(item, nested: true);
    final r = await _engine.call('openNested',
        args: {
          'h': _h,
          'chain': it.nestChain ?? [it.index],
          'flatten': flatten,
          'maxDepth': maxDepth,
          'canAsk': onPassword != null,
        },
        onPassword: onPassword,
        cancel: cancel);
    final m = r.json as Map;
    return ZxArchive._(path, m['h'] as int,
        listingFromWire((m['listing'] as Map).cast()), onPassword,
        parent: this, nestPath: [...nestPath, it.path], flattened: flatten);
  }

  /// Lets the engine forget the handle.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _engine.call('close', args: {'h': _h});
  }

  bool get isNested => parent != null;

  // ---- listing ----

  ZxListing get listing => _listing;
  String get format => _listing.format;
  List<String> get outerFormats => _listing.outerFormats;
  int get physicalSize => _listing.physicalSize;
  String? get method => _listing.method;
  bool get solid => _listing.solid;
  bool get encryptedHeaders => _listing.encryptedHeaders;
  String? get comment => _listing.comment;
  List<String> get errors => _listing.errors;
  List<String> get warnings => _listing.warnings;
  List<String> get volumes => _listing.volumes;
  List<ZxVersion> get versions => _listing.versions;
  int? get version => _listing.numVersions == 0 || _listing.versions.isEmpty
      ? null
      : _listing.versions.last.number;
  int get numVersions => _listing.numVersions;

  /// Nothing can be changed on the web.
  ZxCapabilities get capabilities => const ZxCapabilities();
  List<ZxItem> get items => _listing.items;
  String? get password => _listing.password;

  ZxItem? operator [](String path) =>
      (_byPath ??= {for (final i in items) i.path: i})[_norm(path)];

  List<ZxItem> children(String dir) {
    final c = _children ??= () {
      final m = <String, List<ZxItem>>{};
      for (final i in items) {
        (m[i.parent] ??= []).add(i);
      }
      return m;
    }();
    return c[_norm(dir)] ?? const [];
  }

  void _set(ZxListing l) {
    _listing = l;
    _byPath = null;
    _children = null;
  }

  Future<void> reload({ZxCancelToken? cancel}) async {
    final r = await _engine.call('reload',
        args: {'h': _h, 'canAsk': onPassword != null},
        onPassword: onPassword,
        cancel: cancel);
    _set(listingFromWire((r.json as Map).cast()));
  }

  // ---- reading ----

  /// Extracting to a folder is not possible in a browser: use [readBytes].
  Future<ZxExtractResult> extract(String outDir,
          {List<Object>? items,
          bool keepPaths = true,
          String? relativeTo,
          ZxOverwrite overwrite = ZxOverwrite.overwrite,
          ZxOverwriteCallback? onOverwrite,
          bool restoreTimes = true,
          bool restoreModes = true,
          bool restoreSymlinks = true,
          void Function(ZxProgress progress)? onProgress,
          ZxCancelToken? cancel}) =>
      throw _unsupported('extracting to a folder');

  Future<String> extractToTemp(Object item,
          {String? tempDir,
          void Function(ZxProgress progress)? onProgress,
          ZxCancelToken? cancel}) =>
      throw _unsupported('extracting to a folder');

  /// Decodes the [items] (default: all) and checks them.
  Future<ZxExtractResult> test(
      {List<Object>? items,
      void Function(ZxProgress progress)? onProgress,
      ZxCancelToken? cancel}) async {
    final (paths, indices) = _selection(items);
    final r = await _engine.call('test',
        args: {
          'h': _h,
          'paths': paths,
          'indices': indices,
          'canAsk': onPassword != null,
        },
        onProgress: onProgress,
        onPassword: onPassword,
        cancel: cancel);
    final m = r.json as Map;
    _rememberPassword(m['password'] as String?);
    return extractResultFromWire(m['result'] as List<Object?>);
  }

  ZxItem? readmeIn(String dir) {
    final files = <String, ZxItem>{};
    for (final i in children(dir)) {
      if (!i.isDir) files[i.name] = i;
    }
    final n = pickReadme(files.keys);
    return n == null ? null : files[n];
  }

  Future<ZxReadme?> readme({String dir = '', ZxCancelToken? cancel}) async {
    final item = readmeIn(dir);
    return item == null ? null : readmeOf(item, cancel: cancel);
  }

  /// The file [item] parsed as a README. The engine reads and parses it
  /// (at most [readmeMaxBytes]); only the check of its links runs here.
  Future<ZxReadme> readmeOf(ZxItem item, {ZxCancelToken? cancel}) async {
    final it = _resolveFile(item);
    final r = await _engine.call('readme',
        args: {
          'h': _h,
          'index': it.index,
          'name': it.name,
          'canAsk': onPassword != null,
        },
        onPassword: onPassword,
        cancel: cancel);
    final m = r.json as Map;
    _rememberPassword(m['password'] as String?);
    final doc = markdownFromWire((m['doc'] as Map).cast());
    final base = item.parent;
    final issues = checkReadme(doc, base, (p) => this[p] != null);
    return ZxReadme(item, base, doc, issues);
  }

  /// The data of one file (at most [maxBytes] bytes).
  Future<Uint8List> readBytes(Object item,
      {int? maxBytes, ZxCancelToken? cancel}) async {
    final it = _resolveFile(item);
    final r = await _engine.call('readBytes',
        args: {
          'h': _h,
          'index': it.index,
          'maxBytes': maxBytes,
          'canAsk': onPassword != null,
        },
        onPassword: onPassword,
        cancel: cancel);
    _rememberPassword((r.json as Map)['password'] as String?);
    return r.bytes ?? Uint8List(0);
  }

  Future<String?> probeNested(Object item, {ZxCancelToken? cancel}) async {
    final it = _resolveFile(item, nested: true);
    if (it.isDir) return it.nestedFormat;
    final r = await _engine.call('probeNested',
        args: {'h': _h, 'index': it.index, 'canAsk': onPassword != null},
        onPassword: onPassword,
        cancel: cancel);
    final m = r.json as Map;
    _rememberPassword(m['password'] as String?);
    return m['format'] as String?;
  }

  // ---- .zx ----

  /// .zx: the seals of the archive (see the native ZxArchive.seals).
  Future<List<ZxGenerationSeal>> seals({bool full = false}) async {
    if (format != 'zx') {
      throw SevenZipException(
          '$format: seals are for .zx archives', SevenZipError.unsupported);
    }
    final r = await _engine.call('seals', args: {'h': _h, 'full': full});
    return sealsFromWire(r.json as List<Object?>);
  }

  List<ZxItem> findBySha256(String sha256) {
    final h = sha256.toLowerCase();
    return [
      for (final i in items)
        if (i.sha256 == h) i
    ];
  }

  List<(ZxItem, int)> findSimilar(Object item, {int maxDistance = 100}) {
    String? digest;
    ZxItem? self;
    if (item is ZxItem) {
      self = item;
      digest = item.tlsh;
    } else if (item is String && item.startsWith('T1') && item.length == 72) {
      digest = item;
    } else if (item is String) {
      self = this[item];
      digest = self?.tlsh;
    }
    if (digest == null) return const [];
    final out = <(ZxItem, int)>[];
    for (final i in items) {
      final t = i.tlsh;
      if (t == null || identical(i, self)) continue;
      final d = tlshDistance(digest, t);
      if (d != null && d <= maxDistance) out.add((i, d));
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out;
  }

  // ---- helpers ----

  SevenZipException _unsupported(String what) => SevenZipException(
      '$what is not possible in the browser version',
      SevenZipError.unsupported);

  void _rememberPassword(String? pw) {
    if (pw != null && pw != _listing.password) {
      final l = _listing;
      _set(ZxListing(
          format: l.format,
          outerFormats: l.outerFormats,
          physicalSize: l.physicalSize,
          method: l.method,
          solid: l.solid,
          encryptedHeaders: l.encryptedHeaders,
          comment: l.comment,
          errors: l.errors,
          warnings: l.warnings,
          volumes: l.volumes,
          capabilities: l.capabilities,
          items: l.items,
          password: pw,
          sequential: l.sequential,
          versions: l.versions,
          numVersions: l.numVersions));
    }
  }

  ZxItem _resolveFile(Object item, {bool nested = false}) {
    ZxItem? it;
    if (item is ZxItem) {
      it = item;
    } else if (item is String) {
      it = this[item];
    } else if (item is int) {
      for (final i in items) {
        if (i.index == item) {
          it = i;
          break;
        }
      }
    }
    if (it == null || (it.isDir && !(nested && it.isNested)) || it.index < 0) {
      throw SevenZipException(
          '$item: no such file in the archive', SevenZipError.unsupported);
    }
    return it;
  }

  (List<String>?, List<int>?) _selection(List<Object>? items) {
    if (items == null) return (null, null);
    final paths = <String>[];
    final indices = <int>[];
    for (final o in items) {
      if (o is int) {
        indices.add(o);
      } else if (o is String) {
        paths.add(_norm(o));
      } else if (o is ZxItem) {
        if (o.index >= 0 && !o.isDir) {
          indices.add(o.index);
        } else {
          paths.add(o.path);
        }
      } else {
        throw ArgumentError.value(o, 'items', 'ZxItem, String or int');
      }
    }
    return (paths, indices);
  }
}

/// A path of an archive in the API's form (as zxNormalizePath, '/' only).
String _norm(String p) {
  if (!p.contains('/') && p != '.') return p;
  return [
    for (final s in p.split('/'))
      if (s.isNotEmpty && s != '.') s
  ].join('/');
}
