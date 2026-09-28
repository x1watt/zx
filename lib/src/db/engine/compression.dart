// The compression policy of zxdb trees (docs/zxdb-design.md section 3):
// the names of TreeOptions.compression and the .zx coder chains they
// stand for.
//
//   store     no coder
//   fast      LZ4 (lz4_encode.dart): point reads in microseconds
//   balanced  LZMA2 level 6
//   max       zcm, the level zcm's automatic choice gives without a time
//             budget (level 4) with its memory fitted to the machine
//   ultra     zcm's cmix preset (level 9 with the LSTM), memory fitted
//   other     an explicit chain: coders separated by '+' or spaces, each
//             as the -m switch names it ('zcm:level=7:mem=1g',
//             'BCJ+LZMA2:d=1m')
//
// Pages of 'store' and 'fast' trees are written with their chain at
// commit. The others go to the write buffer (LZ4) at commit and get their
// chain when they are folded.

import '../../codec/zcm/zcm_auto.dart';
import '../../format/zx/zx_codecs.dart';
import '../storage_api.dart';

/// The chain of the write buffer and of the database's own pages: LZ4
/// with the single probe match finder (level 1, the fastest).
const List<ZxCoderSpec> zxDbFastChain = [
  ZxCoderSpec(ZxCodecId.lz4, ZxCoderConfig(level: 1))
];

/// The chain of [compression] for page groups of about [groupBytes];
/// [fallback] names the default ('max' unless the store says otherwise).
List<ZxCoderSpec> zxDbChainFor(String? compression,
    {String fallback = 'max', int groupBytes = 256 << 10}) {
  final c = (compression ?? fallback).trim();
  switch (c.toLowerCase()) {
    case 'store':
    case 'none':
      return const [];
    case 'fast':
      return zxDbFastChain;
    case 'balanced':
      return const [ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 6))];
    case 'max':
    case 'ultra':
      final ultra = c.toLowerCase() == 'ultra';
      final choice = zcmAutoSelect(zcmProbeMachine(), groupBytes,
          timeBudgetSeconds: ultra ? 1e12 : null, allowParallel: false);
      final o = choice.options;
      final params = StringBuffer('level=${o.level}');
      if (o.memoryMiB > 0) params.write(':mem=${o.memoryMiB}m');
      if (o.lstm) params.write(':lstm');
      final info = zxCodecByName('zcm');
      if (info == null) {
        // no zcm in this build: the strongest standard codec
        return const [ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 9))];
      }
      return [
        ZxCoderSpec(
            info.id, ZxCoderConfig(level: o.level, params: params.toString()))
      ];
    default:
      try {
        return [
          for (final part in c.split(RegExp(r'[+\s]+')))
            if (part.isNotEmpty) zxParseCoder(part, 5)
        ];
      } on Exception catch (e) {
        throw ZxDbException(
            'bad compression "$c": $e', ZxDbError.syntax);
      }
  }
}

/// Whether pages of [compression] are written with their own chain at
/// commit ('store' and 'fast'), not through the write buffer.
bool zxDbFinalAtCommit(String? compression, {String fallback = 'max'}) {
  final c = (compression ?? fallback).trim().toLowerCase();
  return c == 'store' || c == 'none' || c == 'fast';
}

/// Checks a compression name (throws ZxDbException(syntax)).
void zxDbCheckCompression(String? compression) {
  if (compression == null) return;
  switch (compression.trim().toLowerCase()) {
    case 'store' || 'none' || 'fast' || 'balanced' || 'max' || 'ultra':
      return;
  }
  zxDbChainFor(compression);
}

/// Checks a page size (throws ZxDbException(constraint)).
void zxDbCheckPageSize(int? pageSize) {
  if (pageSize == null) return;
  if (pageSize < 4096 || pageSize > 65536 || (pageSize & (pageSize - 1)) != 0) {
    throw ZxDbException(
        'page size $pageSize (4096 to 65536, a power of two)',
        ZxDbError.constraint);
  }
}
