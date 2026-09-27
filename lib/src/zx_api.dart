// The generic, isolate based archive API: every format of the command line
// tool (7z, zip and its extensions, rar, tar, gzip, bzip2, xz, lzma, the
// compressed tars, lzh, arj, split volumes) through one handle, for
// archive managers. The work runs in background isolates (zx_worker.dart)
// on the format layer of the command line tool (load_codecs.dart,
// open_archive.dart, the arc_*.dart adapters); the caller's isolate only
// sends requests and receives results, throttled progress and the
// questions of the operation (password, overwrite).

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'api.dart';
import 'cli/nest.dart' show NestNodeSpec;
import 'io/streams.dart';
import 'zx_worker.dart';

/// Progress of a [ZxArchive] operation (bytes done and total, current
/// item), delivered on the calling isolate at most every 100 ms, plus the
/// last event.
typedef ZxProgress = SevenZipProgress;

/// Cancels [ZxArchive] operations: the worker isolate is killed and the
/// files it was writing are deleted. The operation completes with a
/// [SevenZipException] of kind [SevenZipError.cancelled].
typedef ZxCancelToken = SevenZipCancelToken;

/// A file or folder to add ([path] on disk, stored under the last
/// component of the path or under `storedAs`).
typedef ZxSource = SevenZipSource;

/// Why a password is asked.
enum ZxPasswordReason {
  /// The file names are encrypted: the archive can not be listed without
  /// it.
  open,

  /// Encrypted items are extracted or tested.
  extract,

  /// An update has to decode encrypted items (for example deleting from a
  /// solid encrypted 7z block).
  update,
}

/// A question for the password callback.
class ZxPasswordRequest {
  final String archivePath;
  final ZxPasswordReason reason;

  /// The item that needs it, when known.
  final String? itemPath;

  /// True when the previous password was wrong.
  final bool retry;

  /// 0 for the first question of the operation, then 1, 2...
  final int attempt;

  const ZxPasswordRequest(this.archivePath, this.reason,
      {this.itemPath, this.retry = false, this.attempt = 0});

  @override
  String toString() => 'ZxPasswordRequest(${reason.name}, $archivePath'
      '${itemPath == null ? '' : ', $itemPath'}${retry ? ', retry' : ''})';
}

/// Answers a [ZxPasswordRequest] on the calling isolate: the password, or
/// null to give up (the operation then fails with
/// [SevenZipError.cancelled] at open, and reports the items as
/// [SevenZipError.wrongPassword] errors at extraction).
typedef ZxPasswordCallback = Future<String?> Function(
    ZxPasswordRequest request);

/// What to do when a file to extract already exists.
enum ZxOverwrite {
  overwrite,
  skip,

  /// Extract to `name_1.ext` (the first free number).
  rename,

  /// Ask the [ZxOverwriteCallback] for each file.
  ask,
}

/// An answer of the [ZxOverwriteCallback]. The `...All` answers apply to
/// the rest of the operation.
enum ZxOverwriteAnswer {
  overwrite,
  skip,
  rename,
  overwriteAll,
  skipAll,
  renameAll,

  /// Stops the operation: it fails with [SevenZipError.cancelled] before
  /// anything is written.
  cancel,
}

/// A file to extract exists already (or two items extract to the same
/// name).
class ZxOverwriteRequest {
  /// The existing file on disk.
  final String targetPath;

  /// The item of the archive.
  final String itemPath;
  final int? existingSize;
  final DateTime? existingModified;
  final int? newSize;
  final DateTime? newModified;

  const ZxOverwriteRequest(this.targetPath, this.itemPath,
      {this.existingSize,
      this.existingModified,
      this.newSize,
      this.newModified});

  @override
  String toString() => 'ZxOverwriteRequest($targetPath <- $itemPath)';
}

typedef ZxOverwriteCallback = Future<ZxOverwriteAnswer> Function(
    ZxOverwriteRequest request);

/// One item of an archive, or a folder implied by the paths of the items
/// ([isImplied], with [index] -1).
class ZxItem {
  /// Index in the archive (as the handler numbers the items), -1 for an
  /// implied folder.
  final int index;

  /// The path with '/' separators, without a leading or trailing '/'.
  final String path;
  final bool isDir;

  /// A folder that has no entry of its own in the archive.
  final bool isImplied;

  /// Unpacked size (null when the format does not tell it).
  final int? size;

  /// Packed size (null when not known per item, as inside a solid block).
  final int? packSize;
  final DateTime? modified;
  final DateTime? created;
  final DateTime? accessed;

  /// The attributes as 7-Zip gives them (FILE_ATTRIBUTE_* in the low bits,
  /// the POSIX st_mode in the high 16 bits when bit 0x8000 is set).
  final int? attrib;

  /// The POSIX st_mode (type and permission bits), when known.
  final int? posixMode;
  final int? crc;

  /// The compression method (and encryption) as 7-Zip names it.
  final String? method;
  final bool encrypted;

  /// Target of a symbolic link (tar, zip, rar, 7z with -snl...).
  final String? symlinkTarget;

  /// Target of a hard link (tar, cpio, SquashFS...).
  final String? hardlinkTarget;
  final String? comment;

  /// In a flattened archive (`ZxArchive.open(flatten: true)`): the item
  /// indices from the archive to this item, one per nested archive on the
  /// way, then the index in its own archive. null otherwise.
  final List<int>? nestChain;

  /// In a flattened archive: the format of the nested archive this folder
  /// shows (the item itself is an image or an archive). null otherwise.
  final String? nestedFormat;

  const ZxItem({
    required this.index,
    required this.path,
    required this.isDir,
    this.isImplied = false,
    this.size,
    this.packSize,
    this.modified,
    this.created,
    this.accessed,
    this.attrib,
    this.posixMode,
    this.crc,
    this.method,
    this.encrypted = false,
    this.symlinkTarget,
    this.hardlinkTarget,
    this.comment,
    this.nestChain,
    this.nestedFormat,
  });

  /// The last component of [path].
  String get name => path.substring(path.lastIndexOf('/') + 1);

  /// The folder of the item ('' at the top level).
  String get parent {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  /// The folder of a nested archive in a flattened archive.
  bool get isNested => nestedFormat != null;

  bool get isSymlink =>
      symlinkTarget != null ||
      (posixMode != null && (posixMode! & 0xF000) == 0xA000);

  @override
  String toString() => 'ZxItem(#$index $path${isDir ? '/' : ''}'
      '${isImplied ? ' implied' : ''}${size == null ? '' : ', $size'})';
}

/// What the format of an open archive allows.
class ZxCapabilities {
  final bool canAdd;
  final bool canDelete;
  final bool canRename;
  final bool canCreateFolder;
  final bool canSetComment;
  final bool canEncrypt;
  final bool canEncryptHeaders;

  const ZxCapabilities({
    this.canAdd = false,
    this.canDelete = false,
    this.canRename = false,
    this.canCreateFolder = false,
    this.canSetComment = false,
    this.canEncrypt = false,
    this.canEncryptHeaders = false,
  });

  bool get canUpdate => canAdd || canDelete || canRename || canSetComment;

  @override
  String toString() => 'ZxCapabilities(add $canAdd, delete $canDelete, '
      'rename $canRename, folder $canCreateFolder, comment $canSetComment, '
      'encrypt $canEncrypt, encryptHeaders $canEncryptHeaders)';
}

/// An item that could not be extracted or tested (or a link that was not
/// created).
class ZxItemError {
  final String path;
  final SevenZipError kind;
  final String? message;
  const ZxItemError(this.path, this.kind, [this.message]);
  @override
  String toString() =>
      '$path: ${kind.name}${message == null ? '' : ' ($message)'}';
}

/// Result of [ZxArchive.extract] and [ZxArchive.test].
class ZxExtractResult {
  final int files;
  final int dirs;

  /// Unpacked bytes of the files that were extracted (or tested).
  final int bytes;

  /// Files not written because they existed and were skipped.
  final int skipped;
  final List<ZxItemError> errors;

  const ZxExtractResult(
      this.files, this.dirs, this.bytes, this.skipped, this.errors);

  bool get ok => errors.isEmpty;

  /// True when every failure looks like a wrong password.
  bool get wrongPassword =>
      errors.isNotEmpty &&
      errors.every((e) => e.kind == SevenZipError.wrongPassword);

  @override
  String toString() => 'ZxExtractResult($files files, $dirs dirs, '
      '$bytes bytes${skipped == 0 ? '' : ', $skipped skipped'}'
      '${errors.isEmpty ? '' : ', errors: $errors'})';
}

/// Result of the operations that write a new version of the archive.
class ZxUpdateResult {
  /// Items written with new data (add, create, createFolder).
  final int added;

  /// Items removed (delete) or renamed (rename).
  final int changed;

  /// Items copied unchanged from the old archive.
  final int kept;

  /// Input paths that could not be read (they are not in the archive).
  final List<String> skipped;
  final int archiveSize;

  const ZxUpdateResult(
      this.added, this.changed, this.kept, this.skipped, this.archiveSize);

  @override
  String toString() => 'ZxUpdateResult($added added, $changed changed, '
      '$kept kept, $archiveSize bytes'
      '${skipped.isEmpty ? '' : ', skipped $skipped'})';
}

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

  /// Stores symbolic links as links (-snl). When false a link to a file is
  /// stored as the file, a link to a folder is skipped.
  final bool storeSymlinks;

  /// Other -m switches, name to value: {'d': '64m', 'mt': '2', 'em':
  /// 'AES256', 'rr': '3%', 'tc': 'on'}. An empty value is the bare switch.
  final Map<String, String> switches;

  const ZxOptions({
    this.level,
    this.method,
    this.solid,
    this.password,
    this.encryptHeaders,
    this.volumeSize,
    this.storeSymlinks = false,
    this.switches = const {},
  });
}

/// One version (update) of a journaling archive (zpaq): every update adds
/// one, and the archive can be opened as of any of them
/// ([ZxArchive.open] with `version`).
class ZxVersion {
  /// 1 for the first version.
  final int number;

  /// When the update was made (UTC).
  final DateTime time;

  /// Files and folders added or changed by the update.
  final int added;

  /// Files and folders it recorded as deleted.
  final int deleted;

  /// Compressed size of the data the update added.
  final int packSize;
  const ZxVersion(
      this.number, this.time, this.added, this.deleted, this.packSize);

  @override
  String toString() => 'ZxVersion($number, $time, +$added -$deleted)';
}

/// The contents and properties of an archive, as read by [ZxArchive.open].
class ZxListing {
  /// The format of the archive (7-Zip's names: '7z', 'zip', 'Rar',
  /// 'Rar5', 'tar', 'gzip', 'bzip2', 'xz', 'lzma', 'lzma86', 'Lzh', 'Arj',
  /// 'Split').
  final String format;

  /// The formats around it: ['gzip'] for a .tar.gz, ['Split'] for 7z
  /// volumes. Empty for a plain archive.
  final List<String> outerFormats;
  final int physicalSize;
  final String? method;
  final bool solid;

  /// The names are encrypted (a password was needed to list).
  final bool encryptedHeaders;
  final String? comment;
  final List<String> errors;
  final List<String> warnings;

  /// The volume files of a multi-volume archive (empty for one file).
  final List<String> volumes;
  final ZxCapabilities capabilities;

  /// The items, then the implied folders.
  final List<ZxItem> items;

  /// The password that opened the archive or was given for it.
  final String? password;

  /// The archive is read in one pass (a compressed tar): the operations
  /// get the listing from the handle instead of decoding it again.
  final bool sequential;

  /// The versions of a journaling archive (zpaq) up to the one shown;
  /// empty for the other formats.
  final List<ZxVersion> versions;

  /// The number of versions in a journaling archive (zpaq), whatever
  /// version is shown; 0 for the other formats.
  final int numVersions;

  const ZxListing({
    required this.format,
    required this.outerFormats,
    required this.physicalSize,
    required this.method,
    required this.solid,
    required this.encryptedHeaders,
    required this.comment,
    required this.errors,
    required this.warnings,
    required this.volumes,
    required this.capabilities,
    required this.items,
    required this.password,
    this.sequential = false,
    this.versions = const [],
    this.numVersions = 0,
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
      int? version})
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
  /// [version] opens a journaling archive (zpaq) as it was after that
  /// version (1 for the first update): the listing, extract, test and
  /// readBytes see the files of that version, and the handle is read only.
  /// Without it the last version is shown. [versions] lists them. Other
  /// formats ignore it.
  static Future<ZxArchive> open(String path,
      {String? password,
      ZxPasswordCallback? onPassword,
      ZxCancelToken? cancel,
      bool flatten = false,
      int maxDepth = 4,
      int? version}) async {
    if (version != null && version < 1) {
      throw ArgumentError.value(version, 'version', 'must be 1 or more');
    }
    final full = File(path).absolute.path;
    final req = ZxOpenRequest(full, password, onPassword != null,
        nest: flatten ? ZxNest(maxDepth) : null, version: version);
    final r = await _zxRun<ZxOpenResult>((ops) => workerOpen(req, ops),
        cancel: cancel, onPassword: onPassword);
    return ZxArchive._(full, r.listing, onPassword,
        flattened: flatten,
        maxDepth: maxDepth,
        base: r.base,
        chain: r.chain,
        layout: r.layout,
        temps: r.temps,
        version: version);
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
      {bool flatten = false,
      int maxDepth = 4,
      ZxCancelToken? cancel}) async {
    final it = _resolveFile(item, nested: true);
    final chain = [..._chain, ...(it.nestChain ?? [it.index])];
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
        version: _version);
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
        l.volumes.isNotEmpty ? l.volumes.first : full, l, onPassword);
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
  int? get version =>
      _listing.numVersions == 0 ? null : _listing.versions.length;

  /// The number of versions of a journaling archive, whatever version is
  /// shown; 0 for the other formats.
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
        version: _baseVersion);
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
        version: _baseVersion);
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
        comment: comment);
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
