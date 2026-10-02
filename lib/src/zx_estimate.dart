// The compression settings of ZxOptions (automatic or given) and
// ZxArchive.estimate: what an update would choose and cost (time, memory,
// a range of output sizes) without compressing. The estimate runs on a
// worker isolate (ZxArchive.estimate); everything here is synchronous.
//
// The zcm choice is the one of the command line (lib/src/cli/
// zx_zcm_auto.dart: zcmAutoSelect for the machine, the input size and a
// time budget), measured on a sample of the input: 64 KiB taken from up
// to eight of the files are coded with zcm level 3, which gives both the
// speed of this machine (against the nominal speeds) and the ratio the
// output sizes are scaled from.

import 'host/io.dart';
import 'dart:typed_data';

import 'cli/zx_zcm_auto.dart';
import 'codec/zcm/zcm.dart';
import 'codec/zcm/zcm_auto.dart';
import 'format/zx/zx_codecs.dart';
import 'format/zx/zx_writer.dart'
    show zxWorkerMemory, zxWorkersFor, zxDefaultBlockSize, zxParseSize;
import 'io/streams.dart';
import 'pool.dart' show defaultThreads;

/// How a .zx archive is compressed ([ZxOptions.compression]).
///
/// [ZxCompression.auto] lets zx choose the zcm level, its memory and the
/// threads from the machine and the input (the choice is stored as plain
/// settings, so any machine decodes the archive);
/// [ZxCompression.manual] gives them.
class ZxCompression {
  /// Chosen by zx (zcm:auto).
  final bool auto;

  /// auto: the time the compression may take (null: [speed]).
  final Duration? timeBudget;

  /// auto: the preset used without [timeBudget].
  final ZxAutoSpeed speed;

  /// auto: the memory all the workers may use together (null: the safe
  /// maximum of the machine, 75% of the available memory and at most the
  /// available memory less 1.5 GiB).
  final int? memoryBudget;

  /// auto: measure this machine before choosing (about a quarter of a
  /// second) instead of using the nominal speeds.
  final bool calibrate;

  /// auto: false never chooses the LSTM of level 9.
  final bool allowLstm;

  /// manual: zcm settings.
  final ZcmOptions? zcm;

  /// manual: a coder chain in writing order, coders separated by spaces,
  /// as the -m0, -m1... switches take them: `LZMA2:d=64m`, `BCJ LZMA2`,
  /// `PPMd8:o=8:mem=256m`, `zcm:level=6`, `store`.
  final String? chain;

  /// The workers (-mmt; auto: at most this many).
  final int? threads;

  /// manual: the .zx block size (-mbs).
  final int? blockSize;

  const ZxCompression.auto(
      {this.timeBudget,
      this.speed = ZxAutoSpeed.balanced,
      this.memoryBudget,
      this.calibrate = false,
      this.allowLstm = true,
      this.threads})
      : auto = true,
        zcm = null,
        chain = null,
        blockSize = null;

  /// Give [zcm] or [chain].
  const ZxCompression.manual(
      {this.zcm, this.chain, this.threads, this.blockSize})
      : assert((zcm == null) != (chain == null), 'give zcm or chain'),
        auto = false,
        timeBudget = null,
        speed = ZxAutoSpeed.balanced,
        memoryBudget = null,
        calibrate = false,
        allowLstm = true;

  /// The -m switches of this setting for a .zx archive.
  Map<String, String> toSwitches() {
    final m = <String, String>{};
    if (auto) {
      m['0'] = 'zcm:auto';
      final t = timeBudget;
      m['time'] = t != null
          ? '${t.inSeconds < 1 ? 1 : t.inSeconds}s'
          : speed.name;
      if (memoryBudget != null) m['mem'] = '${memoryBudget}b';
      if (calibrate) m['cal'] = '';
      if (!allowLstm) m['lstm-'] = '';
      if (threads != null) m['mt'] = '$threads';
      return m;
    }
    final z = zcm;
    if (z != null) {
      m['0'] = zxZcmMethod(z);
    } else {
      final coders =
          chain!.trim().split(RegExp(r'\s+')).where((c) => c.isNotEmpty);
      var i = 0;
      for (final c in coders) {
        m['${i++}'] = c;
      }
    }
    if (threads != null) m['mt'] = '$threads';
    if (blockSize != null) m['bs'] = '$blockSize';
    return m;
  }

  @override
  String toString() => auto
      ? 'ZxCompression.auto(${timeBudget ?? speed.name}'
          '${memoryBudget == null ? '' : ', mem $memoryBudget'})'
      : 'ZxCompression.manual(${zcm ?? chain}'
          '${threads == null ? '' : ', threads $threads'})';
}

/// The zcm method of [o] as a .zx switch value.
String zxZcmMethod(ZcmOptions o) {
  final b = StringBuffer('zcm:level=${o.level}');
  if (o.memoryMiB > 0) b.write(':mem=${o.memoryMiB}');
  if (o.lstm) {
    b.write(':lstm=${o.lstmCells}/${o.lstmLayers}/${o.lstmHorizon}');
  } else if (o.level == 9) {
    b.write(':nolstm');
  }
  if (o.segmentSize > 0) b.write(':seg=${o.segmentSize}');
  if (!o.detect) b.write(':nodetect');
  return b.toString();
}

/// What an update would do ([ZxArchive.estimate]).
class ZxEstimate {
  /// The main coder: `zcm:level=6:mem=1024`, `LZMA2`...
  final String method;

  /// One line: "zcm level 6, 1.2 GiB, 2 threads, estimated 3 min".
  final String summary;

  /// The zcm level (null for the other methods) and whether the LSTM
  /// is used.
  final int? zcmLevel;
  final bool lstm;
  final int threads;
  final int blockSize;

  /// The files found and their bytes.
  final int files;
  final int inputSize;

  final Duration time;

  /// Estimated peak memory of the workers.
  final int memoryBytes;

  /// A range of output sizes (rough: from a sample).
  final int sizeLow;
  final int sizeHigh;

  /// Input KB per second of the estimate.
  final double kbPerSecond;

  /// The machine: available memory, the part zx may use, processors.
  final int availableMemory;
  final int safeMemory;
  final int cores;

  /// This machine's speed over the nominal one (from the sample).
  final double speedScale;
  final String reason;

  /// Memory above the safe maximum, a compression of hours...
  final List<String> warnings;

  /// The settings of this estimate as [ZxCompression.manual] (for zcm),
  /// so that an update does exactly what was estimated; null for the
  /// other methods.
  final ZxCompression? compression;

  const ZxEstimate(
      {required this.method,
      required this.summary,
      this.zcmLevel,
      this.lstm = false,
      required this.threads,
      required this.blockSize,
      required this.files,
      required this.inputSize,
      required this.time,
      required this.memoryBytes,
      required this.sizeLow,
      required this.sizeHigh,
      required this.kbPerSecond,
      required this.availableMemory,
      required this.safeMemory,
      required this.cores,
      required this.speedScale,
      required this.reason,
      this.warnings = const [],
      this.compression});

  @override
  String toString() => 'ZxEstimate($summary, $method, $files files, '
      '$inputSize bytes -> $sizeLow..$sizeHigh'
      '${warnings.isEmpty ? '' : ', warnings: $warnings'})';
}

/// Nominal single thread speeds of the other .zx methods (MB/s of input,
/// docs/performance.md; rough).
double _methodMBps(String name, int level) {
  switch (name.toLowerCase()) {
    case 'lzma2' || 'lzma':
      return level <= 1 ? 14 : (level <= 4 ? 5 : 2.2);
    case 'ppmd' || 'ppmd7' || 'ppmd8':
      return 4.5;
    case 'bzip2':
      return 8;
    case 'deflate':
      return 20;
    case 'zpaq':
      return level <= 2 ? 10 : (level <= 4 ? 2 : 0.5);
    case 'store' || 'copy':
      return 400;
  }
  return 5;
}

/// The files of [paths] (folders with everything below them): their
/// paths and sizes. Links are not followed below the top.
(List<String>, List<int>) zxScanSizes(List<String> paths) {
  final files = <String>[];
  final sizes = <int>[];
  for (final p in paths) {
    final t = FileSystemEntity.typeSync(p);
    if (t == FileSystemEntityType.file) {
      files.add(p);
      sizes.add(File(p).lengthSync());
    } else if (t == FileSystemEntityType.directory) {
      try {
        for (final e
            in Directory(p).listSync(recursive: true, followLinks: false)) {
          if (e is File) {
            try {
              sizes.add(e.lengthSync());
              files.add(e.path);
            } on FileSystemException {
              // unreadable: left out, as the update would
            }
          }
        }
      } on FileSystemException {
        // unreadable folder
      }
    }
  }
  return (files, sizes);
}

/// Up to [max] bytes of [files]: 8 KiB from up to eight files spread over
/// the list (from a third of each file).
Uint8List zxSample(List<String> files, List<int> sizes, {int max = 64 << 10}) {
  final out = BytesBuilder(copy: false);
  final idx = [
    for (var i = 0; i < files.length; i++)
      if (sizes[i] > 0) i
  ];
  if (idx.isEmpty) return Uint8List(0);
  final picks = idx.length <= 8
      ? idx
      : [for (var k = 0; k < 8; k++) idx[k * idx.length ~/ 8]];
  final per = max ~/ picks.length;
  for (final i in picks) {
    RandomAccessFile? f;
    try {
      f = File(files[i]).openSync();
      final len = sizes[i];
      final n = len < per ? len : per;
      final start = len - n < len ~/ 3 ? len - n : len ~/ 3;
      f.setPositionSync(start);
      out.add(f.readSync(n));
    } on FileSystemException {
      // skipped
    } finally {
      f?.closeSync();
    }
  }
  return out.takeBytes();
}

/// The estimate of an update of [paths] with [compression] (or
/// [method] and [level] of ZxOptions, or the .zx default LZMA2 level 5).
/// Synchronous (a worker isolate calls it).
ZxEstimate zxEstimate(List<String> paths,
    {ZxCompression? compression,
    String? method,
    int? level,
    Map<String, String> switches = const {},
    int? memoryLimit,
    ZcmMachine? machine}) {
  final (files, sizes) = zxScanSizes(paths);
  var total = 0;
  for (final s in sizes) {
    total += s;
  }
  final sample = zxSample(files, sizes);
  final m = machine ?? zcmProbeMachine();
  final lv = (level ?? 5).clamp(0, 9);

  // the main coder
  ZxCompression? c = compression;
  var chain = c == null
      ? (switches['0'] ?? switches['m'] ?? method ?? 'LZMA2')
      : (c.chain ?? (c.zcm != null ? zxZcmMethod(c.zcm!) : 'zcm:auto'));
  var main = 'LZMA2';
  for (final x in chain.trim().split(RegExp(r'\s+'))) {
    final colon = x.indexOf(':');
    final info = zxCodecByName(colon < 0 ? x : x.substring(0, colon));
    if (x.toLowerCase() == 'store' || x.toLowerCase() == 'copy') {
      main = x;
      continue;
    }
    if (info != null && !info.isFilter) main = x;
  }
  final mainName = (main.contains(':')
          ? main.substring(0, main.indexOf(':'))
          : main)
      .toLowerCase();
  final mt = int.tryParse(switches['mt'] ?? '') ?? c?.threads;
  final bsSwitch = switches['bs'];

  if (mainName == 'zcm') {
    // the speed of this machine and the ratio of level 3, on the sample
    var scale = 1.0;
    var ratio3 = 0.5;
    if (sample.length >= (4 << 10)) {
      final sw = Stopwatch()..start();
      final packed = zcmCompressBytes(sample, const ZcmOptions(level: 3));
      final us = sw.elapsedMicroseconds;
      if (us > 0) {
        scale = (sample.length / 1024 / (us / 1e6) / zcmNominalKBps[3])
            .clamp(0.05, 20.0);
      }
      ratio3 = packed.length / sample.length;
    } else {
      scale = zcmCalibrate();
    }
    final params = main.contains(':') ? main.substring(main.indexOf(':') + 1) : '';
    final isAuto = c?.auto ?? params
        .toLowerCase()
        .split(RegExp('[:,]'))
        .contains('auto');
    ZxZcmPlan plan;
    if (isAuto) {
      plan = zxPlanZcm(total,
          timeBudgetSeconds: c?.timeBudget == null
              ? null
              : c!.timeBudget!.inMilliseconds / 1000,
          speed: c?.speed ?? ZxAutoSpeed.balanced,
          memoryBudget: c?.memoryBudget,
          maxThreads: mt,
          lstm: c == null || c.allowLstm ? null : false,
          speedScale: scale,
          memoryLimit: memoryLimit,
          machine: m);
    } else {
      final o = c?.zcm ?? zcmOptionsFromString(params, level: lv < 1 ? 1 : lv);
      final bs = c?.blockSize ??
          zxParseSize(bsSwitch ?? '') ??
          zxDefaultBlockSize;
      plan = zxManualZcmPlan(o, total,
          threads: mt, blockSize: bs, speedScale: scale, machine: m);
    }
    final tier = plan.lstm ? 10 : plan.level;
    final est = total * ratio3 * zxZcmSizeFactor[tier] / zxZcmSizeFactor[3];
    final high = est * 1.05 + 1024;
    return ZxEstimate(
        method: plan.method,
        summary: plan.summary,
        zcmLevel: plan.level,
        lstm: plan.lstm,
        threads: plan.threads,
        blockSize: plan.blockSize,
        files: files.length,
        inputSize: total,
        time: Duration(milliseconds: (plan.seconds * 1000).round()),
        memoryBytes: plan.bytes,
        sizeLow: (est * 0.75).round(),
        sizeHigh: (high > total + 1024 ? total + 1024 : high).round(),
        kbPerSecond: plan.kbPerSecond,
        availableMemory: m.availableBytes,
        safeMemory: plan.safeBytes,
        cores: m.cores,
        speedScale: scale,
        reason: plan.reason,
        warnings: plan.warnings,
        compression: ZxCompression.manual(
            zcm: plan.options,
            threads: plan.threads,
            blockSize: plan.blockSize));
  }

  // the other methods: the ratio of the sample, nominal speeds
  final bs = zxParseSize(bsSwitch ?? '') ?? c?.blockSize ?? zxDefaultBlockSize;
  final coders = <ZxCoderSpec>[];
  var ratio = 1.0;
  if (mainName != 'store' && mainName != 'copy') {
    try {
      final spec = zxParseCoder(main, lv);
      coders.add(spec);
      final info = zxCodecById(spec.codecId);
      if (info != null && info.encode != null && sample.isNotEmpty) {
        ratio = info.encode!(sample, spec.config).data.length / sample.length;
      }
    } on SevenZipException {
      ratio = 1.0;
    }
  }
  final blocks = total <= 0 ? 1 : (total + bs - 1) ~/ bs;
  // the workers the .zx memory guard allows (zx_memory.dart)
  final safe = zcmUsableBytes(m);
  var t = zxWorkersFor(
      mt ?? defaultThreads(), zxWorkerMemory(coders, bs), memoryLimit ?? safe);
  if (t > blocks) t = blocks;
  if (t < 1) t = 1;
  final mbps = _methodMBps(mainName, lv) * (t == 1 ? 1.0 : t * 0.9);
  final seconds = total / (1 << 20) / mbps;
  final mem = zxWorkerMemory(coders, bs) * t;
  final warnings = <String>[
    if (mem > safe)
      'about ${zxFormatBytes(mem)} of memory, more than the '
          '${zxFormatBytes(safe)} this machine can spare',
  ];
  final est = total * ratio;
  return ZxEstimate(
      method: main,
      summary: '$main, ${zxFormatBytes(mem)}, $t thread${t == 1 ? '' : 's'}, '
          'estimated ${zxFormatSeconds(seconds)}',
      threads: t,
      blockSize: bs,
      files: files.length,
      inputSize: total,
      time: Duration(milliseconds: (seconds * 1000).round()),
      memoryBytes: mem,
      sizeLow: (est * 0.8).round(),
      sizeHigh: (est * 1.1 > total + 1024 ? total + 1024 : est * 1.1 + 64).round(),
      kbPerSecond: seconds <= 0 ? 0 : total / 1024 / seconds,
      availableMemory: m.availableBytes,
      safeMemory: safe,
      cores: m.cores,
      speedScale: 1.0,
      reason: 'nominal speed of $mainName',
      warnings: warnings);
}
