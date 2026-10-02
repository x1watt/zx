// The generic, isolate based archive API: every format of the command line
// tool (7z, zip and its extensions, rar, tar, gzip, bzip2, xz, lzma, the
// compressed tars, lzh, arj, split volumes) through one handle, for
// archive managers. The work runs in background isolates (zx_worker.dart)
// on the format layer of the command line tool (load_codecs.dart,
// open_archive.dart, the arc_*.dart adapters); the caller's isolate only
// sends requests and receives results, throttled progress and the
// questions of the operation (password, overwrite).

export 'zx_types.dart';

import 'dart:async';
import 'dart:convert';
import 'host/io.dart';
import 'dart:isolate';
import 'dart:typed_data';

import 'api.dart';
import 'zx_types.dart';
import 'cli/nest.dart' show NestNodeSpec;
import 'io/streams.dart';
import 'format/zx/zx_writer.dart' show ZxVolumeDir;
import 'readme/markdown.dart' show MdDocument;
import 'readme/readme.dart';
import 'readme/readme_links.dart' show checkReadme;
import 'util/tlsh.dart' show tlshDistance;
import 'format/zx/zx_seal.dart'
    show ZxGenerationSeal, ZxSealState, ZxWriteRule, zxCheckSealsOfFile;
import 'zx_estimate.dart';
import 'zx_worker.dart';

// Top level, so that the closure sent to the isolate holds only these.
Future<MdDocument> _parseReadmeInIsolate(
        String name, Uint8List bytes, bool truncated) =>
    Isolate.run(() => parseReadme(name, bytes, truncated: truncated));

/// Settings for [ZxArchive.add] and [ZxArchive.create]. They become the
/// -m switches of 7-Zip for the format; what is not set keeps the format's
/// default (7z: LZMA2 level 5 solid, zip: Deflate level 5, rar: RAR5 level
/// 3, the compressors: level 5).
class ZxOptions {
  /// 0 (store) to 9, -mx (zpaq: 0 to 5, higher values are 5).
  final int? level;

  /// The method: 7z -m0 ('LZMA2', 'LZMA', 'PPMd', 'Copy', 'LZMA2:d=64m'...),
  /// zip -mm ('Deflate', 'Deflate64', 'BZip2', 'LZMA', 'PPMd', 'Copy'),
  /// zpaq -mm (a zpaq method: '0' to '5', '14', 'x4.3ci1'...).
  /// Ignored by the other formats (use [switches]).
  final String? method;

  /// Solid archive (7z, rar).
  final bool? solid;

  /// Encrypts the new data (7z AES-256, zip ZipCrypto or `em=AES256` in
  /// [switches], rar5 AES-256, arj garbling).
  final String? password;

  /// Encrypts the names too (7z, rar5); needs [password].
  final bool? encryptHeaders;

  /// Splits a new archive into volumes of this size (create only): 7z and
  /// the others `name.ext.001, .002...`, rar `name.part1.rar...`.
  final int? volumeSize;

  /// .zx: the size of each volume, the last one repeating (for example
  /// first 4 GiB, then 25 GiB each). A .zx set gets new volumes when it is
  /// updated. Takes the place of [volumeSize].
  final List<int> volumeSizes;

  /// .zx: the folders the volumes are written to, in order: "DIR", or
  /// "DIR:SIZE" (a budget such as 100g), or "DIR:full" (until the disk has
  /// no room for the next volume).
  final List<String> volumeDirs;

  /// Stores symbolic links as links (-snl). When false a link to a file is
  /// stored as the file, a link to a folder is skipped.
  final bool storeSymlinks;

  /// Other -m switches, name to value: {'d': '64m', 'mt': '2', 'em':
  /// 'AES256', 'rr': '3%', 'tc': 'on'}. An empty value is the bare switch.
  final Map<String, String> switches;

  /// .zx: how the data is compressed: [ZxCompression.auto] (zx chooses
  /// the zcm level, memory and threads for the machine, the input and a
  /// time budget) or [ZxCompression.manual] (zcm settings or a coder
  /// chain). Its switches come after [level] and [method] and before
  /// [switches]. Ignored by the other formats. [ZxArchive.estimate] tells
  /// what it would choose and cost.
  final ZxCompression? compression;

  /// .zx: deduplication (-mdedup, on by default): identical chunks of
  /// data (about 64 KiB, content defined) and identical files are stored
  /// once, also against the earlier generations. false turns it off.
  final bool? dedup;

  /// .zx: the memory the block workers may use together, in bytes
  /// (-mmemuse), when writing and reading; fewer blocks are coded at once
  /// when their estimated memory exceeds it. Default: 75% of the
  /// available memory, and at most the available memory minus 1.5 GiB.
  final int? memoryLimit;

  /// .zx: the NOSTR key (an nsec or 64 hex digits) that signs the new
  /// generation (signed generations, docs/zx-format.md "Seals"): the
  /// archive's admin or a maintainer. A new archive is sealed with it, the
  /// key its admin.
  final String? signKey;

  const ZxOptions({
    this.level,
    this.method,
    this.solid,
    this.password,
    this.encryptHeaders,
    this.volumeSize,
    this.volumeSizes = const [],
    this.volumeDirs = const [],
    this.storeSymlinks = false,
    this.switches = const {},
    this.compression,
    this.dedup,
    this.memoryLimit,
    this.signKey,
  });
}

/// An archive of any supported format.
///
/// [open] reads the listing in a background isolate; every operation runs
/// in a new background isolate, so a Flutter UI isolate never blocks.
/// Operations that write (add, delete, rename, createFolder, setComment)
/// write a new archive next to the old one (`name.zx-part`), rename it over
/// the old one when it is complete, and read the listing again, so the
/// handle always shows the archive on disk.
class ZxArchive {
  /// The archive file (for a nested archive: the file of the outermost
  /// archive, see [nestPath]).
  final String path;

  /// Asked for passwords (see [ZxPasswordRequest]); may be set at any time.
  ZxPasswordCallback? onPassword;

  /// The archive this nested archive was opened from ([openNested]), null
  /// for an archive file.
  final ZxArchive? parent;

  /// The paths of the items from the outermost archive to this nested
  /// archive (`['rootfs']` for the UBI image of a firmware section), empty
  /// for an archive file.
  final List<String> nestPath;

  /// The archive is shown as one tree with its nested archives (see
  /// [open]).
  final bool flattened;
  final int _maxDepth;

  // the version a journaling archive was opened at (null: the last one)
  final int? _version;

  /// .zx: the folders searched for the volumes of a set.
  final List<String> searchDirs;

  // where the operations open it: _base, then the items of _chain
  String _base;
  List<int> _chain;
  List<NestNodeSpec>? _layout;
  List<String> _temps;

  ZxListing _listing;
  Map<String, ZxItem>? _byPath;
  Map<String, List<ZxItem>>? _children;

  ZxArchive._(this.path, this._listing, this.onPassword,
      {this.parent,
      this.nestPath = const [],
      this.flattened = false,
      int maxDepth = 4,
      String? base,
      List<int> chain = const [],
      List<NestNodeSpec>? layout,
      List<String> temps = const [],
      int? version,
      this.searchDirs = const []})
      : _maxDepth = maxDepth,
        _version = version,
        _base = base ?? path,
        _chain = chain,
        _layout = layout,
        _temps = temps;

  /// Opens [path]: the format comes from the signature and the extension
  /// as the command line tool finds it (x.tar.gz and the other compressed
  /// tars are one archive, x.7z.001 and the RAR volumes open the set).
  ///
  /// With [flatten] the archive is shown as one read-only tree: each item
  /// that is itself an archive or an image (the items of the container
  /// formats pak, uImage, UBI, MBR and GPT, and any item whose first bytes
  /// match the signature of a known format) becomes a folder holding the
  /// tree of its inner archive (see [ZxItem.isNested]), down to
  /// [maxDepth] levels. A nested archive holding one item that is an
  /// archive too shows that archive directly: the UBI image of a firmware
  /// section with one UBIFS volume shows the files of the volume. Items
  /// that open only as a compressor or a device tree inside a file system
  /// (`x.gz`, `x.dtb`) stay files. Extract, test, readBytes and
  /// extractToTemp work on the tree; it can not be changed. Call [close]
  /// when done: nested archives read from temporary files keep them until
  /// then.
  ///
  /// Throws [SevenZipException]: [SevenZipError.isNotArc] when no format
  /// matches, [SevenZipError.wrongPassword] for encrypted names with a
  /// wrong password, [SevenZipError.cancelled] when [onPassword] gave no
  /// password, [SevenZipError.io] when the file can not be read.
  ///
  /// [version] opens a journaling archive (zpaq, and the generations of
  /// .zx) as it was after that version (1 for the first update): the
  /// listing, extract, test and readBytes see the files of that version,
  /// and the handle is read only. Without it the last version is shown.
  /// [versions] lists them. Other formats ignore it. [date] opens a .zx
  /// archive as of a date ("YYYY-MM-DD", "YYYY-MM-DD HH:MM" or
  /// "YYYY-MM-DD HH:MM:SS", local time): the last generation written up
  /// to the end of that day, minute or second.
  ///
  /// [searchDirs] are folders where the volumes of a .zx set may be,
  /// besides the folder of [path] (volumes are recognized by their
  /// header, whatever their names).
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
    final full = File(path).absolute.path;
    final dirs = [for (final d in searchDirs) Directory(d).absolute.path];
    final req = ZxOpenRequest(full, password, onPassword != null,
        nest: flatten ? ZxNest(maxDepth) : null,
        version: version,
        versionDate: version == null ? date : null,
        searchDirs: dirs);
    final r = await _zxRun<ZxOpenResult>((ops) => workerOpen(req, ops),
        cancel: cancel, onPassword: onPassword);
    var v = version;
    if (v == null && date != null && r.listing.versions.isNotEmpty) {
      v = r.listing.versions.last.number;
    }
    return ZxArchive._(full, r.listing, onPassword,
        flattened: flatten,
        maxDepth: maxDepth,
        base: r.base,
        chain: r.chain,
        layout: r.layout,
        temps: r.temps,
        version: v,
        searchDirs: dirs);
  }

  // the version for the requests: only while the operations start from
  // the archive file itself (not from a temporary copy of a nested one)
  int? get _baseVersion => _base == path ? _version : null;

  /// Opens the file [item] (a [ZxItem], a path or an index) as an archive
  /// of its own, for a UI that goes into it and back ([parent],
  /// [nestPath]). The item is read in place when its format gives random
  /// access to its data (tar, zip, iso, pak, UBI, the file systems...),
  /// otherwise it is copied to a temporary file that [close] deletes.
  /// [flatten] and [maxDepth] as for [open]. The nested archive can not be
  /// changed. Throws [SevenZipException] ([SevenZipError.isNotArc] when
  /// the item is not an archive).
  Future<ZxArchive> openNested(Object item,
      {bool flatten = false, int maxDepth = 4, ZxCancelToken? cancel}) async {
    final it = _resolveFile(item, nested: true);
    final chain = [
      ..._chain,
      ...(it.nestChain ?? [it.index])
    ];
    final req = ZxOpenRequest(_base, password, onPassword != null,
        chain: chain,
        nest: flatten ? ZxNest(maxDepth) : null,
        readOnly: true,
        version: _baseVersion);
    final r = await _zxRun<ZxOpenResult>((ops) => workerOpen(req, ops),
        cancel: cancel, onPassword: onPassword);
    return ZxArchive._(path, r.listing, onPassword,
        parent: this,
        nestPath: [...nestPath, it.path],
        flattened: flatten,
        maxDepth: maxDepth,
        base: r.base,
        chain: r.chain,
        layout: r.layout,
        temps: r.temps,
        version: _version,
        searchDirs: searchDirs);
  }

  /// Deletes the temporary files of this handle (nested archives read
  /// from copies, see [openNested] and [open] with flatten). The handle
  /// must not be used after it. A nested archive has its own handle to
  /// close.
  Future<void> close() async {
    final t = _temps;
    _temps = const [];
    for (final d in t) {
      try {
        await Directory(d).delete(recursive: true);
      } on FileSystemException {
        // already gone
      }
    }
  }

  /// True for an archive opened with [openNested].
  bool get isNested => parent != null;

  ZxNest? get _nest => flattened ? ZxNest(_maxDepth, _layout) : null;

  /// Creates a new archive at [path] from [sources]. The format comes from
  /// [format] (7-Zip's name: '7z', 'zip', 'tar', 'gzip', 'bzip2', 'xz',
  /// 'lzma', 'Rar5', 'Lzh', 'Arj'; 'tar.gz', 'tar.bz2', 'tar.xz' and
  /// 'tar.lzma' for the compressed tars) or else from the extension of
  /// [path] (x.tgz, x.tar.gz... are compressed tars, .jar is zip). The
  /// compressors (gzip, bzip2, xz, lzma) hold one file. An existing file
  /// is replaced only with [overwrite].
  static Future<ZxArchive> create(String path, List<ZxSource> sources,
      {String? format,
      ZxOptions options = const ZxOptions(),
      bool overwrite = false,
      ZxPasswordCallback? onPassword,
      void Function(ZxProgress progress)? onProgress,
      ZxCancelToken? cancel}) async {
    final full = File(path).absolute.path;
    final req = ZxUpdateRequest(
        kind: ZxUpdateKind.create,
        archivePath: full,
        password: options.password,
        canAsk: false,
        format: format,
        sources: [
          for (final s in sources)
            ZxSource(File(s.path).absolute.path, storedAs: s.storedAs)
        ],
        options: options,
        overwrite: overwrite);
    final (l, _) = await _zxRun<(ZxListing, ZxUpdateResult)>(
        (ops) => workerUpdate(req, ops),
        onProgress: onProgress,
        cancel: cancel);
    return ZxArchive._(
        l.volumes.isNotEmpty ? l.volumes.first : full, l, onPassword,
        searchDirs: [
          for (final d in options.volumeDirs)
            Directory(ZxVolumeDir.parse(d).path).absolute.path
        ]);
  }

  /// What adding [sources] (files and folders with everything below
  /// them) with [options] would choose and cost, without compressing: the
  /// settings of [ZxOptions.compression] (for auto: the zcm level,
  /// memory and threads zx picks), the estimated time, peak memory and a
  /// range of output sizes, and warnings (more memory than the machine can
  /// spare, hours of work). Measures this machine's speed on a sample of
  /// the input (up to 64 KiB, about half a second). Runs in a background
  /// isolate. [ZxEstimate.compression] pins the estimated zcm settings for
  /// the update. Estimates the .zx methods (the others as LZMA2).
  static Future<ZxEstimate> estimate(List<ZxSource> sources,
      {ZxOptions options = const ZxOptions()}) {
    final paths = [for (final s in sources) File(s.path).absolute.path];
    final compression = options.compression;
    final method = options.method;
    final level = options.level;
    final switches = options.switches;
    final memoryLimit = options.memoryLimit;
    return Isolate.run(() => zxEstimate(paths,
        compression: compression,
        method: method,
        level: level,
        switches: switches,
        memoryLimit: memoryLimit));
  }

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

  /// The versions of a journaling archive (zpaq) up to the one shown
  /// (see [open] with `version`); empty for the other formats.
  List<ZxVersion> get versions => _listing.versions;

  /// The version shown ([open] with `version`, else the last one); null
  /// for the formats without versions.
  int? get version => _listing.numVersions == 0 || _listing.versions.isEmpty
      ? null
      : _listing.versions.last.number;

  /// The number of versions of a journaling archive, whatever version is
  /// shown (for .zx the number of the last generation: a compaction keeps
  /// the numbers of the generations it keeps); 0 for the other formats.
  int get numVersions => _listing.numVersions;
  ZxCapabilities get capabilities => _listing.capabilities;

  /// Every item, then the implied folders (see [ZxItem.isImplied]).
  List<ZxItem> get items => _listing.items;

  /// The known password (given, or answered to [onPassword]).
  String? get password => _listing.password;

  /// The item (or implied folder) at [path], '/' separated.
  ZxItem? operator [](String path) =>
      (_byPath ??= {for (final i in items) i.path: i})[_norm(path)];

  /// The items directly inside the folder [dir] ('' for the top level).
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

  /// Reads the archive again (a flattened one looks for its nested
  /// archives again).
  Future<void> reload({ZxCancelToken? cancel}) async {
    final req = ZxOpenRequest(_base, password, onPassword != null,
        chain: _chain,
        nest: flattened ? ZxNest(_maxDepth) : null,
        readOnly: isNested || _temps.isNotEmpty,
        version: _baseVersion,
        searchDirs: searchDirs);
    final r = await _zxRun<ZxOpenResult>((ops) => workerOpen(req, ops),
        cancel: cancel, onPassword: onPassword);
    final old = _temps;
    _base = r.base;
    _chain = r.chain;
    _layout = r.layout;
    // the temporary files of the old tree are no longer used
    _temps = [
      for (final d in old)
        if (d == r.base || r.base.startsWith(d)) d,
      ...r.temps
    ];
    for (final d in old) {
      if (!_temps.contains(d)) {
        try {
          await Directory(d).delete(recursive: true);
        } on FileSystemException {
          // already gone
        }
      }
    }
    _set(r.listing);
  }

  // ---- reading ----

  /// Extracts into [outDir] the [items] (default: all). An item is a
  /// [ZxItem], a path (a folder selects everything below it) or an index.
  ///
  /// [keepPaths] false extracts every file into [outDir] itself (7-Zip's
  /// `e`). [relativeTo] is a folder prefix removed from the paths of the
  /// items below it (to extract the folder `a/b` as `b`, pass `a`).
  /// [overwrite] decides for existing files; with [ZxOverwrite.ask] the
  /// [onOverwrite] callback is asked before anything is written.
  /// Modification times, POSIX modes (with chmod) and symbolic links are
  /// restored unless switched off; links are created after every file and
  /// only when they stay inside [outDir].
  ///
  /// Each file is written as `name.zx-part` and renamed when it is
  /// complete and its CRC matched. Per item errors are in the result.
  Future<ZxExtractResult> extract(
    String outDir, {
    List<Object>? items,
    bool keepPaths = true,
    String? relativeTo,
    ZxOverwrite overwrite = ZxOverwrite.overwrite,
    ZxOverwriteCallback? onOverwrite,
    bool restoreTimes = true,
    bool restoreModes = true,
    bool restoreSymlinks = true,
    void Function(ZxProgress progress)? onProgress,
    ZxCancelToken? cancel,
  }) {
    if (overwrite == ZxOverwrite.ask && onOverwrite == null) {
      throw ArgumentError('ZxOverwrite.ask needs onOverwrite');
    }
    final req = _extractRequest(ZxExtractMode.extract, items,
        outDir: File(outDir).absolute.path,
        keepPaths: keepPaths,
        relativeTo: relativeTo == null ? null : _norm(relativeTo),
        overwrite: overwrite,
        restoreTimes: restoreTimes,
        restoreModes: restoreModes,
        restoreSymlinks: restoreSymlinks);
    return _extractRun(req, onProgress, cancel, onOverwrite);
  }

  /// Decodes the [items] (default: all) and checks them, writing nothing.
  Future<ZxExtractResult> test({
    List<Object>? items,
    void Function(ZxProgress progress)? onProgress,
    ZxCancelToken? cancel,
  }) =>
      _extractRun(
          _extractRequest(ZxExtractMode.test, items), onProgress, cancel, null);

  /// Extracts one file into a new folder under [tempDir] (default: the
  /// system temporary folder) and returns its path, for "open with" and
  /// previews. The caller deletes the folder (the parent of the returned
  /// path) when it is done. Throws [SevenZipException] when the item can
  /// not be extracted.
  Future<String> extractToTemp(Object item,
      {String? tempDir,
      void Function(ZxProgress progress)? onProgress,
      ZxCancelToken? cancel}) async {
    final it = _resolveFile(item);
    final base = Directory(tempDir ?? Directory.systemTemp.path);
    final dir = base.createTempSync('zx_');
    try {
      final req = _extractRequest(ZxExtractMode.extract, [it.index],
          outDir: dir.path,
          keepPaths: false,
          overwrite: ZxOverwrite.rename,
          restoreTimes: true,
          restoreModes: false,
          restoreSymlinks: false);
      final r = await _extractRun(req, onProgress, cancel, null);
      if (r.errors.isNotEmpty) {
        final e = r.errors.first;
        throw SevenZipException(
            '${e.path}: ${e.message ?? e.kind.name}', e.kind);
      }
      final name = dir.listSync().whereType<File>().map((f) => f.path);
      if (name.isEmpty) {
        throw SevenZipException('${it.path}: not extracted', SevenZipError.io);
      }
      return name.first;
    } catch (_) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
      rethrow;
    }
  }

  /// The README of the folder [dir] ('' for the top of the archive): the
  /// file README.md (or README.markdown, README.txt, README, in any case)
  /// directly inside it, or null. See docs/readme.md.
  ZxItem? readmeIn(String dir) {
    final files = <String, ZxItem>{};
    for (final i in children(dir)) {
      if (!i.isDir) files[i.name] = i;
    }
    final n = pickReadme(files.keys);
    return n == null ? null : files[n];
  }

  /// The README of the folder [dir], parsed (null when it has none, see
  /// [readmeIn]). The first [readmeMaxBytes] bytes are read; the parsing
  /// runs in a background isolate.
  Future<ZxReadme?> readme({String dir = '', ZxCancelToken? cancel}) async {
    final item = readmeIn(dir);
    return item == null ? null : readmeOf(item, cancel: cancel);
  }

  /// The file [item] parsed as a README (markdown for a .md name, text
  /// otherwise), with the links and images that can not work (see
  /// [checkReadme]).
  Future<ZxReadme> readmeOf(ZxItem item, {ZxCancelToken? cancel}) async {
    final bytes =
        await readBytes(item, maxBytes: readmeMaxBytes, cancel: cancel);
    final doc = await _parseReadmeInIsolate(
        item.name, bytes, bytes.length >= readmeMaxBytes);
    final base = item.parent;
    final issues = checkReadme(doc, base, (p) => this[p] != null);
    return ZxReadme(item, base, doc, issues);
  }

  /// The data of one file (at most [maxBytes] bytes, the start of the file,
  /// for previews). Throws [SevenZipException] on a data error or a wrong
  /// password (unless [maxBytes] was reached before the error).
  Future<Uint8List> readBytes(Object item,
      {int? maxBytes, ZxCancelToken? cancel}) async {
    final it = _resolveFile(item);
    final req =
        _extractRequest(ZxExtractMode.memory, [it.index], maxBytes: maxBytes);
    final (bytes, pw) = await _zxRun<(TransferableTypedData, String?)>(
        (ops) => workerReadBytes(req, ops),
        cancel: cancel,
        onPassword: onPassword);
    _rememberPassword(pw);
    return bytes.materialize().asUint8List();
  }

  /// Whether the file [item] (a [ZxItem], a path or an index) looks like
  /// an archive that [openNested] can open: the name of its format as
  /// the signatures at its start say (an item of a container format such
  /// as pak or GPT is tried with the full detection), or null. Only the
  /// start of the item is read, in the background isolate, so a UI can
  /// ask before it decides between going into the item and opening it
  /// with another program. A folder gives null.
  Future<String?> probeNested(Object item, {ZxCancelToken? cancel}) async {
    final it = _resolveFile(item, nested: true);
    if (it.isDir) return it.nestedFormat;
    final req = _extractRequest(ZxExtractMode.memory, [it.index]);
    final (name, pw) = await _zxRun<(String?, String?)>(
        (ops) => workerProbe(req, ops),
        cancel: cancel,
        onPassword: onPassword);
    _rememberPassword(pw);
    return name;
  }

  // ---- writing ----

  /// Adds [sources] (files and folders with everything below them) into
  /// the folder [destination] of the archive ('' for the top level).
  /// Items with the same path are replaced.
  Future<ZxUpdateResult> add(List<ZxSource> sources,
      {String destination = '',
      ZxOptions options = const ZxOptions(),
      void Function(ZxProgress progress)? onProgress,
      ZxCancelToken? cancel}) async {
    _need(capabilities.canAdd, 'adding');
    return _update(ZxUpdateKind.add, onProgress, cancel,
        options: options,
        destination: _norm(destination),
        sources: [
          for (final s in sources)
            ZxSource(File(s.path).absolute.path, storedAs: s.storedAs)
        ]);
  }

  /// Deletes the items at [paths] (a folder with everything below it).
  Future<ZxUpdateResult> delete(List<String> paths,
      {void Function(ZxProgress progress)? onProgress,
      ZxCancelToken? cancel}) async {
    _need(capabilities.canDelete, 'deleting');
    return _update(ZxUpdateKind.delete, onProgress, cancel,
        paths: [for (final p in paths) _norm(p)]);
  }

  /// Renames the item [from] to [to] (full paths; a folder renames
  /// everything below it). The data is not recompressed.
  Future<ZxUpdateResult> rename(String from, String to,
      {void Function(ZxProgress progress)? onProgress,
      ZxCancelToken? cancel}) async {
    _need(capabilities.canRename, 'renaming');
    final f = _norm(from), t = _norm(to);
    if (f.isEmpty || t.isEmpty) throw ArgumentError('empty path');
    return _update(ZxUpdateKind.rename, onProgress, cancel,
        paths: [f], newPath: t);
  }

  /// Adds an empty folder entry at [path].
  Future<ZxUpdateResult> createFolder(String path,
      {ZxCancelToken? cancel}) async {
    _need(capabilities.canCreateFolder, 'folders');
    final p = _norm(path);
    if (p.isEmpty) throw ArgumentError('empty path');
    return _update(ZxUpdateKind.createFolder, null, cancel, paths: [p]);
  }

  /// Sets the archive comment (zip, rar5); null or '' removes it.
  Future<ZxUpdateResult> setComment(String? comment,
      {ZxCancelToken? cancel}) async {
    _need(capabilities.canSetComment, 'comments');
    return _update(ZxUpdateKind.setComment, null, cancel,
        comment: comment ?? '');
  }

  // ---- .zx ----

  /// .zx: rewrites the archive keeping only the data of the last [keep]
  /// generations (the blocks are copied, not recompressed; a volume set is
  /// written again with the same volume sizes). Returns the bytes freed.
  /// The generations kept keep their numbers and times.
  Future<int> compact({int keep = 1, ZxCancelToken? cancel}) async {
    _needZx('compaction');
    _need(capabilities.canAdd, 'compaction');
    final req = ZxZxRequest(path, password, onPassword != null, ZxZxOp.compact,
        '$keep', searchDirs);
    final (l, freed) = await _zxRun<(ZxListing, int)>(
        (ops) => workerZx(req, ops),
        cancel: cancel,
        onPassword: onPassword);
    _set(l);
    return freed;
  }

  /// .zx: the seals of the archive (signed generations, docs/zx-format.md
  /// "Seals"), from its last generation back to the activation: the Index
  /// hashes, signatures, chain and roles are checked, and with [full]
  /// every stored byte (one pass over the file). No password is needed.
  /// Empty for a volume set; all [ZxSealState.plain] for an archive that
  /// was never sealed.
  Future<List<ZxGenerationSeal>> seals({bool full = false}) async {
    _needZx('seals');
    final p = path;
    return Isolate.run(() => zxCheckSealsOfFile(p, full: full));
  }

  /// .zx: appends a generation with the same files, signed with [key] (an
  /// nsec or 64 hex digits): it signs the history so far, or with
  /// [activate] starts sealing ([key] becomes the admin). The admin can
  /// also switch sealing off ([deactivate]), add and remove maintainers
  /// (npubs or hex keys), set who may sign ([rule]), and hand the admin
  /// role to [newAdmin], who accepts it with its key ([newAdminKey]) or
  /// its acceptance signature ([acceptance], 128 hex digits). Returns the
  /// number of the new generation.
  Future<int> sign(String key,
      {bool activate = false,
      bool deactivate = false,
      List<String> addMaintainers = const [],
      List<String> removeMaintainers = const [],
      ZxWriteRule? rule,
      String? newAdmin,
      String? newAdminKey,
      String? acceptance,
      ZxCancelToken? cancel}) async {
    _needZx('seals');
    final props = [
      ['sign', key],
      if (activate) ['seal', 'on'],
      if (deactivate) ['seal', 'off'],
      if (addMaintainers.isNotEmpty)
        ['addmaintainer', addMaintainers.join(',')],
      if (removeMaintainers.isNotEmpty)
        ['delmaintainer', removeMaintainers.join(',')],
      if (rule != null) ['writerule', rule.name],
      if (newAdmin != null) ['admin', newAdmin],
      if (newAdminKey != null) ['adminkey', newAdminKey],
      if (acceptance != null) ['adminaccept', acceptance],
    ];
    final req = ZxZxRequest(path, password, onPassword != null, ZxZxOp.seal,
        jsonEncode(props), searchDirs);
    final (l, gen) = await _zxRun<(ZxListing, int)>((ops) => workerZx(req, ops),
        cancel: cancel, onPassword: onPassword);
    _set(l);
    return gen;
  }

  /// .zx: every version of the file at [path] across the generations,
  /// oldest first, with the generation (and date) that wrote it and the
  /// one that replaced or deleted it.
  Future<List<ZxFileVersion>> timeline(String path,
      {ZxCancelToken? cancel}) async {
    _needZx('timelines');
    final req = ZxZxRequest(this.path, password, onPassword != null,
        ZxZxOp.timeline, _norm(path), searchDirs);
    return _zxRun<List<ZxFileVersion>>((ops) => workerZx(req, ops),
        cancel: cancel, onPassword: onPassword);
  }

  /// .zx: the items (of the generation shown) whose content has the
  /// SHA-256 [sha256] (hex), by the sorted lookup table of the archive.
  List<ZxItem> findBySha256(String sha256) {
    final h = sha256.toLowerCase();
    return [
      for (final i in items)
        if (i.sha256 == h) i
    ];
  }

  /// .zx: the items whose TLSH digest is within [maxDistance] of the
  /// digest of [item] (a [ZxItem], a path or a TLSH digest), nearest
  /// first, without [item] itself.
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

  void _needZx(String what) {
    if (format != 'zx') {
      throw SevenZipException(
          '$format: $what are for .zx archives', SevenZipError.unsupported);
    }
  }

  // ---- helpers ----

  void _need(bool ok, String what) {
    if (!ok) {
      throw SevenZipException(
          '$format: $what is not supported for this archive',
          SevenZipError.unsupported);
    }
  }

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

  ZxExtractRequest _extractRequest(ZxExtractMode mode, List<Object>? items,
      {String? outDir,
      bool keepPaths = true,
      String? relativeTo,
      ZxOverwrite overwrite = ZxOverwrite.overwrite,
      bool restoreTimes = false,
      bool restoreModes = false,
      bool restoreSymlinks = false,
      int? maxBytes}) {
    List<String>? paths;
    List<int>? indices;
    if (items != null) {
      paths = [];
      indices = [];
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
    }
    return ZxExtractRequest(
        archivePath: _base,
        chain: _chain,
        nest: _nest,
        password: password,
        canAsk: onPassword != null,
        // copying the listing to the worker costs time on this isolate:
        // only when reading it again would decode the whole archive
        items: _listing.sequential ? this.items : null,
        mode: mode,
        paths: paths,
        indices: indices,
        outDir: outDir,
        keepPaths: keepPaths,
        relativeTo: relativeTo,
        overwrite: overwrite,
        restoreTimes: restoreTimes,
        restoreModes: restoreModes,
        restoreSymlinks: restoreSymlinks,
        maxBytes: maxBytes,
        version: _baseVersion,
        searchDirs: searchDirs);
  }

  Future<ZxExtractResult> _extractRun(
      ZxExtractRequest req,
      void Function(ZxProgress)? onProgress,
      ZxCancelToken? cancel,
      ZxOverwriteCallback? onOverwrite) async {
    final (r, pw) = await _zxRun<(ZxExtractResult, String?)>(
        (ops) => workerExtract(req, ops),
        onProgress: onProgress,
        cancel: cancel,
        onPassword: onPassword,
        onOverwrite: onOverwrite);
    _rememberPassword(pw);
    return r;
  }

  Future<ZxUpdateResult> _update(ZxUpdateKind kind,
      void Function(ZxProgress)? onProgress, ZxCancelToken? cancel,
      {ZxOptions options = const ZxOptions(),
      String destination = '',
      List<ZxSource> sources = const [],
      List<String> paths = const [],
      String? newPath,
      String? comment}) async {
    final req = ZxUpdateRequest(
        kind: kind,
        archivePath: path,
        password: password,
        canAsk: onPassword != null,
        options: options,
        destination: destination,
        sources: sources,
        paths: paths,
        newPath: newPath,
        comment: comment,
        searchDirs: searchDirs);
    final (l, r) = await _zxRun<(ZxListing, ZxUpdateResult)>(
        (ops) => workerUpdate(req, ops),
        onProgress: onProgress,
        cancel: cancel,
        onPassword: onPassword);
    _set(l);
    return r;
  }
}

String _norm(String p) => zxNormalizePath(p);

// ---------------------------------------------------------------------------
// The isolate runner: one isolate per operation, like `_run` of api.dart,
// with questions from the worker answered on this isolate.

Future<R> _zxRun<R>(ZxBody body,
    {void Function(ZxProgress)? onProgress,
    ZxCancelToken? cancel,
    ZxPasswordCallback? onPassword,
    ZxOverwriteCallback? onOverwrite}) async {
  if (cancel != null && cancel.isCancelled) {
    throw const SevenZipException('Cancelled', SevenZipError.cancelled);
  }
  final port = RawReceivePort();
  final done = Completer<R>();
  Isolate? isolate;
  SendPort? replies;
  final parts = <String>{};
  final dirs = <String>{};
  var cancelled = false;

  void cleanup() {
    for (final p in parts) {
      try {
        File(p).deleteSync();
      } on FileSystemException {
        // already gone
      }
    }
    parts.clear();
    for (final d in dirs) {
      try {
        Directory(d).deleteSync(recursive: true);
      } on FileSystemException {
        // already gone
      }
    }
    dirs.clear();
  }

  void fail(Object e, [StackTrace? st]) {
    if (!done.isCompleted) done.completeError(e, st);
  }

  Future<void> answer(int id, Object request) async {
    Object? a;
    try {
      if (request is ZxPasswordRequest) {
        a = onPassword == null ? null : await onPassword(request);
      } else if (request is ZxOverwriteRequest) {
        a = onOverwrite == null
            ? ZxOverwriteAnswer.skip
            : await onOverwrite(request);
      }
    } catch (e) {
      // a failing callback gives up (no password, cancel)
      a = request is ZxOverwriteRequest ? ZxOverwriteAnswer.cancel : null;
    }
    if (!cancelled && !done.isCompleted) replies?.send((id, a));
  }

  port.handler = (Object? m) {
    switch (m) {
      case ('p', final SevenZipProgress p):
        if (!cancelled) onProgress?.call(p);
      case ('reply', final SendPort sp):
        replies = sp;
      case ('ask', final int id, final Object request):
        answer(id, request);
      case ('f+', final String p):
        parts.add(p);
      case ('f-', final String p):
        parts.remove(p);
      case ('d+', final String p):
        dirs.add(p);
      case ('d-', final String p):
        dirs.remove(p);
      case ('ok', final Object? v):
        port.close();
        if (!done.isCompleted) done.complete(v as R);
      case ('err', final Object e, final String st):
        cleanup();
        port.close();
        fail(e, StackTrace.fromString(st));
      case [final Object? e, final Object? st]:
        // an uncaught asynchronous error of the worker
        isolate?.kill(priority: Isolate.immediate);
        fail(e ?? 'isolate error',
            st == null ? null : StackTrace.fromString('$st'));
      case null:
        // the worker exited (after a result, or killed)
        port.close();
        if (!done.isCompleted) {
          cleanup();
          fail(cancelled
              ? const SevenZipException('Cancelled', SevenZipError.cancelled)
              : const SevenZipException(
                  'Worker isolate exited', SevenZipError.io));
        }
    }
  };

  void onCancel() {
    if (done.isCompleted || cancelled) return;
    cancelled = true;
    isolate?.kill(priority: Isolate.immediate);
  }

  cancel?.addCancelListener(onCancel);
  try {
    isolate = await Isolate.spawn(
        zxIsolateMain, (port.sendPort, body, onProgress != null),
        onExit: port.sendPort, onError: port.sendPort);
    if (cancelled) isolate.kill(priority: Isolate.immediate);
  } catch (_) {
    port.close();
    cancel?.removeCancelListener(onCancel);
    rethrow;
  }
  try {
    return await done.future;
  } finally {
    cancel?.removeCancelListener(onCancel);
  }
}
