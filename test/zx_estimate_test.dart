// Tests of ZxArchive.estimate and ZxOptions.compression (lib/src/
// zx_estimate.dart).

import 'dart:io';

import 'package:test/test.dart';
import 'package:zx/zx.dart';

void main() {
  late Directory tmp;
  late String src;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zx_estimate_');
    src = '${tmp.path}/src';
    Directory('$src/sub').createSync(recursive: true);
    final b = StringBuffer();
    for (var i = 0; i < 8000; i++) {
      b.write('line $i of the estimate test, words ${i * 7 % 13}\n');
    }
    File('$src/a.txt').writeAsStringSync(b.toString());
    File('$src/sub/b.txt').writeAsStringSync('small file\n' * 200);
    File('$src/empty').writeAsBytesSync([]);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('auto: settings, time, memory and a size range', () async {
    final e = await ZxArchive.estimate([ZxSource(src)],
        options: const ZxOptions(
            compression: ZxCompression.auto(speed: ZxAutoSpeed.fast)));
    final size = File('$src/a.txt').lengthSync() + 2200;
    expect(e.files, 3);
    expect(e.inputSize, size);
    expect(e.zcmLevel, inInclusiveRange(1, 9));
    expect(e.threads, greaterThanOrEqualTo(1));
    expect(e.memoryBytes, greaterThan(0));
    expect(e.memoryBytes, lessThanOrEqualTo(e.safeMemory));
    expect(e.sizeLow, lessThanOrEqualTo(e.sizeHigh));
    expect(e.sizeHigh, lessThan(size));
    expect(e.safeMemory, lessThanOrEqualTo(e.availableMemory));
    expect(e.speedScale, greaterThan(0));
    expect(e.summary, startsWith('zcm level ${e.zcmLevel}'));
    expect(e.method, startsWith('zcm:level=${e.zcmLevel}:mem='));
    expect(e.compression, isNotNull);
    expect(e.compression!.auto, isFalse);
    expect(e.compression!.zcm!.level, e.zcmLevel);
    expect(e.warnings, isEmpty);
  });

  test('manual: zcm settings and warnings, other methods', () async {
    final z = await ZxArchive.estimate([ZxSource(src)],
        options: const ZxOptions(
            compression: ZxCompression.manual(
                zcm: ZcmOptions(level: 9, lstm: true), threads: 1)));
    expect(z.zcmLevel, 9);
    expect(z.lstm, isTrue);
    expect(z.threads, 1);
    expect(z.time, greaterThan(Duration.zero));

    final l = await ZxArchive.estimate([ZxSource(src)],
        options: const ZxOptions(
            compression: ZxCompression.manual(chain: 'BCJ LZMA2:d=1m')));
    expect(l.zcmLevel, isNull);
    expect(l.method, 'LZMA2:d=1m');
    expect(l.compression, isNull);
    expect(l.sizeHigh, lessThan(l.inputSize));
  });

  test('switches of the settings', () {
    expect(
        const ZxCompression.auto(
                timeBudget: Duration(minutes: 10),
                memoryBudget: 1 << 30,
                calibrate: true,
                allowLstm: false,
                threads: 2)
            .toSwitches(),
        {
          '0': 'zcm:auto',
          'time': '600s',
          'mem': '${1 << 30}b',
          'cal': '',
          'lstm-': '',
          'mt': '2',
        });
    expect(const ZxCompression.auto().toSwitches(),
        {'0': 'zcm:auto', 'time': 'balanced'});
    expect(
        const ZxCompression.manual(
                zcm: ZcmOptions(level: 6, memoryMiB: 512),
                threads: 3,
                blockSize: 32 << 20)
            .toSwitches(),
        {'0': 'zcm:level=6:mem=512', 'mt': '3', 'bs': '${32 << 20}'});
    expect(const ZxCompression.manual(chain: 'BCJ  LZMA2').toSwitches(),
        {'0': 'BCJ', '1': 'LZMA2'});
  });

  test('create with auto and with the estimated settings', () async {
    const opts = ZxOptions(
        compression: ZxCompression.auto(speed: ZxAutoSpeed.fast));
    final a = await ZxArchive.create('${tmp.path}/a.zx', [ZxSource(src)],
        options: opts);
    expect(a.items.where((i) => !i.isDir).first.method, startsWith('zcm:'));
    expect((await a.test()).errors, isEmpty);

    final e = await ZxArchive.estimate([ZxSource(src)], options: opts);
    final b = await ZxArchive.create('${tmp.path}/b.zx', [ZxSource(src)],
        options: ZxOptions(compression: e.compression));
    final m = b.items.firstWhere((i) => i.path.endsWith('a.txt')).method!;
    expect(m, startsWith('zcm:${e.zcmLevel}:'));
    expect((await b.test()).errors, isEmpty);
  });
}
