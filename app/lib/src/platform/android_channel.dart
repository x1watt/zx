// The "zx/android" method channel: the Kotlin side is
// app/android/app/src/main/kotlin/io/github/maxbrito/zx_app/ (MainActivity
// and ZxStorage). Every call is asynchronous; the Kotlin side does its I/O
// on a background thread, so nothing here blocks the UI isolate.
//
// Besides what AndroidPlaces needs, this file has:
// - [AndroidIntents]: the archives other apps open with zx (ACTION_VIEW)
//   and the files shared to zx (ACTION_SEND, SEND_MULTIPLE);
// - [AndroidSaf]: the Storage Access Framework, for folders dart:io can
//   not reach (no "All files access"): pick a document tree, list, copy a
//   document to a local file and back, delete, rename, make a folder.

import 'dart:async';

import 'package:flutter/services.dart';

const MethodChannel zxAndroidChannel = MethodChannel('zx/android');

/// A file of an incoming intent.
class IncomingFile {
  /// A local path dart:io can read, or null when the file could not be
  /// read (then [error] says why).
  final String? path;
  final String name;

  /// True when [path] is a copy in the app's cache (the other app gave a
  /// content URI zx can not reach directly): changes to it do not reach
  /// the original.
  final bool copied;

  /// The URI the other app sent.
  final String? uri;
  final String? error;

  const IncomingFile({
    required this.path,
    required this.name,
    this.copied = false,
    this.uri,
    this.error,
  });
}

/// What another app asked zx to do.
enum IncomingAction {
  /// Open an archive (ACTION_VIEW).
  view,

  /// Files shared to zx (ACTION_SEND, SEND_MULTIPLE): compress them into
  /// a new archive.
  send,
}

class IncomingIntent {
  final IncomingAction action;
  final String? mime;
  final List<IncomingFile> files;

  const IncomingIntent(this.action, this.files, {this.mime});

  /// The files that can be read.
  List<String> get paths => [
    for (final f in files)
      if (f.path != null) f.path!,
  ];

  static IncomingIntent? fromMap(Object? m) {
    if (m is! Map) return null;
    final files = <IncomingFile>[
      for (final f in (m['files'] as List? ?? const []))
        if (f is Map)
          IncomingFile(
            path: f['path'] as String?,
            name: f['name'] as String? ?? 'file',
            copied: f['copied'] == true,
            uri: f['uri'] as String?,
            error: f['error'] as String?,
          ),
    ];
    return IncomingIntent(
      m['action'] == 'view' ? IncomingAction.view : IncomingAction.send,
      files,
      mime: m['mime'] as String?,
    );
  }
}

/// The intents of other apps. Call [initial] once when the UI is ready
/// (it also tells the Kotlin side to deliver later intents to [stream]).
class AndroidIntents {
  AndroidIntents._();
  static final AndroidIntents instance = AndroidIntents._();

  final _ctl = StreamController<IncomingIntent>.broadcast();
  bool _listening = false;

  /// The intents that arrive while the app runs.
  Stream<IncomingIntent> get stream {
    _listen();
    return _ctl.stream;
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    zxAndroidChannel.setMethodCallHandler((call) async {
      if (call.method == 'intent') {
        final i = IncomingIntent.fromMap(call.arguments);
        if (i != null) _ctl.add(i);
      }
      return null;
    });
  }

  /// The intent that started the app, or null (started from the launcher).
  Future<IncomingIntent?> initial() async {
    _listen();
    try {
      return IncomingIntent.fromMap(
        await zxAndroidChannel.invokeMethod<Object?>('takeIntent'),
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// A document (file or folder) of the Storage Access Framework.
class SafEntry {
  final String uri;
  final String name;
  final String? mime;
  final bool isDir;
  final int size;
  final DateTime? modified;
  final bool writable;
  final bool deletable;

  const SafEntry({
    required this.uri,
    required this.name,
    required this.isDir,
    this.mime,
    this.size = 0,
    this.modified,
    this.writable = false,
    this.deletable = false,
  });

  static SafEntry fromMap(Map m) {
    final t = (m['mtime'] as num?)?.toInt() ?? 0;
    return SafEntry(
      uri: m['uri'] as String,
      name: m['name'] as String? ?? '',
      mime: m['mime'] as String?,
      isDir: m['dir'] == true,
      size: (m['size'] as num?)?.toInt() ?? 0,
      modified: t > 0 ? DateTime.fromMillisecondsSinceEpoch(t) : null,
      writable: m['writable'] == true,
      deletable: m['deletable'] == true,
    );
  }
}

/// A document tree the user chose (its permission is kept across
/// restarts until [AndroidSaf.release]).
class SafTree {
  /// The root document of the tree (pass it to [AndroidSaf.list]).
  final String uri;
  final String name;

  /// The local path of the tree when dart:io can read it, else null.
  final String? path;

  const SafTree(this.uri, this.name, this.path);

  static SafTree fromMap(Map m) => SafTree(
    m['uri'] as String,
    m['name'] as String? ?? 'Folder',
    m['path'] as String?,
  );
}

/// The Storage Access Framework. Every method returns null / false / an
/// empty list when the call fails.
class AndroidSaf {
  const AndroidSaf();

  Future<T?> _call<T>(String m, [Map<String, Object?>? args]) async {
    try {
      return await zxAndroidChannel.invokeMethod<T>(m, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens the system's folder picker; the chosen tree, or null.
  Future<SafTree?> pickTree() async {
    final m = await _call<Map>('pickTree');
    return m == null ? null : SafTree.fromMap(m);
  }

  /// The trees chosen before.
  Future<List<SafTree>> trees() async {
    final l = await _call<List>('trees') ?? const [];
    return [
      for (final m in l)
        if (m is Map) SafTree.fromMap(m),
    ];
  }

  Future<void> release(String uri) => _call('releaseTree', {'uri': uri});

  Future<List<SafEntry>> list(String uri) async {
    final l = await _call<List>('safList', {'uri': uri}) ?? const [];
    return [
      for (final m in l)
        if (m is Map) SafEntry.fromMap(m),
    ];
  }

  Future<SafEntry?> stat(String uri) async {
    final m = await _call<Map>('safStat', {'uri': uri});
    return m == null ? null : SafEntry.fromMap(m);
  }

  /// The local path of a document when dart:io can read it, else null.
  Future<String?> pathOf(String uri) => _call<String>('safPath', {'uri': uri});

  /// Copies a document to the local file [path] (for example to open an
  /// archive with ZxArchive); the path, or null.
  Future<String?> copyOut(String uri, String path) =>
      _call<String>('safCopyOut', {'uri': uri, 'path': path});

  /// Copies the local file [path] into the folder document [parent] as
  /// [name]; the URI of the new document, or null.
  Future<String?> copyIn(
    String path,
    String parent,
    String name, {
    String? mime,
  }) => _call<String>('safCopyIn', {
    'path': path,
    'parent': parent,
    'name': name,
    'mime': mime,
  });

  Future<bool> delete(String uri) async =>
      await _call<bool>('safDelete', {'uri': uri}) ?? false;

  Future<String?> mkdir(String parent, String name) =>
      _call<String>('safMkdir', {'parent': parent, 'name': name});

  Future<String?> rename(String uri, String name) =>
      _call<String>('safRename', {'uri': uri, 'name': name});
}
