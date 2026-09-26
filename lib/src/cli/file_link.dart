// The reparse data of Windows symbolic links: Windows/FileLink.cpp of the
// LZMA SDK (FillLinkData_WinLink, CReparseAttr::Parse, CReparseAttr::GetPath).
//
// With -snl the Windows build stores a symbolic link as its reparse data
// (FSCTL_GET_REPARSE_POINT). dart:io can not read reparse data, so the port
// builds the data from the link target with FillLinkData_WinLink, the
// function the SDK uses to create links: for links made by "mklink" the
// result is the data Windows stores.

import 'dart:convert';
import 'dart:typed_data';

import 'platform.dart';

/// Z7_WIN_IO_REPARSE_TAG_MOUNT_POINT (junction).
const int kReparseTagMountPoint = 0xA0000003;

/// Z7_WIN_IO_REPARSE_TAG_SYMLINK.
const int kReparseTagSymLink = 0xA000000C;

/// Z7_WIN_IO_REPARSE_TAG_LX_SYMLINK (WSL).
const int kReparseTagLxSymLink = 0xA000001D;

/// Z7_WIN_SYMLINK_FLAG_RELATIVE.
const int kSymLinkFlagRelative = 1;

const int _kLxSymLinkVersion2 = 2;
const String _kLinkPrefix = '\\??\\';
const String _kLinkPrefixUnc = '\\??\\UNC\\';
const int _kLinkPrefixSize = 4;
const int _kLinkSizeLimit = 1 << 16;

// IsNetworkPath (FileName.cpp, Windows)
bool _isNetworkPath(String s) {
  if (s.length < 2 ||
      !isPathSepar(s.codeUnitAt(0)) ||
      !isPathSepar(s.codeUnitAt(1))) {
    return false;
  }
  if (isSuperPath(s) &&
      s.length >= kSuperUncPathPrefixSize &&
      s.substring(kSuperPathPrefixSize, kSuperPathPrefixSize + 3)
              .toUpperCase() ==
          'UNC' &&
      isPathSepar(s.codeUnitAt(kSuperPathPrefixSize + 3))) {
    return true;
  }
  final c = s.length > 2 ? s.codeUnitAt(2) : 0;
  return c != 0x2E && c != 0x3F;
}

/// FillLinkData_WinLink: null when the data can not be made.
Uint8List? fillLinkDataWinLink(String path, bool isSymLink) {
  var isAbs = false;
  if (path.isNotEmpty && isPathSepar(path.codeUnitAt(0))) {
    // root paths "\dir1\path" are marked as relative
    if (path.length > 1 && isPathSepar(path.codeUnitAt(1))) isAbs = true;
  } else {
    isAbs = isAbsolutePath(path);
  }
  if (!isAbs && !isSymLink) return null;

  var needPrintName = true;
  var subs = path;
  if (isAbs) {
    final isSuper = isSuperPath(path);
    if (!isSuper && _isNetworkPath(path)) {
      subs = _kLinkPrefixUnc + path.substring(2);
    } else {
      if (isSuper) {
        path = path.substring(kSuperPathPrefixSize);
        if (!isDrivePath(path)) needPrintName = false;
      }
      subs = _kLinkPrefix + path;
    }
  }
  final len1 = subs.length * 2;
  var len2 = path.length * 2;
  if (!needPrintName) len2 = 0;
  var totalNamesSize = len1 + len2;
  final newOrderScheme = isSymLink;
  if (!newOrderScheme) totalNamesSize += 2 * 2;

  final size = 8 + 8 + (isSymLink ? 4 : 0) + totalNamesSize;
  if (size >= _kLinkSizeLimit) return null;
  final dest = Uint8List(size);
  final bd = ByteData.sublistView(dest);
  bd.setUint32(0, isSymLink ? kReparseTagSymLink : kReparseTagMountPoint,
      Endian.little);
  bd.setUint16(4, size - 8, Endian.little);
  bd.setUint16(6, 0, Endian.little);
  var p = 8;
  var subOffs = 0;
  var printOffs = 0;
  if (newOrderScheme) {
    subOffs = len2;
  } else {
    printOffs = len1 + 2;
  }
  bd.setUint16(p, subOffs, Endian.little);
  bd.setUint16(p + 2, len1, Endian.little);
  bd.setUint16(p + 4, printOffs, Endian.little);
  bd.setUint16(p + 6, len2, Endian.little);
  p += 8;
  if (isSymLink) {
    bd.setUint32(p, isAbs ? 0 : kSymLinkFlagRelative, Endian.little);
    p += 4;
  }
  void writeString(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      bd.setUint16(off + i * 2, s.codeUnitAt(i), Endian.little);
    }
  }

  writeString(p + subOffs, subs);
  if (needPrintName) writeString(p + printOffs, path);
  return dest;
}

/// CReparseAttr.
class ReparseAttr {
  int tag = 0;
  int flags = 0;
  String subsName = '';
  String printName = '';
  String wslName = '';

  bool get isMountPoint => tag == kReparseTagMountPoint;
  bool get isSymLinkWin => tag == kReparseTagSymLink;
  bool get isSymLinkWsl => tag == kReparseTagLxSymLink;
  bool get isRelativeWin => flags == kSymLinkFlagRelative;
  bool get isRelativeWsl => !wslName.startsWith('/');

  // GetString
  static String _getString(Uint8List p, int off, int len) {
    final r = StringBuffer();
    for (var i = 0; i < len; i++) {
      final c = p[off + i * 2] | (p[off + i * 2 + 1] << 8);
      if (c == 0) break;
      r.writeCharCode(c);
    }
    return r.toString();
  }

  /// CReparseAttr::Parse.
  bool parse(Uint8List data) {
    var size = data.length;
    if (size < 8) return false;
    final bd = ByteData.sublistView(data);
    tag = bd.getUint32(0, Endian.little);
    var len = bd.getUint16(4, Endian.little);
    var p = 8;
    size -= 8;
    if (len != size) return false;
    if (tag != kReparseTagMountPoint &&
        tag != kReparseTagSymLink &&
        tag != kReparseTagLxSymLink) {
      return false;
    }
    if (tag == kReparseTagLxSymLink) {
      if (len < 4) return false;
      if (bd.getUint32(p, Endian.little) != _kLxSymLinkVersion2) return false;
      len -= 4;
      p += 4;
      var i = 0;
      while (i < len && data[p + i] != 0) {
        i++;
      }
      wslName = utf8.decode(Uint8List.sublistView(data, p, p + i),
          allowMalformed: true);
      return true;
    }
    if (len < 8) return false;
    final subOffs = bd.getUint16(p, Endian.little);
    final subLen = bd.getUint16(p + 2, Endian.little);
    final printOffs = bd.getUint16(p + 4, Endian.little);
    final printLen = bd.getUint16(p + 6, Endian.little);
    len -= 8;
    p += 8;
    flags = 0;
    if (tag == kReparseTagSymLink) {
      if (len < 4) return false;
      flags = bd.getUint32(p, Endian.little);
      len -= 4;
      p += 4;
    }
    if ((subOffs & 1) != 0 || subOffs > len || len - subOffs < subLen) {
      return false;
    }
    if ((printOffs & 1) != 0 || printOffs > len || len - printOffs < printLen) {
      return false;
    }
    subsName = _getString(data, p + subOffs, subLen >> 1);
    printName = _getString(data, p + printOffs, printLen >> 1);
    return true;
  }

  /// CReparseAttr::GetPath.
  String getPath() {
    var s = subsName;
    if (isSymLinkWsl) return wslName;
    if (s.startsWith(_kLinkPrefix)) {
      if (s.toUpperCase().startsWith(_kLinkPrefixUnc)) {
        s = '\\${s.substring(7)}';
      } else {
        s = '${s.substring(0, 1)}\\${s.substring(2)}';
        if (isDrivePath(s, _kLinkPrefixSize)) s = s.substring(_kLinkPrefixSize);
      }
    }
    return s;
  }
}
