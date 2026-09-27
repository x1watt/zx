// The UBI handler (lib/src/format/ubi/ubi_handler.dart) seen through the
// CLI's IInArchive shape (read only, see arc_simple.dart).

import '../format/ubi/ubi_handler.dart';
import 'arc_simple.dart';

/// The UBI handler.
class UbiArc extends ReadOnlyArc {
  UbiArc() : super(UbiHandler());
}
