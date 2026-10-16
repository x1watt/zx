// The `zx parts` command (zx extension, docs/cli.md, part sets): cuts a
// file into parts of a fixed size with a manifest, so it can be hosted
// where files are limited in size (GitHub: 100 MB) and still be read in
// place, by offset (io/part_set.dart).
//
//   zx parts split [-size=95m] [-o DIR] FILE
//   zx parts check MANIFEST
//   zx parts join MANIFEST OUT
//   zx parts list MANIFEST
//   zx parts warm MANIFEST -sql=SQL ... [-sqlfile=F] [-min=2] [-max=8m] [-block=64k]

import '../db/warm_set.dart';
import '../host/io.dart';
import '../io/part_set.dart';
import '../io/streams.dart' show SevenZipException;
import 'globals.dart';
import 'std_stream.dart';

const String zxPartsUsage = '''
Usage: zx parts split [-size=SIZE] [-o DIR] FILE
       zx parts check MANIFEST
       zx parts join MANIFEST OUT
       zx parts list MANIFEST
       zx parts warm MANIFEST -sql=SQL [-sql=SQL ...] [-sqlfile=FILE]
                     [-min=2] [-max=8m] [-block=64k]
Cuts FILE into parts of SIZE bytes (default 95m; suffixes k, m, g) named
FILE.001, FILE.002, ... with a manifest FILE.parts listing their sizes and
SHA-256 sums. zx reads a set in place: "zx sql FILE" opens it (read only)
when FILE is missing, "zx l FILE.parts" lists it, and the web version
opens the manifest's URL, reading only the parts and ranges a query
needs. check verifies the parts, join writes the whole file again, list
shows the parts. warm records the warm set of a database: the blocks that
opening it and at least -min of the given queries read (run cold, one by
one), up to -max bytes; it is written into the manifest, and the web
version fetches it in parallel when it opens the set.
''';

int? _size(String s) {
  final m = RegExp(r'^(\d+)([kmgKMG]?)$').firstMatch(s);
  if (m == null) return null;
  final n = int.parse(m[1]!);
  return switch (m[2]!.toLowerCase()) {
    'k' => n << 10,
    'm' => n << 20,
    'g' => n << 30,
    _ => n,
  };
}

/// Runs `zx parts` with [args] (after the word "parts"); returns the
/// exit code.
int runPartsCommand(List<String> args, CliIo io) {
  void out(String s) => gStdOut.write(s);
  void err(String s) {
    gStdOut.flush();
    gStdErr.write(s);
  }

  if (args.isEmpty || args.first == '-h' || args.first == '-help') {
    out(zxPartsUsage);
    return args.isEmpty ? 1 : 0;
  }
  final sub = args.first;
  var size = 95 << 20;
  var block = 64 << 10, minHits = 2, maxBytes = 8 << 20;
  final sqls = <String>[];
  String? outDir;
  final pos = <String>[];
  for (var i = 1; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('-size=')) {
      final n = _size(a.substring(6));
      if (n == null || n <= 0) {
        err('zx parts: Error: bad size: $a\n');
        return 1;
      }
      size = n;
    } else if (a.startsWith('-sql=')) {
      sqls.add(a.substring(5));
    } else if (a.startsWith('-sqlfile=')) {
      sqls.addAll(File(a.substring(9))
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('--')));
    } else if (a.startsWith('-min=') && int.tryParse(a.substring(5)) != null) {
      minHits = int.parse(a.substring(5));
    } else if (a.startsWith('-max=') && _size(a.substring(5)) != null) {
      maxBytes = _size(a.substring(5))!;
    } else if (a.startsWith('-block=') && _size(a.substring(7)) != null) {
      block = _size(a.substring(7))!;
    } else if (a == '-o' && i + 1 < args.length) {
      outDir = args[++i];
    } else if (a.startsWith('-') && a.length > 1) {
      err('zx parts: Error: unknown option: $a\n$zxPartsUsage');
      return 1;
    } else {
      pos.add(a);
    }
  }
  try {
    switch (sub) {
      case 'split' when pos.length == 1:
        final m = zxSplitFile(pos[0], size, outDir: outDir);
        out('${m.parts.length} parts of at most ${m.partSize} bytes, '
            '${m.size} bytes in all; manifest ${partManifestName(m.name)}\n');
        return 0;
      case 'check' when pos.length == 1:
        final problems = zxCheckParts(pos[0]);
        if (problems.isEmpty) {
          out('Everything is Ok\n');
          return 0;
        }
        for (final p in problems) {
          err('$p\n');
        }
        return 2;
      case 'join' when pos.length == 2:
        zxJoinParts(pos[0], pos[1]);
        out('${readPartManifest(pos[0]).size} bytes written to ${pos[1]}\n');
        return 0;
      case 'warm' when pos.length == 1 && sqls.isNotEmpty:
        final r = zxRecordWarmSet(pos[0], sqls,
            blockSize: block, minHits: minHits, maxBytes: maxBytes);
        File(pos[0]).writeAsStringSync(r.manifest.toJsonText());
        out('warm set: ${r.manifest.warm.length} ranges, '
            '${r.manifest.warmBytes} bytes (${r.openBlocks} blocks to open, '
            '${r.sharedBlocks} shared by at least $minHits queries'
            '${r.leftOut > 0 ? ', ${r.leftOut} left out over -max' : ''}); '
            'written to ${pos[0]}\n');
        return 0;
      case 'list' when pos.length == 1:
        final m = readPartManifest(pos[0]);
        out('${m.name}: ${m.size} bytes in ${m.parts.length} parts of '
            '${m.partSize}\n');
        for (final p in m.parts) {
          out('${p.size.toString().padLeft(12)}  ${p.sha256 ?? '-'}  ${p.file}\n');
        }
        return 0;
    }
  } on SevenZipException catch (e) {
    err('zx parts: Error: ${e.message}\n');
    return 2;
  } on Exception catch (e) {
    err('zx parts: Error: $e\n');
    return 2;
  }
  err(zxPartsUsage);
  return 1;
}
