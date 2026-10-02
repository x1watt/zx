// The UI side of the web engine (docs/architecture.md section 20): starts
// the engine worker and sends it requests. Compiles with dart2js and
// dart2wasm (the Flutter web build makes both); it holds no engine code.
// A request's progress and password questions come back as events of the
// request; cancelling a request drops its answer (the engine, a single
// thread, finishes the request it is running).

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../api_types.dart';
import '../io/streams.dart' show SevenZipException, SevenZipError;
import '../zx_types.dart';
import 'wire.dart';

@JS('Worker')
extension type _JSWorker._(JSObject _) implements JSObject {
  external _JSWorker(String url, [JSObject? options]);
  external void postMessage(JSAny? message, [JSArray<JSObject>? transfer]);
  external set onmessage(JSFunction? f);
  external set onerror(JSFunction? f);
  external void terminate();
}

extension type _JSEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
  external String? get message;
}

/// The answer of a request.
class EngineReply {
  final Object? json;
  final Uint8List? bytes;
  const EngineReply(this.json, this.bytes);
}

class _Call {
  final Completer<EngineReply> done = Completer();
  final void Function(SevenZipProgress)? onProgress;
  final ZxPasswordCallback? onPassword;
  _Call(this.onProgress, this.onPassword);
}

class ZxEngine {
  final _JSWorker _worker;
  final Map<int, _Call> _calls = {};
  int _next = 1;

  /// The engine's version and whether the browser has a library (OPFS).
  final String version;
  final bool hasLibrary;

  ZxEngine._(this._worker, this.version, this.hasLibrary);

  static ZxEngine? _instance;
  static Future<ZxEngine>? _starting;

  /// The engine, once [start] has run.
  static ZxEngine get instance =>
      _instance ?? (throw StateError('the zx engine is not started'));

  /// Starts the engine worker from [url] (zx_engine_worker.js). Fails with
  /// [UnsupportedError] when the browser can not run it (no WebAssembly
  /// GC, no module workers).
  static Future<ZxEngine> start(String url) =>
      _starting ??= _start(url).then((e) => _instance = e);

  static Future<ZxEngine> _start(String url) {
    final ready = Completer<ZxEngine>();
    final opts = JSObject()..['type'] = 'module'.toJS;
    final w = _JSWorker(url, opts);
    late ZxEngine engine;
    w.onerror = ((_JSEvent e) {
      if (!ready.isCompleted) {
        ready.completeError(
            UnsupportedError('the zx engine did not start: ${e.message}'));
      }
    }).toJS;
    w.onmessage = ((_JSEvent e) {
      final m = e.data as JSObject;
      final event = (m['event'] as JSString?)?.toDart;
      if (!ready.isCompleted) {
        if (event == 'ready') {
          final j = jsonDecode((m['json'] as JSString).toDart) as Map;
          engine = ZxEngine._(w, j['version'] as String, j['library'] as bool);
          ready.complete(engine);
        } else if (event == 'unsupported') {
          ready.completeError(UnsupportedError(
              (m['message'] as JSString?)?.toDart ??
                  'this browser can not run the zx engine'));
        }
        return;
      }
      engine._onMessage(m);
    }).toJS;
    return ready.future;
  }

  void _onMessage(JSObject m) {
    final id = (m['id'] as JSNumber).toDartInt;
    final call = _calls[id];
    if (call == null) return;
    final j = m['json'];
    final json = j == null ? null : jsonDecode((j as JSString).toDart);
    switch ((m['event'] as JSString?)?.toDart) {
      case 'progress':
        call.onProgress?.call(progressFromWire(json as List<Object?>));
        return;
      case 'ask':
        _answer(id, call, json as Map<String, Object?>);
        return;
    }
    _calls.remove(id);
    if ((m['ok'] as JSBoolean).toDart) {
      final b = m['bytes'];
      call.done.complete(EngineReply(
          json, b == null ? null : (b as JSArrayBuffer).toDart.asUint8List()));
    } else {
      call.done
          .completeError(errorFromWire((json as Map).cast<String, Object?>()));
    }
  }

  Future<void> _answer(int id, _Call call, Map<String, Object?> q) async {
    String? answer;
    final ask = call.onPassword;
    if (ask != null) answer = await ask(passwordRequestFromWire(q));
    final o = JSObject()
      ..['id'] = id.toJS
      ..['op'] = 'answer'.toJS
      ..['args'] = jsonEncode({'answer': answer}).toJS;
    _worker.postMessage(o);
  }

  /// Sends the request [op] with [args] (and [files], File objects of the
  /// page) and waits for its answer.
  Future<EngineReply> call(String op,
      {Map<String, Object?> args = const {},
      JSArray<JSObject>? files,
      void Function(SevenZipProgress)? onProgress,
      ZxPasswordCallback? onPassword,
      SevenZipCancelToken? cancel}) {
    if (cancel != null && cancel.isCancelled) {
      return Future.error(
          const SevenZipException('Cancelled', SevenZipError.cancelled));
    }
    final id = _next++;
    final c = _Call(onProgress, onPassword);
    _calls[id] = c;
    final o = JSObject()
      ..['id'] = id.toJS
      ..['op'] = op.toJS
      ..['args'] = jsonEncode(args).toJS;
    if (files != null) o['files'] = files;
    _worker.postMessage(o);
    if (cancel == null) return c.done.future;
    void onCancel() {
      if (_calls.remove(id) != null) {
        c.done.completeError(
            const SevenZipException('Cancelled', SevenZipError.cancelled));
      }
    }

    cancel.addCancelListener(onCancel);
    return c.done.future
        .whenComplete(() => cancel.removeCancelListener(onCancel));
  }
}
