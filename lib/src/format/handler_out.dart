// The generic writing side of the archive handlers:
// CPP/7zip/Archive/Common/HandlerOut.h and HandlerOut.cpp of the LZMA SDK
// (ParseSizeString, CCommonMethodProps, CMultiMethodProps,
// CHandlerTimeOptions), plus GetRamSize (Windows/System.cpp). The 7z and xz
// handlers build on it; the 7z specific COutHandler stays in
// sevenz/handler_out.dart.

import '../host/io.dart';

import '../common/method_props.dart';

/// GetRamSize (Windows/System.cpp): total RAM from /proc/meminfo, or null
/// when it can not be read.
int? getRamSize() {
  try {
    final f = File('/proc/meminfo');
    if (!f.existsSync()) return null;
    for (final line in f.readAsLinesSync()) {
      if (line.startsWith('MemTotal:')) {
        final parts = line.split(RegExp(r'\s+'));
        return int.parse(parts[1]) * 1024;
      }
    }
  } on Object {
    return null;
  }
  return null;
}

/// ParseSizeString (HandlerOut.cpp). Returns null for bad input.
int? parseSizeString(String s, PropVariant prop, int percentsBase) {
  if (s.isEmpty) {
    switch (prop.vt) {
      case VarType.ui4:
      case VarType.ui8:
        return prop.intValue;
      case VarType.bstr:
        s = prop.stringValue;
      default:
        return null;
    }
  } else if (prop.vt != VarType.empty) {
    return null;
  }
  var percentMode = false;
  var i = 0;
  if (s.isNotEmpty && s[0].toLowerCase() == 'p') {
    percentMode = true;
    i++;
  }
  final (v, n) = convertStringToUInt64(s, i);
  if (n == 0) return null;
  final endPos = i + n;
  final c = endPos < s.length ? s[endPos] : '';
  if (percentMode) {
    if (c.isNotEmpty) return null;
    return calcFromValPercents(percentsBase, v);
  }
  if (c.isEmpty) return v;
  if (endPos + 1 != s.length) return null;
  if (c == '%') return calcFromValPercents(percentsBase, v);
  int numBits;
  switch (c.toLowerCase()) {
    case 'b':
      numBits = 0;
    case 'k':
      numBits = 10;
    case 'm':
      numBits = 20;
    case 'g':
      numBits = 30;
    case 't':
      numBits = 40;
    default:
      return null;
  }
  final val2 = v << numBits;
  if ((val2 >> numBits) != v) return null;
  return val2;
}

/// CBoolPair.
class BoolPair {
  bool val = false;
  bool def = false;
  void init() {
    val = false;
    def = false;
  }
}

// PROPVARIANT_to_BoolPair
void propVariantToBoolPair(PropVariant prop, BoolPair dest) {
  dest.val = propVariantToBool(prop);
  dest.def = true;
}

/// k_PropVar_TimePrec_* values (7zTypes.h) accepted by -mtp.
abstract final class TimePrec {
  static const prec0 = 0;
  static const base = 16;
  static const highPrec = 1 << 14;
  static const prec100ns = base + 7;
}

/// CHandlerTimeOptions.
class HandlerTimeOptions {
  final BoolPair writeMTime = BoolPair();
  final BoolPair writeATime = BoolPair();
  final BoolPair writeCTime = BoolPair();
  int prec = -1;

  HandlerTimeOptions() {
    init();
  }

  void init() {
    writeMTime.init();
    writeMTime.val = true;
    writeATime.init();
    writeCTime.init();
    prec = -1;
  }

  /// Parse: returns true when [name] was a time option.
  bool parse(String name, PropVariant prop) {
    final n = name.toLowerCase();
    if (n == 'tm') {
      propVariantToBoolPair(prop, writeMTime);
      return true;
    }
    if (n == 'ta') {
      propVariantToBoolPair(prop, writeATime);
      return true;
    }
    if (n == 'tc') {
      propVariantToBoolPair(prop, writeCTime);
      return true;
    }
    if (n.startsWith('tp')) {
      prec = parsePropToUInt32(name.substring(2), prop, 0);
      return true;
    }
    return false;
  }
}

/// CCommonMethodProps (HandlerOut.h).
class CommonMethodProps {
  int numThreads = 1;
  int numProcessors = 1;
  bool numThreadsWasForced = false;
  bool memUsageWasSet = false;
  int memUsageCompress = 0;
  int memUsageDecompress = 0;
  int memAvail = 0;

  CommonMethodProps() {
    initCommon();
  }

  // InitCommon
  void initCommon() {
    numThreadsWasForced = false;
    numProcessors = numThreads = Platform.numberOfProcessors;
    var mem = 8 << 28; // sizeof(size_t) << 28
    memAvail = mem;
    memUsageCompress = mem;
    memUsageDecompress = mem;
    final ram = getRamSize();
    memUsageWasSet = ram != null;
    if (ram != null) {
      mem = ram;
      memAvail = mem;
      // 80% - is auto usage limit in handlers
      memUsageCompress = calcFromValPercentsLess100(mem, 80);
      memUsageDecompress = mem ~/ 32 * 17;
    }
  }

  // SetCommonProperty: returns true when processed.
  bool setCommonProperty(String name, PropVariant value) {
    final lower = name.toLowerCase();
    if (lower.startsWith('mt')) {
      numThreads = numProcessors;
      numThreadsWasForced = false;
      final (n, force) = parseMtProp2(name.substring(2), value, numThreads);
      numThreads = n;
      numThreadsWasForced = force;
      return true;
    }
    if (lower.startsWith('memuse')) {
      final v = parseSizeString(name.substring(6), value, memAvail);
      if (v == null) invalidArg('Bad memuse value');
      memUsageDecompress = v;
      memUsageCompress = v;
      memUsageWasSet = true;
      return true;
    }
    return false;
  }
}

/// CMultiMethodProps (HandlerOut.h).
class MultiMethodProps extends CommonMethodProps {
  int _level = -1;
  int _analysisLevel = -1;
  int crcSize = 4;
  List<OneMethodInfo> methods = [];
  OneMethodInfo filterMethod = OneMethodInfo();
  bool autoFilter = true;

  MultiMethodProps() {
    _initMulti();
  }

  // InitMulti
  void _initMulti() {
    _level = -1;
    _analysisLevel = -1;
    crcSize = 4;
    autoFilter = true;
  }

  // CMultiMethodProps::Init
  void init() {
    initCommon();
    _initMulti();
    methods = [];
    filterMethod = OneMethodInfo();
  }

  // GetLevel
  int getLevel() => _level == -1 ? 5 : _level;

  // GetAnalysisLevel
  int getAnalysisLevel() => _analysisLevel;

  // GetNumEmptyMethods
  int getNumEmptyMethods() {
    var i = 0;
    for (; i < methods.length; i++) {
      if (!methods[i].isEmpty) break;
    }
    return i;
  }

  // SetGlobalLevelTo
  void setGlobalLevelTo(OneMethodInfo m) {
    if (_level != -1 && m.findProp(CoderPropId.level) < 0) {
      m.addProp32(CoderPropId.level, _level);
    }
  }

  // SetMethodThreadsTo_IfNotFinded
  static void setMethodThreadsToIfNotFinded(MethodProps m, int numThreads) {
    if (m.findProp(CoderPropId.numThreads) < 0) {
      m.addProp32(CoderPropId.numThreads, numThreads);
    }
  }

  // SetMethodThreadsTo_Replace
  static void setMethodThreadsToReplace(MethodProps m, int numThreads) {
    final i = m.findProp(CoderPropId.numThreads);
    if (i >= 0) {
      m.props[i].value = PropVariant.ui4(numThreads);
      return;
    }
    m.addProp32(CoderPropId.numThreads, numThreads);
  }

  // CMultiMethodProps::SetProperty
  void setProperty(String name, PropVariant value) {
    name = name.toLowerCase();
    if (name.isEmpty) invalidArg();
    if (name[0] == 'x') {
      name = name.substring(1);
      _level = 9;
      _level = parsePropToUInt32(name, value, _level);
      return;
    }
    if (name.startsWith('yx')) {
      name = name.substring(2);
      _analysisLevel = parsePropToUInt32(name, value, 9);
      return;
    }
    if (name.startsWith('crc')) {
      name = name.substring(3);
      crcSize = 4;
      crcSize = parsePropToUInt32(name, value, crcSize);
      return;
    }
    if (setCommonProperty(name, value)) return;
    var (number, index) = parseStringToUInt32(name);
    final realName = name.substring(index);
    if (index == 0) {
      if (name == 'f') {
        try {
          autoFilter = propVariantToBool(value);
          return;
        } on InvalidArgException {
          // not a boolean: a filter method
        }
        if (value.vt != VarType.bstr) invalidArg();
        filterMethod.parseMethodFromPropVariant('', value);
        return;
      }
      number = 0;
    }
    if (number > 64) invalidArg();
    for (var j = methods.length; j <= number; j++) {
      methods.add(OneMethodInfo());
    }
    methods[number].parseMethodFromPropVariant(realName, value);
  }
}
