// The worker side of zx_api.dart: runs in the background isolate of one
// operation. It opens archives with the format layer of the command line
// tool (Codecs.load, ArchiveLink.open of open_archive.dart: signatures,
// extensions, compressed tars, split and RAR volumes), extracts with its
// own extract callback (IArchiveExtractCallback: part files, per item
// errors, overwrite decisions, times, modes and links) and updates with
// its own update callback (IArchiveUpdateCallback) over the handlers'
// UpdateItems, as UI/Common/Update.cpp does.
//
// The handlers are synchronous and ask for passwords synchronously. A
// question for the caller's isolate needs an asynchronous round trip, so
// the worker asks before the synchronous part when it can (encrypted items
// in the listing, existing files for the overwrite decisions); when a
// handler asks unexpectedly, the synchronous part is unwound (_NeedPassword),
// the question is asked and the operation continues where it stopped (the
// items already extracted are not extracted again, an update starts over
// with a new part file).

import 'dart:async';
import 'dart:convert';
import 'host/io.dart';
import 'dart:isolate';
import 'dart:typed_data';

import 'api.dart';
import 'common/method_props.dart' show PropVariant;
import 'cli/arc_compound.dart';
import 'cli/arc_handlers.dart';
import 'cli/arc_rar.dart';
import 'cli/arc_tar.dart';
import 'cli/arc_zip.dart';
import 'cli/arc_zpaq.dart';
import 'cli/arc_zx.dart';
import 'cli/common.dart';
import 'cli/extracting_file_path.dart' show getCorrectFsFileName;
import 'cli/fs_utils.dart';
import 'cli/load_codecs.dart';
import 'cli/nest.dart' show NestNodeSpec, NestSniffer;
import 'cli/open_archive.dart';
import 'cli/platform.dart';
import 'cli/update.dart' show rarVolumePath;
import 'cli/wildcard.dart' show extractFileNameFromPath;
import 'format/archive_types.dart';
import 'format/split.dart';
import 'format/zx/zx_format.dart' show zxHex;
import 'format/zx/zx_handler.dart' show ZxTimelineVersion;
import 'format/zx/zx_writer.dart' show ZxVolumeDir;
import 'sync_pool.dart' show syncPoolRegisterDir, syncPoolUnregisterDir;
import 'io/streams.dart';
import 'zx_api.dart';

// ---------------------------------------------------------------------------
// Requests (sent to the worker isolate)

enum ZxExtractMode { extract, test, memory }

enum ZxUpdateKind { create, add, delete, rename, createFolder, setComment }

class ZxOpenRequest {
  /// The file the [chain] starts from (the archive, or a temporary file
  /// holding a nested archive).
  final String archivePath;
  final String? password;
  final bool canAsk;

  /// Item indices from the archive at [archivePath] to the nested archive
  /// to open (empty: that archive itself).
  final List<int> chain;

  /// Shows the archive as one tree with its nested archives.
  final ZxNest? nest;

  /// The listing is read only (a nested archive).
  final bool readOnly;

  /// A journaling archive (zpaq) is shown as of this version (the
  /// listing is then read only); null: the last one.
  final int? version;

  /// A .zx archive is shown as of this date (YYYY-MM-DD[ HH:MM[:SS]]).
  final String? versionDate;

  /// Folders where the volumes of a .zx set may be.
  final List<String> searchDirs;
  const ZxOpenRequest(this.archivePath, this.password, this.canAsk,
      {this.chain = const [],
      this.nest,
      this.readOnly = false,
      this.version,
      this.versionDate,
      this.searchDirs = const []});
}

// the search folders of .zx volumes for the operation of this isolate
List<String> _zxSearchDirs = const [];
String? _zxVersionDate;

/// The flattened tree of a request: its depth, and the nested archives
/// found when it was opened (null: look for them).
class ZxNest {
  final int maxDepth;
  final List<NestNodeSpec>? layout;
  const ZxNest(this.maxDepth, [this.layout]);
}

/// The result of [workerOpen].
class ZxOpenResult {
  final ZxListing listing;

  /// Where the operations open the archive: [base] then the items of
  /// [chain] (a nested archive whose parent has no random access to its
  /// items was copied to a temporary file, which becomes the base).
  final String base;
  final List<int> chain;
  final List<NestNodeSpec>? layout;

  /// Temporary folders the handle deletes when it is closed.
  final List<String> temps;
  const ZxOpenResult(
      this.listing, this.base, this.chain, this.layout, this.temps);
}

class ZxExtractRequest {
  final String archivePath;
  final String? password;
  final bool canAsk;

  /// See [ZxOpenRequest.chain] and [ZxOpenRequest.nest].
  final List<int> chain;
  final ZxNest? nest;

  /// The listing of the handle, for an archive read in one pass (listing
  /// it again means decoding it again); null: the worker reads it.
  final List<ZxItem>? items;
  final ZxExtractMode mode;
  final List<String>? paths;
  final List<int>? indices;
  final String? outDir;
  final bool keepPaths;
  final String? relativeTo;
  final ZxOverwrite overwrite;
  final bool restoreTimes;
  final bool restoreModes;
  final bool restoreSymlinks;
  final int? maxBytes;

  /// See [ZxOpenRequest.version].
  final int? version;

  /// See [ZxOpenRequest.searchDirs].
  final List<String> searchDirs;

  const ZxExtractRequest({
    required this.archivePath,
    required this.password,
    required this.canAsk,
    this.chain = const [],
    this.nest,
    this.items,
    required this.mode,
    this.paths,
    this.indices,
    this.outDir,
    this.keepPaths = true,
    this.relativeTo,
    this.overwrite = ZxOverwrite.overwrite,
    this.restoreTimes = false,
    this.restoreModes = false,
    this.restoreSymlinks = false,
    this.maxBytes,
    this.version,
    this.searchDirs = const [],
  });
}

class ZxUpdateRequest {
  final ZxUpdateKind kind;
  final String archivePath;
  final String? password;
  final bool canAsk;
  final String? format;
  final List<ZxSource> sources;
  final ZxOptions options;
  final String destination;
  final List<String> paths;
  final String? newPath;
  final String? comment;
  final bool overwrite;

  /// See [ZxOpenRequest.searchDirs].
  final List<String> searchDirs;

  const ZxUpdateRequest({
    required this.kind,
    required this.archivePath,
    required this.password,
    required this.canAsk,
    this.format,
    this.sources = const [],
    this.options = const ZxOptions(),
    this.destination = '',
    this.paths = const [],
    this.newPath,
    this.comment,
    this.overwrite = false,
    this.searchDirs = const [],
  });
}

/// A path of an archive in the API's form: '/' separators (and '\' on
/// Windows read as one), no leading or trailing '/', no '.' components,
/// no empty components.
String zxNormalizePath(String p) {
  if (Platform.isWindows) p = p.replaceAll('\\', '/');
  if (!p.contains('/') && p != '.') return p;
  final parts = <String>[];
  for (final s in p.split('/')) {
    if (s.isEmpty || s == '.') continue;
    parts.add(s);
  }
  return parts.join('/');
}

// the folder for the decoded inner archive of a compound one (x.tar.gz in
// a nested chain); none in the web engine, which reads it in one pass
String? _tempBase() => hostFiles != null
    ? null
    : '${Directory.systemTemp.path}${Platform.pathSeparator}';

bool _isUnder(String name, String dir) =>
    dir.isEmpty ||
    name == dir ||
    (name.length > dir.length &&
        name.startsWith(dir) &&
        name.codeUnitAt(dir.length) == 0x2F);

// ---------------------------------------------------------------------------
// The isolate

typedef ZxBody = Future<Object?> Function(ZxOps ops);

/// The worker side of one operation: throttled progress, questions for the
/// caller, the files it writes (deleted if the operation is cancelled or
/// fails) and its temporary folders. [ZxIsolateOps] talks to the caller's
/// isolate; the web engine has its own (lib/src/web).
abstract class ZxOps {
  void progress(int done, int total, {String? file, bool force = false});

  /// Asks the caller ([ZxPasswordRequest], [ZxOverwriteRequest]).
  Future<Object?> ask(Object request);

  /// Registers [path] for deletion if the operation does not finish.
  void registerFile(String path);
  void unregisterFile(String path);
  void registerDir(String path);
  void unregisterDir(String path);

  /// The temporary name of [path] while it is written.
  String partFor(String path) {
    final p = '$path.zx-part';
    registerFile(p);
    return p;
  }

  /// Renames a finished [part] to [path].
  void commit(String part, String path) {
    if (Platform.isWindows &&
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      File(path).deleteSync();
    }
    File(part).renameSync(path);
    unregisterFile(part);
  }

  void discard(String part) {
    try {
      File(part).deleteSync();
    } on FileSystemException {
      // already gone
    }
    unregisterFile(part);
  }
}

/// [ZxOps] of an operation running in its own isolate.
class ZxIsolateOps extends ZxOps {
  final SendPort _port;
  final bool _wantProgress;
  final Stopwatch _sw = Stopwatch()..start();
  int _last = -1000;
  late final RawReceivePort _replies;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;

  ZxIsolateOps(this._port, this._wantProgress) {
    _replies = RawReceivePort((Object? m) {
      if (m case (final int id, final Object? answer)) {
        _pending.remove(id)?.complete(answer);
      }
    });
    _port.send(('reply', _replies.sendPort));
  }

  void close() => _replies.close();

  @override
  void progress(int done, int total, {String? file, bool force = false}) {
    if (!_wantProgress) return;
    final t = _sw.elapsedMilliseconds;
    if (force || t - _last >= 100) {
      _last = t;
      _port.send(('p', SevenZipProgress(done, total, file)));
    }
  }

  @override
  Future<Object?> ask(Object request) {
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _port.send(('ask', id, request));
    return c.future;
  }

  @override
  void registerFile(String path) => _port.send(('f+', path));
  @override
  void unregisterFile(String path) => _port.send(('f-', path));
  @override
  void registerDir(String path) => _port.send(('d+', path));
  @override
  void unregisterDir(String path) => _port.send(('d-', path));
}

Future<void> zxIsolateMain((SendPort, ZxBody, bool) args) async {
  final (port, body, wantProgress) = args;
  final ops = ZxIsolateOps(port, wantProgress);
  // the temporary folders of the .zx block workers are deleted if the
  // operation is cancelled
  syncPoolRegisterDir = ops.registerDir;
  syncPoolUnregisterDir = ops.unregisterDir;
  Object? r;
  try {
    r = await body(ops);
  } catch (e, st) {
    ops.close();
    final err = _toPublicError(e);
    try {
      port.send(('err', err, st.toString()));
    } catch (_) {
      port.send(('err', err.toString(), st.toString()));
    }
    return;
  }
  ops.close();
  Isolate.exit(port, ('ok', r));
}

/// The errors that leave the worker: [SevenZipException] (its subclasses
/// too) and [ArgumentError] as they are, the others as
/// [SevenZipException].
Object _toPublicError(Object e) {
  if (e is SevenZipException || e is ArgumentError) return e;
  if (e is FileSystemException) {
    return SevenZipException(
        '${e.message}${e.path == null ? '' : ': ${e.path}'}'
        '${e.osError == null ? '' : ' (${e.osError!.message})'}',
        SevenZipError.io);
  }
  if (e is SystemException) return _hresError(e.errorCode, null);
  if (e is StringException) {
    return SevenZipException(e.message, SevenZipError.unsupported);
  }
  if (e is _NeedPassword) {
    return const SevenZipException(
        'A password is needed', SevenZipError.wrongPassword);
  }
  return SevenZipException('$e', SevenZipError.io);
}

SevenZipException _hresError(int hr, String? path) {
  final p = path == null ? '' : ': $path';
  switch (hr) {
    case HRes.eAbort:
      return SevenZipException('Cancelled$p', SevenZipError.cancelled);
    case HRes.eNotImpl:
    case HRes.eInvalidArg:
      return SevenZipException(
          '${myFormatMessage(hr)}$p', SevenZipError.unsupported);
    case HRes.sFalse:
      return SevenZipException(
          'Can not open the file as archive$p', SevenZipError.isNotArc);
  }
  return SevenZipException('${myFormatMessage(hr)}$p', SevenZipError.io);
}

/// A handler asked for a password that the worker does not have yet.
class _NeedPassword implements Exception {
  const _NeedPassword();
}

/// The archive was not opened and a password was asked for it.
class _WrongPassword implements Exception {
  const _WrongPassword();
}

/// Item [level] of a chain has no stream (the handler has no random
/// access to its items).
class _NoStream implements Exception {
  final int level;
  const _NoStream(this.level);
}

// ---------------------------------------------------------------------------
// Opening

class _OpenUi extends OpenCallbackUI {
  final String? password;
  bool asked = false;
  _OpenUi(this.password);

  @override
  String openCryptoGetTextPassword() {
    asked = true;
    final p = password;
    if (p == null) throw const _NeedPassword();
    return p;
  }
}

class _Opened {
  final Codecs codecs;
  final ArchiveLink link;
  final String path;
  final String? password;
  final bool passwordAsked;

  /// The archives around a nested one, outermost first.
  final List<ArchiveLink> outer;
  _Opened(this.codecs, this.link, this.path, this.password, this.passwordAsked,
      [this.outer = const []]);

  Arc get arc => link.arcs.last;
  InArchive get archive => link.arcs.last.archive!;

  void close() {
    link.close();
    link.release();
    for (final l in outer.reversed) {
      l.close();
      l.release();
    }
  }
}

List<int> _excludedFormats(Codecs codecs) {
  final h = codecs.findFormatForArchiveType('Hash');
  return h < 0 ? const [] : [h];
}

_Opened _openSync(Codecs codecs, String path, String? password,
    {String? compoundTempDir,
    List<int> chain = const [],
    ZxNest? nest,
    int? version}) {
  final ui = _OpenUi(password);
  final links = <ArchiveLink>[];
  var asked = false;
  void closeAll() {
    for (final l in links.reversed) {
      l.close();
    }
  }

  // the archive, then each nested archive of the chain from the stream of
  // its item in the level before
  for (var k = 0; k <= chain.length; k++) {
    final link = ArchiveLink();
    final op = OpenOptions()
      ..codecs = codecs
      ..types = const []
      ..excludedFormats = _excludedFormats(codecs)
      ..stdInMode = false
      ..filePath = path
      ..compoundTempDir = compoundTempDir
      ..version = k == 0 ? version : null
      ..versionDate = k == 0 && version == null ? _zxVersionDate : null
      ..zxSearchDirs = k == 0 ? _zxSearchDirs : const [];
    if (k > 0) {
      final parent = links.last.arcs.last;
      final index = chain[k - 1];
      SeekableInStream? s;
      try {
        if (index >= 0 && index < parent.archive!.numberOfItems) {
          s = parent.archive!.getStream(index);
          op.filePath = extractFileNameFromPath(parent.getItemPath(index));
        }
      } on Object {
        s = null;
      }
      if (s == null) {
        closeAll();
        throw _NoStream(k - 1);
      }
      op.stream = s;
      op.compoundTempDir ??= _tempBase();
    }
    if (k == chain.length && nest != null) {
      op
        ..nestDepth = nest.maxDepth
        ..nestLayout = nest.layout
        ..nestKeepTemps = nest.layout == null;
    }
    int res;
    try {
      res = link.openStrict(op, ui, null);
    } on SystemException catch (e) {
      link.close();
      closeAll();
      throw _hresError(e.errorCode, path);
    } on SevenZipException catch (e) {
      link.close();
      closeAll();
      // a handler that checks the password itself (.zx with encrypted
      // names): asked again like the others
      if (e.kind == SevenZipError.wrongPassword &&
          (ui.asked || link.passwordWasAsked)) {
        throw const _WrongPassword();
      }
      rethrow;
    } catch (_) {
      link.close();
      closeAll();
      rethrow;
    }
    if (res != HRes.sOk) {
      link.close();
      closeAll();
      if (ui.asked || link.passwordWasAsked) throw const _WrongPassword();
      throw _hresError(res, path);
    }
    asked = asked || link.passwordWasAsked;
    links.add(link);
  }
  return _Opened(codecs, links.last, path, password, ui.asked || asked,
      links.sublist(0, links.length - 1));
}

/// Opens [path], asking the caller's isolate for a password as long as
/// the names can not be read.
Future<_Opened> _openAsk(
    Codecs codecs, String path, String? password, bool canAsk, ZxOps ops,
    {String? compoundTempDir,
    List<int> chain = const [],
    ZxNest? nest,
    int? version}) async {
  var attempt = 0;
  var retry = false;
  var pw = password;
  for (;;) {
    try {
      return _openSync(codecs, path, pw,
          compoundTempDir: compoundTempDir,
          chain: chain,
          nest: nest,
          version: version);
    } on _NeedPassword {
      retry = false;
    } on _WrongPassword {
      retry = true;
    }
    if (!canAsk) {
      throw SevenZipException(
          retry
              ? 'Wrong password: $path'
              : 'The archive is encrypted, a password is needed: $path',
          SevenZipError.wrongPassword);
    }
    final a = await ops.ask(ZxPasswordRequest(path, ZxPasswordReason.open,
        retry: retry, attempt: attempt++));
    if (a is! String) {
      throw SevenZipException(
          'No password given: $path', SevenZipError.cancelled);
    }
    pw = a;
  }
}

// ---------------------------------------------------------------------------
// Listing

const List<String> _kErrorFlagsMessages = [
  'Is not archive',
  'Headers Error',
  'Headers Error in encrypted archive. Wrong password?',
  'Unavailable start of archive',
  'Unconfirmed start of archive',
  'Unexpected end of archive',
  'There are data after the end of archive',
  'Unsupported method',
  'Unsupported feature',
  'Data Error',
  'CRC Error',
];

List<String> _flagsText(int flags) => [
      for (var i = 0; i < _kErrorFlagsMessages.length; i++)
        if ((flags & (1 << i)) != 0) _kErrorFlagsMessages[i],
    ];

String _itemPath(Arc arc, int i) {
  var p = arc.getItemPath(i);
  if (kIsWin) p = p.replaceAll('\\', '/');
  return zxNormalizePath(p);
}

DateTime? _time(Object? v) => v is int && v != 0 ? fileTimeToDateTime(v) : null;

const Set<String> _kMultiItemFormats = {
  '7z',
  'zip',
  'tar',
  'Rar5',
  'Lzh',
  'Arj',
  'zpaq',
  'zx'
};
const Set<String> _kEncryptFormats = {'7z', 'zip', 'Rar5', 'Arj', 'zx'};

ZxListing _readListing(_Opened o, {bool readOnly = false}) {
  final codecs = o.codecs;
  final link = o.link;
  final arc = o.arc;
  final a = o.archive;
  final flat = link.flat;
  if (arc.isSeq) {
    // a compound tar read in one pass: every header is read now
    a.numberOfItems;
    arc.refreshSeqErrors();
  }
  final n = a.numberOfItems;
  final items = <ZxItem>[];
  final explicitDirs = <String>{};
  final all = <String>{};
  for (var i = 0; i < n; i++) {
    if (arc.isItemAnti(i)) continue;
    final path = _itemPath(arc, i);
    final isDir = archiveIsItemDir(a, i);
    final attrib = a.getProperty(i, Kpid.attrib);
    var posix = a.getProperty(i, Kpid.posixAttrib);
    if (posix is! int && attrib is int && (attrib & 0x8000) != 0) {
      posix = (attrib >> 16) & 0xFFFF;
    }
    String? str(int pid) {
      final v = a.getProperty(i, pid);
      return v is String && v.isNotEmpty ? v : null;
    }

    int? num(int pid) {
      final v = a.getProperty(i, pid);
      return v is int ? v : null;
    }

    items.add(ZxItem(
      index: i,
      path: path,
      isDir: isDir,
      size: num(Kpid.size),
      packSize: num(Kpid.packSize),
      modified: _time(a.getProperty(i, Kpid.mTime)),
      created: _time(a.getProperty(i, Kpid.cTime)),
      accessed: _time(a.getProperty(i, Kpid.aTime)),
      attrib: attrib is int ? attrib : null,
      posixMode: posix is int ? posix : null,
      crc: num(Kpid.crc),
      method: str(Kpid.method),
      encrypted: a.getProperty(i, Kpid.encrypted) == true,
      symlinkTarget: str(Kpid.symLink),
      hardlinkTarget: str(Kpid.hardLink),
      comment: str(Kpid.comment),
      nestChain: flat?.chainOf(i),
      nestedFormat: flat?.nestedFormatOf(i),
      sha256: str(Kpid.sha256),
      tlsh: str(ZxKpid.tlsh),
      generation: num(ZxKpid.version),
    ));
    if (isDir) explicitDirs.add(path);
    all.add(path);
  }
  // the folders implied by the paths
  final implied = <String>{};
  for (final p in all) {
    var s = p.lastIndexOf('/');
    while (s > 0) {
      final d = p.substring(0, s);
      if (explicitDirs.contains(d) || !implied.add(d)) break;
      s = d.lastIndexOf('/');
    }
  }
  final impliedList = implied.toList()..sort();
  for (final d in impliedList) {
    if (all.contains(d)) continue; // a file with the name of a folder
    items.add(ZxItem(index: -1, path: d, isDir: true, isImplied: true));
  }

  final fmt = codecs.getFormatNamePtr(arc.formatIndex);
  final outer = [
    for (var k = 0; k < link.arcs.length - 1; k++)
      codecs.getFormatNamePtr(link.arcs[k].formatIndex)
  ];
  final errors = <String>[];
  final warnings = <String>[];
  for (final x in link.arcs) {
    final ei = x.errorInfo;
    errors.addAll(_flagsText(ei.getErrorFlags()));
    if (ei.errorMessage.isNotEmpty) errors.add(ei.errorMessage);
    warnings.addAll(_flagsText(ei.getWarningFlags()));
    if (ei.warningMessage.isNotEmpty) warnings.add(ei.warningMessage);
  }
  if (flat != null) {
    // the nested archives, with the folders that show them
    for (final (prefix, ei) in flat.nestedErrors) {
      final p = zxNormalizePath(kIsWin ? prefix.replaceAll('\\', '/') : prefix);
      for (final m in _flagsText(ei.getWarningFlags())) {
        warnings.add('$p: $m');
      }
      if (ei.warningMessage.isNotEmpty) {
        warnings.add('$p: ${ei.warningMessage}');
      }
    }
  }

  final zxArc = a is ZxArc ? a : null;
  final multiVolume = zxArc == null &&
      (link.volumePaths.isNotEmpty ||
          link.arcs
              .any((x) => codecs.getFormatNamePtr(x.formatIndex) == 'Split'));
  var canUpdate = !multiVolume &&
      a.supportsUpdate &&
      fmt != 'Rar' &&
      fmt != 'Split' &&
      link.arcs.first.arcStreamOffset == 0 &&
      !(arc.errorInfo.thereIsTail && !arc.errorInfo.ignoreTail);
  if (arc.compoundOuterIndex >= 0) {
    // read in one pass here; an update decodes the tar to a temporary
    // file and writes it again through the compressor
    canUpdate = !multiVolume &&
        link.arcs.length == 2 &&
        codecs.formats[arc.compoundOuterIndex].updateEnabled;
  } else if (link.arcs.length > 1) {
    canUpdate = false;
  }
  if (readOnly || flat != null || o.outer.isNotEmpty) canUpdate = false;
  final multi = _kMultiItemFormats.contains(fmt);
  final caps = ZxCapabilities(
    canAdd: canUpdate && multi,
    canDelete: canUpdate && multi,
    canRename: canUpdate && (multi || fmt == 'gzip'),
    canCreateFolder: canUpdate && multi,
    canSetComment: canUpdate && (fmt == 'zip' || fmt == 'Rar5'),
    canEncrypt: canUpdate && _kEncryptFormats.contains(fmt),
    canEncryptHeaders: canUpdate && (fmt == '7z' || fmt == 'Rar5' || fmt == 'zx'),
  );

  // a journaling archive: its versions
  var versions = const <ZxVersion>[];
  var numVersions = 0;
  // (of the archive itself when its nested archives are shown)
  final za = flat?.inner ?? a;
  if (za is ZpaqArc) {
    versions = [
      for (final v in za.h.versions)
        ZxVersion(v.number, fileTimeToDateTime(v.time).toUtc(), v.added,
            v.deleted, v.packSize)
    ];
    numVersions = za.h.numVersions;
  } else if (za is ZxArc) {
    final zr = za.h.reader;
    if (zr != null) {
      final gens = zr.generations;
      final shown = zr.shownGeneration;
      versions = [
        for (final g in gens)
          if (g.number <= shown)
            ZxVersion(g.number, g.dateTime, g.added, g.deleted, g.packed)
      ];
      // the number of the last one (a compaction keeps the numbers)
      numVersions = gens.isEmpty ? 0 : gens.last.number;
    }
  }

  final phy = a.getArchiveProperty(Kpid.phySize);
  var physicalSize = phy is int ? phy : arc.fileSize;
  if (arc.compoundOuterIndex >= 0 || link.arcs.length > 1) {
    physicalSize = link.arcs.first.fileSize + link.volumesSize;
  } else if (link.volumesSize > 0) {
    physicalSize = arc.fileSize + link.volumesSize;
  }
  final m = a.getArchiveProperty(Kpid.method);
  final solid = a.getArchiveProperty(Kpid.solid);
  final comment = a.getArchiveProperty(Kpid.comment);
  return ZxListing(
    format: fmt,
    outerFormats: outer,
    physicalSize: physicalSize,
    method: m is String && m.isNotEmpty ? m : null,
    solid: solid == true,
    encryptedHeaders: o.passwordAsked,
    comment: comment is String && comment.isNotEmpty ? comment : null,
    errors: errors,
    warnings: warnings,
    volumes: zxArc != null ? _zxVolumes(zxArc) : _volumes(o),
    capabilities: caps,
    items: items,
    password: o.password,
    sequential: arc.isSeq,
    versions: versions,
    numVersions: numVersions,
  );
}

/// The volume files of a .zx set (empty for one file).
List<String> _zxVolumes(ZxArc a) {
  final r = a.h.reader;
  if (r == null || !r.header.multiVolume) return const [];
  return r.volumes.paths;
}

/// The files of a multi-volume archive: the one that was opened, then the
/// others (ArchiveLink gives their names relative to its folder).
List<String> _volumes(_Opened o) {
  final v = o.link.volumePaths;
  if (v.isEmpty) return const [];
  final sep = Platform.pathSeparator;
  final dir = o.path.substring(0, o.path.lastIndexOf(sep) + 1);
  return [
    o.path,
    for (final p in v)
      if (p.startsWith(sep) || (kIsWin && p.contains(':'))) p else '$dir$p'
  ];
}

/// [ZxArchive.open], [ZxArchive.openNested], [ZxArchive.reload]:
/// a [ZxOpenResult].
Future<Object?> workerOpen(ZxOpenRequest r, ZxOps ops) async {
  final codecs = Codecs.load();
  _zxSearchDirs = r.searchDirs;
  _zxVersionDate = r.versionDate;
  var base = r.archivePath;
  var chain = r.chain;
  var pw = r.password;
  final temps = <String>[];
  try {
    for (;;) {
      _Opened o;
      try {
        o = await _openAsk(codecs, base, pw, r.canAsk, ops,
            chain: chain,
            nest: r.nest,
            version: base == r.archivePath ? r.version : null);
      } on _NoStream catch (e) {
        // no random access to the item: it is copied to a temporary
        // file, which becomes the start of the chain
        final (file, dir) = await _itemToTempFile(codecs, base,
            chain.sublist(0, e.level), chain[e.level], pw, r.canAsk, ops,
            version: base == r.archivePath ? r.version : null);
        temps.add(dir);
        base = file;
        chain = chain.sublist(e.level + 1);
        continue;
      }
      try {
        pw = o.password;
        final t = o.link.flat?.tempFolder;
        if (t != null) {
          ops.registerDir(t);
          temps.add(t);
        }
        final l = _readListing(o,
            readOnly: r.readOnly ||
                temps.isNotEmpty ||
                r.version != null ||
                r.versionDate != null);
        for (final d in temps) {
          ops.unregisterDir(d);
        }
        return ZxOpenResult(l, base, chain, o.link.flat?.layout, temps);
      } finally {
        o.close();
      }
    }
  } catch (_) {
    for (final d in temps) {
      try {
        Directory(d).deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    }
    rethrow;
  }
}

/// Copies item [index] of the archive at [base] + [chain] into a new
/// temporary folder: (the file, the folder).
Future<(String, String)> _itemToTempFile(Codecs codecs, String base,
    List<int> chain, int index, String? password, bool canAsk, ZxOps ops,
    {int? version}) async {
  final o = await _openAsk(codecs, base, password, canAsk, ops,
      chain: chain, version: version);
  try {
    final a = o.archive;
    if (index < 0 || index >= a.numberOfItems) {
      throw SevenZipException(
          'Item #$index not found in the archive', SevenZipError.unsupported);
    }
    var name = extractFileNameFromPath(o.arc.getItemPath(index));
    if (kIsWin) name = getCorrectFsFileName(name);
    if (name.isEmpty || name == '.' || name == '..') name = 'item';
    if (hostFiles != null) {
      // the web engine has no temporary folder
      throw SevenZipException(
          '${o.arc.getItemPath(index)}: this nested archive can only be '
          'opened from a temporary copy, which the browser version does not '
          'make',
          SevenZipError.unsupported);
    }
    final dir = Directory.systemTemp.createTempSync('zx_nest_').path;
    ops.registerDir(dir);
    final path = _join(dir, name);
    final out = FileOutStream.create(path);
    final cb = _ItemToFile(out, index, o.password);
    try {
      if (o.arc.isSeq) {
        a.extract(null, false, cb);
      } else {
        a.extract([index], false, cb);
      }
      out.flush();
    } finally {
      out.close();
    }
    if (cb.result != OperationResult.ok) {
      throw SevenZipException(
          '${o.arc.getItemPath(index)}: can not be read', SevenZipError.data);
    }
    return (path, dir);
  } finally {
    o.close();
  }
}

class _ItemToFile extends ArchiveExtractCallback
    implements CryptoGetTextPassword {
  final OutStream out;
  final int index;
  final String? password;
  int result = -1;
  bool _cur = false;
  _ItemToFile(this.out, this.index, this.password);

  @override
  OutStream? getStream(int index, int askMode) {
    _cur = index == this.index && askMode == AskMode.extract;
    return _cur ? out : null;
  }

  @override
  void setOperationResult(int opRes) {
    if (_cur) result = opRes;
    _cur = false;
  }

  @override
  String cryptoGetTextPassword() => password ?? '';
}

// ---------------------------------------------------------------------------
// Extraction

/// The selected items by index (null: all).
Set<int>? _select(List<ZxItem> items, List<String>? paths, List<int>? indices) {
  if (paths == null && indices == null) return null;
  final sel = <int>{...?indices};
  if (paths != null && paths.isNotEmpty) {
    for (final it in items) {
      if (it.index < 0) continue;
      for (final p in paths) {
        if (_isUnder(it.path, p)) {
          sel.add(it.index);
          break;
        }
      }
    }
  }
  return sel;
}

/// The relative output path of [path] ('/' separated, made safe), null
/// when nothing is left.
String? _relTarget(String path, bool keepPaths, String? relativeTo) {
  var p = path;
  if (relativeTo != null &&
      relativeTo.isNotEmpty &&
      p.length > relativeTo.length &&
      _isUnder(p, relativeTo)) {
    p = p.substring(relativeTo.length + 1);
  }
  final parts = <String>[];
  for (var s in p.split('/')) {
    if (s.isEmpty || s == '.' || s == '..') continue;
    if (Platform.isWindows) s = getCorrectFsFileName(s);
    parts.add(s);
  }
  if (parts.isEmpty) return null;
  if (!keepPaths) return parts.last;
  return parts.join('/');
}

String _join(String dir, String rel) {
  final sep = Platform.pathSeparator;
  final r = sep == '/' ? rel : rel.replaceAll('/', sep);
  return dir.endsWith(sep) ? '$dir$r' : '$dir$sep$r';
}

enum _Decision { overwrite, skip, rename }

/// Output that counts what goes through and reports progress.
class _CountOut implements OutStream {
  final OutStream? inner;
  final _Extractor owner;
  int count = 0;
  _CountOut(this.inner, this.owner);

  @override
  void write(Uint8List buf, int off, int len) {
    inner?.write(buf, off, len);
    count += len;
    owner._written(len);
  }

  @override
  void flush() => inner?.flush();
}

/// Thrown when [ZxExtractRequest.maxBytes] bytes were read.
class _StopRead implements Exception {
  const _StopRead();
}

/// Output of [ZxExtractMode.memory] with a limit.
class _MemOut implements OutStream {
  final BytesBuilder data = BytesBuilder(copy: true);
  final int? limit;
  _MemOut(this.limit);

  @override
  void write(Uint8List buf, int off, int len) {
    final l = limit;
    if (l != null && data.length + len >= l) {
      data.add(Uint8List.sublistView(buf, off, off + (l - data.length)));
      throw const _StopRead();
    }
    data.add(Uint8List.sublistView(buf, off, off + len));
  }

  @override
  void flush() {}
}

class _PostLink {
  final String diskPath;
  final String rel;
  final String target;
  final String itemPath;
  final DateTime? mTime;
  _PostLink(this.diskPath, this.rel, this.target, this.itemPath, this.mTime);
}

/// IArchiveExtractCallback of the API.
class _Extractor extends ArchiveExtractCallback
    implements CryptoGetTextPassword, ArchiveExtractCallbackMessage2 {
  final ZxExtractRequest req;
  final ZxOps ops;
  final Map<int, ZxItem> byIndex;
  final Set<int>? selected;
  final Map<int, _Decision> decisions;
  final int total;
  String? password;

  /// No password could be had: the handlers get an empty one.
  bool noPassword = false;

  // results
  final Set<int> doneIndices = {};
  final Map<int, ZxItemError> errors = {};
  int files = 0, dirs = 0, bytes = 0, skipped = 0;
  int doneBytes = 0;
  _MemOut? mem;

  final List<(String, ZxItem)> _dirs = [];
  final List<_PostLink> _links = [];
  final List<(String, String, ZxItem)> _hardLinks = [];

  // the current item
  ZxItem? _cur;
  int _curIndex = -1;
  _CountOut? _out;
  FileOutStream? _file;
  String? _part;
  String? _target;
  String? _rel;
  BytesBuilder? _linkData;
  bool _isLink = false;
  bool _skipping = false;

  _Extractor(this.req, this.ops, this.byIndex, this.selected, this.decisions,
      this.total, this.password);

  String? get _outDir => req.outDir;

  void _written(int n) {
    doneBytes += n;
    ops.progress(doneBytes, total, file: _cur?.path);
  }

  /// Extracts the items not done yet from [o].
  void run(_Opened o) {
    final a = o.archive;
    final test = req.mode == ZxExtractMode.test;
    if (o.arc.isSeq) {
      a.extract(null, test, this);
    } else {
      final List<int> indices;
      final sel = selected;
      if (sel == null) {
        indices = [
          for (var i = 0; i < a.numberOfItems; i++)
            if (!doneIndices.contains(i)) i
        ];
      } else {
        indices = [
          for (final i in sel)
            if (!doneIndices.contains(i) && i < a.numberOfItems) i
        ]..sort();
      }
      if (indices.isEmpty) return;
      a.extract(indices, test, this);
    }
    _closeCurrent(false);
  }

  bool _wanted(int index) {
    final sel = selected;
    return (sel == null || sel.contains(index)) && !doneIndices.contains(index);
  }

  @override
  OutStream? getStream(int index, int askMode) {
    _closeCurrent(false);
    if (askMode == AskMode.skip || !_wanted(index)) return null;
    final it = byIndex[index];
    if (it == null) return null;
    _cur = it;
    _curIndex = index;
    ops.progress(doneBytes, total, file: it.path);
    switch (req.mode) {
      case ZxExtractMode.test:
        return _out = _CountOut(null, this);
      case ZxExtractMode.memory:
        return mem = _MemOut(req.maxBytes);
      case ZxExtractMode.extract:
        break;
    }
    final outDir = _outDir!;
    if (it.isDir) {
      if (!req.keepPaths) return null;
      final rel = _relTarget(it.path, true, req.relativeTo);
      if (rel == null) return null;
      final p = _join(outDir, rel);
      Directory(p).createSync(recursive: true);
      _dirs.add((p, it));
      return null;
    }
    final rel = _relTarget(it.path, req.keepPaths, req.relativeTo);
    if (rel == null) return null;
    var target = _join(outDir, rel);
    final type = FileSystemEntity.typeSync(target, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      final d = decisions[index] ??
          switch (req.overwrite) {
            ZxOverwrite.skip => _Decision.skip,
            ZxOverwrite.rename => _Decision.rename,
            _ => _Decision.overwrite,
          };
      switch (d) {
        case _Decision.skip:
          _skipping = true;
          return null;
        case _Decision.rename:
          target = autoRenamePath(target) ?? target;
        case _Decision.overwrite:
          if (type == FileSystemEntityType.directory) {
            try {
              Directory(target).deleteSync();
            } on FileSystemException {
              _error(index, SevenZipError.io, 'A folder with this name exists');
              _skipping = true;
              return null;
            }
          }
      }
    }
    _target = target;
    _rel = rel;
    final hard = it.hardlinkTarget;
    if (hard != null) {
      _hardLinks.add((target, hard, it));
      return null;
    }
    if (it.isSymlink) {
      if (!req.restoreSymlinks) {
        _skipping = true;
        return null;
      }
      _isLink = true;
      _linkData = BytesBuilder();
      return _out = _CountOut(_LinkSink(_linkData!), this);
    }
    File(target).parent.createSync(recursive: true);
    final part = ops.partFor(target);
    _part = part;
    _file = FileOutStream.create(part);
    return _out = _CountOut(_file, this);
  }

  void _error(int index, SevenZipError kind, [String? message]) {
    final it = byIndex[index];
    errors[index] = ZxItemError(it?.path ?? '#$index', kind, message);
  }

  // closes the output of the current item; [ok] commits it
  void _closeCurrent(bool ok) {
    final f = _file;
    if (f != null) {
      _file = null;
      try {
        f.flush();
      } finally {
        f.close();
      }
    }
    final part = _part;
    if (part != null) {
      _part = null;
      if (ok) {
        ops.commit(part, _target!);
      } else {
        ops.discard(part);
      }
    }
    if (!ok) {
      _cur = null;
      _curIndex = -1;
      _out = null;
      _target = _rel = null;
      _linkData = null;
      _isLink = false;
      _skipping = false;
    }
  }

  static SevenZipError _kindOf(int opRes, bool encrypted) {
    if (opRes == OperationResult.wrongPassword) {
      return SevenZipError.wrongPassword;
    }
    if (encrypted &&
        (opRes == OperationResult.dataError ||
            opRes == OperationResult.crcError)) {
      return SevenZipError.wrongPassword;
    }
    return opRes >= 1 && opRes <= 9
        ? SevenZipError.values[opRes - 1]
        : SevenZipError.data;
  }

  @override
  void setOperationResult(int opRes) {
    final it = _cur;
    final index = _curIndex;
    if (it == null) {
      _closeCurrent(false);
      return;
    }
    final ok = opRes == OperationResult.ok;
    if (!ok) {
      _closeCurrent(false);
      _error(index, _kindOf(opRes, it.encrypted));
      doneIndices.add(index);
      return;
    }
    final target = _target;
    final count = _out?.count ?? 0;
    if (req.mode != ZxExtractMode.extract) {
      if (it.isDir) {
        dirs++;
      } else {
        files++;
        bytes += count;
      }
    } else if (_skipping) {
      skipped++;
    } else if (it.isDir) {
      if (req.keepPaths) dirs++;
    } else if (_isLink && target != null) {
      final data = _linkData!.takeBytes();
      final t = it.symlinkTarget ??
          (data.isEmpty ? null : utf8.decode(data, allowMalformed: true));
      if (t != null) {
        _links.add(_PostLink(target, _rel!, t, it.path, it.modified));
      }
      files++;
    } else if (it.hardlinkTarget != null) {
      files++;
    } else if (target != null) {
      final hadPart = _part != null;
      _closeCurrent(true);
      if (!hadPart) {
        // no data was asked for: an empty file
        File(target).parent.createSync(recursive: true);
        File(target).writeAsBytesSync(const []);
      }
      _setFileProps(target, it);
      files++;
      bytes += count;
    }
    doneIndices.add(index);
    _closeCurrent(false);
  }

  void _setFileProps(String path, ZxItem it) {
    if (req.restoreTimes) {
      final m = it.modified, a = it.accessed;
      setFileTimes(path, m == null ? null : dateTimeToFileTime(m),
          a == null ? null : dateTimeToFileTime(a));
    }
    if (req.restoreModes) {
      final mode = it.posixMode;
      if (mode != null && !kIsWin) {
        setFileAttribPosixHighDetect(path, 0x8000 | ((mode & 0xFFFF) << 16));
      } else if (kIsWin && it.attrib != null) {
        setFileAttribPosixHighDetect(path, it.attrib!);
      }
    }
  }

  @override
  void reportExtractResult(int indexType, int index, int opRes) {
    if (indexType != EventIndexType.inArcIndex || index < 0) return;
    if (opRes == OperationResult.ok || !_wanted(index)) return;
    if (errors.containsKey(index)) return;
    _error(index, _kindOf(opRes, byIndex[index]?.encrypted ?? false));
  }

  @override
  String cryptoGetTextPassword() {
    final p = password;
    if (p != null) return p;
    if (noPassword) return '';
    throw const _NeedPassword();
  }

  /// Links, hard links (a copy where the file system can not link),
  /// modes and folder times, after every file.
  void finish() {
    _closeCurrent(false);
    final outDir = _outDir;
    if (req.mode != ZxExtractMode.extract || outDir == null) return;
    for (final l in _links) {
      final problem = _linkProblem(outDir, l.rel, l.target);
      if (problem != null) {
        errors[-1 - errors.length] =
            ZxItemError(l.itemPath, SevenZipError.unsupported, problem);
        continue;
      }
      try {
        final t = FileSystemEntity.typeSync(l.diskPath, followLinks: false);
        if (t == FileSystemEntityType.directory) {
          Directory(l.diskPath).deleteSync();
        } else if (t != FileSystemEntityType.notFound) {
          File(l.diskPath).deleteSync();
        }
        File(l.diskPath).parent.createSync(recursive: true);
        Link(l.diskPath)
            .createSync(kIsWin ? l.target.replaceAll('/', '\\') : l.target);
        final m = l.mTime;
        if (req.restoreTimes && m != null && !kIsWin) {
          setDirOrLinkMTime(l.diskPath, dateTimeToFileTime(m), 0, link: true);
        }
      } on FileSystemException catch (e) {
        errors[-1 - errors.length] =
            ZxItemError(l.itemPath, SevenZipError.io, e.message);
      }
    }
    for (final (target, hard, it) in _hardLinks) {
      final rel =
          _relTarget(zxNormalizePath(hard), req.keepPaths, req.relativeTo);
      final src = rel == null ? null : _join(outDir, rel);
      try {
        if (src == null || !File(src).existsSync()) {
          throw FileSystemException(
              'The target of the hard link is missing', hard);
        }
        File(target).parent.createSync(recursive: true);
        if (!createHardLinkOrCopy(src, target)) {
          throw FileSystemException('Cannot create hard link', target);
        }
        _setFileProps(target, it);
      } on FileSystemException catch (e) {
        errors[-1 - errors.length] =
            ZxItemError(it.path, SevenZipError.io, e.message);
      }
    }
    if (req.restoreModes) {
      for (final (p, it) in _dirs) {
        final mode = it.posixMode;
        if (mode != null && !kIsWin) {
          setFileAttribPosixHighDetect(p, 0x8000 | ((mode & 0xFFFF) << 16));
        }
      }
    }
    flushFileAttribs((path, code) {
      errors[-1 - errors.length] =
          ZxItemError(path, SevenZipError.io, 'Cannot set file attribute');
    });
    if (req.restoreTimes) {
      // children first
      final ds = List.of(_dirs)
        ..sort((a, b) =>
            '/'.allMatches(b.$1).length.compareTo('/'.allMatches(a.$1).length));
      for (final (p, it) in ds) {
        final m = it.modified;
        if (m != null) setDirOrLinkMTime(p, dateTimeToFileTime(m), 0);
      }
    }
  }

  ZxExtractResult result() => ZxExtractResult(
      files, dirs, bytes, skipped, errors.values.toList(growable: false));
}

class _LinkSink implements OutStream {
  final BytesBuilder b;
  _LinkSink(this.b);
  @override
  void write(Uint8List buf, int off, int len) {
    if (b.length + len > (1 << 16)) {
      throw const SevenZipException('Link target too long');
    }
    b.add(Uint8List.sublistView(buf, off, off + len));
  }

  @override
  void flush() {}
}

/// Why the link [rel] -> [target] must not be created (it would point
/// outside the output folder, or its path goes through another link).
String? _linkProblem(String outDir, String rel, String target) {
  final t = target.replaceAll('\\', '/');
  if (t.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(t)) {
    return 'Dangerous link path was ignored: $target';
  }
  final parts = rel.split('/');
  var level = parts.length - 1;
  for (final s in t.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      level--;
      if (level < 0) return 'Dangerous link path was ignored: $target';
    } else {
      level++;
    }
  }
  var p = outDir;
  for (var i = 0; i < parts.length - 1; i++) {
    p = _join(p, parts[i]);
    if (FileSystemEntity.isLinkSync(p)) {
      return 'Dangerous link via another link was ignored: $target';
    }
  }
  return null;
}

/// [ZxArchive.extract], [ZxArchive.test], [ZxArchive.extractToTemp].
Future<Object?> workerExtract(ZxExtractRequest r, ZxOps ops) async {
  _zxSearchDirs = r.searchDirs;
  final ex = await _extractAll(r, ops);
  return (ex.$1.result(), ex.$2);
}

/// [ZxArchive.readBytes].
Future<Object?> workerReadBytes(ZxExtractRequest r, ZxOps ops) async {
  final (data, pw) = await workerReadBytesRaw(r, ops);
  return (TransferableTypedData.fromList([data]), pw);
}

/// [workerReadBytes] without the isolate transfer: (the bytes, the
/// password).
Future<(Uint8List, String?)> workerReadBytesRaw(
    ZxExtractRequest r, ZxOps ops) async {
  _zxSearchDirs = r.searchDirs;
  final (ex, pw) = await _extractAll(r, ops);
  final data = ex.mem?.data.takeBytes() ?? Uint8List(0);
  final reached = r.maxBytes != null && data.length >= r.maxBytes!;
  if (ex.errors.isNotEmpty && !reached) {
    final e = ex.errors.values.first;
    throw SevenZipException('${e.path}: ${e.message ?? e.kind.name}', e.kind);
  }
  if (ex.doneIndices.isEmpty && ex.mem == null && !reached) {
    throw SevenZipException(
        'Item not found in the archive', SevenZipError.unsupported);
  }
  return (data, pw);
}

/// [ZxArchive.probeNested]: (the format name of the item, or null; the
/// password). The item is read through the handler's stream when it has
/// one (only the start of it, for the signatures; an item of a container
/// format that matches none is tried with the full detection), else the
/// start of it is decoded into memory.
Future<Object?> workerProbe(ZxExtractRequest r, ZxOps ops) async {
  _zxSearchDirs = r.searchDirs;
  final codecs = Codecs.load();
  final index = r.indices!.single;
  final sniffer = NestSniffer(codecs);
  final o = await _openAsk(codecs, r.archivePath, r.password, r.canAsk, ops,
      chain: r.chain, nest: r.nest, version: r.version);
  var pw = o.password;
  try {
    final a = o.archive;
    if (index < 0 || index >= a.numberOfItems) {
      throw SevenZipException(
          'Item #$index not found in the archive', SevenZipError.unsupported);
    }
    if (archiveIsItemDir(a, index)) return (null, pw);
    SeekableInStream? s;
    try {
      s = a.getStream(index);
    } on Object {
      s = null;
    }
    if (s != null) {
      final f = sniffer.formatOf(s);
      if (f >= 0) return (codecs.formats[f].name, pw);
      final container =
          r.nest == null && codecs.formats[o.arc.formatIndex].isContainer;
      if (!container) return (null, pw);
      // an item of a container: every format may hold it
      s.position = 0;
      final link = ArchiveLink();
      final op = OpenOptions()
        ..codecs = codecs
        ..types = const []
        ..excludedFormats = _excludedFormats(codecs)
        ..stdInMode = false
        ..filePath = extractFileNameFromPath(o.arc.getItemPath(index))
        ..stream = s
        ..compoundTempDir = _tempBase();
      try {
        final res = link.openStrict(op, _OpenUi(pw), null);
        if (res == HRes.sOk) {
          return (codecs.getFormatNamePtr(link.arcs.last.formatIndex), pw);
        }
      } on Object {
        // not an archive
      } finally {
        link.close();
        link.release();
      }
      return (null, pw);
    }
  } finally {
    o.close();
  }
  // no random access: the start of the item, decoded
  final req = ZxExtractRequest(
      archivePath: r.archivePath,
      password: pw,
      canAsk: r.canAsk,
      chain: r.chain,
      nest: r.nest,
      items: r.items,
      mode: ZxExtractMode.memory,
      indices: [index],
      maxBytes: sniffer.bytesNeeded,
      version: r.version);
  final (ex, pw2) = await _extractAll(req, ops);
  final data = ex.mem?.data.takeBytes() ?? Uint8List(0);
  final f = sniffer.formatOfBytes(data, data.length);
  return (f >= 0 ? codecs.formats[f].name : null, pw2);
}

Future<(_Extractor, String?)> _extractAll(ZxExtractRequest r, ZxOps ops) async {
  final codecs = Codecs.load();
  var pw = r.password;
  var items = r.items;
  if (items == null) {
    final o = await _openAsk(codecs, r.archivePath, pw, r.canAsk, ops,
        chain: r.chain, nest: r.nest, version: r.version);
    try {
      pw = o.password;
      items = _readListing(o).items;
    } finally {
      o.close();
    }
  }
  final byIndex = {
    for (final it in items)
      if (it.index >= 0) it.index: it
  };
  final selected = _select(items, r.paths, r.indices);
  final chosen = [
    for (final it in items)
      if (it.index >= 0 && (selected == null || selected.contains(it.index))) it
  ];
  var total = 0;
  for (final it in chosen) {
    if (!it.isDir) total += it.size ?? 0;
  }

  // the overwrite questions, before anything is written
  final decisions = <int, _Decision>{};
  if (r.mode == ZxExtractMode.extract && r.overwrite == ZxOverwrite.ask) {
    final planned = <String>{};
    _Decision? all;
    for (final it in chosen) {
      if (it.isDir) continue;
      final rel = _relTarget(it.path, r.keepPaths, r.relativeTo);
      if (rel == null) continue;
      final t = _join(r.outDir!, rel);
      FileStat? st;
      final st0 = FileStat.statSync(t);
      if (st0.type != FileSystemEntityType.notFound) st = st0;
      if (st != null || planned.contains(t)) {
        if (all != null) {
          decisions[it.index] = all;
        } else {
          final a = await ops.ask(ZxOverwriteRequest(t, it.path,
              existingSize: st?.size,
              existingModified: st?.modified,
              newSize: it.size,
              newModified: it.modified));
          final d = switch (a) {
            ZxOverwriteAnswer.overwrite ||
            ZxOverwriteAnswer.overwriteAll =>
              _Decision.overwrite,
            ZxOverwriteAnswer.rename ||
            ZxOverwriteAnswer.renameAll =>
              _Decision.rename,
            ZxOverwriteAnswer.skip ||
            ZxOverwriteAnswer.skipAll =>
              _Decision.skip,
            _ => throw const SevenZipException(
                'Cancelled', SevenZipError.cancelled),
          };
          decisions[it.index] = d;
          if (a == ZxOverwriteAnswer.overwriteAll ||
              a == ZxOverwriteAnswer.renameAll ||
              a == ZxOverwriteAnswer.skipAll) {
            all = d;
          }
        }
      }
      planned.add(t);
    }
  }

  var attempt = 0;
  final ex = _Extractor(r, ops, byIndex, selected, decisions, total, pw);
  // encrypted items: the password is asked before the first one
  if (pw == null && r.canAsk && chosen.any((it) => it.encrypted)) {
    final a = await ops.ask(ZxPasswordRequest(
        r.archivePath, ZxPasswordReason.extract,
        itemPath: chosen.firstWhere((it) => it.encrypted).path,
        attempt: attempt++));
    if (a is String) {
      pw = ex.password = a;
    } else {
      ex.noPassword = true;
    }
  }
  if (r.outDir != null && r.mode == ZxExtractMode.extract) {
    Directory(r.outDir!).createSync(recursive: true);
  }
  try {
    for (;;) {
      final o = await _openAsk(codecs, r.archivePath, pw, r.canAsk, ops,
          chain: r.chain, nest: r.nest, version: r.version);
      if (o.password != pw) pw = ex.password = o.password;
      var needPassword = false;
      try {
        ex.run(o);
      } on _NeedPassword {
        ex._closeCurrent(false);
        needPassword = true;
      } on _StopRead {
        ex._closeCurrent(false);
        break;
      } on SystemException catch (e) {
        ex._closeCurrent(false);
        throw _hresError(e.errorCode, r.archivePath);
      } finally {
        o.close();
      }
      if (needPassword) {
        String? a;
        if (r.canAsk) {
          final x = await ops.ask(ZxPasswordRequest(
              r.archivePath, ZxPasswordReason.extract,
              itemPath: null, attempt: attempt++));
          if (x is String) a = x;
        }
        if (a == null) {
          ex.noPassword = true;
        } else {
          pw = ex.password = a;
        }
        continue;
      }
      // wrong password: ask again and extract the failed items again
      final wrong = [
        for (final e in ex.errors.entries)
          if (e.key >= 0 && e.value.kind == SevenZipError.wrongPassword) e.key
      ];
      if (wrong.isNotEmpty && r.canAsk && !ex.noPassword) {
        final x = await ops.ask(ZxPasswordRequest(
            r.archivePath, ZxPasswordReason.extract,
            itemPath: byIndex[wrong.first]?.path,
            retry: true,
            attempt: attempt++));
        if (x is String) {
          pw = ex.password = x;
          for (final i in wrong) {
            ex.errors.remove(i);
            ex.doneIndices.remove(i);
          }
          continue;
        }
      }
      break;
    }
  } finally {
    ex.finish();
  }
  ops.progress(ex.doneBytes, total, force: true);
  return (ex, pw);
}

// ---------------------------------------------------------------------------
// Updating

/// A file or folder found by the scan of the sources.
class _Scanned {
  final String disk;
  final String stored;
  final FileSystemEntityType type;
  final FileStat stat;
  final String? linkTarget;
  _Scanned(this.disk, this.stored, this.type, this.stat, this.linkTarget);
}

void _scan(String disk, String stored, bool storeLinks, List<_Scanned> out,
    List<String> skipped, Set<String> exclude) {
  if (exclude.contains(disk)) return;
  var type = FileSystemEntity.typeSync(disk, followLinks: false);
  String? linkTarget;
  if (type == FileSystemEntityType.link) {
    if (storeLinks) {
      try {
        linkTarget = Link(disk).targetSync();
      } on FileSystemException {
        skipped.add(disk);
        return;
      }
    } else {
      type = FileSystemEntity.typeSync(disk);
      // a link to a folder is skipped: following it could loop
      if (type != FileSystemEntityType.file) {
        skipped.add(disk);
        return;
      }
    }
  }
  if (type == FileSystemEntityType.notFound) {
    skipped.add(disk);
    return;
  }
  final stat = type == FileSystemEntityType.link
      ? Link(disk).statSync()
      : FileStat.statSync(disk);
  if (stored.isNotEmpty) {
    out.add(_Scanned(disk, stored, type, stat, linkTarget));
  }
  if (type == FileSystemEntityType.directory) {
    final List<FileSystemEntity> children;
    try {
      children = Directory(disk).listSync(followLinks: false);
    } on FileSystemException {
      skipped.add(disk);
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final c in children) {
      final name =
          c.path.substring(c.path.lastIndexOf(Platform.pathSeparator) + 1);
      _scan(c.path, stored.isEmpty ? name : '$stored/$name', storeLinks, out,
          skipped, exclude);
    }
  }
}

/// One item of the new archive.
class _UItem {
  final int oldIndex;
  final bool newData;
  final bool newProps;

  /// The new path ('/' separated) of a renamed or new item.
  final String? path;
  final _Scanned? disk;
  final bool isDir;
  final int? mTime;
  _UItem.keep(this.oldIndex)
      : newData = false,
        newProps = false,
        path = null,
        disk = null,
        isDir = false,
        mTime = null;
  _UItem.renamed(this.oldIndex, String this.path)
      : newData = false,
        newProps = true,
        disk = null,
        isDir = false,
        mTime = null;
  _UItem.fromDisk(_Scanned this.disk, {this.oldIndex = -1})
      : newData = true,
        newProps = true,
        path = disk.stored,
        isDir = disk.type == FileSystemEntityType.directory,
        mTime = null;
  _UItem.folder(String this.path, this.mTime)
      : oldIndex = -1,
        newData = true,
        newProps = true,
        disk = null,
        isDir = true;
}

String _storedPath(String p) => kIsWin ? p.replaceAll('/', '\\') : p;

/// An input file for a handler: counts what is read, closed by the
/// handler (ReleasableStream) or at the end of the update.
class _CountIn implements InStream, StreamGetSize, ReleasableStream {
  final FileInStream f;
  final _UpdateCallback owner;
  bool _closed = false;
  _CountIn(this.f, this.owner);

  @override
  int read(Uint8List buf, int off, int len) {
    final n = f.read(buf, off, len);
    owner._read(n);
    return n;
  }

  @override
  int? get streamSize => f.length;

  @override
  void release() {
    if (_closed) return;
    _closed = true;
    try {
      f.close();
    } on Object {
      // ignore
    }
  }
}

/// IArchiveUpdateCallback of the API.
class _UpdateCallback extends ArchiveUpdateCallback
    implements
        ArchiveUpdateCallbackFile,
        CryptoGetTextPassword2,
        CryptoGetTextPassword {
  final List<_UItem> items;
  final InArchive? old;
  final Arc? oldArc;
  final String? newPassword;
  final String? oldPassword;
  final ZxOps ops;
  final int newTotal;
  final List<String> skipped = [];
  final List<_CountIn> _open = [];
  int _readBytes = 0;
  String? _current;
  int _handlerTotal = 0;

  _UpdateCallback(this.items, this.old, this.oldArc, this.newPassword,
      this.oldPassword, this.ops, this.newTotal);

  void _read(int n) {
    _readBytes += n;
    ops.progress(_readBytes, newTotal, file: _current);
  }

  void releaseAll() {
    for (final s in _open) {
      s.release();
    }
    _open.clear();
  }

  @override
  void setTotal(int total) => _handlerTotal = total;

  @override
  void setCompleted(int completeValue) {
    if (newTotal == 0) {
      ops.progress(completeValue, _handlerTotal, file: _current);
    }
  }

  @override
  UpdateItemInfo getUpdateItemInfo(int index) {
    final it = items[index];
    return UpdateItemInfo(it.newData, it.newProps, it.oldIndex);
  }

  @override
  Object? getProperty(int index, int propId) {
    final it = items[index];
    if (!it.newData) {
      if (propId == Kpid.path && it.path != null) return _storedPath(it.path!);
      return old?.getProperty(it.oldIndex, propId);
    }
    final d = it.disk;
    switch (propId) {
      case Kpid.path:
        return _storedPath(it.path!);
      case Kpid.isDir:
        return it.isDir;
      case Kpid.isAnti:
        return false;
    }
    if (d == null) {
      // a new folder
      switch (propId) {
        case Kpid.size:
          return 0;
        case Kpid.mTime:
          return it.mTime;
        case Kpid.attrib:
          return kIsWin
              ? FileAttrib.directory
              : winAttribFromPosixMode(0x4000 | 0x1ED);
        case Kpid.posixAttrib:
          return kIsWin ? null : 0x4000 | 0x1ED;
      }
      return null;
    }
    final isLink = d.type == FileSystemEntityType.link;
    final perm = d.stat.mode & 0xFFF;
    final typeBits = it.isDir ? 0x4000 : (isLink ? 0xA000 : 0x8000);
    switch (propId) {
      case Kpid.size:
        if (it.isDir) return 0;
        if (isLink) return utf8.encode(d.linkTarget!).length;
        return d.stat.size;
      case Kpid.mTime:
        return dateTimeToFileTime(d.stat.modified);
      case Kpid.aTime:
        return dateTimeToFileTime(d.stat.accessed);
      case Kpid.cTime:
        return dateTimeToFileTime(d.stat.changed);
      case Kpid.attrib:
        if (kIsWin) {
          var a = it.isDir ? FileAttrib.directory : FileAttrib.archive;
          if ((perm & 0x92) == 0) a |= FileAttrib.readOnly;
          return a;
        }
        return winAttribFromPosixMode(typeBits | (isLink ? 0x1FF : perm));
      case Kpid.posixAttrib:
        return kIsWin ? null : typeBits | (isLink ? 0x1FF : perm);
      case Kpid.symLink:
        return isLink ? d.linkTarget : null;
    }
    return null;
  }

  @override
  InStream? getStream(int index) => getStream2(index,
      items[index].oldIndex < 0 ? UpdateNotifyOp.add : UpdateNotifyOp.update);

  @override
  InStream? getStream2(int index, int notifyOp) {
    final it = items[index];
    if (!it.newData) throw const SystemException(HRes.eFail);
    _current = it.path;
    ops.progress(_readBytes, newTotal, file: _current, force: false);
    final d = it.disk;
    if (it.isDir || d == null) return null;
    if (d.type == FileSystemEntityType.link) {
      return MemoryInStream(Uint8List.fromList(utf8.encode(d.linkTarget!)));
    }
    FileInStream f;
    try {
      f = FileInStream.open(d.disk);
    } on FileSystemException {
      skipped.add(d.disk);
      return null;
    }
    final s = _CountIn(f, this);
    _open.add(s);
    return s;
  }

  @override
  void reportOperation(int indexType, int index, int notifyOp) {
    if (indexType == EventIndexType.inArcIndex && index >= 0) {
      final a = oldArc;
      if (a != null) {
        try {
          _current = _itemPath(a, index);
        } on Object {
          // ignore
        }
      }
    } else if (indexType == EventIndexType.outArcIndex &&
        index >= 0 &&
        index < items.length) {
      _current = items[index].path ?? _current;
    }
  }

  @override
  String? cryptoGetTextPassword2() => newPassword;

  @override
  String cryptoGetTextPassword() {
    final p = oldPassword;
    if (p == null) throw const _NeedPassword();
    return p;
  }
}

bool _anyEncrypted(InArchive a) {
  for (var i = 0; i < a.numberOfItems; i++) {
    if (a.getProperty(i, Kpid.encrypted) == true) return true;
  }
  return false;
}

/// The -m switches of [o] for the format [fmt].
List<MapEntry<String, String>> _props(
    String fmt, ZxOptions o, bool compound, bool hasPassword) {
  final r = <MapEntry<String, String>>[];
  if (o.level != null) r.add(MapEntry('x', '${o.level}'));
  final m = o.method;
  if (m != null && !compound) {
    if (fmt == '7z') r.add(MapEntry('0', m));
    if (fmt == 'zip') r.add(MapEntry('m', m));
    if (fmt == 'zpaq') r.add(MapEntry('m', m));
    if (fmt == 'zx') r.add(MapEntry('0', m));
  }
  final s = o.solid;
  if (s != null &&
      (fmt == '7z' || fmt == 'Rar5' || fmt == 'Rar' || fmt == 'zx')) {
    r.add(MapEntry('s', s ? 'on' : 'off'));
  }
  final he = o.encryptHeaders;
  if (he != null &&
      hasPassword &&
      (fmt == '7z' || fmt == 'Rar5' || fmt == 'Rar' || fmt == 'zx')) {
    r.add(MapEntry('he', he ? 'on' : 'off'));
  }
  if (fmt == 'zx') {
    final c = o.compression;
    if (c != null) {
      for (final e in c.toSwitches().entries) {
        r.add(MapEntry(e.key, e.value));
      }
    }
    final dd = o.dedup;
    if (dd != null) r.add(MapEntry('dedup', dd ? 'on' : 'off'));
    final ml = o.memoryLimit;
    if (ml != null) r.add(MapEntry('memuse', '${ml}b'));
    final sk = o.signKey;
    if (sk != null) r.add(MapEntry('sign', sk));
    final vs = o.volumeSizes;
    if (vs.isNotEmpty) r.add(MapEntry('vsizes', vs.join(',')));
    for (final d in o.volumeDirs) {
      r.add(MapEntry('vdir', d));
    }
  }
  for (final e in o.switches.entries) {
    r.add(MapEntry(e.key, e.value));
  }
  return r;
}

/// The format index for a new archive and the compressor around a tar
/// (-1 for none).
(int, int) _formatForCreate(Codecs codecs, String path, String? format) {
  final tar = codecs.findFormatForArchiveType('tar');
  if (format != null) {
    final f = format.toLowerCase();
    if (f.startsWith('tar.')) {
      final outer = switch (f.substring(4)) {
        'gz' || 'gzip' => 'gzip',
        'bz2' || 'bzip2' => 'bzip2',
        'xz' => 'xz',
        'lzma' => 'lzma',
        _ => '',
      };
      final o = codecs.findFormatForArchiveType(outer);
      if (o < 0) {
        throw SevenZipException(
            'Unknown format: $format', SevenZipError.unsupported);
      }
      return (tar, o);
    }
    final i = codecs.findFormatForArchiveType(f == 'rar' ? 'Rar5' : f);
    if (i < 0) {
      throw SevenZipException(
          'Unknown format: $format', SevenZipError.unsupported);
    }
    return (i, -1);
  }
  var i = codecs.findFormatForArchiveName(path);
  if (i < 0) i = codecs.findFormatForArchiveType('7z');
  final ai = codecs.formats[i];
  if (isCompoundOuterFormat(ai) &&
      isCompoundTarName(
          path.substring(path.lastIndexOf(Platform.pathSeparator) + 1))) {
    return (tar, i);
  }
  if (ai.name == 'Rar') i = codecs.findFormatForArchiveType('Rar5');
  return (i, -1);
}

/// [ZxArchive.create] and the operations that change an archive.
Future<Object?> workerUpdate(ZxUpdateRequest r, ZxOps ops) async {
  // the destination folders of new .zx volumes are searched too
  _zxSearchDirs = [
    ...r.searchDirs,
    for (final d in r.options.volumeDirs) ZxVolumeDir.parse(d).path,
  ];
  final codecs = Codecs.load();
  final path = r.archivePath;
  final create = r.kind == ZxUpdateKind.create;
  if (create &&
      !r.overwrite &&
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
    throw SevenZipException('$path: the file exists', SevenZipError.io);
  }

  // the sources
  final scanned = <_Scanned>[];
  final skipped = <String>[];
  if (r.kind == ZxUpdateKind.create || r.kind == ZxUpdateKind.add) {
    final exclude = {path, '$path.zx-part'};
    for (final s in r.sources) {
      var disk = s.path;
      while (disk.length > 1 && disk.endsWith(Platform.pathSeparator)) {
        disk = disk.substring(0, disk.length - 1);
      }
      var stored = zxNormalizePath(s.storedAs ??
          disk.substring(disk.lastIndexOf(Platform.pathSeparator) + 1));
      final dest = r.destination;
      if (dest.isNotEmpty) stored = stored.isEmpty ? dest : '$dest/$stored';
      _scan(disk, stored, r.options.storeSymlinks, scanned, skipped, exclude);
    }
    if (create && scanned.isEmpty) {
      throw const SevenZipException(
          'Nothing to add', SevenZipError.unsupported);
    }
  }

  // a compound tar is decoded into this folder for the update
  Directory? tmp;
  if (!create) {
    final parent = File(path).parent;
    tmp = parent.createTempSync('.zx-');
    ops.registerDir(tmp.path);
  }
  var pw = r.password;
  var attempt = 0;
  try {
    for (;;) {
      final o = create
          ? null
          : await _openAsk(codecs, path, pw, r.canAsk, ops,
              compoundTempDir: '${tmp!.path}${Platform.pathSeparator}');
      if (o != null) pw = o.password;
      _Written? w;
      try {
        w = _writeSync(codecs, o, r, pw, scanned, ops);
      } on _NeedPassword {
        w = null;
      } finally {
        o?.close();
      }
      if (w == null) {
        if (!r.canAsk) {
          throw const SevenZipException(
              'A password is needed', SevenZipError.wrongPassword);
        }
        final a = await ops.ask(ZxPasswordRequest(path, ZxPasswordReason.update,
            attempt: attempt++));
        if (a is! String) {
          throw const SevenZipException(
              'No password given', SevenZipError.cancelled);
        }
        pw = a;
        continue;
      }
      // the new archive replaces the old one
      final part = w.part;
      if (part != null) ops.commit(part, path);
      for (final v in w.volumes) {
        ops.unregisterFile(v);
        ops.unregisterFile('$v.tmp');
      }
      final listPath = w.volumes.isNotEmpty && !File(path).existsSync()
          ? w.volumes.first
          : path;
      final lpw = pw ?? r.options.password;
      final o2 = _openSync(codecs, listPath, lpw);
      try {
        final l = _readListing(o2);
        return (
          l,
          ZxUpdateResult(
              w.added, w.changed, w.kept, [...skipped, ...w.skipped], w.size)
        );
      } finally {
        o2.close();
      }
    }
  } finally {
    if (tmp != null) {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
      ops.unregisterDir(tmp.path);
    }
  }
}

class _Written {
  final String? part;
  final List<String> volumes;
  final int size;
  final int added, changed, kept;
  final List<String> skipped;
  _Written(this.part, this.volumes, this.size, this.added, this.changed,
      this.kept, this.skipped);
}

_Written _writeSync(Codecs codecs, _Opened? o, ZxUpdateRequest r, String? pw,
    List<_Scanned> scanned, ZxOps ops) {
  final path = r.archivePath;
  InArchive outArchive;
  String fmt;
  var compound = false;
  InArchive? old;
  if (o != null) {
    final arc = o.arc;
    old = arc.archive!;
    fmt = codecs.getFormatNamePtr(arc.formatIndex);
    if (!old.supportsUpdate || fmt == 'Rar' || o.link.arcs.length > 2) {
      throw SevenZipException(
          '$fmt: this archive can not be updated', SevenZipError.unsupported);
    }
    outArchive = old;
    if (arc.compoundOuterIndex >= 0) {
      compound = true;
      final create = codecs.formats[arc.compoundOuterIndex].createInArchive!;
      outArchive = CompoundOutArc(
          create(),
          old as TarArc,
          compoundInnerName(
              path.substring(path.lastIndexOf(Platform.pathSeparator) + 1)));
    } else if (o.link.arcs.length > 1) {
      throw SevenZipException(
          '$fmt: this archive can not be updated', SevenZipError.unsupported);
    }
  } else {
    final (fi, outer) = _formatForCreate(codecs, path, r.format);
    final ai = codecs.formats[fi];
    fmt = ai.name;
    final make = ai.createInArchive;
    if (make == null || !ai.updateEnabled) {
      throw SevenZipException(
          '$fmt: archives of this format can not be created',
          SevenZipError.unsupported);
    }
    outArchive = make();
    if (outer >= 0) {
      compound = true;
      outArchive = CompoundOutArc(
          codecs.formats[outer].createInArchive!(),
          outArchive as TarArc,
          compoundInnerName(
              path.substring(path.lastIndexOf(Platform.pathSeparator) + 1)));
    }
  }

  // the items of the new archive
  final plan = <_UItem>[];
  var added = 0, changed = 0, kept = 0;
  final oldPaths = <String>[];
  if (o != null) {
    final a = o.archive;
    for (var i = 0; i < a.numberOfItems; i++) {
      oldPaths.add(_itemPath(o.arc, i));
    }
  }
  switch (r.kind) {
    case ZxUpdateKind.create:
      for (final s in scanned) {
        plan.add(_UItem.fromDisk(s));
        added++;
      }
    case ZxUpdateKind.add:
      final byPath = <String, _Scanned>{for (final s in scanned) s.stored: s};
      for (var i = 0; i < oldPaths.length; i++) {
        final s = byPath[oldPaths[i]];
        final oldIsDir = archiveIsItemDir(old!, i);
        if (s != null &&
            !(oldIsDir && s.type == FileSystemEntityType.directory)) {
          plan.add(_UItem.fromDisk(s, oldIndex: i));
          added++;
          byPath.remove(oldPaths[i]);
        } else {
          if (s != null) byPath.remove(oldPaths[i]);
          plan.add(_UItem.keep(i));
          kept++;
        }
      }
      for (final s in scanned) {
        if (byPath.containsKey(s.stored)) {
          plan.add(_UItem.fromDisk(s));
          added++;
        }
      }
    case ZxUpdateKind.delete:
      for (var i = 0; i < oldPaths.length; i++) {
        if (r.paths.any((p) => _isUnder(oldPaths[i], p))) {
          changed++;
        } else {
          plan.add(_UItem.keep(i));
          kept++;
        }
      }
    case ZxUpdateKind.rename:
      final from = r.paths.first, to = r.newPath!;
      if (_isUnder(to, from) && to != from) {
        throw const SevenZipException(
            'A folder can not be moved into itself', SevenZipError.unsupported);
      }
      for (var i = 0; i < oldPaths.length; i++) {
        final p = oldPaths[i];
        if (!_isUnder(p, from) && p == to) {
          throw SevenZipException(
              '$to: an item with this name exists', SevenZipError.unsupported);
        }
      }
      for (var i = 0; i < oldPaths.length; i++) {
        final p = oldPaths[i];
        if (_isUnder(p, from)) {
          plan.add(_UItem.renamed(i, to + p.substring(from.length)));
          changed++;
        } else {
          plan.add(_UItem.keep(i));
          kept++;
        }
      }
      if (changed == 0) {
        throw SevenZipException(
            '$from: not found in the archive', SevenZipError.unsupported);
      }
    case ZxUpdateKind.createFolder:
      final p = r.paths.first;
      if (oldPaths.contains(p)) {
        throw SevenZipException(
            '$p: an item with this name exists', SevenZipError.unsupported);
      }
      for (var i = 0; i < oldPaths.length; i++) {
        plan.add(_UItem.keep(i));
        kept++;
      }
      plan.add(_UItem.folder(p, dateTimeToFileTime(DateTime.now())));
      added++;
    case ZxUpdateKind.setComment:
      for (var i = 0; i < oldPaths.length; i++) {
        plan.add(_UItem.keep(i));
        kept++;
      }
      final c = r.comment ?? '';
      if (outArchive is ZipArc) {
        outArchive.h.writeOptions.newComment =
            Uint8List.fromList(utf8.encode(c));
      } else if (outArchive is Rar5Arc) {
        outArchive.h.writeOptions.newComment = c;
      } else {
        throw SevenZipException(
            '$fmt: comments are not supported', SevenZipError.unsupported);
      }
  }

  final newPassword = switch (r.kind) {
    ZxUpdateKind.create || ZxUpdateKind.add => r.options.password,
    _ => (old != null && _anyEncrypted(old) ? pw : null),
  };
  setArchiveProperties(
      outArchive, _props(fmt, r.options, compound, newPassword != null));

  var newTotal = 0;
  for (final it in plan) {
    final d = it.disk;
    if (it.newData && d != null && d.type == FileSystemEntityType.file) {
      newTotal += d.stat.size;
    }
  }
  final cb = _UpdateCallback(plan, old, o?.arc, newPassword, pw, ops, newTotal);

  // .zx writes itself: a new generation in place, new volumes for a set
  if (outArchive is ZxArc) {
    final vs = r.options.volumeSizes.isNotEmpty
        ? r.options.volumeSizes
        : [if (r.options.volumeSize != null) r.options.volumeSize!];
    final written = <String>[];
    try {
      if (o == null && vs.isEmpty) {
        final part = ops.partFor(path);
        final res = outArchive.updateFile(part, plan.length, cb);
        cb.releaseAll();
        return _Written(part, const [], File(part).lengthSync(), added,
            changed, kept, [...cb.skipped, ...res.warnings]);
      }
      final target = o == null
          ? path
          : ((o.archive as ZxArc).openedPath ?? path);
      final res = outArchive.updateFile(target, plan.length, cb,
          volumeSizes: o == null ? vs : const [], onFile: (f) {
        written.add(f);
        ops.registerFile(f);
      });
      cb.releaseAll();
      var size = 0;
      for (final f in res.files.isEmpty ? [target] : res.files) {
        size += File(f).lengthSync();
      }
      if (o != null && res.files.isEmpty) {
        // appended in place
        return _Written(null, const [], size, added, changed, kept,
            [...cb.skipped, ...res.warnings]);
      }
      return _Written(null, written, size, added, changed, kept,
          [...cb.skipped, ...res.warnings]);
    } catch (_) {
      cb.releaseAll();
      for (final f in written) {
        try {
          File(f).deleteSync();
        } on FileSystemException {
          // ignore
        }
        ops.unregisterFile(f);
      }
      rethrow;
    }
  }

  // the output: a part file next to the archive, or volumes
  final volSize = r.options.volumeSize;
  if (volSize != null && o == null) {
    final isRar = fmt == 'Rar5';
    final volumes = <String>[];
    final ms = MultiOutStream('$path.', [volSize]);
    String name(int i) {
      if (isRar) {
        final dot = path.lastIndexOf('.');
        final base = dot > path.lastIndexOf(Platform.pathSeparator)
            ? path.substring(0, dot)
            : path;
        final n = volSize <= 0 ? 1 : (newTotal + volSize - 1) ~/ volSize;
        return rarVolumePath(base, i, '$n'.length);
      }
      return '$path.${'${i + 1}'.padLeft(3, '0')}';
    }

    ms.volumeName = (i) {
      final v = name(i);
      if (!volumes.contains(v)) {
        volumes.add(v);
        ops.registerFile(v);
        ops.registerFile('$v.tmp');
      }
      return v;
    };
    if (isRar) ms.singleVolumeName = path;
    try {
      outArchive.updateItems(ms, plan.length, cb);
      final size = ms.length;
      ms.finalFlushAndCloseFiles();
      cb.releaseAll();
      final vols = File(path).existsSync() && isRar ? <String>[] : volumes;
      if (vols.isEmpty) {
        for (final v in volumes) {
          ops.unregisterFile(v);
          ops.unregisterFile('$v.tmp');
        }
      }
      return _Written(null, vols, size, added, changed, kept, cb.skipped);
    } catch (_) {
      cb.releaseAll();
      try {
        ms.destruct();
      } on Object {
        // ignore
      }
      rethrow;
    }
  }

  final part = ops.partFor(path);
  final out = FileOutStream.create(part);
  int size;
  try {
    outArchive.updateItems(out, plan.length, cb);
    out.flush();
    size = out.length;
  } catch (_) {
    cb.releaseAll();
    try {
      out.close();
    } on Object {
      // ignore
    }
    ops.discard(part);
    rethrow;
  }
  cb.releaseAll();
  out.close();
  return _Written(part, const [], size, added, changed, kept, cb.skipped);
}

// ---------------------------------------------------------------------------
// .zx operations

enum ZxZxOp { compact, timeline, seal }

class ZxZxRequest {
  final String archivePath;
  final String? password;
  final bool canAsk;
  final ZxZxOp op;
  final String arg;
  final List<String> searchDirs;
  const ZxZxRequest(this.archivePath, this.password, this.canAsk, this.op,
      this.arg, this.searchDirs);
}

/// [ZxArchive.compact] ((listing, bytes freed)) and [ZxArchive.timeline]
/// (the versions).
Future<Object?> workerZx(ZxZxRequest r, ZxOps ops) async {
  final codecs = Codecs.load();
  _zxSearchDirs = r.searchDirs;
  final o = await _openAsk(codecs, r.archivePath, r.password, r.canAsk, ops);
  var closed = false;
  try {
    final a = o.archive;
    if (a is! ZxArc) {
      throw const SevenZipException(
          'not a .zx archive', SevenZipError.unsupported);
    }
    switch (r.op) {
      case ZxZxOp.timeline:
        return [
          for (final ZxTimelineVersion v in a.h.timeline(r.arg))
            ZxFileVersion(
                v.path,
                v.generation,
                DateTime.fromMicrosecondsSinceEpoch(v.time ~/ 1000,
                    isUtc: true),
                v.size,
                v.sha256 == null ? null : zxHex(v.sha256!),
                v.endGeneration,
                v.endTime == null
                    ? null
                    : DateTime.fromMicrosecondsSinceEpoch(v.endTime! ~/ 1000,
                        isUtc: true),
                v.deleted)
        ];
      case ZxZxOp.seal:
        // arg: the -m switches, JSON [[name, value]...]
        final props = [
          for (final e in jsonDecode(r.arg) as List)
            MapEntry((e as List)[0] as String, PropVariant.bstr(e[1] as String))
        ];
        final path = a.openedPath ?? r.archivePath;
        a.h.setProperties(props);
        final res = a.h.sealFile(path, password: o.password);
        o.close();
        closed = true;
        final o2 = _openSync(codecs, r.archivePath, o.password);
        try {
          return (_readListing(o2), res.generation);
        } finally {
          o2.close();
        }
      case ZxZxOp.compact:
        final keep = int.parse(r.arg);
        final path = a.openedPath ?? r.archivePath;
        final registered = <String>[];
        final freed = a.compactFile(path, keep, password: o.password,
            onFile: (f) {
          registered.add(f);
          ops.registerFile(f);
        });
        for (final f in registered) {
          ops.unregisterFile(f);
        }
        o.close();
        closed = true;
        final o2 = _openSync(codecs, r.archivePath, o.password);
        try {
          return (_readListing(o2), freed);
        } finally {
          o2.close();
        }
    }
  } finally {
    if (!closed) o.close();
  }
}
