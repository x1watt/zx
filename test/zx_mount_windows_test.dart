// The Windows parts of `zx mount` that need no Windows: mount point names,
// the state files between a server and `zx umount`, the Run value.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zx/src/cli/mount_windows.dart';

void main() {
  test('drive letters and keys', () {
    expect(isDriveLetter('Z:'), isTrue);
    expect(isDriveLetter(r'z:\'), isTrue);
    expect(isDriveLetter('Z:/x'), isFalse);
    expect(isDriveLetter('/mnt/x'), isFalse);
    expect(normalizeMountPoint('z:'), 'Z:');
    expect(normalizeMountPoint(r'z:\'), 'Z:');
    expect(normalizeMountPoint(r'C:\mnt\docs'), r'C:\mnt\docs');
    expect(mountKey('z:'), 'Z_');
    expect(mountKey('C:/mnt/docs'), 'C__mnt_docs');
  });

  test('the Run value', () {
    expect(runValueName('docs'), 'zx-mount-docs');
    expect(runCommandLine([r'C:\Program Files\zx\zx.exe'], 'docs'),
        r'"C:\Program Files\zx\zx.exe" mount -entry=docs');
  });

  test('state files: write, read, stop request', () async {
    final tmp = Directory.systemTemp.createTempSync('zxwin_');
    try {
      mountLocalDirOverride = tmp.path;
      writeMountState('Z:', r'C:\a\b.zx');
      final st = readMountState('z:')!;
      expect(st.mountpoint, 'Z:');
      expect(st.archive, r'C:\a\b.zx');
      expect(st.pid, pid);
      expect(readMountStates().map((s) => s.mountpoint), contains('Z:'));

      // a server that stops when asked
      final stopped = Completer<void>();
      final w = watchStopRequest('Z:', () {
        removeMountState('Z:');
        stopped.complete();
      });
      expect(await requestStop('Z:', timeout: const Duration(seconds: 10)), 0);
      await stopped.future;
      w.cancel();
      expect(readMountState('Z:'), isNull);

      // nobody answers: a timeout
      writeMountState('Y:', 'x');
      expect(
          await requestStop('Y:', timeout: const Duration(milliseconds: 400)),
          1);
      removeMountState('Y:');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
