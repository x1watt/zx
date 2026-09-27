// Reolink / Swann PAK firmware files (read only).
//
// The layout and the checksum rule follow pakler 0.2.0 by Vincent Mallet
// (MIT license, see LICENSE), checked against real firmware files:
//
//   header       <III   magic 0x32725913, crc32, type    (64-bit: <QQQ)
//   N sections   <32s24sII   name, version, start, len  (64-bit: <32s24sQQ)
//   N MTD parts  <32sI32sII  name, a, mtd, start, len
//
// Firmware for 64-bit devices widens the header and the section offsets
// to 8 bytes: the high halves of magic, crc and type are then zero, while
// in the 32-bit layout those places hold the crc and the start of the
// first section name, which can not all be zero (pakler's is_64bit).
//
// The number of sections is not stored. The MTD table repeats the first
// section's name in its first entry, so the count is the index of the
// first entry after section 0 that starts with that name (pakler's
// get_section_count, at most 30). The MTD table has as many entries.
//
// The header checksum is a CRC-32 register that starts at 0 (zlib's
// crc32 seeded with 0xFFFFFFFF, then xored with 0xFFFFFFFF), run over all
// bytes after the header up to the end of the file, then the four bytes
// 02 00 00 00, then the section table.
//
// Items are the non-empty sections, named after the section ("kernel",
// "rootfs"...; "section<N>" when the name is empty, "<name>_<N>" when a
// name repeats), in table order. The section number, the version string
// and the matching MTD partition (by name) are in the item's comment; the
// whole MTD table is in the archive comment.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../item_streams.dart';

const int kPakMagic = 0x32725913;
const int _kMtdSize = 76;
const int _kMaxSections = 30;

/// A section of the PAK table.
class PakSection {
  final int index;
  final String name;
  final String version;
  final int start;
  final int len;
  PakSection(this.index, this.name, this.version, this.start, this.len);
}

/// An entry of the MTD partition table.
class PakMtdPart {
  final String name;
  final int a;
  final String mtd;
  final int start;
  final int len;
  PakMtdPart(this.name, this.a, this.mtd, this.start, this.len);
}

class _Item {
  final PakSection s;
  final String path;
  final PakMtdPart? mtd;
  _Item(this.s, this.path, this.mtd);
}

/// The PAK handler.
class PakHandler extends ReadOnlyHandler {
  SeekableInStream? _stream;
  bool is64 = false;
  int storedCrc = 0;
  int type = 0;
  int headerSize = 0;
  final List<PakSection> sections = [];
  final List<PakMtdPart> mtdParts = [];
  final List<_Item> _items = [];
  int? _computedCrc;
  int _phySize = 0;
  bool _unexpectedEnd = false;

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.size,
    Kpid.packSize,
    Kpid.offset,
    Kpid.comment,
  ];

  static const List<int> _arcProps = [
    Kpid.bit64,
    Kpid.headersSize,
    Kpid.checksum,
    Kpid.comment,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final len = stream.length;
    final h = readAt(stream, 0, 24);
    if (h.length < 24 || getUint32LE(h, 0) != kPakMagic) return false;
    // PAK.is_64bit
    is64 = getUint32LE(h, 4) == 0 &&
        getUint32LE(h, 12) == 0 &&
        getUint32LE(h, 20) == 0;
    final hdrHdr = is64 ? 24 : 12;
    final secSize = is64 ? 72 : 64;
    // PAK.get_section_count
    final table = readAt(stream, hdrHdr, secSize * (_kMaxSections + 1));
    if (table.length < secSize) return false;
    var nameLen = 0;
    while (nameLen < 32 && table[nameLen] != 0) {
      nameLen++;
    }
    if (nameLen == 0) return false;
    var count = 0;
    for (var k = 1; k <= _kMaxSections; k++) {
      final o = k * secSize;
      if (o + nameLen > table.length) break;
      var same = true;
      for (var i = 0; i < nameLen; i++) {
        if (table[o + i] != table[i]) {
          same = false;
          break;
        }
      }
      if (same) {
        count = k;
        break;
      }
    }
    if (count == 0) return false;
    headerSize = hdrHdr + count * secSize + count * _kMtdSize;
    if (headerSize > len) return false;
    final hdr = readAt(stream, 0, headerSize);
    if (hdr.length != headerSize) return false;
    if (is64) {
      storedCrc = getUint64LE(hdr, 8);
      type = getUint64LE(hdr, 16);
    } else {
      storedCrc = getUint32LE(hdr, 4);
      type = getUint32LE(hdr, 8);
    }
    for (var i = 0; i < count; i++) {
      final o = hdrHdr + i * secSize;
      final start = is64 ? getUint64LE(hdr, o + 56) : getUint32LE(hdr, o + 56);
      final slen = is64 ? getUint64LE(hdr, o + 64) : getUint32LE(hdr, o + 60);
      sections.add(PakSection(
          i, cString(hdr, o, 32), cString(hdr, o + 32, 24), start, slen));
    }
    final mtdBase = hdrHdr + count * secSize;
    for (var i = 0; i < count; i++) {
      final o = mtdBase + i * _kMtdSize;
      mtdParts.add(PakMtdPart(
          cString(hdr, o, 32),
          getUint32LE(hdr, o + 32),
          cString(hdr, o + 36, 32),
          getUint32LE(hdr, o + 68),
          getUint32LE(hdr, o + 72)));
    }
    _phySize = headerSize;
    final used = <String>{};
    for (final s in sections) {
      if (s.len == 0) continue;
      if (s.start < headerSize) return false;
      final end = s.start + s.len;
      if (end > _phySize) _phySize = end;
      if (end > len) _unexpectedEnd = true;
      var path = s.name.isEmpty ? 'section${s.index}' : s.name;
      if (!used.add(path)) {
        path = '${path}_${s.index}';
        used.add(path);
      }
      PakMtdPart? mtd;
      for (final m in mtdParts) {
        if (m.name == s.name) {
          mtd = m;
          break;
        }
      }
      _items.add(_Item(s, path, mtd));
    }
    if (_phySize > len) _phySize = len;
    _stream = stream;
    _computedCrc = _calcCrc(stream, hdr, hdrHdr, count * secSize);
    return true;
  }

  // PAK.calc_crc
  int _calcCrc(SeekableInStream s, Uint8List hdr, int tableOff, int tableLen) {
    final buf = Uint8List(1 << 16);
    var v = 0;
    s.position = headerSize;
    for (;;) {
      final n = s.read(buf, 0, buf.length);
      if (n == 0) break;
      v = crc32Update(v, buf, 0, n);
    }
    buf[0] = 2;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0;
    v = crc32Update(v, buf, 0, 4);
    v = crc32Update(v, hdr, tableOff, tableOff + tableLen);
    return v & 0xFFFFFFFF;
  }

  /// True when the stored header CRC matches the file.
  bool get crcOk => _computedCrc == storedCrc;

  @override
  void close() {
    _stream = null;
    sections.clear();
    mtdParts.clear();
    _items.clear();
    _computedCrc = null;
    _phySize = 0;
    _unexpectedEnd = false;
  }

  @override
  int get numberOfItems => _items.length;

  static String _hex(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';

  String _itemComment(_Item it) {
    final sb = StringBuffer('section ${it.s.index}');
    if (it.s.version.isNotEmpty) sb.write(', version ${it.s.version}');
    final m = it.mtd;
    if (m != null) {
      sb.write(', mtd ${m.mtd} start ${_hex(m.start)} len ${_hex(m.len)}');
    }
    return sb.toString();
  }

  @override
  Object? getProperty(int index, int propId) {
    if (index < 0 || index >= _items.length) return null;
    final it = _items[index];
    switch (propId) {
      case Kpid.path:
        return it.path;
      case Kpid.isDir:
        return false;
      case Kpid.size:
      case Kpid.packSize:
        return it.s.len;
      case Kpid.offset:
        return it.s.start;
      case Kpid.comment:
        return _itemComment(it);
    }
    return null;
  }

  String _archiveComment() {
    final sb = StringBuffer('type ${_hex(type)}\n');
    for (final m in mtdParts) {
      sb.write('mtd part ${m.name}: ${m.mtd} a ${_hex(m.a)} '
          'start ${_hex(m.start)} len ${_hex(m.len)}\n');
    }
    return sb.toString();
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.phySize:
        return _phySize;
      case Kpid.headersSize:
        return headerSize;
      case Kpid.bit64:
        return is64;
      case Kpid.checksum:
        return _hex(storedCrc);
      case Kpid.comment:
        return _archiveComment();
      case Kpid.errorFlags:
        return _unexpectedEnd ? ErrorFlags.unexpectedEnd : 0;
      case Kpid.warningFlags:
        return crcOk ? null : ErrorFlags.crcError;
      case Kpid.warning:
        final c = _computedCrc;
        if (c == null || crcOk) return null;
        return 'Header CRC mismatch: stored ${_hex(storedCrc)}, '
            'computed ${_hex(c)}';
    }
    return null;
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(_items.length, indices, testMode, cb, (_) => false,
        (i) => _items[i].s.len, (i) => getStream(i)!,
        expectedSize: (i) => _items[i].s.len);
  }

  @override
  SeekableInStream? getStream(int index) {
    final s = _stream;
    if (s == null || index < 0 || index >= _items.length) return null;
    final sec = _items[index].s;
    var n = sec.len;
    if (sec.start + n > s.length) n = s.length - sec.start;
    if (n < 0) n = 0;
    return SubInStream(s, sec.start, n);
  }
}
