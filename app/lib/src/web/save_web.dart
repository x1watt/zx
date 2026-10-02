// Downloads in the browser: the bytes become a Blob, and a link to it with
// the download attribute is clicked. The name is the last component of
// the path the (web) save dialog gave.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external _Blob(JSArray<JSAny> parts, [JSObject? options]);
}

@JS('URL.createObjectURL')
external String _createUrl(JSObject blob);

@JS('URL.revokeObjectURL')
external void _revokeUrl(String url);

@JS('document')
external JSObject get _document;

/// Offers [bytes] as a download named after [path].
Future<void> saveBytes(
  String path,
  Uint8List bytes, {
  String type = 'application/octet-stream',
}) async {
  final name = path.substring(path.lastIndexOf('/') + 1);
  final blob = _Blob(
    [bytes.toJS as JSAny].toJS,
    JSObject()..['type'] = type.toJS,
  );
  final url = _createUrl(blob);
  final a = _document.callMethod<JSObject>('createElement'.toJS, 'a'.toJS);
  a['href'] = url.toJS;
  a['download'] = name.toJS;
  a['rel'] = 'noopener'.toJS;
  final body = _document['body'] as JSObject;
  body.callMethod<JSAny?>('append'.toJS, a);
  a.callMethod<JSAny?>('click'.toJS);
  a.callMethod<JSAny?>('remove'.toJS);
  // the download has started; the URL is released a little later
  Future<void>.delayed(const Duration(minutes: 1), () => _revokeUrl(url));
}

/// Offers [text] (UTF-8) as a download named after [path].
Future<void> saveText(String path, String text) => saveBytes(
  path,
  Uint8List.fromList(utf8.encode(text)),
  type: 'text/plain;charset=utf-8',
);
