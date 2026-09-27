// The .zx codec registry (docs/zx-format.md, section 11): every codec and
// filter a coder chain can name, with its id, name, props layout, the zx
// version that introduced it, and its encoder and decoder over whole
// blocks (a block is at most 64 MiB, and coded on one isolate).
//
// Registration is open: [registerZxCodec] adds a codec (an experimental
// family in the 0x10000 range registers itself here, see
// [_registerExperimentalCodecs]). Encoders and decoders run in worker
// isolates too: the registry is filled on first use in each isolate.

import 'dart:typed_data';

import '../../codec/bzip2/bzip2_coder.dart';
import '../../codec/codec.dart';
import '../../codec/deflate/deflate_coder.dart';
import '../../codec/filters/bra.dart';
import '../../codec/filters/delta.dart';
import '../../codec/lz4/lz4.dart';
import '../../codec/lzma/lzma2_dec.dart' show lzma2DictSizeFromProp;
import '../../codec/lzma/lzma_coder.dart';
import '../../codec/lzo/lzo1x.dart';
import '../../codec/ppmd/ppmd_coder.dart';
import '../../codec/ppmd8/ppmd8_coder.dart';
import '../../codec/zcm/zcm.dart';
import '../../codec/zstd/zstd.dart';
import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../../zpaq/core/decompresser.dart' show decompressAll;
import '../../zpaq/core/io.dart' show ZBuffer, MemoryReader;
import '../../zpaq/core/method.dart' show compressBlock;
import 'zx_format.dart';

/// The encoder settings of one coder: the archive level (0 to 9) and the
/// codec parameters of the -m switch (7-Zip's syntax, "d=16m:fb=64",
/// "o=8:mem=64m", "4" for Delta:4).
class ZxCoderConfig {
  final int level;
  final String params;
  const ZxCoderConfig({this.level = 5, this.params = ''});
}

/// The output of an encoder: the packed bytes and the coder properties.
class ZxEncoded {
  final Uint8List data;
  final Uint8List props;
  const ZxEncoded(this.data, this.props);
}

/// Encodes a whole block. It may change [input].
typedef ZxEncodeFn = ZxEncoded Function(Uint8List input, ZxCoderConfig cfg);

/// Decodes a whole block: [outSize] is the size of this coder's output
/// when known (the block's unpacked size for the last coder undone, else
/// -1). It may change [payload].
typedef ZxDecodeFn = Uint8List Function(
    Uint8List payload, Uint8List props, int outSize);

/// One codec or filter of the registry.
class ZxCodecInfo {
  final int id;

  /// The name in listings and in -m switches (case does not matter).
  final String name;
  final List<String> aliases;
  final ZxVer introducedIn;

  /// A filter keeps the size (BCJ, Delta...).
  final bool isFilter;

  /// null: the codec is decode only (zx has no encoder for it).
  final ZxEncodeFn? encode;
  final ZxDecodeFn decode;

  /// The props as the Method column shows them ("LZMA2:24"...).
  final String Function(Uint8List props)? describe;

  const ZxCodecInfo(
      {required this.id,
      required this.name,
      this.aliases = const [],
      this.introducedIn = (0, 5, 0),
      this.isFilter = false,
      this.encode,
      required this.decode,
      this.describe});

  /// Codecs in 0x10000..0x1FFFF are experimental (section 11).
  bool get isExperimental => id >= 0x10000 && id <= 0x1FFFF;

  bool get canEncode => encode != null;

  /// A codec from a [Compressor] factory and a 7z style [DecoderFactory]
  /// (for codec families written as streams, for example the zcm
  /// context mixing codecs).
  factory ZxCodecInfo.fromCoders(
      {required int id,
      required String name,
      List<String> aliases = const [],
      ZxVer introducedIn = (0, 5, 0),
      Compressor Function(ZxCoderConfig cfg, int inputSize)? compressor,
      required DecoderFactory decoder,
      String Function(Uint8List props)? describe}) {
    ZxEncodeFn? enc;
    if (compressor != null) {
      enc = (input, cfg) {
        final c = compressor(cfg, input.length);
        final out = MemoryOutStream(input.length ~/ 2 + 64);
        c.encode(MemoryInStream(input), out);
        return ZxEncoded(Uint8List.fromList(out.toBytes()), c.props);
      };
    }
    return ZxCodecInfo(
        id: id,
        name: name,
        aliases: aliases,
        introducedIn: introducedIn,
        encode: enc,
        decode: (payload, props, outSize) => _readOut(
            decoder(props, [MemoryInStream(payload)],
                outSize < 0 ? null : outSize, const CoderContext()),
            outSize),
        describe: describe);
  }
}

/// Codec ids of the standard registry.
abstract final class ZxCodecId {
  static const store = 0;
  static const lzma2 = 1;
  static const lzma = 2;
  static const zstd = 3;
  static const ppmd7 = 4;
  static const ppmd8 = 5;
  static const bzip2 = 6;
  static const deflate = 7;
  static const zpaq = 8;
  static const lz4 = 9;
  static const lzo1x = 10;
  static const bcj = 0x40;
  static const arm = 0x41;
  static const armt = 0x42;
  static const arm64 = 0x43;
  static const ppc = 0x44;
  static const sparc = 0x45;
  static const ia64 = 0x46;
  static const riscv = 0x47;
  static const delta = 0x48;

  /// The start of the experimental range.
  static const experimentalFirst = 0x10000;
  static const experimentalLast = 0x1FFFF;
}

final Map<int, ZxCodecInfo> _byId = {};
final Map<String, ZxCodecInfo> _byName = {};
bool _filled = false;

void _fill() {
  if (_filled) return;
  _filled = true;
  for (final c in _standardCodecs()) {
    registerZxCodec(c);
  }
  _registerExperimentalCodecs();
}

/// Adds [c] to the registry of this isolate. Ids are never reused: a
/// second codec with the same id replaces nothing and throws.
void registerZxCodec(ZxCodecInfo c) {
  _fill();
  final old = _byId[c.id];
  if (old != null) {
    if (identical(old, c)) return;
    throw ArgumentError('zx codec id 0x${c.id.toRadixString(16)} is taken '
        'by ${old.name}');
  }
  _byId[c.id] = c;
  _byName[c.name.toLowerCase()] = c;
  for (final a in c.aliases) {
    _byName[a.toLowerCase()] = c;
  }
}

/// The codec with [id], or null.
ZxCodecInfo? zxCodecById(int id) {
  _fill();
  return _byId[id];
}

/// The codec named [name] (or one of its aliases), or null.
ZxCodecInfo? zxCodecByName(String name) {
  _fill();
  return _byName[name.toLowerCase()];
}

/// Every registered codec, by id.
List<ZxCodecInfo> zxCodecs() {
  _fill();
  return _byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
}

/// The seam for experimental codec families (ids 0x10000 to 0x1FFFF,
/// section 11 of docs/zx-format.md). A family adds its codecs here, for
/// example the context mixing codecs of lib/src/codec/zcm:
///
///   registerZxCodec(ZxCodecInfo.fromCoders(
///       id: 0x10000, name: 'zcm', introducedIn: (0, 5, 0),
///       compressor: (cfg, size) => ZcmCompressor(ZcmOptions(...)),
///       decoder: zcmDecoder));
///
/// A writer that uses an experimental codec sets min_reader_version to
/// its own version and warns (zx_writer.dart).
void _registerExperimentalCodecs() {
  // zcm, the context mixing codecs (lib/src/codec/zcm): params as
  // zcmOptionsFromString reads them ("level=3", "cmix:mem=2g", "6:lstm"),
  // the archive level (-mx) is the default zcm level.
  registerZxCodec(ZxCodecInfo.fromCoders(
      id: zcmCodecId,
      name: 'zcm',
      introducedIn: (0, 5, 0),
      compressor: (cfg, size) => ZcmCompressor(
          zcmOptionsFromString(cfg.params, level: cfg.level.clamp(1, 9)),
          inputSize: size),
      decoder: zcmDecoder,
      describe: zcmDescribe));
}

// ---------------------------------------------------------------------------
// helpers

Uint8List _readOut(InStream s, int outSize) {
  if (outSize >= 0) {
    final out = Uint8List(outSize);
    final n = readFully(s, out, 0, outSize);
    if (n != outSize) {
      throw const SevenZipException(
          'Unexpected end of data', SevenZipError.unexpectedEnd);
    }
    return out;
  }
  return Uint8List.fromList(readAll(s));
}

Uint8List _compress(Compressor c, Uint8List input) {
  final out = MemoryOutStream(input.length ~/ 2 + 256);
  c.encode(MemoryInStream(input), out);
  return Uint8List.fromList(out.toBytes());
}

List<CoderProp> _props(ZxCoderConfig cfg, {bool withLevel = true}) => [
      if (withLevel)
        CoderProp(CoderPropId.level, PropVariant.ui4(cfg.level.clamp(0, 9))),
      if (cfg.params.isNotEmpty) ...parseMethodProps(cfg.params),
    ];

String _dictName(int d) {
  for (var i = 0; i < 64; i++) {
    if (d == 1 << i) return '$i';
  }
  if (d % (1 << 20) == 0) return '${d >> 20}m';
  if (d % (1 << 10) == 0) return '${d >> 10}k';
  return '$d';
}

Never _badProps(String codec) => throw SevenZipException(
    'zx: bad properties for $codec', SevenZipError.unsupportedMethod);

// ---------------------------------------------------------------------------
// the standard codecs (introduced in zx 0.5.0)

List<ZxCodecInfo> _standardCodecs() => [
      ZxCodecInfo(
          id: ZxCodecId.store,
          name: 'store',
          aliases: const ['copy'],
          encode: (input, cfg) => ZxEncoded(input, Uint8List(0)),
          decode: (payload, props, outSize) {
            if (outSize >= 0 && payload.length != outSize) {
              throw const SevenZipException('zx: stored block size mismatch');
            }
            return payload;
          }),
      ZxCodecInfo(
          id: ZxCodecId.lzma2,
          name: 'LZMA2',
          encode: _lzma2Encode,
          decode: (payload, props, outSize) {
            if (props.length != 1 || props[0] > 40) _badProps('LZMA2');
            return _readOut(
                Lzma2DecoderStream(props[0], MemoryInStream(payload),
                    outSize: outSize < 0 ? null : outSize),
                outSize);
          },
          describe: (p) => p.length == 1 && p[0] <= 40
              ? 'LZMA2:${_dictName(lzma2DictSizeFromProp(p[0]))}'
              : 'LZMA2'),
      ZxCodecInfo(
          id: ZxCodecId.lzma,
          name: 'LZMA',
          encode: (input, cfg) {
            final ep = lzmaPropsFromCoderProps(_props(cfg));
            ep.reduceSize = input.length;
            final c = LzmaCompressor(ep);
            return ZxEncoded(_compress(c, input), c.props);
          },
          decode: (payload, props, outSize) {
            if (props.length != 5) _badProps('LZMA');
            return _readOut(
                LzmaDecoderStream(props, MemoryInStream(payload),
                    outSize: outSize < 0 ? null : outSize),
                outSize);
          },
          describe: (p) =>
              p.length == 5 ? 'LZMA:${_dictName(getUint32LE(p, 1))}' : 'LZMA'),
      ZxCodecInfo(
          id: ZxCodecId.zstd,
          name: 'zstd',
          decode: (payload, props, outSize) {
            final out = zstdDecompress(payload,
                maxOutput: outSize < 0 ? null : outSize);
            if (outSize >= 0 && out.length != outSize) {
              throw const SevenZipException('zx: zstd block size mismatch');
            }
            return out;
          }),
      ZxCodecInfo(
          id: ZxCodecId.ppmd7,
          name: 'PPMd',
          aliases: const ['PPMd7', 'PPMdH'],
          encode: (input, cfg) {
            final c = PpmdCompressor.fromCoderProps([
              ..._props(cfg),
              CoderProp(CoderPropId.reduceSize, PropVariant.ui8(input.length)),
            ]);
            return ZxEncoded(_compress(c, input), c.props);
          },
          decode: (payload, props, outSize) {
            if (props.length != 5 || outSize < 0) _badProps('PPMd');
            return _readOut(
                PpmdDecoderStream(props, MemoryInStream(payload), outSize),
                outSize);
          },
          describe: (p) => p.length == 5
              ? 'PPMd:o${p[0]}:mem${_dictName(getUint32LE(p, 1))}'
              : 'PPMd'),
      ZxCodecInfo(
          id: ZxCodecId.ppmd8,
          name: 'PPMd8',
          aliases: const ['PPMdI'],
          encode: (input, cfg) {
            final c = Ppmd8ZipCompressor.fromCoderProps([
              ..._props(cfg),
              CoderProp(CoderPropId.reduceSize, PropVariant.ui8(input.length)),
            ]);
            final all = _compress(c, input);
            // the zip stream starts with the parameter word: it is the props
            return ZxEncoded(Uint8List.sublistView(all, 2),
                Uint8List.fromList(Uint8List.sublistView(all, 0, 2)));
          },
          decode: (payload, props, outSize) {
            if (props.length != 2) _badProps('PPMd8');
            return _readOut(
                Ppmd8ZipDecoder(
                    ConcatInStream(
                        [MemoryInStream(props), MemoryInStream(payload)]),
                    outSize: outSize < 0 ? null : outSize),
                outSize);
          },
          describe: (p) {
            if (p.length != 2) return 'PPMd8';
            final w = p[0] | (p[1] << 8);
            return 'PPMd8:o${(w & 15) + 1}:mem${((w >> 4) & 0xFF) + 1}m'
                '${(w >> 12) != 0 ? ':r1' : ''}';
          }),
      ZxCodecInfo(
          id: ZxCodecId.bzip2,
          name: 'BZip2',
          encode: (input, cfg) {
            final c = Bzip2Compressor.fromCoderProps(_props(cfg));
            return ZxEncoded(_compress(c, input), Uint8List(0));
          },
          decode: (payload, props, outSize) => _readOut(
              Bzip2DecoderStream(MemoryInStream(payload),
                  outSize: outSize < 0 ? null : outSize),
              outSize)),
      ZxCodecInfo(
          id: ZxCodecId.deflate,
          name: 'Deflate',
          encode: (input, cfg) {
            final c = DeflateCompressor.fromCoderProps(_props(cfg));
            return ZxEncoded(_compress(c, input), Uint8List(0));
          },
          decode: (payload, props, outSize) => _readOut(
              InflateDecoderStream(MemoryInStream(payload),
                  outSize: outSize < 0 ? null : outSize),
              outSize)),
      ZxCodecInfo(
          id: ZxCodecId.zpaq,
          name: 'zpaq',
          encode: (input, cfg) {
            // the zpaq method: "m=<method>" or a bare level/method, else
            // the archive level 1..9 mapped to zpaq 1..5
            var method = '';
            for (final part in cfg.params.split(':')) {
              if (part.isEmpty) continue;
              method = part.startsWith('m=') ? part.substring(2) : part;
            }
            if (method.isEmpty) {
              final l = cfg.level.clamp(1, 9);
              method = '${(l + 1) ~/ 2}';
            }
            final out = ZBuffer(input.length ~/ 2 + 1024);
            compressBlock(ZBuffer.of(input), out, method, dosha1: false);
            return ZxEncoded(
                Uint8List.fromList(
                    Uint8List.sublistView(out.data, 0, out.size)),
                Uint8List(0));
          },
          decode: (payload, props, outSize) {
            final out = ZBuffer(outSize >= 0 ? outSize + 16 : 1 << 16);
            decompressAll(MemoryReader(payload), out);
            final r = Uint8List.sublistView(out.data, 0, out.size);
            if (outSize >= 0 && r.length != outSize) {
              throw const SevenZipException('zx: zpaq block size mismatch');
            }
            return r;
          }),
      ZxCodecInfo(
          id: ZxCodecId.lz4,
          name: 'LZ4',
          decode: (payload, props, outSize) => _readOut(
              Lz4FrameDecoderStream(MemoryInStream(payload)), outSize)),
      ZxCodecInfo(
          id: ZxCodecId.lzo1x,
          name: 'LZO1X',
          aliases: const ['LZO'],
          decode: (payload, props, outSize) {
            if (outSize < 0) _badProps('LZO1X');
            final out = lzo1xDecompress(payload, outSize: outSize);
            if (out.length != outSize) {
              throw const SevenZipException('zx: LZO1X block size mismatch');
            }
            return out;
          }),
      _branch(ZxCodecId.bcj, 'BCJ', const ['x86'], null),
      _branch(ZxCodecId.arm, 'ARM', const [], (true, z7BranchConvArmEnc),
          (false, z7BranchConvArmDec)),
      _branch(ZxCodecId.armt, 'ARMT', const [], (true, z7BranchConvArmtEnc),
          (false, z7BranchConvArmtDec)),
      _branch(ZxCodecId.arm64, 'ARM64', const [], (true, z7BranchConvArm64Enc),
          (false, z7BranchConvArm64Dec)),
      _branch(ZxCodecId.ppc, 'PPC', const [], (true, z7BranchConvPpcEnc),
          (false, z7BranchConvPpcDec)),
      _branch(ZxCodecId.sparc, 'SPARC', const [], (true, z7BranchConvSparcEnc),
          (false, z7BranchConvSparcDec)),
      _branch(ZxCodecId.ia64, 'IA64', const [], (true, z7BranchConvIa64Enc),
          (false, z7BranchConvIa64Dec)),
      _branch(ZxCodecId.riscv, 'RISCV', const [], (true, z7BranchConvRiscvEnc),
          (false, z7BranchConvRiscvDec)),
      ZxCodecInfo(
          id: ZxCodecId.delta,
          name: 'Delta',
          isFilter: true,
          encode: (input, cfg) {
            var dist = 1;
            final p = cfg.params;
            if (p.isNotEmpty) {
              final v = int.tryParse(p.startsWith('d=') ? p.substring(2) : p);
              if (v == null || v < 1 || v > 256) {
                throw InvalidArgException('Delta: distance must be 1..256');
              }
              dist = v;
            }
            final state = Uint8List(kDeltaStateSize);
            deltaInit(state);
            deltaEncode(state, dist, input, 0, input.length);
            return ZxEncoded(input, Uint8List.fromList([dist - 1]));
          },
          decode: (payload, props, outSize) {
            if (props.length != 1) _badProps('Delta');
            final state = Uint8List(kDeltaStateSize);
            deltaInit(state);
            deltaDecode(state, props[0] + 1, payload, 0, payload.length);
            return payload;
          },
          describe: (p) => p.length == 1 ? 'Delta:${p[0] + 1}' : 'Delta'),
    ];

// a branch filter; [enc] and [dec] are null for x86 (its own function with
// a state). Props: nothing, or a u32 start offset.
ZxCodecInfo _branch(
    int id, String name, List<String> aliases, (bool, BranchConvFunc)? enc,
    [(bool, BranchConvFunc)? dec]) {
  int startOf(Uint8List props) {
    if (props.isEmpty) return 0;
    if (props.length != 4) _badProps(name);
    return getUint32LE(props, 0);
  }

  Uint8List run(Uint8List data, int pc, bool encoding) {
    if (enc == null) {
      final st = Uint32List(1)..[0] = kBranchConvStX86StateInitVal;
      if (encoding) {
        z7BranchConvStX86Enc(data, 0, data.length, pc, st);
      } else {
        z7BranchConvStX86Dec(data, 0, data.length, pc, st);
      }
    } else {
      (encoding ? enc.$2 : dec!.$2)(data, 0, data.length, pc);
    }
    return data;
  }

  return ZxCodecInfo(
      id: id,
      name: name,
      aliases: aliases,
      isFilter: true,
      encode: (input, cfg) {
        var pc = 0;
        final p = cfg.params;
        if (p.isNotEmpty) {
          final v = int.tryParse(
              p.startsWith('offset=') ? p.substring(7) : p.replaceAll('0x', ''),
              radix: p.contains('0x') ? 16 : 10);
          if (v == null || v < 0 || v > 0xFFFFFFFF) {
            throw InvalidArgException('$name: bad start offset');
          }
          pc = v;
        }
        run(input, pc, true);
        final props = Uint8List(pc == 0 ? 0 : 4);
        if (pc != 0) setUint32LE(props, 0, pc);
        return ZxEncoded(input, props);
      },
      decode: (payload, props, outSize) => run(payload, startOf(props), false));
}

// LZMA2 with the dictionary reduced to the block (as xz does), one stream
ZxEncoded _lzma2Encode(Uint8List input, ZxCoderConfig cfg) {
  final p = lzma2PropsFromCoderProps(_props(cfg));
  p.lzmaProps.reduceSize = input.length;
  p.blockSize = lzma2BlockSizeSolid;
  p.numBlockThreadsMax = 1;
  p.numTotalThreads = 1;
  final c = Lzma2Compressor(p);
  final data = _compress(c, input);
  return ZxEncoded(data, c.props);
}

// ---------------------------------------------------------------------------
// chains

/// One coder of a chain for the writer: the codec and its config.
class ZxCoderSpec {
  final int codecId;
  final ZxCoderConfig config;
  const ZxCoderSpec(this.codecId, [this.config = const ZxCoderConfig()]);
}

/// Encodes [data] through [coders] in order; returns the payload and the
/// coders with their props. [data] may be changed.
(Uint8List, List<ZxCoder>) zxEncodeChain(
    Uint8List data, List<ZxCoderSpec> coders) {
  var d = data;
  final out = <ZxCoder>[];
  for (final c in coders) {
    final info = zxCodecById(c.codecId);
    final enc = info?.encode;
    if (info == null || enc == null) {
      throw SevenZipException(
          'zx: codec ${info?.name ?? '0x${c.codecId.toRadixString(16)}'} '
          'can not be used for writing',
          SevenZipError.unsupportedMethod);
    }
    final r = enc(d, c.config);
    d = r.data;
    out.add(ZxCoder(c.codecId, r.props));
  }
  return (d, out);
}

/// Decodes a payload through [chain] (in reverse order). [unpackedSize]
/// is the block's unpacked size.
Uint8List zxDecodeChain(Uint8List payload, ZxChain chain, int unpackedSize) {
  var d = payload;
  final cs = chain.coders;
  for (var i = cs.length - 1; i >= 0; i--) {
    final c = cs[i];
    final info = zxCodecById(c.codecId);
    if (info == null) {
      throw SevenZipException(
          'zx: unsupported codec id 0x${c.codecId.toRadixString(16)} '
          '(written by a newer zx?)',
          SevenZipError.unsupportedMethod);
    }
    // the size of this coder's output is the unpacked size when every
    // coder before it (in writing order) keeps the size
    var known = true;
    for (var j = 0; j < i; j++) {
      final f = zxCodecById(cs[j].codecId);
      if (f == null || !f.isFilter) known = false;
    }
    d = info.decode(d, c.props, known ? unpackedSize : -1);
  }
  if (d.length != unpackedSize) {
    throw const SevenZipException('zx: block size mismatch');
  }
  return d;
}

/// The Method column text of a chain ("BCJ LZMA2:24").
String zxChainName(ZxChain chain) {
  if (chain.coders.isEmpty) return 'store';
  return chain.coders.map((c) {
    final info = zxCodecById(c.codecId);
    if (info == null) return '0x${c.codecId.toRadixString(16)}';
    return info.describe?.call(c.props) ?? info.name;
  }).join(' ');
}

/// The greatest "introduced in" version of the codecs of [coders], and
/// whether one is experimental.
(ZxVer, bool) zxChainRequirements(List<ZxCoder> coders) {
  ZxVer v = (0, 5, 0);
  var experimental = false;
  for (final c in coders) {
    final info = zxCodecById(c.codecId);
    if (info == null) continue;
    if (zxCompareVersions(info.introducedIn, v) > 0) v = info.introducedIn;
    if (info.isExperimental) experimental = true;
  }
  return (v, experimental);
}

/// Parses a method switch value ("LZMA2:d=16m", "PPMd:o=8", "Delta:4",
/// "zpaq:3") into a coder spec; [level] is the archive level.
ZxCoderSpec zxParseCoder(String s, int level) {
  final colon = s.indexOf(':');
  final name = colon < 0 ? s : s.substring(0, colon);
  var params = colon < 0 ? '' : s.substring(colon + 1);
  final info = zxCodecByName(name);
  if (info == null) {
    throw InvalidArgException('zx: unknown method $name');
  }
  if (!info.canEncode) {
    throw InvalidArgException(
        'zx: ${info.name} can be read but not written by zx');
  }
  if (info.id == ZxCodecId.zpaq && params.isNotEmpty && !params.contains('=')) {
    params = 'm=$params';
  }
  return ZxCoderSpec(info.id, ZxCoderConfig(level: level, params: params));
}
