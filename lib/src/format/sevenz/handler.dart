// The 7z archive handler, reading side: 7zHandler.h, 7zHandler.cpp and
// 7zProperties.cpp of the LZMA SDK. The writing side (IOutArchive) is in
// handler_out.dart, extraction (7zExtract.cpp) in extract.dart.

import '../../codec/codec.dart';
import '../../codec/registry.dart';
import '../../io/streams.dart';
import '../archive_types.dart';
import 'extract.dart';
import 'handler_out.dart';
import 'header.dart';
import 'method_factory.dart';
import 'sevenz_in.dart';

/// CHandler (7zHandler.h).
class SevenZipHandler extends OutHandler {
  SeekableInStream? inStream;
  DbEx db = DbEx();

  bool isEncrypted = false;
  bool passwordIsDefined = false;
  String password = '';

  List<int> _fileInfoPopIDs = [];

  /// Password source for extraction when the extract callback does not
  /// implement [CryptoGetTextPassword].
  PasswordProvider? defaultPassword;

  /// Options for the decoders (threads, progress).
  CoderContext coderContext = const CoderContext();

  // GetNumberOfItems
  int get numberOfItems => db.files.length;

  /// Open: returns false when [stream] is not a 7z archive or its headers
  /// can not be read (see [errorFlags] and [isEncrypted]).
  /// [getTextPassword] is asked when the headers are encrypted.
  bool open(SeekableInStream stream,
      {int? maxCheckStartPosition, PasswordProvider? getTextPassword}) {
    // The decoders (REGISTER_CODEC tables), so no manual setup is needed.
    registerAllCodecs();
    close();
    _fileInfoPopIDs = [];
    final archive = InArchive(coderContext: coderContext);
    db.isArc = false;
    if (!archive.open(stream, searchHeaderSizeLimit: maxCheckStartPosition)) {
      return false;
    }
    db.isArc = true;
    final crypto = DecoderCryptoVars(getTextPassword);
    bool result;
    try {
      result = archive.readDatabase(db, crypto);
    } on SevenZipException catch (e) {
      if (e.kind == SevenZipError.io || e.kind == SevenZipError.cancelled) {
        rethrow;
      }
      // E_NOTIMPL becomes UnsupportedFeatureError in ReadDatabase; other
      // decoder errors are S_FALSE.
      if (e.kind == SevenZipError.unsupportedMethod) {
        db.unsupportedFeatureError = true;
      }
      result = false;
    }
    isEncrypted = crypto.isEncrypted;
    passwordIsDefined = crypto.passwordIsDefined;
    password = crypto.password ?? '';
    if (!result) return false;
    inStream = stream;
    _fillPopIDs();
    return true;
  }

  // Close
  void close() {
    inStream = null;
    db = DbEx();
    isEncrypted = false;
    passwordIsDefined = false;
    password = '';
  }

  /// kpidErrorFlags of the last [open].
  int get errorFlags {
    var v = 0;
    if (!db.isArc) v |= ErrorFlags.isNotArc;
    if (db.thereIsHeaderError) v |= ErrorFlags.headersError;
    if (db.unexpectedEnd) v |= ErrorFlags.unexpectedEnd;
    if (db.unsupportedFeatureError) v |= ErrorFlags.unsupportedFeature;
    return v;
  }

  /// kpidWarningFlags of the last [open].
  int get warningFlags {
    var v = 0;
    if (db.startHeaderWasRecovered) v |= ErrorFlags.headersError;
    if (db.unsupportedFeatureWarning) v |= ErrorFlags.unsupportedFeature;
    return v;
  }

  /// kArcProps: the archive properties this handler lists.
  static const List<int> archivePropIds = [
    Kpid.headersSize,
    Kpid.method,
    Kpid.solid,
    Kpid.numBlocks,
  ];

  // AddMethodName
  static void _addMethodName(StringBuffer s, int id) {
    final name = findMethodName(id);
    if (name == null) {
      s.write(_convertMethodIdToString(id));
    } else {
      s.write(name);
    }
  }

  // GetArchiveProperty
  Object? getArchiveProperty(int propID) {
    switch (propID) {
      case Kpid.method:
        final s = StringBuffer();
        final pm = db.parsedMethods;
        for (final id in pm.ids) {
          if (s.isNotEmpty) s.write(' ');
          if (id == MethodId.lzma2) {
            s.write('LZMA2:');
            s.write(_getLzma2String(pm.lzma2Prop));
          } else if (id == MethodId.lzma) {
            s.write('LZMA:');
            s.write(_getStringForSizeValue(pm.lzmaDic));
          } else {
            _addMethodName(s, id);
          }
        }
        return s.toString();
      case Kpid.solid:
        return db.isSolid;
      case Kpid.numBlocks:
        return db.numFolders;
      case Kpid.headersSize:
        return db.headersSize;
      case Kpid.phySize:
        return db.phySize;
      case Kpid.offset:
        return db.arcInfo.startPosition != 0 ? db.arcInfo.startPosition : null;
      case Kpid.warningFlags:
        final v = warningFlags;
        return v != 0 ? v : null;
      case Kpid.errorFlags:
        return errorFlags;
      case Kpid.readOnly:
        return db.canUpdate ? null : true;
    }
    return null;
  }

  // IsFolderEncrypted
  bool isFolderEncrypted(int folderIndex) {
    if (folderIndex == kNumNoIndex) return false;
    final startPos = db.foCodersDataOffset[folderIndex];
    final inByte = InByte2()
      ..init(db.codersData, startPos, db.foCodersDataOffset[folderIndex + 1]);
    var numCoders = inByte.readNum();
    for (; numCoders != 0; numCoders--) {
      final mainByte = inByte.readByte();
      final idSize = mainByte & 0xF;
      var id64 = 0;
      for (var j = 0; j < idSize; j++) {
        id64 = (id64 << 8) | inByte.buffer[inByte.pos + j];
      }
      inByte.skipDataNoCheck(idSize);
      if (id64 == MethodId.aes) return true;
      if ((mainByte & 0x20) != 0) inByte.skipDataNoCheck(inByte.readNum());
    }
    return false;
  }

  // SetMethodToProp
  String? methodString(int folderIndex) {
    if (folderIndex == kNumNoIndex) return null;
    final startPos = db.foCodersDataOffset[folderIndex];
    final inByte = InByte2()
      ..init(db.codersData, startPos, db.foCodersDataOffset[folderIndex + 1]);
    final parts = <String>[];
    var numCoders = inByte.readNum();
    var total = 0;
    for (; numCoders != 0; numCoders--) {
      if (total > 256 - 32) break;
      final mainByte = inByte.readByte();
      var id64 = 0;
      final idSize = mainByte & 0xF;
      for (var j = 0; j < idSize; j++) {
        id64 = (id64 << 8) | inByte.buffer[inByte.pos + j];
      }
      inByte.skipDataNoCheck(idSize);
      if ((mainByte & 0x10) != 0) {
        inByte.readNum();
        inByte.readNum();
      }
      var propsSize = 0;
      var propsPos = 0;
      if ((mainByte & 0x20) != 0) {
        propsSize = inByte.readNum();
        propsPos = inByte.pos;
        inByte.skipDataNoCheck(propsSize);
      }
      final props = inByte.buffer;
      String? name;
      var s = '';
      if (id64 >= 0 && id64 <= 0xFFFFFFFF) {
        final id = id64;
        if (id == MethodId.lzma) {
          name = 'LZMA';
          if (propsSize == 5) {
            final dicSize = getUint32LE(props, propsPos + 1);
            s = _getStringForSizeValue(dicSize);
            var d = props[propsPos];
            if (d != 0x5D) {
              final lc = d % 9;
              d ~/= 9;
              final pb = d ~/ 5;
              final lp = d % 5;
              if (lc != 3) s += ':lc$lc';
              if (lp != 0) s += ':lp$lp';
              if (pb != 2) s += ':pb$pb';
            }
          }
        } else if (id == MethodId.lzma2) {
          name = 'LZMA2';
          if (propsSize == 1) s = _getLzma2String(props[propsPos]);
        } else if (id == MethodId.ppmd) {
          name = 'PPMD';
          if (propsSize == 5) {
            s = 'o${props[propsPos]}:mem'
                '${_getStringForSizeValue(getUint32LE(props, propsPos + 1))}';
          }
        } else if (id == MethodId.delta) {
          name = 'Delta';
          if (propsSize == 1) s = '${props[propsPos] + 1}';
        } else if (id == MethodId.arm64 || id == MethodId.riscv) {
          name = id == MethodId.arm64 ? 'ARM64' : 'RISCV';
          if (propsSize == 4) s = '${getUint32LE(props, propsPos)}';
        } else if (id == MethodId.bcj2) {
          name = 'BCJ2';
        } else if (id == MethodId.bcj) {
          name = 'BCJ';
        } else if (id == MethodId.aes) {
          name = '7zAES';
          if (propsSize >= 1) s = '${props[propsPos] & 0x3F}';
        }
      }
      String part;
      if (name != null) {
        part = s.isEmpty ? name : '$name:$s';
      } else {
        part = findMethodName(id64) ?? _convertMethodIdToString(id64);
      }
      parts.add(part);
      total += part.length + 1;
    }
    // Coders are listed from the last one (the order of 7-Zip's output).
    var res = parts.reversed.join(' ');
    if (numCoders != 0) res = '... $res';
    return res;
  }

  // GetProperty
  Object? getProperty(int index, int propID) {
    final item = db.files[index];
    switch (propID) {
      case Kpid.isDir:
        return item.isDir;
      case Kpid.size:
        return item.size;
      case Kpid.packSize:
        final folderIndex = db.fileIndexToFolderIndexMap[index];
        if (folderIndex != kNumNoIndex) {
          if (db.folderStartFileIndex[folderIndex] == index) {
            return db.getFolderFullPackSize(folderIndex);
          }
          return null;
        }
        return 0;
      case Kpid.position:
        return db.startPos.getItem(index);
      case Kpid.cTime:
        return db.cTime.getItem(index);
      case Kpid.aTime:
        return db.aTime.getItem(index);
      case Kpid.mTime:
        return db.mTime.getItem(index);
      case Kpid.attrib:
        return db.attrib.validAndDefined(index) ? db.attrib.vals[index] : null;
      case Kpid.crc:
        return item.crcDefined ? item.crc : null;
      case Kpid.encrypted:
        return isFolderEncrypted(db.fileIndexToFolderIndexMap[index]);
      case Kpid.isAnti:
        return db.isItemAnti(index);
      case Kpid.path:
        return db.namesBuf == null ? null : db.getPath(index);
      case Kpid.method:
        return methodString(db.fileIndexToFolderIndexMap[index]);
      case Kpid.block:
        final folderIndex = db.fileIndexToFolderIndexMap[index];
        return folderIndex != kNumNoIndex ? folderIndex : null;
    }
    return null;
  }

  // FillPopIDs (7zProperties.cpp)
  void _fillPopIDs() {
    _fileInfoPopIDs = [];
    final fileInfoPopIDs = List<int>.of(db.arcInfo.fileInfoPopIDs);
    fileInfoPopIDs.remove(NID.kEmptyStream);
    fileInfoPopIDs.remove(NID.kEmptyFile);
    void copyOneItem(int id) {
      final i = fileInfoPopIDs.indexOf(id);
      if (i >= 0) {
        _fileInfoPopIDs.add(id);
        fileInfoPopIDs.removeAt(i);
      }
    }

    copyOneItem(NID.kName);
    copyOneItem(NID.kAnti);
    copyOneItem(NID.kSize);
    copyOneItem(NID.kPackInfo);
    copyOneItem(NID.kCTime);
    copyOneItem(NID.kMTime);
    copyOneItem(NID.kATime);
    copyOneItem(NID.kWinAttrib);
    copyOneItem(NID.kCRC);
    copyOneItem(NID.kComment);
    _fileInfoPopIDs.addAll(fileInfoPopIDs);
    _fileInfoPopIDs.add(_k7zIdEncrypted);
    _fileInfoPopIDs.add(_k7zIdMethod);
    _fileInfoPopIDs.add(_k7zIdBlock);
    void insertToHead(int id) {
      _fileInfoPopIDs.remove(id);
      _fileInfoPopIDs.insert(0, id);
    }

    insertToHead(NID.kMTime);
    insertToHead(NID.kPackInfo);
    insertToHead(NID.kSize);
    insertToHead(NID.kName);
  }

  static const _k7zIdEncrypted = 97;
  static const _k7zIdMethod = 98;
  static const _k7zIdBlock = 99;

  // kPropMap (7zProperties.cpp)
  static const Map<int, int> _propMap = {
    NID.kName: Kpid.path,
    NID.kSize: Kpid.size,
    NID.kPackInfo: Kpid.packSize,
    NID.kCTime: Kpid.cTime,
    NID.kMTime: Kpid.mTime,
    NID.kATime: Kpid.aTime,
    NID.kWinAttrib: Kpid.attrib,
    NID.kStartPos: Kpid.position,
    NID.kCRC: Kpid.crc,
    NID.kAnti: Kpid.isAnti,
    _k7zIdEncrypted: Kpid.encrypted,
    _k7zIdMethod: Kpid.method,
    _k7zIdBlock: Kpid.block,
  };

  /// GetNumberOfProperties / GetPropertyInfo: the item properties present
  /// in this archive, in 7-Zip's listing order (kpid values).
  List<int> get itemPropIds {
    final r = <int>[];
    for (final id in _fileInfoPopIDs) {
      final p = _propMap[id];
      if (p != null) r.add(p);
    }
    return r;
  }

  /// Extract (7zExtract.cpp). [indices] null means all items (in order).
  void extract(List<int>? indices, bool testMode,
      ArchiveExtractCallback extractCallback) {
    extractItems(this, indices, testMode, extractCallback);
  }
}

// GetHex
String _getHex(int value) =>
    String.fromCharCode(value < 10 ? 0x30 + value : 0x41 + (value - 10));

// ConvertMethodIdToString
String _convertMethodIdToString(int id) {
  final sb = <String>[];
  do {
    sb.insert(0, _getHex(id & 0xF));
    id >>= 4;
    sb.insert(0, _getHex(id & 0xF));
    id >>= 4;
  } while (id != 0);
  return sb.join();
}

// GetStringForSizeValue
String _getStringForSizeValue(int val) {
  for (var i = 0; i < 32; i++) {
    if ((1 << i) == val) return '$i';
  }
  var c = 'b';
  if ((val & ((1 << 20) - 1)) == 0) {
    val >>= 20;
    c = 'm';
  } else if ((val & ((1 << 10) - 1)) == 0) {
    val >>= 10;
    c = 'k';
  }
  return '$val$c';
}

// GetLzma2String
String _getLzma2String(int d) {
  if (d > 40) return '';
  if ((d & 1) == 0) return '${(d >> 1) + 12}';
  d = (d >> 1) + 1;
  var c = 'k';
  if (d >= 10) {
    c = 'm';
    d -= 10;
  }
  return '${3 << d}$c';
}
