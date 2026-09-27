// Shared helpers of the LZO, LZ4, zstd and zlib tests: the reference tools
// (system PATH first, then ref/tools/root/usr/bin, where `apt-get download`
// plus `dpkg-deb -x` put them) and test data.

import 'dart:io';
import 'dart:typed_data';

/// Path of the reference tool [name], or null when it is not installed.
String? findTool(String name) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  final local = File('ref/tools/root/usr/bin/$name');
  if (local.existsSync()) return local.absolute.path;
  return null;
}

/// Runs [tool] with [args] and returns its stdout as bytes; fails the test
/// on a non-zero exit code.
Uint8List runTool(String tool, List<String> args, {Uint8List? stdinData}) {
  final r = Process.runSync(tool, args, stdoutEncoding: null);
  if (r.exitCode != 0) {
    throw StateError('$tool ${args.join(' ')} failed: ${r.stderr}');
  }
  return Uint8List.fromList(r.stdout as List<int>);
}

/// Compressible test data: words, runs, small numbers and some random
/// bytes, deterministic for a [seed].
Uint8List genData(int n, int seed, {int randomPercent = 5}) {
  var st = seed;
  int next() {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    return st >> 8;
  }

  const words = [
    'firmware ',
    'rootfs ',
    'kernel ',
    'volume ',
    'inode ',
    'squashfs\n',
    'block ',
    'the ',
    'of ',
    'and ',
    'zstd ',
    'lz4 ',
    'lzo ',
    '0x1234 ',
  ];
  final out = Uint8List(n);
  var p = 0;
  while (p < n) {
    final r = next() % 100;
    if (r < randomPercent) {
      final k = 1 + next() % 64;
      for (var i = 0; i < k && p < n; i++) {
        out[p++] = next() & 0xFF;
      }
    } else if (r < randomPercent + 3) {
      final k = 1 + next() % 300;
      final b = next() & 0xFF;
      for (var i = 0; i < k && p < n; i++) {
        out[p++] = b;
      }
    } else if (r < randomPercent + 8 && p > 70000) {
      // a long far match
      final k = 100 + next() % 5000;
      final from = next() % (p - 65536);
      for (var i = 0; i < k && p < n; i++) {
        out[p++] = out[from + i];
      }
    } else {
      final w = words[next() % words.length];
      for (var i = 0; i < w.length && p < n; i++) {
        out[p++] = w.codeUnitAt(i);
      }
    }
  }
  return out;
}

/// Pseudo random bytes (incompressible).
Uint8List randomData(int n, int seed) {
  var st = seed;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    st = (st * 6364136223846793005 + 1442695040888963407);
    out[i] = (st >> 33) & 0xFF;
  }
  return out;
}

/// A temporary directory removed at exit of the test file.
Directory tempDir(String prefix) =>
    Directory.systemTemp.createTempSync('zx_${prefix}_');

bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
