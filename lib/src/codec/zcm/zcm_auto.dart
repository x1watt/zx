// zcm: automatic settings from the machine, the input and a time budget.
//
// The choice only picks ZcmOptions (and a thread count for
// zcmCompressParallel); everything that shapes the model is stored in the
// stream, so the output is deterministic once the options are chosen and
// any machine decodes it.
//
// Rules (see zcmAutoSelect):
//   * usable memory = min(75% of the available memory, available - 1.5
//     GiB), at least 64 MiB; the budget of every worker plus the input and
//     output buffers must fit in it;
//   * without a time budget: level 4 ("normal"), one thread (best ratio);
//   * with a time budget: the strongest level (9 with the LSTM counts as
//     the strongest) whose estimated time fits, with as few threads as
//     possible (segments cost ratio), up to half the cores;
//   * the speed of each level comes from measurements on this machine type
//     (docs/performance.md), scaled by a calibration run when one is made.

import 'dart:io';
import 'dart:typed_data';

import 'zcm.dart';

/// What the machine offers.
final class ZcmMachine {
  /// Memory the system can give without swapping (MemAvailable on Linux).
  final int availableBytes;

  /// Logical processors.
  final int cores;

  /// Whether [availableBytes] was measured (false: a default).
  final bool measured;

  const ZcmMachine(
      {required this.availableBytes, required this.cores, this.measured = true});

  @override
  String toString() => 'ZcmMachine(available: ${availableBytes >> 20} MiB, '
      'cores: $cores${measured ? '' : ', default'})';
}

/// Reads the machine: /proc/meminfo on Linux and Android; elsewhere a safe
/// default (dart:io has no memory query): 2 GiB on desktops, 1 GiB on
/// phones.
ZcmMachine zcmProbeMachine() {
  final cores = Platform.numberOfProcessors;
  if (Platform.isLinux || Platform.isAndroid) {
    try {
      final avail = zcmParseMemAvailable(
          File('/proc/meminfo').readAsStringSync());
      if (avail != null) {
        return ZcmMachine(availableBytes: avail, cores: cores);
      }
    } on FileSystemException {
      // fall through to the default
    }
  }
  final def = (Platform.isAndroid || Platform.isIOS) ? 1 << 30 : 2 << 30;
  return ZcmMachine(availableBytes: def, cores: cores, measured: false);
}

/// MemAvailable (bytes) from the text of /proc/meminfo, or null.
int? zcmParseMemAvailable(String meminfo) {
  for (final line in meminfo.split('\n')) {
    if (line.startsWith('MemAvailable:')) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final kb = int.tryParse(parts[1]);
        if (kb != null) return kb * 1024;
      }
    }
  }
  return null;
}

/// Memory the codec may use on [m]: 75% of the available memory, and
/// never more than the available memory minus 1.5 GiB (at least 64 MiB).
int zcmUsableBytes(ZcmMachine m) {
  var u = m.availableBytes * 3 ~/ 4;
  final cap = m.availableBytes - (3 << 29);
  if (cap < u) u = cap;
  if (u < (64 << 20)) u = 64 << 20;
  return u;
}

/// Encoding speed per level in KB/s (index 10: level 9 with the LSTM),
/// measured with tool/zcm_bench.dart (AOT) on the two corpora of
/// docs/performance.md (text, code, binaries, images and audio), Ryzen 7
/// 3700X. Decoding runs at the same speed.
const List<double> zcmNominalKBps = [
  0, 1100, 260, 150, 85, 80, 24, 9, 5, 4, 2 //
];

/// A chosen setting.
final class ZcmAutoChoice {
  final ZcmOptions options;

  /// Worker isolates for zcmCompressParallel (1: ZcmCompressor).
  final int threads;

  /// Estimated seconds to encode.
  final double estimatedSeconds;

  /// Estimated peak memory (bytes).
  final int estimatedBytes;

  /// Why this choice (for logs and the CLI).
  final String reason;

  const ZcmAutoChoice(this.options, this.threads, this.estimatedSeconds,
      this.estimatedBytes, this.reason);

  @override
  String toString() => 'ZcmAutoChoice($options, threads: $threads, '
      '~${estimatedSeconds.toStringAsFixed(1)} s, '
      '~${estimatedBytes >> 20} MiB: $reason)';
}

/// Peak memory of encoding [inputSize] bytes with [o] on [threads]
/// workers: the models, the input and output buffers, and the Dart heap
/// overhead (about a third more than the tables).
int zcmEstimateBytes(ZcmOptions o, int inputSize, int threads) {
  final mib = zcmEffectiveMemoryMiB(o, inputSize);
  final model = (mib << 20) * 4 ~/ 3;
  var lstm = 0;
  if (o.lstm && o.level == 9) {
    final n = o.lstmCells;
    lstm = 8 * 13 * n * (256 + 2 * n + 1) * o.lstmLayers;
  }
  return (model + lstm) * threads + inputSize * 2 + (16 << 20);
}

/// Picks options for [inputSize] bytes on [m]. [timeBudgetSeconds] limits
/// the estimated encoding time; [speedScale] (from [zcmCalibrate]) scales
/// the nominal speeds to this machine; [allowParallel] allows segments
/// on several isolates.
ZcmAutoChoice zcmAutoSelect(ZcmMachine m, int inputSize,
    {double? timeBudgetSeconds,
    double speedScale = 1.0,
    bool allowParallel = true,
    int maxLevel = 9}) {
  final usable = zcmUsableBytes(m);
  final maxThreads = allowParallel ? (m.cores ~/ 2).clamp(1, 8) : 1;
  ZcmOptions opts(int tier) {
    final level = tier > 9 ? 9 : tier;
    final o = ZcmOptions(level: level, lstm: tier > 9);
    // Fit the budget: a level's default, less when memory is short.
    return _fitMemory(o, inputSize, usable, 1);
  }

  double seconds(int tier, int threads) {
    final kbps = zcmNominalKBps[tier] * speedScale;
    final eff = threads == 1 ? 1.0 : threads * 0.9;
    return inputSize / 1024 / (kbps * eff);
  }

  if (timeBudgetSeconds == null) {
    final level = 4 < maxLevel ? 4 : maxLevel;
    final o = opts(level);
    return ZcmAutoChoice(o, 1, seconds(level, 1),
        zcmEstimateBytes(o, inputSize, 1), 'default level, one thread');
  }
  final topTier = maxLevel >= 9 ? 10 : maxLevel;
  for (var tier = topTier; tier >= 1; tier--) {
    for (var t = 1; t <= maxThreads; t *= 2) {
      // Segments of at least 1 MiB: small inputs get one thread.
      if (t > 1 && inputSize < t * (1 << 20)) break;
      if (seconds(tier, t) > timeBudgetSeconds) continue;
      var o = opts(tier);
      if (t > 1) {
        o = _fitMemory(
            o.copyWith(segmentSize: _segment(inputSize, t)), inputSize,
            usable, t);
      }
      final bytes = zcmEstimateBytes(o, inputSize, t);
      if (bytes > usable) continue;
      return ZcmAutoChoice(o, t, seconds(tier, t), bytes,
          'strongest level within ${timeBudgetSeconds}s');
    }
  }
  final o = opts(1);
  return ZcmAutoChoice(o, 1, seconds(1, 1), zcmEstimateBytes(o, inputSize, 1),
      'time budget too short: fastest level');
}

int _segment(int size, int threads) {
  var seg = (size + threads - 1) ~/ threads;
  seg = (seg + zcmBlockSize - 1) ~/ zcmBlockSize * zcmBlockSize;
  return seg < (1 << 20) ? 1 << 20 : seg;
}

// Lowers the memory budget of [o] until [threads] workers fit in [usable].
ZcmOptions _fitMemory(ZcmOptions o, int inputSize, int usable, int threads) {
  var mib = zcmEffectiveMemoryMiB(o, inputSize);
  var r = o.copyWith(memoryMiB: mib);
  while (mib > zcmMinMemoryMiB && zcmEstimateBytes(r, inputSize, threads) > usable) {
    mib = mib * 3 ~/ 4;
    if (mib < zcmMinMemoryMiB) mib = zcmMinMemoryMiB;
    r = o.copyWith(memoryMiB: mib);
  }
  return r;
}

/// Measures this machine against the nominal speeds: codes [sample] (or
/// 64 KiB of generated mixed data) at [level] and returns measured KB/s
/// divided by the nominal KB/s of that level. Runs synchronously (call it
/// in a worker isolate from a UI).
double zcmCalibrate({Uint8List? sample, int level = 3}) {
  final data = sample ?? _calibrationData();
  final sw = Stopwatch()..start();
  zcmCompressBytes(data, ZcmOptions(level: level));
  final us = sw.elapsedMicroseconds;
  if (us <= 0) return 1.0;
  final kbps = data.length / 1024 / (us / 1e6);
  final scale = kbps / zcmNominalKBps[level];
  return scale.clamp(0.05, 20.0);
}

// Deterministic mixed data: words, numbers and some binary.
Uint8List _calibrationData() {
  const words = [
    'the ', 'model ', 'context ', 'mixing ', 'of ', 'bits ', 'and ', //
    'bytes ', 'is ', 'a ', 'stream ', '\n', 'int ', '= ', '0x', ';'
  ];
  final out = Uint8List(64 << 10);
  var seed = 12345;
  var i = 0;
  while (i < out.length) {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    if ((seed >> 20) % 8 == 0) {
      out[i++] = seed & 255;
      continue;
    }
    final w = words[(seed >> 16) % words.length];
    for (var j = 0; j < w.length && i < out.length; j++) {
      out[i++] = w.codeUnitAt(j);
    }
  }
  return out;
}

/// Probes this machine (and, with [calibrate], measures its speed on
/// 64 KiB of sample data, about a quarter of a second) and picks settings
/// for [inputSize] bytes. Synchronous: call it in a worker isolate from a
/// UI.
ZcmAutoChoice zcmAuto(int inputSize,
    {double? timeBudgetSeconds,
    bool calibrate = false,
    bool allowParallel = true,
    int maxLevel = 9}) {
  final m = zcmProbeMachine();
  final scale = calibrate ? zcmCalibrate() : 1.0;
  return zcmAutoSelect(m, inputSize,
      timeBudgetSeconds: timeBudgetSeconds,
      speedScale: scale,
      allowParallel: allowParallel,
      maxLevel: maxLevel);
}
