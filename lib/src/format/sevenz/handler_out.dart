// The 7z handler, writing side: 7z/7zHandlerOut.cpp (COutHandler,
// SetMainMethod, SetHeaderMethod, UpdateItems, SetProperties) of the LZMA
// SDK. The generic HandlerOut.cpp part (CMultiMethodProps, ParseSizeString,
// CHandlerTimeOptions) is in ../handler_out.dart.

import 'dart:io';

import '../../codec/codec.dart';
import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import '../handler_out.dart';
import 'compression_mode.dart';
import 'handler.dart';
import 'method_factory.dart';
import 'update.dart';

/// COutHandler (7zHandler.h): the 7z options on top of CMultiMethodProps.
class OutHandler extends MultiMethodProps {
  int numSolidFiles = -1;
  int numSolidBytes = -1;
  bool numSolidBytesDefined = false;
  bool solidExtension = false;
  bool useTypeSorting = false;
  bool compressHeaders = true;
  bool encryptHeadersSpecified = false;
  bool encryptHeaders = false;
  final HandlerTimeOptions timeOptions = HandlerTimeOptions();
  final BoolPair writeAttrib = BoolPair();
  bool useMultiThreadMixer = true;
  bool removeSfxBlock = false;
  int decoderCompatibilityVersion = kDecoderCompatibilityVersion;
  List<int> enabledFilters = [];
  List<int> disabledFilters = [];

  List<Bond2> _bonds = [];

  OutHandler() {
    initProps7z();
  }

  static const int kDecoderCompatibilityVersion = 2301;

  // InitSolidFiles, InitSolidSize, InitSolid
  void _initSolid() {
    numSolidFiles = -1;
    numSolidBytes = -1;
    solidExtension = false;
    numSolidBytesDefined = false;
  }

  // InitProps7z
  void initProps7z() {
    removeSfxBlock = false;
    compressHeaders = true;
    encryptHeadersSpecified = false;
    encryptHeaders = false;
    timeOptions.init();
    writeAttrib.init();
    useMultiThreadMixer = true;
    _initSolid();
    useTypeSorting = false;
    decoderCompatibilityVersion = kDecoderCompatibilityVersion;
    enabledFilters = [];
    disabledFilters = [];
  }

  // InitProps
  void initProps() {
    init();
    initProps7z();
  }

  // SetSolidFromString
  void _setSolidFromString(String s) {
    final s2 = s.toLowerCase();
    var i = 0;
    while (i < s2.length) {
      final (v0, n) = convertStringToUInt64(s2, i);
      var v = v0;
      if (n == 0) {
        if (s2[i++] != 'e') invalidArg('Bad solid mode: $s');
        solidExtension = true;
        continue;
      }
      i += n;
      if (i == s2.length) invalidArg('Bad solid mode: $s');
      final c = s2[i++];
      if (c == 'f') {
        if (v < 1) v = 1;
        numSolidFiles = v;
      } else {
        int numBits;
        switch (c) {
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
            invalidArg('Bad solid mode: $s');
        }
        numSolidBytes = v << numBits;
        numSolidBytesDefined = true;
      }
    }
  }

  // SetSolidFromPROPVARIANT
  void _setSolidFromPropVariant(PropVariant value) {
    bool isSolid;
    switch (value.vt) {
      case VarType.empty:
        isSolid = true;
      case VarType.bool_:
        isSolid = value.boolValue;
      case VarType.bstr:
        final b = stringToBool(value.stringValue);
        if (b == null) {
          _setSolidFromString(value.stringValue);
          return;
        }
        isSolid = b;
      default:
        invalidArg();
    }
    if (isSolid) {
      _initSolid();
    } else {
      numSolidFiles = 1;
    }
  }

  static const Map<String, int> _gFilterPairs = {
    'delta': MethodId.delta,
    'arm64': MethodId.arm64,
    'riscv': MethodId.riscv,
    'swap2': MethodId.swap2,
    'swap4': MethodId.swap4,
    'bcj': MethodId.bcj,
    'bcj2': MethodId.bcj2,
    'ppc': MethodId.ppc,
    'ia64': MethodId.ia64,
    'arm': MethodId.arm,
    'armt': MethodId.armt,
    'sparc': MethodId.sparc,
  };

  static void _addToUniqueSorted(List<int> v, int id) {
    if (!v.contains(id)) {
      v.add(id);
      v.sort();
    }
  }

  /// COutHandler::SetProperty (one -m switch, name without "m").
  @override
  void setProperty(String nameSpec, PropVariant value) {
    var name = nameSpec.toLowerCase();
    if (name.isEmpty) invalidArg();
    if (name[0] == 's') {
      name = name.substring(1);
      if (name.isEmpty) {
        _setSolidFromPropVariant(value);
        return;
      }
      if (value.vt != VarType.empty) invalidArg();
      _setSolidFromString(name);
      return;
    }
    final (_, index) = parseStringToUInt32(name);
    if (index == 0) {
      if (name == 'rsfx') {
        removeSfxBlock = propVariantToBool(value);
        return;
      }
      if (name == 'hc') {
        compressHeaders = propVariantToBool(value);
        return;
      }
      if (name == 'hcf') {
        if (!propVariantToBool(value)) invalidArg();
        return;
      }
      if (name == 'he') {
        encryptHeaders = propVariantToBool(value);
        encryptHeadersSpecified = true;
        return;
      }
      if (timeOptions.parse(name, value)) {
        final p = timeOptions.prec;
        if (p != -1 &&
            p != TimePrec.prec0 &&
            p != TimePrec.highPrec &&
            p != TimePrec.prec100ns) {
          invalidArg('Unsupported time precision');
        }
        return;
      }
      if (name == 'tr') {
        propVariantToBoolPair(value, writeAttrib);
        return;
      }
      if (name == 'mtf') {
        useMultiThreadMixer = propVariantToBool(value);
        return;
      }
      if (name == 'qs') {
        useTypeSorting = propVariantToBool(value);
        return;
      }
      if (name.startsWith('yv')) {
        decoderCompatibilityVersion =
            parsePropToUInt32(name.substring(2), value, 1 << 16);
        return;
      }
      if (name.startsWith('yf')) {
        final rest = name.substring(2);
        List<int> vec;
        if (rest == 'a') {
          vec = enabledFilters;
        } else if (rest == 'd') {
          vec = disabledFilters;
        } else {
          invalidArg();
        }
        if (value.vt != VarType.bstr) invalidArg();
        final id = _gFilterPairs[value.stringValue.toLowerCase()];
        if (id == null) invalidArg('Unknown filter: ${value.stringValue}');
        _addToUniqueSorted(vec, id);
        return;
      }
    }
    super.setProperty(name, value);
  }

  // ParseBond: returns (coder, stream, rest).
  static (int, int, String) _parseBond(String s) {
    var stream = 0;
    final (coder, index) = parseStringToUInt32(s);
    if (index == 0) invalidArg();
    s = s.substring(index);
    if (s.isNotEmpty && s[0] == 's') {
      s = s.substring(1);
      final (st, idx2) = parseStringToUInt32(s);
      if (idx2 == 0) invalidArg();
      stream = st;
      s = s.substring(idx2);
    }
    return (coder, stream, s);
  }

  /// SetProperties (ISetProperties): [props] are (name, value) pairs as
  /// the -m switches give them after SetProperties.cpp conversion (see
  /// [convertCliProperty]). Throws [InvalidArgException].
  void setProperties(List<MapEntry<String, PropVariant>> props) {
    _bonds = [];
    initProps();
    for (final p in props) {
      var name = p.key.toLowerCase();
      if (name.isEmpty) invalidArg();
      final value = p.value;
      if (name.contains(':') && name[0] == 'b') {
        if (value.vt != VarType.empty) invalidArg();
        name = name.substring(1);
        final (outCoder, outStream, rest) = _parseBond(name);
        if (rest.isEmpty || rest[0] != ':') invalidArg();
        final (inCoder, inStream, rest2) = _parseBond(rest.substring(1));
        if (inStream != 0) invalidArg();
        if (rest2.isNotEmpty) invalidArg();
        _bonds.add(Bond2(outCoder, outStream, inCoder));
        continue;
      }
      setProperty(name, value);
    }
    final numEmptyMethods = getNumEmptyMethods();
    if (numEmptyMethods > 0) {
      for (final bond in _bonds) {
        if (bond.inCoder < numEmptyMethods || bond.outCoder < numEmptyMethods) {
          invalidArg();
        }
      }
      for (final bond in _bonds) {
        bond.inCoder -= numEmptyMethods;
        bond.outCoder -= numEmptyMethods;
      }
      methods.removeRange(0, numEmptyMethods);
    }
    for (final bond in _bonds) {
      if (bond.inCoder >= methods.length || bond.outCoder >= methods.length) {
        invalidArg();
      }
    }
  }

  /// Convenience: SetProperties from CLI strings (-mx=9 gives ("x", "9")).
  void setPropertiesFromStrings(List<MapEntry<String, String>> props) {
    setProperties([for (final p in props) convertCliProperty(p.key, p.value)]);
  }

  // PropsMethod_To_FullMethod
  MethodFull _propsMethodToFullMethod(OneMethodInfo m) {
    final info = findMethodIndex(m.methodName);
    if (info == null) invalidArg('Unsupported method: ${m.methodName}');
    final dest = MethodFull()
      ..id = info.id
      ..numStreams = info.numStreams;
    dest.props.addAll(m.props.map((p) => p.copy()));
    return dest;
  }

  // SetHeaderMethod
  void setHeaderMethod(CompressionMethodMode headerMethod) {
    if (!compressHeaders) return;
    final m = OneMethodInfo()..methodName = 'LZMA';
    m.addPropAscii(CoderPropId.matchFinder, 'BT2');
    m.addPropLevel(5);
    m.addProp32(CoderPropId.numFastBytes, 273);
    m.addProp32(CoderPropId.dictionarySize, 1 << 20);
    m.addPropNumThreads(1);
    headerMethod.methods.add(_propsMethodToFullMethod(m));
  }

  // SetMainMethod
  void setMainMethod(CompressionMethodMode methodMode) {
    methodMode.bonds = [for (final b in _bonds) b.copy()];
    final methods = [for (final m in this.methods) m.copy()];
    for (final m in methods) {
      if (m.methodName.isEmpty) m.methodName = 'LZMA2';
    }
    if (methods.isEmpty) {
      methods.add(
          OneMethodInfo()..methodName = getLevel() == 0 ? 'Copy' : 'LZMA2');
      methodMode.defaultMethodWasInserted = true;
    }
    if (filterMethod.methodName.isNotEmpty) {
      for (final bond in methodMode.bonds) {
        bond.inCoder++;
        bond.outCoder++;
      }
      methods.insert(0, filterMethod.copy());
      methodMode.filterWasInserted = true;
    }

    const kSolidBytesMin = 1 << 24;
    const kSolidBytesMax = 1 << 32;
    var needSolid = false;

    for (final oneMethodInfo in methods) {
      setGlobalLevelTo(oneMethodInfo);
      final numThreadsWasSpecifiedInMethod = oneMethodInfo.getNumThreads() >= 0;
      if (!numThreadsWasSpecifiedInMethod) {
        MultiMethodProps.setMethodThreadsToIfNotFinded(oneMethodInfo, methodMode.numThreads);
      }
      final methodFull = _propsMethodToFullMethod(oneMethodInfo);
      methodFull.setNumThreads = true;
      methodFull.numThreads = methodMode.numThreads;
      methodMode.methods.add(methodFull);

      if (methodFull.id != MethodId.copy) needSolid = true;

      int dicSize;
      switch (methodFull.id) {
        case MethodId.lzma:
        case MethodId.lzma2:
          dicSize = oneMethodInfo.getLzmaDicSize();
        case MethodId.ppmd:
          dicSize = oneMethodInfo.getPpmdMemSize();
        case MethodId.deflate:
          dicSize = 1 << 15;
        case MethodId.deflate64:
          dicSize = 1 << 16;
        case MethodId.bzip2:
          dicSize = oneMethodInfo.getBZip2BlockSize();
        default:
          continue;
      }

      int solidBytes;
      if (methodFull.id == MethodId.lzma2) {
        var cs = dicSize << 2;
        const kMinSize = 1 << 20;
        const kMaxSize = 1 << 28;
        if (cs < kMinSize) cs = kMinSize;
        if (cs > kMaxSize) cs = kMaxSize;
        if (cs < dicSize) cs = dicSize;
        cs += kMinSize - 1;
        cs &= ~(kMinSize - 1);
        solidBytes = cs << 6;
        cs = oneMethodInfo.getXzBlockSize();
        // UInt64 compare ((UInt64)-1 is the solid block size)
        if ((dicSize ^ 0x8000000000000000) > (cs ^ 0x8000000000000000)) {
          dicSize = cs;
        }
        const kSolidBytesLzma2Max = 1 << 34;
        if (solidBytes > kSolidBytesLzma2Max) solidBytes = kSolidBytesLzma2Max;
        methodFull.setNumThreads = false;

        if (!numThreadsWasSpecifiedInMethod &&
            !methodMode.numThreadsWasForced &&
            methodMode.memoryUsageLimitWasSet) {
          final lzmaThreads = oneMethodInfo.getLzmaNumThreads();
          final numBlockThreadsOriginal = methodMode.numThreads ~/ lzmaThreads;
          if (numBlockThreadsOriginal > 1) {
            var numBlockThreads = numBlockThreadsOriginal;
            final lzmaMemUsage = oneMethodInfo.getLzmaMemUsage(false);
            for (; numBlockThreads > 1; numBlockThreads--) {
              var size = numBlockThreads * (lzmaMemUsage + cs);
              var numPackChunks = numBlockThreads + (numBlockThreads ~/ 8) + 1;
              if (cs < (1 << 26)) numPackChunks++;
              if (cs < (1 << 24)) numPackChunks++;
              if (cs < (1 << 22)) numPackChunks++;
              size += numPackChunks * cs;
              if (size <= methodMode.memoryUsageLimit) break;
            }
            if (numBlockThreads == 0) numBlockThreads = 1;
            if (numBlockThreads != numBlockThreadsOriginal) {
              MultiMethodProps.setMethodThreadsToReplace(
                  methodFull, numBlockThreads * lzmaThreads);
            }
          }
        }
      } else {
        solidBytes = dicSize << 7;
        if (solidBytes > kSolidBytesMax) solidBytes = kSolidBytesMax;
      }

      if (numSolidBytesDefined) continue;
      if (solidBytes < kSolidBytesMin) solidBytes = kSolidBytesMin;
      numSolidBytes = solidBytes;
      numSolidBytesDefined = true;
    }

    if (!numSolidBytesDefined) {
      numSolidBytes = needSolid ? kSolidBytesMax : 0;
    }
    numSolidBytesDefined = true;
  }
}

// GetTime (7zHandlerOut.cpp)
(int, bool) _getTime(ArchiveUpdateCallback cb, int index, int propID) {
  final prop = cb.getProperty(index, propID);
  if (prop == null) return (0, false);
  if (prop is! int) invalidArg('Bad time property');
  return (prop, true);
}

/// CHandler::UpdateItems (7zHandlerOut.cpp). Writes the new archive to
/// [outStream]; [h] may have an open archive (the old one).
void updateItems(SevenZipHandler h, SeekableOutStream outStream, int numItems,
    ArchiveUpdateCallback updateCallback) {
  // The encoders and decoders, so no manual setup is needed.
  registerSevenZipMethods();
  final db = h.inStream != null ? h.db : null;
  if (db != null && !db.canUpdate) {
    throw const SevenZipException(
        'The archive can not be updated', SevenZipError.unsupported);
  }

  final updateItems = <UpdateItem>[];
  final to = h.timeOptions;
  var needCTime = to.writeCTime.def && to.writeCTime.val;
  var needATime = to.writeATime.def && to.writeATime.val;
  var needMTime = to.writeMTime.def ? to.writeMTime.val : true;
  var needAttrib = h.writeAttrib.def ? h.writeAttrib.val : true;

  if (db != null && db.files.isNotEmpty) {
    if (!to.writeCTime.def) needCTime = db.cTime.defs.isNotEmpty;
    if (!to.writeATime.def) needATime = db.aTime.defs.isNotEmpty;
    if (!to.writeMTime.def) needMTime = db.mTime.defs.isNotEmpty;
    if (!h.writeAttrib.def) needAttrib = db.attrib.defs.isNotEmpty;
  }

  for (var i = 0; i < numItems; i++) {
    final info = updateCallback.getUpdateItemInfo(i);
    final ui = UpdateItem()
      ..newProps = info.newProps
      ..newData = info.newData
      ..indexInArchive = info.indexInArchive
      ..indexInClient = i
      ..isAnti = false
      ..size = 0;
    var name = '';
    if (ui.indexInArchive != -1) {
      if (db == null || ui.indexInArchive >= db.files.length) {
        invalidArg('Bad index in archive');
      }
      final fi = db.files[ui.indexInArchive];
      if (!ui.newProps) name = db.getPath(ui.indexInArchive);
      ui.isDir = fi.isDir;
      ui.size = fi.size;
      ui.isAnti = db.isItemAnti(ui.indexInArchive);
      if (!ui.newProps) {
        final c = db.cTime.getItem(ui.indexInArchive);
        ui.cTimeDefined = c != null;
        ui.cTime = c ?? 0;
        final a = db.aTime.getItem(ui.indexInArchive);
        ui.aTimeDefined = a != null;
        ui.aTime = a ?? 0;
        final m = db.mTime.getItem(ui.indexInArchive);
        ui.mTimeDefined = m != null;
        ui.mTime = m ?? 0;
      }
    }

    if (ui.newProps) {
      bool folderStatusIsDefined;
      if (needAttrib) {
        final prop = updateCallback.getProperty(i, Kpid.attrib);
        if (prop == null) {
          ui.attribDefined = false;
        } else if (prop is! int) {
          invalidArg('Bad attrib property');
        } else {
          ui.attrib = prop & 0xFFFFFFFF;
          ui.attribDefined = true;
        }
      }
      if (needCTime) {
        final (v, d) = _getTime(updateCallback, i, Kpid.cTime);
        ui.cTime = v;
        ui.cTimeDefined = d;
      }
      if (needATime) {
        final (v, d) = _getTime(updateCallback, i, Kpid.aTime);
        ui.aTime = v;
        ui.aTimeDefined = d;
      }
      if (needMTime) {
        final (v, d) = _getTime(updateCallback, i, Kpid.mTime);
        ui.mTime = v;
        ui.mTimeDefined = d;
      }
      {
        final prop = updateCallback.getProperty(i, Kpid.path);
        if (prop == null) {
        } else if (prop is! String) {
          invalidArg('Bad path property');
        } else {
          // NItemName::ReplaceSlashes_OsToUnix
          name = Platform.pathSeparator == '/'
              ? prop
              : prop.replaceAll(Platform.pathSeparator, '/');
        }
      }
      {
        final prop = updateCallback.getProperty(i, Kpid.isDir);
        if (prop == null) {
          folderStatusIsDefined = false;
        } else if (prop is! bool) {
          invalidArg('Bad isDir property');
        } else {
          ui.isDir = prop;
          folderStatusIsDefined = true;
        }
      }
      {
        final prop = updateCallback.getProperty(i, Kpid.isAnti);
        if (prop == null) {
          ui.isAnti = false;
        } else if (prop is! bool) {
          invalidArg('Bad isAnti property');
        } else {
          ui.isAnti = prop;
        }
      }
      if (ui.isAnti) {
        ui.attribDefined = false;
        ui.cTimeDefined = false;
        ui.aTimeDefined = false;
        ui.mTimeDefined = false;
        ui.size = 0;
      }
      if (!folderStatusIsDefined && ui.attribDefined) {
        ui.setDirStatusFromAttrib();
      }
    }
    ui.name = name;

    if (ui.newData) {
      ui.size = 0;
      if (!ui.isDir) {
        final prop = updateCallback.getProperty(i, Kpid.size);
        if (prop is! int) invalidArg('Size property expected');
        ui.size = prop;
        if (ui.size != 0 && ui.isAnti) invalidArg('Anti item with data');
      }
    }
    updateItems.add(ui);
  }

  final methodMode = CompressionMethodMode();
  final headerMethod = CompressionMethodMode();
  methodMode.memoryUsageLimit = h.memUsageCompress;
  methodMode.memoryUsageLimitWasSet = h.memUsageWasSet;
  {
    var numThreads = h.numThreads;
    const kNumThreadsMax = 1024;
    if (numThreads > kNumThreadsMax) numThreads = kNumThreadsMax;
    methodMode.numThreads = numThreads;
    methodMode.numThreadsWasForced = h.numThreadsWasForced;
    methodMode.multiThreadMixer = h.useMultiThreadMixer;
    headerMethod.multiThreadMixer = h.useMultiThreadMixer;
  }

  h.setMainMethod(methodMode);
  h.setHeaderMethod(headerMethod);

  methodMode.passwordIsDefined = false;
  methodMode.password = '';
  if (updateCallback is CryptoGetTextPassword2) {
    final pw =
        (updateCallback as CryptoGetTextPassword2).cryptoGetTextPassword2();
    methodMode.passwordIsDefined = pw != null;
    if (pw != null) methodMode.password = pw;
  }

  var compressMainHeader = h.compressHeaders;
  var encryptHeaders = false;
  if (!methodMode.passwordIsDefined && h.passwordIsDefined) {
    // if header is compressed, we use that password for updated archive
    methodMode.passwordIsDefined = true;
    methodMode.password = h.password;
  }
  if (methodMode.passwordIsDefined) {
    if (h.encryptHeadersSpecified) {
      encryptHeaders = h.encryptHeaders;
    } else {
      encryptHeaders = h.passwordIsDefined;
    }
    compressMainHeader = true;
    if (encryptHeaders) {
      headerMethod.passwordIsDefined = methodMode.passwordIsDefined;
      headerMethod.password = methodMode.password;
    }
  }
  if (numItems < 2) compressMainHeader = false;

  final level = h.getLevel();
  final options = UpdateOptions()
    ..needCTime = needCTime
    ..needATime = needATime
    ..needMTime = needMTime
    ..needAttrib = needAttrib
    ..method = methodMode
    ..headerMethod = (h.compressHeaders || encryptHeaders) ? headerMethod : null
    ..useFilters = level != 0 && h.autoFilter && !methodMode.filterWasInserted
    ..maxFilter = level >= 8
    ..analysisLevel = h.getAnalysisLevel();
  options.setFilterSupportingVerEnabledDisabled(
      h.decoderCompatibilityVersion, h.enabledFilters, h.disabledFilters);
  options.headerOptions.compressMainHeader = compressMainHeader;
  options.numSolidFiles = h.numSolidFiles;
  options.numSolidBytes = h.numSolidBytes;
  options.solidExtension = h.solidExtension;
  options.useTypeSorting = h.useTypeSorting;
  options.removeSfxBlock = h.removeSfxBlock;
  options.multiThreadMixer = h.useMultiThreadMixer;

  update(h.inStream, db, updateItems, outStream, updateCallback, options,
      h.coderContext);
}
