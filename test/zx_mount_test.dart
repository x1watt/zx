// Integration test of `zx mount`: the real FUSE daemon (native/fuse/zx-mount,
// build it with make -C native/fuse) serving a ZxFs, used through ordinary
// file operations on the mount point. Skipped when /dev/fuse, fusermount3 or
// the daemon is missing. The file operations are asynchronous: the server
// runs on this isolate.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zx/src/cli/mount_command.dart';
import 'package:zx/src/mount/fuse_bridge.dart';
import 'package:zx/src/mount/zx_fs.dart';
import 'package:zx/zx.dart';

void main() {
  final daemon = findDaemon();
  final fusermount = ['/usr/bin/fusermount3', '/bin/fusermount3']
      .where((p) => File(p).existsSync())
      .firstOrNull;
  final skip = !Platform.isLinux ||
          !File('/dev/fuse').existsSync() ||
          fusermount == null ||
          daemon == null
      ? 'needs /dev/fuse, fusermount3 and native/fuse/zx-mount'
      : null;

  test('mount, read, write, unmount commits', () async {
    final tmp = Directory.systemTemp.createTempSync('zxmount_');
    try {
      final src = Directory('${tmp.path}/src')..createSync();
      File('${src.path}/a.txt').writeAsStringSync('hello\n');
      Directory('${src.path}/dir').createSync();
      File('${src.path}/dir/b.txt').writeAsStringSync('bee ' * 100);
      final arPath = '${tmp.path}/x.zx';
      final ar = await ZxArchive.create(
          arPath, [ZxSource('${src.path}/a.txt'), ZxSource('${src.path}/dir')]);
      final mp = Directory('${tmp.path}/mnt')..createSync();
      final fs = ZxFs(ZxArchiveBackend(ar),
          ZxFsOptions('${tmp.path}/work', idleCommit: null));
      final proc = await Process.start(daemon!, ['--name', arPath, mp.path]);
      proc.stderr.listen((_) {});
      final served = serveFuse(fs, proc, (_) {});
      // wait until it is mounted
      for (var i = 0; i < 100; i++) {
        if (activeMounts().any((m) => m.$1 == mp.resolveSymbolicLinksSync())) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await File('${mp.path}/a.txt').readAsString(), 'hello\n');
      expect((await File('${mp.path}/dir/b.txt').readAsString()).length, 400);
      expect(
          (await mp.list().map((e) => e.path.split('/').last).toList())
            ..sort(),
          ['a.txt', 'dir']);

      await File('${mp.path}/new.txt').writeAsString('abc');
      await File('${mp.path}/a.txt').writeAsString('HELLO\n');
      await File('${mp.path}/dir/b.txt').rename('${mp.path}/dir/c.txt');
      await Directory('${mp.path}/made').create();
      expect(await File('${mp.path}/new.txt').readAsString(), 'abc');
      expect(await File('${mp.path}/a.txt').readAsString(), 'HELLO\n');
      expect(await File('${mp.path}/dir/b.txt').exists(), isFalse);

      final r = await Process.run(fusermount!, ['-u', mp.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(await served, 0);

      final after = await ZxArchive.open(arPath);
      expect(after['new.txt']?.size, 3);
      expect(after['dir/c.txt']?.size, 400);
      expect(after['dir/b.txt'], isNull);
      expect(after['made']?.isDir, isTrue);
      expect(String.fromCharCodes(await after.readBytes('a.txt')), 'HELLO\n');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('the table of mounts', () {
    final tmp = Directory.systemTemp.createTempSync('zxmounts_');
    try {
      final f = '${tmp.path}/mounts.conf';
      final e = MountEntry('docs', '/a/b.zx', '/mnt/docs')
        ..readOnly = true
        ..version = 3
        ..passwordFile = '/home/u/pw';
      writeMountTable([e, MountEntry('two', '/c.7z', '/mnt/two')], f);
      final back = readMountTable(f);
      expect(back.map((e) => e.name), ['docs', 'two']);
      expect(back[0].readOnly, isTrue);
      expect(back[0].version, 3);
      expect(back[0].passwordFile, '/home/u/pw');
      expect(back[1].readOnly, isFalse);
      expect(back[1].archive, '/c.7z');
      expect(systemdUnit(['/usr/bin/zx']), contains('mount -f -entry=%i'));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
