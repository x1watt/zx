// The uimage handler (lib/src/format/uimage/uimage_handler.dart) seen through the CLI's
// IInArchive shape (read only, see arc_simple.dart).

import '../format/uimage/uimage_handler.dart';
import 'arc_simple.dart';

/// The uimage handler.
class UImageArc extends ReadOnlyArc {
  UImageArc() : super(UImageHandler());
}
