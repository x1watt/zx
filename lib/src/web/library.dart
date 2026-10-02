// The library of the web version (docs/architecture.md section 20): the
// archives a user keeps in the browser, in the origin private file system
// (folder zx-library). Files are written with a synchronous access handle
// (workers only, every browser with OPFS has it) and read as Blobs
// (getFile, then BlobInStream), so an archive being read holds no lock.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../io/streams.dart' show SevenZipException, SevenZipError;
import 'js_bindings.dart';

class LibraryEntry {
  final String name;
  final int size;
  final DateTime modified;
  const LibraryEntry(this.name, this.size, this.modified);

  Map<String, Object?> toJson() => {
        'name': name,
        'size': size,
        'modified': modified.millisecondsSinceEpoch,
      };
}

JSObject _create() => JSObject()..['create'] = true.toJS;

/// A file name that OPFS accepts (no '/', '\', no NUL; not '.' or '..').
String libraryName(String name) {
  var n = name.replaceAll(RegExp(r'[/\\\x00]'), '_').trim();
  if (n.isEmpty || n == '.' || n == '..') n = 'archive';
  if (n.length > 200) n = n.substring(n.length - 200);
  return n;
}

class Library {
  JSDirectoryHandle? _dir;

  Future<JSDirectoryHandle> _folder() async =>
      _dir ??= await (await jsStorage.getDirectory().toDart)
          .getDirectoryHandle('zx-library', _create())
          .toDart;

  /// True when the browser has OPFS with synchronous access handles.
  static bool get available {
    try {
      final nav = globalContext['navigator'] as JSObject;
      final st = nav['storage'] as JSObject?;
      return st != null &&
          st.has('getDirectory') &&
          globalContext.has('FileSystemSyncAccessHandle');
    } catch (_) {
      return false;
    }
  }

  Future<List<LibraryEntry>> list() async {
    final dir = await _folder();
    final out = <LibraryEntry>[];
    final it = dir.values();
    for (;;) {
      final r = await it.next().toDart;
      if (r.done) break;
      final h = r.value as JSFileHandle;
      if (h.kind != 'file') continue;
      final f = await h.getFile().toDart as JSFileWithTime;
      out.add(LibraryEntry(h.name, f.size,
          DateTime.fromMillisecondsSinceEpoch(f.lastModified, isUtc: true)));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<bool> _exists(String name) async {
    try {
      await (await _folder()).getFileHandle(name).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// [name], or "name (2).ext"... when it is taken.
  Future<String> freeName(String name) async {
    final n = libraryName(name);
    if (!await _exists(n)) return n;
    final dot = n.lastIndexOf('.');
    final stem = dot > 0 ? n.substring(0, dot) : n;
    final ext = dot > 0 ? n.substring(dot) : '';
    for (var i = 2;; i++) {
      final c = '$stem ($i)$ext';
      if (!await _exists(c)) return c;
    }
  }

  /// The archive [name] as a File (a Blob read with FileReaderSync).
  Future<JSFile> file(String name) async =>
      (await (await _folder()).getFileHandle(name).toDart).getFile().toDart;

  Future<void> remove(String name) async {
    await (await _folder()).removeEntry(name).toDart;
  }

  /// Writes a new file [name] from [fill], which gets a function writing
  /// the next bytes; the file is removed when [fill] fails.
  Future<LibraryEntry> _write(String name,
      Future<void> Function(void Function(Uint8List) write) fill) async {
    final dir = await _folder();
    final fh = await dir.getFileHandle(name, _create()).toDart;
    final h = await fh.createSyncAccessHandle().toDart;
    var pos = 0;
    var ok = false;
    try {
      h.truncate(0);
      await fill((b) {
        final at = JSObject()..['at'] = pos.toJS;
        final n = h.write(b.toJS, at);
        if (n != b.length) {
          throw const SevenZipException(
              'the browser storage is full', SevenZipError.io);
        }
        pos += n;
      });
      h.flush();
      ok = true;
    } finally {
      h.close();
      if (!ok) {
        try {
          await dir.removeEntry(name).toDart;
        } catch (_) {
          // gone already
        }
      }
    }
    return LibraryEntry(name, pos, DateTime.now().toUtc());
  }

  /// Copies [blob] (an uploaded file) into the library as [name].
  Future<LibraryEntry> importBlob(JSBlob blob, String name,
      {void Function(int done, int total)? progress}) {
    const chunk = 8 << 20;
    return _write(name, (write) async {
      final reader = JSFileReaderSync();
      final total = blob.size;
      for (var p = 0; p < total; p += chunk) {
        final e = p + chunk < total ? p + chunk : total;
        write(reader.readAsArrayBuffer(blob.slice(p, e)).toDart.asUint8List());
        progress?.call(e, total);
        // lets the progress messages out
        await Future<void>.delayed(Duration.zero);
      }
    });
  }

  /// Downloads [url] whole into the library as [name] (for a server
  /// without range requests).
  Future<LibraryEntry> download(String url, String name,
      {int? size, void Function(int done, int total)? progress}) {
    return _write(name, (write) async {
      final init = JSObject()
        ..['credentials'] = 'omit'.toJS
        ..['cache'] = 'no-store'.toJS;
      final r = await jsFetch(url, init).toDart;
      if (r.status != 200) {
        throw SevenZipException(
            'the server answered HTTP ${r.status}', SevenZipError.io);
      }
      final body = r.body;
      if (body == null) {
        throw const SevenZipException(
            'the server sent no data', SevenZipError.io);
      }
      final reader = body.getReader();
      var done = 0;
      for (;;) {
        final c = await reader.read().toDart;
        if (c.done) break;
        final v = c.value;
        if (v == null) continue;
        final b = v.toDart;
        write(b);
        done += b.length;
        progress?.call(done, size ?? 0);
      }
    });
  }

  /// Bytes used and available to this site, and whether the browser keeps
  /// them under storage pressure.
  Future<Map<String, Object?>> usage() async {
    final e = await jsStorage.estimate().toDart;
    var persisted = false;
    try {
      persisted = (await jsStorage.persisted().toDart).toDart;
    } catch (_) {
      // not in this browser
    }
    return {
      'usage': e.usage?.toInt(),
      'quota': e.quota?.toInt(),
      'persisted': persisted,
    };
  }
}
