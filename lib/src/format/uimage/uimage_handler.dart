// U-Boot legacy images ("uImage", read only).
//
// Written from the documented layout of the legacy image header (U-Boot's
// image.h describes it; the field layout and the IH_OS / IH_ARCH /
// IH_TYPE / IH_COMP codes are format facts, the names below are the ones
// mkimage accepts, checked against mkimage 2025.10 black box):
//
//   0  ih_magic  0x27051956      32 ih_os, 33 ih_arch, 34 ih_type,
//   4  ih_hcrc   header CRC-32   35 ih_comp (u8 each)
//   8  ih_time   Unix seconds    36 ih_name[32]
//  12  ih_size   payload bytes
//  16  ih_load   load address    all u32 fields are big endian; the
//  20  ih_ep     entry point     header CRC is taken with ih_hcrc zero,
//  24  ih_dcrc   payload CRC-32  the data CRC over the ih_size bytes
//
// A multi-file image (IH_TYPE_MULTI) starts its payload with a table of
// u32 big endian sizes ended by a zero entry; the images follow, each
// padded to a multiple of 4 bytes.
//
// Items: one item per image, decompressed according to ih_comp (for the
// parts of a multi-file image only when the part starts like data of that
// method, as U-Boot applies ih_comp to the kernel part only). The item is
// named after ih_name ("image" when empty), with ".dtb" for a flat device
// tree and ".bin" otherwise; a part of a multi-file image adds ".<n>"
// before the extension. The raw payload is not listed separately: for a
// "none" image the item is the payload.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../../util/crc.dart';
import '../archive_types.dart';
import '../item_streams.dart';
import 'uimage_codecs.dart';

const int kUImageMagic = 0x27051956;
const int _kHeaderSize = 64;
const int _typeMulti = 4;
const int _typeFlatDt = 8;

const List<String> _osNames = [
  'invalid', 'openbsd', 'netbsd', 'freebsd', '4_4bsd', 'linux', 'svr4', //
  'esix', 'solaris', 'irix', 'sco', 'dell', 'ncr', 'lynxos', 'vxworks',
  'psos', 'qnx', 'u-boot', 'rtems', 'artos', 'unity', 'integrity', 'ose',
  'plan9', 'openrtos', 'arm-trusted-firmware', 'tee', 'opensbi', 'efi',
];

const List<String> _archNames = [
  'invalid', 'alpha', 'arm', 'x86', 'ia64', 'mips', 'mips64', 'powerpc', //
  's390', 'sh', 'sparc', 'sparc64', 'm68k', 'nios', 'microblaze', 'nios2',
  'blackfin', 'avr32', 'st200', 'sandbox', 'nds32', 'or1k', 'arm64', 'arc',
  'x86_64', 'xtensa', 'riscv',
];

const List<String> _typeNames = [
  'invalid', 'standalone', 'kernel', 'ramdisk', 'multi', 'firmware', //
  'script', 'filesystem', 'flat_dt', 'kwbimage', 'imximage', 'ublimage',
  'omapimage', 'aisimage', 'kernel_noload', 'pblimage', 'mxsimage',
  'gpimage', 'atmelimage', 'socfpgaimage', 'x86_setup', 'lpc32xximage',
  'loadable', 'rkimage', 'rksd', 'rkspi', 'zynqimage', 'zynqmpimage',
  'zynqmpbif', 'fpga', 'vybridimage', 'tee', 'firmware_ivt', 'pmmc',
];

const List<String> _compNames = [
  'none', 'gzip', 'bzip2', 'lzma', 'lzo', 'lz4', 'zstd' //
];

String _name(List<String> t, int v) => v < t.length ? t[v] : '$v';

/// The parsed legacy header.
class UImageHeader {
  int hcrc = 0;
  int time = 0;
  int size = 0;
  int load = 0;
  int ep = 0;
  int dcrc = 0;
  int os = 0;
  int arch = 0;
  int type = 0;
  int comp = 0;
  String name = '';

  String get osName => _name(_osNames, os);
  String get archName => _name(_archNames, arch);
  String get typeName => _name(_typeNames, type);
  String get compName => _name(_compNames, comp);
}

class _Item {
  final String path;
  final int start; // in the file
  final int packSize;
  final int comp; // the method applied to this item
  int? size; // unpacked size, null when not known
  _Item(this.path, this.start, this.packSize, this.comp);
}

/// The uImage handler.
class UImageHandler extends ReadOnlyHandler {
  SeekableInStream? _stream;
  final UImageHeader header = UImageHeader();
  final List<_Item> _items = [];
  bool _headerCrcOk = true;
  bool _dataCrcOk = true;
  bool _unexpectedEnd = false;
  int _phySize = 0;

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.method,
    Kpid.hostOS,
    Kpid.cpu,
    Kpid.characts,
    Kpid.va,
    Kpid.comment,
  ];

  static const List<int> _arcProps = [
    Kpid.name,
    Kpid.mTime,
    Kpid.hostOS,
    Kpid.cpu,
    Kpid.characts,
    Kpid.method,
    Kpid.headersSize,
    Kpid.comment,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  @override
  int get timePrec => FileTimeType.unix;

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final h = readAt(stream, 0, _kHeaderSize);
    if (h.length < _kHeaderSize || getUint32BE(h, 0) != kUImageMagic) {
      return false;
    }
    final hd = header;
    hd.hcrc = getUint32BE(h, 4);
    hd.time = getUint32BE(h, 8);
    hd.size = getUint32BE(h, 12);
    hd.load = getUint32BE(h, 16);
    hd.ep = getUint32BE(h, 20);
    hd.dcrc = getUint32BE(h, 24);
    hd.os = h[28];
    hd.arch = h[29];
    hd.type = h[30];
    hd.comp = h[31];
    hd.name = cString(h, 32, 32);
    final hc = Uint8List.fromList(h);
    hc[4] = hc[5] = hc[6] = hc[7] = 0;
    _headerCrcOk = Crc32.of(hc) == hd.hcrc;
    // a wrong header CRC with an implausible header is not an image
    if (!_headerCrcOk && (hd.comp > 6 || hd.type >= _typeNames.length)) {
      return false;
    }
    final len = stream.length;
    var dataLen = hd.size;
    _phySize = _kHeaderSize + dataLen;
    if (_phySize > len) {
      _unexpectedEnd = true;
      dataLen = len - _kHeaderSize;
      _phySize = len;
    }
    _stream = stream;
    _dataCrcOk = _crcOf(stream, _kHeaderSize, dataLen) == hd.dcrc;

    final base = _baseName(hd.name);
    final ext = hd.type == _typeFlatDt ? '.dtb' : '.bin';
    if (hd.type == _typeMulti) {
      final sizes = <int>[];
      var pos = _kHeaderSize;
      final end = _kHeaderSize + dataLen;
      for (;;) {
        if (pos + 4 > end) {
          _unexpectedEnd = true;
          break;
        }
        final v = getUint32BE(readAt(stream, pos, 4), 0);
        pos += 4;
        if (v == 0) break;
        sizes.add(v);
      }
      for (var i = 0; i < sizes.length; i++) {
        var n = sizes[i];
        if (pos + n > end) {
          _unexpectedEnd = true;
          n = end > pos ? end - pos : 0;
        }
        final first = readAt(stream, pos, 16);
        final comp =
            hd.comp != UImageComp.none && uimagePayloadMatches(hd.comp, first)
                ? hd.comp
                : UImageComp.none;
        _items.add(_Item('$base.$i$ext', pos, n, comp));
        pos += (sizes[i] + 3) & ~3;
      }
    } else {
      _items.add(_Item('$base$ext', _kHeaderSize, dataLen, hd.comp));
    }
    for (final it in _items) {
      it.size = it.comp == UImageComp.none
          ? it.packSize
          : uimageUnpackedSize(it.comp, _raw(it));
    }
    return true;
  }

  static String _baseName(String n) {
    final sb = StringBuffer();
    for (final c in n.trim().codeUnits) {
      if (c < 0x20 || c == 0x2F || c == 0x5C) {
        sb.writeCharCode(0x5F);
      } else {
        sb.writeCharCode(c);
      }
    }
    final s = sb.toString();
    return s.isEmpty || s == '.' || s == '..' ? 'image' : s;
  }

  static int _crcOf(SeekableInStream s, int start, int len) {
    final buf = Uint8List(1 << 16);
    var v = 0xFFFFFFFF;
    s.position = start;
    var left = len;
    while (left > 0) {
      final n = s.read(buf, 0, left < buf.length ? left : buf.length);
      if (n == 0) break;
      v = crc32Update(v, buf, 0, n);
      left -= n;
    }
    return (v ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  SubInStream _raw(_Item it) => SubInStream(_stream!, it.start, it.packSize);

  @override
  void close() {
    _stream = null;
    _items.clear();
    _headerCrcOk = true;
    _dataCrcOk = true;
    _unexpectedEnd = false;
    _phySize = 0;
  }

  @override
  int get numberOfItems => _items.length;

  static String _hex(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';

  String _comment() {
    final h = header;
    return 'name "${h.name}", os ${h.osName}, arch ${h.archName}, '
        'type ${h.typeName}, comp ${h.compName}, '
        'load ${_hex(h.load)}, entry ${_hex(h.ep)}';
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
        return it.size;
      case Kpid.packSize:
        return it.packSize;
      case Kpid.mTime:
        return header.time == 0 ? null : unixSecondsToFileTime(header.time);
      case Kpid.method:
        return uimageMethodName(it.comp);
      case Kpid.hostOS:
        return header.osName;
      case Kpid.cpu:
        return header.archName;
      case Kpid.characts:
        return header.typeName;
      case Kpid.va:
        return header.load;
      case Kpid.comment:
        return _comment();
    }
    return null;
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.name:
        return header.name;
      case Kpid.mTime:
        return header.time == 0 ? null : unixSecondsToFileTime(header.time);
      case Kpid.hostOS:
        return header.osName;
      case Kpid.cpu:
        return header.archName;
      case Kpid.characts:
        return header.typeName;
      case Kpid.method:
        return uimageMethodName(header.comp);
      case Kpid.headersSize:
        return _kHeaderSize;
      case Kpid.comment:
        return _comment();
      case Kpid.phySize:
        return _phySize;
      case Kpid.errorFlags:
        var f = 0;
        if (_unexpectedEnd) f |= ErrorFlags.unexpectedEnd;
        if (!_headerCrcOk) f |= ErrorFlags.headersError;
        return f;
      case Kpid.warningFlags:
        return _dataCrcOk ? null : ErrorFlags.crcError;
      case Kpid.warning:
        if (!_headerCrcOk) return 'Header CRC error';
        return _dataCrcOk ? null : 'Data CRC error';
    }
    return null;
  }

  InStream _decoded(int index) {
    final it = _items[index];
    return uimageDecoder(it.comp, _raw(it));
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(_items.length, indices, testMode, cb, (_) => false,
        (i) => _items[i].size, _decoded,
        expectedSize: (i) => _items[i].size,
        verify: (_) =>
            _dataCrcOk ? OperationResult.ok : OperationResult.crcError);
  }

  @override
  SeekableInStream? getStream(int index) {
    if (_stream == null || index < 0 || index >= _items.length) return null;
    final it = _items[index];
    if (it.comp == UImageComp.none) return _raw(it);
    return ReopenSeekableInStream(() => _decoded(index), it.size);
  }
}
