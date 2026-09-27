// MBR partitioned disk images (read only): the four entries of the master
// boot record and the logical partitions of an extended partition (the
// chain of extended boot records). Items are the partitions, readable as
// streams, named like 7-Zip ("0.fat", "2.img"), plus the unallocated space
// after the last partition as 7-Zip lists it ("4").
//
// Written for this package from the MBR layout facts (the partition table
// at offset 446, four 16 byte entries: status, CHS start, type, CHS end,
// LBA start, sector count; the 0x55 0xAA marker at 510; each extended boot
// record holding one logical partition relative to itself and a link to
// the next record relative to the start of the extended partition). Names
// and listed properties checked black box with 7-Zip's listing.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../archive_types.dart';
import '../fat/fat_handler.dart';
import '../iso/disc_streams.dart' show le32;
import '../item_streams.dart';
import 'part_sniff.dart';

const int _kSector = 512;

bool _isExtendedType(int t) => t == 0x05 || t == 0x0F || t == 0x85;

bool _hasGptSig(Uint8List b, int off) {
  const sig = 'EFI PART';
  if (b.length < off + 8) return false;
  for (var i = 0; i < 8; i++) {
    if (b[off + i] != sig.codeUnitAt(i)) return false;
  }
  return true;
}

/// The partition table of b[0, 512) looks valid: the marker, status bytes
/// 0 or 0x80, sizes of used entries not 0, starts after the MBR, at least
/// one used entry. [protective] is set to whether an entry has type 0xEE.
bool mbrTableValid(Uint8List b, {List<bool>? protective}) {
  if (b.length < 512 || b[510] != 0x55 || b[511] != 0xAA) return false;
  var used = 0;
  var ee = false;
  for (var i = 0; i < 4; i++) {
    final o = 446 + i * 16;
    final status = b[o];
    if (status != 0 && status != 0x80) return false;
    final type = b[o + 4];
    if (type == 0) continue;
    if (le32(b, o + 12) == 0 || le32(b, o + 8) == 0) return false;
    if (type == 0xEE) ee = true;
    used++;
  }
  if (protective != null && protective.isNotEmpty) protective[0] = ee;
  return used > 0;
}

/// IsArc for the format table: a valid table that is neither a GPT
/// protective MBR nor the boot sector of a FAT volume nor the system area
/// of an ISO 9660 image.
int isArcMbr(Uint8List p, int size) {
  if (size < 512) return 2;
  final ee = [false];
  if (!mbrTableValid(p, protective: ee)) return 0;
  if (ee[0] && (_hasGptSig(p, 512) || _hasGptSig(p, 4096))) return 0;
  if (size >= 0x8006 && _isIso(p, 0x8001)) return 0;
  if (parseFatBpb(p, 0) != null) return 0;
  return 1;
}

bool _isIso(Uint8List b, int o) =>
    b.length >= o + 5 &&
    b[o] == 0x43 &&
    b[o + 1] == 0x44 &&
    b[o + 2] == 0x30 &&
    b[o + 3] == 0x30 &&
    b[o + 4] == 0x31;

/// A partition (or the unallocated tail).
class MbrItem {
  int type = 0;
  int lba = 0;
  int sectors = 0;
  bool primary = true;
  bool active = false;
  bool tail = false;
  String chsBegin = '';
  String chsEnd = '';
  String path = '';
  String fileSystem = '';
  int get offset => lba * _kSector;
  int get size => sectors * _kSector;
}

// (file system name, item extension) of a partition type
(String, String) _typeInfo(int t) {
  switch (t) {
    case 0x01:
      return ('FAT12', 'fat');
    case 0x04:
      return ('FAT16 DOS 3.0+', 'fat');
    case 0x05:
      return ('Extended', '');
    case 0x06:
      return ('FAT16 DOS 3.31+', 'fat');
    case 0x0B:
      return ('FAT32', 'fat');
    case 0x0C:
      return ('FAT32-LBA', 'fat');
    case 0x0E:
      return ('FAT16-LBA', 'fat');
    case 0x0F:
      return ('Extended-LBA', '');
    case 0x27:
      return ('NTFS-WinRE', 'ntfs');
    case 0x82:
      return ('Solaris x86 / Linux swap', 'img');
    case 0x83:
      return ('Linux', 'img');
    case 0x85:
      return ('Linux extended', '');
    case 0x8E:
      return ('Linux LVM', 'lvm');
    case 0xA5:
      return ('BSD slice', 'img');
    case 0xEE:
      return ('GPT protective', 'img');
    case 0xEF:
      return ('EFI System', 'img');
    case 0xFD:
      return ('Linux RAID', 'img');
  }
  return ('$t', 'img');
}

String _chs(Uint8List b, int o) {
  final head = b[o];
  final sec = b[o + 1] & 0x3F;
  final cyl = ((b[o + 1] & 0xC0) << 2) | b[o + 2];
  return '$cyl-$head-$sec';
}

/// The MBR handler.
class MbrHandler extends ReadOnlyHandler {
  SeekableInStream? _s;
  final List<MbrItem> items = [];
  bool _headersError = false;

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.size,
    Kpid.fileSystem,
    Kpid.offset,
    Kpid.characts,
  ];

  static const List<int> _arcProps = [Kpid.id];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  int _diskId = 0;

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final head = readAt(stream, 0, 512);
    final ee = [false];
    if (!mbrTableValid(head, protective: ee)) return false;
    if (ee[0]) {
      // a GPT disk: the GPT handler lists it
      final ss = stream.length ~/ 512 * 512;
      if (_hasGptSig(readAt(stream, 512, 8), 0) ||
          _hasGptSig(readAt(stream, 4096, 8), 0) ||
          (ss >= 1024 && _hasGptSig(readAt(stream, ss - 512, 8), 0))) {
        return false;
      }
    }
    if (_isIso(readAt(stream, 0x8001, 5), 0)) return false;
    // a FAT boot sector with a table-like tail: the volume wins when no
    // partition fits in the disk
    if (parseFatBpb(head, 0) != null && !_anyFits(head, stream.length)) {
      return false;
    }
    _s = stream;
    _diskId = le32(head, 440);
    for (var i = 0; i < 4; i++) {
      final o = 446 + i * 16;
      final type = head[o + 4];
      if (type == 0) continue;
      final lba = le32(head, o + 8);
      final n = le32(head, o + 12);
      if (_isExtendedType(type)) {
        _readExtended(lba, n);
        continue;
      }
      items.add(_entry(head, o, 0, true));
    }
    var end = 0;
    for (final it in items) {
      final e = it.offset + it.size;
      if (e > end) end = e;
    }
    for (var i = 0; i < items.length; i++) {
      _name(items[i], i);
    }
    final len = stream.length;
    if (len > end && end > 0) {
      final t = MbrItem()
        ..tail = true
        ..lba = end ~/ _kSector
        ..sectors = (len - end) ~/ _kSector
        ..path = '${items.length}';
      if (t.sectors > 0) items.add(t);
    }
    return true;
  }

  static bool _anyFits(Uint8List b, int len) {
    for (var i = 0; i < 4; i++) {
      final o = 446 + i * 16;
      if (b[o + 4] == 0) continue;
      final end = (le32(b, o + 8) + le32(b, o + 12)) * _kSector;
      if (end <= len) return true;
    }
    return false;
  }

  MbrItem _entry(Uint8List b, int o, int base, bool primary) {
    return MbrItem()
      ..type = b[o + 4]
      ..lba = base + le32(b, o + 8)
      ..sectors = le32(b, o + 12)
      ..primary = primary
      ..active = b[o] == 0x80
      ..chsBegin = _chs(b, o + 1)
      ..chsEnd = _chs(b, o + 5);
  }

  // the chain of extended boot records
  void _readExtended(int extStart, int extSize) {
    final seen = <int>{};
    var cur = extStart;
    for (var guard = 0; guard < 4096; guard++) {
      if (!seen.add(cur)) {
        _headersError = true;
        return;
      }
      final b = readAt(_s!, cur * _kSector, 512);
      if (b.length < 512 || b[510] != 0x55 || b[511] != 0xAA) {
        _headersError = true;
        return;
      }
      const o0 = 446;
      if (b[o0 + 4] != 0 && le32(b, o0 + 12) != 0) {
        items.add(_entry(b, o0, cur, false));
      }
      const o1 = 446 + 16;
      final t1 = b[o1 + 4];
      final rel = le32(b, o1 + 8);
      if (!_isExtendedType(t1) || rel == 0) return;
      if (extSize != 0 && rel >= extSize) {
        _headersError = true;
        return;
      }
      cur = extStart + rel;
    }
  }

  void _name(MbrItem it, int index) {
    final (fs, typeExt) = _typeInfo(it.type);
    var ext = typeExt;
    var fsName = fs;
    if (ext == 'img' || it.type == 0x07) {
      final sniffed = sniffPartitionExt(_s!, it.offset, it.size);
      if (sniffed != null) ext = sniffed;
      if (it.type == 0x07) fsName = sniffedFsName(sniffed) ?? fs;
    }
    it.fileSystem = fsName;
    it.path = '$index.$ext';
  }

  @override
  void close() {
    _s = null;
    items.clear();
    _headersError = false;
    _diskId = 0;
  }

  @override
  int get numberOfItems => items.length;

  @override
  Object? getProperty(int index, int propId) {
    if (index < 0 || index >= items.length) return null;
    final it = items[index];
    switch (propId) {
      case Kpid.path:
        return it.path;
      case Kpid.isDir:
        return false;
      case Kpid.size:
        return it.size;
      case Kpid.packSize:
        return it.size;
      case Kpid.fileSystem:
        return it.tail ? null : it.fileSystem;
      case Kpid.offset:
        return it.offset;
      case Kpid.characts:
        if (it.tail) return null;
        final p = it.primary ? 'Primary' : 'Logical';
        return it.active
            ? '$p Active CHS:${it.chsBegin}..${it.chsEnd}'
            : '$p CHS:${it.chsBegin}..${it.chsEnd}';
    }
    return null;
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.phySize:
        return _s?.length;
      case Kpid.id:
        return _s == null
            ? null
            : _diskId.toRadixString(16).toUpperCase().padLeft(8, '0');
      case Kpid.errorFlags:
        return _headersError ? ErrorFlags.headersError : 0;
    }
    return null;
  }

  @override
  SeekableInStream? getStream(int index) {
    if (index < 0 || index >= items.length) return null;
    final it = items[index];
    return SubInStream(_s!, it.offset, it.size);
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(items.length, indices, testMode, cb, (i) => false,
        (i) => items[i].size, (i) => getStream(i)!,
        expectedSize: (i) => items[i].size);
  }
}
