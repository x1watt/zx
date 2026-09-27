// The CramFS handler (lib/src/format/cramfs/cramfs_handler.dart) seen through the
// CLI's IInArchive shape (read only, see arc_simple.dart).

import '../format/cramfs/cramfs_handler.dart';
import 'arc_simple.dart';

/// The CramFS handler.
class CramfsArc extends ReadOnlyArc {
  CramfsArc() : super(CramfsHandler());
}
