// The "b" command: UI/Common/Bench.cpp of the LZMA SDK (the LZMA benchmark
// with its data generator, rating formulas and output format, the CPU
// frequency estimate and the hash benchmark) and Console/BenchCon.cpp.
//
// The port runs every benchmark in one thread: the -mmt value is accepted,
// but the benchmark threads are always 1 (Dart isolates would not share
// the buffers the way the C threads do).

import '../host/io.dart';
import 'dart:typed_data';

import '../codec/lzma/lzma_coder.dart';
import '../common/method_props.dart';
import '../crypto/sha256.dart';
import '../format/handler_out.dart' show getRamSize;
import '../io/streams.dart';
import '../util/crc.dart';
import 'common.dart';
import 'console.dart';
import 'std_stream.dart';

const int _kComplexInCommands = 1 << 34;
const int _kComplexInMs = 4000;
const int _kBenchmarkUsageMultBits = 16;
const int _kBenchmarkUsageMult = 1 << _kBenchmarkUsageMultBits;
const int _kNumHashDictBits = 17;
const int _kOldLzmaDictBits = 32;
const int _kAdditionalSize = 1 << 16;
const int _kCompressedAdditionalSize = 1 << 10;
const int _kBenchMinDicLogSize = 18;
const int _kSubBits = 8;

// SetComplexCommandsMs
int _setComplexCommandsMs(int complexInMs, bool isSpecifiedFreq, int cpuFreq) {
  var complexInCommands = _kComplexInCommands;
  const kMinFreq = 1000000 * 4;
  const kMaxFreq = 1000000 * 20000;
  if (cpuFreq < kMinFreq && !isSpecifiedFreq) cpuFreq = kMinFreq;
  if (cpuFreq < kMaxFreq || isSpecifiedFreq) {
    if (complexInMs != 0) {
      complexInCommands = complexInMs * cpuFreq ~/ 1000;
    } else {
      complexInCommands = cpuFreq >> 2;
    }
  }
  return complexInCommands;
}

// Benchmark_GetUsage_Percents
int _getUsagePercents(int usage) =>
    (100 * usage + _kBenchmarkUsageMult ~/ 2) ~/ _kBenchmarkUsageMult;

/// CBaseRandomGenerator.
class _BaseRandomGenerator {
  int _a1 = 0;
  int _a2 = 0;
  final int salt;
  _BaseRandomGenerator([this.salt = 0]) {
    init();
  }
  void init() {
    _a1 = 362436069;
    _a2 = 521288629;
  }

  int getRnd() {
    _a1 = (36969 * (_a1 & 0xffff) + (_a1 >> 16)) & 0xFFFFFFFF;
    _a2 = (18000 * (_a2 & 0xffff) + (_a2 >> 16)) & 0xFFFFFFFF;
    return (salt ^ (((_a1 << 16) + _a2) & 0xFFFFFFFF)) & 0xFFFFFFFF;
  }
}

// RandGen_BufAfterPad
void _randGenBufAfterPad(Uint8List buf, int size) {
  final rg = _BaseRandomGenerator();
  for (var i = 0; i < size; i += 4) {
    final v = rg.getRnd();
    buf[i] = v;
    buf[i + 1] = v >> 8;
    buf[i + 2] = v >> 16;
    buf[i + 3] = v >> 24;
  }
}

/// CBenchRandomGenerator.
class _BenchRandomGenerator {
  late Uint8List buf;

  void alloc(int size) => buf = Uint8List(size);

  // GenerateSimpleRandom
  void generateSimpleRandom(int salt) {
    final rg = _BaseRandomGenerator(salt);
    for (var i = 0; i < buf.length; i++) {
      buf[i] = rg.getRnd();
    }
  }

  // GenerateLz
  void generateLz(int dictBits, int salt) {
    final rg = _BaseRandomGenerator(salt);
    var pos = 0;
    var rep0 = 1;
    final bufSize = buf.length;
    final b = buf;
    var posBits = 1;
    var r = 0;
    int getVal(int numBits) {
      final val = r & ((1 << numBits) - 1);
      r >>= numBits;
      return val;
    }

    int getLen() {
      final len = getVal(2);
      return getVal(1 + len);
    }

    while (pos < bufSize) {
      r = rg.getRnd();
      if (getVal(1) == 0 || pos < 1024) {
        b[pos++] = r & 0xFF;
      } else {
        var len = 1 + getLen();
        if (getVal(3) != 0) {
          len += getLen();
          while ((1 << posBits) < pos) {
            posBits++;
          }
          var numBitsMax = dictBits;
          if (numBitsMax > posBits) numBitsMax = posBits;
          const kAddBits = 6;
          var numLogBits = 5;
          if (numBitsMax <= (1 << 4) - 1 + kAddBits) numLogBits = 4;
          for (;;) {
            final ppp = getVal(numLogBits) + kAddBits;
            r = rg.getRnd();
            if (ppp > numBitsMax) continue;
            rep0 = r & ((1 << ppp) - 1);
            if (rep0 < pos) break;
            r = rg.getRnd();
          }
          rep0++;
        }
        {
          final rem = bufSize - pos;
          if (len > rem) len = rem;
        }
        var dest = pos;
        var src = dest - rep0;
        pos += len;
        for (var i = 0; i < len; i++) {
          b[dest++] = b[src++];
        }
      }
    }
  }
}

/// The process CPU time in clock ticks (times(): utime + stime).
int _processTicks() {
  try {
    final stat = File('/proc/self/stat').readAsStringSync();
    final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    return int.parse(rest[11]) + int.parse(rest[12]);
  } on Object {
    return 0;
  }
}

final Stopwatch _clock = Stopwatch()..start();

// GetTimeCount (gettimeofday in us)
int _getTimeCount() => _clock.elapsedMicroseconds;

// GetFreq
const int _kFreq = 1000000;

// GetUserFreq: sysconf(_SC_CLK_TCK)
const int _kUserFreq = 100;

/// CBenchInfo.
class BenchInfo {
  int globalTime = 0;
  int globalFreq = 0;
  int userTime = 0;
  int userFreq = 0;
  int unpackSize = 0;
  int packSize = 0;
  int numIterations = 0;

  BenchInfo copy() => BenchInfo()
    ..globalTime = globalTime
    ..globalFreq = globalFreq
    ..userTime = userTime
    ..userFreq = userFreq
    ..unpackSize = unpackSize
    ..packSize = packSize
    ..numIterations = numIterations;

  // GetUsage
  int getUsage() {
    var userFreq = this.userFreq;
    var globalTime = this.globalTime;
    if (userFreq == 0) userFreq = 1;
    if (globalTime == 0) globalTime = 1;
    final v = (userTime / userFreq) *
        (globalFreq / globalTime) *
        _kBenchmarkUsageMult;
    return _getUInt64FromDouble(v);
  }

  // GetRatingPerUsage
  int getRatingPerUsage(int rating) {
    if (userTime == 0) return 0;
    var globalFreq = this.globalFreq;
    if (globalFreq == 0) globalFreq = 1;
    final v = (globalTime / globalFreq) * (userFreq / userTime) * rating;
    return _getUInt64FromDouble(v);
  }

  // GetSpeed
  int getSpeed(int numUnits) => _myMultDiv64(numUnits, globalFreq, globalTime);

  int getUnpackSizeSpeed() => getSpeed(unpackSize * numIterations);
}

// Get_UInt64_from_double
int _getUInt64FromDouble(double v) {
  const kMaxVal = 1 << 62;
  if (v > kMaxVal) return kMaxVal;
  if (v.isNaN || v < 0) return 0;
  return v.toInt();
}

// MyMultDiv64
int _myMultDiv64(int m1, int m2, int d) {
  if (d == 0) d = 1;
  return _getUInt64FromDouble(m1.toDouble() * m2.toDouble() / d.toDouble());
}

// GetLogSize
int _getLogSize(int size) {
  var i = 0;
  for (;;) {
    i++;
    size >>= 1;
    if (size == 0) break;
  }
  return i;
}

// GetLogSize_Sub
int _getLogSizeSub(int size) {
  if (size <= 1) return 0;
  final i = _getLogSize(size) - 1;
  int v;
  if (i <= _kSubBits) {
    v = (size << (_kSubBits - i)) & 0xFFFFFFFF;
  } else {
    v = (size >> (i - _kSubBits)) & 0xFFFFFFFF;
  }
  return (i << _kSubBits) + (v & ((1 << _kSubBits) - 1));
}

// GetNumCommands_from_Size_and_Complexity
int _getNumCommands(int size, int complexity) =>
    complexity >= 0 ? size * complexity : size ~/ (-complexity);

/// CBenchProps.
class _BenchProps {
  bool lzmaRatingMode = false;
  int encComplex = 0;
  int decComplexCompr = 0;
  int decComplexUnc = 0;

  // SetLzmaCompexity
  void setLzmaCompexity() {
    encComplex = 1200;
    decComplexUnc = 4;
    decComplexCompr = 190;
    lzmaRatingMode = true;
  }

  int getNumCommandsEnc(int unpackSize) {
    const kMinSize = 100;
    if (unpackSize < kMinSize) unpackSize = kMinSize;
    return _getNumCommands(unpackSize, encComplex);
  }

  int getNumCommandsDec(int packSize, int unpackSize) =>
      _getNumCommands(packSize, decComplexCompr) +
      _getNumCommands(unpackSize, decComplexUnc);

  // GetRating_Enc
  int getRatingEnc(int dictSize, int elapsedTime, int freq, int size) {
    if (dictSize < (1 << _kBenchMinDicLogSize)) {
      dictSize = 1 << _kBenchMinDicLogSize;
    }
    var encComplex = this.encComplex;
    if (lzmaRatingMode) {
      final t = (_getLogSizeSub(dictSize) - (_kBenchMinDicLogSize << _kSubBits)) &
          0xFFFFFFFF;
      encComplex = 870 + (((t * t * 5) & 0xFFFFFFFF) >> (2 * _kSubBits));
    }
    final numCommands = _getNumCommands(size, encComplex);
    return _myMultDiv64(numCommands, freq, elapsedTime);
  }

  // GetRating_Dec
  int getRatingDec(int elapsedTime, int freq, int outSize, int inSize,
      int numIterations) {
    final numCommands = getNumCommandsDec(inSize, outSize) * numIterations;
    return _myMultDiv64(numCommands, freq, elapsedTime);
  }
}

/// CTotalBenchRes.
class _TotalBenchRes {
  int numIterations2 = 0;
  int rating = 0;
  int usage = 0;
  int rpu = 0;
  int speed = 0;

  void init() {
    numIterations2 = 0;
    rating = 0;
    usage = 0;
    rpu = 0;
    speed = 0;
  }

  // Generate_From_BenchInfo
  void generateFromBenchInfo(BenchInfo info) {
    speed = info.getUnpackSizeSpeed();
    usage = info.getUsage();
    rpu = info.getRatingPerUsage(rating);
  }

  // Mult_For_Weight
  void multForWeight(int weight) {
    numIterations2 *= weight;
    rpu *= weight;
    rating *= weight;
    usage *= weight;
    speed *= weight;
  }

  // Update_With_Res
  void updateWithRes(_TotalBenchRes r) {
    rating += r.rating;
    usage += r.usage;
    rpu += r.rpu;
    speed += r.speed;
    numIterations2 += r.numIterations2;
  }

  _TotalBenchRes copy() => _TotalBenchRes()..updateWithRes(this);
}

/// IBenchPrintCallback over a console stream (CPrintBenchCallback).
class _PrintCallback {
  final StdOutStream so;
  _PrintCallback(this.so);
  void print(String s) => so.write(s);
  void newLine() {
    so.write('\n');
    so.flush();
  }

  void checkBreak() => checkBreak2();
}

// PrintNumber
void _printNumber(_PrintCallback f, int value, int size) {
  final s = u64ToString(value);
  size++;
  f.print(size > s.length ? s.padLeft(size) : ' $s');
}

const int _kFieldSizeSmallName = 4;
const int _kFieldSizeSpeed = 9;
const int _kFieldSizeUsage = 5;
const int _kFieldSizeRU = 6;
const int _kFieldSizeRating = 6;
const int _kFieldSizeEU = 5;
const int _kFieldSizeEffec = 5;
const int _kFieldSizeCrcSpeed = 8;
const int _kFieldSizeTotalSize = 4 +
    _kFieldSizeSpeed +
    _kFieldSizeUsage +
    _kFieldSizeRU +
    _kFieldSizeRating;
const int _kFieldSizeEUAndEffec = 2 + _kFieldSizeEU + _kFieldSizeEffec;

void _printRating(_PrintCallback f, int rating, int size) =>
    _printNumber(f, (rating + 500000) ~/ 1000000, size);

void _printPercents(_PrintCallback f, int val, int divider, int size) {
  var v = 0;
  if (divider != 0) v = (val * 100 + divider ~/ 2) ~/ divider;
  _printNumber(f, v, size);
}

void _printChars(_PrintCallback f, String c, int size) => f.print(c * size);
void _printSpaces(_PrintCallback f, int size) => _printChars(f, ' ', size);

void _printUsage(_PrintCallback f, int usage, int size) =>
    _printNumber(f, _getUsagePercents(usage), size);

// PrintResults
void _printResults0(_PrintCallback f, int usage, int rpu, int rating,
    bool showFreq, int cpuFreq) {
  _printUsage(f, usage, _kFieldSizeUsage);
  _printRating(f, rpu, _kFieldSizeRU);
  _printRating(f, rating, _kFieldSizeRating);
  if (showFreq) {
    if (cpuFreq == 0) {
      _printSpaces(f, _kFieldSizeEUAndEffec);
    } else {
      _printPercents(
          f, rating, cpuFreq * usage ~/ _kBenchmarkUsageMult, _kFieldSizeEU);
      _printPercents(f, rating, cpuFreq, _kFieldSizeEffec);
    }
  }
}

void _printResults(_PrintCallback? f, BenchInfo info, int weight, int rating,
    bool showFreq, int cpuFreq, _TotalBenchRes? res) {
  final t = _TotalBenchRes()
    ..rating = rating
    ..numIterations2 = 1;
  t.generateFromBenchInfo(info);
  if (f != null) {
    if (t.speed != 0) {
      _printNumber(f, t.speed ~/ 1024, _kFieldSizeSpeed);
    } else {
      _printSpaces(f, 1 + _kFieldSizeSpeed);
    }
    _printResults0(f, t.usage, t.rpu, rating, showFreq, cpuFreq);
  }
  if (res != null) {
    t.multForWeight(weight);
    res.updateWithRes(t);
  }
}

// PrintTotals
void _printTotals(_PrintCallback f, bool showFreq, int cpuFreq, bool showSpeed,
    _TotalBenchRes res) {
  final numIterations2 = res.numIterations2 != 0 ? res.numIterations2 : 1;
  final speed = res.speed ~/ numIterations2;
  if (showSpeed && speed != 0) {
    _printNumber(f, speed ~/ 1024, _kFieldSizeSpeed);
  } else {
    _printSpaces(f, 1 + _kFieldSizeSpeed);
  }
  _printResults0(f, res.usage ~/ numIterations2, res.rpu ~/ numIterations2,
      res.rating ~/ numIterations2, showFreq, cpuFreq);
}

void _printLeft(_PrintCallback f, String s, int size) {
  f.print(s);
  final n = size - s.length;
  if (n > 0) _printSpaces(f, n);
}

void _printRight(_PrintCallback f, String s, int size) {
  final n = size - s.length;
  if (n > 0) _printSpaces(f, n);
  f.print(s);
}

// PrintRequirements
void _printRequirements(_PrintCallback f, String sizeString, bool sizeDefined,
    int size, String threadsString, int numThreads) {
  f.print('RAM ');
  f.print(sizeString);
  if (sizeDefined) {
    _printNumber(f, size >> 20, 6);
  } else {
    f.print('      ?');
  }
  f.print(' MB');
  f.print(',  # ');
  f.print(threadsString);
  _printNumber(f, numThreads, 3);
}

const String _kSep = '  | ';

/// CBenchCallbackToPrint.
class _BenchCallbackToPrint {
  bool needPrint = true;
  bool use2Columns = false;
  bool showFreq = false;
  int nameFieldSize = 0;
  int encodeWeight = 1;
  int decodeWeight = 1;
  int cpuFreq = 0;
  int dictSize = 0;
  late _PrintCallback file;
  final _BenchProps benchProps = _BenchProps();
  final _TotalBenchRes encodeRes = _TotalBenchRes();
  final _TotalBenchRes decodeRes = _TotalBenchRes();
  final List<BenchInfo> benchInfoResults = [BenchInfo(), BenchInfo()];

  void init() {
    encodeRes.init();
    decodeRes.init();
  }

  void setEncodeResult(BenchInfo info, bool finalRes) {
    file.checkBreak();
    if (finalRes) benchInfoResults[0] = info.copy();
    if (finalRes && needPrint) {
      final rating = benchProps.getRatingEnc(dictSize, info.globalTime,
          info.globalFreq, info.unpackSize * info.numIterations);
      _printResults(
          file, info, encodeWeight, rating, showFreq, cpuFreq, encodeRes);
      if (!use2Columns) file.newLine();
    }
  }

  void setDecodeResult(BenchInfo info, bool finalRes) {
    file.checkBreak();
    if (finalRes) benchInfoResults[1] = info.copy();
    if (finalRes && needPrint) {
      final rating = benchProps.getRatingDec(info.globalTime, info.globalFreq,
          info.unpackSize, info.packSize, info.numIterations);
      if (use2Columns) {
        file.print(_kSep);
      } else {
        _printSpaces(file, nameFieldSize);
      }
      final info2 = info.copy()
        ..unpackSize = info.unpackSize * info.numIterations
        ..packSize = info.packSize * info.numIterations
        ..numIterations = 1;
      _printResults(
          file, info2, decodeWeight, rating, showFreq, cpuFreq, decodeRes);
    }
  }
}

/// CBenchInfoCalc.
class _BenchInfoCalc {
  final BenchInfo benchInfo = BenchInfo();
  int _userStart = 0;

  // SetStartTime
  void setStartTime() {
    benchInfo.globalFreq = _kFreq;
    benchInfo.userFreq = _kUserFreq;
    benchInfo.globalTime = _getTimeCount();
    benchInfo.userTime = 0;
    _userStart = _processTicks();
  }

  // SetFinishTime
  BenchInfo setFinishTime() {
    final dest = benchInfo.copy();
    dest.globalTime = _getTimeCount() - benchInfo.globalTime;
    dest.userTime = _processTicks() - _userStart;
    return dest;
  }
}

/// A sequential input over a buffer (CBenchmarkInStream).
class _BenchInStream implements InStream {
  late Uint8List _data;
  int _pos = 0;
  int _size = 0;
  void init(Uint8List data, int size) {
    _data = data;
    _size = size;
    _pos = 0;
  }

  bool get wasFinished => _pos == _size;

  @override
  int read(Uint8List buf, int off, int len) {
    const kMaxBlockSize = 1 << 20;
    if (len > kMaxBlockSize) len = kMaxBlockSize;
    final remain = _size - _pos;
    if (len > remain) len = remain;
    if (len != 0) buf.setRange(off, off + len, _data, _pos);
    _pos += len;
    return len;
  }
}

/// CBenchmarkOutStream.
class _BenchOutStream implements OutStream {
  late Uint8List buf;
  int pos = 0;
  bool realCopy = true;
  bool calcCrc = false;
  int crc = 0xFFFFFFFF;

  void init(bool realCopy, bool calcCrc) {
    crc = 0xFFFFFFFF;
    this.realCopy = realCopy;
    this.calcCrc = calcCrc;
    pos = 0;
  }

  @override
  void write(Uint8List data, int off, int size) {
    var curSize = buf.length - pos;
    if (curSize > size) curSize = size;
    if (curSize != 0) {
      if (realCopy) buf.setRange(pos, pos + curSize, data, off);
      if (calcCrc) crc = crc32Update(crc, data, off, off + curSize);
      pos += curSize;
    }
    if (curSize != size) throw const SystemException(HRes.eFail);
  }

  @override
  void flush() {}
}

// GetBenchCompressedSize
int _getBenchCompressedSize(int bufferSize) =>
    _kCompressedAdditionalSize + bufferSize + bufferSize ~/ 16;

// GetNumIterations
int _getNumIterations(int numCommands, int complexInCommands) {
  if (numCommands < (1 << 4)) numCommands = 1 << 4;
  final res = complexInCommands ~/ numCommands;
  return res == 0 ? 1 : res;
}

/// The single thread MethodBench for LZMA: returns S_OK, S_FALSE (decoding
/// error) or throws.
int _methodBench(
    int complexInCommands,
    OneMethodInfo method2,
    int uncompressedDataSize,
    Uint8List? fileData,
    int generateDictBits,
    _PrintCallback printCallback,
    _BenchCallbackToPrint callback,
    _BenchProps benchProps) {
  final method = method2.copy();
  if (method.methodName.toLowerCase() != 'lzma') {
    throw const SystemException(HRes.eNotImpl);
  }
  // oldLzmaBenchMode with one thread
  if (method.getNumThreads() < 0) method.addPropNumThreads(1);

  final kBufferSize = uncompressedDataSize;
  final rg = _BenchRandomGenerator();
  Uint8List data;
  var crc = 0;
  if (fileData != null) {
    data = fileData;
    crc = Crc32.of(fileData, 0, uncompressedDataSize);
  } else {
    rg.alloc(kBufferSize);
    if (generateDictBits == 0) {
      rg.generateSimpleRandom(0);
    } else {
      rg.generateLz(generateDictBits, 0);
    }
    data = rg.buf;
    crc = Crc32.of(data);
  }

  final outStream = _BenchOutStream()
    ..buf = Uint8List(_getBenchCompressedSize(kBufferSize));
  final checkCrcEnc = benchProps.encComplex > 30;

  // ---------- Encode ----------
  final encProps = method.toCoderProperties(dataSizeReduce: kBufferSize);
  var props = Uint8List(0);
  final numIterationsEnc = _getNumIterations(
      benchProps.getNumCommandsEnc(uncompressedDataSize), complexInCommands);

  final bpi = _BenchInfoCalc();
  bpi.benchInfo.numIterations = 1;
  bpi.setStartTime();
  var compressedSize = 0;
  final inStream = _BenchInStream();
  const mask = 0;
  final useCrc = mask < numIterationsEnc && checkCrcEnc;
  var crcPrevDefined = false;
  var crcPrev = 0;
  var prev = 0;
  var unpackSizeTotal = 0;
  for (var i = numIterationsEnc; i != 0;) {
    i--;
    if (unpackSizeTotal - prev >= (1 << 26)) {
      prev = unpackSizeTotal;
      printCallback.checkBreak();
    }
    final calcCrc = useCrc && ((i & mask) == 0);
    outStream.init(true, calcCrc);
    inStream.init(data, kBufferSize);
    final enc = LzmaCompressor.fromCoderProps(encProps);
    props = enc.props;
    enc.encode(inStream, outStream);
    if (!inStream.wasFinished) throw const SystemException(HRes.eFail);
    if (compressedSize != outStream.pos) {
      if (compressedSize != 0) throw const SystemException(HRes.eFail);
      compressedSize = outStream.pos;
    }
    if (calcCrc) {
      final crc2 = outStream.crc ^ 0xFFFFFFFF;
      if (crcPrevDefined && crcPrev != crc2) {
        throw const SystemException(HRes.eFail);
      }
      crcPrev = crc2;
      crcPrevDefined = true;
    }
    unpackSizeTotal += kBufferSize;
  }
  {
    final info = bpi.setFinishTime()
      ..unpackSize = kBufferSize
      ..packSize = compressedSize
      ..numIterations = numIterationsEnc;
    callback.setEncodeResult(info, true);
  }

  // ---------- Decode ----------
  final numIterationsDec = _getNumIterations(
      benchProps.getNumCommandsDec(compressedSize, kBufferSize),
      complexInCommands);
  final bpd = _BenchInfoCalc();
  bpd.benchInfo.numIterations = 1;
  bpd.setStartTime();
  final checkCrcAlways =
      benchProps.decComplexCompr + benchProps.decComplexUnc > 30 ||
          fileData != null;
  final decBuf = Uint8List(1 << 16);
  prev = 0;
  var decUnpacked = 0;
  for (var i = 0; i < numIterationsDec; i++) {
    if (decUnpacked - prev >= (1 << 26)) {
      printCallback.checkBreak();
      prev = decUnpacked;
    }
    final calcCrc = checkCrcAlways || i == 0;
    inStream.init(outStream.buf, compressedSize);
    final dec = LzmaDecoderStream(props, inStream, outSize: kBufferSize);
    var c = 0xFFFFFFFF;
    var outPos = 0;
    try {
      for (;;) {
        final n = dec.read(decBuf, 0, decBuf.length);
        if (n == 0) break;
        if (calcCrc) c = crc32Update(c, decBuf, 0, n);
        outPos += n;
      }
    } on SevenZipException {
      return HRes.sFalse;
    }
    if (!inStream.wasFinished) return HRes.sFalse;
    if (dec.inProcessed != compressedSize) return HRes.sFalse;
    if (outPos != kBufferSize) return HRes.sFalse;
    if (calcCrc && (c ^ 0xFFFFFFFF) != crc) return HRes.sFalse;
    decUnpacked += kBufferSize;
  }
  {
    final info = bpd.setFinishTime()
      ..unpackSize = kBufferSize
      ..packSize = compressedSize
      ..numIterations = numIterationsDec;
    callback.setDecodeResult(info, true);
  }
  return HRes.sOk;
}

// GetDictSizeFromLog
int _getDictSizeFromLog(int dictSizeLog) => 1 << dictSizeLog;

const int _kLzmaMaxDictSize = 15 << 28;

// GetLZMAUsage
int _getLzmaUsage(bool multiThread, int btMode, int dict) {
  if (dict == 0) dict = 1;
  if (dict > _kLzmaMaxDictSize) dict = _kLzmaMaxDictSize;
  var hs = (dict - 1) & 0xFFFFFFFF;
  hs |= hs >> 1;
  hs |= hs >> 2;
  hs |= hs >> 4;
  hs |= hs >> 8;
  hs >>= 1;
  hs |= 0xFFFF;
  if (hs > (1 << 24)) hs >>= 1;
  hs++;
  hs += 1 << 16;
  const kBlockSizeMax = 0x100000000 - (1 << 16);
  var blockSize = dict + (1 << 16) + (multiThread ? (1 << 20) : 0);
  blockSize += blockSize >> (blockSize < (1 << 30) ? 1 : 2);
  if (blockSize >= kBlockSizeMax) blockSize = kBlockSizeMax;
  var son = dict;
  if (btMode != 0) son *= 2;
  return (hs + son) * 4 + blockSize + (1 << 20) + (multiThread ? (6 << 20) : 0);
}

/// GetBenchMemoryUsage.
int getBenchMemoryUsage(int numThreads, int level, int dictionary, bool totalBench) {
  final kBufferSize = dictionary + _kAdditionalSize;
  final kCompressedBufferSize = _getBenchCompressedSize(kBufferSize);
  if (level < 0) level = 5;
  final algo = level < 5 ? 0 : 1;
  final btMode = algo == 0 ? 0 : 1;
  var numBigThreads = numThreads;
  final lzmaMt = totalBench || (numThreads > 1 && btMode != 0);
  if (btMode != 0) {
    if (!totalBench && lzmaMt) numBigThreads ~/= 2;
  }
  return (kBufferSize +
          kCompressedBufferSize +
          _getLzmaUsage(lzmaMt, btMode, dictionary) +
          (2 << 20)) *
      numBigThreads;
}

// CrcInternalTest
bool _crcInternalTest() {
  const kBufSize = 1 << 11;
  const kCheckSize = 1 << 6;
  final buf = Uint8List(kBufSize);
  _randGenBufAfterPad(buf, kBufSize);
  var sum = 0;
  for (var i = 0; i < kBufSize - kCheckSize * 2; i += kCheckSize - 1) {
    for (var j = 0; j < kCheckSize; j++) {
      sum = ((sum << 11) | (sum >> 21)) & 0xFFFFFFFF;
      sum = (sum + Crc32.of(buf, i + j, i + j + j)) & 0xFFFFFFFF;
    }
  }
  return sum == 0x28462c7c;
}

// CountCpuFreq: YY7 is 64 times "sum += val; sum ^= val;"
int _countCpuFreq(int sum, int num, int val) {
  for (var i = 0; i < num; i++) {
    for (var k = 0; k < 8; k++) {
      sum = ((sum + val) & 0xFFFFFFFF) ^ val;
      sum = ((sum + val) & 0xFFFFFFFF) ^ val;
      sum = ((sum + val) & 0xFFFFFFFF) ^ val;
      sum = ((sum + val) & 0xFFFFFFFF) ^ val;
      sum = ((sum + val) & 0xFFFFFFFF) ^ val;
      sum = ((sum + val) & 0xFFFFFFFF) ^ val;
      sum = ((sum + val) & 0xFFFFFFFF) ^ val;
      sum = ((sum + val) & 0xFFFFFFFF) ^ val;
    }
  }
  return sum;
}

const int _kNumFreqCommands = 128;
int _gBenchCpuFreqTemp = 1;

// Print_Pow
void _printPow(_PrintCallback f, int pow) =>
    _printLeft(f, '$pow:', _kFieldSizeSmallName);

// GetCompiler (the port runs on the Dart VM)
String _getCompiler() {
  final v = Platform.version;
  final sp = v.indexOf(' ');
  return 'Dart ${sp < 0 ? v : v.substring(0, sp)}';
}

// GetSystemInfoText (the parts the port can read)
String _getSystemInfoText() {
  final sb = StringBuffer();
  String read(String p) {
    try {
      return File(p).readAsStringSync().trim();
    } on Object {
      return '';
    }
  }

  final os = Platform.operatingSystem;
  final rel = read('/proc/sys/kernel/osrelease');
  final ver = read('/proc/sys/kernel/version');
  final v = Platform.version;
  final arch = v.contains('_x64')
      ? 'x86_64'
      : v.contains('_arm64')
          ? 'aarch64'
          : v.contains('_riscv64')
              ? 'riscv64'
              : v.contains('_ia32')
                  ? 'i686'
                  : '';
  sb.write('${os[0].toUpperCase()}${os.substring(1)}');
  if (rel.isNotEmpty) sb.write(' : $rel');
  if (ver.isNotEmpty) sb.write(' : $ver');
  if (arch.isNotEmpty) sb.write(' : $arch');
  sb.write('\n');
  try {
    for (final line in File('/proc/cpuinfo').readAsLinesSync()) {
      if (line.startsWith('model name')) {
        sb.write('${line.substring(line.indexOf(':') + 1).trim()}\n');
        break;
      }
    }
  } on Object {
    // no cpuinfo
  }
  return sb.toString();
}

/// Bench: returns S_OK or S_FALSE (a decoding error); throws for errors.
int _bench(_PrintCallback f, List<MapEntry<String, String>> props,
    int numIterations, bool multiDict) {
  if (!_crcInternalTest()) throw const SystemException(HRes.eFail);

  // the port runs one benchmark thread; numCPUs is shown only
  final numCPUs = Platform.numberOfProcessors;
  final ram = getRamSize();
  final ramSizeDefined = ram != null;
  final ramSize = ram ?? (8 << 29);

  var needSetComplexity = false;
  var testTimeMs = _kComplexInMs;
  var startDicLog = 22;
  var specifiedFreq = 0;
  var complexInCommands = _kComplexInCommands;
  var isFixedDict = false;
  var startDicLogDefined = false;
  final method = OneMethodInfo();

  for (final p in props) {
    f.print(' ${p.key}');
    if (p.value.isNotEmpty) f.print('=${p.value}');
  }
  if (props.isNotEmpty) f.newLine();

  for (final p in props) {
    final name = p.key.toLowerCase();
    if (name == 'file') {
      throw const SystemException(HRes.eNotImpl);
    }
    final propVariant = p.value.isEmpty
        ? const PropVariant.empty()
        : parseNumberString(p.value);
    int parseU32(int def) {
      try {
        return parsePropToUInt32('', propVariant, def);
      } on InvalidArgException {
        throw const SystemException(HRes.eInvalidArg);
      }
    }

    if (name == 'time') {
      testTimeMs = parseU32(testTimeMs) * 1000;
      needSetComplexity = true;
      continue;
    }
    if (name == 'timems') {
      testTimeMs = parseU32(testTimeMs);
      needSetComplexity = true;
      continue;
    }
    if (name == 'tic') {
      final v = parseU32(0);
      if (v >= 64) throw const SystemException(HRes.eInvalidArg);
      complexInCommands = 1 << v;
      continue;
    }
    final isCurrentFixedDict = name == 'df';
    if (isCurrentFixedDict) isFixedDict = true;
    if (isCurrentFixedDict || name == 'ds') {
      startDicLog = parseU32(startDicLog);
      if (startDicLog > 32) throw const SystemException(HRes.eInvalidArg);
      startDicLogDefined = true;
      continue;
    }
    if (name == 'mts' || name == 'af') {
      parseU32(0);
      continue;
    }
    if (name == 'freq') {
      final freq32 = parseU32(0);
      if (freq32 == 0) throw const SystemException(HRes.eInvalidArg);
      specifiedFreq = freq32 * 1000000;
      f.print('freq=');
      _printNumber(f, freq32, 0);
      f.newLine();
      continue;
    }
    if (name.startsWith('mt')) {
      // the thread count is checked, the port uses one thread
      final s = name.substring(2);
      if (s != '*' && !(s.isEmpty && p.value == '*')) {
        try {
          parseMtProp2(s, propVariant, numCPUs);
        } on InvalidArgException {
          throw const SystemException(HRes.eInvalidArg);
        }
      }
      continue;
    }
    try {
      method.parseMethodFromPropVariant(name, propVariant);
    } on InvalidArgException {
      throw const SystemException(HRes.eInvalidArg);
    }
  }

  f.print('Compiler: ${_getCompiler()}');
  f.newLine();
  f.print(_getSystemInfoText());
  f.newLine();
  f.print('1T CPU Freq (MHz):');
  {
    var numMilCommands = 1 << 6;
    if (specifiedFreq != 0) {
      while (numMilCommands > 1 && specifiedFreq < numMilCommands * 1000000) {
        numMilCommands >>= 1;
      }
    }
    for (var jj = 0;; jj++) {
      f.checkBreak();
      var start = _getTimeCount();
      var sum = start & 0xFFFFFFFF;
      sum = _countCpuFreq(sum, numMilCommands * 1000000 ~/ _kNumFreqCommands,
          _gBenchCpuFreqTemp);
      if (sum == 0xF1541213) f.print('');
      final realDelta = _getTimeCount() - start;
      start = realDelta;
      if (start == 0) start = 1;
      const freq = _kFreq;
      final mipsVal = numMilCommands * freq ~/ start;
      if (realDelta == 0) {
        f.print(' -');
      } else {
        _printNumber(f, mipsVal, 5);
      }
      if (jj >= 1) {
        var needStop = numMilCommands >= (1 << 11);
        if (start >= freq * 16) {
          f.print(' (Cmplx)');
          needSetComplexity = true;
          needStop = true;
        }
        if (needSetComplexity) {
          complexInCommands =
              _setComplexCommandsMs(testTimeMs, false, mipsVal * 1000000);
        }
        if (needStop) break;
        numMilCommands <<= 1;
      }
    }
  }

  f.newLine();
  f.newLine();
  _printRequirements(
      f, 'size: ', ramSizeDefined, ramSize, 'CPU hardware threads:', numCPUs);
  f.newLine();

  var dict = 1 << startDicLog;
  final dicSize = method.getDicSize();
  if (dicSize != null) dict = dicSize;
  final dictIsDefined = isFixedDict || dicSize != null;
  final level = method.getLevel();
  final originalMethodName = method.methodName;
  if (method.methodName.isEmpty) method.methodName = 'LZMA';

  final callback = _BenchCallbackToPrint()
    ..init()
    ..file = f;

  final methodName = method.methodName.toLowerCase();
  final hashName = methodName == 'crc' ? 'crc32' : methodName;
  if (_findBenchHasher(hashName) != null) {
    return _hashBench(f, method, hashName, dict, dictIsDefined, startDicLog,
        startDicLogDefined, numIterations, complexInCommands);
  }
  if (methodName != 'lzma') {
    // other codecs and the total benchmark (*) are not in the port
    if (originalMethodName.isNotEmpty) {
      throw const SystemException(HRes.eNotImpl);
    }
  }

  const numThreads = 1;
  if (!dictIsDefined) {
    const dicSizeLogMain = 25;
    var dicSizeLog = dicSizeLogMain;
    if (ramSizeDefined) {
      for (; dicSizeLog > _kBenchMinDicLogSize; dicSizeLog--) {
        if (getBenchMemoryUsage(numThreads, level, 1 << dicSizeLog, false) +
                (8 << 20) <=
            ramSize) {
          break;
        }
      }
    }
    dict = 1 << dicSizeLog;
  }

  _printRequirements(f, 'usage:', true,
      getBenchMemoryUsage(numThreads, level, dict, false),
      'Benchmark threads:   ', numThreads);
  f.newLine();
  f.newLine();

  callback.nameFieldSize = _kFieldSizeSmallName;
  callback.use2Columns = true;
  const showFreq = false;
  var cpuFreq = 0;
  const fileldSize = _kFieldSizeTotalSize;

  _printSpaces(f, callback.nameFieldSize);
  _printRight(f, 'Compressing', fileldSize);
  f.print(_kSep);
  _printRight(f, 'Decompressing', fileldSize);
  f.newLine();
  _printLeft(f, 'Dict', callback.nameFieldSize);
  for (var j = 0; j < 2; j++) {
    _printRight(f, 'Speed', _kFieldSizeSpeed + 1);
    _printRight(f, 'Usage', _kFieldSizeUsage + 1);
    _printRight(f, 'R/U', _kFieldSizeRU + 1);
    _printRight(f, 'Rating', _kFieldSizeRating + 1);
    if (j == 0) f.print(_kSep);
  }
  f.newLine();
  _printSpaces(f, callback.nameFieldSize);
  for (var j = 0; j < 2; j++) {
    _printRight(f, 'KiB/s', _kFieldSizeSpeed + 1);
    _printRight(f, '%', _kFieldSizeUsage + 1);
    _printRight(f, 'MIPS', _kFieldSizeRU + 1);
    _printRight(f, 'MIPS', _kFieldSizeRating + 1);
    if (j == 0) f.print(_kSep);
  }
  f.newLine();
  f.newLine();

  if (specifiedFreq != 0) cpuFreq = specifiedFreq;
  callback.benchProps.setLzmaCompexity();

  if (startDicLog < _kBenchMinDicLogSize) startDicLog = _kBenchMinDicLogSize;

  for (var i = 0; i < numIterations; i++) {
    var pow = dict < _getDictSizeFromLog(startDicLog)
        ? _kBenchMinDicLogSize
        : startDicLog;
    if (!multiDict) pow = 32;
    while (_getDictSizeFromLog(pow) > dict && pow > 0) {
      pow--;
    }
    for (; _getDictSizeFromLog(pow) <= dict; pow++) {
      _printPow(f, pow);
      callback.dictSize = 1 << pow;
      final method2 = method.copy();
      if (method2.methodName.toLowerCase() == 'lzma') {
        method2.parseMethodFromPropVariant('d', PropVariant.ui4(pow));
      }
      var uncompressedDataSize = callback.dictSize;
      if (uncompressedDataSize >= (1 << 18)) {
        uncompressedDataSize += _kAdditionalSize;
      }
      final res = _methodBench(complexInCommands, method2, uncompressedDataSize,
          null, _kOldLzmaDictBits, f, callback, callback.benchProps);
      f.newLine();
      if (res != HRes.sOk) return res;
      if (!multiDict) break;
    }
  }

  _printChars(f, '-', callback.nameFieldSize + fileldSize);
  f.print(_kSep);
  _printChars(f, '-', fileldSize);
  f.newLine();
  _printLeft(f, 'Avr:', callback.nameFieldSize);
  _printTotals(f, showFreq, cpuFreq, true, callback.encodeRes);
  f.print(_kSep);
  _printTotals(f, showFreq, cpuFreq, true, callback.decodeRes);
  f.newLine();
  _printLeft(f, 'Tot:', callback.nameFieldSize);
  final midRes = callback.encodeRes.copy()..updateWithRes(callback.decodeRes);
  _printTotals(f, showFreq, cpuFreq, false, midRes);
  f.newLine();
  return HRes.sOk;
}

// ---------------------------------------------------------------------------
// Hash benchmark (CrcBench with one thread)

/// (complexity, checksum at 2^17 bytes) of g_Hash for the port's hashers.
(int, int)? _findBenchHasher(String name) {
  switch (name) {
    case 'crc32':
      return (256, 0x21e207bb);
    case 'crc64':
      return (256, 0x41b901d1);
    case 'sha256':
      return (5100, 0x7913ba03);
  }
  return null;
}

class _BenchHasher {
  final String name;
  _BenchHasher(this.name);
  int _crc = 0xFFFFFFFF;
  Crc64 _c64 = Crc64();
  final Sha256 _sha = Sha256();

  void init() {
    _crc = 0xFFFFFFFF;
    _c64 = Crc64();
    _sha.init();
  }

  void update(Uint8List b, int off, int len) {
    switch (name) {
      case 'crc32':
        _crc = crc32Update(_crc, b, off, off + len);
      case 'crc64':
        _c64.update(b, off, off + len);
      default:
        _sha.update(b, off, len);
    }
  }

  Uint8List finalDigest() {
    switch (name) {
      case 'crc32':
        final v = _crc ^ 0xFFFFFFFF;
        return Uint8List(4)
          ..[0] = v
          ..[1] = v >> 8
          ..[2] = v >> 16
          ..[3] = v >> 24;
      case 'crc64':
        return _c64.bytes;
      default:
        return _sha.digest();
    }
  }
}

// CrcBench with one thread: returns (hresult, speed, usage).
(int, int, int) _crcBench(int complexInCommands, int bufferSize,
    int complexity, int? checkSum, _BenchHasher hasher, _PrintCallback f) {
  final bsize = bufferSize == 0 ? 1 : bufferSize;
  var numIterations = complexInCommands * 256 ~/ complexity ~/ bsize;
  if (numIterations == 0) numIterations = 1;

  // CCrcInfo_Base::Generate
  final size2 = (bufferSize + 3) & ~3;
  final data = Uint8List(size2);
  _randGenBufAfterPad(data, size2);

  final calc = _BenchInfoCalc()..setStartTime();
  // CCrcInfo_Base::CrcProcess
  var prev = 0, cur = 0;
  int? check = checkSum;
  var k = numIterations;
  do {
    hasher.init();
    hasher.update(data, 0, bufferSize);
    final d = hasher.finalDigest();
    final hash32 = Uint8List(64)..setRange(0, d.length, d);
    var sum = 0;
    for (var j = 0; j < d.length; j += 4) {
      sum = ((sum << 11) | (sum >> 21)) & 0xFFFFFFFF;
      sum = (sum +
              (hash32[j] |
                  (hash32[j + 1] << 8) |
                  (hash32[j + 2] << 16) |
                  (hash32[j + 3] << 24))) &
          0xFFFFFFFF;
    }
    if (check != null) {
      if (sum != check) return (HRes.sFalse, 0, 0);
    } else {
      check = sum;
    }
    cur += bufferSize;
    if (cur - prev >= (1 << 30)) {
      prev = cur;
      f.checkBreak();
    }
  } while (--k != 0);
  final info = calc.setFinishTime();
  final unpSize = numIterations * bufferSize;
  info
    ..unpackSize = unpSize
    ..packSize = unpSize
    ..numIterations = 1;
  f.checkBreak();
  return (HRes.sOk, info.getSpeed(unpSize), info.getUsage());
}

// Bench_BW_Print_Usage_Speed
void _bwPrintUsageSpeed(_PrintCallback f, int usage, int speed) {
  _printUsage(f, usage, _kFieldSizeUsage);
  _printNumber(f, speed ~/ 1000000, _kFieldSizeCrcSpeed);
}

int _hashBench(
    _PrintCallback f,
    OneMethodInfo method,
    String hashName,
    int dict,
    bool dictIsDefined,
    int startDicLog,
    bool startDicLogDefined,
    int numIterations,
    int complexInCommands) {
  const numThreads = 1;
  var dict64 = dict;
  if (!dictIsDefined) dict64 = 1 << 27;
  final (complexity, checkSum) = _findBenchHasher(hashName)!;
  {
    var usage = 1 << 20;
    final bufSize = dict64;
    usage += numThreads * bufSize * 1;
    _printRequirements(
        f, 'usage:', true, usage, 'Benchmark threads:   ', numThreads);
  }
  f.newLine();
  for (var line = 0; line < 3; line++) {
    f.newLine();
    f.print(line == 0 ? 'THRD' : line == 1 ? '    ' : 'Size');
    if (line == 0) {
      _printNumber(f, 1, 1 + _kFieldSizeUsage + _kFieldSizeCrcSpeed);
    } else {
      _printRight(f, line == 1 ? 'Usage' : '%', _kFieldSizeUsage + 1);
      _printRight(f, line == 1 ? 'BW' : 'MB/s', _kFieldSizeCrcSpeed + 1);
    }
  }
  f.newLine();

  var numSteps = 0;
  var speedTotal = 0, usageTotal = 0;
  var pow = startDicLogDefined ? startDicLog : 10;
  final hasher = _BenchHasher(hashName);
  for (;; pow++) {
    final dataSize = 1 << pow;
    for (var iter = 0; iter < numIterations; iter++) {
      _printPow(f, pow);
      f.checkBreak();
      final (res, speed, usage) = _crcBench(complexInCommands, dataSize,
          complexity, pow == _kNumHashDictBits ? checkSum : null, hasher, f);
      if (res != HRes.sOk) return res;
      _bwPrintUsageSpeed(f, usage, speed);
      speedTotal += speed;
      usageTotal += usage;
      f.newLine();
      numSteps++;
    }
    if (dataSize >= dict64) break;
  }
  if (numSteps != 0) {
    f.print('Avg:');
    _bwPrintUsageSpeed(f, usageTotal ~/ numSteps, speedTotal ~/ numSteps);
    f.newLine();
  }
  return HRes.sOk;
}

/// BenchCon.
int benchCon(List<MapEntry<String, String>> props, int numIterations,
    StdOutStream so) {
  final f = _PrintCallback(so);
  final r = _bench(f, props, numIterations, true);
  so.flush();
  return r;
}
