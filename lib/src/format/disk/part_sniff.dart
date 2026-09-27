// What a partition holds, from the signatures of its first bytes: used by
// the MBR and GPT handlers to name partition items by their content
// ("0.fat", "1.ext"). Written for this package; the signatures are the
// documented magic numbers of each file system.

import 'dart:typed_data';

import '../../io/streams.dart';
import '../fat/fat_handler.dart';
import '../iso/disc_streams.dart' show le16;
import '../item_streams.dart';

/// The item extension of the file system at [off] of [s] ([size] bytes),
/// or null when none is recognized.
String? sniffPartitionExt(SeekableInStream s, int off, int size) {
  if (size < 512 || off >= s.length) return null;
  final head = readAt(s, off, size < 2048 ? size : 2048);
  if (head.length < 512) return null;
  bool at(int o, String sig) {
    if (head.length < o + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (head[o + i] != sig.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (at(3, 'NTFS    ')) return 'ntfs';
  if (at(3, 'EXFAT   ')) return 'exfat';
  if (parseFatBpb(head, 0) != null) return 'fat';
  if (head.length >= 1082 && le16(head, 1080) == 0xEF53) return 'ext';
  if (at(0, 'hsqs') || at(0, 'sqsh')) return 'squashfs';
  if (at(0, 'UBI#')) return 'ubi';
  if (size > 0x8006) {
    final vd = readAt(s, off + 0x8001, 5);
    if (vd.length == 5 && String.fromCharCodes(vd) == 'CD001') return 'iso';
  }
  return null;
}

/// The file system name of a recognized extension, as 7-Zip lists it.
String? sniffedFsName(String? ext) {
  switch (ext) {
    case 'ntfs':
      return 'NTFS';
    case 'exfat':
      return 'exFAT';
  }
  return null;
}

/// A partition name usable as a path part: no folder separators.
String safePartName(String s) =>
    s.replaceAll('/', '_').replaceAll('\\', '_').replaceAll('\u0000', '');

/// Bytes [b] as text of 16-bit little endian code units up to the first 0.
String utf16leZ(Uint8List b, int off, int len) {
  final u = <int>[];
  for (var i = 0; i + 1 < len; i += 2) {
    final c = b[off + i] | (b[off + i + 1] << 8);
    if (c == 0) break;
    u.add(c);
  }
  return String.fromCharCodes(u);
}
