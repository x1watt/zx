// Tests of the zx switches around zcm (lib/src/cli/zx_zcm_auto.dart):
// -m0=zcm:auto, -mtime, -mmem, -mlstm, -mcal, named -mx levels, and the
// printout of the chosen settings.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/main.dart';
import 'package:zx/src/cli/zx_zcm_auto.dart';
import 'package:zx/src/codec/zcm/zcm.dart';
import 'package:zx/src/codec/zcm/zcm_auto.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/zx/zx_codecs.dart';
import 'package:zx/src/format/zx/zx_writer.dart'
    show zxWorkerMemory, zxWorkersFor;

class _Run {
  final int code;
  final String out;
  final String err;
  _Run(this.code, this.out, this.err);
}

Future<_Run> _run(Directory dir, List<String> args) async {
  final out = BytesBuilder();
  final err = BytesBuilder();
  final code = await runSevenZipCli(args,
      stdout: out.add, stderr: err.add, workingDirectory: dir.path);
  return _Run(code, utf8.decode(out.takeBytes(), allowMalformed: true),
      utf8.decode(err.takeBytes(), allowMalformed: true));
}

List<MapEntry<String, PropVariant>> _props(Map<String, String> m) => [
      for (final e in m.entries) convertCliProperty(e.key, e.value),
    ];

String? _method(ZxZcmPrepared r, [String key = '0']) {
  for (final p in r.props) {
    if (p.key == key) return p.value.stringValue;
  }
  return null;
}

// 16 cores, 8 GiB available: zcmUsableBytes gives 6 GiB
const _machine = ZcmMachine(availableBytes: 8 << 30, cores: 16);

void main() {
  group('values', () {
    test('durations', () {
      expect(zxParseDuration('90'), 90);
      expect(zxParseDuration('90s'), 90);
      expect(zxParseDuration('10m'), 600);
      expect(zxParseDuration('2h'), 7200);
      expect(zxParseDuration('1h30m'), 5400);
      expect(zxParseDuration('1.5h'), 5400);
      expect(zxParseDuration('1d'), 86400);
      expect(zxParseDuration('abc'), isNull);
      expect(zxParseDuration('10x'), isNull);
      expect(zxParseDuration(''), isNull);
    });

    test('memory sizes', () {
      expect(zxParseMemSize('512'), 512 << 20);
      expect(zxParseMemSize('512m'), 512 << 20);
      expect(zxParseMemSize('2g'), 2 << 30);
      expect(zxParseMemSize('1.5g'), 3 << 29);
      expect(zxParseMemSize('2GiB'), 2 << 30);
      expect(zxParseMemSize('4096b'), 4096);
      expect(zxParseMemSize('lots'), isNull);
    });

    test('level names', () {
      expect(zxLevelByName('ultra', zcm: true), 8);
      expect(zxLevelByName('cmix', zcm: true), 9);
      expect(zxLevelByName('fast', zcm: true), 2);
      expect(zxLevelByName('fastest', zcm: true), 1);
      expect(zxLevelByName('ultra', zcm: false), 9);
      expect(zxLevelByName('fast', zcm: false), 3);
      expect(zxLevelByName('store', zcm: false), 0);
      expect(zxLevelByName('bogus', zcm: false), isNull);
    });

    test('formatting', () {
      expect(zxFormatBytes(3 << 29), '1.5 GiB');
      expect(zxFormatBytes(300 << 20), '300 MiB');
      expect(zxFormatSeconds(42), '42 s');
      expect(zxFormatSeconds(180), '3 min');
      expect(zxFormatSeconds(4800), '1 h 20 min');
      expect(zxFormatSeconds(26 * 3600), '26 h');
    });
  });

  group('switch parsing', () {
    test('zcm:auto becomes a placeholder and a request', () {
      final r = zxPrepareZcmProperties(
          _props({'0': 'zcm:auto:nodetect', 'time': '10m', 'mem': '1g'}));
      expect(_method(r), 'zcm:nodetect');
      expect(r.props.map((p) => p.key), isNot(contains('time')));
      expect(r.props.map((p) => p.key), isNot(contains('mem')));
      final q = r.auto!;
      expect(q.methodKey, '0');
      expect(q.timeBudgetSeconds, 600);
      expect(q.memoryBudget, 1 << 30);
      expect(q.extraParams, 'nodetect');
    });

    test('-mtime alone means zcm:auto; presets', () {
      final r = zxPrepareZcmProperties(_props({'time': 'max', 'cal': ''}));
      expect(_method(r), 'zcm');
      expect(r.auto!.speed, ZxAutoSpeed.max);
      expect(r.auto!.timeBudgetSeconds, isNull);
      expect(r.auto!.calibrate, isTrue);
      final c = zxPrepareZcmProperties(_props({'cal': ''}));
      expect(c.auto!.speed, ZxAutoSpeed.balanced);
    });

    test('-mtime with another method is an error', () {
      expect(() => zxPrepareZcmProperties(_props({'0': 'LZMA2', 'time': '1m'})),
          throwsA(isA<InvalidArgException>()));
      expect(() => zxPrepareZcmProperties(_props({'time': 'soon'})),
          throwsA(isA<InvalidArgException>()));
    });

    test('-mmem and -mlstm go to a zcm level', () {
      final r = zxPrepareZcmProperties(
          _props({'0': 'zcm:9', 'mem': '2g', 'lstm': '32/2/15'}));
      expect(_method(r), 'zcm:9:mem=2048:lstm=32/2/15');
      expect(r.auto, isNull);
      final n = zxPrepareZcmProperties(_props({'0': 'zcm', 'lstm-': ''}));
      expect(_method(n), 'zcm:nolstm');
      expect(() => zxPrepareZcmProperties(_props({'0': 'LZMA2', 'mem': '1g'})),
          throwsA(isA<InvalidArgException>()));
      expect(() => zxPrepareZcmProperties(_props({'0': 'zcm', 'mem': 'x'})),
          throwsA(isA<InvalidArgException>()));
    });

    test('-mlstm with auto sizes the LSTM; -mlstm- excludes it', () {
      final r = zxPrepareZcmProperties(
          _props({'0': 'zcm:auto', 'lstm': '128/1/30'}));
      expect(r.auto!.lstm, isTrue);
      expect(r.auto!.lstmCells, 128);
      expect(r.auto!.lstmHorizon, 30);
      final n = zxPrepareZcmProperties(_props({'0': 'zcm:auto', 'lstm-': ''}));
      expect(n.auto!.lstm, isFalse);
    });

    test('named -mx levels follow the method', () {
      int level(Map<String, String> m) => zxPrepareZcmProperties(_props(m))
          .props
          .firstWhere((p) => p.key == 'x')
          .value
          .intValue;
      expect(level({'x': 'ultra', '0': 'zcm'}), 8);
      expect(level({'x': 'cmix', '0': 'zcm'}), 9);
      expect(level({'x': 'ultra'}), 9);
      expect(level({'x': 'fast', '0': 'LZMA2'}), 3);
      expect(() => zxPrepareZcmProperties(_props({'x': 'huge'})),
          throwsA(isA<InvalidArgException>()));
    });

    test('-mmt and -mbs are kept and bound the choice', () {
      final r = zxPrepareZcmProperties(
          _props({'0': 'zcm:auto', 'mt': '2', 'bs': '8m'}));
      expect(r.auto!.threads, 2);
      expect(r.auto!.blockSize, 8 << 20);
      expect(r.props.map((p) => p.key), containsAll(['mt', 'bs']));
    });
  });

  group('plan', () {
    test('fits the time and memory budgets', () {
      const size = 100 << 20;
      final p = zxPlanZcm(size,
          timeBudgetSeconds: 600, speedScale: 1.0, machine: _machine);
      expect(p.seconds, lessThanOrEqualTo(600));
      expect(p.bytes, lessThanOrEqualTo(zcmUsableBytes(_machine)));
      expect(p.threads, inInclusiveRange(1, 8));
      expect(p.blockSize, inInclusiveRange(1 << 20, 64 << 20));
      expect(p.options.segmentSize, 0);
      expect(p.method, startsWith('zcm:level=${p.level}:mem='));
      expect(p.summary,
          matches(RegExp(r'^zcm level \d( \+ LSTM)?, [\d.]+ [KMG]iB, '
              r'\d+ threads?, estimated .+$')));
      // a smaller budget never gives a stronger level
      final q = zxPlanZcm(size,
          timeBudgetSeconds: 60, speedScale: 1.0, machine: _machine);
      expect(q.level, lessThanOrEqualTo(p.level));

      final small = zxPlanZcm(size,
          timeBudgetSeconds: 3600,
          memoryBudget: 256 << 20,
          speedScale: 1.0,
          machine: _machine);
      expect(small.bytes, lessThanOrEqualTo(256 << 20));
      expect(small.budgetBytes, 256 << 20);
    });

    test('uses the estimate of the .zx memory guard', () {
      const size = 300 << 20;
      final p = zxPlanZcm(size,
          timeBudgetSeconds: 1800,
          memoryLimit: 1 << 30,
          speedScale: 1.0,
          machine: _machine);
      expect(p.guardBytes, 1 << 30);
      expect(p.bytes, lessThanOrEqualTo(1 << 30));
      final per = zxWorkerMemory([
        ZxCoderSpec(zcmCodecId,
            ZxCoderConfig(level: p.level, params: p.method.substring(4)))
      ], p.blockSize);
      expect(p.bytes, per * p.threads);
      expect(zxWorkersFor(p.threads, per, 1 << 30), p.threads);
      final req = zxPrepareZcmProperties(_props({'0': 'zcm:auto'})).auto!;
      expect(req.properties(p).map((e) => e.key), isNot(contains('memuse')));

      // -mmem above the guard's limit raises the limit for the plan
      final big = zxPlanZcm(size,
          timeBudgetSeconds: 1800,
          memoryBudget: 2 << 30,
          memoryLimit: 256 << 20,
          speedScale: 1.0,
          machine: _machine);
      if (big.bytes > 256 << 20) {
        final mu = req.properties(big).firstWhere((e) => e.key == 'memuse');
        expect(mu.value.intValue, big.bytes);
      }
      final lim = zxPrepareZcmProperties(
          _props({'0': 'zcm:auto', 'memuse': '512m'})).auto!;
      expect(lim.memoryLimit, 512 << 20);
    });

    test('presets order the levels', () {
      const size = 50 << 20;
      final f = zxPlanZcm(size,
          speed: ZxAutoSpeed.fast, speedScale: 1.0, machine: _machine);
      final b = zxPlanZcm(size, speedScale: 1.0, machine: _machine);
      final m = zxPlanZcm(size,
          speed: ZxAutoSpeed.max, speedScale: 1.0, machine: _machine);
      expect(f.level, lessThanOrEqualTo(b.level));
      expect(b.level, lessThanOrEqualTo(m.level));
      expect(m.level, greaterThanOrEqualTo(7));
    });

    test('-mlstm- and thread caps', () {
      final p = zxPlanZcm(1 << 20,
          timeBudgetSeconds: 1e6,
          lstm: false,
          speedScale: 1.0,
          machine: _machine);
      expect(p.level, 9);
      expect(p.lstm, isFalse);
      expect(p.method, endsWith(':nolstm'));
      final one = zxPlanZcm(200 << 20,
          timeBudgetSeconds: 600,
          maxThreads: 1,
          speedScale: 1.0,
          machine: _machine);
      expect(one.threads, 1);
      expect(one.blockSize, 64 << 20);
    });

    test('warnings for memory and hours', () {
      final p = zxManualZcmPlan(
          const ZcmOptions(level: 9), 1 << 30,
          threads: 8, blockSize: 64 << 20, speedScale: 1.0,
          machine: const ZcmMachine(availableBytes: 4 << 30, cores: 16));
      expect(p.warnings.join('\n'), contains('this machine can spare'));
      expect(p.warnings.join('\n'), matches(RegExp(r'about [\d.]+ hours at ~')));
      final ok = zxManualZcmPlan(const ZcmOptions(level: 1), 1 << 20,
          speedScale: 1.0, machine: _machine);
      expect(ok.warnings, isEmpty);
    });
  });

  group('command line', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('zx_cli_zcm_');
      final src = Directory('${tmp.path}/src')..createSync();
      final words = ['alpha ', 'beta ', 'gamma ', 'delta\n', 'context '];
      final b = StringBuffer();
      for (var i = 0; i < 6000; i++) {
        b.write(words[(i * 7 + i ~/ 3) % words.length]);
      }
      File('${src.path}/a.txt').writeAsStringSync(b.toString());
      File('${src.path}/b.txt').writeAsStringSync('hello zcm\n' * 50);
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });

    test('zcm:auto prints the choice and writes explicit settings', () async {
      final r = await _run(
          tmp, ['a', '-m0=zcm:auto', '-mtime=fast', 'x.zx', 'src']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, matches(RegExp(r'zcm level \d.*, \d+ threads?, estimated ')));
      expect(r.out, isNot(contains('zcm auto:')));
      // the plan fits the memory guard: no workers cut
      expect(r.err, isNot(contains('block worker')));
      final l = await _run(tmp, ['l', '-slt', 'x.zx']);
      expect(l.out, matches(RegExp(r'Method = zcm:\d:m\d+')));
      final t = await _run(tmp, ['t', 'x.zx']);
      expect(t.code, 0);
      expect(t.out, contains('Everything is Ok'));
    });

    test('-bb1 prints the details, -mtime alone chooses zcm', () async {
      final r = await _run(
          tmp, ['a', '-bb1', '-mtime=30s', '-mmem=256m', 'y.zx', 'src']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('zcm auto: '));
      expect(r.out, contains('memory budget 256 MiB'));
      final l = await _run(tmp, ['l', '-slt', 'y.zx']);
      expect(l.out, contains('Method = zcm:'));
    });

    test('named level and manual zcm switches', () async {
      final r = await _run(
          tmp, ['a', '-mx=ultra', '-m0=zcm', '-mmem=64m', 'z.zx', 'src']);
      expect(r.code, 0, reason: r.err);
      expect(r.out, isNot(contains('estimated')));
      final l = await _run(tmp, ['l', '-slt', 'z.zx']);
      expect(l.out, contains('Method = zcm:8:'));
    });

    test('bad switches say why', () async {
      final r = await _run(tmp, ['a', '-mtime=soon', 'e.zx', 'src']);
      expect(r.code, isNot(0));
      expect(r.err, contains('-mtime needs a duration'));
      final m = await _run(
          tmp, ['a', '-m0=LZMA2', '-mtime=10m', 'e.zx', 'src']);
      expect(m.code, isNot(0));
      expect(m.err, contains('-m0=zcm:auto'));
      expect(File('${tmp.path}/e.zx').existsSync(), isFalse);
    });

    test('help lists the zx zcm switches', () async {
      final r = await _run(tmp, ['--help']);
      for (final s in ['-m0=zcm:auto', '-mtime=', '-mmem=', '-mlstm', '-mcal']) {
        expect(r.out, contains(s));
      }
    });
  });
}
