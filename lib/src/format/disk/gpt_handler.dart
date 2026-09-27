// GPT partitioned disk images (read only): the GUID partition table header
// (with its CRC-32), the partition entry array (with its CRC-32), the
// backup header at the end of the disk when the primary one is damaged,
// 512 and 4096 byte logical sectors. Items are the partitions, readable as
// streams, named like 7-Zip ("0.EFI System.img") with the extension of
// the file system found in the partition when there is one ("0.fat").
//
// Written for this package from the UEFI specification (chapter 5, GUID
// Partition Table disk layout: the header and entry fields, the CRC rules,
// the partition attributes) and the documented partition type GUIDs.
// Names and listed properties checked black box with 7-Zip's listing and
// sgdisk.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../iso/disc_streams.dart' show le32, le64;
import '../item_streams.dart';
import 'part_sniff.dart';

bool _sigAt(Uint8List b, int off) {
  const sig = 'EFI PART';
  if (b.length < off + 8) return false;
  for (var i = 0; i < 8; i++) {
    if (b[off + i] != sig.codeUnitAt(i)) return false;
  }
  return true;
}

/// IsArc for the format table: a GPT header at LBA 1 (512 or 4096 byte
/// sectors), or a protective MBR (a partition of type 0xEE).
int isArcGpt(Uint8List p, int size) {
  if (size < 520) return 2;
  if (_sigAt(p, 512)) return 1;
  if (size >= 4104 && _sigAt(p, 4096)) return 1;
  if (p[510] == 0x55 && p[511] == 0xAA) {
    for (var i = 0; i < 4; i++) {
      if (p[446 + i * 16 + 4] == 0xEE) return 1;
    }
  }
  return 0;
}

/// A GUID as text (the first three fields little endian).
String guidToString(Uint8List b, int o) {
  String h(int v, int n) => v.toRadixString(16).toUpperCase().padLeft(n, '0');
  final sb = StringBuffer()
    ..write(h(le32(b, o), 8))
    ..write('-')
    ..write(h(b[o + 4] | (b[o + 5] << 8), 4))
    ..write('-')
    ..write(h(b[o + 6] | (b[o + 7] << 8), 4))
    ..write('-');
  for (var i = 8; i < 16; i++) {
    if (i == 10) sb.write('-');
    sb.write(h(b[o + i], 2));
  }
  return sb.toString();
}

// friendly names of the common partition type GUIDs (7-Zip's names where
// it has one) and the extension of their items
const Map<String, (String, String)> _types = {
  'C12A7328-F81F-11D2-BA4B-00A0C93EC93B': ('EFI System', 'img'),
  '024DEE41-33E7-11D3-9D69-0008C781F39F': ('MBR partition scheme', 'img'),
  '21686148-6449-6E6F-744E-656564454649': ('BIOS Boot', 'img'),
  'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7': ('Windows BDP', 'img'),
  'E3C9E316-0B5C-4DB8-817D-F92DF00215AE': ('Windows MSR', 'img'),
  'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC': ('Windows Recovery', 'img'),
  '5808C8AA-7E8F-42E0-85D2-E1E90434CFB3': ('Windows LDM Metadata', 'img'),
  'AF9B60A0-1431-4F62-BC68-3311714A69AD': ('Windows LDM Data', 'img'),
  '0FC63DAF-8483-4772-8E79-3D69D8477DE4': ('Linux Data', 'img'),
  '0657FD6D-A4AB-43C4-84E5-0933C84B4F4F': ('Linux Swap', 'img'),
  'E6D6D379-F507-44C2-A23C-238F2A3DF928': ('Linux LVM', 'img'),
  'A19D880F-05FC-4D3B-A006-743F0F84911E': ('Linux RAID', 'img'),
  '933AC7E1-2EB4-4F13-B844-0E14E2AEF915': ('Linux Home', 'img'),
  '44479540-F297-41B2-9AF7-D131D5F0458A': ('Linux Root x86', 'img'),
  '4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709': ('Linux Root x86-64', 'img'),
  'B921B045-1DF0-41C3-AF44-4C6F280D3FAE': ('Linux Root ARM64', 'img'),
  'CA7D7CCB-63ED-4C53-861C-1742536059CC': ('Linux LUKS', 'img'),
  'BC13C2FF-59E6-4262-A352-B275FD6F7172': ('Linux Extended Boot', 'img'),
  '48465300-0000-11AA-AA11-00306543ECAC': ('Apple HFS+', 'hfs'),
  '7C3457EF-0000-11AA-AA11-00306543ECAC': ('Apple APFS', 'img'),
  'FE3A2A5D-4F32-41A7-B725-ACCC3285A309': ('ChromeOS Kernel', 'img'),
  '3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC': ('ChromeOS Root', 'img'),
  '516E7CB6-6ECF-11D6-8FF8-00022D09712B': ('FreeBSD UFS', 'img'),
};

/// A partition.
class GptItem {
  int index = 0; // entry index in the table
  String typeGuid = '';
  String id = '';
  int firstLba = 0;
  int lastLba = 0;
  int attributes = 0;
  String name = '';
  String path = '';
  String fileSystem = '';
}

/// The GPT handler.
class GptHandler extends ReadOnlyHandler {
  SeekableInStream? _s;
  final List<GptItem> items = [];
  int sectorSize = 512;
  String diskId = '';
  bool usedBackup = false;
  bool _headersError = false;
  int _phySize = 0;

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.size,
    Kpid.fileSystem,
    Kpid.characts,
    Kpid.offset,
    Kpid.id,
  ];

  static const List<int> _arcProps = [Kpid.id, Kpid.sectorSize];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  // the header at [lba]: (header, entries) when both CRCs match, else null
  (Uint8List, Uint8List)? _readTable(int lba, int ss) {
    final s = _s!;
    if (lba <= 0 || (lba + 1) * ss > s.length) return null;
    final h = readAt(s, lba * ss, ss);
    if (!_sigAt(h, 0)) return null;
    final hs = le32(h, 12);
    if (hs < 92 || hs > ss) return null;
    final hc = Uint8List.fromList(Uint8List.sublistView(h, 0, hs));
    hc[16] = hc[17] = hc[18] = hc[19] = 0;
    if (Crc32.of(hc) != le32(h, 16)) return null;
    if (le64(h, 24) != lba) return null;
    final n = le32(h, 80);
    final es = le32(h, 84);
    if (es < 128 || (es & 7) != 0 || es > 4096) return null;
    if (n == 0 || n * es > (1 << 22)) return null;
    final eLba = le64(h, 72);
    final e = readAt(s, eLba * ss, n * es);
    if (e.length != n * es) return null;
    if (Crc32.of(e) != le32(h, 88)) return null;
    return (h, e);
  }

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    _s = stream;
    (Uint8List, Uint8List)? t;
    for (final ss in const [512, 4096]) {
      t = _readTable(1, ss);
      if (t == null) {
        // the backup header: at the last sector, or where the primary
        // header (valid but with a damaged array) says
        final last = stream.length ~/ ss - 1;
        t = _readTable(last, ss);
        if (t == null) {
          final h = readAt(stream, ss, ss);
          if (_sigAt(h, 0) && h.length >= 40) {
            t = _readTable(le64(h, 32), ss);
          }
        }
        if (t != null) usedBackup = true;
      }
      if (t != null) {
        sectorSize = ss;
        break;
      }
    }
    if (t == null) {
      _s = null;
      return false;
    }
    final (h, e) = t;
    final ss = sectorSize;
    diskId = guidToString(h, 56);
    final n = le32(h, 80);
    final es = le32(h, 84);
    _phySize = stream.length;
    final end = (le64(h, 32) > le64(h, 24) ? le64(h, 32) : le64(h, 24)) + 1;
    if (end * ss > _phySize) _headersError = true;
    for (var i = 0; i < n; i++) {
      final o = i * es;
      var zero = true;
      for (var k = 0; k < 16; k++) {
        if (e[o + k] != 0) {
          zero = false;
          break;
        }
      }
      if (zero) continue;
      final it = GptItem()
        ..index = i
        ..typeGuid = guidToString(e, o)
        ..id = guidToString(e, o + 16)
        ..firstLba = le64(e, o + 32)
        ..lastLba = le64(e, o + 40)
        ..attributes = le64(e, o + 48)
        ..name = utf16leZ(e, o + 56, es - 56 < 72 ? es - 56 : 72);
      if (it.lastLba < it.firstLba) {
        _headersError = true;
        continue;
      }
      items.add(it);
    }
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final info = _types[it.typeGuid];
      var ext = info?.$2 ?? 'img';
      final sniffed = sniffPartitionExt(stream, _offset(it), _size(it));
      if (sniffed != null) ext = sniffed;
      it.fileSystem = info?.$1 ?? it.typeGuid;
      final nm = safePartName(it.name);
      it.path = nm.isEmpty ? '$i.$ext' : '$i.$nm.$ext';
    }
    return true;
  }

  int _offset(GptItem it) => it.firstLba * sectorSize;
  int _size(GptItem it) => (it.lastLba - it.firstLba + 1) * sectorSize;

  @override
  void close() {
    _s = null;
    items.clear();
    sectorSize = 512;
    diskId = '';
    usedBackup = false;
    _headersError = false;
    _phySize = 0;
  }

  @override
  int get numberOfItems => items.length;

  static String _attrs(int a) {
    final l = <String>[];
    if ((a & 1) != 0) l.add('Required');
    if ((a & 2) != 0) l.add('NoBlockIO');
    if ((a & 4) != 0) l.add('LegacyBIOSBootable');
    if ((a & (1 << 60)) != 0) l.add('ReadOnly');
    if ((a & (1 << 62)) != 0) l.add('Hidden');
    if ((a & (1 << 63)) != 0) l.add('NoAutoMount');
    final rest = a & ~(7 | (1 << 60) | (1 << 62) | (1 << 63));
    if (rest != 0) l.add('0x${rest.toUnsigned(64).toRadixString(16)}');
    return l.join(' ');
  }

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
      case Kpid.packSize:
        return _size(it);
      case Kpid.fileSystem:
        return it.fileSystem;
      case Kpid.characts:
        return _attrs(it.attributes);
      case Kpid.offset:
        return _offset(it);
      case Kpid.id:
        return it.id;
      case Kpid.name:
        return it.name.isEmpty ? null : it.name;
    }
    return null;
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.phySize:
        return _s == null ? null : _phySize;
      case Kpid.id:
        return diskId.isEmpty ? null : diskId;
      case Kpid.sectorSize:
        return _s == null ? null : sectorSize;
      case Kpid.errorFlags:
        return _headersError ? ErrorFlags.headersError : 0;
      case Kpid.warning:
        return usedBackup
            ? 'The primary GPT header is damaged: the backup header was used'
            : null;
    }
    return null;
  }

  @override
  SeekableInStream? getStream(int index) {
    if (index < 0 || index >= items.length) return null;
    final it = items[index];
    return SubInStream(_s!, _offset(it), _size(it));
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(items.length, indices, testMode, cb, (i) => false,
        (i) => _size(items[i]), (i) => getStream(i)!,
        expectedSize: (i) => _size(items[i]));
  }
}
