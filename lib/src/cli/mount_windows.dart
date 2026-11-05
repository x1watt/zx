// Windows parts of `zx mount` (docs/mount.md): where things live, the state
// files that tell which drives are up and ask a server to stop, and the
// "Run" key of the registry that starts drives at login. Plain Dart: the
// functions are used on Windows only, but compile everywhere.
//
// A running `zx mount -f` writes %LOCALAPPDATA%\zx\mount\state\KEY.state
// (line 1: pid, 2: mount point, 3: archive) and removes it when it ends.
// `zx umount` creates KEY.stop; the server sees it, writes the pending
// changes, stops the daemon (which unmounts the drive) and removes both.

import 'dart:async';

import '../host/io.dart';

String winEnv(String name, String fallback) =>
    Platform.environment[name] ?? fallback;

/// For tests: where mountLocalDir is.
String? mountLocalDirOverride;

/// %LOCALAPPDATA%\zx\mount (cache, logs, state); on other systems under
/// the home folder, so tests can use it.
String mountLocalDir() {
  final over =
      mountLocalDirOverride ?? Platform.environment['ZX_MOUNT_LOCAL_DIR'];
  if (over != null) return over.replaceAll('\\', '/');
  final base = Platform.isWindows
      ? winEnv('LOCALAPPDATA', '${winEnv('USERPROFILE', '.')}\\AppData\\Local')
      : '${winEnv('HOME', '.')}/.local/share';
  return '$base/zx/mount'.replaceAll('\\', '/');
}

String mountStateDir() => '${mountLocalDir()}/state';

/// "Z:", "z:\" and "Z:/" are the drive Z.
final RegExp _driveRe = RegExp(r'^([A-Za-z]):[\\/]?$');

bool isDriveLetter(String mp) => _driveRe.hasMatch(mp);

/// The mount point as the drive tests want it ("Z:" upper case).
String normalizeMountPoint(String mp) {
  final m = _driveRe.firstMatch(mp);
  return m == null ? mp : '${m[1]!.toUpperCase()}:';
}

/// A file name for a mount point ("Z:" gives "Z_").
String mountKey(String mp) =>
    normalizeMountPoint(mp).replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

/// Whether the file system is there (the drive, or the folder WinFsp made).
bool mountIsUp(String mp) {
  final n = normalizeMountPoint(mp);
  return isDriveLetter(n)
      ? Directory('$n\\').existsSync()
      : Directory(n).existsSync();
}

class MountState {
  final int pid;
  final String mountpoint;
  final String archive;
  const MountState(this.pid, this.mountpoint, this.archive);
}

File _stateFile(String mp) => File('${mountStateDir()}/${mountKey(mp)}.state');
File _stopFile(String mp) => File('${mountStateDir()}/${mountKey(mp)}.stop');

void writeMountState(String mp, String archive) {
  final f = _stateFile(mp);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('$pid\n${normalizeMountPoint(mp)}\n$archive\n');
  final s = _stopFile(mp);
  if (s.existsSync()) s.deleteSync();
}

void removeMountState(String mp) {
  for (final f in [_stateFile(mp), _stopFile(mp)]) {
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // ignore
    }
  }
}

MountState? readMountState(String mp) {
  final f = _stateFile(mp);
  if (!f.existsSync()) return null;
  final l = f.readAsLinesSync();
  if (l.length < 3) return null;
  return MountState(int.tryParse(l[0]) ?? 0, l[1], l[2]);
}

/// The servers that have a state file.
List<MountState> readMountStates() {
  final d = Directory(mountStateDir());
  if (!d.existsSync()) return [];
  final out = <MountState>[];
  for (final e in d.listSync()) {
    if (e is File && e.path.endsWith('.state')) {
      final l = e.readAsLinesSync();
      if (l.length >= 3) {
        out.add(MountState(int.tryParse(l[0]) ?? 0, l[1], l[2]));
      }
    }
  }
  return out;
}

/// Calls [onStop] (once) when `zx umount` asks the server of [mp] to stop.
Timer watchStopRequest(String mp, void Function() onStop) {
  late Timer t;
  t = Timer.periodic(const Duration(milliseconds: 500), (_) {
    if (_stopFile(mp).existsSync()) {
      t.cancel();
      onStop();
    }
  });
  return t;
}

/// Asks the server of [mp] to stop and waits until it has (its state file is
/// gone). 0 when it did, 1 on timeout.
Future<int> requestStop(String mp,
    {Duration timeout = const Duration(seconds: 120)}) async {
  final s = _stopFile(mp);
  s.parent.createSync(recursive: true);
  s.writeAsStringSync('stop\n');
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (!_stateFile(mp).existsSync()) return 0;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  try {
    s.deleteSync();
  } on FileSystemException {
    // ignore
  }
  return 1;
}

// ------------------------------------------------------------- registry

const String runKeyPath = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

String runValueName(String entry) => 'zx-mount-$entry';

/// The command line of the Run value: the program and `mount -entry=NAME`.
String runCommandLine(List<String> self, String entry) {
  String q(String s) => '"$s"';
  return '${self.map(q).join(' ')} mount -entry=$entry';
}

Future<bool> regAddRun(String entry, String command) async {
  final r = await Process.run('reg', [
    'add',
    runKeyPath,
    '/v',
    runValueName(entry),
    '/t',
    'REG_SZ',
    '/d',
    command,
    '/f',
  ]);
  return r.exitCode == 0;
}

Future<bool> regDeleteRun(String entry) async {
  final r = await Process.run(
      'reg', ['delete', runKeyPath, '/v', runValueName(entry), '/f']);
  return r.exitCode == 0;
}

/// The entries that have a Run value.
Future<List<String>> regListRun() async {
  final r = await Process.run('reg', ['query', runKeyPath]);
  if (r.exitCode != 0) return [];
  return [
    for (final m in RegExp(r'^\s*zx-mount-(\S+)\s+REG_', multiLine: true)
        .allMatches(r.stdout as String))
      m[1]!
  ];
}
