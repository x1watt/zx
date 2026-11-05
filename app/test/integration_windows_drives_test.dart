// The drives of `zx mount` in the Windows integration, with a fake program
// runner (no registry): the Run value query, the zx.exe it runs, the free
// drive letters.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx_app/src/integration.dart';

import 'helpers.dart';

void main() {
  late Directory tmp;
  final commands = <String>[];
  var regOut = '';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zx_win_');
    commands.clear();
    regOut = '';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  WindowsIntegration make({bool withCli = true}) {
    final cli = p.join(tmp.path, 'zx.exe');
    if (withCli) File(cli).writeAsStringSync('x');
    return WindowsIntegration(
      r'C:\Program Files\zx\zx-gui.exe',
      paths: testPaths(tmp.path),
      zxCliCandidates: [cli],
      runner: (exe, args) async {
        commands.add('$exe ${args.join(' ')}');
        return ProcessResult(0, 0, exe == 'reg' ? regOut : '', '');
      },
    );
  }

  test('needs zx.exe', () async {
    final st = await make(withCli: false).mountLoginStatus();
    expect(st.available, isFalse);
  });

  test('the Run value says whether the drives start at login', () async {
    final w = make();
    var st = await w.mountLoginStatus();
    expect(st.available, isTrue);
    expect(st.enabled, isFalse);
    regOut = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run
    OneDrive    REG_SZ    "C:\\x\\OneDrive.exe"
    zx-mount-docs    REG_SZ    "C:\\zx\\zx.exe" mount -entry=docs
''';
    st = await w.mountLoginStatus();
    expect(st.enabled, isTrue);
  });

  test('drive letters, the table and the commands', () async {
    final w = make();
    File(p.join(tmp.path, '.config', 'zx', 'mounts.conf'))
      ..createSync(recursive: true)
      ..writeAsStringSync('[docs]\narchive = D:/a/docs.zx\nmountpoint = Z:\n');
    final st = await w.mountLoginStatus();
    expect(st.drives.single.mountpoint, 'Z:');
    // on a machine without these drives they are all free; Z first
    expect(st.driveLetters.first, 'Z:');
    expect(st.driveLetters.last, 'D:');
    commands.clear();
    await w.addMountDrive('D:/a/new.zx', 'Y:');
    await w.setMountAtLogin(true);
    final cli = p.join(tmp.path, 'zx.exe');
    expect(commands.where((c) => !c.startsWith('reg')), [
      '$cli mounts add Y_ D:/a/new.zx Y:',
      '$cli mounts enable-boot -exe=$cli',
    ]);
  });
}
