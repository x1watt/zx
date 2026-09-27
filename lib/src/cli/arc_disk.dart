// The disk image and file system handlers (MBR, GPT, FAT, ext2/3/4) seen
// through the CLI's IInArchive shape (read only, see arc_simple.dart).

import '../format/disk/gpt_handler.dart';
import '../format/disk/mbr_handler.dart';
import '../format/ext/ext_handler.dart';
import '../format/fat/fat_handler.dart';
import 'arc_simple.dart';

/// The MBR handler.
class MbrArc extends ReadOnlyArc {
  MbrArc() : super(MbrHandler());
}

/// The GPT handler.
class GptArc extends ReadOnlyArc {
  GptArc() : super(GptHandler());
}

/// The FAT handler.
class FatArc extends ReadOnlyArc {
  FatArc() : super(FatHandler());
}

/// The ext2/3/4 handler.
class ExtArc extends ReadOnlyArc {
  ExtArc() : super(ExtHandler());
}
