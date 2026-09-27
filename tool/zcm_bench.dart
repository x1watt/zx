// Benchmark of the zcm codec: ratio and speed per level on a set of files.
//
//   dart compile exe tool/zcm_bench.dart -o /tmp/zcm_bench
//   /tmp/zcm_bench [-l 1,2,3] [-m MiB] [-nodec] [-seg BYTES] [-par THREADS]
//       [-lstm cells,layers,horizon] [-nodict] [-nodetect] file...
//
// Prints, per file and level: packed size, encode and decode KB/s (input
// KB per second of wall time) and whether the round trip matched.

import 'dart:io';
import 'dart:typed_data';

import 'package:zx/src/codec/zcm/zcm.dart';
import 'package:zx/src/codec/zcm/zcm_parallel.dart';

Future<void> main(List<String> args) async {
  var levels = [1, 2, 3, 4, 5];
  var mem = 0;
  var dec = true;
  var seg = 0;
  var par = 0;
  var dict = true;
  var detect = true;
  List<int>? lstm;
  final files = <String>[];

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '-l') {
      levels = args[++i].split(',').map(int.parse).toList();
    } else if (a == '-m') {
      mem = int.parse(args[++i]);
    } else if (a == '-par') {
      par = int.parse(args[++i]);
    } else if (a == '-seg') {
      seg = int.parse(args[++i]);
    } else if (a == '-lstm') {
      lstm = args[++i].split(',').map(int.parse).toList();
    } else if (a == '-nodec') {
      dec = false;
    } else if (a == '-nodict') {
      dict = false;
    } else if (a == '-nodetect') {
      detect = false;
    } else {
      files.add(a);
    }
  }
  for (final level in levels) {
    var totalIn = 0, totalOut = 0;
    var encUs = 0, decUs = 0;
    for (final f in files) {
      final data = File(f).readAsBytesSync();
      final opts = ZcmOptions(
          level: level,
          memoryMiB: mem,
          segmentSize: seg,
          lstm: lstm != null,
          lstmCells: lstm?[0] ?? 32,
          lstmLayers: lstm?[1] ?? 1,
          lstmHorizon: lstm?[2] ?? 10,
          dictionary: dict,
          detect: detect);
      final sw = Stopwatch()..start();
      final packed = par > 0
          ? await zcmCompressParallel(data, opts, threads: par)
          : zcmCompressBytes(data, opts);
      final te = sw.elapsedMicroseconds;
      var ok = 'nodec';
      var td = 0;
      if (dec) {
        sw.reset();
        final back = par > 0
            ? await zcmDecompressParallel(packed, threads: par)
            : zcmDecompressBytes(packed);
        td = sw.elapsedMicroseconds;
        ok = _same(back, data) ? 'ok' : 'MISMATCH';
      }
      totalIn += data.length;
      totalOut += packed.length;
      encUs += te;
      decUs += td;
      final name = f.split('/').last;
      print('L$level ${name.padRight(12)} ${data.length.toString().padLeft(9)}'
          ' -> ${packed.length.toString().padLeft(8)}'
          '  enc ${_kbs(data.length, te)} KB/s'
          '  dec ${dec ? _kbs(data.length, td) : '-'} KB/s  $ok');
    }
    print('L$level total ${totalIn.toString().padLeft(9)} -> '
        '${totalOut.toString().padLeft(8)}  enc ${_kbs(totalIn, encUs)} KB/s'
        '  dec ${dec ? _kbs(totalIn, decUs) : '-'} KB/s');
  }
  print('peak RSS ${ProcessInfo.maxRss >> 20} MiB');
}

String _kbs(int bytes, int us) =>
    us == 0 ? '-' : (bytes / 1024 / (us / 1e6)).toStringAsFixed(0);

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
