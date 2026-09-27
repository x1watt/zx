// The fdt handler (lib/src/format/fdt/fdt_handler.dart) seen through the CLI's
// IInArchive shape (read only, see arc_simple.dart).

import '../format/fdt/fdt_handler.dart';
import 'arc_simple.dart';

/// The fdt handler.
class FdtArc extends ReadOnlyArc {
  FdtArc() : super(FdtHandler());
}
