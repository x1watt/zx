// Part sets (zx extension, docs/architecture.md section 21): one file cut
// into parts of a fixed size, for hosts that limit the size of a file
// (GitHub: 100 MB) but serve byte ranges, plus a manifest NAME.parts that
// lists them. Unlike the volumes of a .zx archive (written as volumes,
// each with its own header), a part set is a plain cut of any file: a
// zxdb database, an archive with later generations, anything read by
// offset. Readers see the parts as one read-only stream
// ([PartSetInStream]); the parts are opened when first touched and only a
// few stay open, so a set of many parts costs no more than a few files.
//
// The manifest (JSON, UTF-8):
//   {"zxParts": 1, "name": "NAME", "size": TOTAL, "partSize": P,
//    "parts": [{"file": "NAME.001", "size": P, "sha256": "..."}, ...]}
// Every part but the last has exactly partSize bytes. An optional
// "warm": [[OFFSET, LENGTH], ...] lists byte ranges of the whole file that
// readers almost always need first (the warm set: the upper levels of a
// database's trees, recorded by `zx parts warm`); the web engine fetches
// them in parallel when it opens the set. A part's "file" is
// a path relative to the manifest (or a URL, relative or absolute, when
// the set is read over HTTP), so parts may sit in other folders, or on
// other sites of the same origin.

import 'dart:convert';
import 'dart:typed_data';

import '../crypto/sha256.dart';
import '../host/io.dart';
import 'streams.dart';

/// The name of the manifest of the set of [name].
String partManifestName(String name) => '$name${ZxPartManifest.suffix}';

class ZxPart {
  /// Path or URL of the part, relative to the manifest.
  final String file;
  final int size;

  /// Lower case hex SHA-256 of the part, or null when not recorded.
  final String? sha256;
  const ZxPart(this.file, this.size, [this.sha256]);

  Map<String, Object?> toJson() =>
      {'file': file, 'size': size, if (sha256 != null) 'sha256': sha256};
}

/// The list of the parts of one file (see the file comment).
class ZxPartManifest {
  static const String suffix = '.parts';
  static const int version = 1;

  /// The name of the whole file.
  final String name;
  final int size;
  final int partSize;
  final List<ZxPart> parts;

  /// The warm set: (offset, length) ranges of the whole file, sorted.
  final List<(int, int)> warm;

  ZxPartManifest(this.name, this.size, this.partSize, this.parts,
      {this.warm = const []}) {
    if (partSize <= 0) throw _bad('partSize must be positive');
    var total = 0;
    for (var i = 0; i < parts.length; i++) {
      final s = parts[i].size;
      final last = i == parts.length - 1;
      if (last ? (s <= 0 || s > partSize) : s != partSize) {
        throw _bad('part ${i + 1} has $s bytes; every part but the last '
            'must have $partSize, the last at most that');
      }
      total += s;
    }
    if (total != size) {
      throw _bad('the parts add up to $total bytes, not $size');
    }
    for (final (o, n) in warm) {
      if (o < 0 || n <= 0 || o + n > size) {
        throw _bad('warm range $o+$n is outside the file');
      }
    }
  }

  /// The same manifest with another warm set.
  ZxPartManifest withWarm(List<(int, int)> w) =>
      ZxPartManifest(name, size, partSize, parts, warm: w);

  int get warmBytes => warm.fold(0, (a, r) => a + r.$2);

  /// The warm set as requests per part: (part index, offset in the part,
  /// length), a range that crosses a part boundary cut in two.
  List<(int, int, int)> warmRequests() {
    final out = <(int, int, int)>[];
    for (final (o, n) in warm) {
      var at = o, left = n;
      while (left > 0) {
        final i = at ~/ partSize;
        final inPart = at - i * partSize;
        final room = parts[i].size - inPart;
        final k = left < room ? left : room;
        out.add((i, inPart, k));
        at += k;
        left -= k;
      }
    }
    return out;
  }

  static SevenZipException _bad(String m) =>
      SevenZipException('bad part manifest: $m', SevenZipError.data);

  static ZxPartManifest parse(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException catch (e) {
      throw _bad(e.message);
    }
    if (j is! Map || j['zxParts'] is! int) throw _bad('not a part manifest');
    if ((j['zxParts'] as int) > version) {
      throw _bad('version ${j['zxParts']} is newer than this zx knows');
    }
    try {
      final parts = [
        for (final p in j['parts'] as List)
          ZxPart((p as Map)['file'] as String, p['size'] as int,
              p['sha256'] as String?),
      ];
      final warm = [
        for (final r in (j['warm'] as List?) ?? const [])
          ((r as List)[0] as int, r[1] as int),
      ];
      return ZxPartManifest(
          j['name'] as String, j['size'] as int, j['partSize'] as int, parts,
          warm: warm);
    } on TypeError {
      throw _bad('a field is missing or of the wrong type');
    }
  }

  String toJsonText() => const JsonEncoder.withIndent(' ').convert({
        'zxParts': version,
        'name': name,
        'size': size,
        'partSize': partSize,
        'parts': [for (final p in parts) p.toJson()],
        if (warm.isNotEmpty)
          'warm': [
            for (final (o, n) in warm) [o, n]
          ],
      });
}

/// One read-only stream over the parts of a [ZxPartManifest]. [open] gives
/// the stream of part i (0 based) when it is first read; at most [maxOpen]
/// stay open, the least recently used closed first (each keeps its own
/// buffer or block cache).
class PartSetInStream implements ClosableInStream {
  final ZxPartManifest manifest;
  final ClosableInStream Function(int index) open;
  final int maxOpen;

  // index -> stream, least recently used first
  final Map<int, ClosableInStream> _open = {};

  @override
  int position = 0;

  /// Parts opened so far (a part opened again after it was closed counts
  /// again): how far apart the reads of a workload fall.
  int opens = 0;

  PartSetInStream(this.manifest, this.open, {this.maxOpen = 4});

  /// The stream of part [index] (0 based), opened when it is not open; it
  /// counts as used now.
  ClosableInStream partStream(int index) => _part(index);

  @override
  int get length => manifest.size;

  ClosableInStream _part(int i) {
    var s = _open.remove(i);
    if (s == null) {
      s = open(i);
      opens++;
      if (s.length != manifest.parts[i].size) {
        s.close();
        throw SevenZipException(
            'part ${i + 1} (${manifest.parts[i].file}) has ${s.length} bytes, '
            'the manifest says ${manifest.parts[i].size}',
            SevenZipError.data);
      }
      while (_open.length >= maxOpen) {
        final k = _open.keys.first;
        _open.remove(k)!.close();
      }
    }
    _open[i] = s;
    return s;
  }

  @override
  int read(Uint8List buf, int off, int len) {
    if (len <= 0 || position >= manifest.size) return 0;
    final p = manifest.partSize;
    final i = position ~/ p;
    final inPart = position - i * p;
    final s = _part(i);
    final room = manifest.parts[i].size - inPart;
    s.position = inPart;
    final n = s.read(buf, off, len < room ? len : room);
    if (n > 0) position += n;
    return n;
  }

  @override
  void close() {
    for (final s in _open.values) {
      s.close();
    }
    _open.clear();
  }
}

/// The manifest that stands for [path], natively: [path] itself when it
/// names a manifest, else `path.parts` when [path] is missing and that
/// manifest exists; null otherwise (a plain file).
String? partManifestPathFor(String path) {
  if (path.endsWith(ZxPartManifest.suffix) && File(path).existsSync()) {
    return path;
  }
  final m = partManifestName(path);
  if (!File(path).existsSync() && File(m).existsSync()) return m;
  return null;
}

/// Reads the manifest at [manifestPath] (native files).
ZxPartManifest readPartManifest(String manifestPath) =>
    ZxPartManifest.parse(File(manifestPath).readAsStringSync());

String _dirOf(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  final j = path.lastIndexOf('/');
  final k = i > j ? i : j;
  return k < 0 ? '.' : path.substring(0, k);
}

/// The local path of [part] of the manifest at [manifestPath].
String partPath(String manifestPath, ZxPart part) => part.file.startsWith('/')
    ? part.file
    : '${_dirOf(manifestPath)}/${part.file}';

/// Opens the set of the manifest at [manifestPath] (native files).
PartSetInStream openPartSet(String manifestPath, {int maxOpen = 4}) {
  final m = readPartManifest(manifestPath);
  return PartSetInStream(
      m, (i) => FileInStream.open(partPath(manifestPath, m.parts[i])),
      maxOpen: maxOpen);
}

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Cuts [path] into parts of [partSize] bytes in [outDir] (default: the
/// file's folder), named NAME.001, NAME.002 and so on (three digits at
/// least), and writes the manifest NAME.parts next to them. Reads and
/// writes 1 MiB at a time.
ZxPartManifest zxSplitFile(String path, int partSize,
    {String? outDir, void Function(int done, int total)? progress}) {
  if (partSize <= 0) {
    throw const SevenZipException(
        'the part size must be positive', SevenZipError.unsupported);
  }
  final name = path.substring(
      (path.lastIndexOf('/') > path.lastIndexOf(Platform.pathSeparator)
              ? path.lastIndexOf('/')
              : path.lastIndexOf(Platform.pathSeparator)) +
          1);
  final dir = outDir ?? _dirOf(path);
  final input = File(path).openSync();
  final total = input.lengthSync();
  final count = total == 0 ? 1 : (total + partSize - 1) ~/ partSize;
  final digits = count.toString().length < 3 ? 3 : count.toString().length;
  final parts = <ZxPart>[];
  final buf = Uint8List(1 << 20);
  var done = 0;
  try {
    for (var i = 0; i < count; i++) {
      final file = '$name.${(i + 1).toString().padLeft(digits, '0')}';
      final size = i == count - 1 ? total - i * partSize : partSize;
      final out = File('$dir/$file').openSync(mode: FileMode.write);
      final h = Sha256();
      try {
        var left = size;
        while (left > 0) {
          final n =
              input.readIntoSync(buf, 0, left < buf.length ? left : buf.length);
          if (n <= 0) {
            throw SevenZipException('$path got shorter', SevenZipError.io);
          }
          out.writeFromSync(buf, 0, n);
          h.update(buf, 0, n);
          left -= n;
          done += n;
          progress?.call(done, total);
        }
      } finally {
        out.closeSync();
      }
      parts.add(ZxPart(file, size, _hex(h.digest())));
    }
  } finally {
    input.closeSync();
  }
  final m = ZxPartManifest(name, total, partSize, parts);
  File('$dir/${partManifestName(name)}').writeAsStringSync(m.toJsonText());
  return m;
}

/// Checks every part of the manifest at [manifestPath]: present, of its
/// size, and of its SHA-256 when recorded. Returns the problems (empty:
/// the set is whole).
List<String> zxCheckParts(String manifestPath) {
  final m = readPartManifest(manifestPath);
  final problems = <String>[];
  final buf = Uint8List(1 << 20);
  for (final p in m.parts) {
    final f = File(partPath(manifestPath, p));
    if (!f.existsSync()) {
      problems.add('${p.file}: missing');
      continue;
    }
    final raf = f.openSync();
    try {
      final len = raf.lengthSync();
      if (len != p.size) {
        problems.add('${p.file}: $len bytes, the manifest says ${p.size}');
        continue;
      }
      if (p.sha256 == null) continue;
      final h = Sha256();
      int n;
      while ((n = raf.readIntoSync(buf)) > 0) {
        h.update(buf, 0, n);
      }
      if (_hex(h.digest()) != p.sha256) {
        problems.add('${p.file}: SHA-256 does not match');
      }
    } finally {
      raf.closeSync();
    }
  }
  return problems;
}

/// Writes the whole file of the manifest at [manifestPath] to [outPath].
void zxJoinParts(String manifestPath, String outPath) {
  final s = openPartSet(manifestPath, maxOpen: 1);
  final out = File(outPath).openSync(mode: FileMode.write);
  final buf = Uint8List(1 << 20);
  try {
    int n;
    while ((n = s.read(buf, 0, buf.length)) > 0) {
      out.writeFromSync(buf, 0, n);
    }
  } finally {
    out.closeSync();
    s.close();
  }
}
