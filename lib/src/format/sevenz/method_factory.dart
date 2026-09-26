// Encoder factory for the 7z handler: the part of CreateCoder.cpp that the
// 7z encoder uses (FindMethod_Index, CreateCoder_Id with encode = true and
// SetCoderProps2 of 7zEncode.cpp).
//
// A 7z method id plus its coder properties (CProps, as parsed from
// "-m0=LZMA2:d=64m:fb=64") is turned into a [CoderEncoder]. The codec
// directories register their factories into [encoderRegistry]; the 7z
// handler only depends on the shapes below.

import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../codec/copy.dart';
import '../../codec/filters/bcj2.dart';
import '../../codec/filters/filters.dart';
import '../../codec/lzma/lzma_coder.dart';
import '../../codec/ppmd/ppmd_coder.dart';
import '../../codec/registry.dart';
import '../../crypto/seven_zip_aes.dart';
import '../../io/streams.dart';
import '../../common/method_props.dart';

/// Options passed to encoder factories (what CEncoder::CreateMixerCoder
/// hands to a coder besides its properties).
class EncoderContext {
  /// The 7zAES password (ICryptoSetPassword), null when not encrypting.
  final String? password;

  /// Threads allowed for this coder (ICompressSetCoderMt), see
  /// CMethodFull::NumThreads.
  final int threads;
  final ProgressCallback? progress;

  const EncoderContext({this.password, this.threads = 1, this.progress});
}

/// One coder of a 7z folder in the encode direction. A factory creates it
/// once per CEncoder (one per group of files with the same method), then it
/// is used for every folder of that group, like 7-Zip's mixer coders.
sealed class CoderEncoder {
  /// The coder properties for the folder header, read after coding
  /// (FillProps_from_Coder).
  Uint8List get props;

  /// ICompressSetCoderPropertiesOpt with kExpectedDataSize, called before
  /// each folder.
  void setExpectedDataSize(int expectedDataSize) {}
}

/// A filter (BCJ, ARM..., Delta, SWAP): one input, one output, pull.
class FilterCoderEncoder extends CoderEncoder {
  final FilterCoder filter;
  FilterCoderEncoder(this.filter);
  @override
  Uint8List get props => filter.props;
}

/// A compressor (Copy, LZMA, LZMA2, PPMd): pulls its input, pushes output.
class CompressorCoderEncoder extends CoderEncoder {
  final Compressor compressor;
  final void Function(int expectedDataSize)? _onExpectedDataSize;
  CompressorCoderEncoder(this.compressor,
      {void Function(int expectedDataSize)? onExpectedDataSize})
      : _onExpectedDataSize = onExpectedDataSize;
  @override
  Uint8List get props => compressor.props;
  @override
  void setExpectedDataSize(int expectedDataSize) =>
      _onExpectedDataSize?.call(expectedDataSize);
}

/// A push encoder (7zAES). [open] is called once per folder with the output
/// (the new IV of ICryptoResetInitVector goes there); [props] are read
/// after the folder is closed.
class PushCoderEncoder extends CoderEncoder {
  final PushEncoder Function(OutStream output) open;
  PushEncoder? _last;
  PushCoderEncoder(this.open);

  PushEncoder openFolder(OutStream output) => _last = open(output);

  @override
  Uint8List get props => _last?.props ?? Uint8List(0);
}

/// Sizes of the files of a folder input (ICompressGetSubStreamSize): the
/// size of sub stream [index], or null when not known yet (S_FALSE).
typedef SubStreamSizeFunction = int? Function(int index);

/// BCJ2: one input, four outputs (main, call, jump, range coder).
/// [subStreamSize] is given when the input is the folder input stream.
typedef Bcj2EncodeFunction = void Function(InStream input, OutStream main,
    OutStream call, OutStream jump, OutStream rc,
    {SubStreamSizeFunction? subStreamSize, ProgressCallback? progress});

class Bcj2CoderEncoder extends CoderEncoder {
  final Bcj2EncodeFunction encode;
  Bcj2CoderEncoder(this.encode);
  @override
  Uint8List get props => Uint8List(0);
}

/// Creates the encoder of one method. [props] are the coder properties in
/// the order ICompressSetCoderProperties would receive them (the method's
/// CProps, then kReduceSize when known). A factory throws
/// [InvalidArgException] for bad properties (E_INVALIDARG) and
/// [SevenZipException] for unsupported ones.
typedef EncoderFactory = CoderEncoder Function(
    List<CoderProp> props, EncoderContext ctx);

/// Registry of encoders by method id.
final Map<int, EncoderFactory> encoderRegistry = {};

/// A method known to the 7z handler by name (the codec table of
/// CreateCoder.cpp restricted to 7z methods): id and number of pack
/// streams of the encoder.
class MethodInfo {
  final String name;
  final int id;
  final int numStreams;
  final bool isFilter;
  const MethodInfo(this.name, this.id, this.numStreams, this.isFilter);
}

/// The codecs of the SDK's 7zr in registration order (names as the
/// *Register.cpp files give them).
const List<MethodInfo> knownMethods = [
  MethodInfo('Copy', MethodId.copy, 1, false),
  MethodInfo('LZMA', MethodId.lzma, 1, false),
  MethodInfo('LZMA2', MethodId.lzma2, 1, false),
  MethodInfo('PPMD', MethodId.ppmd, 1, false),
  MethodInfo('BCJ', MethodId.bcj, 1, true),
  MethodInfo('BCJ2', MethodId.bcj2, 4, true),
  MethodInfo('PPC', MethodId.ppc, 1, true),
  MethodInfo('IA64', MethodId.ia64, 1, true),
  MethodInfo('ARM', MethodId.arm, 1, true),
  MethodInfo('ARMT', MethodId.armt, 1, true),
  MethodInfo('ARM64', MethodId.arm64, 1, true),
  MethodInfo('RISCV', MethodId.riscv, 1, true),
  MethodInfo('SPARC', MethodId.sparc, 1, true),
  MethodInfo('Delta', MethodId.delta, 1, true),
  MethodInfo('SWAP2', MethodId.swap2, 1, true),
  MethodInfo('SWAP4', MethodId.swap4, 1, true),
  MethodInfo('7zAES', MethodId.aes, 1, true),
];

/// FindMethod_Index (CreateCoder.cpp) with encode = true: looks the method
/// up by name (ASCII case insensitive) among the methods that have an
/// encoder. Returns null when there is none.
MethodInfo? findMethodIndex(String name) {
  final lower = name.toLowerCase();
  for (final m in knownMethods) {
    if (m.name.toLowerCase() == lower && encoderRegistry[m.id] != null) {
      return m;
    }
  }
  return null;
}

/// FindMethod (CreateCoder.cpp): the name of a method id among the codecs
/// of 7zr, or null (7-Zip then prints the id in hex).
String? findMethodName(int id) {
  for (final m in knownMethods) {
    if (m.id == id) return m.name;
  }
  return null;
}

/// CreateCoder_Id(encode = true) plus SetCoderProps2: creates the encoder
/// of [methodId] with [props]. [dataSizeReduce] is the kReduceSize hint.
CoderEncoder createEncoder(int methodId, CoderProps props,
    {int? dataSizeReduce, EncoderContext ctx = const EncoderContext()}) {
  final f = encoderRegistry[methodId];
  if (f == null) {
    throw SevenZipException(
        'Unsupported method ${findMethodName(methodId) ?? methodId.toRadixString(16)}',
        SevenZipError.unsupportedMethod);
  }
  return f(props.toCoderProperties(dataSizeReduce: dataSizeReduce), ctx);
}

/// Registers the Copy encoder (CopyRegister.cpp). Copy has no settable
/// properties: SetCoderProps2 fails for non optional ones.
void registerCopyEncoder([Map<int, EncoderFactory>? reg]) {
  (reg ?? encoderRegistry)[MethodId.copy] = (props, ctx) {
    for (final p in props) {
      if (!p.isOptional && p.id != CoderPropId.reduceSize) {
        throw const InvalidArgException('Copy method has no properties');
      }
    }
    return CompressorCoderEncoder(CopyCompressor());
  };
}

// NCompress::NBcj2::CEncoder::SetCoderProperties
int _bcj2RelatLimit(List<CoderProp> props) {
  var relatLim = bcj2EncRelatLimitDefault;
  for (final p in props) {
    if (p.id >= CoderPropId.reduceSize) continue;
    switch (p.id) {
      case CoderPropId.dictionarySize:
        if (p.value.vt != VarType.ui4) {
          throw const InvalidArgException('BCJ2: bad d value');
        }
        relatLim = p.value.intValue;
        if (relatLim > bcj2EncRelatLimitMax) {
          throw const InvalidArgException('BCJ2: d is too large');
        }
      case CoderPropId.numThreads:
      case CoderPropId.level:
        continue;
      default:
        throw const InvalidArgException('BCJ2: unsupported property');
    }
  }
  return relatLim;
}

bool _encodersRegistered = false;

/// Registers every encoder and decoder available to the 7z handler: the
/// decoders through [registerAllCodecs] (the one list of REGISTER_CODEC
/// tables), then the encoders by method id. Safe to call from every entry
/// point.
void registerSevenZipMethods() {
  registerAllCodecs();
  if (_encodersRegistered) return;
  _encodersRegistered = true;

  final enc = encoderRegistry;
  registerCopyEncoder(enc);
  enc[MethodId.lzma] = (props, ctx) {
    final c = LzmaCompressor.fromCoderProps(props);
    return CompressorCoderEncoder(c,
        onExpectedDataSize: (v) => c.expectedDataSize = v);
  };
  enc[MethodId.lzma2] = (props, ctx) {
    final c = Lzma2Compressor.fromCoderProps(props);
    return CompressorCoderEncoder(c,
        onExpectedDataSize: (v) => c.expectedDataSize = v);
  };
  enc[MethodId.ppmd] = (props, ctx) =>
      CompressorCoderEncoder(PpmdCompressor.fromCoderProps(props));
  for (final id in const [
    MethodId.bcj,
    MethodId.ppc,
    MethodId.ia64,
    MethodId.arm,
    MethodId.armt,
    MethodId.sparc,
    MethodId.arm64,
    MethodId.riscv,
    MethodId.delta,
    MethodId.swap2,
    MethodId.swap4,
  ]) {
    enc[id] = (props, ctx) {
      final f = createFilterEncoderFromProps(id, props);
      if (f == null) {
        throw SevenZipException('No encoder for ${findMethodName(id)}',
            SevenZipError.unsupportedMethod);
      }
      return FilterCoderEncoder(f);
    };
  }
  enc[MethodId.bcj2] = (props, ctx) {
    final relatLimit = _bcj2RelatLimit(props);
    return Bcj2CoderEncoder((input, main, call, jump, rc,
            {subStreamSize, progress}) =>
        bcj2Encode(input, main, call, jump, rc,
            subStreamSize: subStreamSize,
            relatLimit: relatLimit,
            progress: progress));
  };
  enc[MethodId.aes] = (props, ctx) {
    final password = ctx.password;
    if (password == null) {
      throw const SevenZipException(
          'Password is not defined', SevenZipError.wrongPassword);
    }
    return PushCoderEncoder((out) => SevenZipAesEncoder(out, password));
  };
}
