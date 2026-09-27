// Not in 7-Zip: the zcm settings of a .zx update chosen from the machine,
// the size of the input and a time budget, and the zx switches around them:
//
//   -m0=zcm:auto      choose the level, memory and threads (the other
//                     params of the method are kept: zcm:auto:nodetect)
//   -mtime={T}        the time budget of the choice: 90s, 10m, 2h, 1h30m,
//                     or a preset: fast, balanced (the default), max
//   -mmem={Size}      the zcm memory: with auto the budget of all the
//                     workers together (default: the safe maximum of the
//                     machine); with a zcm level the model budget of each
//                     stream (as zcm:mem=); plain numbers are MiB
//   -mlstm[=C/L/H]    the LSTM of level 9 (cells, layers, horizon); with
//                     auto the size used when the LSTM is chosen, and
//                     -mlstm- never chooses it
//   -mcal             measure this machine before choosing (a quarter of
//                     a second) instead of the nominal speeds
//   -mx={name}        named levels: with zcm fast (2), normal (4), max
//                     (6), ultra (8), cmix (9); with the other methods
//                     store (0), fastest (1), fast (3), normal (5), max
//                     (7), ultra (9)
//
// The choice (zcmAutoSelect of lib/src/codec/zcm/zcm_auto.dart) is turned
// into plain switches before anything is written: a zcm method with an
// explicit level and memory, -mmt (the .zx workers code one block each)
// and -mbs (a block per worker, at most 64 MiB). The archive stores only
// those, so it decodes anywhere. Pure computation apart from the machine
// probe and the optional calibration (synchronous: call it on a worker
// isolate from a UI).

import 'dart:typed_data';

import '../codec/zcm/zcm.dart';
import '../codec/zcm/zcm_auto.dart';
import '../common/method_props.dart';
import '../format/handler_out.dart' show getRamSize, parseSizeString;
import '../format/zx/zx_codecs.dart' show ZxCoderConfig, ZxCoderSpec;
import '../format/zx/zx_writer.dart'
    show zxDefaultMemoryLimit, zxParseSize, zxWorkerMemory;

/// The time budget presets of the automatic zcm choice.
enum ZxAutoSpeed {
  /// About 500 KB/s of input at the nominal speeds (levels 1 to 3).
  fast,

  /// About 100 KB/s (levels 3 to 5 with a few threads), the default.
  balanced,

  /// About 10 KB/s (levels 8 and 9).
  max,
}

/// The nominal input speed (KB/s) a preset asks for: the time budget is
/// the input size over this speed.
double zxAutoSpeedKBps(ZxAutoSpeed s) => switch (s) {
      ZxAutoSpeed.fast => 500,
      ZxAutoSpeed.balanced => 100,
      ZxAutoSpeed.max => 10,
    };

/// The time budget (seconds) of [s] for [inputSize] bytes: the input
/// over the preset's speed, at least 5 s (fast), 30 s (balanced) or 5
/// minutes (max), so that small inputs get a strong level.
double zxAutoBudgetSeconds(ZxAutoSpeed s, int inputSize) {
  final t = inputSize / 1024 / zxAutoSpeedKBps(s);
  final floor = switch (s) {
    ZxAutoSpeed.fast => 5.0,
    ZxAutoSpeed.balanced => 30.0,
    ZxAutoSpeed.max => 300.0,
  };
  return t < floor ? floor : t;
}

/// Parses a duration: `90`, `90s`, `10m`, `2h`, `1h30m`, `1.5h`, `2d`
/// (seconds when there is no unit). Null when it is not one.
double? zxParseDuration(String s) {
  final t = s.trim().toLowerCase();
  if (t.isEmpty) return null;
  final re = RegExp(r'(\d+(?:\.\d+)?)\s*(s|sec|m|min|h|d)?');
  var pos = 0;
  var sum = 0.0;
  for (final m in re.allMatches(t)) {
    if (m.start != pos) return null;
    pos = m.end;
    final v = double.parse(m.group(1)!);
    sum += v *
        switch (m.group(2)) {
          'm' || 'min' => 60,
          'h' => 3600,
          'd' => 86400,
          _ => 1,
        };
  }
  if (pos != t.length) return null;
  return sum;
}

/// Parses a memory size: `512m`, `2g`, `1.5g`, `64k`, `1000b`; a plain
/// number is MiB. Null when it is not one.
int? zxParseMemSize(String s) {
  final m = RegExp(r'^(\d+(?:\.\d+)?)\s*([bkmgt]?)i?b?$')
      .firstMatch(s.trim().toLowerCase());
  if (m == null) return null;
  final v = double.parse(m.group(1)!);
  final mul = switch (m.group(2)) {
    'b' => 1,
    'k' => 1 << 10,
    'g' => 1 << 30,
    't' => 1 << 40,
    _ => 1 << 20,
  };
  return (v * mul).round();
}

/// A level name of -mx: with [zcm] the zcm names ([zcmLevelByName], and
/// `fastest` is 1), else the names of the 7-Zip File Manager. Null when
/// unknown.
int? zxLevelByName(String name, {required bool zcm}) {
  final n = name.trim().toLowerCase();
  if (zcm) {
    if (n == 'fastest') return 1;
    if (n == 'maximum') return 6;
    return zcmLevelByName(n);
  }
  return switch (n) {
    'store' || 'copy' => 0,
    'fastest' => 1,
    'fast' => 3,
    'normal' => 5,
    'max' || 'maximum' => 7,
    'ultra' || 'cmix' => 9,
    _ => null,
  };
}

/// Relative output size of each zcm level against level 3 (index 10:
/// level 9 with the LSTM), from the corpus of docs/performance.md.
const List<double> zxZcmSizeFactor = [
  1.0, 1.056, 1.021, 1.0, 0.978, 0.974, 0.970, 0.969, 0.968, 0.968, 0.965 //
];

/// "1.2 GiB", "340 MiB", "12 KiB".
String zxFormatBytes(int b) {
  if (b >= 1 << 30) {
    final g = b / (1 << 30);
    return '${g >= 10 ? g.round() : g.toStringAsFixed(1)} GiB';
  }
  if (b >= 1 << 20) return '${(b / (1 << 20)).round()} MiB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).round()} KiB';
  return '$b B';
}

/// "12 s", "3 min", "1 h 20 min", "26 h".
String zxFormatSeconds(double s) {
  if (s < 1) return 'under a second';
  if (s < 90) return '${s.round()} s';
  final min = (s / 60).round();
  if (min < 60) return '$min min';
  final h = min ~/ 60;
  final rest = min % 60;
  if (h >= 10) return '$h h';
  return rest == 0 ? '$h h' : '$h h $rest min';
}

/// Settings of zcm in a .zx update: chosen by [zxPlanZcm] or given
/// ([zxManualZcmPlan]), with their estimate.
final class ZxZcmPlan {
  /// The zcm options of each block (segmentSize 0: a block is a stream;
  /// memoryMiB is the budget each stream declares).
  final ZcmOptions options;

  /// Worker isolates (-mmt): each codes one block.
  final int threads;

  /// The .zx block size (-mbs).
  final int blockSize;

  /// The bytes to compress.
  final int inputSize;

  /// Estimated seconds to compress (decompression takes about as long).
  final double seconds;

  /// Estimated peak memory of the workers together.
  final int bytes;

  /// The memory the choice had to fit in (-mmem, or [guardBytes]).
  final int budgetBytes;

  /// The limit of the .zx memory guard (-mmemuse, or [safeBytes]).
  final int guardBytes;

  /// What the machine can give without swapping, and the part zcm may
  /// take of it (zcmUsableBytes).
  final int availableBytes;
  final int safeBytes;
  final int cores;

  /// Measured speed over the nominal speeds (1.0 without calibration).
  final double speedScale;
  final bool calibrated;

  /// Chosen automatically (false: given).
  final bool auto;
  final String reason;
  final List<String> warnings;

  const ZxZcmPlan(
      {required this.options,
      required this.threads,
      required this.blockSize,
      required this.inputSize,
      required this.seconds,
      required this.bytes,
      required this.budgetBytes,
      required this.guardBytes,
      required this.availableBytes,
      required this.safeBytes,
      required this.cores,
      required this.speedScale,
      required this.calibrated,
      required this.auto,
      required this.reason,
      this.warnings = const []});

  int get level => options.level;
  bool get lstm => options.lstm && options.level == 9;

  /// Input KB per second of the estimate.
  double get kbPerSecond =>
      seconds <= 0 ? 0 : inputSize / 1024 / seconds;

  /// The zcm method with explicit settings: `zcm:level=6:mem=1024`,
  /// `zcm:level=9:mem=2048:lstm=64/1/20`.
  String get method => 'zcm:${_params(options)}';

  /// One line: "zcm level 6, 1.2 GiB, 2 threads, estimated 3 min".
  String get summary => 'zcm level $level${lstm ? ' + LSTM' : ''}, '
      '${zxFormatBytes(bytes)}, $threads thread${threads == 1 ? '' : 's'}, '
      'estimated ${zxFormatSeconds(seconds)}';

  /// The details for -bb1: the machine and the reason.
  String get details => 'zcm ${auto ? 'auto' : 'settings'}: '
      '${zxFormatBytes(inputSize)} of input, blocks of '
      '${zxFormatBytes(blockSize)}, memory budget '
      '${zxFormatBytes(budgetBytes)} (available ${zxFormatBytes(availableBytes)}, '
      'safe ${zxFormatBytes(safeBytes)}), $cores cores, speed '
      'x${speedScale.toStringAsFixed(2)}'
      '${calibrated ? ' (calibrated)' : ' (nominal)'}, '
      '~${kbPerSecond.toStringAsFixed(kbPerSecond < 10 ? 1 : 0)} KB/s: '
      '$reason';

  @override
  String toString() => '$summary [$method, -mmt$threads, -mbs$blockSize]';
}

// A machine whose zcmUsableBytes is [usable] (to impose a memory budget
// on zcmAutoSelect).
ZcmMachine _machineWithUsable(int usable, int cores) {
  var avail = usable + (3 << 29);
  final alt = usable * 4 ~/ 3;
  if (alt > avail) avail = alt;
  var m = ZcmMachine(availableBytes: avail, cores: cores);
  while (zcmUsableBytes(m) < usable) {
    avail += 4;
    m = ZcmMachine(availableBytes: avail, cores: cores);
  }
  return m;
}

double _kbps(int level, bool lstm) =>
    zcmNominalKBps[lstm && level == 9 ? 10 : level];

double _seconds(int inputSize, int level, bool lstm, int threads,
    double scale) {
  final eff = threads <= 1 ? 1.0 : threads * 0.9;
  final v = _kbps(level, lstm) * scale * eff;
  return v <= 0 ? 0 : inputSize / 1024 / v;
}

// Peak memory of [threads] workers coding blocks of [blockSize] bytes
// with [o]: the estimate of the .zx memory guard (zxWorkerMemory of
// zx_memory.dart) for each worker, so that the guard never cuts the
// workers of a plan that fits its limit.
int _bytes(ZcmOptions o, int blockSize, int threads) =>
    zxWorkerMemory([
      ZxCoderSpec(zcmCodecId,
          ZxCoderConfig(level: o.level, params: _params(o)))
    ], blockSize) *
    threads;

// The zcm params of [o] as the zx registry reads them.
String _params(ZcmOptions o) {
  final b = StringBuffer('level=${o.level}:mem=${o.memoryMiB}');
  if (o.lstm && o.level == 9) {
    b.write(':lstm=${o.lstmCells}/${o.lstmLayers}/${o.lstmHorizon}');
  } else if (o.level == 9) {
    b.write(':nolstm');
  }
  if (!o.detect) b.write(':nodetect');
  return b.toString();
}

int _roundUpMiB(int n) => (n + (1 << 20) - 1) >> 20 << 20;

/// Chooses zcm settings for [inputSize] bytes: the strongest level whose
/// estimated time fits [timeBudgetSeconds] (or the budget of [speed]),
/// within [memoryBudget] (default: the safe maximum of [machine]) and at
/// most [maxThreads] workers (default: half the cores, at most 8).
/// [lstm] false never chooses the LSTM; [lstmCells], [lstmLayers] and
/// [lstmHorizon] size it when it is chosen. [blockSize] keeps a given
/// .zx block size. [calibrate] measures this machine first (on [sample]
/// when given); [speedScale] gives the result of a calibration made
/// before. Synchronous.
ZxZcmPlan zxPlanZcm(int inputSize,
    {double? timeBudgetSeconds,
    ZxAutoSpeed speed = ZxAutoSpeed.balanced,
    int? memoryBudget,
    int? maxThreads,
    int? blockSize,
    bool? lstm,
    int? lstmCells,
    int? lstmLayers,
    int? lstmHorizon,
    bool detect = true,
    bool calibrate = false,
    Uint8List? sample,
    double? speedScale,
    int? memoryLimit,
    ZcmMachine? machine}) {
  final m = machine ?? zcmProbeMachine();
  final calibrated = speedScale != null || calibrate;
  final scale = speedScale ?? (calibrate ? zcmCalibrate(sample: sample) : 1.0);
  final safe = zcmUsableBytes(m);
  final warnings = <String>[];
  // the limit of the .zx memory guard (-mmemuse): a plan above it would
  // get fewer workers
  final guard = memoryLimit ?? (machine != null ? safe : zxDefaultMemoryLimit());
  var usable = memoryBudget ?? guard;
  if (usable < (64 << 20)) usable = 64 << 20;
  if (memoryBudget != null && memoryBudget > safe) {
    warnings.add('the zcm memory budget ${zxFormatBytes(memoryBudget)} is '
        'more than the ${zxFormatBytes(safe)} this machine can spare');
  }
  final budget =
      timeBudgetSeconds ?? zxAutoBudgetSeconds(speed, inputSize);
  // zcmAutoSelect allows up to half the cores (at most 8)
  final cores = maxThreads != null ? maxThreads * 2 : m.cores;
  final choice = zcmAutoSelect(_machineWithUsable(usable, cores), inputSize,
      timeBudgetSeconds: budget,
      speedScale: scale,
      allowParallel: maxThreads == null || maxThreads > 1);
  var level = choice.options.level;
  var withLstm = choice.options.lstm && level == 9;
  var reason = choice.reason;
  if (withLstm && lstm == false) {
    withLstm = false;
    reason = '$reason, without the LSTM (-mlstm-)';
  }
  var threads = choice.threads < 1 ? 1 : choice.threads;

  // one block per worker, at most 64 MiB (more blocks than workers then)
  var bs = blockSize ??
      (threads > 1 && choice.options.segmentSize > 0
          ? choice.options.segmentSize
          : _roundUpMiB(inputSize));
  if (blockSize == null) {
    bs = _roundUpMiB(bs);
    if (bs < (1 << 20)) bs = 1 << 20;
    if (bs > (64 << 20)) bs = 64 << 20;
  }
  final blockData = inputSize < 1 ? 1 : (inputSize < bs ? inputSize : bs);

  // the budget of each stream: fitted to the data of a block, then
  // lowered until the workers fit the estimate of the memory guard; a
  // model is not cut below a quarter while fewer workers would do
  var o = ZcmOptions(
      level: level,
      memoryMiB: choice.options.memoryMiB,
      lstm: withLstm,
      lstmCells: lstmCells ?? choice.options.lstmCells,
      lstmLayers: lstmLayers ?? choice.options.lstmLayers,
      lstmHorizon: lstmHorizon ?? choice.options.lstmHorizon,
      detect: detect);
  final mib0 = zcmEffectiveMemoryMiB(o, blockData);
  var mib = mib0;
  var bytes = 0;
  for (;;) {
    final floor = threads > 1 ? mib0 ~/ 4 : zcmMinMemoryMiB;
    mib = mib0;
    o = o.copyWith(memoryMiB: mib);
    bytes = _bytes(o, bs, threads);
    while (bytes > usable && mib > zcmMinMemoryMiB && mib > floor) {
      mib = mib * 3 ~/ 4;
      if (mib < zcmMinMemoryMiB) mib = zcmMinMemoryMiB;
      o = o.copyWith(memoryMiB: mib);
      bytes = _bytes(o, bs, threads);
    }
    if (bytes <= usable || threads == 1) break;
    threads = threads ~/ 2;
    reason = '$reason, $threads worker${threads == 1 ? '' : 's'} for the '
        'memory';
  }
  final seconds = _seconds(inputSize, level, withLstm, threads, scale);
  if (bytes > safe && (memoryBudget == null || memoryBudget <= safe)) {
    warnings.add('about ${zxFormatBytes(bytes)} of memory, more than the '
        '${zxFormatBytes(safe)} this machine can spare');
  }
  _timeWarning(warnings, seconds, inputSize);
  return ZxZcmPlan(
      options: o,
      threads: threads,
      blockSize: bs,
      inputSize: inputSize,
      seconds: seconds,
      bytes: bytes,
      budgetBytes: usable,
      guardBytes: guard,
      availableBytes: m.availableBytes,
      safeBytes: safe,
      cores: m.cores,
      speedScale: scale,
      calibrated: calibrated,
      auto: true,
      reason: reason,
      warnings: warnings);
}

void _timeWarning(List<String> warnings, double seconds, int inputSize) {
  if (seconds < 3600) return;
  final kbps = inputSize / 1024 / seconds;
  final h = seconds / 3600;
  warnings.add('this takes about '
      '${h >= 10 ? h.round() : h.toStringAsFixed(1)} hours at '
      '~${kbps.toStringAsFixed(kbps < 10 ? 1 : 0)} KB/s '
      '(decompression takes as long)');
}

/// The estimate of given zcm settings [o] on [threads] workers (default:
/// as many as the blocks, up to half the cores) with .zx blocks of
/// [blockSize] bytes.
ZxZcmPlan zxManualZcmPlan(ZcmOptions o, int inputSize,
    {int? threads,
    int blockSize = 16 << 20,
    bool calibrate = false,
    Uint8List? sample,
    double? speedScale,
    ZcmMachine? machine}) {
  final m = machine ?? zcmProbeMachine();
  final calibrated = speedScale != null || calibrate;
  final scale = speedScale ?? (calibrate ? zcmCalibrate(sample: sample) : 1.0);
  final safe = zcmUsableBytes(m);
  final blocks = inputSize <= 0 ? 1 : (inputSize + blockSize - 1) ~/ blockSize;
  var t = threads ?? (m.cores ~/ 2).clamp(1, 8);
  if (t > blocks) t = blocks;
  if (t < 1) t = 1;
  final blockData =
      inputSize < 1 ? 1 : (inputSize < blockSize ? inputSize : blockSize);
  final withLstm = o.lstm && o.level == 9;
  final eff = o.copyWith(
      memoryMiB: zcmEffectiveMemoryMiB(o, blockData), segmentSize: 0);
  final bytes = _bytes(eff, blockSize, t);
  final seconds = _seconds(inputSize, o.level, withLstm, t, scale);
  final warnings = <String>[];
  if (bytes > safe) {
    warnings.add('about ${zxFormatBytes(bytes)} of memory, more than the '
        '${zxFormatBytes(safe)} this machine can spare: lower the level, '
        'the memory or the threads');
  }
  _timeWarning(warnings, seconds, inputSize);
  return ZxZcmPlan(
      options: eff,
      threads: t,
      blockSize: blockSize,
      inputSize: inputSize,
      seconds: seconds,
      bytes: bytes,
      budgetBytes: safe,
      guardBytes: safe,
      availableBytes: m.availableBytes,
      safeBytes: safe,
      cores: m.cores,
      speedScale: scale,
      calibrated: calibrated,
      auto: false,
      reason: 'given settings',
      warnings: warnings);
}

// ---------------------------------------------------------------------------
// The switches

/// What the zx extension switches of an update ask for (see the file
/// header). Built by [zxPrepareZcmProperties].
final class ZxZcmRequest {
  /// The method key of the zcm:auto method ('0', '1'... or 'm').
  final String methodKey;

  /// The params of that method besides `auto`, appended to the chosen
  /// method (they win).
  final String extraParams;
  final double? timeBudgetSeconds;
  final ZxAutoSpeed speed;
  final int? memoryBudget;
  final bool? lstm;
  final int? lstmCells, lstmLayers, lstmHorizon;
  final bool calibrate;

  /// -mmemuse when given (the limit of the memory guard).
  final int? memoryLimit;

  /// -mmt and -mbs when given (they are kept).
  final int? threads;
  final int? blockSize;

  const ZxZcmRequest(
      {required this.methodKey,
      this.extraParams = '',
      this.timeBudgetSeconds,
      this.speed = ZxAutoSpeed.balanced,
      this.memoryBudget,
      this.lstm,
      this.lstmCells,
      this.lstmLayers,
      this.lstmHorizon,
      this.calibrate = false,
      this.memoryLimit,
      this.threads,
      this.blockSize});

  /// The plan for [inputSize] bytes.
  ZxZcmPlan plan(int inputSize, {ZcmMachine? machine, double? speedScale}) {
    var detect = true;
    for (final t in extraParams.split(RegExp('[:,]'))) {
      if (t.trim().toLowerCase() == 'nodetect') detect = false;
    }
    return zxPlanZcm(inputSize,
        timeBudgetSeconds: timeBudgetSeconds,
        speed: speed,
        memoryBudget: memoryBudget,
        maxThreads: threads,
        blockSize: blockSize,
        lstm: lstm,
        lstmCells: lstmCells,
        lstmLayers: lstmLayers,
        lstmHorizon: lstmHorizon,
        detect: detect,
        calibrate: calibrate,
        speedScale: speedScale,
        memoryLimit: memoryLimit,
        machine: machine);
  }

  /// The properties that apply [p]: the method, -mmt and -mbs, and
  /// -mmemuse when -mmem asked for more than the guard's limit (so that
  /// the guard keeps the workers of the plan).
  List<MapEntry<String, PropVariant>> properties(ZxZcmPlan p) {
    final extra = extraParams.isEmpty ? '' : ':$extraParams';
    return [
      MapEntry(methodKey, PropVariant.bstr('${p.method}$extra')),
      MapEntry('mt', PropVariant.ui4(p.threads)),
      MapEntry('bs', PropVariant.bstr('${p.blockSize}')),
      if (p.bytes > p.guardBytes)
        MapEntry('memuse', PropVariant.ui8(p.bytes)),
    ];
  }
}

/// The result of [zxPrepareZcmProperties].
final class ZxZcmPrepared {
  /// The properties for the handler (the zx extensions resolved or
  /// removed, a zcm:auto method replaced by a valid placeholder).
  final List<MapEntry<String, PropVariant>> props;

  /// Set when a zcm method is `auto`: the choice waits for the size of
  /// the input.
  final ZxZcmRequest? auto;
  const ZxZcmPrepared(this.props, this.auto);
}

bool _isMethodKey(String name) =>
    name == 'm' || RegExp(r'^\d+$').hasMatch(name);

String _str(PropVariant v) => switch (v.vt) {
      VarType.bstr => v.stringValue,
      VarType.ui4 || VarType.ui8 => '${v.intValue}',
      _ => '',
    };

bool _isZcm(String method) {
  final c = method.indexOf(':');
  return (c < 0 ? method : method.substring(0, c)).trim().toLowerCase() ==
      'zcm';
}

bool _flag(MapEntry<String, PropVariant> p) {
  final v = p.value;
  if (v.vt == VarType.empty) return true;
  if (v.vt == VarType.bool_) return v.boolValue;
  final s = _str(v).toLowerCase();
  if (s == '' || s == 'on' || s == '+' || s == 'true') return true;
  if (s == 'off' || s == '-' || s == 'false') return false;
  invalidArg('zx: bad value for -m${p.key}');
}

/// Reads the zx extension switches of zcm from the -m properties of a
/// .zx update (see the file header) and returns the properties for the
/// handler and, for `zcm:auto`, the request to resolve when the input
/// size is known. Throws [InvalidArgException] for bad values.
ZxZcmPrepared zxPrepareZcmProperties(List<MapEntry<String, PropVariant>> props) {
  double? time;
  var speed = ZxAutoSpeed.balanced;
  var timeGiven = false;
  int? mem;
  bool? lstm;
  int? cells, layers, horizon;
  var cal = false;
  int? threads;
  int? blockSize;
  int? memuse;
  final out = <MapEntry<String, PropVariant>>[];
  for (final p in props) {
    final name = p.key.toLowerCase();
    final s = _str(p.value);
    switch (name) {
      case 'time':
        final t = s.trim().toLowerCase();
        timeGiven = true;
        final preset = ZxAutoSpeed.values
            .where((e) => e.name == t || (t == 'normal' && e.name == 'balanced'));
        if (preset.isNotEmpty) {
          speed = preset.first;
          time = null;
        } else {
          time = zxParseDuration(t);
          if (time == null || time <= 0) {
            invalidArg('zx: -mtime needs a duration (90s, 10m, 2h) or '
                'fast, balanced, max');
          }
        }
        continue;
      case 'mem':
        final b = zxParseMemSize(s);
        if (b == null || b < (4 << 20)) {
          invalidArg('zx: -mmem needs a size of at least 4m (512m, 2g)');
        }
        mem = b;
        continue;
      case 'lstm':
        if (p.value.vt == VarType.bool_ || s.isEmpty || !s.contains('/') &&
            int.tryParse(s) == null) {
          lstm = _flag(p);
          continue;
        }
        final parts = s.split('/').map((x) => int.tryParse(x.trim())).toList();
        if (parts.any((x) => x == null || x < 1)) {
          invalidArg('zx: -mlstm=CELLS[/LAYERS[/HORIZON]]');
        }
        lstm = true;
        cells = parts[0];
        layers = parts.length > 1 ? parts[1] : null;
        horizon = parts.length > 2 ? parts[2] : null;
        if (cells! > zcmMaxLstmCells ||
            (layers ?? 1) > zcmMaxLstmLayers ||
            (horizon ?? 1) > zcmMaxLstmHorizon) {
          invalidArg('zx: the LSTM is at most $zcmMaxLstmCells cells, '
              '$zcmMaxLstmLayers layers, horizon $zcmMaxLstmHorizon');
        }
        continue;
      case 'cal' || 'calibrate':
        cal = _flag(p);
        continue;
      case 'bs' || 'block':
        blockSize = zxParseSize(s);
      case 's':
        final n = zxParseSize(s);
        if (n != null && n > 0) blockSize = n;
      default:
        if (name.startsWith('memuse')) {
          try {
            memuse = parseSizeString(name.substring(6), p.value,
                getRamSize() ?? zxDefaultMemoryLimit());
          } on Object {
            memuse = null; // the handler reports it
          }
        } else if (name.startsWith('mt')) {
          final n = name.substring(2);
          threads = n.isNotEmpty
              ? int.tryParse(n)
              : (p.value.vt == VarType.ui4 ? p.value.intValue : null);
        }
    }
    out.add(p);
  }

  // the methods, and the zcm:auto one
  var anyZcm = false;
  var anyMethod = false;
  int? autoAt;
  var extra = '';
  for (var i = 0; i < out.length; i++) {
    final p = out[i];
    final name = p.key.toLowerCase();
    if (!_isMethodKey(name)) continue;
    anyMethod = true;
    final v = _str(p.value);
    if (!_isZcm(v)) continue;
    anyZcm = true;
    final c = v.indexOf(':');
    final params = c < 0 ? '' : v.substring(c + 1);
    final tokens = params
        .split(RegExp('[:,]'))
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .toList();
    if (tokens.any((x) => x.toLowerCase() == 'auto')) {
      if (autoAt != null) invalidArg('zx: only one zcm:auto method');
      autoAt = i;
      extra = tokens.where((x) => x.toLowerCase() != 'auto').join(':');
      out[i] = MapEntry(p.key, PropVariant.bstr(
          extra.isEmpty ? 'zcm' : 'zcm:$extra'));
    }
  }
  if (autoAt == null && (timeGiven || cal)) {
    if (anyMethod) {
      invalidArg('zx: -mtime and -mcal choose the zcm settings: use them '
          'with -m0=zcm:auto');
    }
    out.add(const MapEntry('0', PropVariant.bstr('zcm')));
    autoAt = out.length - 1;
    anyZcm = true;
  }
  if ((mem != null || lstm != null) && !anyZcm) {
    invalidArg('zx: -mmem and -mlstm set the zcm codec: use them with '
        '-m0=zcm... (or -m0=zcm:auto)');
  }
  // manual zcm methods get -mmem and -mlstm as params
  if (mem != null || lstm != null) {
    for (var i = 0; i < out.length; i++) {
      final p = out[i];
      if (i == autoAt || !_isMethodKey(p.key.toLowerCase())) continue;
      final v = _str(p.value);
      if (!_isZcm(v)) continue;
      final b = StringBuffer(v.contains(':') ? v : '$v:');
      void add(String x) {
        if (!b.toString().endsWith(':')) b.write(':');
        b.write(x);
      }

      if (mem != null) add('mem=${(mem + (1 << 20) - 1) >> 20}');
      if (lstm == true) {
        add(cells == null
            ? 'lstm'
            : 'lstm=$cells/${layers ?? 1}/${horizon ?? 20}');
      } else if (lstm == false) {
        add('nolstm');
      }
      out[i] = MapEntry(p.key, PropVariant.bstr(b.toString()));
    }
  }
  // named levels (-mx=ultra)
  for (var i = 0; i < out.length; i++) {
    final p = out[i];
    final name = p.key.toLowerCase();
    if (name != 'x' || p.value.vt != VarType.bstr) continue;
    final l = zxLevelByName(p.value.stringValue, zcm: anyZcm);
    if (l == null) {
      invalidArg('zx: unknown level ${p.value.stringValue}');
    }
    out[i] = MapEntry(p.key, PropVariant.ui4(l));
  }
  final req = autoAt == null
      ? null
      : ZxZcmRequest(
          methodKey: out[autoAt].key,
          extraParams: extra,
          timeBudgetSeconds: time,
          speed: speed,
          memoryBudget: mem,
          lstm: lstm,
          lstmCells: cells,
          lstmLayers: layers,
          lstmHorizon: horizon,
          calibrate: cal,
          memoryLimit: memuse,
          threads: threads,
          blockSize: blockSize);
  return ZxZcmPrepared(out, req);
}
