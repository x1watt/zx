// Flattened device tree blobs (.dtb, read only).
//
// Written from the Devicetree Specification (devicetree.org, chapter 5,
// "Flattened Devicetree (DTB) Format"): a 40 byte big endian header
// (magic 0xD00DFEED, totalsize, off_dt_struct, off_dt_strings,
// off_mem_rsvmap, version, last_comp_version, boot_cpuid_phys,
// size_dt_strings, size_dt_struct), the memory reservation block (pairs
// of u64 address and size ended by a zero pair), the structure block
// (FDT_BEGIN_NODE 1 with the NUL terminated unit name padded to 4 bytes,
// FDT_END_NODE 2, FDT_PROP 3 with u32 len, u32 nameoff and the value
// padded to 4 bytes, FDT_NOP 4, FDT_END 9) and the strings block.
//
// Items: every node except the root is a folder ("cpus/cpu@0"), every
// property a small file holding its raw value ("cpus/cpu@0/reg"), and
// one generated text item "<name>.dts" (the archive name without its
// extension, "devicetree" when unknown) renders the whole tree in dts
// syntax. The rendering matches what `dtc -I dtb -O dts` prints (dtc
// 1.7, compared black box): a value is shown as a string list when it
// ends with a NUL, every other byte is printable ASCII or one of the C
// escapes \a \b \t \n \v \f \r, and it holds no more NULs than other
// bytes; else as 32-bit cells when its length is a multiple of 4; else as
// bytes.

import 'dart:convert';
import 'dart:typed_data';

import '../../io/streams.dart';
import '../archive_types.dart';
import '../item_streams.dart';

const int kFdtMagic = 0xD00DFEED;
const int _kMaxBlob = 64 << 20;

const int _fdtBeginNode = 1;
const int _fdtEndNode = 2;
const int _fdtProp = 3;
const int _fdtNop = 4;
const int _fdtEnd = 9;

class _Item {
  final String path;
  final bool isDir;
  final int off; // value offset in the blob (files)
  final int len;
  _Item(this.path, this.isDir, this.off, this.len);
}

/// The fdt handler.
class FdtHandler extends ReadOnlyHandler {
  Uint8List _blob = Uint8List(0);
  final List<_Item> _items = [];
  Uint8List _dts = Uint8List(0);
  String _dtsName = 'devicetree.dts';
  int version = 0;
  int _phySize = 0;
  bool _unexpectedEnd = false;
  bool _headersError = false;

  static const List<int> _itemProps = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
  ];

  static const List<int> _arcProps = [
    Kpid.headersSize,
    Kpid.characts,
  ];

  @override
  List<int> get itemPropIds => _itemProps;
  @override
  List<int> get archivePropIds => _arcProps;

  @override
  bool open(SeekableInStream stream, {String? name}) {
    close();
    final h = readAt(stream, 0, 40);
    if (h.length < 40 || getUint32BE(h, 0) != kFdtMagic) return false;
    final total = getUint32BE(h, 4);
    final offStruct = getUint32BE(h, 8);
    final offStrings = getUint32BE(h, 12);
    final offRsv = getUint32BE(h, 16);
    version = getUint32BE(h, 20);
    final lastComp = getUint32BE(h, 24);
    if (version < 16 || lastComp > 17 || total < 40 || total > _kMaxBlob) {
      return false;
    }
    if (offStruct >= total || offStrings > total || offRsv >= total) {
      return false;
    }
    final blob = readAt(stream, 0, total);
    if (blob.length < total) _unexpectedEnd = true;
    _blob = blob;
    _phySize = blob.length;
    final sizeStrings = getUint32BE(h, 32);
    var stringsEnd = offStrings + sizeStrings;
    if (stringsEnd > blob.length) stringsEnd = blob.length;

    _dtsName = '${_baseName(name)}.dts';
    final dts = StringBuffer('/dts-v1/;\n\n');
    // memory reservation block
    var p = offRsv;
    while (p + 16 <= blob.length) {
      final addr = getUint64BE(blob, p);
      final size = getUint64BE(blob, p + 8);
      p += 16;
      if (addr == 0 && size == 0) break;
      dts.write('/memreserve/\t0x${_hex16(addr)} 0x${_hex16(size)};\n');
    }

    _items.add(_Item(_dtsName, false, 0, 0)); // text filled in below
    p = offStruct;
    final path = <String>[];
    var depth = -1;
    var ended = false;
    final seen = <String>{};
    while (!ended) {
      if (p + 4 > blob.length) {
        _unexpectedEnd = true;
        break;
      }
      final tok = getUint32BE(blob, p);
      p += 4;
      switch (tok) {
        case _fdtBeginNode:
          var e = p;
          while (e < blob.length && blob[e] != 0) {
            e++;
          }
          if (e >= blob.length) {
            _unexpectedEnd = true;
            ended = true;
            break;
          }
          final nodeName = bytesToName(Uint8List.sublistView(blob, p, e));
          p = (e + 1 + 3) & ~3;
          final indent = '\t' * (depth + 1);
          if (depth < 0) {
            dts.write('/ {\n');
          } else {
            dts.write('\n$indent$nodeName {\n');
            path.add(nodeName);
            final dirPath = path.join('/');
            seen.add(dirPath);
            _items.add(_Item(dirPath, true, 0, 0));
          }
          depth++;
        case _fdtEndNode:
          if (depth < 0) {
            _headersError = true;
            ended = true;
            break;
          }
          dts.write('${'\t' * depth}};\n');
          depth--;
          if (depth < 0) break;
          path.removeLast();
        case _fdtProp:
          if (p + 8 > blob.length || depth < 0) {
            _headersError = true;
            ended = true;
            break;
          }
          final len = getUint32BE(blob, p);
          final nameOff = getUint32BE(blob, p + 4);
          p += 8;
          if (p + len > blob.length) {
            _unexpectedEnd = true;
            ended = true;
            break;
          }
          final propName = offStrings + nameOff < stringsEnd
              ? cString(
                  blob, offStrings + nameOff, stringsEnd - offStrings - nameOff)
              : '';
          final value = Uint8List.sublistView(blob, p, p + len);
          dts.write('${'\t' * (depth + 1)}$propName');
          _writeValue(dts, value);
          dts.write(';\n');
          final propPath = [...path, propName].join('/');
          if (seen.add(propPath)) {
            _items.add(_Item(propPath, false, p, len));
          }
          p = (p + len + 3) & ~3;
        case _fdtNop:
          break;
        case _fdtEnd:
          ended = true;
        default:
          _headersError = true;
          ended = true;
      }
    }
    if (depth >= 0 && !_unexpectedEnd) _headersError = true;
    _dts = Uint8List.fromList(utf8.encode(dts.toString()));
    return true;
  }

  static String _baseName(String? name) {
    if (name == null || name.isEmpty) return 'devicetree';
    var s = name;
    final slash = s.lastIndexOf(RegExp(r'[/\\]'));
    if (slash >= 0) s = s.substring(slash + 1);
    final dot = s.lastIndexOf('.');
    if (dot > 0) s = s.substring(0, dot);
    return s.isEmpty ? 'devicetree' : s;
  }

  static String _hex16(int v) =>
      (v >> 32 & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0') +
      (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');

  static bool _isStringByte(int c) =>
      (c >= 0x20 && c < 0x7F) || (c >= 7 && c <= 13);

  /// Whether dtc shows [v] as a string list.
  static bool isStringValue(Uint8List v) {
    final n = v.length;
    if (n == 0 || v[n - 1] != 0) return false;
    var nuls = 0;
    for (var i = 0; i < n; i++) {
      final c = v[i];
      if (c == 0) {
        nuls++;
      } else if (!_isStringByte(c)) {
        return false;
      }
    }
    return nuls * 2 <= n;
  }

  static const _escapes = {
    7: r'\a',
    8: r'\b',
    9: r'\t',
    10: r'\n',
    11: r'\v',
    12: r'\f',
    13: r'\r',
    0x22: r'\"',
    0x5C: r'\\',
    0: r'\0',
  };

  // " = value" in dts syntax, or nothing for an empty property
  static void _writeValue(StringBuffer sb, Uint8List v) {
    final n = v.length;
    if (n == 0) return;
    if (isStringValue(v)) {
      sb.write(' = "');
      for (var i = 0; i < n - 1; i++) {
        final c = v[i];
        final e = _escapes[c];
        if (e != null) {
          sb.write(e);
        } else {
          sb.writeCharCode(c);
        }
      }
      sb.write('"');
    } else if ((n & 3) == 0) {
      sb.write(' = <');
      for (var i = 0; i < n; i += 4) {
        if (i > 0) sb.write(' ');
        sb.write('0x${getUint32BE(v, i).toRadixString(16).padLeft(2, '0')}');
      }
      sb.write('>');
    } else {
      sb.write(' = [');
      for (var i = 0; i < n; i++) {
        if (i > 0) sb.write(' ');
        sb.write(v[i].toRadixString(16).padLeft(2, '0'));
      }
      sb.write(']');
    }
  }

  /// The generated dts text.
  Uint8List get dtsText => _dts;

  @override
  void close() {
    _blob = Uint8List(0);
    _items.clear();
    _dts = Uint8List(0);
    _phySize = 0;
    _unexpectedEnd = false;
    _headersError = false;
  }

  @override
  int get numberOfItems => _items.length;

  int _size(int index) => index == 0 ? _dts.length : _items[index].len;

  @override
  Object? getProperty(int index, int propId) {
    if (index < 0 || index >= _items.length) return null;
    final it = _items[index];
    switch (propId) {
      case Kpid.path:
        return it.path;
      case Kpid.isDir:
        return it.isDir;
      case Kpid.size:
        return it.isDir ? null : _size(index);
    }
    return null;
  }

  @override
  Object? getArchiveProperty(int propId) {
    switch (propId) {
      case Kpid.phySize:
        return _phySize;
      case Kpid.headersSize:
        return 40;
      case Kpid.characts:
        return 'v$version';
      case Kpid.errorFlags:
        var f = 0;
        if (_unexpectedEnd) f |= ErrorFlags.unexpectedEnd;
        if (_headersError) f |= ErrorFlags.headersError;
        return f;
    }
    return null;
  }

  Uint8List _data(int index) => index == 0
      ? _dts
      : Uint8List.sublistView(
          _blob, _items[index].off, _items[index].off + _items[index].len);

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    extractSimpleItems(
        _items.length,
        indices,
        testMode,
        cb,
        (i) => _items[i].isDir,
        (i) => _items[i].isDir ? 0 : _size(i),
        (i) => MemoryInStream(_data(i)));
  }

  @override
  SeekableInStream? getStream(int index) {
    if (index < 0 || index >= _items.length || _items[index].isDir) {
      return null;
    }
    return MemoryInStream(_data(index));
  }
}
