// The memory guard of the .zx writer and reader: an estimate of the
// memory one worker needs to code a block with a chain, and the number of
// workers that fit in a budget. The default budget is the one of zcm's
// automatic settings (lib/src/codec/zcm/zcm_auto.dart): 75% of the
// available memory, and at most the available memory minus 1.5 GiB.

import 'dart:typed_data';

import '../../codec/zcm/zcm.dart';
import '../../codec/zcm/zcm_auto.dart';
import '../../io/streams.dart';
import 'zx_codecs.dart';
import 'zx_format.dart';

/// The default memory budget of the block workers (bytes): see the top of
/// this file. Probed once per isolate.
int zxDefaultMemoryLimit() =>
    _probed ??= zcmUsableBytes(zcmProbeMachine());
int? _probed;

/// The memory of zpaq's models by method level (1 to 5): its levels 1 and
/// 2 are LZ77 with hash tables, 3 to 5 context mixing models of growing
/// size (libzpaq's method strings; the tables are per block).
const List<int> _zpaqModel = [0, 32 << 20, 64 << 20, 160 << 20, 400 << 20, 1 << 30];

int _zpaqLevel(ZxCoderConfig cfg) {
  for (final part in cfg.params.split(':')) {
    final m = part.startsWith('m=') ? part.substring(2) : part;
    if (m.isEmpty) continue;
    final d = int.tryParse(m[0]);
    if (d != null) return d.clamp(1, 5);
    // x.. and other custom methods: the largest model
    return 5;
  }
  return (cfg.level.clamp(1, 9) + 1) ~/ 2;
}

// the size in bytes of "mem=..." or "d=..." in 7-Zip's syntax (a number
// with b, k, m or g, a bare number of MB for mem), or null
int? _paramSize(String params, List<String> keys, {int bareUnit = 1 << 20}) {
  for (final p in params.split(RegExp('[:,]'))) {
    final eq = p.indexOf('=');
    if (eq < 0) continue;
    if (!keys.contains(p.substring(0, eq).toLowerCase())) continue;
    final m = RegExp(r'^(\d+)([bkmg]?)$').firstMatch(p.substring(eq + 1).toLowerCase());
    if (m == null) return null;
    final v = int.parse(m[1]!);
    return switch (m[2]) {
      'b' => v,
      'k' => v << 10,
      'm' => v << 20,
      'g' => v << 30,
      _ => v * bareUnit,
    };
  }
  return null;
}

/// An estimate of the memory one worker uses to encode a block of
/// [blockSize] bytes with [coders]: the block, its output and each
/// encoder's model (LZMA and LZMA2 about 11.5 times the dictionary, which
/// is at most the block; PPMd its model size; zpaq its method's tables;
/// zcm the estimate of zcm itself).
int zxWorkerMemory(List<ZxCoderSpec> coders, int blockSize) {
  var m = 3 * blockSize;
  for (final c in coders) {
    switch (c.codecId) {
      case ZxCodecId.lzma || ZxCodecId.lzma2:
        var d = _paramSize(c.config.params, const ['d']) ?? blockSize;
        if (d > blockSize) d = blockSize;
        m += d * 23 ~/ 2;
      case ZxCodecId.ppmd7 || ZxCodecId.ppmd8:
        final lv = c.config.level.clamp(1, 9);
        var mem = _paramSize(c.config.params, const ['mem']) ?? 1 << (lv + 19);
        if (mem > 16 * blockSize + (1 << 20)) mem = 16 * blockSize + (1 << 20);
        m += mem;
      case ZxCodecId.zpaq:
        m += blockSize * 3 + _zpaqModel[_zpaqLevel(c.config)];
      case zcmCodecId:
        try {
          final o = zcmOptionsFromString(c.config.params,
              level: c.config.level.clamp(1, 9));
          m += zcmEstimateBytes(o, blockSize, 1);
        } on SevenZipException {
          m += 1 << 30;
        } on Object {
          m += 1 << 30;
        }
      default:
        m += blockSize;
    }
  }
  return m;
}

/// An estimate of the memory one worker uses to decode a block of
/// [unpackedSize] bytes coded with [chain] (from the props the chain
/// stores: the PPMd model size, the zcm budget).
int zxDecodeMemory(ZxChain chain, int unpackedSize) {
  var m = 2 * unpackedSize;
  for (final c in chain.coders) {
    final p = c.props;
    switch (c.codecId) {
      case ZxCodecId.lzma || ZxCodecId.lzma2:
        m += unpackedSize;
      case ZxCodecId.ppmd7:
        m += p.length == 5 ? getUint32LE(p, 1) : 256 << 20;
      case ZxCodecId.ppmd8:
        m += p.length == 2 ? ((((p[0] | (p[1] << 8)) >> 4) & 0xFF) + 1) << 20 : 256 << 20;
      case ZxCodecId.zpaq:
        // the model is described inside the payload: assume a large one
        m += unpackedSize + (256 << 20);
      case zcmCodecId:
        try {
          final h = zcmParseProps(Uint8List.fromList(p));
          m += (h.memoryMiB << 20) * 4 ~/ 3 + (16 << 20);
          if (h.lstm) {
            final n = h.lstmCells;
            m += 8 * 13 * n * (256 + 2 * n + 1) * h.lstmLayers;
          }
        } on Object {
          m += 1 << 30;
        }
      default:
        m += unpackedSize;
    }
  }
  return m;
}

/// The number of workers for [threads] wanted, when each needs
/// [perWorker] bytes and all of them together at most [limit]: at least
/// one.
int zxWorkersFor(int threads, int perWorker, int limit) {
  var t = threads < 1 ? 1 : threads;
  final cap = limit ~/ (perWorker < 1 ? 1 : perWorker);
  if (t > cap) t = cap < 1 ? 1 : cap;
  return t;
}
