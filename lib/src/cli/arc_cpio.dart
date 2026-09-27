// The cpio handler (lib/src/format/cpio/cpio_handler.dart) seen through the CLI's
// IInArchive shape (read only, see arc_simple.dart).

import '../format/cpio/cpio_handler.dart';
import 'arc_simple.dart';

/// The cpio handler.
class CpioArc extends ReadOnlyArc {
  CpioArc() : super(CpioHandler());
}
