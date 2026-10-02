// The browser APIs the web engine uses (docs/architecture.md section 20),
// bound by hand with dart:js_interop: the library has no packages. Only
// lib/src/web/** and lib/src/host/*_web.dart may import this.

import 'dart:js_interop';

/// postMessage of the worker scope.
@JS('postMessage')
external void jsPostMessage(JSAny? message, [JSArray<JSObject>? transfer]);

/// onmessage of the worker scope.
@JS('onmessage')
external set jsOnMessage(JSFunction? handler);

extension type JSMessageEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
}

extension type JSBlob._(JSObject _) implements JSObject {
  external int get size;
  external JSBlob slice(int start, int end);
}

extension type JSFile._(JSObject _) implements JSBlob {
  external String get name;
}

/// FileReaderSync: synchronous reads of a Blob (workers only).
@JS('FileReaderSync')
extension type JSFileReaderSync._(JSObject _) implements JSObject {
  external JSFileReaderSync();
  external JSArrayBuffer readAsArrayBuffer(JSBlob blob);
}

/// XMLHttpRequest, used synchronously (workers only) for byte ranges.
@JS('XMLHttpRequest')
extension type JSXMLHttpRequest._(JSObject _) implements JSObject {
  external JSXMLHttpRequest();
  external void open(String method, String url, bool async);
  external void setRequestHeader(String name, String value);
  external set responseType(String value);
  external void send();
  external int get status;
  external JSAny? get response;
  external String? getResponseHeader(String name);
}

extension type JSFileWithTime._(JSObject _) implements JSFile {
  external int get lastModified;
}

// ---------------------------------------------------------------------------
// fetch (the probe of a URL and full downloads)

@JS('fetch')
external JSPromise<JSResponse> jsFetch(String url, [JSObject? init]);

extension type JSResponse._(JSObject _) implements JSObject {
  external int get status;
  external bool get ok;
  external JSHeaders get headers;
  external JSReadableStream? get body;
}

extension type JSHeaders._(JSObject _) implements JSObject {
  external String? get(String name);
}

extension type JSReadableStream._(JSObject _) implements JSObject {
  external JSReadableStreamReader getReader();
}

extension type JSReadableStreamReader._(JSObject _) implements JSObject {
  external JSPromise<JSReadResult> read();
  external JSPromise<JSAny?> cancel();
}

extension type JSReadResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

@JS('AbortController')
extension type JSAbortController._(JSObject _) implements JSObject {
  external JSAbortController();
  external JSObject get signal;
  external void abort();
}

// ---------------------------------------------------------------------------
// The origin private file system (the library)

@JS('navigator.storage')
external JSStorageManager get jsStorage;

extension type JSStorageManager._(JSObject _) implements JSObject {
  external JSPromise<JSDirectoryHandle> getDirectory();
  external JSPromise<JSStorageEstimate> estimate();
  external JSPromise<JSBoolean> persist();
  external JSPromise<JSBoolean> persisted();
}

extension type JSStorageEstimate._(JSObject _) implements JSObject {
  external double? get usage;
  external double? get quota;
}

extension type JSDirectoryHandle._(JSObject _) implements JSObject {
  external JSPromise<JSDirectoryHandle> getDirectoryHandle(String name,
      [JSObject? options]);
  external JSPromise<JSFileHandle> getFileHandle(String name,
      [JSObject? options]);
  external JSPromise<JSAny?> removeEntry(String name, [JSObject? options]);

  /// An async iterator of the handles in the folder.
  external JSAsyncIterator values();
}

extension type JSAsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<JSIteratorResult> next();
}

extension type JSIteratorResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSAny? get value;
}

extension type JSFileHandle._(JSObject _) implements JSObject {
  external String get kind;
  external String get name;
  external JSPromise<JSFile> getFile();
  external JSPromise<JSSyncAccessHandle> createSyncAccessHandle();
}

/// FileSystemSyncAccessHandle: synchronous writes (workers only).
extension type JSSyncAccessHandle._(JSObject _) implements JSObject {
  external int write(JSUint8Array buffer, [JSObject? options]);
  external int getSize();
  external void truncate(int size);
  external void flush();
  external void close();
}
