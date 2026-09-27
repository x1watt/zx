// What the app knows about the archive formats: the formats a new archive
// can have, their options, the file name rules (the folder an archive
// extracts to) and the extensions the desktop integration registers.

import 'package:path/path.dart' as p;

/// A format a new archive can be written in.
class NewFormat {
  /// Stable id (settings, tests): '7z', 'zip', 'tar.gz'...
  final String id;
  final String label;

  /// The extension of a new archive, without the dot.
  final String extension;

  /// The format name given to ZxArchive.create.
  final String createFormat;

  /// Holds exactly one file (gz, bz2, xz).
  final bool singleFile;
  final List<String> methods;
  final bool levels;
  final bool password;
  final bool encryptNames;
  final bool solid;

  const NewFormat(
    this.id,
    this.label,
    this.extension,
    this.createFormat, {
    this.singleFile = false,
    this.methods = const [],
    this.levels = true,
    this.password = false,
    this.encryptNames = false,
    this.solid = false,
  });
}

const kNewFormats = <NewFormat>[
  // zx's own format (docs/zx-format.md), the default: any codec, updates
  // append generations (history by date), SHA-256 and TLSH per file
  NewFormat(
    'zx',
    'zx',
    'zx',
    'zx',
    methods: ['LZMA2', 'PPMd8', 'PPMd', 'BZip2', 'Deflate', 'zpaq', 'store'],
    password: true,
    encryptNames: true,
    solid: true,
  ),
  NewFormat(
    '7z',
    '7z',
    '7z',
    '7z',
    methods: ['LZMA2', 'LZMA', 'PPMd', 'Copy'],
    password: true,
    encryptNames: true,
    solid: true,
  ),
  NewFormat(
    'zip',
    'zip',
    'zip',
    'zip',
    methods: ['Deflate', 'Deflate64', 'BZip2', 'LZMA', 'PPMd', 'Copy'],
    password: true,
  ),
  NewFormat('tar.gz', 'tar.gz', 'tar.gz', 'tar.gz'),
  NewFormat('tar.bz2', 'tar.bz2', 'tar.bz2', 'tar.bz2'),
  NewFormat('tar.xz', 'tar.xz', 'tar.xz', 'tar.xz'),
  NewFormat(
    'rar',
    'rar (RAR5)',
    'rar',
    'Rar5',
    password: true,
    encryptNames: true,
    solid: true,
  ),
  NewFormat('tar', 'tar', 'tar', 'tar', levels: false),
  NewFormat('lzh', 'lzh', 'lzh', 'Lzh', methods: ['lh5', 'lh6', 'lh7', 'lh0']),
  NewFormat(
    'arj',
    'arj',
    'arj',
    'Arj',
    methods: ['1', '2', '3', '4', '0'],
    password: true,
  ),
  // zpaq: versioned, deduplicated backups (each update adds a version);
  // the zpaq methods instead of the levels (5 is very slow)
  NewFormat(
    'zpaq',
    'zpaq (versions)',
    'zpaq',
    'zpaq',
    methods: ['1', '2', '3', '4', '5', '0'],
    levels: false,
    password: true,
  ),
  NewFormat('gz', 'gz (one file)', 'gz', 'gzip', singleFile: true),
  NewFormat('bz2', 'bz2 (one file)', 'bz2', 'bzip2', singleFile: true),
  NewFormat('xz', 'xz (one file)', 'xz', 'xz', singleFile: true),
];

NewFormat newFormatById(String id) =>
    kNewFormats.firstWhere((f) => f.id == id, orElse: () => kNewFormats[0]);

/// The options of adding to an archive of the format [format] (the name
/// ZxArchive gives, '7z', 'zip', 'Rar5'...), as the add dialog shows them.
NewFormat? formatForArchive(String format, List<String> outer) {
  if (format == 'tar' && outer.isNotEmpty) {
    switch (outer.first) {
      case 'gzip':
        return newFormatById('tar.gz');
      case 'bzip2':
        return newFormatById('tar.bz2');
      case 'xz':
        return newFormatById('tar.xz');
    }
    return null;
  }
  for (final f in kNewFormats) {
    if (f.createFormat == format) return f;
  }
  return null;
}

/// Labels of the arj and zpaq methods.
String methodLabel(NewFormat f, String m) {
  if (f.id == 'zpaq') {
    return switch (m) {
      '0' => 'Store (deduplication only)',
      '1' => 'Method 1 (fast)',
      '5' => 'Method 5 (best, slow)',
      _ => 'Method $m',
    };
  }
  if (f.id == 'arj') {
    return switch (m) {
      '0' => 'Store',
      '1' => 'Method 1 (best)',
      '2' => 'Method 2',
      '3' => 'Method 3',
      _ => 'Method 4 (fastest)',
    };
  }
  return m;
}

/// Extensions of the archives the app opens, longest first (compound
/// ones before their last part).
const kArchiveExtensions = <String>[
  'tar.gz',
  'tar.bz2',
  'tar.xz',
  'tar.lzma',
  'tar.bz',
  'tar.z',
  '7z',
  'zip',
  'jar',
  'war',
  'ear',
  'apk',
  'zipx',
  'rar',
  'tar',
  'tgz',
  'tbz',
  'tbz2',
  'tb2',
  'txz',
  'tlz',
  'gz',
  'bz2',
  'bz',
  'xz',
  'lzma',
  'lzh',
  'lha',
  'arj',
  'zpaq',
  'zx',
  'cbz',
  'cbr',
  'epub',
  'docx',
  'xlsx',
  'pptx',
  'odt',
  'ods',
  'odp',
];

/// The extensions that are only a compressor around another file name.
const _compressorExt = {'gz', 'bz2', 'bz', 'xz', 'lzma', 'z'};

/// True when [path] has the name of an archive the app handles, volume
/// names included (x.7z.001, x.part1.rar, x.r00).
bool looksLikeArchive(String path) {
  final n = p.basename(path).toLowerCase();
  if (RegExp(r'\.\d{3}$').hasMatch(n)) return true;
  if (RegExp(r'\.r\d\d$').hasMatch(n)) return true;
  for (final e in kArchiveExtensions) {
    if (n.endsWith('.$e')) return true;
  }
  return false;
}

/// The name of the folder an archive extracts to: the file name without
/// its archive extensions (x.tar.gz and x.tgz give x, x.7z.001 gives x,
/// x.part1.rar gives x, x.txt.gz gives x.txt).
String folderNameFor(String archivePath) {
  var n = p.basename(archivePath);
  var lower = n.toLowerCase();
  String cut(int k) {
    n = n.substring(0, n.length - k);
    lower = lower.substring(0, lower.length - k);
    return n;
  }

  // volumes: x.7z.001, x.zip.001, x.001, x.part01.rar, x.r00
  final num = RegExp(r'\.\d{3}$').firstMatch(lower);
  if (num != null) cut(num.group(0)!.length);
  final part = RegExp(r'\.part\d+\.rar$').firstMatch(lower);
  if (part != null) {
    cut(part.group(0)!.length);
    return n.isEmpty ? 'archive' : n;
  }
  final rNN = RegExp(r'\.r\d\d$').firstMatch(lower);
  if (rNN != null) {
    cut(rNN.group(0)!.length);
    return n.isEmpty ? 'archive' : n;
  }
  for (final e in const [
    'tar.gz',
    'tar.bz2',
    'tar.xz',
    'tar.lzma',
    'tar.bz',
    'tar.z',
  ]) {
    if (lower.endsWith('.$e') && lower.length > e.length + 1) {
      cut(e.length + 1);
      return n;
    }
  }
  final dot = lower.lastIndexOf('.');
  if (dot > 0) {
    final ext = lower.substring(dot + 1);
    if (kArchiveExtensions.contains(ext) || _compressorExt.contains(ext)) {
      cut(ext.length + 1);
    }
  }
  return n.isEmpty ? 'archive' : n;
}

/// The MIME types (shared-mime-info names) of the formats, for the desktop
/// entry and the default application settings. The aliases are listed too
/// because file managers and older mime databases still use them.
const kArchiveMimeTypes = <String>[
  'application/x-7z-compressed',
  'application/zip',
  'application/x-zip-compressed',
  'application/java-archive',
  'application/vnd.rar',
  'application/x-rar',
  'application/x-rar-compressed',
  'application/x-tar',
  'application/x-compressed-tar',
  'application/gzip',
  'application/x-gzip',
  'application/x-bzip2',
  'application/x-bzip',
  'application/x-bzip2-compressed-tar',
  'application/x-bzip-compressed-tar',
  'application/x-bzip1',
  'application/x-bzip1-compressed-tar',
  'application/x-xz',
  'application/x-xz-compressed-tar',
  'application/x-lzma',
  'application/x-lzma-compressed-tar',
  'application/x-lha',
  'application/x-lzh-compressed',
  'application/x-arj',
  'application/x-zpaq',
  'application/x-zx',
];

/// The types the association checks and sets as default (one per format,
/// the canonical names of shared-mime-info).
const kPrimaryMimeTypes = <String>[
  'application/x-7z-compressed',
  'application/zip',
  'application/vnd.rar',
  'application/x-tar',
  'application/x-compressed-tar',
  'application/gzip',
  'application/x-bzip2',
  'application/x-bzip2-compressed-tar',
  'application/x-xz',
  'application/x-xz-compressed-tar',
  'application/x-lzma',
  'application/x-lzma-compressed-tar',
  'application/x-lha',
  'application/x-arj',
  'application/x-zpaq',
  'application/x-zx',
];

/// The extensions registered on Windows and matched by the file manager
/// actions.
const kIntegrationExtensions = <String>[
  '7z',
  'zip',
  'jar',
  'rar',
  'tar',
  'gz',
  'tgz',
  'bz2',
  'tbz',
  'tbz2',
  'xz',
  'txz',
  'lzma',
  'tlz',
  'lzh',
  'lha',
  'arj',
  'zpaq',
  'zx',
  '001',
];

/// The shared-mime-info definition of application/x-zx (not in the
/// freedesktop database yet): the magic at offset 0 and the glob. The
/// Linux integration installs it in the user's mime packages, the .deb in
/// /usr/share/mime/packages.
const kZxMimeXml = '''<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-zx">
    <comment>zx archive</comment>
    <generic-icon name="package-x-generic"/>
    <magic priority="60">
      <match type="string" offset="0" value="\\x89ZX\\x0d\\x0a\\x1a\\x0a\\x00"/>
    </magic>
    <glob pattern="*.zx"/>
  </mime-type>
</mime-info>
''';

/// The file name of [kZxMimeXml] in a mime/packages folder.
const kZxMimeFile = 'zx-archive.xml';
