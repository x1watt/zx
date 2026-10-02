// Writes an export (CSV, JSON) where the save dialog said: a file on the
// native platforms, a download in the browser.

export 'save_text_io.dart' if (dart.library.js_interop) '../web/save_web.dart';
