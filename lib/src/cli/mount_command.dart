// The `zx mount`, `zx umount` and `zx mounts` commands (zx extension,
// docs/mount.md): an archive as a virtual drive (Linux, FUSE).
//
//   zx mount [OPTIONS] ARCHIVE MOUNTPOINT
//   zx mount [OPTIONS] --entry NAME
//   zx umount MOUNTPOINT
//   zx mounts [list]
//   zx mounts add|remove ...      the table of persistent mounts
//   zx mounts enable-boot|disable-boot [--linger]
//
// Each mount is a process of its own (this program, serving a ZxFs, and the
// C daemon native/fuse/zx-mount), so any number of archives can be mounted
// at once. The table of persistent mounts is ~/.config/zx/mounts.conf; the
// per-user systemd unit zx-mount@NAME.service mounts an entry at login (or
// at boot, with linger).

import 'dart:async';

import '../host/io.dart';
import '../io/streams.dart' show SevenZipException;
import '../mount/fuse_bridge.dart';
import '../mount/zx_fs.dart';
import '../zx_api.dart';
import 'size_arg.dart';

const String zxMountUsage = '''
Usage: zx mount [OPTIONS] ARCHIVE MOUNTPOINT
       zx mount [OPTIONS] --entry NAME
       zx umount MOUNTPOINT
       zx mounts [list]
       zx mounts add [OPTIONS] NAME ARCHIVE MOUNTPOINT
       zx mounts remove NAME
       zx mounts enable-boot [-linger] [-exe=PROGRAM]
       zx mounts disable-boot
Mounts an archive as a virtual drive (Linux, FUSE 3). The archive is
changed through the mount when its format can be updated (.zx, 7z, zip...)
unless -ro is given: changes are collected and written as one update
(a new generation for .zx) after a few seconds without writes, on fsync
and when the drive is unmounted. Several archives can be mounted at once.
OPTIONS:
   -ro               read only
   -p{Password}      password (visible to other users; prefer -pfile)
   -pfile=FILE       read the password from FILE (mode 0600)
   -pcmd=COMMAND     the password is the output of COMMAND (run by sh)
   -version=N        .zx: mount the archive as of generation N (read only)
   -allow-other      let other users see the drive (needs user_allow_other
                     in /etc/fuse.conf)
   -cache=SIZE       read cache of extracted files (default 1g)
   -commit=SECONDS   idle seconds before a commit (default 5, 0: only on
                     fsync and unmount)
   -f                stay in the foreground (the systemd unit does)
   -persist          also add the mount to the table (name: the folder
                     name of the mount point), see "zx mounts"
   -entry=NAME       mount an entry of the table
zx mounts enable-boot installs the user unit zx-mount@.service and enables
it for every entry of the table; add -linger to start them at boot, before
you log in (loginctl enable-linger). disable-boot removes it.
The daemon is looked for in \$ZX_MOUNT_BIN, next to this program, in
native/fuse of the source tree, ~/.local/lib/zx, /usr/lib/zx and
/usr/libexec/zx.
''';

// ---------------------------------------------------------------- table

/// One entry of the table of persistent mounts.
class MountEntry {
  String name;
  String archive;
  String mountpoint;
  bool readOnly = false;
  bool allowOther = false;
  int? version;
  String? passwordFile;
  String? passwordCmd;
  int? commitSeconds;
  String? cache;

  MountEntry(this.name, this.archive, this.mountpoint);

  Map<String, String> toMap() => {
        'archive': archive,
        'mountpoint': mountpoint,
        if (readOnly) 'readonly': 'true',
        if (allowOther) 'allow_other': 'true',
        if (version != null) 'version': '$version',
        if (passwordFile != null) 'password_file': passwordFile!,
        if (passwordCmd != null) 'password_cmd': passwordCmd!,
        if (commitSeconds != null) 'commit': '$commitSeconds',
        if (cache != null) 'cache': cache!,
      };
}

String _home() => Platform.environment['HOME'] ?? '.';
String _configDir() =>
    '${Platform.environment['XDG_CONFIG_HOME'] ?? '${_home()}/.config'}/zx';
String mountTablePath() =>
    Platform.environment['ZX_MOUNTS_CONF'] ?? '${_configDir()}/mounts.conf';

final _nameRe = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$');

/// Reads the table: INI sections `[name]` with `key = value` lines.
List<MountEntry> readMountTable([String? path]) {
  final f = File(path ?? mountTablePath());
  if (!f.existsSync()) return [];
  final out = <MountEntry>[];
  MountEntry? cur;
  Map<String, String> kv = {};
  void flush() {
    final c = cur;
    if (c == null) return;
    c.archive = kv['archive'] ?? '';
    c.mountpoint = kv['mountpoint'] ?? '';
    c.readOnly = kv['readonly'] == 'true';
    c.allowOther = kv['allow_other'] == 'true';
    c.version = int.tryParse(kv['version'] ?? '');
    c.passwordFile = kv['password_file'];
    c.passwordCmd = kv['password_cmd'];
    c.commitSeconds = int.tryParse(kv['commit'] ?? '');
    c.cache = kv['cache'];
    if (c.archive.isNotEmpty && c.mountpoint.isNotEmpty) out.add(c);
  }

  for (var line in f.readAsLinesSync()) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      flush();
      cur = MountEntry(line.substring(1, line.length - 1).trim(), '', '');
      kv = {};
    } else {
      final i = line.indexOf('=');
      if (i > 0) kv[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
  }
  flush();
  return out;
}

void writeMountTable(List<MountEntry> entries, [String? path]) {
  final f = File(path ?? mountTablePath());
  f.parent.createSync(recursive: true);
  final sb = StringBuffer('# zx mounts: see "zx mounts" and docs/mount.md\n');
  for (final e in entries) {
    sb.write('\n[${e.name}]\n');
    for (final kv in e.toMap().entries) {
      sb.write('${kv.key} = ${kv.value}\n');
    }
  }
  final tmp = File('${f.path}.tmp');
  tmp.writeAsStringSync(sb.toString());
  tmp.renameSync(f.path);
}

// -------------------------------------------------------------- helpers

String _expandHome(String p) =>
    p == '~' || p.startsWith('~/') ? '${_home()}${p.substring(1)}' : p;

String _abs(String p) => File(_expandHome(p)).absolute.path;

/// The command that runs this program again: the executable, plus the
/// script when it runs under the Dart VM.
List<String> selfCommand() {
  final exe = Platform.resolvedExecutable;
  final base = exe.split('/').last;
  if (base == 'dart' || base == 'dartaotruntime') {
    return [exe, Platform.script.toFilePath()];
  }
  return [exe];
}

/// Where the FUSE daemon is, or null.
String? findDaemon() {
  final c = <String>[
    if (Platform.environment['ZX_MOUNT_BIN'] != null)
      Platform.environment['ZX_MOUNT_BIN']!,
  ];
  final self = selfCommand();
  final dir = File(self.first).parent.path;
  c.add('$dir/zx-mount');
  final script = self.length > 1 ? File(self[1]).parent.parent.path : dir;
  c.add('$script/native/fuse/zx-mount');
  c.add('${Directory.current.path}/native/fuse/zx-mount');
  c.addAll([
    '${_home()}/.local/lib/zx/zx-mount',
    '/usr/lib/zx/zx-mount',
    '/usr/libexec/zx/zx-mount',
    '/opt/zx/zx-mount',
  ]);
  for (final p in c) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

Future<String?> _which(String name) async {
  for (final d in (Platform.environment['PATH'] ?? '').split(':')) {
    if (d.isNotEmpty && File('$d/$name').existsSync()) return '$d/$name';
  }
  return null;
}

/// The mount points of zx drives, from /proc/self/mountinfo: (mountpoint,
/// fsname) pairs. The paths are unescaped (octal \040 and the like).
List<(String, String)> activeMounts() {
  final f = File('/proc/self/mountinfo');
  if (!f.existsSync()) return [];
  String unesc(String s) => s.replaceAllMapped(RegExp(r'\\([0-7]{3})'),
      (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)));
  final out = <(String, String)>[];
  for (final l in f.readAsLinesSync()) {
    final parts = l.split(' ');
    final dash = parts.indexOf('-');
    if (dash < 0 || dash + 3 >= parts.length + 0) continue;
    if (parts[dash + 1] != 'fuse.zx') continue;
    out.add((unesc(parts[4]), unesc(parts[dash + 2])));
  }
  return out;
}

bool _isMounted(String mp) {
  final real = _real(mp);
  return activeMounts().any((m) => m.$1 == real);
}

String _real(String p) {
  try {
    return Directory(p).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p;
  }
}

Future<int> _fusermount(String mp, {bool lazy = false}) async {
  for (final n in ['fusermount3', 'fusermount']) {
    final exe = await _which(n) ?? (File('/usr/bin/$n').existsSync() ? '/usr/bin/$n' : null);
    if (exe == null) continue;
    final r = await Process.run(exe, [if (lazy) '-z', '-u', mp]);
    if (r.exitCode != 0) {
      stderr.write(r.stderr);
    }
    return r.exitCode;
  }
  stderr.writeln('zx: fusermount3 not found (install the fuse3 package)');
  return 1;
}

// ---------------------------------------------------------------- mount

class _MountOpts {
  bool ro = false, allowOther = false, foreground = false, persist = false;
  String? password, passwordFile, passwordCmd, entry;
  int? version;
  int cache = 1 << 30;
  int commit = 5;
  final pos = <String>[];
}

String? _parseMountOpts(List<String> args, _MountOpts o) {
  for (final a in args) {
    if (a.startsWith('-') && a.length > 1) {
      final s = a.startsWith('--') ? a.substring(2) : a.substring(1);
      if (s == 'ro') {
        o.ro = true;
      } else if (s == 'f') {
        o.foreground = true;
      } else if (s == 'persist') {
        o.persist = true;
      } else if (s == 'allow-other') {
        o.allowOther = true;
      } else if (s.startsWith('pfile=')) {
        o.passwordFile = s.substring(6);
      } else if (s.startsWith('pcmd=')) {
        o.passwordCmd = s.substring(5);
      } else if (s.startsWith('p')) {
        o.password = s.substring(1);
      } else if (s.startsWith('version=')) {
        o.version = int.tryParse(s.substring(8));
        if (o.version == null) return 'bad version: $a';
      } else if (s.startsWith('cache=')) {
        final n = parseSizeArg(s.substring(6));
        if (n == null) return 'bad size: $a';
        o.cache = n;
      } else if (s.startsWith('commit=')) {
        final n = int.tryParse(s.substring(7));
        if (n == null || n < 0) return 'bad number: $a';
        o.commit = n;
      } else if (s.startsWith('entry=')) {
        o.entry = s.substring(6);
      } else {
        return 'unknown option: $a';
      }
    } else {
      o.pos.add(a);
    }
  }
  return null;
}

Future<String?> _readPassword(_MountOpts o) async {
  if (o.password != null) return o.password;
  final pf = o.passwordFile;
  if (pf != null) {
    final f = File(_abs(pf));
    if (!f.existsSync()) throw SevenZipException('password file not found: $pf');
    final mode = f.statSync().mode & 0x3F; // group and other bits
    if (mode != 0) {
      throw SevenZipException(
          'password file $pf must not be readable by others (chmod 600)');
    }
    return f.readAsStringSync().replaceAll(RegExp(r'[\r\n]+$'), '');
  }
  final pc = o.passwordCmd;
  if (pc != null) {
    final r = await Process.run('sh', ['-c', pc]);
    if (r.exitCode != 0) {
      throw SevenZipException('password command failed (${r.exitCode})');
    }
    return (r.stdout as String).replaceAll(RegExp(r'[\r\n]+$'), '');
  }
  return null;
}

String _workDir(String name) {
  final base = Platform.environment['XDG_CACHE_HOME'] ?? '${_home()}/.cache';
  final root = Directory('$base/zx/mount')..createSync(recursive: true);
  // folders of mounts that died without cleaning up
  for (final e in root.listSync()) {
    final n = e.path.split('/').last;
    final pid = int.tryParse(n.split('-').first);
    if (e is Directory && pid != null && !Directory('/proc/$pid').existsSync()) {
      try {
        e.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    }
  }
  return '${root.path}/$pid-$name';
}

void _applyEntry(_MountOpts o, MountEntry e) {
  o.pos
    ..clear()
    ..addAll([e.archive, e.mountpoint]);
  o.ro = o.ro || e.readOnly;
  o.allowOther = o.allowOther || e.allowOther;
  o.version ??= e.version;
  o.passwordFile ??= e.passwordFile;
  o.passwordCmd ??= e.passwordCmd;
  if (e.commitSeconds != null) o.commit = e.commitSeconds!;
  if (e.cache != null) o.cache = parseSizeArg(e.cache!) ?? o.cache;
}

String _entryName(String mountpoint) {
  final base = mountpoint.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'zx';
  final n = base.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  return _nameRe.hasMatch(n) ? n : 'zx_$n';
}

/// Runs `zx mount` with [args] (after the word "mount").
Future<int> runMountCommand(List<String> args) async {
  if (args.isEmpty || args.first == '-h' || args.first == '-help') {
    stdout.write(zxMountUsage);
    return args.isEmpty ? 1 : 0;
  }
  if (!Platform.isLinux) {
    stderr.writeln('zx mount: only Linux is supported for now');
    return 1;
  }
  final o = _MountOpts();
  final bad = _parseMountOpts(args, o);
  if (bad != null) {
    stderr.writeln('zx mount: $bad');
    return 2;
  }
  if (o.entry != null) {
    final e = readMountTable().where((e) => e.name == o.entry).firstOrNull;
    if (e == null) {
      stderr.writeln('zx mount: no entry "${o.entry}" in ${mountTablePath()}');
      return 1;
    }
    _applyEntry(o, e);
  }
  if (o.pos.length != 2) {
    stderr.write(zxMountUsage);
    return 2;
  }
  final archivePath = _abs(o.pos[0]);
  final mp = _abs(o.pos[1]);
  if (!File(archivePath).existsSync()) {
    stderr.writeln('zx mount: archive not found: $archivePath');
    return 1;
  }
  final daemon = findDaemon();
  if (daemon == null) {
    stderr.writeln('zx mount: the FUSE daemon zx-mount was not found '
        '(build it: make -C native/fuse)');
    return 1;
  }
  if (_isMounted(mp)) {
    stderr.writeln('zx mount: $mp is already a mount point in use');
    return 1;
  }
  if (!Directory(mp).existsSync()) {
    Directory(mp).createSync(recursive: true);
  } else if (Directory(mp).listSync().isNotEmpty) {
    stderr.writeln('zx mount: $mp is not empty');
    return 1;
  }
  final name = o.entry ?? _entryName(mp);

  if (o.persist) {
    final t = readMountTable();
    if (t.any((e) => e.name == name)) {
      stderr.writeln('zx mount: the table already has an entry "$name"');
      return 1;
    }
    final e = MountEntry(name, archivePath, mp)
      ..readOnly = o.ro
      ..allowOther = o.allowOther
      ..version = o.version
      ..passwordFile = o.passwordFile
      ..passwordCmd = o.passwordCmd;
    writeMountTable([...t, e]);
    stdout.writeln('added "$name" to ${mountTablePath()}');
  }

  if (!o.foreground) return _background(args, mp, o);

  // ---- foreground: this process is the server of the drive ----
  final String? pw;
  try {
    pw = await _readPassword(o);
  } on SevenZipException catch (e) {
    stderr.writeln('zx mount: ${e.message}');
    return 1;
  }
  final ZxArchive archive;
  try {
    archive = await ZxArchive.open(archivePath,
        password: pw, version: o.version, onPassword: (r) async => pw);
  } on SevenZipException catch (e) {
    stderr.writeln('zx mount: cannot open $archivePath: ${e.message}'
        '${pw == null ? ' (an encrypted archive needs -pfile=FILE)' : ''}');
    return 1;
  }
  final work = _workDir(name);
  final fs = ZxFs(
      ZxArchiveBackend(archive),
      ZxFsOptions(work,
          cacheBytes: o.cache,
          readOnly: o.ro || o.version != null,
          idleCommit: o.commit == 0 ? null : Duration(seconds: o.commit),
          uid: 0,
          gid: 0));
  final proc = await Process.start(daemon, [
    if (!fs.writable) '--ro',
    if (o.allowOther) '--allow-other',
    '--name',
    archivePath.replaceAll(',', '_'),
    mp,
  ]);
  proc.stderr.listen(stderr.add);
  void log(String s) => stderr.writeln('zx mount: $s');
  var stopping = false;
  Future<void> stop(ProcessSignal _) async {
    if (stopping) return;
    stopping = true;
    // unmounting makes the daemon tell us (destroy): we commit then
    var rc = await _fusermount(mp);
    if (rc != 0) {
      await Future<void>.delayed(const Duration(seconds: 2));
      rc = await _fusermount(mp, lazy: true);
    }
    if (rc != 0) proc.kill();
  }

  final subs = [
    ProcessSignal.sigterm.watch().listen(stop),
    ProcessSignal.sigint.watch().listen(stop),
    ProcessSignal.sighup.watch().listen(stop),
  ];
  log('$archivePath mounted on $mp${fs.writable ? '' : ' (read only)'}');
  final code = await serveFuse(fs, proc, log);
  for (final s in subs) {
    await s.cancel();
  }
  await archive.close();
  if (fs.lastCommitError != null) {
    log('the last changes could not be written: ${fs.lastCommitError}; '
        'they are kept in $work');
    return 1;
  }
  return code;
}

/// Starts the foreground server in a session of its own (setsid, output to
/// a log file) and waits until the drive is up.
Future<int> _background(List<String> args, String mp, _MountOpts o) async {
  final self = selfCommand();
  final logDir = Directory(
      '${Platform.environment['XDG_CACHE_HOME'] ?? '${_home()}/.cache'}/zx/mount')
    ..createSync(recursive: true);
  final log = File('${logDir.path}/${_entryName(mp)}.log');
  log.writeAsStringSync('');
  final a = [
    ...self,
    'mount',
    '-f',
    for (final x in args)
      if (x != '-persist' && x != '--persist') x,
  ];
  final setsid = await _which('setsid');
  final child = await Process.start(
      'sh',
      [
        '-c',
        'exec ${setsid == null ? '' : 'setsid '}"\$@" </dev/null >/dev/null 2>>"\$ZX_LOG"',
        'zx',
        ...a,
      ],
      environment: {'ZX_LOG': log.path},
      workingDirectory: Directory.current.path);
  child.stdin.close();
  child.stdout.drain<void>();
  child.stderr.drain<void>();
  var exited = false;
  int? code;
  unawaited(child.exitCode.then((c) {
    exited = true;
    code = c;
  }));
  final end = DateTime.now().add(const Duration(seconds: 180));
  while (DateTime.now().isBefore(end)) {
    if (_isMounted(mp)) {
      stdout.writeln('mounted on $mp (log: ${log.path})');
      await stdout.flush();
      // the server runs on: leave without waiting for its handles
      exit(0);
    }
    if (exited) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  stderr.write(log.readAsStringSync());
  if (!exited) {
    stderr.writeln('zx mount: timed out waiting for the mount');
    return 1;
  }
  return code == 0 ? 1 : code!;
}

/// Runs `zx umount` with [args] (after the word "umount").
Future<int> runUmountCommand(List<String> args) async {
  if (args.isEmpty || args.first == '-h' || args.first == '-help') {
    stdout.write('Usage: zx umount [-z] MOUNTPOINT|NAME\n'
        'Unmounts a drive of "zx mount" (changes are written first).\n');
    return args.isEmpty ? 1 : 0;
  }
  final lazy = args.contains('-z');
  final target = args.firstWhere((a) => !a.startsWith('-'), orElse: () => '');
  var mp = _abs(target);
  final e = readMountTable().where((e) => e.name == target).firstOrNull;
  if (e != null && !Directory(mp).existsSync()) mp = e.mountpoint;
  if (e != null && !_isMounted(mp)) mp = e.mountpoint;
  if (!_isMounted(mp)) {
    stderr.writeln('zx umount: $mp is not a zx drive');
    return 1;
  }
  return _fusermount(mp, lazy: lazy);
}

// --------------------------------------------------------------- mounts

String _unitDir() =>
    '${Platform.environment['XDG_CONFIG_HOME'] ?? '${_home()}/.config'}/systemd/user';

/// Text of the user unit template.
String systemdUnit(List<String> self) {
  String q(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  return '''
[Unit]
Description=zx archive drive %i
Documentation=file:${_home()}/.config/zx/mounts.conf

[Service]
Type=simple
ExecStart=${self.map(q).join(' ')} mount -f -entry=%i
# SIGTERM unmounts the drive, writing pending changes first
TimeoutStopSec=120
KillMode=mixed
Restart=on-failure
RestartSec=10
# a missing or locked archive is retried, not fatal for the session
SuccessExitStatus=0

[Install]
WantedBy=default.target
''';
}

Future<int> _systemctl(List<String> a) async {
  final r = await Process.run('systemctl', ['--user', ...a]);
  if (r.exitCode != 0) stderr.write(r.stderr);
  return r.exitCode;
}

/// Runs `zx mounts` with [args] (after the word "mounts").
Future<int> runMountsCommand(List<String> args) async {
  final sub = args.isEmpty ? 'list' : args.first;
  final rest = args.skip(1).toList();
  switch (sub) {
    case '-h':
    case '-help':
    case 'help':
      stdout.write(zxMountUsage);
      return 0;
    case 'list':
      final act = activeMounts();
      final table = readMountTable();
      if (act.isEmpty && table.isEmpty) {
        stdout.writeln('no zx drives mounted, no entries in ${mountTablePath()}');
        return 0;
      }
      for (final m in act) {
        final e = table.where((e) => _real(e.mountpoint) == m.$1).firstOrNull;
        stdout.writeln('mounted  ${m.$1}  <-  ${m.$2}'
            '${e == null ? '' : '  [${e.name}]'}');
      }
      for (final e in table) {
        if (!act.any((m) => m.$1 == _real(e.mountpoint))) {
          stdout.writeln('stopped  ${e.mountpoint}  <-  ${e.archive}  [${e.name}]');
        }
      }
      return 0;
    case 'add':
      final o = _MountOpts();
      final bad = _parseMountOpts(rest, o);
      if (bad != null || o.pos.length != 3) {
        stderr.writeln(bad ?? zxMountUsage);
        return 2;
      }
      final name = o.pos[0];
      if (!_nameRe.hasMatch(name)) {
        stderr.writeln('zx mounts: bad name "$name" (letters, digits, _ . -)');
        return 2;
      }
      final t = readMountTable();
      if (t.any((e) => e.name == name)) {
        stderr.writeln('zx mounts: "$name" exists already');
        return 1;
      }
      final e = MountEntry(name, _abs(o.pos[1]), _abs(o.pos[2]))
        ..readOnly = o.ro
        ..allowOther = o.allowOther
        ..version = o.version
        ..passwordFile = o.passwordFile == null ? null : _abs(o.passwordFile!)
        ..passwordCmd = o.passwordCmd;
      writeMountTable([...t, e]);
      stdout.writeln('added "$name"; mount it with: zx mount -entry=$name');
      return 0;
    case 'remove':
      if (rest.length != 1) {
        stderr.write(zxMountUsage);
        return 2;
      }
      final t = readMountTable();
      if (!t.any((e) => e.name == rest[0])) {
        stderr.writeln('zx mounts: no entry "${rest[0]}"');
        return 1;
      }
      writeMountTable([for (final e in t) if (e.name != rest[0]) e]);
      if (File('${_unitDir()}/zx-mount@.service').existsSync()) {
        await _systemctl(['disable', '--now', 'zx-mount@${rest[0]}.service']);
      }
      stdout.writeln('removed "${rest[0]}"');
      return 0;
    case 'enable-boot':
      if (await _which('systemctl') == null) {
        stderr.writeln('zx mounts: systemd (systemctl) not found');
        return 1;
      }
      final t = readMountTable();
      if (t.isEmpty) {
        stderr.writeln('zx mounts: the table is empty (zx mounts add ...)');
        return 1;
      }
      // -exe=PATH: the program the unit runs (the app starts this from its
      // own executable, which is not the command line tool)
      final exe = rest
          .where((a) => a.startsWith('-exe=') || a.startsWith('--exe='))
          .map((a) => a.substring(a.indexOf('=') + 1))
          .firstOrNull;
      final dir = Directory(_unitDir())..createSync(recursive: true);
      File('${dir.path}/zx-mount@.service')
          .writeAsStringSync(systemdUnit(exe == null ? selfCommand() : [exe]));
      var rc = await _systemctl(['daemon-reload']);
      for (final e in t) {
        rc |= await _systemctl(['enable', '--now', 'zx-mount@${e.name}.service']);
      }
      if (rest.contains('--linger') || rest.contains('-linger')) {
        final r = await Process.run('loginctl', ['enable-linger']);
        if (r.exitCode != 0) {
          stderr.write(r.stderr);
          rc |= 1;
        }
      } else {
        stdout.writeln('the drives start at login; add -linger to start them '
            'at boot');
      }
      return rc == 0 ? 0 : 1;
    case 'disable-boot':
      var rc = 0;
      for (final e in readMountTable()) {
        await _systemctl(['disable', '--now', 'zx-mount@${e.name}.service']);
      }
      final f = File('${_unitDir()}/zx-mount@.service');
      if (f.existsSync()) f.deleteSync();
      rc = await _systemctl(['daemon-reload']);
      return rc;
  }
  stderr.write(zxMountUsage);
  return 2;
}
