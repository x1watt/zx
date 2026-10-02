// dart:io for the library, also on the web (docs/architecture.md section
// 20). Natively it is dart:io itself; compiled for the web (dart2wasm) it
// is dart:io with a Platform that answers instead of throwing: the read
// path asks it for the path separator, the processor count or the
// operating system, and runs single threaded. Files and processes are not
// used on the web read path (its sources are SeekableInStreams).
export 'io_native.dart' if (dart.library.js_interop) 'io_web.dart';
