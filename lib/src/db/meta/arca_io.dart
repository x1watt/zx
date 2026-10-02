// Arca interop (docs/zxdb-design.md 1.2): `.import-arca DIR` and
// `.export-arca DIR` as library functions over the metadata tables.
//
// Arca keeps, beside each file of a collection folder (arca_core
// sidecars.dart, docs/architecture.md 9.4):
//   Talk.webm           the file
//   Talk.arca.json      its manifest, format 'arca-manifest/1', written by
//                       JsonEncoder.withIndent('  ') plus a final newline,
//                       keys in LibraryFile.manifest() order: format, file,
//                       size, sha256, sha1 (only when known), mime, title,
//                       description, tags, added, layers
//   Talk.en.srt         subtitles, <base>.<lang>.srt, listed in the
//                       manifest's layers ({type, file, language, origin,
//                       tool, model, created} for machine-made ones)
// where <base> is the file name without its extension, or the full name
// when another file of the folder has the same stem (Song.mp3 and
// Song.flac). Video previews live in the app's previews/ folder as
// <sha256>.jpg (a still) and <sha256>.gif (an animation).
//
// Import reads every manifest under DIR into zx_meta and zx_layers (the
// subtitle text into zx_layers.content, so it is full-text searchable),
// subtitles beside a file that its manifest does not list (as layers
// marked "$sidecar"), and previews into zx_media; optionally it hands the
// described files to a callback that adds them to the archive. Export
// writes the manifests and subtitle files back next to the files (which
// `zx x` extracts), byte for byte as arca wrote them: what does not map to
// a column (unknown keys, a key order or null that is not arca's) is kept
// in zx_meta.extra and zx_layers.attrs ("$order"), and a manifest that
// still would not come out identical keeps its text ("$raw").

import 'dart:convert';
import '../../host/io.dart';
import 'dart:typed_data';

import '../system/archive_view.dart';
import 'meta_store.dart';

const String arcaManifestSuffix = '.arca.json';
const String arcaManifestFormat = 'arca-manifest/1';

/// arca's manifest writer (Sidecars.writeManifest).
String arcaEncodeManifest(Map<String, Object?> m) =>
    '${const JsonEncoder.withIndent('  ').convert(m)}\n';

const List<String> _topKeys = [
  'format', 'file', 'size', 'sha256', 'sha1', 'mime', 'title', //
  'description', 'tags', 'added', 'layers',
];
const List<String> _layerKeys = [
  'type', 'file', 'language', 'origin', 'tool', 'model', 'created',
];

String _hex(Uint8List b) {
  const d = '0123456789abcdef';
  final sb = StringBuffer();
  for (final x in b) {
    sb
      ..write(d[x >> 4])
      ..write(d[x & 15]);
  }
  return sb.toString();
}

Uint8List? _unhex(Object? s) {
  if (s is! String || s.length != 64) return null;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    final v = int.tryParse(s.substring(2 * i, 2 * i + 2), radix: 16);
    if (v == null) return null;
    out[i] = v;
  }
  return out;
}

String _stem(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

bool _isSidecarName(String n) =>
    n.endsWith(arcaManifestSuffix) || n.toLowerCase().endsWith('.srt');

/// arca's Sidecars.baseOf for a file named [name] among the file names
/// [names] of its folder: the stem, or the full name on a stem clash.
String arcaBaseName(String name, Iterable<String> names) {
  final stem = _stem(name);
  if (stem == name) return name;
  final clash =
      names.any((n) => n != name && !_isSidecarName(n) && _stem(n) == stem);
  return clash ? name : stem;
}

Map<String, Object?> _obj(Object? json) {
  if (json is String && json.isNotEmpty) {
    try {
      final v = jsonDecode(json);
      if (v is Map) return v.cast<String, Object?>();
    } on FormatException {
      // not JSON
    }
  }
  return <String, Object?>{};
}

/// (width, height) of a JPEG, PNG or GIF, or null.
(int, int)? imageSize(Uint8List b) {
  if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E) {
    final d = ByteData.sublistView(b);
    return (d.getUint32(16), d.getUint32(20));
  }
  if (b.length > 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return (b[6] | (b[7] << 8), b[8] | (b[9] << 8));
  }
  if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var p = 2;
    while (p + 9 < b.length) {
      if (b[p] != 0xFF) {
        p++;
        continue;
      }
      final m = b[p + 1];
      if (m == 0xFF) {
        p++;
        continue;
      }
      if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
        p += 2;
        continue;
      }
      final len = (b[p + 2] << 8) | b[p + 3];
      final sof = (m >= 0xC0 && m <= 0xCF) && m != 0xC4 && m != 0xC8 && m != 0xCC;
      if (sof && p + 8 < b.length) {
        return ((b[p + 7] << 8) | b[p + 8], (b[p + 5] << 8) | b[p + 6]);
      }
      p += 2 + len;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// manifest to rows and back

/// The rows of one manifest: zx_meta and zx_layers.
class ArcaRows {
  final List<Object?> meta;
  final List<List<Object?>> layers;
  ArcaRows(this.meta, this.layers);
}

/// Maps manifest [m] of the file at archive path [path] to rows. Layer
/// contents are filled by the caller. [original] (the manifest's text)
/// lets the rows record what they need to give it back byte for byte.
ArcaRows? arcaManifestToRows(Map<String, Object?> m, String path,
    {String? original}) {
  final sha = _unhex(m['sha256']);
  if (sha == null) return null;
  final extra = <String, Object?>{};
  final name = path.split('/').last;
  for (final e in m.entries) {
    switch (e.key) {
      case 'format':
        if (e.value != arcaManifestFormat) extra['format'] = e.value;
      case 'file':
        if (e.value != name) extra['file'] = e.value;
      case 'size':
        if (e.value is! int) extra['size'] = e.value;
      case 'sha256':
        if (e.value != _hex(sha)) extra['sha256'] = e.value;
      case 'sha1' || 'mime' || 'title' || 'description' || 'added':
        if (e.value is! String) extra[e.key] = e.value;
      case 'tags':
        final t = e.value;
        if (t is! List || t.any((x) => x is! String)) extra['tags'] = t;
      case 'layers':
        if (e.value is! List) extra['layers'] = e.value;
      default:
        extra[e.key] = e.value;
    }
  }
  String? str(String k) => extra.containsKey(k) ? null : m[k] as String?;
  final tags = m['tags'];
  final meta = <Object?>[
    sha,
    path,
    extra.containsKey('size') ? null : m['size'] as int?,
    str('title'),
    str('description'),
    str('mime'),
    str('sha1'),
    str('added'),
    tags is List && !extra.containsKey('tags') ? jsonEncode(tags) : null,
    null,
  ];
  final layers = <List<Object?>>[];
  final ll = m['layers'];
  if (ll is List && !extra.containsKey('layers')) {
    for (var n = 0; n < ll.length; n++) {
      final l = ll[n];
      if (l is! Map) {
        // not a layer object: keep it whole
        layers.add(_layerRow(sha, n, {}, {r'$value': l}));
        continue;
      }
      final lm = l.cast<String, Object?>();
      final attrs = <String, Object?>{};
      for (final e in lm.entries) {
        if (!_layerKeys.contains(e.key) || (e.value != null && e.value is! String)) {
          attrs[e.key] = e.value;
        }
      }
      final keys = lm.keys.toList();
      final canon = [
        for (final k in _layerKeys)
          if (lm[k] is String) k,
        for (final k in keys)
          if (!_layerKeys.contains(k)) k,
      ];
      if (!_sameList(keys, canon)) attrs[r'$order'] = keys;
      layers.add(_layerRow(sha, n, lm, attrs));
    }
  }
  final keys = m.keys.toList();
  final canon = _canonTop(meta, extra);
  if (!_sameList(keys, canon)) extra[r'$order'] = keys;
  if (extra.isNotEmpty) meta[ZxMetaSchema.mExtra] = jsonEncode(extra);
  if (original != null) {
    final again = arcaRowsToManifestText(meta, layers);
    if (again != original) {
      extra[r'$raw'] = original;
      meta[ZxMetaSchema.mExtra] = jsonEncode(extra);
    }
  }
  return ArcaRows(meta, layers);
}

List<Object?> _layerRow(Uint8List sha, int n, Map<String, Object?> lm,
        Map<String, Object?> attrs) =>
    [
      sha,
      n,
      lm['type'] is String ? lm['type'] : null,
      lm['language'] is String ? lm['language'] : null,
      lm['origin'] is String ? lm['origin'] : null,
      lm['tool'] is String ? lm['tool'] : null,
      lm['model'] is String ? lm['model'] : null,
      lm['created'] is String ? lm['created'] : null,
      lm['file'] is String ? lm['file'] : null,
      null,
      null,
      attrs.isEmpty ? null : jsonEncode(attrs),
    ];

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The key order arca would write for these rows (arca always writes
/// "layers").
List<String> _canonTop(List<Object?> meta, Map<String, Object?> extra) {
  final present = <String>{
    'format',
    'file',
    if (meta[ZxMetaSchema.mSize] != null || extra.containsKey('size')) 'size',
    'sha256',
    if (((meta[ZxMetaSchema.mSha1] as String?)?.isNotEmpty ?? false) ||
        extra.containsKey('sha1'))
      'sha1',
    if (meta[ZxMetaSchema.mMime] != null || extra.containsKey('mime')) 'mime',
    if (meta[ZxMetaSchema.mTitle] != null || extra.containsKey('title'))
      'title',
    if (meta[ZxMetaSchema.mDescription] != null ||
        extra.containsKey('description'))
      'description',
    if (meta[ZxMetaSchema.mTags] != null || extra.containsKey('tags')) 'tags',
    if (meta[ZxMetaSchema.mAdded] != null || extra.containsKey('added'))
      'added',
    'layers',
  };
  return [
    for (final k in _topKeys)
      if (present.contains(k)) k,
    for (final k in extra.keys)
      if (!_topKeys.contains(k) && !k.startsWith(r'$')) k,
  ];
}

Map<String, Object?> _layerObject(List<Object?> l) {
  final attrs = _obj(l[ZxMetaSchema.lAttrs]);
  final known = <String, Object?>{
    'type': l[ZxMetaSchema.lKind],
    'file': l[ZxMetaSchema.lFile],
    'language': l[ZxMetaSchema.lLanguage],
    'origin': l[ZxMetaSchema.lOrigin],
    'tool': l[ZxMetaSchema.lTool],
    'model': l[ZxMetaSchema.lModel],
    'created': l[ZxMetaSchema.lCreated],
  };
  final order = attrs[r'$order'];
  final keys = order is List
      ? [for (final k in order) '$k']
      : [
          for (final k in _layerKeys)
            if (known[k] != null) k,
          for (final k in attrs.keys)
            if (!_layerKeys.contains(k) && !k.startsWith(r'$')) k,
        ];
  return {
    for (final k in keys) k: attrs.containsKey(k) ? attrs[k] : known[k],
  };
}

/// The manifest object of the rows (without [r'$raw'] handling).
Map<String, Object?> arcaRowsToManifest(
    List<Object?> meta, List<List<Object?>> layers) {
  final extra = _obj(meta[ZxMetaSchema.mExtra]);
  final path = meta[ZxMetaSchema.mPath] as String? ?? '';
  final visible = [
    for (final l in layers)
      if (!_obj(l[ZxMetaSchema.lAttrs]).containsKey(r'$sidecar')) l
  ]..sort((a, b) => (a[1] as int).compareTo(b[1] as int));
  final tags = meta[ZxMetaSchema.mTags];
  final known = <String, Object?>{
    'format': arcaManifestFormat,
    'file': path.split('/').last,
    'size': meta[ZxMetaSchema.mSize],
    'sha256': _hex(meta[ZxMetaSchema.mSha256] as Uint8List),
    'sha1': meta[ZxMetaSchema.mSha1],
    'mime': meta[ZxMetaSchema.mMime],
    'title': meta[ZxMetaSchema.mTitle],
    'description': meta[ZxMetaSchema.mDescription],
    'tags': tags == null ? null : ZxMetaDb.tagsOf(tags),
    'added': meta[ZxMetaSchema.mAdded],
    'layers': [
      for (final l in visible)
        _obj(l[ZxMetaSchema.lAttrs]).containsKey(r'$value')
            ? _obj(l[ZxMetaSchema.lAttrs])[r'$value']
            : _layerObject(l)
    ],
  };
  final order = extra[r'$order'];
  final keys = order is List
      ? [for (final k in order) '$k']
      : _canonTop(meta, extra);
  return {
    for (final k in keys) k: extra.containsKey(k) ? extra[k] : known[k],
  };
}

/// The manifest text of the rows, as arca writes it.
String arcaRowsToManifestText(List<Object?> meta, List<List<Object?>> layers) {
  final extra = _obj(meta[ZxMetaSchema.mExtra]);
  final raw = extra[r'$raw'];
  if (raw is String) {
    // the kept text, while it still says what the rows say
    final withoutRaw = [...meta];
    final e2 = {...extra}..remove(r'$raw');
    withoutRaw[ZxMetaSchema.mExtra] = e2.isEmpty ? null : jsonEncode(e2);
    try {
      final now = jsonEncode(arcaRowsToManifest(withoutRaw, layers));
      final then = jsonEncode(jsonDecode(raw));
      if (now == then) return raw;
    } on FormatException {
      // fall through
    }
    return arcaEncodeManifest(arcaRowsToManifest(withoutRaw, layers));
  }
  return arcaEncodeManifest(arcaRowsToManifest(meta, layers));
}

// ---------------------------------------------------------------------------
// import

class ArcaImportReport {
  int manifests = 0;
  int layers = 0;
  int layerTexts = 0;
  int sidecarSubtitles = 0;
  int previews = 0;
  int filesAdded = 0;
  final List<String> warnings = [];
  @override
  String toString() => '$manifests manifests, $layers layers '
      '($layerTexts texts, $sidecarSubtitles unlisted subtitles), '
      '$previews previews, $filesAdded files added'
      '${warnings.isEmpty ? '' : ', ${warnings.length} warnings'}';
}

bool _hidden(String rel) => rel.split('/').any((s) => s.startsWith('.'));

String _readText(File f, Map<String, Object?> attrs) {
  final b = f.readAsBytesSync();
  try {
    return utf8.decode(b);
  } on FormatException {
    attrs[r'$encoding'] = 'latin1';
    return latin1.decode(b);
  }
}

/// Imports the arca sidecars under [dir] into the metadata tables of
/// [db] (a write transaction). Archive paths are the paths under [dir],
/// with [prefix] ('' or 'folder/') in front. [previewsDirs] are searched
/// for `<sha256>.jpg` and `<sha256>.gif` (default: [dir]/previews). With
/// [addFile], every described file that exists is handed over (archive
/// path, file path) to be added to the archive; with [sidecarsToArchive]
/// the subtitle files are handed over too and their layers get a
/// content_ref.
ArcaImportReport arcaImport(ZxMetaDb db, String dir,
    {String prefix = '',
    List<String>? previewsDirs,
    void Function(String archivePath, String filePath)? addFile,
    bool sidecarsToArchive = false,
    bool previewsAsBlobs = true}) {
  final report = ArcaImportReport();
  final root = Directory(dir).absolute.path.replaceAll('\\', '/');
  final base = root.endsWith('/') ? root : '$root/';
  final pdirs = previewsDirs ?? ['${base}previews'];
  final manifests = <String>[];
  final namesIn = <String, List<String>>{};
  for (final e in Directory(root).listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final p = e.path.replaceAll('\\', '/');
    final rel = p.substring(base.length);
    if (_hidden(rel)) continue;
    if (rel.startsWith('previews/')) continue;
    final d = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
    (namesIn[d] ??= []).add(rel.split('/').last);
    if (rel.endsWith(arcaManifestSuffix)) manifests.add(rel);
  }
  manifests.sort();
  db.batch(() {
    for (final rel in manifests) {
      final text = File('$base$rel').readAsStringSync();
      Map<String, Object?> m;
      try {
        final v = jsonDecode(text);
        if (v is! Map) throw const FormatException('not an object');
        m = v.cast<String, Object?>();
      } on FormatException catch (e) {
        report.warnings.add('$rel: not a manifest (${e.message})');
        continue;
      }
      final d = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
      final dirPrefix = d.isEmpty ? '' : '$d/';
      final file = m['file'];
      if (file is! String || file.isEmpty || file.contains('/')) {
        report.warnings.add('$rel: no file name');
        continue;
      }
      final path = '$prefix$dirPrefix$file';
      final rows = arcaManifestToRows(m, path, original: text);
      if (rows == null) {
        report.warnings.add('$rel: no valid sha256');
        continue;
      }
      final sha = rows.meta[0] as Uint8List;
      db.deletePrefix(ZxMetaSchema.layers, [sha]);
      db.put(ZxMetaSchema.meta, rows.meta);
      report.manifests++;
      final listed = <String>{};
      for (final l in rows.layers) {
        final f = l[ZxMetaSchema.lFile];
        if (f is String && !f.contains('/')) {
          listed.add(f);
          final sf = File('$base$dirPrefix$f');
          if (sf.existsSync()) {
            final attrs = _obj(l[ZxMetaSchema.lAttrs]);
            l[ZxMetaSchema.lContent] = _readText(sf, attrs);
            l[ZxMetaSchema.lAttrs] = attrs.isEmpty ? null : jsonEncode(attrs);
            report.layerTexts++;
            if (sidecarsToArchive && addFile != null) {
              l[ZxMetaSchema.lContentRef] = '$prefix$dirPrefix$f';
              addFile('$prefix$dirPrefix$f', sf.path);
            }
          }
        }
        db.put(ZxMetaSchema.layers, l);
        report.layers++;
      }
      // subtitles beside the file that the manifest does not list
      final names = namesIn[d] ?? const [];
      final b = arcaBaseName(file, names);
      final pat = RegExp('^${RegExp.escape(b)}'
          r'(?:\.([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)?))?\.srt$');
      var n = rows.layers.length;
      for (final name in [...names]..sort()) {
        final mm = pat.firstMatch(name);
        if (mm == null || listed.contains(name)) continue;
        final attrs = <String, Object?>{r'$sidecar': true};
        final content = _readText(File('$base$dirPrefix$name'), attrs);
        db.put(ZxMetaSchema.layers, [
          sha, n++, 'subtitles', mm[1], null, null, null, null, name, //
          content,
          sidecarsToArchive && addFile != null ? '$prefix$dirPrefix$name' : null,
          jsonEncode(attrs),
        ]);
        if (sidecarsToArchive && addFile != null) {
          addFile('$prefix$dirPrefix$name', '$base$dirPrefix$name');
        }
        report.sidecarSubtitles++;
      }
      // previews
      final hex = _hex(sha);
      for (final pd in pdirs) {
        for (final (ext, kind, mime) in const [
          ('jpg', 'preview', 'image/jpeg'),
          ('gif', 'gif', 'image/gif'),
        ]) {
          final pf = File('$pd/$hex.$ext');
          if (!pf.existsSync()) continue;
          if (db.get(ZxMetaSchema.media, [sha, kind, 0]) != null) continue;
          final bytes = pf.readAsBytesSync();
          final size = imageSize(bytes);
          db.put(ZxMetaSchema.media, [
            sha, kind, 0, null, size?.$1, size?.$2, null, mime, //
            previewsAsBlobs ? null : 'previews/$hex.$ext',
            previewsAsBlobs ? bytes : null,
          ]);
          if (!previewsAsBlobs && addFile != null) {
            addFile('previews/$hex.$ext', pf.path);
          }
          report.previews++;
        }
      }
      if (addFile != null) {
        final ff = File('$base$dirPrefix$file');
        if (ff.existsSync()) {
          addFile(path, ff.path);
          report.filesAdded++;
        }
      }
    }
  });
  return report;
}

// ---------------------------------------------------------------------------
// export

class ArcaExportReport {
  int manifests = 0;
  int subtitles = 0;
  int previews = 0;
  final List<String> skipped = [];
  @override
  String toString() => '$manifests manifests, $subtitles subtitle files, '
      '$previews previews${skipped.isEmpty ? '' : ', ${skipped.length} skipped'}';
}

void _writeAtomic(String path, List<int> bytes) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  final name = path.split('/').last;
  final tmp = File('${f.parent.path}/.$name.tmp');
  tmp.writeAsBytesSync(bytes, flush: true);
  tmp.renameSync(path);
}

/// Writes the manifests, subtitle files and (with [previewsDir], default
/// [dir]/previews; null to skip with [previews] false) previews of the
/// metadata tables under [dir], next to where the files are (their
/// zx_meta.path, or their path in [archive] for rows without one). A row
/// whose path starts with [prefix] loses it. [readRef] reads an archive
/// entry for layers and media that are stored as content_ref only.
ArcaExportReport arcaExport(ZxMetaDb db, String dir,
    {ZxArchiveView? archive,
    String prefix = '',
    bool previews = true,
    String? previewsDir,
    Uint8List? Function(String archivePath)? readRef}) {
  final report = ArcaExportReport();
  final root = Directory(dir).absolute.path.replaceAll('\\', '/');
  final base = root.endsWith('/') ? root : '$root/';
  final rows = db.scan(ZxMetaSchema.meta).toList();
  // targets first: the stem clash rule needs every name of a folder
  final targets = <(List<Object?>, String)>[];
  final namesIn = <String, Set<String>>{};
  for (final m in rows) {
    var path = m[ZxMetaSchema.mPath] as String?;
    if (path == null && archive != null) {
      final v = archive.current;
      final hits = v.findBySha256(m[0] as Uint8List);
      if (hits.isNotEmpty) path = v.entries[hits.first].path;
    }
    if (path == null || path.isEmpty) {
      report.skipped.add(_hex(m[0] as Uint8List));
      continue;
    }
    if (prefix.isNotEmpty && path.startsWith(prefix)) {
      path = path.substring(prefix.length);
    }
    final row = [...m]..[ZxMetaSchema.mPath] = path;
    targets.add((row, path));
    final d = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
    (namesIn[d] ??= {}).add(path.split('/').last);
  }
  for (final e in namesIn.entries) {
    final folder = Directory('$base${e.key}');
    if (folder.existsSync()) {
      for (final f in folder.listSync(followLinks: false)) {
        if (f is File) e.value.add(f.path.replaceAll('\\', '/').split('/').last);
      }
    }
  }
  final pdir = previewsDir ?? '${base}previews';
  for (final (m, path) in targets) {
    final sha = m[0] as Uint8List;
    final layers = db.layersOf(sha);
    final d = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
    final dirPrefix = d.isEmpty ? '' : '$d/';
    final name = path.split('/').last;
    final b = arcaBaseName(name, namesIn[d] ?? const {});
    _writeAtomic('$base$dirPrefix$b$arcaManifestSuffix',
        utf8.encode(arcaRowsToManifestText(m, layers)));
    report.manifests++;
    for (final l in layers) {
      final f = l[ZxMetaSchema.lFile];
      if (f is! String || f.isEmpty || f.contains('/')) continue;
      final attrs = _obj(l[ZxMetaSchema.lAttrs]);
      List<int>? bytes;
      final c = l[ZxMetaSchema.lContent];
      if (c is String) {
        bytes = attrs[r'$encoding'] == 'latin1' ? latin1.encode(c) : utf8.encode(c);
      } else if (l[ZxMetaSchema.lContentRef] is String && readRef != null) {
        bytes = readRef(l[ZxMetaSchema.lContentRef] as String);
      }
      if (bytes == null) continue;
      _writeAtomic('$base$dirPrefix$f', bytes);
      report.subtitles++;
    }
    if (!previews) continue;
    final hex = _hex(sha);
    for (final r in db.mediaOf(sha)) {
      final kind = r[ZxMetaSchema.dKind];
      final ext = kind == 'preview'
          ? 'jpg'
          : kind == 'gif'
              ? 'gif'
              : null;
      if (ext == null || r[ZxMetaSchema.dN] != 0) continue;
      var data = r[ZxMetaSchema.dData] as Uint8List?;
      final ref = r[ZxMetaSchema.dContentRef];
      if (data == null && ref is String && readRef != null) data = readRef(ref);
      if (data == null) continue;
      _writeAtomic('$pdir/$hex.$ext', data);
      report.previews++;
    }
  }
  return report;
}
