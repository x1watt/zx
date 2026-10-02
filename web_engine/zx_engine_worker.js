// Starts the zx engine (zx_engine.wasm, compiled by dart2wasm) in this
// module worker (docs/architecture.md section 20). A browser that can not
// run it (no WebAssembly GC) gets an 'unsupported' event with the reason.
import * as loader from './zx_engine.mjs';

try {
  const app = await loader.compileStreaming(
      fetch(new URL('./zx_engine.wasm', import.meta.url)));
  const instance = await app.instantiate({});
  instance.invokeMain();
} catch (e) {
  postMessage({event: 'unsupported', message: String(e)});
}
