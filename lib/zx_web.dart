/// The web version's own calls (docs/architecture.md section 20): starting
/// the engine worker, adding uploaded files and URLs, the library in
/// browser storage, databases. For the browser only; use with
/// package:zx/zx_client.dart.
library;

export 'src/web/engine_client.dart' show ZxEngine, EngineReply;
export 'src/web/web_client.dart';
