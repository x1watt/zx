// The format and codec tables of 7zr: UI/Common/LoadCodecs.cpp (CCodecs,
// CArcInfoEx, FindFormatForArchiveType...) with the REGISTER_ARC entries of
// 7zRegister.cpp, XzHandler.cpp, LzmaHandler.cpp, SplitHandler.cpp and the
// hash handler that Codecs_AddHashArcHandler adds; and the REGISTER_CODEC /
// REGISTER_HASHER tables for the "i" command.

import 'dart:typed_data';

import '../format/lzma_alone.dart';
import 'arc_handlers.dart';
import 'platform.dart';

/// NArcInfoFlags.
abstract final class ArcInfoFlags {
  static const keepName = 1 << 0;
  static const altStreams = 1 << 1;
  static const ntSecure = 1 << 2;
  static const findSignature = 1 << 3;
  static const multiSignature = 1 << 4;
  static const useGlobalOffset = 1 << 5;
  static const startOpen = 1 << 6;
  static const pureStartOpen = 1 << 7;
  static const backwardOpen = 1 << 8;
  static const preArc = 1 << 9;
  static const symLinks = 1 << 10;
  static const hardLinks = 1 << 11;
  static const byExtOnlyOpen = 1 << 12;
  static const hashHandler = 1 << 13;
  static const cTime = 1 << 14;
  static const cTimeDefault = 1 << 15;
  static const aTime = 1 << 16;
  static const aTimeDefault = 1 << 17;
  static const mTime = 1 << 18;
  static const mTimeDefault = 1 << 19;
}

/// k_IsArc_Res_*.
abstract final class IsArcRes {
  static const no = 0;
  static const yes = 1;
  static const needMore = 2;
}

/// CArcExtInfo.
class ArcExtInfo {
  final String ext;
  final String addExt;
  const ArcExtInfo(this.ext, [this.addExt = '']);
}

/// CArcInfoEx.
class ArcInfoEx {
  final String name;
  final List<ArcExtInfo> exts;
  final int flags;
  final List<Uint8List> signatures;
  final int signatureOffset;
  final int Function(Uint8List p, int size)? isArcFunc;
  final InArchive Function()? createInArchive;
  final bool updateEnabled;

  const ArcInfoEx(this.name, this.exts, this.flags, this.signatures,
      {this.signatureOffset = 0,
      this.isArcFunc,
      this.createInArchive,
      this.updateEnabled = false});

  bool get flagsKeepName => (flags & ArcInfoFlags.keepName) != 0;
  bool get flagsFindSignature => (flags & ArcInfoFlags.findSignature) != 0;
  bool get flagsAltStreams => (flags & ArcInfoFlags.altStreams) != 0;
  bool get flagsNtSecurity => (flags & ArcInfoFlags.ntSecure) != 0;
  bool get flagsUseGlobalOffset => (flags & ArcInfoFlags.useGlobalOffset) != 0;
  bool get flagsStartOpen => (flags & ArcInfoFlags.startOpen) != 0;
  bool get flagsBackwardOpen => (flags & ArcInfoFlags.backwardOpen) != 0;
  bool get flagsPreArc => (flags & ArcInfoFlags.preArc) != 0;
  bool get flagsPureStartOpen => (flags & ArcInfoFlags.pureStartOpen) != 0;
  bool get flagsByExtOnlyOpen => (flags & ArcInfoFlags.byExtOnlyOpen) != 0;
  bool get flagsHashHandler => (flags & ArcInfoFlags.hashHandler) != 0;

  // GetMainExt
  String getMainExt() => exts.isEmpty ? '' : exts.first.ext;

  // FindExtension
  int findExtension(String ext) {
    final e = ext.toLowerCase();
    for (var i = 0; i < exts.length; i++) {
      if (e == exts[i].ext.toLowerCase()) return i;
    }
    return -1;
  }

  bool get is7z => name.toLowerCase() == '7z';
  bool get isSplit => name.toLowerCase() == 'split';
  bool get isXz => name.toLowerCase() == 'xz';
}

// IsArc_Lzma / IsArc_Lzma86 adapters
int _isArcLzma(Uint8List p, int size) => isArcLzma(p, 0, size);
int _isArcLzma86(Uint8List p, int size) => isArcLzma86(p, 0, size);

// AddExts: "xz txz" with "* .tar"
List<ArcExtInfo> _exts(String ext, [String addExt = '']) {
  final e = ext.split(' ').where((s) => s.isNotEmpty).toList();
  final a = addExt.split(' ').where((s) => s.isNotEmpty).toList();
  return [
    for (var i = 0; i < e.length; i++)
      ArcExtInfo(e[i], i < a.length && a[i] != '*' ? a[i] : ''),
  ];
}

const String _kHashExts =
    'sha256 sha512 sha384 sha224 sha512-224 sha512-256 sha3-224 sha3-256 '
    'sha3-384 sha3-512 sha1 sha2 sha3 sha md5 blake2s blake2b blake2sp '
    'xxh64 crc32 crc64 cksum asc';

/// CCodecs: the formats of 7zr, sorted by name (Formats.Sort()), then the
/// hash handler.
class Codecs {
  final List<ArcInfoEx> formats;

  Codecs._(this.formats);

  factory Codecs.load() {
    final list = <ArcInfoEx>[
      ArcInfoEx(
          '7z',
          _exts('7z'),
          ArcInfoFlags.findSignature |
              ArcInfoFlags.cTime |
              ArcInfoFlags.aTime |
              ArcInfoFlags.mTime |
              ArcInfoFlags.mTimeDefault,
          [
            Uint8List.fromList([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])
          ],
          createInArchive: SevenZipArc.new,
          updateEnabled: true),
      ArcInfoEx('Split', _exts('001'), 0, const [],
          createInArchive: SplitArc.new),
      ArcInfoEx('lzma', _exts('lzma'),
          ArcInfoFlags.startOpen | ArcInfoFlags.keepName, const [],
          isArcFunc: _isArcLzma, createInArchive: () => LzmaArc(false)),
      ArcInfoEx('lzma86', _exts('lzma86'), ArcInfoFlags.keepName, const [],
          isArcFunc: _isArcLzma86, createInArchive: () => LzmaArc(true)),
      ArcInfoEx(
          'xz',
          _exts('xz txz', '* .tar'),
          ArcInfoFlags.keepName,
          [
            Uint8List.fromList([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
          ],
          createInArchive: XzArc.new,
          updateEnabled: true),
    ];
    // Formats.Sort(): by name, ordinal compare
    list.sort((a, b) => a.name.compareTo(b.name));
    // Codecs_AddHashArcHandler
    list.add(ArcInfoEx(
        'Hash',
        _exts(_kHashExts),
        ArcInfoFlags.keepName |
            ArcInfoFlags.startOpen |
            ArcInfoFlags.byExtOnlyOpen |
            ArcInfoFlags.hashHandler,
        const [],
        updateEnabled: true));
    return Codecs._(list);
  }

  // GetFormatNamePtr
  String getFormatNamePtr(int formatIndex) =>
      formatIndex < 0 ? '#' : formats[formatIndex].name;

  // FindFormatForArchiveName
  int findFormatForArchiveName(String arcPath) {
    final dotPos = arcPath.lastIndexOf('.');
    if (dotPos <= reverseFindPathSepar(arcPath)) return -1;
    final ext = arcPath.substring(dotPos + 1);
    if (ext.isEmpty) return -1;
    if (ext.toLowerCase() == 'exe') return -1;
    for (var i = 0; i < formats.length; i++) {
      if (formats[i].findExtension(ext) >= 0) return i;
    }
    return -1;
  }

  // FindFormatForExtension
  int findFormatForExtension(String ext) {
    if (ext.isEmpty) return -1;
    for (var i = 0; i < formats.length; i++) {
      if (formats[i].findExtension(ext) >= 0) return i;
    }
    return -1;
  }

  // FindFormatForArchiveType
  int findFormatForArchiveType(String arcType) {
    final t = arcType.toLowerCase();
    for (var i = 0; i < formats.length; i++) {
      if (formats[i].name.toLowerCase() == t) return i;
    }
    return -1;
  }

  /// FindFormatForArchiveType (list form): null for false.
  List<int>? findFormatsForArchiveType(String arcType) {
    final r = <int>[];
    var pos = 0;
    while (pos < arcType.length) {
      var pos2 = arcType.indexOf('.', pos);
      if (pos2 < 0) pos2 = arcType.length;
      final name = arcType.substring(pos, pos2);
      if (name.isEmpty) return null;
      final index = findFormatForArchiveType(name);
      if (index < 0 && name != '*') return null;
      r.add(index);
      pos = pos2 + 1;
    }
    return r;
  }
}

/// CCodecInfo as the "i" command prints it.
class CodecInfoEntry {
  final int numStreams;
  final bool encoder;
  final bool decoder;
  final bool isFilter;
  final int id;
  final String name;
  const CodecInfoEntry(
      this.numStreams, this.encoder, this.decoder, this.isFilter, this.id,
      this.name);
}

/// g_Codecs of 7zr in registration order (the SDK's 7zr has no PPMd; the
/// port has it, so it is listed after LZMA as in the full 7-Zip order).
const List<CodecInfoEntry> kCodecs = [
  CodecInfoEntry(4, true, true, false, 0x303011B, 'BCJ2'),
  CodecInfoEntry(1, true, true, true, 0x3030103, 'BCJ'),
  CodecInfoEntry(1, true, true, true, 0x3030205, 'PPC'),
  CodecInfoEntry(1, true, true, true, 0x3030401, 'IA64'),
  CodecInfoEntry(1, true, true, true, 0x3030501, 'ARM'),
  CodecInfoEntry(1, true, true, true, 0x3030701, 'ARMT'),
  CodecInfoEntry(1, true, true, true, 0x3030805, 'SPARC'),
  CodecInfoEntry(1, true, true, true, 0xA, 'ARM64'),
  CodecInfoEntry(1, true, true, true, 0xB, 'RISCV'),
  CodecInfoEntry(1, true, true, true, 0x20302, 'Swap2'),
  CodecInfoEntry(1, true, true, true, 0x20304, 'Swap4'),
  CodecInfoEntry(1, true, true, false, 0x0, 'Copy'),
  CodecInfoEntry(1, true, true, true, 0x3, 'Delta'),
  CodecInfoEntry(1, true, true, false, 0x21, 'LZMA2'),
  CodecInfoEntry(1, true, true, false, 0x30101, 'LZMA'),
  CodecInfoEntry(1, true, true, false, 0x30401, 'PPMD'),
  CodecInfoEntry(1, true, true, true, 0x6F10701, '7zAES'),
  CodecInfoEntry(1, true, true, true, 0x6F00181, 'AES256CBC'),
];

/// CHasherInfo of 7zr: (digest size, id, name) in registration order.
const List<(int, int, String)> kHashers = [
  (4, 0x1, 'CRC32'),
  (32, 0xA, 'SHA256'),
  (8, 0x4, 'CRC64'),
];
