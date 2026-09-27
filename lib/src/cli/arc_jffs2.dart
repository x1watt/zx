// The JFFS2 handler (lib/src/format/jffs2/jffs2_handler.dart) seen through the
// CLI's IInArchive shape (read only, see arc_simple.dart).

import '../format/jffs2/jffs2_handler.dart';
import 'arc_simple.dart';

/// The JFFS2 handler.
class Jffs2Arc extends ReadOnlyArc {
  Jffs2Arc() : super(Jffs2Handler());
}
