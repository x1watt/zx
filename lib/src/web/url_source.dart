// Archives at a URL in the web engine (docs/architecture.md section 20).
// Before anything is read, [probeUrl] asks for the first byte with a Range
// header and decides:
//   range    the server answers 206 to a cross-origin request: the archive
//            is read where it is, with HttpRangeInStream over synchronous
//            XMLHttpRequests (XhrRangeTransport), fetching only the parts
//            the reader needs;
//   full     the server answers 200 (no ranges): the archive can only be
//            downloaded whole, into the library;
//   blocked  the request fails: no CORS headers (GitHub release assets),
//            no network, or no such host.
// Content-Range and ETag are read only when the server exposes them
// (Access-Control-Expose-Headers); the size comes from Content-Range, else
// from a HEAD request (Content-Length is always readable).

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../io/streams.dart' show SevenZipException, SevenZipError;
import 'js_bindings.dart';
import 'range_stream.dart';

enum UrlAccess { range, full, blocked }

class UrlProbe {
  final UrlAccess access;

  /// The size of the file (null when the server does not tell it).
  final int? size;
  final String? etag;

  /// The HTTP status of an error, or the browser's message.
  final String? problem;
  const UrlProbe(this.access, {this.size, this.etag, this.problem});

  Map<String, Object?> toJson() =>
      {'access': access.name, 'size': size, 'problem': problem};
}

JSObject _init(
    {String? method, Map<String, String>? headers, JSObject? signal}) {
  final o = JSObject();
  if (method != null) o['method'] = method.toJS;
  if (headers != null) o['headers'] = headers.jsify();
  if (signal != null) o['signal'] = signal;
  // no cookies: a public archive is read like any download
  o['credentials'] = 'omit'.toJS;
  o['cache'] = 'no-store'.toJS;
  return o;
}

/// Decides how the archive at [url] can be read (see the file comment).
Future<UrlProbe> probeUrl(String url) async {
  final abort = JSAbortController();
  JSResponse r;
  try {
    r = await jsFetch(
            url, _init(headers: {'Range': 'bytes=0-0'}, signal: abort.signal))
        .toDart;
  } catch (e) {
    return UrlProbe(UrlAccess.blocked, problem: '$e');
  }
  final status = r.status;
  if (status == 206) {
    final etag = r.headers.get('ETag');
    var size = contentRangeTotal(r.headers.get('Content-Range'));
    abort.abort();
    size ??= await _headSize(url);
    if (size == null) {
      return const UrlProbe(UrlAccess.full,
          problem: 'the server does not tell the size of the file');
    }
    return UrlProbe(UrlAccess.range, size: size, etag: etag);
  }
  if (status == 200) {
    final n = int.tryParse(r.headers.get('Content-Length') ?? '');
    abort.abort();
    return UrlProbe(UrlAccess.full, size: n);
  }
  abort.abort();
  return UrlProbe(UrlAccess.blocked, problem: 'HTTP $status');
}

Future<int?> _headSize(String url) async {
  try {
    final r = await jsFetch(url, _init(method: 'HEAD')).toDart;
    if (!r.ok) return null;
    return int.tryParse(r.headers.get('Content-Length') ?? '');
  } catch (_) {
    return null;
  }
}

/// Range requests with synchronous XMLHttpRequest (allowed in workers,
/// and the only synchronous network read a browser has).
class XhrRangeTransport implements RangeTransport {
  final String url;
  XhrRangeTransport(this.url);

  @override
  RangeResponse fetch(int start, int endInclusive) {
    final x = JSXMLHttpRequest();
    x.open('GET', url, false);
    x.setRequestHeader('Range', 'bytes=$start-$endInclusive');
    x.responseType = 'arraybuffer';
    try {
      x.send();
    } catch (e) {
      throw SevenZipException(
          'the server can not be reached ($e)', SevenZipError.io);
    }
    final body = x.response;
    final bytes = body == null
        ? Uint8List(0)
        : Uint8List.fromList((body as JSArrayBuffer).toDart.asUint8List());
    return RangeResponse(x.status, bytes,
        contentRange: x.getResponseHeader('Content-Range'),
        etag: x.getResponseHeader('ETag'),
        contentEncoding: x.getResponseHeader('Content-Encoding'));
  }
}
