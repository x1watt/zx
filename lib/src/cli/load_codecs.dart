// The format and codec tables of 7zr: UI/Common/LoadCodecs.cpp (CCodecs,
// CArcInfoEx, FindFormatForArchiveType...) with the REGISTER_ARC entries of
// 7zRegister.cpp, XzHandler.cpp, LzmaHandler.cpp, SplitHandler.cpp and the
// hash handler that Codecs_AddHashArcHandler adds; and the REGISTER_CODEC /
// REGISTER_HASHER tables for the "i" command.

import 'dart:typed_data';

import '../format/arj/arj_handler.dart';
import '../format/bzip2/bzip2_handler.dart';
import '../format/lha/lha_handler.dart';
import '../format/lzma_alone.dart';
import '../format/tar/tar_header.dart';
import '../format/cpio/cpio_handler.dart';
import '../format/iso/iso_handler.dart';
import '../format/udf/udf_handler.dart';
import 'arc_arj.dart';
import 'arc_bzip2.dart';
import 'arc_cpio.dart';
import 'arc_fdt.dart';
import 'arc_gzip.dart';
import 'arc_lzh.dart';
import 'arc_pak.dart';
import 'arc_rar.dart';
import 'arc_tar.dart';
import 'arc_uimage.dart';
import 'arc_zip.dart';
import 'arc_zpaq.dart';
import 'arc_zx.dart';
import '../format/zx/zx_format.dart' show zxMagic;
import '../format/zpaq/zpaq_handler.dart';
import 'arc_handlers.dart';
import 'arc_iso.dart';
import 'arc_udf.dart';
import '../format/ubi/ubi_handler.dart';
import '../format/ubifs/ubifs_handler.dart';
import 'arc_ubi.dart';
import 'arc_ubifs.dart';
import '../format/squashfs/squashfs_handler.dart';
import '../format/cramfs/cramfs_handler.dart';
import '../format/jffs2/jffs2_handler.dart';
import 'arc_squashfs.dart';
import 'arc_cramfs.dart';
import 'arc_jffs2.dart';
import '../format/disk/gpt_handler.dart';
import '../format/disk/mbr_handler.dart';
import '../format/ext/ext_handler.dart';
import '../format/fat/fat_handler.dart';
import 'arc_disk.dart';
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

  /// The items are images (firmware sections, volumes, partitions): each
  /// one is tried as a nested archive (zx extension, see nest.dart).
  final bool isContainer;

  const ArcInfoEx(this.name, this.exts, this.flags, this.signatures,
      {this.signatureOffset = 0,
      this.isArcFunc,
      this.createInArchive,
      this.isContainer = false,
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

// IsArc_BZip2
int _isArcBzip2(Uint8List p, int size) =>
    isBzip2Signature(p, 0, size) ? IsArcRes.yes : IsArcRes.no;

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
      ArcInfoEx('lzma', _exts('lzma tlz', '* .tar'),
          ArcInfoFlags.startOpen | ArcInfoFlags.keepName, const [],
          isArcFunc: _isArcLzma,
          createInArchive: () => LzmaArc(false),
          updateEnabled: true),
      ArcInfoEx('lzma86', _exts('lzma86'), ArcInfoFlags.keepName, const [],
          isArcFunc: _isArcLzma86, createInArchive: () => LzmaArc(true)),
      ArcInfoEx(
          'bzip2',
          _exts('bz2 bzip2 tbz2 tbz', '* * .tar .tar'),
          ArcInfoFlags.keepName,
          [
            Uint8List.fromList([0x42, 0x5A, 0x68])
          ],
          isArcFunc: _isArcBzip2,
          createInArchive: Bzip2Arc.new,
          updateEnabled: true),
      ArcInfoEx(
          'gzip',
          _exts('gz gzip tgz tpz apk', '* * .tar .tar .tar'),
          ArcInfoFlags.keepName | ArcInfoFlags.mTime,
          [
            Uint8List.fromList([0x1F, 0x8B, 8])
          ],
          createInArchive: GzipArc.new,
          updateEnabled: true),
      ArcInfoEx('Lzh', _exts('lzh lha'),
          ArcInfoFlags.mTime | ArcInfoFlags.mTimeDefault,
          [
            Uint8List.fromList([0x2D, 0x6C, 0x68]),
            Uint8List.fromList([0x2D, 0x6C, 0x7A]),
            Uint8List.fromList([0x2D, 0x70, 0x6D])
          ],
          signatureOffset: 2,
          isArcFunc: isArcLzh,
          createInArchive: LzhArc.new,
          updateEnabled: true),
      ArcInfoEx('Arj', _exts('arj'),
          ArcInfoFlags.mTime | ArcInfoFlags.mTimeDefault,
          [
            Uint8List.fromList([0x60, 0xEA])
          ],
          isArcFunc: isArcArj,
          createInArchive: ArjArc.new,
          updateEnabled: true),
      ArcInfoEx(
          'tar',
          _exts('tar ova'),
          ArcInfoFlags.startOpen |
              ArcInfoFlags.symLinks |
              ArcInfoFlags.hardLinks |
              ArcInfoFlags.mTime |
              ArcInfoFlags.mTimeDefault,
          [
            Uint8List.fromList([0x75, 0x73, 0x74, 0x61, 0x72])
          ],
          signatureOffset: 257,
          isArcFunc: isArcTar,
          createInArchive: TarArc.new,
          updateEnabled: true),
      ArcInfoEx(
          'xz',
          _exts('xz txz', '* .tar'),
          ArcInfoFlags.keepName,
          [
            Uint8List.fromList([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
          ],
          createInArchive: XzArc.new,
          updateEnabled: true),
      ArcInfoEx(
          'zip',
          _exts('zip z01 zipx jar xpi odt ods docx xlsx epub ipa apk appx'),
          ArcInfoFlags.findSignature |
              ArcInfoFlags.multiSignature |
              ArcInfoFlags.useGlobalOffset |
              ArcInfoFlags.symLinks |
              ArcInfoFlags.cTime |
              ArcInfoFlags.aTime |
              ArcInfoFlags.mTime |
              ArcInfoFlags.mTimeDefault,
          [
            Uint8List.fromList([0x50, 0x4B, 0x03, 0x04]),
            Uint8List.fromList([0x50, 0x4B, 0x05, 0x06]),
            Uint8List.fromList(
                [0x50, 0x4B, 0x07, 0x08, 0x50, 0x4B, 0x03, 0x04]),
          ],
          isArcFunc: isArcZipFunc,
          createInArchive: ZipArc.new,
          updateEnabled: true),
      ArcInfoEx('Rar', _exts('rar r00'), 0, [rar4ArcSignature],
          createInArchive: RarArc.new, updateEnabled: true),
      ArcInfoEx(
          'Rar5',
          _exts('rar r00'),
          ArcInfoFlags.symLinks |
              ArcInfoFlags.cTime |
              ArcInfoFlags.aTime |
              ArcInfoFlags.mTime |
              ArcInfoFlags.mTimeDefault,
          [rar5ArcSignature],
          createInArchive: Rar5Arc.new,
          updateEnabled: true),
      // zpaq journaling archives (not in 7-Zip; engine vendored from
      // zpaq-flutter): the locator tag zpaq writes before each block, or a
      // block header without it. Encrypted archives have no signature and
      // open by the extension.
      ArcInfoEx('zpaq', _exts('zpaq'),
          ArcInfoFlags.mTime | ArcInfoFlags.mTimeDefault,
          [zpaqLocatorTag, Uint8List.fromList(const [0x7A, 0x50, 0x51])],
          isArcFunc: isArcZpaq,
          createInArchive: ZpaqArc.new,
          updateEnabled: true),
      // zx's own format (docs/zx-format.md): the magic at offset 0
      ArcInfoEx(
          'zx',
          _exts('zx'),
          ArcInfoFlags.symLinks |
              ArcInfoFlags.hardLinks |
              ArcInfoFlags.cTime |
              ArcInfoFlags.aTime |
              ArcInfoFlags.mTime |
              ArcInfoFlags.mTimeDefault,
          [zxMagic],
          isArcFunc: isArcZx,
          createInArchive: ZxArc.new,
          updateEnabled: true),
      // firmware and image formats (read only)
      ArcInfoEx(
          'Cpio',
          _exts('cpio'),
          ArcInfoFlags.symLinks | ArcInfoFlags.hardLinks | ArcInfoFlags.mTime,
          [
            Uint8List.fromList('070701'.codeUnits),
            Uint8List.fromList('070702'.codeUnits),
            Uint8List.fromList('070707'.codeUnits),
            Uint8List.fromList('070727'.codeUnits),
            Uint8List.fromList([0xC7, 0x71]),
            Uint8List.fromList([0x71, 0xC7]),
          ],
          isArcFunc: isArcCpio,
          createInArchive: CpioArc.new),
      ArcInfoEx('Pak', _exts('pak'), 0, [
        Uint8List.fromList([0x13, 0x59, 0x72, 0x32])
      ], createInArchive: PakArc.new, isContainer: true),
      ArcInfoEx('UImage', _exts('uimage uimg ub'), ArcInfoFlags.mTime, [
        Uint8List.fromList([0x27, 0x05, 0x19, 0x56])
      ], createInArchive: UImageArc.new, isContainer: true),
      ArcInfoEx('Fdt', _exts('dtb dtbo'), 0, [
        Uint8List.fromList([0xD0, 0x0D, 0xFE, 0xED])
      ], createInArchive: FdtArc.new),
      // disc images (read only); OpenStream2 tries Udf before Iso for a
      // name whose extension both claim (ISO/UDF bridge discs)
      ArcInfoEx('Iso', _exts('iso img'),
          ArcInfoFlags.symLinks | ArcInfoFlags.mTime, [
        Uint8List.fromList('CD001'.codeUnits)
      ],
          signatureOffset: kIsoVdOffset + 1,
          isArcFunc: isArcIso,
          createInArchive: IsoArc.new),
      ArcInfoEx(
          'Udf',
          _exts('udf iso img'),
          ArcInfoFlags.symLinks |
              ArcInfoFlags.cTime |
              ArcInfoFlags.aTime |
              ArcInfoFlags.mTime,
          [
            Uint8List.fromList([0, 0x42, 0x45, 0x41, 0x30, 0x31, 1])
          ],
          signatureOffset: kIsoVdOffset,
          isArcFunc: isArcUdf,
          createInArchive: UdfArc.new),
      // UBI images and UBIFS volumes (read only)
      ArcInfoEx('Ubi', _exts('ubi'), 0, [
        Uint8List.fromList([0x55, 0x42, 0x49, 0x23])
      ], isArcFunc: isArcUbi, createInArchive: UbiArc.new, isContainer: true),
      ArcInfoEx(
          'UbiFs',
          _exts('ubifs'),
          ArcInfoFlags.symLinks |
              ArcInfoFlags.hardLinks |
              ArcInfoFlags.cTime |
              ArcInfoFlags.aTime |
              ArcInfoFlags.mTime,
          [
            Uint8List.fromList([0x31, 0x18, 0x10, 0x06])
          ],
          isArcFunc: isArcUbifs,
          createInArchive: UbiFsArc.new),
      // embedded file systems: SquashFS, cramfs, JFFS2 (read only)
      ArcInfoEx(
          'SquashFS',
          _exts('squashfs sqsh sfs sqfs'),
          ArcInfoFlags.symLinks | ArcInfoFlags.hardLinks | ArcInfoFlags.mTime,
          [
            Uint8List.fromList('hsqs'.codeUnits),
            Uint8List.fromList('sqsh'.codeUnits),
          ],
          isArcFunc: isArcSquashfs,
          createInArchive: SquashfsArc.new),
      ArcInfoEx('CramFS', _exts('cramfs'), ArcInfoFlags.symLinks, [
        Uint8List.fromList([0x45, 0x3D, 0xCD, 0x28]),
        Uint8List.fromList([0x28, 0xCD, 0x3D, 0x45]),
      ], isArcFunc: isArcCramfs, createInArchive: CramfsArc.new),
      ArcInfoEx(
          'Jffs2',
          _exts('jffs2'),
          ArcInfoFlags.symLinks |
              ArcInfoFlags.hardLinks |
              ArcInfoFlags.cTime |
              ArcInfoFlags.aTime |
              ArcInfoFlags.mTime,
          [
            Uint8List.fromList([0x85, 0x19]),
            Uint8List.fromList([0x19, 0x85]),
          ],
          isArcFunc: isArcJffs2,
          createInArchive: Jffs2Arc.new),
      // disk images and their file systems: MBR, GPT, FAT, ext2/3/4 (read
      // only); the MBR check defers to GPT (protective MBR), FAT boot
      // sectors and ISO 9660 system areas
      ArcInfoEx('MBR', _exts('mbr img'), 0, [
        Uint8List.fromList([0x55, 0xAA])
      ],
          signatureOffset: 510,
          isArcFunc: isArcMbr,
          createInArchive: MbrArc.new,
          isContainer: true),
      ArcInfoEx('GPT', _exts('gpt mbr img'), 0, [
        Uint8List.fromList('EFI PART'.codeUnits)
      ],
          signatureOffset: 512,
          isArcFunc: isArcGpt,
          createInArchive: GptArc.new,
          isContainer: true),
      ArcInfoEx('FAT', _exts('fat img vfd'),
          ArcInfoFlags.cTime | ArcInfoFlags.aTime | ArcInfoFlags.mTime,
          const [],
          isArcFunc: isArcFat, createInArchive: FatArc.new),
      ArcInfoEx(
          'Ext',
          _exts('ext ext2 ext3 ext4 img'),
          ArcInfoFlags.symLinks |
              ArcInfoFlags.hardLinks |
              ArcInfoFlags.cTime |
              ArcInfoFlags.aTime |
              ArcInfoFlags.mTime,
          [
            Uint8List.fromList([0x53, 0xEF])
          ],
          signatureOffset: 1080,
          isArcFunc: isArcExt,
          createInArchive: ExtArc.new),
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
/// port has it, so it is listed after LZMA as in the full 7-Zip order),
/// then the methods of the zip, rar, arj and lzh handlers. The last ones
/// are not 7z coders: they are listed so that `i` shows what the port can
/// decode (D) and encode (E); Lzh stands for lh0 to lh7 and the others.
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
  // the codecs of the other formats, with the ids of DOC/Methods.txt
  CodecInfoEntry(1, true, true, false, 0x40108, 'Deflate'),
  CodecInfoEntry(1, true, true, false, 0x40109, 'Deflate64'),
  CodecInfoEntry(1, true, true, false, 0x40202, 'BZip2'),
  CodecInfoEntry(1, false, true, false, 0x40101, 'Shrink'),
  CodecInfoEntry(1, false, true, false, 0x40106, 'Implode'),
  CodecInfoEntry(1, true, true, false, 0x40162, 'PPMdZip'),
  CodecInfoEntry(1, true, true, true, 0x40163, 'wzAES'),
  CodecInfoEntry(1, true, true, true, 0x6F10101, 'ZipCrypto'),
  CodecInfoEntry(1, false, true, false, 0x40303, 'Rar3'),
  CodecInfoEntry(1, true, true, false, 0x40305, 'Rar5'),
  CodecInfoEntry(1, true, true, false, 0x40401, 'Arj'),
  CodecInfoEntry(1, true, true, false, 0x40402, 'Arj4'),
  CodecInfoEntry(1, true, true, false, 0x406, 'Lzh'),
];

/// CHasherInfo of 7zr: (digest size, id, name) in registration order.
const List<(int, int, String)> kHashers = [
  (4, 0x1, 'CRC32'),
  (32, 0xA, 'SHA256'),
  (8, 0x4, 'CRC64'),
];
