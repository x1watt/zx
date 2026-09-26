// Benchmark driver for docs/performance.md: runs one API operation, so that
// an outer `/usr/bin/time` measures its wall time, CPU and peak RSS.
//
//   dart compile exe tool/bench.dart -o /tmp/zxbench
//   /tmp/zxbench a <archive.7z> <dir> [x=5] [0=PPMd] [mt=1] ...
//   /tmp/zxbench x <archive.7z> <outdir>
//   /tmp/zxbench t <archive.7z>
//   /tmp/zxbench xz <file> <out.xz> <level> <threads> [s=4m] ...
//   /tmp/zxbench unxz <file.xz> <out>
//
// `a` takes -m switch bodies without the "-m" prefix. tool/benchmark.sh
// runs the whole comparison with /usr/bin/7z.

import 'dart:io';

import 'package:zx/zx.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: see the comment at the top of tool/bench.dart');
    exit(2);
  }
  final sw = Stopwatch()..start();
  switch (args[0]) {
    case 'a':
      final f = File(args[1]);
      if (f.existsSync()) f.deleteSync();
      final r = await SevenZipArchive(args[1]).add(
          [SevenZipSource(args[2], storedAs: '')],
          options: SevenZipOptions(switches: args.sublist(3)));
      print(r);
    case 'x':
      print(await SevenZipArchive(args[1]).extract(args[2]));
    case 't':
      print(await SevenZipArchive(args[1]).test());
    case 'xz':
      await xzCompressFile(args[1], args[2],
          level: int.parse(args[3]),
          threads: int.parse(args[4]),
          switches: args.sublist(5));
      print(File(args[2]).lengthSync());
    case 'unxz':
      await xzDecompressFile(args[1], args[2]);
    default:
      stderr.writeln('unknown command ${args[0]}');
      exit(2);
  }
  stderr.writeln('${sw.elapsedMilliseconds} ms');
}
