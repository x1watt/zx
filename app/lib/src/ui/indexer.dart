// A low-priority filesystem indexer sharing the explorer's local .zx archive
// with thumbnail entries. Removable-drive records stay local while offline.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart' show Sha256, Tlsh, tlshDistance;

import '../platform/places.dart';
import 'format_utils.dart' show isImageName;
import 'thumbnail_cache.dart';

const _filesPrefix = 'index/v1/files/';
const _drivesPrefix = 'index/v1/drives/';
const _batchSize = 128;
const _yieldPerFile = Duration(milliseconds: 2);
const _yieldPerChunk = Duration(milliseconds: 10);
const _persistInterval = Duration(seconds: 4);
const _rootRefreshInterval = Duration(minutes: 1);
const _rescanInterval = Duration(minutes: 15);
const _categories = [
  'Documents',
  'Code',
  'Images',
  'Videos',
  'Audio',
  'Archives',
  'Other',
];

String _hex(List<int> bytes) =>
    [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();
String _digest(String text) =>
    _hex((Sha256()..update(Uint8List.fromList(utf8.encode(text)))).digest());
String _shard(String path) => _digest(path).substring(0, 3);

String _category(String path) {
  final ext = p.extension(path).toLowerCase();
  if (const {
    '.md',
    '.txt',
    '.pdf',
    '.doc',
    '.docx',
    '.odt',
    '.rtf',
    '.epub',
    '.xls',
    '.xlsx',
    '.csv',
    '.ppt',
    '.pptx',
    '.json',
    '.xml',
    '.yaml',
  }.contains(ext)) {
    return 'Documents';
  }
  if (const {
    '.dart',
    '.c',
    '.h',
    '.cc',
    '.cpp',
    '.rs',
    '.go',
    '.py',
    '.js',
    '.ts',
    '.tsx',
    '.jsx',
    '.java',
    '.kt',
    '.swift',
    '.sh',
    '.bash',
    '.html',
    '.css',
    '.scss',
    '.sql',
    '.toml',
    '.ini',
    '.gradle',
    '.lock',
    '.make',
    '.cmake',
  }.contains(ext)) {
    return 'Code';
  }
  if (const {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.tif',
    '.tiff',
    '.heic',
    '.heif',
    '.avif',
    '.svg',
    '.ico',
    '.raw',
    '.cr2',
    '.nef',
  }.contains(ext)) {
    return 'Images';
  }
  if (const {
    '.mp4',
    '.mkv',
    '.mov',
    '.avi',
    '.webm',
    '.m4v',
    '.mpeg',
    '.mpg',
    '.wmv',
    '.flv',
    '.3gp',
  }.contains(ext)) {
    return 'Videos';
  }
  if (const {
    '.mp3',
    '.wav',
    '.flac',
    '.aac',
    '.ogg',
    '.opus',
    '.m4a',
    '.wma',
  }.contains(ext)) {
    return 'Audio';
  }
  if (const {
    '.zx',
    '.zip',
    '.7z',
    '.rar',
    '.tar',
    '.gz',
    '.bz2',
    '.xz',
    '.zst',
    '.lz',
    '.lzma',
    '.lzh',
    '.arj',
    '.iso',
    '.dmg',
  }.contains(ext)) {
    return 'Archives';
  }
  return 'Other';
}

class _Record {
  final String path;
  final int size;
  final int modified;
  final String sha256;
  final String? tlsh;
  final String category;
  const _Record(
    this.path,
    this.size,
    this.modified,
    this.sha256,
    this.tlsh,
    this.category,
  );

  List<Object?> wire() => [path, size, modified, sha256, tlsh, category];
  Map<String, Object?> json() => {
    'p': path,
    's': size,
    'm': modified,
    'h': sha256,
    't': tlsh,
    'c': category,
  };
  factory _Record.fromWire(List row) => _Record(
    row[0] as String,
    row[1] as int,
    row[2] as int,
    row[3] as String,
    row[4] as String?,
    row[5] as String,
  );
  factory _Record.fromJson(Object? value) {
    if (value is! Map ||
        value['p'] is! String ||
        value['s'] is! int ||
        value['m'] is! int ||
        value['h'] is! String ||
        value['c'] is! String) {
      throw const FormatException('invalid index record');
    }
    return _Record(
      value['p'] as String,
      value['s'] as int,
      value['m'] as int,
      value['h'] as String,
      value['t'] as String?,
      value['c'] as String,
    );
  }
}

class _Drive {
  final String id;
  String path;
  String label;
  final bool removable;
  final Map<String, _Record> files = {};
  final Map<String, int> folderBytes = {};
  final Map<String, int> categoryCounts = {for (final c in _categories) c: 0};
  final Map<String, int> categoryBytes = {for (final c in _categories) c: 0};
  int directories = 0;
  int scanned = 0;
  DateTime? lastScan;
  bool online = true;
  bool scanning = false;
  _Drive(this.id, this.path, this.label, this.removable);
  int get bytes => categoryBytes.values.fold(0, (a, b) => a + b);
  int get count => categoryCounts.values.fold(0, (a, b) => a + b);
}

/// Sequential, low-priority scanner. File data is read in a worker isolate;
/// hashes and folder/category totals are stored in the thumbnails.zx archive.
class FileIndexer extends ChangeNotifier {
  final ThumbnailCache cache;
  final PlatformPlaces places;
  final String home;
  final String excludedDataPath;
  final Map<String, _Drive> _drives = {};
  final Map<String, Set<String>> _dirtyShards = {};
  final Set<String> _dirtyDrives = {};
  Future<void>? _writing;
  final Map<String, Set<String>> _shaPaths = {};
  final Map<String, Set<String>> _tlshPaths = {};
  final Queue<ThumbnailRequest> _thumbnailQueue = Queue();
  int _activeThumbnails = 0;
  Timer? _persistTimer;
  Timer? _refreshTimer;
  Timer? _notifyTimer;
  Isolate? _worker;
  Completer<void>? _scanDone;
  SendPort? _control;
  bool _running = false;
  bool _closed = false;
  Future<void>? _closeFuture;

  FileIndexer({
    required this.cache,
    required this.places,
    required this.home,
    required this.excludedDataPath,
  });

  List<IndexerDriveSummary> get drives => [
    for (final d in _drives.values)
      if (d.online)
        IndexerDriveSummary(
          id: d.id,
          path: d.path,
          label: d.label,
          removable: d.removable,
          files: d.count,
          directories: d.directories,
          bytes: d.bytes,
          categoryCounts: Map.unmodifiable(d.categoryCounts),
          categoryBytes: Map.unmodifiable(d.categoryBytes),
          scanning: d.scanning,
          scanned: d.scanned,
        ),
  ];

  /// Total indexed file bytes at [path], including nested folders.
  int? folderSize(String path) {
    final d = _driveFor(path);
    if (d == null) return null;
    return d.folderBytes[p.normalize(path)] ??
        (p.equals(path, d.path) ? d.bytes : null);
  }

  /// Paths with exactly this SHA-256 digest, updated as scans complete.
  List<String> findBySha256(String hex) =>
      List.unmodifiable(_shaPaths[hex.toLowerCase()] ?? const <String>{});

  /// Indexed files whose SHA-256 equals the digest of [path].
  List<String> duplicatePaths(String path) {
    for (final drive in _drives.values) {
      final record = drive.files[path];
      if (record != null) {
        return List.unmodifiable(
          (_shaPaths[record.sha256] ?? const <String>{}).where(
            (p) => p != path,
          ),
        );
      }
    }
    return const [];
  }

  /// Files matching the indexed size/type of [path], for exact SHA/TLSH follow-up.
  List<String> candidatesFor(String path) {
    for (final drive in _drives.values) {
      final record = drive.files[path];
      if (record == null) continue;
      final out = <String>{...(_shaPaths[record.sha256] ?? const <String>{})};
      if (record.tlsh != null) {
        for (var i = 8; i + 8 <= record.tlsh!.length; i += 8) {
          out.addAll(
            _tlshPaths[record.tlsh!.substring(i, i + 8)] ?? const <String>{},
          );
        }
      }
      out.remove(path);
      return List.unmodifiable(out);
    }
    return const [];
  }

  /// Approximate TLSH candidates, followed by exact distance ranking.
  List<({String path, int distance})> findSimilar(
    String digest, {
    int maxDistance = 100,
    int limit = 20,
  }) {
    final candidates = <String>{};
    final normalized = digest.toUpperCase();
    // Four-byte bands provide a small candidate set before exact TLSH distance.
    if (normalized.length == 72 && normalized.startsWith('T1')) {
      for (var i = 8; i + 8 <= normalized.length; i += 8) {
        candidates.addAll(
          _tlshPaths[normalized.substring(i, i + 8)] ?? const <String>{},
        );
      }
    }
    final matches = <({String path, int distance})>[];
    for (final d in _drives.values) {
      for (final record in d.files.values) {
        if (!candidates.contains(record.path) ||
            record.tlsh == null ||
            record.tlsh == digest) {
          continue;
        }
        final distance = tlshDistance(digest, record.tlsh!);
        if (distance != null && distance <= maxDistance) {
          matches.add((path: record.path, distance: distance));
        }
      }
    }
    matches.sort((a, b) => a.distance.compareTo(b.distance));
    return List.unmodifiable(matches.take(limit));
  }

  _Drive? _driveFor(String path) {
    _Drive? found;
    for (final d in _drives.values) {
      if ((p.equals(path, d.path) || p.isWithin(d.path, path)) &&
          (found == null || d.path.length > found.path.length)) {
        found = d;
      }
    }
    return found;
  }

  Future<void> start() async {
    if (_closed || _refreshTimer != null) return;
    await _refreshRoots();
    if (!_closed) {
      _refreshTimer = Timer.periodic(
        _rootRefreshInterval,
        (_) => unawaited(_refreshRoots()),
      );
    }
  }

  Future<void> _refreshRoots() async {
    if (_closed || _running) return;
    try {
      final roots = <(String, String, bool)>[(home, 'Home', false)];
      roots.addAll([
        for (final v in await places.volumes())
          if (v.removable) (v.path, v.label, true),
      ]);
      final active = <String>{};
      for (final (path, label, removable) in roots) {
        if (_closed) return;
        if (!await Directory(path).exists()) continue;
        final id = _digest(p.normalize(path));
        active.add(id);
        var drive = _drives[id];
        if (drive == null) {
          drive = _Drive(id, path, label, removable);
          _drives[id] = drive;
          await _loadDrive(drive);
        } else {
          drive
            ..path = path
            ..label = label
            ..online = true;
        }
      }
      for (final d in _drives.values) {
        if (!active.contains(d.id)) d.online = false;
      }
      _notify();
      final stale = <String>{};
      for (final id in active) {
        final lastScan = _drives[id]!.lastScan;
        if (lastScan == null ||
            DateTime.now().difference(lastScan) > _rescanInterval) {
          stale.add(id);
        }
      }
      if (!_running && stale.isNotEmpty) {
        unawaited(_scan(stale));
      }
    } on Object {
      // A later refresh retries device discovery.
    }
  }

  Future<void> _loadDrive(_Drive d) async {
    final entries = await cache.readArchiveEntries(
      '$_filesPrefix${d.id}/',
      maxEntries: 4096,
      maxEntryBytes: 32 << 20,
    );
    for (final bytes in entries.values) {
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is List) {
          for (final v in decoded) {
            _put(d, _Record.fromJson(v), dirty: false);
          }
        }
      } on Object {
        /* A damaged shard is replaced during a rescan. */
      }
    }
    final summary = await cache.readArchiveEntry('$_drivesPrefix${d.id}.json');
    if (summary != null) {
      try {
        final data = jsonDecode(utf8.decode(summary));
        if (data is Map) {
          d.directories = data['directories'] as int? ?? 0;
          final stamp = data['lastScan'];
          if (stamp is int) {
            d.lastScan = DateTime.fromMillisecondsSinceEpoch(stamp);
          }
        }
      } on Object {
        /* Rebuilt after scanning. */
      }
    }
  }

  void _addTotals(_Drive d, _Record r, int sign) {
    d.categoryCounts[r.category] = (d.categoryCounts[r.category] ?? 0) + sign;
    d.categoryBytes[r.category] =
        (d.categoryBytes[r.category] ?? 0) + sign * r.size;
    var dir = p.dirname(r.path);
    while (p.equals(d.path, dir) || p.isWithin(d.path, dir)) {
      d.folderBytes[dir] = (d.folderBytes[dir] ?? 0) + sign * r.size;
      if (p.equals(dir, d.path)) break;
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
  }

  void _put(_Drive d, _Record r, {bool dirty = true}) {
    final old = d.files[r.path];
    if (old?.sha256 == r.sha256 &&
        old?.size == r.size &&
        old?.modified == r.modified &&
        old?.tlsh == r.tlsh) {
      return;
    }
    if (old != null) {
      _addTotals(d, old, -1);
      _unindex(old);
    }
    d.files[r.path] = r;
    _addTotals(d, r, 1);
    if (r.sha256.isNotEmpty) {
      _shaPaths.putIfAbsent(r.sha256, () => {}).add(r.path);
    }
    if (r.tlsh != null) {
      for (var i = 8; i + 8 <= r.tlsh!.length; i += 8) {
        _tlshPaths
            .putIfAbsent(r.tlsh!.substring(i, i + 8), () => {})
            .add(r.path);
      }
    }
    if (dirty) {
      _dirtyShards.putIfAbsent(d.id, () => {}).add(_shard(r.path));
      _dirtyDrives.add(d.id);
    }
  }

  void _unindex(_Record r) {
    _shaPaths[r.sha256]?.remove(r.path);
    if (r.tlsh != null) {
      for (var i = 8; i + 8 <= r.tlsh!.length; i += 8) {
        _tlshPaths[r.tlsh!.substring(i, i + 8)]?.remove(r.path);
      }
    }
  }

  Future<void> _scan(Set<String> ids) async {
    if (_running || _closed) return;
    _running = true;
    final scanDone = Completer<void>();
    _scanDone = scanDone;
    final roots = [
      for (final id in ids)
        if (_drives[id] case final d?) (d.id, d.path, d.removable),
    ];
    for (final id in ids) {
      final d = _drives[id];
      if (d != null) {
        d
          ..scanning = true
          ..scanned = 0;
      }
    }
    _notify();
    final port = ReceivePort();
    final control = ReceivePort();
    final prior = <String, Map<String, List<Object?>>>{
      for (final id in ids)
        if (_drives[id] case final d?)
          d.id: {for (final e in d.files.entries) e.key: e.value.wire()},
    };
    try {
      _worker = await Isolate.spawn(
        _workerMain,
        (
          port.sendPort,
          control.sendPort,
          roots,
          prior,
          [p.normalize(excludedDataPath)],
        ),
        onExit: port.sendPort,
        onError: port.sendPort,
      );
      final done = Completer<void>();
      port.listen((m) {
        if (m == null) {
          if (!done.isCompleted) done.complete();
          return;
        }
        if (m is! List || m.isEmpty) return;
        switch (m[0]) {
          case 'control':
            _control = m[1] as SendPort;
          case 'done':
            if (!done.isCompleted) done.complete();
          case 'thumbnail':
            _queueThumbnail(m[1] as String, m[2] as int, m[3] as int);
          case 'batch':
            final id = m[1] as String;
            final d = _drives[id];
            if (d != null) {
              for (final row in m[2] as List) {
                _put(d, _Record.fromWire(row as List));
              }
              d.scanned += (m[2] as List).length;
            }
            _schedulePersist();
            _notify();
          case 'remove':
            final d = _drives[m[1] as String];
            if (d != null) {
              for (final path in (m[2] as List).cast<String>()) {
                final old = d.files.remove(path);
                if (old != null) {
                  _addTotals(d, old, -1);
                  _unindex(old);
                  _dirtyShards.putIfAbsent(d.id, () => {}).add(_shard(path));
                  _dirtyDrives.add(d.id);
                }
              }
            }
            _schedulePersist();
            _notify();
          case 'root-done':
            final d = _drives[m[1] as String];
            if (d != null) {
              d
                ..directories = m[2] as int
                ..lastScan = DateTime.now()
                ..scanning = false;
              _dirtyDrives.add(d.id);
              _schedulePersist();
            }
            _notify();
          case 'root-error':
            final d = _drives[m[1] as String];
            if (d != null) {
              d.scanning = false;
            }
        }
      });
      control.listen((m) {
        if (m == 'stop') _control = null;
      });
      await done.future;
      await _persist();
    } on Object {
      for (final id in ids) {
        final d = _drives[id];
        if (d != null) d.scanning = false;
      }
    } finally {
      _worker?.kill(priority: Isolate.immediate);
      _worker = null;
      port.close();
      control.close();
      _control = null;
      _running = false;
      if (identical(_scanDone, scanDone)) _scanDone = null;
      if (!scanDone.isCompleted) scanDone.complete();
      if (!_closed) _notify();
    }
  }

  void _queueThumbnail(String path, int size, int modified) {
    if (_closed || size <= 0 || size > 40 << 20 || !isImageName(path)) return;
    final identity = '$path\n$size\n$modified';
    _thumbnailQueue.add(
      ThumbnailRequest(
        thumbnailKey(identity),
        () => readThumbnailFile(path, size),
      ),
    );
    _drainThumbnails();
  }

  void _drainThumbnails() {
    while (!_closed && _activeThumbnails < 2 && _thumbnailQueue.isNotEmpty) {
      final request = _thumbnailQueue.removeFirst();
      _activeThumbnails++;
      unawaited(
        cache.load(request).whenComplete(() {
          _activeThumbnails--;
          _drainThumbnails();
        }),
      );
    }
  }

  void _schedulePersist() {
    if (_persistTimer != null || _closed) return;
    _persistTimer = Timer(_persistInterval, () {
      _persistTimer = null;
      unawaited(_persist());
    });
  }

  Future<void> _persist() async {
    final activeWrite = _writing;
    if (activeWrite != null) {
      await activeWrite;
      if (_dirtyShards.isEmpty && _dirtyDrives.isEmpty) return;
    }
    if (_dirtyShards.isEmpty && _dirtyDrives.isEmpty) return;
    final dirtyShards = <String, Set<String>>{
      for (final entry in _dirtyShards.entries) entry.key: {...entry.value},
    };
    final dirtyDrives = Set<String>.of(_dirtyDrives);
    final writes = <String, Uint8List>{};
    final deletes = <String>[];
    for (final e in dirtyShards.entries) {
      final d = _drives[e.key];
      if (d == null) continue;
      for (final shard in e.value) {
        final path = '$_filesPrefix${d.id}/$shard.json';
        final rows = [
          for (final r in d.files.values)
            if (_shard(r.path) == shard) r.json(),
        ];
        if (rows.isEmpty) {
          deletes.add(path);
        } else {
          writes[path] = Uint8List.fromList(utf8.encode(jsonEncode(rows)));
        }
      }
    }
    for (final id in dirtyDrives) {
      final d = _drives[id];
      if (d == null) continue;
      writes['$_drivesPrefix$id.json'] = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'root': d.path,
            'label': d.label,
            'removable': d.removable,
            'directories': d.directories,
            'lastScan': d.lastScan?.millisecondsSinceEpoch,
            'files': d.count,
            'bytes': d.bytes,
            'categories': d.categoryCounts,
            'categoryBytes': d.categoryBytes,
          }),
        ),
      );
    }
    final changedShards = <String, Set<String>>{
      for (final entry in _dirtyShards.entries) entry.key: {...entry.value},
    };
    final changedDrives = Set<String>.of(_dirtyDrives);
    _dirtyShards.clear();
    _dirtyDrives.clear();
    final write = () async {
      try {
        if (deletes.isNotEmpty) await cache.deleteArchiveEntries(deletes);
        if (writes.isNotEmpty) await cache.writeArchiveEntries(writes);
      } on Object {
        _dirtyShards.addAll(changedShards);
        _dirtyDrives.addAll(changedDrives);
      }
    }();
    _writing = write;
    try {
      await write;
    } finally {
      if (identical(_writing, write)) _writing = null;
      if (_dirtyShards.isNotEmpty || _dirtyDrives.isNotEmpty) {
        _schedulePersist();
      }
    }
  }

  void _notify() {
    if (_notifyTimer != null || _closed) return;
    _notifyTimer = Timer(const Duration(milliseconds: 300), () {
      _notifyTimer = null;
      if (!_closed) notifyListeners();
    });
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    _refreshTimer?.cancel();
    _persistTimer?.cancel();
    _notifyTimer?.cancel();
    _closed = true;
    _control?.send('stop');
    _worker?.kill(priority: Isolate.immediate);
    final scanDone = _scanDone;
    if (scanDone != null) await scanDone.future;
    _worker = null;
    _running = false;
    _thumbnailQueue.clear();
    await _persist();
    try {
      await cache.flushWrites().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      // Do not hold app shutdown open for an unavailable cache.
    }
  }
}

class IndexerDriveSummary {
  final String id, path, label;
  final bool removable, scanning;
  final int files, directories, bytes, scanned;
  final Map<String, int> categoryCounts, categoryBytes;
  const IndexerDriveSummary({
    required this.id,
    required this.path,
    required this.label,
    required this.removable,
    required this.files,
    required this.directories,
    required this.bytes,
    required this.categoryCounts,
    required this.categoryBytes,
    required this.scanning,
    required this.scanned,
  });
}

class IndexerPanel extends StatelessWidget {
  final FileIndexer indexer;
  const IndexerPanel({super.key, required this.indexer});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: indexer,
    builder: (context, _) {
      final cs = Theme.of(context).colorScheme;
      final drives = indexer.drives;
      if (drives.isEmpty) {
        return Center(
          child: Text(
            'Discovering drives…',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Indexer', style: Theme.of(context).textTheme.titleLarge),
          Text(
            'One background worker yields between files. Removable-drive data remains in the local zx archive while offline.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          for (final drive in drives) _DriveCard(drive: drive),
        ],
      );
    },
  );
}

class _DriveCard extends StatelessWidget {
  final IndexerDriveSummary drive;
  const _DriveCard({required this.drive});
  static const colors = <String, Color>{
    'Documents': Color(0xff7c9cff),
    'Code': Color(0xffb486f5),
    'Images': Color(0xff56b4a7),
    'Videos': Color(0xffec9a58),
    'Audio': Color(0xffe67e9b),
    'Archives': Color(0xffd1b458),
    'Other': Color(0xff83909d),
  };
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final categories = [
      for (final name in _categories)
        if ((drive.categoryCounts[name] ?? 0) > 0)
          (name, drive.categoryCounts[name]!, drive.categoryBytes[name] ?? 0),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final count = drive.files == 0 ? 1 : drive.files;
    return Card(
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  drive.removable ? Icons.usb_rounded : Icons.storage_rounded,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        drive.label,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        drive.path,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (drive.scanning)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            Text(
              '${drive.files} files · ${drive.directories} folders · ${formatBytes(drive.bytes)}',
            ),
            if (drive.scanning)
              Text(
                '${drive.scanned} files scanned',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 10,
                child: Row(
                  children: [
                    for (final (name, n, _) in categories)
                      Expanded(
                        flex: n,
                        child: ColoredBox(color: colors[name]!),
                      ),
                    if (categories.isEmpty)
                      const Expanded(child: ColoredBox(color: Colors.black12)),
                  ],
                ),
              ),
            ),
            Wrap(
              spacing: 10,
              children: [
                for (final (name, n, bytes) in categories)
                  Text(
                    '$name ${((n * 100) / count).toStringAsFixed(1)}% · ${formatBytes(bytes)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var value = bytes.toDouble(), unit = -1;
  do {
    value /= 1024;
    unit++;
  } while (value >= 1024 && unit < units.length - 1);
  return '${value >= 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} ${units[unit]}';
}

Future<void> _workerMain(
  (
    SendPort,
    SendPort,
    List<(String, String, bool)>,
    Map<String, Map<String, List<Object?>>>,
    List<String>,
  )
  args,
) async {
  final (out, controlOut, roots, oldByDrive, excluded) = args;
  final control = ReceivePort();
  var stop = false;
  control.listen((message) {
    if (message == 'stop') stop = true;
  });
  controlOut.send(['control', control.sendPort]);
  final blocked = excluded.map(p.normalize).toList();
  for (final (id, root, _) in roots) {
    final old = oldByDrive[id] ?? const <String, List<Object?>>{};
    final seen = <String>{};
    final stack = <String>[root];
    final batch = <List<Object?>>[];
    var directories = 0, complete = true;
    while (stack.isNotEmpty && !stop) {
      final dir = stack.removeLast();
      try {
        await for (final entity in Directory(dir).list(followLinks: false)) {
          if (stop) break;
          final path = p.normalize(entity.path);
          if (blocked.any((x) => p.equals(path, x) || p.isWithin(x, path))) {
            continue;
          }
          if (entity is Directory) {
            directories++;
            stack.add(path);
            continue;
          }
          if (entity is! File) continue;
          try {
            final stat = await entity.stat();
            if (stat.type != FileSystemEntityType.file) continue;
            final modified = stat.modified.millisecondsSinceEpoch;
            final previous = old[path];
            List<Object?> row;
            if (previous != null &&
                previous[1] == stat.size &&
                previous[2] == modified) {
              row = previous;
            } else {
              final hashes = await _hashFile(path, stat.size);
              row = [
                path,
                stat.size,
                modified,
                hashes.$1,
                hashes.$2,
                _category(path),
              ];
            }
            seen.add(path);
            if (stat.size > 0 && stat.size <= 40 << 20 && isImageName(path)) {
              out.send(['thumbnail', path, stat.size, modified]);
            }
            batch.add(row);
            if (batch.length >= _batchSize) {
              out.send(['batch', id, List<List<Object?>>.of(batch)]);
              batch.clear();
            }
            await Future<void>.delayed(_yieldPerFile);
          } on FileSystemException {
            complete = false;
          }
        }
      } on FileSystemException {
        complete = false;
      }
    }
    if (batch.isNotEmpty) out.send(['batch', id, batch]);
    if (complete && !stop) {
      final missing = [
        for (final path in old.keys)
          if (!seen.contains(path)) path,
      ];
      for (var i = 0; i < missing.length; i += _batchSize) {
        out.send(['remove', id, missing.skip(i).take(_batchSize).toList()]);
      }
      out.send(['root-done', id, directories]);
    } else {
      out.send(['root-error', id]);
    }
  }
  control.close();
  out.send(['done']);
  out.send(null);
}

Future<(String, String?)> _hashFile(String path, int size) async {
  final sha = Sha256();
  final tlsh = Tlsh();
  await for (final chunk in File(path).openRead()) {
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    sha.update(bytes);
    tlsh.update(bytes);
    await Future<void>.delayed(_yieldPerChunk);
  }
  return (_hex(sha.digest()), tlsh.digest());
}
