// The UBIFS handler (lib/src/format/ubifs/ubifs_handler.dart) seen through
// the CLI's IInArchive shape (read only, see arc_simple.dart).

import '../format/ubifs/ubifs_handler.dart';
import 'arc_simple.dart';

/// The UBIFS handler.
class UbiFsArc extends ReadOnlyArc {
  UbiFsArc() : super(UbifsHandler());
}
