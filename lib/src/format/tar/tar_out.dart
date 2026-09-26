// Tar writer: the header writers of libarchive (BSD 2-clause, see LICENSE):
// archive_write_set_format_gnutar.c (GNU format with 'L' and 'K' long name
// headers and base-256 numbers), archive_write_set_format_ustar.c and
// archive_write_set_format_pax.c (ustar headers with a pax 'x' extended
// header only when a field does not fit: long or non-ASCII names, large
// sizes and ids, times out of range or with a fraction).
//
// The field layout follows GNU tar and 7-Zip: 7 octal digits and a NUL for
// mode, uid and gid, 11 digits and a NUL for size and mtime, the checksum
// as 6 digits, NUL, space. The writer only appends, so the archive can go
// to any OutStream (a pipe, or a gzip, bzip2 or xz compressor).

import 'dart:convert';
import 'dart:typed_data';

import '../../io/streams.dart';
import 'tar_header.dart';
import 'tar_in.dart';

/// The header format for new items.
enum TarWriteFormat {
  /// GNU tar format ("ustar  " magic, 'L' and 'K' headers, base-256
  /// numbers): what `7z a -ttar` writes by default (-mm=gnu).
  gnu,

  /// POSIX pax interchange format ("ustar" magic, pax extended headers
  /// when needed): -mm=pax or -mm=posix.
  pax,
}

/// An item to write: the fields of archive_entry that the writers use.
class TarOutItem {
  String name;

  /// The link target of a symbolic link.
  String? symLink;

  /// The target of a hard link (an earlier item of the archive).
  String? hardLink;

  /// Permission bits (07777).
  int mode;

  /// File type bits (PosixMode.regular, directory, symLink...).
  int fileType;

  int size;
  int uid;
  int gid;
  String user;
  String group;
  TarTime? mTime;
  TarTime? aTime;
  TarTime? cTime;
  int devMajor;
  int devMinor;

  /// The type flag of a regular file when it is not '0' (NUL of old
  /// archives, '7'), kept when a renamed item is written again.
  int? regularTypeFlag;

  TarOutItem(this.name,
      {this.symLink,
      this.hardLink,
      this.mode = 0x1A4, // 0644
      this.fileType = PosixMode.regular,
      this.size = 0,
      this.uid = 0,
      this.gid = 0,
      this.user = '',
      this.group = '',
      this.mTime,
      this.aTime,
      this.cTime,
      this.devMajor = 0,
      this.devMinor = 0});

  bool get isDir => fileType == PosixMode.directory;
}

/// Options of the pax writer for times.
class TarTimeOptions {
  /// Digits of the fraction of a second written in pax time records
  /// (0: whole seconds, 9: nanoseconds).
  int numDigits = 0;

  bool writeMTime = true;
  bool writeATime = false;
  bool writeCTime = false;
}

// get_ustar_max_mtime
const int _ustarMaxMtime = 0x1ffffffff;

/// Sequential tar writer.
class TarWriter {
  final OutStream out;
  final TarWriteFormat format;
  final TarTimeOptions times;

  /// Bytes written so far.
  int position = 0;

  int _entryRemaining = 0;
  int _entryPadding = 0;
  final Uint8List _zeros = Uint8List(kTarBlockSize);

  TarWriter(this.out, {this.format = TarWriteFormat.gnu, TarTimeOptions? times})
      : times = times ?? TarTimeOptions();

  // __archive_write_output
  void _output(Uint8List b, [int off = 0, int? len]) {
    final n = len ?? b.length - off;
    if (n == 0) return;
    out.write(b, off, n);
    position += n;
  }

  // __archive_write_nulls
  void _nulls(int n) {
    while (n > 0) {
      final k = n < kTarBlockSize ? n : kTarBlockSize;
      _output(_zeros, 0, k);
      n -= k;
    }
  }

  /// Writes bytes of an old archive unchanged (items kept by an update).
  void writeRaw(Uint8List b, int off, int len) => _output(b, off, len);

  /// archive_write_*_header: writes the header records of [item]. The item
  /// data ([TarOutItem.size] bytes, regular files only) follows with
  /// [writeData], then [finishEntry].
  void writeHeader(TarOutItem item) {
    if (format == TarWriteFormat.gnu) {
      _writeGnutarHeader(item);
    } else {
      _writePaxHeader(item);
    }
  }

  /// archive_write_*_data: [len] bytes of the item data.
  void writeData(Uint8List b, int off, int len) {
    if (len > _entryRemaining) len = _entryRemaining;
    _output(b, off, len);
    _entryRemaining -= len;
  }

  /// Bytes of data the current item still expects.
  int get entryRemaining => _entryRemaining;

  /// archive_write_*_finish_entry: fills missing data with zeros and pads
  /// the item to a 512 byte boundary.
  void finishEntry() {
    _nulls(_entryRemaining + _entryPadding);
    _entryRemaining = 0;
    _entryPadding = 0;
  }

  /// archive_write_*_close: the end marker (two zero blocks, as 7-Zip
  /// writes it).
  void close() {
    finishEntry();
    _nulls(kTarBlockSize * 2);
    out.flush();
  }

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

  static Uint8List _dirName(Uint8List p) {
    if (p.isNotEmpty && p[p.length - 1] != 0x2F) {
      return Uint8List.fromList([...p, 0x2F]);
    }
    return p;
  }

  // GNU format

  // archive_write_gnutar_header
  void _writeGnutarHeader(TarOutItem item) {
    var size = item.size;
    final hardLink = item.hardLink;
    final symLink = item.symLink;
    if (hardLink != null ||
        symLink != null ||
        item.fileType != PosixMode.regular) {
      size = 0;
    }
    var pathname = _utf8(item.name);
    if (item.fileType == PosixMode.directory && hardLink == null) {
      pathname = _dirName(pathname);
    }
    final uname = _utf8(item.user);
    final gname = _utf8(item.group);
    Uint8List linkname = Uint8List(0);
    if (hardLink != null) {
      linkname = _utf8(hardLink);
    } else if (symLink != null) {
      linkname = _utf8(symLink);
    }
    final buff = Uint8List(kTarBlockSize);
    if (linkname.length > TarHeader.linknameSize) {
      _writeGnuLongHeader(buff, TarType.gnuLongLink, linkname);
    }
    if (pathname.length > TarHeader.nameSize) {
      _writeGnuLongHeader(buff, TarType.gnuLongName, pathname);
    }
    int tartype;
    if (hardLink != null) {
      tartype = TarType.hardLink;
    } else {
      tartype = _typeFlagOf(item);
    }
    buff.fillRange(0, kTarBlockSize, 0);
    _formatGnutarHeader(buff, pathname, linkname, uname, gname, item.mode,
        item.uid, item.gid, size, _mtimeSec(item), tartype, item);
    _output(buff);
    _entryRemaining = size;
    _entryPadding = (-size) & 0x1FF;
  }

  // the 'L' / 'K' header with "././@LongLink" and the name with its NUL
  void _writeGnuLongHeader(Uint8List buff, int type, Uint8List name) {
    final length = name.length + 1;
    buff.fillRange(0, kTarBlockSize, 0);
    _formatGnutarHeader(buff, ascii.encode('././@LongLink'), Uint8List(0),
        Uint8List(0), Uint8List(0), 0x1A4, 0, 0, length, 0, type, null);
    _output(buff);
    _output(name);
    _nulls(1 + ((-length) & 0x1FF));
  }

  static int _typeFlagOf(TarOutItem item) {
    switch (item.fileType) {
      case PosixMode.symLink:
        return TarType.symLink;
      case PosixMode.charDevice:
        return TarType.charDevice;
      case PosixMode.blockDevice:
        return TarType.blockDevice;
      case PosixMode.directory:
        return TarType.directory;
      case PosixMode.fifo:
        return TarType.fifo;
    }
    if (item.symLink != null) return TarType.symLink;
    return item.regularTypeFlag ?? TarType.regular;
  }

  int _mtimeSec(TarOutItem item) {
    if (!times.writeMTime) return 0;
    return item.mTime?.sec ?? 0;
  }

  // archive_format_gnutar_header
  void _formatGnutarHeader(
      Uint8List h,
      List<int> name,
      Uint8List linkname,
      Uint8List uname,
      Uint8List gname,
      int mode,
      int uid,
      int gid,
      int size,
      int mtime,
      int tartype,
      TarOutItem? item) {
    _copyField(h, TarHeader.nameOffset, name, TarHeader.nameSize);
    _copyField(h, TarHeader.linknameOffset, linkname, TarHeader.linknameSize);
    _copyField(h, TarHeader.unameOffset, uname, TarHeader.unameSize);
    _copyField(h, TarHeader.gnameOffset, gname, TarHeader.gnameSize);
    tarFormatOctal(mode & 0xFFF, h, TarHeader.modeOffset, 7);
    tarFormatNumberGnu(uid, h, TarHeader.uidOffset, 7, 8);
    tarFormatNumberGnu(gid, h, TarHeader.gidOffset, 7, 8);
    tarFormatNumberGnu(size, h, TarHeader.sizeOffset, 11, 12);
    tarFormatOctal(mtime, h, TarHeader.mtimeOffset, 11);
    for (var i = 0; i < kGnuMagic.length; i++) {
      h[TarHeader.magicOffset + i] = kGnuMagic[i];
    }
    if (item != null &&
        (tartype == TarType.charDevice || tartype == TarType.blockDevice)) {
      tarFormatOctal(item.devMajor, h, TarHeader.rdevmajorOffset, 7);
      tarFormatOctal(item.devMinor, h, TarHeader.rdevminorOffset, 7);
    }
    h[TarHeader.typeflagOffset] = tartype;
    tarSetChecksum(h);
  }

  static void _copyField(Uint8List h, int off, List<int> s, int size) {
    final n = s.length < size ? s.length : size;
    for (var i = 0; i < n; i++) {
      h[off + i] = s[i];
    }
  }

  // ustar and pax formats

  // __archive_write_format_header_ustar: false when a field does not fit
  bool _formatUstarHeader(
      Uint8List h,
      List<int> path,
      List<int> linkname,
      List<int> uname,
      List<int> gname,
      int mode,
      int uid,
      int gid,
      int size,
      int mtime,
      int tartype,
      bool strict,
      TarOutItem? item) {
    var ok = true;
    h.fillRange(0, kTarBlockSize, 0);
    if (path.length <= TarHeader.nameSize) {
      _copyField(h, TarHeader.nameOffset, path, path.length);
    } else {
      // store in two pieces, splitting at a '/'
      var p = _indexOf(path, 0x2F, path.length - TarHeader.nameSize - 1);
      if (p == 0) p = _indexOf(path, 0x2F, 1);
      if (p < 0 || p == path.length - 1 || p > TarHeader.prefixSize) {
        ok = false;
      } else {
        _copyField(h, TarHeader.prefixOffset, path.sublist(0, p), p);
        _copyField(
            h, TarHeader.nameOffset, path.sublist(p + 1), path.length - p - 1);
      }
    }
    if (linkname.length > TarHeader.linknameSize) ok = false;
    _copyField(h, TarHeader.linknameOffset, linkname, TarHeader.linknameSize);
    _copyField(h, TarHeader.unameOffset, uname, TarHeader.unameSize);
    _copyField(h, TarHeader.gnameOffset, gname, TarHeader.gnameSize);
    if (strict) {
      tarFormatOctal(mode & 0xFFF, h, TarHeader.modeOffset, 7);
      tarFormatOctal(uid, h, TarHeader.uidOffset, 7);
      tarFormatOctal(gid, h, TarHeader.gidOffset, 7);
      tarFormatOctal(size, h, TarHeader.sizeOffset, 11);
      tarFormatOctal(mtime, h, TarHeader.mtimeOffset, 11);
    } else {
      tarFormatNumberUstar(mode & 0xFFF, h, TarHeader.modeOffset, 7, 8);
      tarFormatNumberUstar(uid, h, TarHeader.uidOffset, 7, 8);
      tarFormatNumberUstar(gid, h, TarHeader.gidOffset, 7, 8);
      tarFormatNumberUstar(size, h, TarHeader.sizeOffset, 11, 12);
      tarFormatNumberUstar(mtime, h, TarHeader.mtimeOffset, 11, 11);
    }
    for (var i = 0; i < kUstarMagic.length; i++) {
      h[TarHeader.magicOffset + i] = kUstarMagic[i];
    }
    h[TarHeader.versionOffset] = 0x30;
    h[TarHeader.versionOffset + 1] = 0x30;
    var major = 0;
    var minor = 0;
    if (item != null &&
        (tartype == TarType.charDevice || tartype == TarType.blockDevice)) {
      major = item.devMajor;
      minor = item.devMinor;
    }
    tarFormatNumberUstar(major, h, TarHeader.rdevmajorOffset, 7, 8);
    tarFormatNumberUstar(minor, h, TarHeader.rdevminorOffset, 7, 8);
    h[TarHeader.typeflagOffset] = tartype;
    tarSetChecksum(h);
    return ok;
  }

  static int _indexOf(List<int> s, int c, int start) {
    for (var i = start < 0 ? 0 : start; i < s.length; i++) {
      if (s[i] == c) return i;
    }
    return -1;
  }

  // archive_write_pax_header
  void _writePaxHeader(TarOutItem item) {
    final pax = BytesBuilder();
    final hardLink = item.hardLink;
    var path = _utf8(item.name);
    if (hardLink == null && item.fileType == PosixMode.directory) {
      path = _dirName(path);
    }
    final uname = _utf8(item.user);
    final gname = _utf8(item.group);
    Uint8List? linkpath;
    if (hardLink != null) {
      linkpath = _utf8(hardLink);
    } else if (item.symLink != null) {
      linkpath = _utf8(item.symLink!);
    }
    List<int> mainPath = path;
    List<int> mainLink = linkpath ?? const [];

    // A long or non-ASCII path goes to 'path'; the ustar name is a
    // shortened form.
    if (tarHasNonAscii(path)) {
      tarAddPaxAttr(pax, 'path', path);
      mainPath = _buildUstarEntryName(path, path.length, null);
    } else if (path.length > 100) {
      var suffix = _indexOf(path, 0x2F, path.length - 100 - 1);
      if (suffix == 0) suffix = _indexOf(path, 0x2F, 1);
      if (suffix < 0 || suffix == path.length - 1 || suffix > 155) {
        tarAddPaxAttr(pax, 'path', path);
        mainPath = _buildUstarEntryName(path, path.length, null);
      }
    }

    if (linkpath != null) {
      if (linkpath.length > 100 || tarHasNonAscii(linkpath)) {
        tarAddPaxAttr(pax, 'linkpath', linkpath);
        if (linkpath.length > 100) {
          mainLink = ascii.encode(
              hardLink != null ? '././@LongHardLink' : '././@LongSymLink');
        }
      }
    }

    final entryName = mainPath;
    var size = item.size;
    final isRegular = item.fileType == PosixMode.regular &&
        item.symLink == null &&
        hardLink == null;
    if (!isRegular) size = 0;

    if (item.gid >= (1 << 18)) {
      tarAddPaxAttrInt(pax, 'gid', item.gid);
    }
    if (gname.length > 31 || tarHasNonAscii(gname)) {
      tarAddPaxAttr(pax, 'gname', gname);
    }
    if (item.uid >= (1 << 18)) {
      tarAddPaxAttrInt(pax, 'uid', item.uid);
    }
    if (uname.length > 31 || tarHasNonAscii(uname)) {
      tarAddPaxAttr(pax, 'uname', uname);
    }
    final tartype = hardLink != null ? TarType.hardLink : _typeFlagOf(item);
    if (tartype == TarType.charDevice || tartype == TarType.blockDevice) {
      if (item.devMajor >= (1 << 18)) {
        tarAddPaxAttrInt(pax, 'SCHILY.devmajor', item.devMajor);
      }
      if (item.devMinor >= (1 << 18)) {
        tarAddPaxAttrInt(pax, 'SCHILY.devminor', item.devMinor);
      }
    }

    final mTime = times.writeMTime ? item.mTime : null;
    final mSec = mTime?.sec ?? 0;
    final mNs = mTime?.ns ?? 0;

    // times asked for by -mtc, -mta and -mtp
    final nd = times.numDigits;
    if (times.writeCTime && item.cTime != null) {
      tarAddPaxAttrTime(pax, 'ctime', item.cTime!.sec, item.cTime!.ns, nd);
    }
    if (times.writeATime && item.aTime != null) {
      tarAddPaxAttrTime(pax, 'atime', item.aTime!.sec, item.aTime!.ns, nd);
    }
    if (mTime != null &&
        (mSec < 0 || mSec >= _ustarMaxMtime || _hasFraction(mNs, nd))) {
      tarAddPaxAttrTime(pax, 'mtime', mSec, mNs, nd);
    }

    if (size >= (1 << 33)) tarAddPaxAttrInt(pax, 'size', size);

    final ustarbuff = Uint8List(kTarBlockSize);
    final mtimeField = mSec < 0 ? 0 : mSec;
    if (!_formatUstarHeader(
        ustarbuff,
        mainPath,
        mainLink,
        uname,
        gname,
        item.mode,
        item.uid,
        item.gid,
        size,
        mtimeField,
        tartype,
        false,
        item)) {
      throw const SevenZipException(
          'tar: a name does not fit in the header', SevenZipError.unsupported);
    }

    if (pax.isNotEmpty) {
      final body = pax.toBytes();
      final paxbuff = Uint8List(kTarBlockSize);
      var uid = item.uid;
      if (uid >= 1 << 18) uid = (1 << 18) - 1;
      var gid = item.gid;
      if (gid >= 1 << 18) gid = (1 << 18) - 1;
      // no S_ISUID, S_ISGID, S_ISVTX
      final mode = item.mode & 0x1FF;
      var s = mSec;
      if (s < 0) s = 0;
      if (s > _ustarMaxMtime) s = _ustarMaxMtime;
      _formatUstarHeader(
          paxbuff,
          _buildPaxAttributeName(entryName),
          const [],
          uname,
          gname,
          mode,
          uid,
          gid,
          body.length,
          s,
          TarType.paxLocal,
          true,
          null);
      _output(paxbuff);
      _output(body);
      _nulls((-body.length) & 0x1FF);
    }
    _output(ustarbuff);
    _entryRemaining = size;
    _entryPadding = (-size) & 0x1FF;
  }

  static bool _hasFraction(int ns, int numDigits) {
    if (numDigits <= 0 || ns == 0) return false;
    var div = 1;
    for (var i = numDigits; i < 9; i++) {
      div *= 10;
    }
    return ns ~/ div != 0;
  }

  // build_ustar_entry_name: a name of at most 155 + 1 + 99 bytes that the
  // ustar header can split (prefix, part of the dirname, the file name,
  // [insert] as an extra directory before the file name).
  static List<int> _buildUstarEntryName(
      List<int> src, int srcLength, String? insert) {
    final ins = insert == null ? null : ascii.encode(insert);
    var suffixLength = 98;
    final insertLength = ins == null ? 0 : ins.length + 2;
    if (srcLength < 100 && ins == null) return src.sublist(0, srcLength);

    var filenameEnd = srcLength;
    var needSlash = false;
    for (;;) {
      if (filenameEnd > 0 && src[filenameEnd - 1] == 0x2F) {
        filenameEnd--;
        needSlash = true;
        continue;
      }
      if (filenameEnd > 1 &&
          src[filenameEnd - 1] == 0x2E &&
          src[filenameEnd - 2] == 0x2F) {
        filenameEnd -= 2;
        needSlash = true;
        continue;
      }
      break;
    }
    if (filenameEnd == 0) {
      return [...?ins, 0x2F];
    }
    if (needSlash) suffixLength--;
    var filename = filenameEnd - 1;
    while (filename > 0 && src[filename] != 0x2F) {
      filename--;
    }
    if (src[filename] == 0x2F && filename < filenameEnd - 1) filename++;
    suffixLength -= insertLength;
    if (filenameEnd > filename + suffixLength) {
      filenameEnd = filename + suffixLength;
    }
    suffixLength -= filenameEnd - filename;

    const prefix = 0;
    var prefixEnd = prefix + 154;
    if (prefixEnd > filename) prefixEnd = filename;
    while (prefixEnd > prefix && src[prefixEnd] != 0x2F) {
      prefixEnd--;
    }
    if (prefixEnd < filename && src[prefixEnd] == 0x2F) prefixEnd++;

    final suffix = prefixEnd;
    var suffixEnd = suffix + suffixLength;
    if (suffixEnd > filename) suffixEnd = filename;
    if (suffixEnd < suffix) suffixEnd = suffix;
    while (suffixEnd > suffix && src[suffixEnd] != 0x2F) {
      suffixEnd--;
    }
    if (suffixEnd < filename && src[suffixEnd] == 0x2F) suffixEnd++;

    final dest = <int>[];
    if (prefixEnd > prefix) dest.addAll(src.sublist(prefix, prefixEnd));
    if (suffixEnd > suffix) dest.addAll(src.sublist(suffix, suffixEnd));
    if (ins != null) {
      dest.addAll(ins);
      dest.add(0x2F);
    }
    dest.addAll(src.sublist(filename, filenameEnd));
    if (needSlash) dest.add(0x2F);
    return dest;
  }

  // build_pax_attribute_name: "dir/PaxHeader/file"
  static List<int> _buildPaxAttributeName(List<int> src) {
    if (src.isEmpty) return ascii.encode('PaxHeader/blank');
    var p = src.length;
    for (;;) {
      if (p > 0 && src[p - 1] == 0x2F) {
        --p;
        continue;
      }
      if (p > 1 && src[p - 1] == 0x2E && src[p - 2] == 0x2F) {
        --p;
        continue;
      }
      break;
    }
    if (p == 0) return ascii.encode('/PaxHeader/rootdir');
    if (src[0] == 0x2E && p == 1) return ascii.encode('PaxHeader/currentdir');
    return _buildUstarEntryName(src, p, 'PaxHeader');
  }
}
