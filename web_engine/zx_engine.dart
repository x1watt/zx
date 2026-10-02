// The zx engine of the web version (docs/architecture.md section 20): the
// library compiled with dart2wasm (`dart compile wasm`), started by
// zx_engine_worker.js in a module Web Worker. See lib/src/web/engine.dart.

import 'package:zx/src/web/engine.dart';

void main() => Engine().start();
