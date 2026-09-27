// The pak handler (lib/src/format/pak/pak_handler.dart) seen through the CLI's
// IInArchive shape (read only, see arc_simple.dart).

import '../format/pak/pak_handler.dart';
import 'arc_simple.dart';

/// The pak handler.
class PakArc extends ReadOnlyArc {
  PakArc() : super(PakHandler());
}
