// 7zCompressionMode.h of the LZMA SDK.

import '../../common/method_props.dart';

/// CMethodFull: a method with its id, number of pack streams and props.
class MethodFull extends MethodProps {
  int id = 0;
  int numStreams = 1;
  int numThreads = 1;
  bool setNumThreads = false;

  // IsSimpleCoder
  bool get isSimpleCoder => numStreams == 1;

  MethodFull copy() {
    final m = MethodFull()
      ..id = id
      ..numStreams = numStreams
      ..numThreads = numThreads
      ..setNumThreads = setNumThreads;
    m.props.addAll(props.map((p) => p.copy()));
    return m;
  }
}

/// CBond2: output stream [outStream] of coder [outCoder] feeds coder
/// [inCoder] (encode direction, method indexes).
class Bond2 {
  int outCoder;
  int outStream;
  int inCoder;
  Bond2(this.outCoder, this.outStream, this.inCoder);
  Bond2 copy() => Bond2(outCoder, outStream, inCoder);
}

/// CCompressionMethodMode.
class CompressionMethodMode {
  List<MethodFull> methods = [];
  List<Bond2> bonds = [];

  bool defaultMethodWasInserted = false;
  bool filterWasInserted = false;
  bool passwordIsDefined = false;
  bool memoryUsageLimitWasSet = false;

  bool numThreadsWasForced = false;
  bool multiThreadMixer = true;
  int numThreads = 1;
  int numThreadGroups = 0;

  String password = '';
  int memoryUsageLimit = 1 << 30;

  // IsThereBond_to_Coder
  bool isThereBondToCoder(int coderIndex) {
    for (final b in bonds) {
      if (b.inCoder == coderIndex) return true;
    }
    return false;
  }

  // IsEmpty
  bool get isEmpty => methods.isEmpty && !passwordIsDefined;

  CompressionMethodMode copy() => CompressionMethodMode()
    ..methods = [for (final m in methods) m.copy()]
    ..bonds = [for (final b in bonds) b.copy()]
    ..defaultMethodWasInserted = defaultMethodWasInserted
    ..filterWasInserted = filterWasInserted
    ..passwordIsDefined = passwordIsDefined
    ..memoryUsageLimitWasSet = memoryUsageLimitWasSet
    ..numThreadsWasForced = numThreadsWasForced
    ..multiThreadMixer = multiThreadMixer
    ..numThreads = numThreads
    ..numThreadGroups = numThreadGroups
    ..password = password
    ..memoryUsageLimit = memoryUsageLimit;
}
