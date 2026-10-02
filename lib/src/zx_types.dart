// The types of the generic archive API (zx_api.dart) that its callers
// hold: items, listings, results, the questions of an operation. Plain
// Dart: the web client (lib/zx_client.dart) compiles them with dart2js and
// receives them from the engine worker.

import 'api_types.dart';
import 'io/streams.dart' show SevenZipError, SevenZipException;
import 'readme/markdown.dart' show MdDocument;
import 'readme/readme_links.dart' show ReadmeIssue;

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

  /// The SHA-256 of the content (hex), when the format stores it (.zx).
  final String? sha256;

  /// The TLSH digest of the content ("T1" and 70 hex digits), .zx only;
  /// null for small or uniform files.
  final String? tlsh;

  /// The generation (.zx) or version (zpaq) that wrote this content.
  final int? generation;

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
    this.sha256,
    this.tlsh,
    this.generation,
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

/// A README of an archive ([ZxArchive.readme]).
class ZxReadme {
  /// The file.
  final ZxItem item;

  /// Its folder: the relative links and images start there.
  final String baseDir;
  final MdDocument doc;

  /// The links and images that can not work (images from outside the
  /// archive are never shown).
  final List<ReadmeIssue> issues;
  const ZxReadme(this.item, this.baseDir, this.doc, this.issues);
}

/// The part of a README that [ZxArchive.readme] reads.
const int readmeMaxBytes = 1 << 20;

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

/// One version of a path in a .zx archive ([ZxArchive.timeline]).
class ZxFileVersion {
  final String path;

  /// The generation that wrote this version, and when.
  final int generation;
  final DateTime time;
  final int size;

  /// SHA-256 of the content (hex).
  final String? sha256;

  /// The generation in which the version was replaced or deleted (null
  /// while it is the current one), and when.
  final int? endGeneration;
  final DateTime? endTime;

  /// The path was deleted in [endGeneration] (not replaced).
  final bool deleted;
  const ZxFileVersion(this.path, this.generation, this.time, this.size,
      this.sha256, this.endGeneration, this.endTime, this.deleted);

  @override
  String toString() => 'ZxFileVersion($path, gen $generation $time, $size'
      '${endGeneration == null ? '' : deleted ? ', deleted in $endGeneration' : ', replaced in $endGeneration'})';
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
