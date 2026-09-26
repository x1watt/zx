// Registration of the filter codecs (BranchRegister.cpp, BcjRegister.cpp,
// DeltaFilter.cpp, ByteSwap.cpp and Bcj2Register.cpp) and the encoder side
// property parsing (CEncoder::SetCoderProperties, WriteCoderProperties).

import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../codec.dart';
import 'bcj2.dart';
import 'bra.dart';
import 'delta.dart';
import 'filter_coder.dart';
import 'swap.dart';

/// Creates a fresh [CompressFilter] for one direction.
typedef CompressFilterFactory = CompressFilter Function(bool encoding);

/// A [FilterCoder] built from a filter factory.
class SimpleFilterCoder implements FilterCoder {
  final CompressFilterFactory _factory;
  @override
  final Uint8List props;
  SimpleFilterCoder(this._factory, [Uint8List? props])
      : props = props ?? Uint8List(0);

  @override
  InStream encoder(InStream input) =>
      FilterReader(input, _factory(true), encodeMode: true);

  @override
  InStream decoder(InStream input) => FilterReader(input, _factory(false));
}

const _unsupported = SevenZipException(
    'Unsupported filter properties', SevenZipError.unsupportedMethod);

BranchConvFunc? _braFunc(int methodId, bool encoding) {
  switch (methodId) {
    case MethodId.ppc:
      return encoding ? z7BranchConvPpcEnc : z7BranchConvPpcDec;
    case MethodId.ia64:
      return encoding ? z7BranchConvIa64Enc : z7BranchConvIa64Dec;
    case MethodId.arm:
      return encoding ? z7BranchConvArmEnc : z7BranchConvArmDec;
    case MethodId.armt:
      return encoding ? z7BranchConvArmtEnc : z7BranchConvArmtDec;
    case MethodId.sparc:
      return encoding ? z7BranchConvSparcEnc : z7BranchConvSparcDec;
    case MethodId.arm64:
      return encoding ? z7BranchConvArm64Enc : z7BranchConvArm64Dec;
    case MethodId.riscv:
      return encoding ? z7BranchConvRiscvEnc : z7BranchConvRiscvDec;
  }
  return null;
}

/// Alignment mask of the start offset (REGISTER_FILTER_E_BRANCH).
int _pcAlignment(int methodId) => methodId == MethodId.arm64 ? 3 : 1;

InStream _checkOneInput(List<InStream> inputs) {
  if (inputs.length != 1) {
    throw const SevenZipException(
        'Wrong number of coder streams', SevenZipError.unsupportedMethod);
  }
  return inputs[0];
}

/// Registers the decoders of BCJ, BCJ2, PPC, IA64, ARM, ARMT, SPARC, ARM64,
/// RISCV, Delta, SWAP2 and SWAP4.
void registerFilterCodecs(Map<int, DecoderFactory> reg) {
  // NBcj::CCoder2 has no ICompressSetDecoderProperties2, nor have the old
  // NBranch::CCoder filters: 7zDecode.cpp fails if properties are present.
  InStream noProps(CompressFilter Function() f, Uint8List props,
      List<InStream> inputs, int? outSize) {
    if (props.isNotEmpty) throw _unsupported;
    return FilterReader(_checkOneInput(inputs), f(), outSize: outSize);
  }

  reg[MethodId.bcj] = (props, inputs, outSize, ctx) =>
      noProps(() => BcjFilter(false), props, inputs, outSize);
  for (final id in const [
    MethodId.ppc,
    MethodId.ia64,
    MethodId.arm,
    MethodId.armt,
    MethodId.sparc,
  ]) {
    final func = _braFunc(id, false)!;
    reg[id] = (props, inputs, outSize, ctx) =>
        noProps(() => BranchFilter(func), props, inputs, outSize);
  }

  // NBranch::CDecoder::SetDecoderProperties2 (ARM64, RISCV)
  for (final id in const [MethodId.arm64, MethodId.riscv]) {
    final func = _braFunc(id, false)!;
    final alignment = _pcAlignment(id);
    reg[id] = (props, inputs, outSize, ctx) {
      var val = 0;
      if (props.isNotEmpty) {
        if (props.length != 4) throw _unsupported;
        val = getUint32LE(props, 0);
        if ((val & alignment) != 0) throw _unsupported;
      }
      return FilterReader(_checkOneInput(inputs), BranchFilter(func, val),
          outSize: outSize);
    };
  }

  // NDelta::CDecoder::SetDecoderProperties2
  reg[MethodId.delta] = (props, inputs, outSize, ctx) {
    if (props.length != 1) throw _unsupported;
    return FilterReader(
        _checkOneInput(inputs), DeltaFilter(false, props[0] + 1),
        outSize: outSize);
  };

  reg[MethodId.swap2] = (props, inputs, outSize, ctx) =>
      noProps(() => ByteSwap2Filter(), props, inputs, outSize);
  reg[MethodId.swap4] = (props, inputs, outSize, ctx) =>
      noProps(() => ByteSwap4Filter(), props, inputs, outSize);

  reg[MethodId.bcj2] = bcj2DecoderFactory;
}

/// Creates the encoder side [FilterCoder] for [methodId], or null when the
/// method is not a single stream filter handled here (BCJ2 has its own
/// entry point, [bcj2Encode]).
///
/// [methodProps] are the -m switch parameters by name, as SplitParam gives
/// them: '' is the default property (for example "Delta:4" gives
/// {'': '4'}), 'offset' the branch start offset. They go through
/// CMethodProps::SetParam; 'mt' and 'x' are added as optional properties,
/// as the archive handlers add them (AddProp32). Invalid properties throw
/// [InvalidArgException] (E_INVALIDARG in 7-Zip).
FilterCoder? createFilterEncoder(
    int methodId, Map<String, String> methodProps) {
  final props = <CoderProp>[];
  methodProps.forEach((name, value) {
    final p = parseMethodParam(name, value);
    if (p.id == CoderPropId.numThreads || p.id == CoderPropId.level) {
      p.isOptional = true;
    }
    props.add(p);
  });
  return createFilterEncoderFromProps(methodId, props);
}

/// Creates the encoder side [FilterCoder] for [methodId] from coder
/// properties in the order ICompressSetCoderProperties receives them (the
/// method's CProps, then kReduceSize), or null when the method is not a
/// single stream filter handled here. Throws [InvalidArgException].
FilterCoder? createFilterEncoderFromProps(
    int methodId, List<CoderProp> props) {
  switch (methodId) {
    case MethodId.bcj:
    case MethodId.ppc:
    case MethodId.ia64:
    case MethodId.arm:
    case MethodId.armt:
    case MethodId.sparc:
    case MethodId.swap2:
    case MethodId.swap4:
      // These coders have no ICompressSetCoderProperties: SetCoderProps2
      // (7zEncode.cpp) fails when there are non optional properties.
      for (final p in props) {
        if (!p.isOptional && p.id != CoderPropId.reduceSize) {
          throw InvalidArgException(
              'Property ${p.id} is not supported by ${methodNames[methodId]}');
        }
      }
      if (methodId == MethodId.bcj) {
        return SimpleFilterCoder((enc) => BcjFilter(enc));
      }
      if (methodId == MethodId.swap2) {
        return SimpleFilterCoder((enc) => ByteSwap2Filter());
      }
      if (methodId == MethodId.swap4) {
        return SimpleFilterCoder((enc) => ByteSwap4Filter());
      }
      final encFunc = _braFunc(methodId, true)!;
      final decFunc = _braFunc(methodId, false)!;
      return SimpleFilterCoder((enc) => BranchFilter(enc ? encFunc : decFunc));

    case MethodId.arm64:
    case MethodId.riscv:
      // NBranch::CEncoder::SetCoderProperties
      var pc = 0;
      final alignment = _pcAlignment(methodId);
      for (final p in props) {
        if (p.id == CoderPropId.defaultProp ||
            p.id == CoderPropId.branchOffset) {
          if (p.value.vt != VarType.ui4) {
            throw InvalidArgException('Bad branch offset: ${p.value.value}');
          }
          pc = p.value.intValue;
          if ((pc & alignment) != 0) {
            throw InvalidArgException('Unaligned branch offset: $pc');
          }
        }
      }
      // NBranch::CEncoder::WriteCoderProperties
      final wprops = Uint8List(pc == 0 ? 0 : 4);
      if (pc != 0) setUint32LE(wprops, 0, pc);
      final encFunc = _braFunc(methodId, true)!;
      final decFunc = _braFunc(methodId, false)!;
      final pcInit = pc;
      return SimpleFilterCoder(
          (enc) => BranchFilter(enc ? encFunc : decFunc, pcInit), wprops);

    case MethodId.delta:
      // NDelta::CEncoder::SetCoderProperties
      var delta = 1;
      for (final p in props) {
        if (p.id >= CoderPropId.reduceSize) continue;
        if (p.value.vt != VarType.ui4) {
          throw InvalidArgException('Bad Delta property: ${p.value.value}');
        }
        final v = p.value.intValue;
        switch (p.id) {
          case CoderPropId.defaultProp:
            if (v < 1 || v > 256) {
              throw InvalidArgException('Invalid Delta distance: $v');
            }
            delta = v;
          case CoderPropId.numThreads:
          case CoderPropId.level:
            break;
          default:
            throw InvalidArgException(
                'Property ${p.id} is not supported by Delta');
        }
      }
      final d = delta;
      // NDelta::CEncoder::WriteCoderProperties
      return SimpleFilterCoder(
          (enc) => DeltaFilter(enc, d), Uint8List.fromList([d - 1]));
  }
  return null;
}
