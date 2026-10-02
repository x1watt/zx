// The page of the web version (https://x1watt.github.io/zx/online/): an
// archive is opened from the user's files (picked or dropped; read where
// they are, nothing is uploaded anywhere), from a URL (read with range
// requests when the server allows it, else downloaded whole into the
// library on request), or from the library kept in the browser's storage.
// Archives are read only here. docs/app.md "The web version".

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:zx/zx_client.dart';
import 'package:zx/zx_web.dart';

import '../archive_model.dart';
import '../db_session.dart';
import '../ui/format_utils.dart';
import 'web_archive.dart';
import 'web_services.dart';

/// Where the open archive is read from.
enum _Kind { file, url, library }

class _Source {
  final _Kind kind;
  final String name;

  /// The engine path.
  final String path;

  /// The URL of a remote archive.
  final String? url;
  const _Source(this.kind, this.name, this.path, {this.url});
}

class WebHome extends StatefulWidget {
  /// Where the engine worker is (relative to the page).
  final String engineUrl;
  const WebHome({super.key, this.engineUrl = 'engine/zx_engine_worker.js'});

  @override
  State<WebHome> createState() => _WebHomeState();
}

class _WebHomeState extends State<WebHome> {
  ZxEngine? _engine;
  Object? _engineError;
  List<ZxLibraryEntry> _library = const [];
  ZxLibraryUsage? _usage;
  List<String> _recent = const [];
  _Source? _source;
  ArchiveModel? _model;
  DbSession? _db;
  bool _hover = false;
  String? _busy;
  ZxProgress? _progress;
  ZxCancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    _recent = recentUrls();
    listenForDrops(_openFiles, (h) {
      if (h != _hover && mounted) setState(() => _hover = h);
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final e = await ZxEngine.start(widget.engineUrl);
      if (!mounted) return;
      setState(() => _engine = e);
      await _loadLibrary();
      final url = urlParameter();
      if (url != null) await _openUrl(url);
    } catch (e) {
      if (mounted) setState(() => _engineError = e);
    }
  }

  Future<void> _loadLibrary() async {
    final e = _engine;
    if (e == null || !e.hasLibrary) return;
    try {
      final (l, u) = await e.library();
      if (mounted) {
        setState(() {
          _library = l;
          _usage = u;
        });
      }
    } catch (_) {
      // the library stays empty
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<T?> _run<T>(
    String what,
    Future<T> Function(ZxCancelToken cancel) body,
  ) async {
    final c = ZxCancelToken();
    setState(() {
      _busy = what;
      _progress = null;
      _cancel = c;
    });
    try {
      return await body(c);
    } catch (e) {
      if (!(e is SevenZipException && e.kind == SevenZipError.cancelled)) {
        _snack(errorText(e));
      }
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _cancel = null;
        });
      }
    }
  }

  void _onProgress(ZxProgress p) {
    if (mounted) setState(() => _progress = p);
  }

  // ---- opening

  Future<String?> _askPassword(ZxPasswordRequest q) async {
    final c = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_outline_rounded),
        title: Text(q.retry ? 'Wrong password, try again' : 'Password'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: c,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(
              hintText: q.itemPath ?? 'The password of the archive',
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    c.dispose();
    return r;
  }

  Future<void> _show(_Source s) async {
    final a = await _run(
      'Opening ${s.name}',
      (cancel) =>
          ZxArchive.open(s.path, onPassword: _askPassword, cancel: cancel),
    );
    if (a == null || !mounted) return;
    await _closeCurrent();
    final m = ArchiveModel(a);
    DbSession? db;
    if (a.format == 'zx') {
      db = DbSession(
        a.path,
        password: a.password,
        readOnlyWhy: 'The browser version',
        opener: webDbOpener,
      );
      unawaited(db.start());
    }
    setState(() {
      _source = s;
      _model = m;
      _db = db;
    });
    setUrlParameter(s.url);
  }

  Future<void> _closeCurrent() async {
    final m = _model;
    final db = _db;
    _model = null;
    _db = null;
    await db?.close();
    for (ArchiveModel? l = m; l != null; l = l.parent) {
      await l.closeHandles();
    }
  }

  Future<void> _close() async {
    await _closeCurrent();
    setUrlParameter(null);
    if (mounted) setState(() => _source = null);
  }

  /// The archive of a set of files: the first volume of a set, else the
  /// first file.
  int _firstArchive(List<String> names) {
    for (var i = 0; i < names.length; i++) {
      final n = names[i].toLowerCase();
      if (n.endsWith('.001') || RegExp(r'\.part0*1\.rar$').hasMatch(n)) {
        return i;
      }
    }
    return 0;
  }

  Future<void> _openFiles(JSArray<JSObject> files) async {
    final e = _engine;
    if (e == null) return;
    final paths = await _run('Reading', (_) => e.addFiles(files));
    if (paths == null || paths.isEmpty) return;
    final names = [for (final p in paths) p.substring(p.lastIndexOf('/') + 1)];
    final k = _firstArchive(names);
    await _show(_Source(_Kind.file, names[k], paths[k]));
  }

  Future<void> _pick() async {
    final files = await pickFiles();
    if (files != null && files.length > 0) await _openFiles(files);
  }

  Future<void> _openUrl(String url) async {
    final e = _engine;
    if (e == null) return;
    final u = Uri.tryParse(url.trim());
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http')) {
      _snack('Give an http or https address.');
      return;
    }
    final info = await _run('Contacting ${u.host}', (_) => e.addUrl('$u'));
    if (info == null || !mounted) return;
    switch (info.access) {
      case ZxUrlAccess.range:
        rememberUrl('$u');
        setState(() => _recent = recentUrls());
        await _show(_Source(_Kind.url, info.name, info.path!, url: '$u'));
      case ZxUrlAccess.full:
        await _offerDownload('$u', info);
      case ZxUrlAccess.blocked:
        await _explainBlocked('$u', info);
    }
  }

  Future<void> _offerDownload(String url, ZxUrlInfo info) async {
    final e = _engine!;
    final size = info.size == null ? '' : ' (${formatBytes(info.size)})';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.cloud_download_outlined),
        title: const Text('Download the whole archive?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            'The server of this address sends the file only as a whole '
            '(it does not answer requests for parts of it), so the archive '
            'can not be read in place. It can be downloaded$size into '
            'the library of this browser and opened from there.'
            '${e.hasLibrary ? '' : '\n\nThis browser has no storage for '
                      'the library.'}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: e.hasLibrary ? () => Navigator.pop(context, true) : null,
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final entry = await _run(
      'Downloading ${info.name}',
      (cancel) => e.download(
        url,
        info.name,
        size: info.size,
        onProgress: _onProgress,
        cancel: cancel,
      ),
    );
    if (entry == null) return;
    await _loadLibrary();
    await _openLibrary(entry.name, url: url);
  }

  Future<void> _explainBlocked(String url, ZxUrlInfo info) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.block_rounded),
        title: const Text('This address can not be read from here'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            '${info.problem == null ? '' : 'The browser said: ${info.problem}.\n\n'}'
            'A web page may read a file of another site only when that '
            'site allows it (CORS headers). Many hosts do not, GitHub '
            'release downloads among them. Download the file with the '
            'browser and open it here with Open files, or host it where '
            'CORS is allowed (GitHub Pages, raw file hosting, a bucket '
            'with a CORS rule).',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _askUrl() async {
    final c = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.link_rounded),
        title: const Text('Open an archive from an address'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('web-url-field'),
                controller: c,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'https://example.org/archive.zx',
                ),
                onSubmitted: (v) => Navigator.pop(context, v),
              ),
              const SizedBox(height: 12),
              const Text(
                'Only the parts of the archive that are needed are '
                'fetched, when the server allows it: listing a large '
                'archive reads its start and its end.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    c.dispose();
    if (url != null && url.trim().isNotEmpty) await _openUrl(url.trim());
  }

  Future<void> _openLibrary(String name, {String? url}) async {
    final e = _engine;
    if (e == null) return;
    final path = await _run('Opening $name', (_) => e.libraryPath(name));
    if (path == null) return;
    await _show(_Source(_Kind.library, name, path, url: url));
  }

  Future<void> _keep() async {
    final e = _engine;
    final s = _source;
    if (e == null || s == null || s.kind != _Kind.file) return;
    final entry = await _run(
      'Keeping ${s.name}',
      (_) => e.keep(s.path, s.name, onProgress: _onProgress),
    );
    if (entry == null) return;
    await e.persistLibrary().catchError((Object _) => false);
    await _loadLibrary();
    _snack('${entry.name} is in the library of this browser.');
  }

  Future<void> _remove(ZxLibraryEntry entry) async {
    final e = _engine;
    if (e == null) return;
    if (_source?.kind == _Kind.library && _source?.name == entry.name) {
      await _close();
    }
    await _run('Removing', (_) => e.removeFromLibrary(entry.name));
    await _loadLibrary();
  }

  // ---- levels

  Future<bool> _openNested(ZxItem item) async {
    final m = _model;
    if (m == null) return false;
    final format = await m.archive.probeNested(item);
    if (format == null) return false;
    final a = await m.archive.openNested(item);
    if (!mounted) {
      await a.close();
      return true;
    }
    setState(() => _model = ArchiveModel(a, parent: m, entry: item));
    return true;
  }

  Future<void> _toLevel(ArchiveModel level, String dir) async {
    var m = _model;
    while (m != null && m != level) {
      final p = m.parent;
      await m.closeHandles();
      m = p;
    }
    if (m == null) return;
    m.navigate(dir);
    setState(() => _model = m);
  }

  // ---- layout

  Widget _sidebar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final e = _engine;
    final title = Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: cs.onSurfaceVariant);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Library', style: title),
        ),
        if (e != null && !e.hasLibrary)
          const ListTile(
            dense: true,
            title: Text('This browser has no storage for archives.'),
          )
        else if (_library.isEmpty)
          const ListTile(
            dense: true,
            title: Text('No archives kept yet'),
            subtitle: Text('Open a file, then Keep in library.'),
          ),
        for (final l in _library)
          ListTile(
            key: Key('lib:${l.name}'),
            dense: true,
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(formatBytes(l.size)),
            selected: _source?.kind == _Kind.library && _source?.name == l.name,
            onTap: () => _openLibrary(l.name),
            trailing: IconButton(
              tooltip: 'Remove from the library',
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              onPressed: () => _remove(l),
            ),
          ),
        if (_usage case final u? when u.usage != null && u.quota != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              '${formatBytes(u.usage)} of ${formatBytes(u.quota)} used'
              '${u.persisted ? '' : ' (the browser may clear it when space runs low)'}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        if (_recent.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Addresses', style: title),
          ),
          for (final u in _recent)
            ListTile(
              dense: true,
              leading: const Icon(Icons.link_rounded),
              title: Text(
                Uri.tryParse(u)?.pathSegments.lastOrNull ?? u,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                Uri.tryParse(u)?.host ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _openUrl(u),
              trailing: IconButton(
                tooltip: 'Forget',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () {
                  forgetUrl(u);
                  setState(() => _recent = recentUrls());
                },
              ),
            ),
        ],
      ],
    );
  }

  Widget _welcome(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final err = _engineError;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              'This browser can not run the zx engine: it needs WebAssembly '
              'with garbage collection and module workers (Chrome or Edge '
              '119, Firefox 120, Safari 18.2 or newer).\n\n$err',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    if (_engine == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/icon/zx-256.png', width: 96, height: 96),
              const SizedBox(height: 16),
              Text(
                'Open an archive',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Drop an archive here, pick one, or give its address. '
                '7z, zip, rar, tar and its compressed forms, zpaq, .zx and '
                'the other formats of zx. The files stay on this computer: '
                'they are read by this page, not uploaded.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('web-open-files'),
                    onPressed: _pick,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Open files'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('web-open-url'),
                    onPressed: _askUrl,
                    icon: const Icon(Icons.link_rounded),
                    label: const Text('Open address'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _sourceText() {
    final s = _source;
    if (s == null) return null;
    return switch (s.kind) {
      _Kind.file => 'from this computer',
      _Kind.url => 'from ${Uri.tryParse(s.url ?? '')?.host ?? 'the web'}',
      _Kind.library => 'from the library',
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final m = _model;
    final busy = _busy;
    final body = m == null
        ? _welcome(context)
        : WebArchiveView(
            model: m,
            db: _db,
            onOpenNested: _openNested,
            onLevel: _toLevel,
            sourceText: _sourceText(),
            actions: [
              if (_source?.kind == _Kind.file && (_engine?.hasLibrary ?? false))
                TextButton.icon(
                  key: const Key('web-keep'),
                  onPressed: busy == null ? _keep : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Keep in library'),
                ),
              TextButton.icon(
                onPressed: _close,
                icon: const Icon(Icons.close_rounded),
                label: const Text('Close'),
              ),
            ],
          );
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          children: [
            Image.asset('assets/icon/zx-256.png', width: 28, height: 28),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                _source?.name ?? 'zx',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Open files',
            onPressed: _engine == null ? null : _pick,
            icon: const Icon(Icons.folder_open_rounded),
          ),
          IconButton(
            tooltip: 'Open address',
            onPressed: _engine == null ? null : _askUrl,
            icon: const Icon(Icons.link_rounded),
          ),
          const SizedBox(width: 8),
        ],
        bottom: busy == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: _progress?.fraction,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(busy, style: const TextStyle(fontSize: 12)),
                    TextButton(
                      onPressed: () => _cancel?.cancel(),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
      ),
      drawer: wide ? null : Drawer(child: SafeArea(child: _sidebar(context))),
      body: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide) ...[
                SizedBox(width: 260, child: _sidebar(context)),
                const VerticalDivider(width: 1),
              ],
              Expanded(child: body),
            ],
          ),
          if (_hover)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: cs.primary.withValues(alpha: 0.08),
                  alignment: Alignment.center,
                  child: Text(
                    'Drop to open',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(color: cs.primary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
