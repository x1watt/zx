// The SquashFS handler (lib/src/format/squashfs/squashfs_handler.dart) seen through the
// CLI's IInArchive shape (read only, see arc_simple.dart).

import '../format/squashfs/squashfs_handler.dart';
import 'arc_simple.dart';

/// The SquashFS handler.
class SquashfsArc extends ReadOnlyArc {
  SquashfsArc() : super(SquashfsHandler());
}
