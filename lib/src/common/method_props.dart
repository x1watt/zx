// Method property parsing shared by the coders and the archive handlers:
// MethodProps.h and MethodProps.cpp of the LZMA SDK (CPP/7zip/Common), the
// NCoderPropID values of ICoder.h, the PROPVARIANT subset the property code
// uses, ConvertStringToUInt32 / ConvertStringToUInt64 of
// CPP/Common/StringToInt.cpp and ParseNumberString of
// CPP/7zip/UI/Common/SetProperties.cpp.
//
// Errors are E_INVALIDARG: [InvalidArgException], which is a
// [SevenZipException] of kind [SevenZipError.unsupported].

import '../io/streams.dart';

/// PROPVARIANT types used by the property code.
enum VarType { empty, ui4, ui8, bstr, bool_ }

/// A small PROPVARIANT: VT_EMPTY, VT_UI4, VT_UI8, VT_BSTR or VT_BOOL.
class PropVariant {
  final VarType vt;
  final int _int;
  final String? _str;
  final bool _bool;

  const PropVariant.empty()
      : vt = VarType.empty,
        _int = 0,
        _str = null,
        _bool = false;
  const PropVariant.ui4(int v)
      : vt = VarType.ui4,
        _int = v,
        _str = null,
        _bool = false;
  const PropVariant.ui8(int v)
      : vt = VarType.ui8,
        _int = v,
        _str = null,
        _bool = false;
  const PropVariant.bstr(String s)
      : vt = VarType.bstr,
        _int = 0,
        _str = s,
        _bool = false;
  const PropVariant.boolean(bool b)
      : vt = VarType.bool_,
        _int = 0,
        _str = null,
        _bool = b;

  bool get isEmpty => vt == VarType.empty;

  /// The value for VT_UI4 / VT_UI8.
  int get intValue => _int;

  /// The value for VT_BSTR.
  String get stringValue => _str ?? '';

  /// The value for VT_BOOL.
  bool get boolValue => _bool;

  /// Plain Dart value: null, int, String or bool.
  Object? get value => switch (vt) {
        VarType.empty => null,
        VarType.ui4 || VarType.ui8 => _int,
        VarType.bstr => _str,
        VarType.bool_ => _bool,
      };

  @override
  String toString() => 'PropVariant(${vt.name}: $value)';
}

/// Parses a -m switch value the way UI/Common/SetProperties.cpp does
/// (ParseNumberString): a decimal number becomes VT_UI4 (or VT_UI8 when
/// larger), anything else VT_BSTR.
PropVariant parseNumberString(String s) {
  final r = _convertStringToUInt64(s, 0);
  if (r.end != s.length || s.isEmpty) return PropVariant.bstr(s);
  if (r.value >= 0 && r.value <= 0xFFFFFFFF) return PropVariant.ui4(r.value);
  return PropVariant.ui8(r.value);
}

/// Converts one CLI property (name, value) like SetProperties.cpp: an empty
/// value with a trailing '+' or '-' in the name becomes VT_BOOL.
MapEntry<String, PropVariant> convertCliProperty(String name, String value) {
  var prop = const PropVariant.empty();
  if (value.isEmpty) {
    if (name.isNotEmpty) {
      final c = name[name.length - 1];
      if (c == '-') {
        prop = const PropVariant.boolean(false);
      } else if (c == '+') {
        prop = const PropVariant.boolean(true);
      }
      if (!prop.isEmpty) name = name.substring(0, name.length - 1);
    }
  } else {
    prop = parseNumberString(value);
  }
  return MapEntry(name, prop);
}

/// Thrown for invalid property names or values (E_INVALIDARG).
class InvalidArgException extends SevenZipException {
  const InvalidArgException(String message)
      : super(message, SevenZipError.unsupported);
  @override
  String toString() => 'InvalidArgException: $message';
}

Never invalidArg([String message = 'Invalid property']) =>
    throw InvalidArgException(message);

class _Num {
  final int value;
  final int end;
  const _Num(this.value, this.end);
}

// ConvertStringToUInt64 (StringToInt.cpp): parses decimal digits from
// [start]; stops at the first non digit or on overflow.
_Num _convertStringToUInt64(String s, int start) {
  var res = 0;
  var i = start;
  for (; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) break;
    final v = c - 0x30;
    // overflow check for unsigned 64 bits: res * 10 + v > 2^64 - 1
    if (res < 0 ||
        res > 0x1999999999999999 ||
        (res == 0x1999999999999999 && v > 5)) {
      return _Num(0, start);
    }
    res = res * 10 + v;
  }
  return _Num(res, i);
}

// ConvertStringToUInt32 (StringToInt.cpp)
_Num _convertStringToUInt32(String s, int start) {
  var res = 0;
  var i = start;
  for (; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) break;
    final v = c - 0x30;
    if (res > 0x19999999 || (res == 0x19999999 && v > 5)) {
      return _Num(0, start);
    }
    res = res * 10 + v;
  }
  return _Num(res, i);
}

/// ConvertStringToUInt64 exposed for other ports: returns (value, number of
/// characters used).
(int, int) convertStringToUInt64(String s, [int start = 0]) {
  final r = _convertStringToUInt64(s, start);
  return (r.value, r.end - start);
}

/// ConvertStringToUInt32 exposed for other ports.
(int, int) convertStringToUInt32(String s, [int start = 0]) {
  final r = _convertStringToUInt32(s, start);
  return (r.value, r.end - start);
}

// Calc_From_Val_Percents_Less100
int calcFromValPercentsLess100(int val, int percents) {
  if (percents == 0) return 0;
  if (val <= 0x7FFFFFFFFFFFFFFF ~/ percents) return val * percents ~/ 100;
  return val ~/ 100 * percents;
}

// Calc_From_Val_Percents
int calcFromValPercents(int val, int percents) {
  final q = percents ~/ 100;
  final r = percents % 100;
  var res = 0;
  if (q != 0) {
    if (val > 0x7FFFFFFFFFFFFFFF ~/ q) return 0x7FFFFFFFFFFFFFFF;
    res = val * q;
  }
  if (r != 0) {
    int v2;
    if (val <= 0x7FFFFFFFFFFFFFFF ~/ r) {
      v2 = val * r ~/ 100;
    } else {
      v2 = val ~/ 100 * r;
    }
    res += v2;
    if (res < v2) return 0x7FFFFFFFFFFFFFFF;
  }
  return res;
}

bool _equalsNoCaseAscii(String a, String b) =>
    a.length == b.length && a.toLowerCase() == b.toLowerCase();

// StringToBool
bool? stringToBool(String s) {
  if (s.isEmpty || s == '+' || _equalsNoCaseAscii(s, 'ON')) return true;
  if (s == '-' || _equalsNoCaseAscii(s, 'OFF')) return false;
  return null;
}

// PROPVARIANT_to_bool
bool propVariantToBool(PropVariant prop) {
  switch (prop.vt) {
    case VarType.empty:
      return true;
    case VarType.bool_:
      return prop.boolValue;
    case VarType.bstr:
      final r = stringToBool(prop.stringValue);
      if (r == null) invalidArg('Bad boolean value: ${prop.stringValue}');
      return r;
    default:
      invalidArg('Bad boolean value');
  }
}

/// ParseStringToUInt32: returns (number, number of digits used).
(int, int) parseStringToUInt32(String s) => convertStringToUInt32(s);

// ParsePropToUInt32: returns the new value ([resValue] when unchanged).
int parsePropToUInt32(String name, PropVariant prop, int resValue) {
  if (prop.vt == VarType.ui4) {
    if (name.isNotEmpty) invalidArg();
    return prop.intValue;
  }
  if (prop.vt != VarType.empty) invalidArg();
  if (name.isEmpty) return resValue;
  final (v, n) = parseStringToUInt32(name);
  if (n != name.length) invalidArg('Bad number: $name');
  return v;
}

/// ParseMtProp2: returns (numThreads, force).
(int, bool) parseMtProp2(String name, PropVariant prop, int numThreads) {
  var force = false;
  String s;
  if (name.isEmpty) {
    if (prop.vt == VarType.ui4) return (prop.intValue, true);
    bool? val;
    try {
      val = propVariantToBool(prop);
    } on InvalidArgException {
      val = null;
    }
    if (val != null) {
      if (!val) {
        numThreads = 1;
        force = true;
      }
      return (numThreads, force);
    }
    if (prop.vt != VarType.bstr) invalidArg();
    s = prop.stringValue;
    if (s.isEmpty) invalidArg();
  } else {
    if (prop.vt != VarType.empty) invalidArg();
    s = name;
  }
  s = s.toLowerCase();
  var i = 0;
  var v = numThreads;
  var forceLoc = true;
  while (i < s.length) {
    final c = s[i];
    if (c == 'd') {
      forceLoc = false;
      i++;
      continue;
    }
    if (c == 'u') {
      forceLoc = true;
      i++;
      continue;
    }
    var isPercent = false;
    if (c == 'p') {
      isPercent = true;
      i++;
    }
    final r = _convertStringToUInt32(s, i);
    if (r.end == i) invalidArg();
    v = r.value;
    if (isPercent) v = numThreads * v ~/ 100;
    i = r.end;
  }
  return (v, forceLoc);
}

// SetLogSizeProp
PropVariant _setLogSizeProp(int number) {
  if (number < 0 || number >= 64) invalidArg();
  if (number < 32) return PropVariant.ui4(1 << number);
  return PropVariant.ui8(1 << number);
}

// StringToDictSize
PropVariant _stringToDictSize(String s) {
  final r = _convertStringToUInt64(s, 0);
  final numDigits = r.end;
  final number = r.value;
  if (numDigits == 0 || s.length > numDigits + 1) invalidArg('Bad size: $s');
  if (s.length == numDigits) return _setLogSizeProp(number);
  int numBits;
  switch (s[numDigits].toLowerCase()) {
    case 'b':
      numBits = 0;
    case 'k':
      numBits = 10;
    case 'm':
      numBits = 20;
    case 'g':
      numBits = 30;
    default:
      invalidArg('Bad size: $s');
  }
  final range4g = 1 << (32 - numBits);
  if (number >= 0 && number < range4g) {
    return PropVariant.ui4((number << numBits) & 0xFFFFFFFF);
  }
  if (numBits == 0) return PropVariant.ui8(number);
  if (number < 0 || number >= (1 << (63 - numBits)) * 2) invalidArg();
  return PropVariant.ui8(number << numBits);
}

// PROPVARIANT_to_DictSize
PropVariant _propVariantToDictSize(PropVariant prop) {
  if (prop.vt == VarType.ui4) return _setLogSizeProp(prop.intValue);
  if (prop.vt == VarType.bstr) return _stringToDictSize(prop.stringValue);
  invalidArg();
}

/// NCoderPropID (ICoder.h).
abstract final class CoderPropId {
  static const defaultProp = 0;
  static const dictionarySize = 1;
  static const usedMemorySize = 2;
  static const order = 3;
  static const blockSize = 4;
  static const posStateBits = 5;
  static const litContextBits = 6;
  static const litPosBits = 7;
  static const numFastBytes = 8;
  static const matchFinder = 9;
  static const matchFinderCycles = 10;
  static const numPasses = 11;
  static const algorithm = 12;
  static const numThreads = 13;
  static const endMarker = 14;
  static const level = 15;
  static const reduceSize = 16;
  static const expectedDataSize = 17;
  static const blockSize2 = 18;
  static const checkSize = 19;
  static const filter = 20;
  static const memUse = 21;
  static const affinity = 22;
  static const branchOffset = 23;
  static const hashBits = 24;
  static const numThreadGroups = 25;
  static const threadGroup = 26;
  static const affinityInGroup = 27;
}

class _NameToPropId {
  final VarType varType;
  final String name;
  const _NameToPropId(this.varType, this.name);
}

// g_NameToPropID: indexed by NCoderPropID.
const List<_NameToPropId> _gNameToPropID = [
  _NameToPropId(VarType.ui4, ''),
  _NameToPropId(VarType.ui4, 'd'),
  _NameToPropId(VarType.ui4, 'mem'),
  _NameToPropId(VarType.ui4, 'o'),
  _NameToPropId(VarType.ui8, 'c'),
  _NameToPropId(VarType.ui4, 'pb'),
  _NameToPropId(VarType.ui4, 'lc'),
  _NameToPropId(VarType.ui4, 'lp'),
  _NameToPropId(VarType.ui4, 'fb'),
  _NameToPropId(VarType.bstr, 'mf'),
  _NameToPropId(VarType.ui4, 'mc'),
  _NameToPropId(VarType.ui4, 'pass'),
  _NameToPropId(VarType.ui4, 'a'),
  _NameToPropId(VarType.ui4, 'mt'),
  _NameToPropId(VarType.bool_, 'eos'),
  _NameToPropId(VarType.ui4, 'x'),
  _NameToPropId(VarType.ui8, 'reduce'),
  _NameToPropId(VarType.ui8, 'expect'),
  _NameToPropId(VarType.ui8, 'cc'),
  _NameToPropId(VarType.ui4, 'check'),
  _NameToPropId(VarType.bstr, 'filter'),
  _NameToPropId(VarType.ui8, 'memuse'),
  _NameToPropId(VarType.ui8, 'aff'),
  _NameToPropId(VarType.ui4, 'offset'),
  _NameToPropId(VarType.ui4, 'zhb'),
];

// FindPropIdExact
int _findPropIdExact(String name) {
  for (var i = 0; i < _gNameToPropID.length; i++) {
    if (_equalsNoCaseAscii(name, _gNameToPropID[i].name)) return i;
  }
  return -1;
}

// ConvertProperty: returns null on failure.
PropVariant? _convertProperty(PropVariant src, VarType varType) {
  if (varType == src.vt) return src;
  if (varType == VarType.ui8 && src.vt == VarType.ui4) {
    return PropVariant.ui8(src.intValue);
  }
  if (varType == VarType.bool_) {
    try {
      return PropVariant.boolean(propVariantToBool(src));
    } on InvalidArgException {
      return null;
    }
  }
  if (src.vt == VarType.empty) return src;
  return null;
}

// SplitParams
List<String> _splitParams(String s) {
  if (s.isEmpty) return [];
  return s.split(':');
}

// SplitParam
(String, String) _splitParam(String param) {
  final eqPos = param.indexOf('=');
  if (eqPos >= 0) {
    return (param.substring(0, eqPos), param.substring(eqPos + 1));
  }
  var i = 0;
  for (; i < param.length; i++) {
    final c = param.codeUnitAt(i);
    if (c >= 0x30 && c <= 0x39) break;
  }
  return (param.substring(0, i), param.substring(i));
}

// IsLogSizeProp
bool _isLogSizeProp(int propid) {
  switch (propid) {
    case CoderPropId.dictionarySize:
    case CoderPropId.usedMemorySize:
    case CoderPropId.blockSize:
    case CoderPropId.blockSize2:
      return true;
  }
  return false;
}

/// CProp (MethodProps.h).
class CoderProp {
  final int id;
  bool isOptional;
  PropVariant value;
  CoderProp(this.id, this.value, {this.isOptional = false});
  CoderProp copy() => CoderProp(id, value, isOptional: isOptional);
  @override
  String toString() => 'CoderProp($id, $value)';
}

/// CProps (MethodProps.h): the ordered coder properties handed to an
/// encoder (ICompressSetCoderProperties). When an id appears twice the later
/// entry wins, as when the coder applies them in order.
class CoderProps {
  final List<CoderProp> props = [];

  void clear() => props.clear();

  // AreThereNonOptionalProps
  bool get areThereNonOptionalProps {
    for (final p in props) {
      if (!p.isOptional) return true;
    }
    return false;
  }

  // AddProp32
  void addProp32(int propid, int val) =>
      props.add(CoderProp(propid, PropVariant.ui4(val), isOptional: true));

  // AddPropBool
  void addPropBool(int propid, bool val) =>
      props.add(CoderProp(propid, PropVariant.boolean(val), isOptional: true));

  // AddProp_Ascii
  void addPropAscii(int propid, String s) =>
      props.add(CoderProp(propid, PropVariant.bstr(s), isOptional: true));

  /// The properties as SetCoderProps / SetCoderProps_DSReduce_Aff pass them:
  /// every prop, then kReduceSize when [dataSizeReduce] is given.
  List<CoderProp> toCoderProperties({int? dataSizeReduce}) {
    final r = [for (final p in props) p.copy()];
    if (dataSizeReduce != null) {
      r.add(CoderProp(CoderPropId.reduceSize, PropVariant.ui8(dataSizeReduce)));
    }
    return r;
  }

  void copyFrom(CoderProps other) {
    props
      ..clear()
      ..addAll(other.props.map((p) => p.copy()));
  }
}

/// CMethodProps (MethodProps.h).
class MethodProps extends CoderProps {
  // FindProp: last index with [id], or -1.
  int findProp(int id) {
    for (var i = props.length; i != 0;) {
      if (props[--i].id == id) return i;
    }
    return -1;
  }

  // GetLevel
  int getLevel() {
    final i = findProp(CoderPropId.level);
    if (i < 0) return 5;
    if (props[i].value.vt != VarType.ui4) return 9;
    final level = props[i].value.intValue;
    return level > 9 ? 9 : level;
  }

  // Get_NumThreads
  int getNumThreads() {
    final i = findProp(CoderPropId.numThreads);
    if (i >= 0) {
      final val = props[i].value;
      if (val.vt == VarType.ui4) return val.intValue;
    }
    return -1;
  }

  // Get_DicSize: null when not defined.
  int? getDicSize() {
    final i = findProp(CoderPropId.dictionarySize);
    if (i >= 0) {
      final val = props[i].value;
      if (val.vt == VarType.ui4 || val.vt == VarType.ui8) return val.intValue;
    }
    return null;
  }

  // Get_Lzma_Algo
  int getLzmaAlgo() {
    final i = findProp(CoderPropId.algorithm);
    if (i >= 0) {
      final val = props[i].value;
      if (val.vt == VarType.ui4) return val.intValue;
    }
    return getLevel() >= 5 ? 1 : 0;
  }

  // Get_Lzma_DicSize (64-bit size_t)
  int getLzmaDicSize() {
    final v = getDicSize();
    if (v != null) return v;
    final level = getLevel();
    const sizeofSizeT = 8;
    return level <= 4
        ? 1 << (level * 2 + 16)
        : level <= sizeofSizeT ~/ 2 + 4
            ? 1 << (level + 20)
            : 1 << (sizeofSizeT ~/ 2 + 24);
  }

  // Get_Lzma_MatchFinder_IsBt
  bool getLzmaMatchFinderIsBt() {
    final i = findProp(CoderPropId.matchFinder);
    if (i >= 0) {
      final val = props[i].value;
      if (val.vt == VarType.bstr) {
        final s = val.stringValue;
        return s.isEmpty || (s.codeUnitAt(0) | 0x20) != 0x68; // 'h'
      }
    }
    return getLevel() >= 5;
  }

  // Get_Lzma_Eos
  bool getLzmaEos() {
    final i = findProp(CoderPropId.endMarker);
    if (i >= 0) {
      final val = props[i].value;
      if (val.vt == VarType.bool_) return val.boolValue;
    }
    return false;
  }

  // Are_Lzma_Model_Props_Defined
  bool areLzmaModelPropsDefined() =>
      findProp(CoderPropId.posStateBits) >= 0 ||
      findProp(CoderPropId.litContextBits) >= 0 ||
      findProp(CoderPropId.litPosBits) >= 0;

  // Get_Lzma_NumThreads
  int getLzmaNumThreads() {
    if (getLzmaAlgo() == 0) return 1;
    final numThreads = getNumThreads();
    if (numThreads >= 0) return numThreads < 2 ? 1 : 2;
    return 2;
  }

  // GetProp_BlockSize
  int getPropBlockSize(int id) {
    final i = findProp(id);
    if (i >= 0) {
      final val = props[i].value;
      if (val.vt == VarType.ui4 || val.vt == VarType.ui8) return val.intValue;
    }
    return 0;
  }

  // Get_Xz_BlockSize
  int getXzBlockSize() {
    {
      final blockSize1 = getPropBlockSize(CoderPropId.blockSize);
      final blockSize2 = getPropBlockSize(CoderPropId.blockSize2);
      // UInt64 compares: the solid value (UInt64)-1 is -1 here.
      final b1Less = _ultU64(blockSize1, blockSize2);
      final minSize = b1Less ? blockSize1 : blockSize2;
      if (minSize != 0) return minSize;
      final maxSize = b1Less ? blockSize2 : blockSize1;
      if (maxSize != 0) return maxSize;
    }
    const kMinSize = 1 << 20;
    const kMaxSize = 1 << 28;
    final dictSize = getLzmaDicSize();
    var blockSize = dictSize << 2;
    if (blockSize < kMinSize) blockSize = kMinSize;
    if (blockSize > kMaxSize) blockSize = kMaxSize;
    if (blockSize < dictSize) blockSize = dictSize;
    blockSize += kMinSize - 1;
    blockSize &= ~(kMinSize - 1);
    return blockSize;
  }

  // Get_BZip2_BlockSize
  int getBZip2BlockSize() {
    final i = findProp(CoderPropId.dictionarySize);
    if (i >= 0) {
      final val = props[i].value;
      if (val.vt == VarType.ui4) {
        var blockSize = val.intValue;
        const kDicSizeMin = 100000;
        const kDicSizeMax = 900000;
        if (blockSize < kDicSizeMin) blockSize = kDicSizeMin;
        if (blockSize > kDicSizeMax) blockSize = kDicSizeMax;
        return blockSize;
      }
    }
    final level = getLevel();
    return 100000 * (level >= 5 ? 9 : (level >= 1 ? level * 2 - 1 : 1));
  }

  // Get_Ppmd_MemSize
  int getPpmdMemSize() {
    final i = findProp(CoderPropId.usedMemorySize);
    if (i >= 0) {
      final val = props[i].value;
      if (val.vt == VarType.ui4 || val.vt == VarType.ui8) return val.intValue;
    }
    final level = getLevel();
    return 1 << (level + 19);
  }

  // Get_Lzma_MemUsage
  int getLzmaMemUsage(bool addSlidingWindowSize) {
    const kLzmaMaxDictSize = 15 << 28;
    final dicSize = getLzmaDicSize();
    final isBt = getLzmaMatchFinderIsBt();
    final dict32 = dicSize >= kLzmaMaxDictSize ? kLzmaMaxDictSize : dicSize;
    final numThreads = getLzmaNumThreads();
    var size = _getMemoryUsageLzma(dict32, isBt, numThreads);
    if (addSlidingWindowSize) {
      const kBlockSizeMax = 0x100000000 - (1 << 16);
      var blockSize = dict32 + (1 << 16) + (numThreads > 1 ? (1 << 20) : 0);
      blockSize += blockSize >> (blockSize < (1 << 30) ? 1 : 2);
      if (blockSize >= kBlockSizeMax) blockSize = kBlockSizeMax;
      size += blockSize;
    }
    return size;
  }

  void addPropLevel(int level) => addProp32(CoderPropId.level, level);
  void addPropNumThreads(int n) => addProp32(CoderPropId.numThreads, n);

  // AddProp_EndMarker_if_NotFound
  void addPropEndMarkerIfNotFound(bool eos) {
    if (findProp(CoderPropId.endMarker) < 0) {
      addPropBool(CoderPropId.endMarker, eos);
    }
  }

  // AddProp_BlockSize2
  void addPropBlockSize2(int blockSize2) {
    if (findProp(CoderPropId.blockSize2) < 0) {
      props.add(CoderProp(CoderPropId.blockSize2, PropVariant.ui8(blockSize2),
          isOptional: true));
    }
  }

  // SetParam: one "name=value" (or "name" + digits) pair.
  void setParam(String name, String value) {
    var index = _findPropIdExact(name);
    if (index < 0) {
      // 'b' was used as NCoderPropID::kBlockSize2 before v23
      if (!_equalsNoCaseAscii(name, 'b') || value.contains(':')) {
        invalidArg('Unknown method parameter: $name');
      }
      index = CoderPropId.blockSize2;
    }
    final nameToPropID = _gNameToPropID[index];
    if (_isLogSizeProp(index)) {
      props.add(CoderProp(index, _stringToDictSize(value)));
      return;
    }
    var propValue = const PropVariant.empty();
    if (nameToPropID.varType == VarType.bstr) {
      propValue = PropVariant.bstr(value);
    } else if (nameToPropID.varType == VarType.bool_) {
      final res = stringToBool(value);
      if (res == null) invalidArg('Bad boolean value: $value');
      propValue = PropVariant.boolean(res);
    } else if (value.isNotEmpty) {
      if (nameToPropID.varType == VarType.ui4) {
        final r = _convertStringToUInt32(value, 0);
        propValue = r.end == value.length
            ? PropVariant.ui4(r.value)
            : PropVariant.bstr(value);
      } else if (nameToPropID.varType == VarType.ui8) {
        final r = _convertStringToUInt64(value, 0);
        propValue = r.end == value.length
            ? PropVariant.ui8(r.value)
            : PropVariant.bstr(value);
      } else {
        propValue = PropVariant.bstr(value);
      }
    }
    final converted = _convertProperty(propValue, nameToPropID.varType);
    if (converted == null) invalidArg('Bad value for $name: $value');
    props.add(CoderProp(index, converted));
  }

  // ParseParamsFromString
  void parseParamsFromString(String srcString) {
    for (final param in _splitParams(srcString)) {
      final (name, value) = _splitParam(param);
      setParam(name, value);
    }
  }

  // ParseParamsFromPROPVARIANT
  void parseParamsFromPropVariant(String realName, PropVariant value) {
    if (realName.isEmpty) invalidArg(); // [empty]=method
    if (value.vt == VarType.empty) {
      final (name, valueStr) = _splitParam(realName);
      setParam(name, valueStr);
      return;
    }
    final index = _findPropIdExact(realName);
    if (index < 0) invalidArg('Unknown method parameter: $realName');
    final nameToPropID = _gNameToPropID[index];
    if (_isLogSizeProp(index)) {
      props.add(CoderProp(index, _propVariantToDictSize(value)));
    } else {
      final converted = _convertProperty(value, nameToPropID.varType);
      if (converted == null) invalidArg('Bad value for $realName');
      props.add(CoderProp(index, converted));
    }
  }
}

/// CMethodProps::ParseParamsFromString for callers that only need the
/// coder properties: parses "d=64m:fb=64:mf=bt4:eos" (the part after
/// "LZMA:" in a -m switch). Throws [InvalidArgException].
List<CoderProp> parseMethodProps(String s) =>
    (MethodProps()..parseParamsFromString(s)).props;

/// CMethodProps::SetParam for one (name, value) pair, as SplitParam gives
/// it. Throws [InvalidArgException].
CoderProp parseMethodParam(String name, String value) =>
    (MethodProps()..setParam(name, value)).props.single;

// GetMemoryUsage_LZMA
int _getMemoryUsageLzma(int dict, bool isBt, int numThreads) {
  var hs = (dict - 1) & 0xFFFFFFFF;
  hs |= hs >> 1;
  hs |= hs >> 2;
  hs |= hs >> 4;
  hs |= hs >> 8;
  hs >>= 1;
  if (hs >= (1 << 24)) hs >>= 1;
  hs |= (1 << 16) - 1;
  if (!isBt) hs |= (256 << 10) - 1;
  hs++;
  var size1 = hs * 4;
  size1 += dict * 4;
  if (isBt) size1 += dict * 4;
  size1 += 2 << 20;
  if (numThreads > 1 && isBt) size1 += (2 << 20) + (4 << 20);
  return size1;
}

/// COneMethodInfo (MethodProps.h): a method name and its properties, as
/// parsed from "LZMA2:d=64m:fb=64".
class OneMethodInfo extends MethodProps {
  String methodName = '';
  String propsString = '';

  @override
  void clear() {
    super.clear();
    methodName = '';
    propsString = '';
  }

  bool get isEmpty => methodName.isEmpty && props.isEmpty;

  OneMethodInfo copy() {
    final m = OneMethodInfo()
      ..methodName = methodName
      ..propsString = propsString;
    m.props.addAll(props.map((p) => p.copy()));
    return m;
  }

  // ParseMethodFromString
  void parseMethodFromString(String s) {
    methodName = '';
    final splitPos = s.indexOf(':');
    final temp = splitPos >= 0 ? s.substring(0, splitPos) : s;
    for (final c in temp.codeUnits) {
      if (c >= 0x80) invalidArg('Non ASCII method name');
    }
    methodName = temp;
    if (splitPos < 0) return;
    propsString = s.substring(splitPos + 1);
    parseParamsFromString(propsString);
  }

  // ParseMethodFromPROPVARIANT
  void parseMethodFromPropVariant(String realName, PropVariant value) {
    if (realName.isNotEmpty && !_equalsNoCaseAscii(realName, 'm')) {
      parseParamsFromPropVariant(realName, value);
      return;
    }
    // -m{N}=method
    if (value.vt != VarType.bstr) invalidArg('Method name expected');
    parseMethodFromString(value.stringValue);
  }
}

// Unsigned 64-bit a < b.
bool _ultU64(int a, int b) =>
    (a ^ 0x8000000000000000) < (b ^ 0x8000000000000000);
