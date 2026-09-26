// Archive update: 7zUpdate.h and 7zUpdate.cpp of the LZMA SDK, plus
// CompareFileNames (Common/Wildcard.cpp).
//
// Builds a new archive from the old one (folders whose files are all kept
// are copied byte for byte, partly kept folders are repacked) and new
// items (grouped by filter type, sorted, and split into solid blocks by the
// -ms limits), then writes the header.

import 'dart:io';
import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../io/streams.dart';
import '../../util/crc.dart';
import '../split.dart' show StreamSetRestriction;
import '../archive_types.dart';
import 'compression_mode.dart';
import 'decode.dart';
import 'encode.dart';
import 'folder_in_stream.dart';
import 'header.dart';
import '../../common/method_props.dart';
import 'sevenz_in.dart';
import 'sevenz_out.dart';

/// g_CaseSensitive (Wildcard.cpp).
final bool gCaseSensitive = !(Platform.isWindows || Platform.isMacOS);

bool _isPathSepar(int c) => c == 0x2F || (Platform.isWindows && c == 0x5C);

/// CompareFileNames (Wildcard.cpp): MyStringCompare_Path or
/// MyStringCompareNoCase_Path, where a path separator sorts before any
/// other character.
int compareFileNames(String s1, String s2) {
  final n1 = s1.length, n2 = s2.length;
  var i = 0;
  for (;; i++) {
    var c1 = i < n1 ? s1.codeUnitAt(i) : 0;
    var c2 = i < n2 ? s2.codeUnitAt(i) : 0;
    if (c1 != c2) {
      if (c1 == 0) return -1;
      if (c2 == 0) return 1;
      if (_isPathSepar(c1)) c1 = 0;
      if (_isPathSepar(c2)) c2 = 0;
      if (!gCaseSensitive) {
        c1 = _myCharUpper(c1);
        c2 = _myCharUpper(c2);
      }
      if (c1 < c2) return -1;
      if (c1 > c2) return 1;
      continue;
    }
    if (c1 == 0) return 0;
  }
}

int _myCharUpper(int c) {
  if (c >= 0x61 && c <= 0x7A) return c - 0x20;
  if (c < 0x80) return c;
  return String.fromCharCode(c).toUpperCase().codeUnitAt(0);
}

// ReverseFind_PathSepar
int _reverseFindPathSepar(String s) {
  for (var i = s.length - 1; i >= 0; i--) {
    if (_isPathSepar(s.codeUnitAt(i))) return i;
  }
  return -1;
}

// ReverseFind_Dot
int _reverseFindDot(String s) => s.lastIndexOf('.');

/// CUpdateItem (7zUpdate.h).
class UpdateItem {
  int indexInArchive = -1;
  int indexInClient = 0;
  int cTime = 0;
  int aTime = 0;
  int mTime = 0;
  int size = 0;
  String name = '';
  int attrib = 0;
  bool newData = false;
  bool newProps = false;
  bool isAnti = false;
  bool isDir = false;
  bool attribDefined = false;
  bool cTimeDefined = false;
  bool aTimeDefined = false;
  bool mTimeDefined = false;

  // HasStream
  bool get hasStream => !isDir && !isAnti && size != 0;

  // SetDirStatusFromAttrib
  void setDirStatusFromAttrib() => isDir = (attrib & FileAttrib.directory) != 0;
}

/// CUpdateOptions (7zUpdate.h).
class UpdateOptions {
  CompressionMethodMode? method;
  CompressionMethodMode? headerMethod;
  bool useFilters = false;
  bool maxFilter = false;
  int analysisLevel = -1;

  /// -1 means no limit (UInt64 max in 7-Zip).
  int numSolidFiles = -1;
  int numSolidBytes = -1;
  bool solidExtension = false;
  bool useTypeSorting = true;
  bool removeSfxBlock = false;
  bool multiThreadMixer = true;

  bool needCTime = false;
  bool needATime = false;
  bool needMTime = false;
  bool needAttrib = false;

  final HeaderOptions headerOptions = HeaderOptions();
  List<int> disabledFilterIDs = [MethodId.riscv];

  // Add_DisabledFilter_for_id
  void _addDisabledFilterForId(int id, List<int> enabledFilters) {
    if (!enabledFilters.contains(id) && !disabledFilterIDs.contains(id)) {
      disabledFilterIDs.add(id);
      disabledFilterIDs.sort();
    }
  }

  // SetFilterSupporting_ver_enabled_disabled
  void setFilterSupportingVerEnabledDisabled(
      int compatVer, List<int> enabledFilters, List<int> disabledFilters) {
    disabledFilterIDs = List<int>.of(disabledFilters);
    if (compatVer < 2300) {
      _addDisabledFilterForId(MethodId.arm64, enabledFilters);
    }
    if (compatVer < 2402) {
      _addDisabledFilterForId(MethodId.riscv, enabledFilters);
    }
  }
}

/// CFilterMode.
class FilterMode {
  int id = 0;

  /// Required file size alignment (or the delta for k_Delta).
  int delta = 0;
  int offset = 0;

  // ClearFilterMode
  void clearFilterMode() {
    id = 0;
    delta = 0;
    offset = 0;
  }

  // SetDelta
  void setDelta() {
    if (id == MethodId.ia64) {
      delta = 16;
    } else if (id == MethodId.arm64 ||
        id == MethodId.arm ||
        id == MethodId.ppc ||
        id == MethodId.sparc) {
      delta = 4;
    } else if (id == MethodId.armt || id == MethodId.riscv) {
      delta = 2;
    } else if (id == MethodId.bcj || id == MethodId.bcj2) {
      delta = 1;
    } else {
      delta = 0;
    }
  }

  void copyFrom(FilterMode m) {
    id = m.id;
    delta = m.delta;
    offset = m.offset;
  }
}

int _getUi16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _getBe16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
int _getBe32(Uint8List b, int o) =>
    ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) & 0xFFFFFFFF;

// Parse_EXE
bool _parseExe(Uint8List buf, int size, FilterMode filterMode) {
  if (size < 512 || _getUi16(buf, 0) != 0x5A4D) return false;
  final peOffset = getUint32LE(buf, 0x3C);
  if (peOffset >= 0x1000 || peOffset + 512 > size || (peOffset & 7) != 0) {
    return false;
  }
  var p = peOffset;
  if (getUint32LE(buf, p) != 0x00004550) return false;
  p += 4;
  final machine = _getUi16(buf, p);
  int filterId;
  switch (machine) {
    case 0x014C:
    case 0x8664:
      filterId = MethodId.bcj;
    case 0xAA64:
      filterId = MethodId.arm64;
    case 0x01C0:
    case 0x01C2:
      filterId = MethodId.arm;
    case 0x01C4:
      filterId = MethodId.armt;
    case 0x5032:
    case 0x5064:
      filterId = MethodId.riscv;
    case 0x0200:
      filterId = MethodId.ia64;
    default:
      return false;
  }
  final numSections = _getUi16(buf, p + 2);
  final optHeaderSize = _getUi16(buf, p + 16);
  if (optHeaderSize > (1 << 10)) return false;
  p += 20;
  switch (_getUi16(buf, p)) {
    case 0x10B:
    case 0x20B:
      break;
    default:
      return false;
  }
  const kNumScanSectionsMax = 1 << 6;
  const kPeSectHeaderSize = 40;
  if (p + optHeaderSize <= size) {
    p += optHeaderSize;
    if (numSections <= kNumScanSectionsMax && machine == 0x8664) {
      for (var i = 0; i < numSections; i++, p += kPeSectHeaderSize) {
        if (p + kPeSectHeaderSize > size) break;
        // ".a64xrm" (ARM64EC), 8 bytes with the terminating zero
        const sig = [0x2E, 0x61, 0x36, 0x34, 0x78, 0x72, 0x6D, 0x00];
        var eq = true;
        for (var k = 0; k < 8; k++) {
          if (buf[p + k] != sig[k]) {
            eq = false;
            break;
          }
        }
        if (eq) {
          filterId = MethodId.arm64;
          break;
        }
      }
    }
  }
  filterMode.id = filterId;
  return true;
}

// Parse_ELF
bool _parseElf(Uint8List buf, int size, FilterMode filterMode) {
  if (size < 512 || buf[6] != 1) return false;
  if (getUint32LE(buf, 0) != 0x464C457F) return false;
  switch (buf[4]) {
    case 1:
    case 2:
      break;
    default:
      return false;
  }
  bool be;
  switch (buf[5]) {
    case 1:
      be = false;
    case 2:
      be = true;
    default:
      return false;
  }
  final machine = be ? _getBe16(buf, 0x12) : _getUi16(buf, 0x12);
  int filterId;
  switch (machine) {
    case 3:
    case 6:
    case 62:
      filterId = MethodId.bcj;
    case 2:
    case 18:
    case 43:
      filterId = MethodId.sparc;
    case 20:
    case 21:
      if (!be) return false;
      filterId = MethodId.ppc;
    case 40:
      if (be) return false;
      filterId = MethodId.arm;
    case 183:
      if (be) return false;
      filterId = MethodId.arm64;
    case 243:
      if (be) return false;
      filterId = MethodId.riscv;
    default:
      return false;
  }
  filterMode.id = filterId;
  return true;
}

// Parse_MACH
bool _parseMach(Uint8List buf, int size, FilterMode filterMode) {
  if (size < 512) return false;
  bool be;
  switch (getUint32LE(buf, 0)) {
    case 0xCEFAEDFE:
    case 0xCFFAEDFE:
      be = true;
    case 0xFEEDFACE:
    case 0xFEEDFACF:
      be = false;
    default:
      return false;
  }
  int get32(int o) => be ? _getBe32(buf, o) : getUint32LE(buf, o);
  const abi64 = 1 << 24;
  int filterId;
  switch (get32(4)) {
    case 7:
    case const (abi64 | 7):
      filterId = MethodId.bcj;
    case 12:
      if (be) return false;
      filterId = MethodId.arm;
    case 14:
      if (!be) return false;
      filterId = MethodId.sparc;
    case 18:
    case const (abi64 | 18):
      if (!be) return false;
      filterId = MethodId.ppc;
    case const (abi64 | 12):
      if (be) return false;
      filterId = MethodId.arm64;
    default:
      return false;
  }
  final numCommands = get32(0x10);
  final commandsSize = get32(0x14);
  if (commandsSize > (1 << 24) || numCommands > (1 << 18)) return false;
  filterMode.id = filterId;
  return true;
}

// Parse_WAV
bool _parseWav(Uint8List buf, int size, FilterMode filterMode) {
  if (size < 0x2C) return false;
  if (getUint32LE(buf, 0) != 0x46464952 ||
      getUint32LE(buf, 8) != 0x45564157 ||
      getUint32LE(buf, 0xC) != 0x20746D66) {
    return false;
  }
  var subChunkSize = getUint32LE(buf, 0x10);
  if (subChunkSize < 0x10 || subChunkSize > 0x12 || _getUi16(buf, 0x14) != 1) {
    return false;
  }
  final numChannels = _getUi16(buf, 0x16);
  final bitsPerSample = _getUi16(buf, 0x22);
  if ((bitsPerSample & 7) != 0) return false;
  final delta = numChannels * (bitsPerSample >> 3);
  if (delta == 0 || delta > 256) return false;
  var pos = 0x14 + subChunkSize;
  for (var i = 0; i < 10; i++) {
    if (pos + 8 > size) return false;
    subChunkSize = getUint32LE(buf, pos + 4);
    if (getUint32LE(buf, pos) == 0x61746164) {
      filterMode.id = MethodId.delta;
      filterMode.delta = delta;
      return true;
    }
    if (subChunkSize > (1 << 16)) return false;
    pos += subChunkSize + 8;
  }
  return false;
}

// ParseFile
bool _parseFile(Uint8List buf, int size, FilterMode filterMode) {
  filterMode.clearFilterMode();
  if (_parseExe(buf, size, filterMode)) return true;
  if (_parseElf(buf, size, filterMode)) return true;
  if (_parseMach(buf, size, filterMode)) return true;
  return _parseWav(buf, size, filterMode);
}

/// CFilterMode2.
class FilterMode2 extends FilterMode {
  bool encrypted = false;
  int groupIndex = 0;

  // Compare
  int compare(FilterMode2 m) {
    if (!encrypted) {
      if (m.encrypted) return -1;
    } else if (!m.encrypted) {
      return 1;
    }
    if (id < m.id) return -1;
    if (id > m.id) return 1;
    if (delta < m.delta) return -1;
    if (delta > m.delta) return 1;
    if (offset < m.offset) return -1;
    if (offset > m.offset) return 1;
    return 0;
  }

  // operator ==
  bool same(FilterMode2 m) =>
      id == m.id &&
      delta == m.delta &&
      offset == m.offset &&
      encrypted == m.encrypted;
}

// GetGroup
int _getGroup(List<FilterMode2> filters, FilterMode2 m) {
  for (var i = 0; i < filters.length; i++) {
    if (m.same(filters[i])) return i;
  }
  filters.add(m);
  return filters.length - 1;
}

// Is86Filter
bool _is86Filter(int m) => m == MethodId.bcj || m == MethodId.bcj2;

// IsExeFilter
bool _isExeFilter(int m) {
  switch (m) {
    case MethodId.arm64:
    case MethodId.riscv:
    case MethodId.bcj:
    case MethodId.bcj2:
    case MethodId.arm:
    case MethodId.armt:
    case MethodId.ppc:
    case MethodId.sparc:
    case MethodId.ia64:
      return true;
  }
  return false;
}

// Get_FilterGroup_for_Folder
int _getFilterGroupForFolder(
    List<FilterMode2> filters, FolderEx f, bool extractFilter) {
  final m = FilterMode2()..encrypted = f.isEncrypted;
  if (extractFilter) {
    final coder = f.coders[f.unpackCoder];
    if (coder.methodId == MethodId.delta) {
      if (coder.props.length == 1) {
        m.delta = coder.props[0] + 1;
        m.id = MethodId.delta;
      }
    } else if (_isExeFilter(coder.methodId)) {
      m.id = coder.methodId;
      if (m.id == MethodId.bcj2) m.id = MethodId.bcj;
      m.setDelta();
      if (m.id == MethodId.arm64 || m.id == MethodId.riscv) {
        if (coder.props.length == 4) m.offset = getUint32LE(coder.props, 0);
      }
    }
  }
  return _getGroup(filters, m);
}

// WriteRange
void _writeRange(
    SeekableInStream inStream, OutStream outStream, int position, int size) {
  inStream.position = position;
  final n = copyStream(LimitedInStream(inStream, size), outStream);
  if (n != size) {
    throw const SevenZipException(
        'Unexpected end of archive', SevenZipError.unexpectedEnd);
  }
}

// CompareEmptyItems
int _compareEmptyItems(UpdateItem u1, UpdateItem u2) {
  if (u1.isAnti != u2.isAnti) return u1.isAnti ? 1 : -1;
  if (u1.isDir != u2.isDir) {
    if (u1.isDir) return u1.isAnti ? 1 : -1;
    return u2.isAnti ? -1 : 1;
  }
  final n = compareFileNames(u1.name, u2.name);
  return (u1.isDir && u1.isAnti) ? -n : n;
}

// g_Exts
const String _gExts =
    ' 7z xz lzma ace arc arj bz tbz bz2 tbz2 cab deb gz tgz ha lha lzh lzo lzx pak rar rpm sit zoo'
    ' zip jar ear war msi'
    ' 3gp avi mov mpeg mpg mpe wmv'
    ' aac ape fla flac la mp3 m4a mp4 ofr ogg pac ra rm rka shn swa tta wv wma wav'
    ' swf'
    ' chm hxi hxs'
    ' gif jpeg jpg jp2 png tiff  bmp ico psd psp'
    ' awg ps eps cgm dxf svg vrml wmf emf ai md'
    ' cad dwg pps key sxi'
    ' max 3ds'
    ' iso bin nrg mdf img pdi tar cpio xpi'
    ' vfd vhd vud vmc vsv'
    ' vmdk dsk nvram vmem vmsd vmsn vmss vmtm'
    ' inl inc idl acf asa'
    ' h hpp hxx c cpp cxx m mm go swift'
    ' rc java cs rs pas bas vb cls ctl frm dlg def'
    ' f77 f f90 f95'
    ' asm s'
    ' sql manifest dep'
    ' mak clw csproj vcproj sln dsp dsw'
    ' class'
    ' bat cmd bash sh'
    ' xml xsd xsl xslt hxk hxc htm html xhtml xht mht mhtml htw asp aspx css cgi jsp shtml'
    ' awk sed hta js json php php3 php4 php5 phptml pl pm py pyo rb tcl ts vbs'
    ' text txt tex ans asc srt reg ini doc docx mcw dot rtf hlp xls xlr xlt xlw ppt pdf'
    ' sxc sxd sxi sxg sxw stc sti stw stm odt ott odg otg odp otp ods ots odf'
    ' abw afp cwk lwp wpd wps wpt wrf wri'
    ' abf afm bdf fon mgf otf pcf pfa snf ttf'
    ' dbf mdb nsf ntf wdb db fdb gdb'
    ' exe dll ocx vbx sfx sys tlb awx com obj lib out o so'
    ' pdb pch idb ncb opt';

final List<String> _gExtWords =
    _gExts.split(' ').where((w) => w.isNotEmpty).toList();

// GetExtIndex
int _getExtIndex(String ext) {
  final i = _gExtWords.indexOf(ext);
  return i >= 0 ? i + 1 : _gExtWords.length + 1;
}

/// CRefItem.
class _RefItem {
  final UpdateItem updateItem;
  final int index;
  int extensionPos = 0;
  int namePos = 0;
  int extensionIndex = 0;

  _RefItem(this.index, this.updateItem, bool sortByType) {
    if (sortByType) {
      final name = updateItem.name;
      final slashPos = _reverseFindPathSepar(name);
      namePos = slashPos + 1;
      final dotPos = _reverseFindDot(name);
      if (dotPos <= slashPos) {
        extensionPos = name.length;
      } else {
        extensionPos = dotPos + 1;
        if (extensionPos != name.length) {
          final s = StringBuffer();
          var pos = extensionPos;
          for (;; pos++) {
            if (pos == name.length) {
              extensionIndex = _getExtIndex(s.toString());
              break;
            }
            final c = name.codeUnitAt(pos);
            if (c >= 0x80) break;
            s.writeCharCode(c >= 0x41 && c <= 0x5A ? c + 0x20 : c);
          }
        }
      }
    }
  }
}

int _cmpInt(int a, int b) => a < b ? -1 : (a > b ? 1 : 0);

// CompareUpdateItems
int _compareUpdateItems(_RefItem a1, _RefItem a2, bool sortByType) {
  final u1 = a1.updateItem;
  final u2 = a2.updateItem;
  if (u1.isDir != u2.isDir) return u1.isDir ? 1 : -1;
  if (u1.isDir) {
    if (u1.isAnti != u2.isAnti) return u1.isAnti ? 1 : -1;
    return -compareFileNames(u1.name, u2.name);
  }
  if (sortByType) {
    var r = _cmpInt(a1.extensionIndex, a2.extensionIndex);
    if (r != 0) return r;
    r = compareFileNames(
        u1.name.substring(a1.extensionPos), u2.name.substring(a2.extensionPos));
    if (r != 0) return r;
    r = compareFileNames(
        u1.name.substring(a1.namePos), u2.name.substring(a2.namePos));
    if (r != 0) return r;
    if (!u1.mTimeDefined && u2.mTimeDefined) return 1;
    if (u1.mTimeDefined && !u2.mTimeDefined) return -1;
    if (u1.mTimeDefined && u2.mTimeDefined) {
      r = _cmpU64(u1.mTime, u2.mTime);
      if (r != 0) return r;
    }
    r = _cmpU64(u1.size, u2.size);
    if (r != 0) return r;
  }
  var r = compareFileNames(u1.name, u2.name);
  if (r != 0) return r;
  r = _cmpInt(u1.indexInClient, u2.indexInClient);
  if (r != 0) return r;
  return _cmpInt(u1.indexInArchive, u2.indexInArchive);
}

int _cmpU64(int a, int b) {
  if (a == b) return 0;
  return (a ^ 0x8000000000000000) < (b ^ 0x8000000000000000) ? -1 : 1;
}

/// CFolderRepack.
class _FolderRepack {
  final int folderIndex;
  final int numCopyFiles;
  _FolderRepack(this.folderIndex, this.numCopyFiles);
}

/// CSolidGroup.
class _SolidGroup {
  final List<int> indices = [];
  final List<_FolderRepack> folderRefs = [];
}

const List<String> _gExeExts = ['dll', 'exe', 'ocx', 'sfx', 'sys'];
const List<String> _gExeUnixExts = ['so', 'dylib'];

// IsExt_Exe
bool _isExtExe(String ext) => _gExeExts.contains(ext.toLowerCase());

// IsExt_ExeUnix_NumericAllowed: finds "so" in names like libstdc++.so.6.0.29
bool _isExtExeUnixNumericAllowed(String path) {
  var pos = path.length;
  var dotPos = pos;
  for (;;) {
    if (pos == 0) return false;
    final c = path.codeUnitAt(--pos);
    if (_isPathSepar(c)) return false;
    if (c == 0x2E) {
      final num = dotPos - pos - 1;
      if (num < 1) return false;
      final cur = path.substring(pos + 1);
      for (final ext in _gExeUnixExts) {
        if (num == ext.length && cur.toLowerCase().startsWith(ext)) {
          return true;
        }
      }
      final (_, n) = convertStringToUInt32(cur);
      if (n != num) return false;
      dotPos = pos;
    }
  }
}

/// CAnalysis.
class _Analysis {
  ArchiveUpdateCallbackFile? callback;
  Uint8List? _buffer;
  bool parseWav = false;
  bool parseExe = false;
  bool parseExeUnix = false;
  bool parseNoExt = false;
  bool parseAll = false;

  static const int _kAnalysisBufSize = 1 << 14;

  // GetFilterGroup
  void getFilterGroup(int index, UpdateItem ui, FilterMode filterMode) {
    filterMode.clearFilterMode();
    final filterModeTemp = FilterMode();
    final name = ui.name;
    final slashPos = _reverseFindPathSepar(name);
    final dotPos = _reverseFindDot(name);

    var needReadFile = parseAll;
    var probablyIsSameIsa = false;
    final cb = callback;
    if (!needReadFile || cb == null) {
      String? ext;
      if (dotPos > slashPos) ext = name.substring(dotPos + 1);
      // 7-Zip stores posix attributes in high 16 bits and sets 0x8000
      if ((ui.attrib & 0x8000) != 0) {
        final stMode = ui.attrib >> 16;
        if ((stMode & (0x40 | 0x8 | 0x1)) != 0 &&
            (stMode & 0xF000) == 0x8000 &&
            ui.size >= (1 << 11)) {
          if (!Platform.isWindows) probablyIsSameIsa = true;
          needReadFile = true;
        }
      }
      if (!needReadFile) {
        if (ext == null) {
          needReadFile = parseNoExt;
        } else {
          var isUnixExt = false;
          if (parseExeUnix) isUnixExt = _isExtExeUnixNumericAllowed(name);
          if (isUnixExt) {
            needReadFile = true;
            if (!Platform.isWindows) probablyIsSameIsa = true;
          } else if (_isExtExe(ext)) {
            needReadFile = parseExe;
            if (Platform.isWindows) probablyIsSameIsa = true;
          } else if (ext.toLowerCase() == 'wav') {
            if (!needReadFile) needReadFile = parseWav;
          }
        }
      }
    }

    if (needReadFile) {
      var parseRes = false;
      if (cb != null) {
        final buf = _buffer ??= Uint8List(_kAnalysisBufSize);
        final stream = cb.getStream2(index, UpdateNotifyOp.analyze);
        if (stream != null) {
          final size = readFully(stream, buf, 0, _kAnalysisBufSize);
          releaseStream(stream);
          parseRes = _parseFile(buf, size, filterModeTemp);
        }
      } else if (probablyIsSameIsa) {
        final v = Platform.version;
        if (v.contains('_x64') || v.contains('_ia32')) {
          filterModeTemp.id = MethodId.bcj;
        } else if (v.contains('_arm64')) {
          filterModeTemp.id = MethodId.arm64;
        } else if (v.contains('_riscv')) {
          filterModeTemp.id = MethodId.riscv;
        }
        parseRes = true;
      }
      if (parseRes &&
          filterModeTemp.id != MethodId.delta &&
          filterModeTemp.delta == 0) {
        filterModeTemp.setDelta();
        if (filterModeTemp.delta > 1) {
          if (ui.size % filterModeTemp.delta != 0) parseRes = false;
        }
      }
      if (!parseRes) filterModeTemp.clearFilterMode();
    }
    filterMode.copyFrom(filterModeTemp);
  }
}

// GetMethodFull
MethodFull _getMethodFull(int methodID, int numStreams) => MethodFull()
  ..id = methodID
  ..numStreams = numStreams;

// AddBondForFilter: adds the bond for mode.Methods[0] (the filter).
void _addBondForFilter(CompressionMethodMode mode) {
  for (var c = 1; c < mode.methods.length; c++) {
    if (!mode.isThereBondToCoder(c)) {
      mode.bonds.add(Bond2(0, 0, c));
      return;
    }
  }
  invalidArg('No coder for the filter');
}

// AddBcj2Methods
void _addBcj2Methods(CompressionMethodMode mode) {
  final m = _getMethodFull(MethodId.lzma, 1);
  m.addProp32(CoderPropId.dictionarySize, 1 << 20);
  m.addProp32(CoderPropId.numFastBytes, 128);
  m.addProp32(CoderPropId.numThreads, 1);
  m.addProp32(CoderPropId.litPosBits, 2);
  m.addProp32(CoderPropId.litContextBits, 0);

  final methodIndex = mode.methods.length;
  if (mode.bonds.isEmpty) {
    for (var i = 1; i + 1 < mode.methods.length; i++) {
      mode.bonds.add(Bond2(i, 0, i + 1));
    }
  }
  mode.methods.add(m);
  mode.methods.add(m.copy());
  _addBondForFilter(mode);
  mode.bonds.add(Bond2(0, 1, methodIndex));
  mode.bonds.add(Bond2(0, 2, methodIndex + 1));
}

// MakeExeMethod
void _makeExeMethod(CompressionMethodMode mode, FilterMode filterMode,
    bool bcj2IsAllowed, List<int> disabledFilterIDs) {
  if (mode.filterWasInserted) {
    final m = mode.methods[0];
    if (m.id == MethodId.bcj2) {
      _addBcj2Methods(mode);
      return;
    }
    if (!m.isSimpleCoder) {
      throw const SevenZipException(
          'Unsupported filter', SevenZipError.unsupportedMethod);
    }
    if (mode.bonds.isEmpty) return;
    _addBondForFilter(mode);
    return;
  }

  if (filterMode.id == 0) return;

  int nextCoder;
  final useBcj2 = bcj2IsAllowed &&
      _is86Filter(filterMode.id) &&
      !disabledFilterIDs.contains(MethodId.bcj2);

  if (!useBcj2 && disabledFilterIDs.contains(filterMode.id)) {
    // the filter is disabled, but the alignment can still tune lzma
    nextCoder = 0;
    if (mode.bonds.isNotEmpty) {
      for (var c = 0;; c++) {
        if (c == mode.methods.length) return;
        if (!mode.isThereBondToCoder(c)) {
          nextCoder = c;
          break;
        }
      }
    }
  } else {
    // insert the new filter method at index 0
    for (final bond in mode.bonds) {
      bond.inCoder++;
      bond.outCoder++;
    }
    if (useBcj2) {
      mode.methods.insert(0, _getMethodFull(MethodId.bcj2, 4));
      _addBcj2Methods(mode);
      return;
    }
    final m = _getMethodFull(filterMode.id, 1);
    mode.methods.insert(0, m);
    if (filterMode.id == MethodId.delta) {
      m.addProp32(CoderPropId.defaultProp, filterMode.delta);
    } else if (filterMode.id == MethodId.arm64 ||
        filterMode.id == MethodId.riscv) {
      m.addProp32(CoderPropId.defaultProp, filterMode.offset);
    }
    nextCoder = 1;
    if (mode.bonds.isNotEmpty) {
      _addBondForFilter(mode);
      nextCoder = mode.bonds.last.inCoder;
    }
  }

  if (nextCoder >= mode.methods.length) return;

  var alignBits = -1;
  {
    final delta = filterMode.delta;
    if (delta == 0 || delta > 16) {
    } else if ((delta & 15) == 0) {
      alignBits = 4;
    } else if ((delta & 7) == 0) {
      alignBits = 3;
    } else if ((delta & 3) == 0) {
      alignBits = 2;
    } else if ((delta & 1) == 0) {
      alignBits = 1;
    }
  }
  if (alignBits <= 0) return;
  final nextMethod = mode.methods[nextCoder];
  if (nextMethod.id == MethodId.lzma || nextMethod.id == MethodId.lzma2) {
    if (!nextMethod.areLzmaModelPropsDefined()) {
      if (alignBits > 2 || filterMode.id == MethodId.delta) {
        nextMethod.addProp32(CoderPropId.posStateBits, alignBits);
      }
      final lc = alignBits < 3 ? 3 - alignBits : 0;
      nextMethod.addProp32(CoderPropId.litContextBits, lc);
      nextMethod.addProp32(CoderPropId.litPosBits, alignBits);
    }
  }
}

// UpdateItem_To_FileItem2
void _updateItemToFileItem2(UpdateItem ui, FileItem2 file2) {
  file2.attrib = ui.attrib;
  file2.attribDefined = ui.attribDefined;
  file2.cTime = ui.cTime;
  file2.cTimeDefined = ui.cTimeDefined;
  file2.aTime = ui.aTime;
  file2.aTimeDefined = ui.aTimeDefined;
  file2.mTime = ui.mTime;
  file2.mTimeDefined = ui.mTimeDefined;
  file2.isAnti = ui.isAnti;
  file2.startPosDefined = false;
}

// UpdateItem_To_FileItem
void _updateItemToFileItem(UpdateItem ui, FileItem file, FileItem2 file2) {
  _updateItemToFileItem2(ui, file2);
  file.size = ui.size;
  file.isDir = ui.isDir;
  file.hasStream = ui.hasStream;
}

/// CRepackStreamBase + CFolderInStream2: reads the decoded old folder and
/// passes on only the files that are kept, checking their CRCs.
class _FolderInStream2 implements InStream {
  bool _needWrite = false;
  bool _fileIsOpen = false;
  bool _calcCrc = false;
  int _crc = 0;
  int _rem = 0;
  late List<bool> _extractStatuses;
  int _startIndex = 0;
  int _currentIndex = 0;

  final DbEx _db;
  final ArchiveUpdateCallbackFile? _opCallback;
  final ArchiveExtractCallbackMessage2? _extractCallback;
  final InStream _inStream;
  final Uint8List _buf = Uint8List(1 << 16);

  _FolderInStream2(
      this._db, this._opCallback, this._extractCallback, this._inStream);

  // Init
  void init(int startIndex, List<bool> extractStatuses) {
    _startIndex = startIndex;
    _extractStatuses = extractStatuses;
    _currentIndex = 0;
    _fileIsOpen = false;
    _processEmptyFiles();
  }

  // CheckFinishedState
  bool get finished => _currentIndex == _extractStatuses.length;

  // OpenFile
  void _openFile() {
    final arcIndex = _startIndex + _currentIndex;
    final fi = _db.files[arcIndex];
    _needWrite = _extractStatuses[_currentIndex];
    _opCallback?.reportOperation(EventIndexType.inArcIndex, arcIndex,
        _needWrite ? UpdateNotifyOp.repack : UpdateNotifyOp.skip);
    _crc = 0xFFFFFFFF;
    _calcCrc = fi.crcDefined && !fi.isDir;
    _fileIsOpen = true;
    _rem = fi.size;
  }

  // CloseFile
  void _closeFile() {
    final arcIndex = _startIndex + _currentIndex;
    final fi = _db.files[arcIndex];
    _fileIsOpen = false;
    _currentIndex++;
    if (!_calcCrc || fi.crc == (_crc ^ 0xFFFFFFFF)) return;
    _extractCallback?.reportExtractResult(
        EventIndexType.inArcIndex, arcIndex, OperationResult.crcError);
    throw const SevenZipException(
        'CRC error in repacked file', SevenZipError.crc);
  }

  // ProcessEmptyFiles
  void _processEmptyFiles() {
    while (_currentIndex < _extractStatuses.length &&
        _db.files[_startIndex + _currentIndex].size == 0) {
      _openFile();
      _closeFile();
    }
  }

  @override
  int read(Uint8List data, int off, int size) {
    var processed = 0;
    while (size != 0) {
      if (_fileIsOpen) {
        var cur = size < _rem ? size : _rem;
        int n;
        if (_needWrite) {
          n = _inStream.read(data, off, cur);
          _crc = crc32Update(_crc, data, off, off + n);
        } else {
          if (cur > _buf.length) cur = _buf.length;
          n = _inStream.read(_buf, 0, cur);
          _crc = crc32Update(_crc, _buf, 0, n);
        }
        _rem -= n;
        if (_needWrite) {
          off += n;
          size -= n;
          processed += n;
        }
        if (_rem == 0) {
          _closeFile();
          _processEmptyFiles();
        }
        if (n == 0) {
          throw const SevenZipException(
              'Unexpected end of old folder', SevenZipError.data);
        }
        continue;
      }
      _processEmptyFiles();
      if (_currentIndex == _extractStatuses.length) return processed;
      _openFile();
    }
    return processed;
  }
}

// GetFile
(FileItem, FileItem2) _getFile(Database inDb, int index) {
  final file = inDb.files[index].copy();
  final file2 = FileItem2();
  final c = inDb.cTime.getItem(index);
  file2.cTimeDefined = c != null;
  file2.cTime = c ?? 0;
  final a = inDb.aTime.getItem(index);
  file2.aTimeDefined = a != null;
  file2.aTime = a ?? 0;
  final m = inDb.mTime.getItem(index);
  file2.mTimeDefined = m != null;
  file2.mTime = m ?? 0;
  final s = inDb.startPos.getItem(index);
  file2.startPosDefined = s != null;
  file2.startPos = s ?? 0;
  final at = inDb.attrib.getItem(index);
  file2.attribDefined = at != null;
  file2.attrib = at ?? 0;
  file2.isAnti = inDb.isItemAnti(index);
  return (file, file2);
}

/// CLocalProgress (in size is the main size).
class _LocalProgress {
  final ArchiveUpdateCallback cb;
  int progressOffset = 0;
  int inSize = 0;
  int outSize = 0;
  _LocalProgress(this.cb);
  void setCur() => cb.setCompleted(progressOffset + inSize);
  void setRatio(int inS, int outS) =>
      cb.setCompleted(progressOffset + inSize + inS);
}

const int _kMaxU64 = 0x7FFFFFFFFFFFFFFF;

/// Update (7zUpdate.cpp): writes a new archive to [seqOutStream] from the
/// old archive ([inStream], [db], may be null) and [updateItems].
void update(
    SeekableInStream? inStream,
    DbEx? db,
    List<UpdateItem> updateItems,
    SeekableOutStream seqOutStream,
    ArchiveUpdateCallback updateCallback,
    UpdateOptions options,
    CoderContext coderContext) {
  var numSolidFiles =
      options.numSolidFiles < 0 ? _kMaxU64 : options.numSolidFiles;
  if (numSolidFiles == 0) numSolidFiles = 1;
  final numSolidBytes =
      options.numSolidBytes < 0 ? _kMaxU64 : options.numSolidBytes;

  final opCallback = updateCallback is ArchiveUpdateCallbackFile
      ? updateCallback as ArchiveUpdateCallbackFile
      : null;
  final extractCallback = updateCallback is ArchiveExtractCallbackMessage2
      ? updateCallback as ArchiveExtractCallbackMessage2
      : null;

  StreamSetRestriction? vStreamSetRestriction;
  {
    final sfxBlockSize =
        (db != null && !options.removeSfxBlock) ? db.arcInfo.startPosition : 0;
    if (seqOutStream is StreamSetRestriction) {
      final r = seqOutStream as StreamSetRestriction;
      vStreamSetRestriction = r;
      final offset = seqOutStream.position;
      r.setRestriction(offset + sfxBlockSize,
          offset + sfxBlockSize + kStartHeadersRewriteSize);
    }
    if (sfxBlockSize != 0) {
      _writeRange(inStream!, seqOutStream, 0, sfxBlockSize);
    }
  }

  List<int> fileIndexToUpdateIndexMap = const [];
  var complexity = 0;
  var isThereUnknownSize = false;
  var inSizeForReduce2 = 0;
  var needEncryptedRepack = false;

  final filters = <FilterMode2>[];
  final groups = <_SolidGroup>[];

  var useFilters = options.useFilters;
  final method0 = options.method!;
  if (useFilters) {
    for (final m in method0.methods) {
      if (isFilterMethod(m.id)) {
        useFilters = false;
        break;
      }
    }
  }

  if (db != null) {
    fileIndexToUpdateIndexMap = List<int>.filled(db.files.length, -1);
    for (var i = 0; i < updateItems.length; i++) {
      final index = updateItems[i].indexInArchive;
      if (index != -1) fileIndexToUpdateIndexMap[index] = i;
    }
    for (var i = 0; i < db.numFolders; i++) {
      var indexInFolder = 0;
      var numCopyItems = 0;
      final numUnpackStreams = db.numUnpackStreamsVector[i];
      var repackSize = 0;
      for (var fi = db.folderStartFileIndex[i];
          indexInFolder < numUnpackStreams;
          fi++) {
        if (fi >= db.files.length) {
          throw const SevenZipException('Bad archive', SevenZipError.headers);
        }
        final file = db.files[fi];
        if (file.hasStream) {
          indexInFolder++;
          final updateIndex = fileIndexToUpdateIndexMap[fi];
          if (updateIndex >= 0 && !updateItems[updateIndex].newData) {
            numCopyItems++;
            repackSize += file.size;
          }
        }
      }
      if (numCopyItems == 0) continue;
      final rep = _FolderRepack(i, numCopyItems);
      final f = db.parseFolderEx(i);
      final isEncrypted = f.isEncrypted;
      final needCopy = numCopyItems == numUnpackStreams;
      final extractFilter = useFilters || needCopy;
      final groupIndex = _getFilterGroupForFolder(filters, f, extractFilter);
      while (groupIndex >= groups.length) {
        groups.add(_SolidGroup());
      }
      groups[groupIndex].folderRefs.add(rep);
      if (needCopy) {
        complexity += db.getFolderFullPackSize(i);
      } else {
        complexity += repackSize;
        if (inSizeForReduce2 < repackSize) inSizeForReduce2 = repackSize;
        if (isEncrypted) needEncryptedRepack = true;
      }
    }
  }

  var inSizeForReduce = 0;
  {
    final isSolid = numSolidFiles > 1 && numSolidBytes != 0;
    for (final ui in updateItems) {
      if (ui.newData) {
        if (ui.size == -1) {
          isThereUnknownSize = true;
        } else {
          complexity += ui.size;
          if (isSolid) {
            inSizeForReduce += ui.size;
          } else if (inSizeForReduce < ui.size) {
            inSizeForReduce = ui.size;
          }
        }
      }
    }
  }
  if (isThereUnknownSize) {
    inSizeForReduce = -1;
  } else {
    updateCallback.setTotal(complexity);
  }
  if (inSizeForReduce != -1 && inSizeForReduce < inSizeForReduce2) {
    inSizeForReduce = inSizeForReduce2;
  }
  final int? reduceSize = inSizeForReduce == -1 ? null : inSizeForReduce;

  final lps = _LocalProgress(updateCallback);

  {
    final analysis = _Analysis();
    var analysisLevel = options.analysisLevel;
    if (analysisLevel < 0) analysisLevel = 5;
    if (analysisLevel != 0) {
      analysis.callback = opCallback;
      analysis.parseWav = true;
      if (analysisLevel >= 5) {
        analysis.parseExe = true;
        analysis.parseExeUnix = true;
        if (analysisLevel >= 7) {
          analysis.parseNoExt = true;
          if (analysisLevel >= 9) analysis.parseAll = true;
        }
      }
    }

    // Split files to groups
    for (var i = 0; i < updateItems.length; i++) {
      final ui = updateItems[i];
      if (!ui.newData || !ui.hasStream) continue;
      final fm = FilterMode2();
      if (useFilters) analysis.getFilterGroup(i, ui, fm);
      fm.encrypted = method0.passwordIsDefined;
      final groupIndex = _getGroup(filters, fm);
      while (groupIndex >= groups.length) {
        groups.add(_SolidGroup());
      }
      groups[groupIndex].indices.add(i);
    }
  }

  String? repackPassword;
  if (needEncryptedRepack) {
    if (method0.passwordIsDefined) {
      repackPassword = method0.password;
    } else {
      if (updateCallback is! CryptoGetTextPassword) {
        throw const SevenZipException(
            'Password is required', SevenZipError.unsupportedMethod);
      }
      repackPassword =
          (updateCallback as CryptoGetTextPassword).cryptoGetTextPassword();
    }
  }

  // Compress
  final archive = OutArchive();
  final newDatabase = ArchiveDatabaseOut();
  archive.createAndWriteStartPrefix(seqOutStream);

  {
    // Write non-AUX dirs and Empty files
    final emptyRefs = <int>[];
    for (var i = 0; i < updateItems.length; i++) {
      final ui = updateItems[i];
      if (ui.newData) {
        if (ui.hasStream) continue;
      } else if (ui.indexInArchive != -1 &&
          db!.files[ui.indexInArchive].hasStream) {
        continue;
      }
      emptyRefs.add(i);
    }
    emptyRefs
        .sort((a, b) => _compareEmptyItems(updateItems[a], updateItems[b]));
    for (final ref in emptyRefs) {
      final ui = updateItems[ref];
      FileItem file;
      FileItem2 file2;
      String name;
      if (ui.newProps) {
        file = FileItem();
        file2 = FileItem2();
        _updateItemToFileItem(ui, file, file2);
        file.crcDefined = false;
        name = ui.name;
      } else {
        (file, file2) = _getFile(db!, ui.indexInArchive);
        name = db.getPath(ui.indexInArchive);
      }
      newDatabase.addFile(file, file2, name);
    }
  }

  lps.progressOffset = 0;

  {
    // Sort Filters
    for (var i = 0; i < filters.length; i++) {
      filters[i].groupIndex = i;
    }
    filters.sort((a, b) => a.compare(b));
  }

  final decoder = Decoder();

  for (var groupIndex = 0; groupIndex < filters.length; groupIndex++) {
    final filterMode = filters[groupIndex];
    final method = method0.copy();
    _makeExeMethod(
        method,
        filterMode,
        options.maxFilter && options.multiThreadMixer,
        options.disabledFilterIDs);

    if (filterMode.encrypted) {
      if (!method.passwordIsDefined) {
        if (repackPassword != null) method.password = repackPassword;
        method.passwordIsDefined = true;
      }
    } else {
      method.passwordIsDefined = false;
      method.password = '';
    }

    final encoder = Encoder(method);

    // Repack and copy old solid blocks
    final group = groups[filterMode.groupIndex];
    for (final rep in group.folderRefs) {
      final folderIndex = rep.folderIndex;
      final numUnpackStreams = db!.numUnpackStreamsVector[folderIndex];

      if (rep.numCopyFiles == numUnpackStreams) {
        if (opCallback != null) {
          opCallback.reportOperation(
              EventIndexType.blockIndex, folderIndex, UpdateNotifyOp.replicate);
          var indexInFolder = 0;
          for (var fi = db.folderStartFileIndex[folderIndex];
              indexInFolder < numUnpackStreams;
              fi++) {
            if (db.files[fi].hasStream) {
              indexInFolder++;
              opCallback.reportOperation(
                  EventIndexType.inArcIndex, fi, UpdateNotifyOp.replicate);
            }
          }
        }

        // Copy old solid block
        final packSize = db.getFolderFullPackSize(folderIndex);
        _writeRange(inStream!, archive.seqStream,
            db.getFolderStreamPos(folderIndex, 0), packSize);
        lps.progressOffset += packSize;

        final folderIndexNew = newDatabase.folders.length;
        final folder = Folder();
        newDatabase.folders.add(folder);
        if (db.folderCRCs.validAndDefined(folderIndex)) {
          newDatabase.folderUnpackCRCs
              .setItem(folderIndexNew, true, db.folderCRCs.vals[folderIndex]);
        }
        db.parseFolderInfo(folderIndex, folder);
        final startIndex = db.foStartPackStreamIndex[folderIndex];
        for (var j = 0; j < folder.packStreams.length; j++) {
          newDatabase.packSizes.add(db.getStreamPackSize(startIndex + j));
        }
        for (var k = db.foToCoderUnpackSizes[folderIndex];
            k < db.foToCoderUnpackSizes[folderIndex + 1];
            k++) {
          newDatabase.coderUnpackSizes.add(db.coderUnpackSizes[k]);
        }
      } else {
        // Repack old solid block
        final extractStatuses = <bool>[];
        var indexInFolder = 0;
        opCallback?.reportOperation(
            EventIndexType.blockIndex, folderIndex, UpdateNotifyOp.repack);
        var sizeToEncode = 0;
        for (var fi = db.folderStartFileIndex[folderIndex];
            indexInFolder < numUnpackStreams;
            fi++) {
          var needExtract = false;
          final file = db.files[fi];
          if (file.hasStream) {
            indexInFolder++;
            final updateIndex = fileIndexToUpdateIndexMap[fi];
            if (updateIndex >= 0 && !updateItems[updateIndex].newData) {
              needExtract = true;
            }
          }
          extractStatuses.add(needExtract);
          if (needExtract) sizeToEncode += file.size;
        }

        var startPackIndex = newDatabase.packSizes.length;
        int curUnpackSize;
        {
          final crypto = DecoderCryptoVars(
              repackPassword == null ? null : () => repackPassword);
          InStream decodedStream;
          try {
            decodedStream = decoder.decode(
                inStream!,
                db.arcInfo.dataStartPosition,
                db,
                folderIndex,
                null,
                crypto,
                coderContext);
          } on SevenZipException catch (e) {
            extractCallback?.reportExtractResult(EventIndexType.blockIndex,
                folderIndex, OperationResult.unsupportedMethod);
            throw SevenZipException(e.message, e.kind);
          }
          final fos2 =
              _FolderInStream2(db, opCallback, extractCallback, decodedStream);
          final startIndex = db.folderStartFileIndex[folderIndex];
          fos2.init(startIndex, extractStatuses);
          // CRepackInStreamWithSizes
          final inStreamSizeCount = CountingInStream(fos2);
          int? repackSubStreamSize(int subStream) {
            if (subStream >= extractStatuses.length) return null;
            if (extractStatuses[subStream]) {
              final fi = db.files[startIndex + subStream];
              if (fi.hasStream) return fi.size;
            }
            return 0;
          }

          final folder = Folder();
          newDatabase.folders.add(folder);
          try {
            encoder.encode1(inStreamSizeCount, reduceSize, sizeToEncode, folder,
                archive.seqStream, newDatabase.packSizes,
                progress: lps.setRatio, subStreamSize: repackSubStreamSize);
          } on SevenZipException catch (e) {
            if (e.kind == SevenZipError.crc) rethrow;
            if (e.kind == SevenZipError.data ||
                e.kind == SevenZipError.unexpectedEnd) {
              extractCallback?.reportExtractResult(EventIndexType.blockIndex,
                  folderIndex, OperationResult.dataError);
            }
            rethrow;
          }
          curUnpackSize = inStreamSizeCount.count;
          encoder.encodePost(curUnpackSize, newDatabase.coderUnpackSizes);
          if (!fos2.finished) {
            throw const SevenZipException(
                'Repack did not finish', SevenZipError.data);
          }
          if (curUnpackSize != sizeToEncode) {
            throw const SevenZipException(
                'Repack size mismatch', SevenZipError.data);
          }
        }
        for (;
            startPackIndex < newDatabase.packSizes.length;
            startPackIndex++) {
          lps.outSize += newDatabase.packSizes[startPackIndex];
        }
        lps.inSize += curUnpackSize;
      }

      newDatabase.numUnpackStreamsVector.add(rep.numCopyFiles);

      var indexInFolder = 0;
      for (var fi = db.folderStartFileIndex[folderIndex];
          indexInFolder < numUnpackStreams;
          fi++) {
        if (db.files[fi].hasStream) {
          indexInFolder++;
          final updateIndex = fileIndexToUpdateIndexMap[fi];
          if (updateIndex >= 0) {
            final ui = updateItems[updateIndex];
            if (ui.newData) continue;
            var (file, file2) = _getFile(db, fi);
            String name;
            if (ui.newProps) {
              _updateItemToFileItem2(ui, file2);
              file.isDir = ui.isDir;
              name = ui.name;
            } else {
              name = db.getPath(fi);
            }
            newDatabase.addFile(file, file2, name);
          }
        }
      }
    }

    // Compress files to new solid blocks
    final numFiles = group.indices.length;
    if (numFiles == 0) continue;
    final sortByType = options.useTypeSorting;
    final refItems = [
      for (final idx in group.indices)
        _RefItem(idx, updateItems[idx], sortByType)
    ];
    refItems.sort((a, b) => _compareUpdateItems(a, b, sortByType));
    final indices = [for (final r in refItems) r.index];

    for (var i = 0; i < numFiles;) {
      var totalSize = 0;
      var numSubFiles = 0;
      String? prevExtension;
      for (numSubFiles = 0;
          i + numSubFiles < numFiles && numSubFiles < numSolidFiles;
          numSubFiles++) {
        final ui = updateItems[indices[i + numSubFiles]];
        totalSize += ui.size;
        if (totalSize > numSolidBytes) break;
        if (options.solidExtension) {
          final slashPos = _reverseFindPathSepar(ui.name);
          final dotPos = _reverseFindDot(ui.name);
          final ext = ui.name
              .substring(dotPos <= slashPos ? ui.name.length : dotPos + 1);
          if (numSubFiles == 0) {
            prevExtension = ext;
          } else if (ext.toLowerCase() != prevExtension!.toLowerCase()) {
            break;
          }
        }
      }
      if (numSubFiles < 1) numSubFiles = 1;

      lps.setCur();

      final inStreamSpec = FolderInStream()
        ..needCTime = options.needCTime
        ..needATime = options.needATime
        ..needMTime = options.needMTime
        ..needAttrib = options.needAttrib;
      inStreamSpec.init(updateCallback, indices, i, numSubFiles);

      var startPackIndex = newDatabase.packSizes.length;
      final expectedDataSize = totalSize;
      final folder = Folder();
      newDatabase.folders.add(folder);
      encoder.encode1(inStreamSpec, reduceSize, expectedDataSize, folder,
          archive.seqStream, newDatabase.packSizes,
          progress: lps.setRatio, subStreamSize: inStreamSpec.getSubStreamSize);
      if (!inStreamSpec.wasFinished) {
        throw StateError('Folder input was not finished');
      }
      final curFolderUnpackSize = inStreamSpec.totalSizeForCoder;
      encoder.encodePost(curFolderUnpackSize, newDatabase.coderUnpackSizes);

      var packSize = 0;
      for (; startPackIndex < newDatabase.packSizes.length; startPackIndex++) {
        packSize += newDatabase.packSizes[startPackIndex];
      }
      lps.outSize += packSize;

      var numUnpackStreams = 0;
      var skippedSize = 0;
      var procSize = 0;
      for (var subIndex = 0; subIndex < numSubFiles; subIndex++) {
        final ui = updateItems[indices[i + subIndex]];
        FileItem file;
        FileItem2 file2;
        String name;
        if (ui.newProps) {
          file = FileItem();
          file2 = FileItem2();
          _updateItemToFileItem(ui, file, file2);
          name = ui.name;
        } else {
          (file, file2) = _getFile(db!, ui.indexInArchive);
          name = db.getPath(ui.indexInArchive);
        }
        if (file2.isAnti || file.isDir) {
          throw StateError('Anti item or dir in a solid block');
        }
        if (!inStreamSpec.processed[subIndex]) {
          skippedSize += ui.size;
          continue;
        }
        file.crc = inStreamSpec.crcs[subIndex];
        file.size = inStreamSpec.sizes[subIndex];
        procSize += file.size;
        if (file.size != 0) {
          file.crcDefined = true;
          file.hasStream = true;
          numUnpackStreams++;
        } else {
          file.crcDefined = false;
          file.hasStream = false;
        }
        if (inStreamSpec.timesDefined[subIndex]) {
          if (inStreamSpec.needCTime) {
            file2.cTimeDefined = true;
            file2.cTime = inStreamSpec.cTimes[subIndex];
          }
          if (inStreamSpec.needATime) {
            file2.aTimeDefined = true;
            file2.aTime = inStreamSpec.aTimes[subIndex];
          }
          if (inStreamSpec.needMTime) {
            file2.mTimeDefined = true;
            file2.mTime = inStreamSpec.mTimes[subIndex];
          }
          if (inStreamSpec.needAttrib) {
            file2.attribDefined = true;
            file2.attrib = inStreamSpec.attribs[subIndex];
          }
        }
        newDatabase.addFile(file, file2, name);
      }

      if (procSize != curFolderUnpackSize) {
        throw StateError('Folder size mismatch');
      }
      lps.inSize += procSize;
      newDatabase.numUnpackStreamsVector.add(numUnpackStreams);
      i += numSubFiles;

      if (skippedSize != 0 && complexity >= skippedSize) {
        complexity -= skippedSize;
        updateCallback.setTotal(complexity);
      }
    }
  }

  lps.setCur();

  {
    final numFolders = newDatabase.folders.length;
    if (newDatabase.numUnpackStreamsVector.length != numFolders ||
        newDatabase.folderUnpackCRCs.defs.length > numFolders) {
      throw StateError('Bad new database');
    }
    newDatabase.folderUnpackCRCs.ifNonEmptyFillResidueWithFalse(numFolders);
  }

  opCallback?.reportOperation(
      EventIndexType.noIndex, -1, UpdateNotifyOp.header);

  archive.writeDatabase(
      newDatabase, options.headerMethod, options.headerOptions);
  vStreamSetRestriction?.setRestriction(0, 0);
}
