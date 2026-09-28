// Widget tests of the .zx Compression section (Auto and Manual, the
// estimate, the warnings), its settings and the progress dialog's time
// left. The estimator is a fake: no isolate runs.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zx/zx.dart';
import 'package:zx_app/src/dialogs/add_dialogs.dart';
import 'package:zx_app/src/dialogs/progress.dart';
import 'package:zx_app/src/dialogs/zx_compression.dart';
import 'package:zx_app/src/settings.dart';
import 'package:zx_app/src/ui/settings_page.dart';

import 'helpers.dart';

/// Records the requests and answers with [make].
class FakeEstimator {
  final calls = <ZxOptions>[];
  ZxEstimate Function(ZxOptions o) make;
  FakeEstimator(this.make);

  Future<ZxEstimate> call(List<ZxSource> sources, {ZxOptions? options}) {
    final o = options ?? const ZxOptions();
    calls.add(o);
    return Future.value(make(o));
  }
}

ZxEstimate est({
  int level = 6,
  bool lstm = false,
  int threads = 2,
  int mem = 1288490189, // 1.2 GiB
  Duration time = const Duration(minutes: 3),
  List<String> warnings = const [],
  ZxCompression? pinned,
}) => ZxEstimate(
  method: 'zcm:level=$level:mem=1024',
  summary: 'zcm level $level',
  zcmLevel: level,
  lstm: lstm,
  threads: threads,
  blockSize: 16 << 20,
  files: 7,
  inputSize: 50 << 20,
  time: time,
  memoryBytes: mem,
  sizeLow: 10 << 20,
  sizeHigh: 14 << 20,
  kbPerSecond: 280,
  availableMemory: 11 << 30,
  safeMemory: 8 << 30,
  cores: 16,
  speedScale: 1,
  reason: 'test',
  warnings: warnings,
  compression: pinned,
);

void main() {
  late Directory tmp;
  late String tree;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zx_compress_');
    tree = makeTree(tmp.path);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  /// Opens the dialog; the result holds the dialog's future (a record, so
  /// that awaiting the opening does not wait for the dialog).
  Future<(Future<NewArchiveRequest?>?,)> Function() openNew(
    WidgetTester tester,
    FakeEstimator e, {
    ZxPrefs prefs = const ZxPrefs(),
  }) {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<NewArchiveRequest?>? result;
    return () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => result = showNewArchiveDialog(
                context,
                folder: tmp.path,
                sources: [tree],
                formatId: 'zx',
                defaultLevel: 5,
                picker: FakePicker(),
                zxDefaults: prefs,
                estimator: e.call,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      return (result,);
    };
  }

  testWidgets('auto: the estimate is shown and pinned for the update', (
    tester,
  ) async {
    const pinned = ZxCompression.manual(
      zcm: ZcmOptions(level: 6, memoryMiB: 1024),
      threads: 2,
      blockSize: 16 << 20,
    );
    final e = FakeEstimator((_) => est(pinned: pinned));
    final (result,) = await openNew(tester, e)();
    expect(e.calls, hasLength(1));
    expect(e.calls.single.compression?.auto, isTrue);
    expect(e.calls.single.compression?.speed, ZxAutoSpeed.max);
    expect(
      find.text('Chosen: level 6, 1.2 GiB RAM, 2 threads, ~3 minutes'),
      findsOneWidget,
    );
    expect(find.textContaining('output about 10 MiB to 14 MiB'), findsOne);
    expect(find.byKey(const Key('zx-warning')), findsNothing);

    // another preset asks again (debounced)
    // selecting the default preset again does not invalidate the estimate
    await tester.tap(find.text('Automatic best'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(e.calls, hasLength(1));

    // custom minutes: a time budget
    await tester.ensureVisible(find.text('Custom'));
    await tester.tap(find.text('Custom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(e.calls.last.compression?.timeBudget, const Duration(minutes: 10));
    expect(find.byKey(const Key('zx-minutes')), findsOneWidget);

    await tester.tap(find.byKey(const Key('new-ok')));
    // the dialog checks that the file does not exist (real I/O)
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    final r = await result;
    expect(r, isNotNull);
    // what was shown is what runs
    expect(identical(r!.options.compression, pinned), isTrue);
    expect(r.options.level, isNull);
    expect(r.options.dedup, isTrue);
  });

  testWidgets('a stale estimate is not pinned', (tester) async {
    final done = Completer<ZxEstimate>();
    var n = 0;
    final e = FakeEstimator((_) => est());
    Future<ZxEstimate> slow(List<ZxSource> s, {ZxOptions? options}) {
      n++;
      return n == 1 ? done.future : e.call(s, options: options);
    }

    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ZxCompressionSection(
              state: ZxCompressionState(const ZxPrefs()),
              sources: [tree],
              level: 5,
              onLevel: (_) {},
              estimator: slow,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Estimating...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // a change while the first estimate runs
    await tester.tap(find.text('Fast'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.textContaining('Chosen: level 6'), findsOneWidget);
    // the first answer comes late and is dropped
    done.complete(est(level: 9));
    await tester.pump();
    expect(find.textContaining('Chosen: level 9'), findsNothing);
  });

  testWidgets('manual: zcm memory, LSTM, threads and the warnings', (
    tester,
  ) async {
    final e = FakeEstimator((o) {
      final z = o.compression?.zcm;
      return est(
        level: z?.level ?? 5,
        lstm: z?.lstm ?? false,
        threads: o.compression?.threads ?? 4,
        mem: 20 << 30,
        time: const Duration(hours: 30),
        warnings: [
          'about 20 GiB of memory, more than the 8.0 GiB this machine can '
              'spare: lower the level, the memory or the threads',
          'this takes about 30 hours at ~0.5 KB/s (decompression takes as '
              'long)',
        ],
      );
    });
    final (result,) = await openNew(
      tester,
      e,
      prefs: const ZxPrefs(auto: false, method: 'zcm:6'),
    )();
    expect(find.byKey(const Key('zx-method')), findsOneWidget);
    expect(find.byKey(const Key('zx-memory')), findsOneWidget);
    expect(find.byKey(const Key('zx-level')), findsNothing);
    expect(
      find.text(
        'Safe maximum on this machine: 8.0 GiB (11 GiB available, 16 '
        'processors)',
      ),
      findsOneWidget,
    );
    // the LSTM is for level 9 only
    expect(
      tester.widget<Checkbox>(find.byKey(const Key('zx-lstm'))).onChanged,
      isNull,
    );
    expect(find.byKey(const Key('zx-warning')), findsNWidgets(2));
    expect(find.textContaining('about 30 hours at ~0.5 KB/s'), findsOneWidget);
    expect(find.textContaining('About 20 GiB of memory'), findsOneWidget);
    final warn = tester.widget<Text>(find.byKey(const Key('zx-warning')).first);
    final ctx = tester.element(find.byKey(const Key('zx-warning')).first);
    expect(warn.style?.color, Theme.of(ctx).colorScheme.error);

    // level 9 (cmix) with the LSTM
    await tester.tap(find.byKey(const Key('zx-method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('zcm level 9 (cmix)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('zx-lstm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('zx-lstm-cells')), findsOneWidget);
    await tester.tap(find.byKey(const Key('zx-threads')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final last = e.calls.last.compression!;
    expect(last.auto, isFalse);
    expect(last.zcm?.level, 9);
    expect(last.zcm?.lstm, isTrue);
    expect(last.threads, 2);
    expect(find.textContaining('Estimate: level 9 + LSTM'), findsOneWidget);

    // other methods: the level dropdown, no zcm settings
    await tester.tap(find.byKey(const Key('zx-method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LZMA2').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('zx-level')), findsOneWidget);
    expect(find.byKey(const Key('zx-memory')), findsNothing);
    expect(e.calls.last.compression?.chain, 'LZMA2');
    expect(e.calls.last.level, 5);

    // deduplication: on by default, off reaches ZxOptions
    final dd = find.byKey(const Key('zx-dedup'));
    expect(tester.widget<CheckboxListTile>(dd).value, isTrue);
    await tester.ensureVisible(dd);
    await tester.pumpAndSettle();
    await tester.tap(dd);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(e.calls.last.dedup, isFalse);

    await tester.tap(find.byKey(const Key('new-ok')));
    // the dialog checks that the file does not exist (real I/O)
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    final r = await result;
    expect(r!.options.dedup, isFalse);
    expect(r.options.compression?.toSwitches(), {'0': 'LZMA2', 'mt': '2'});
    expect(r.options.level, 5);
  });

  testWidgets('the dialog defaults come from the settings', (tester) async {
    final e = FakeEstimator((_) => est());
    await openNew(tester, e, prefs: const ZxPrefs(speed: 'fast'))();
    expect(e.calls.single.compression?.speed, ZxAutoSpeed.fast);
    final seg = tester.widget<SegmentedButton<String>>(
      find.byKey(const Key('zx-speed')),
    );
    expect(seg.selected, {'fast'});
  });

  testWidgets('settings page: compression defaults', (tester) async {
    final s = testServices(tmp.path, settings: Settings());
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SettingsPage(services: s)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('set-zx-speed')), findsOneWidget);
    await tester.tap(find.byKey(const Key('set-zx-speed')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom (minutes)').last);
    await tester.pumpAndSettle();
    expect(s.settings.zxCompression.speed, 'custom');
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('set-zx-dedup')))
          .value,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('set-zx-dedup')));
    await tester.pumpAndSettle();
    expect(s.settings.zxCompression.dedup, isFalse);
    expect(find.byKey(const Key('set-zx-minutes')), findsOneWidget);

    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();
    expect(s.settings.zxCompression.auto, isFalse);
    await tester.tap(find.byKey(const Key('set-zx-method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('zcm level 9 (cmix)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('set-zx-lstm')));
    await tester.pumpAndSettle();
    expect(s.settings.zxCompression.method, 'zcm:9');
    expect(s.settings.zxCompression.lstm, isTrue);
  });

  test('compression settings are saved and read back', () async {
    final f = p.join(tmp.path, 'cfg2', 'settings.json');
    final s = await Settings.load(f);
    expect(s.zxCompression.auto, isTrue);
    expect(s.zxCompression.dedup, isTrue);
    s.zxCompression = const ZxPrefs(
      auto: false,
      speed: 'custom',
      minutes: 42,
      method: 'zcm:9',
      memoryMiB: 2048,
      lstm: true,
      lstmCells: 128,
      lstmLayers: 2,
      threads: 4,
      dedup: false,
    );
    s.defaultLevel = 7;
    await s.flush();
    final r = await Settings.load(f);
    final z = r.zxCompression;
    expect(z.auto, isFalse);
    expect(z.speed, 'custom');
    expect(z.minutes, 42);
    expect(z.method, 'zcm:9');
    expect(z.memoryMiB, 2048);
    expect(z.lstm, isTrue);
    expect(z.lstmCells, 128);
    expect(z.lstmLayers, 2);
    expect(z.threads, 4);
    expect(z.dedup, isFalse);
    expect(r.defaultLevel, 7);
    // what the dialog asks for
    final c = zxCompressionOf(z);
    expect(c.zcm?.level, 9);
    expect(c.zcm?.memoryMiB, 2048);
    expect(c.zcm?.lstmCells, 128);
    expect(c.threads, 4);
    expect(
      zxCompressionOf(const ZxPrefs(speed: 'custom', minutes: 42)).timeBudget,
      const Duration(minutes: 42),
    );
  });

  test('labels and times', () {
    expect(zxMethodLabel('zcm:9'), 'zcm level 9 (cmix)');
    expect(zxMethodLabel('zcm:3'), 'zcm level 3');
    expect(approxTime(const Duration(seconds: 40)), '~40 seconds');
    expect(approxTime(const Duration(minutes: 12)), '~12 minutes');
    expect(approxTime(const Duration(minutes: 150)), '~2.5 hours');
    expect(approxTime(const Duration(hours: 336)), '~14 days');
    expect(approxTime(const Duration(milliseconds: 1200)), '~1 second');
    expect(etaText(const Duration(minutes: 12)), 'about 12 min left');
    expect(etaText(const Duration(minutes: 125)), 'about 2 h 5 min left');
    expect(etaText(const Duration(seconds: 4)), 'a few seconds left');
    expect(formatElapsed(const Duration(minutes: 3, seconds: 7)), '3:07');
  });

  testWidgets('progress: recent speed and the time left', (tester) async {
    var now = Duration.zero;
    final pr = OperationProgress('Creating x.zx', clock: () => now);
    pr.update(const ZxProgress(0, 1000 << 20));
    now = const Duration(seconds: 10);
    pr.update(const ZxProgress(100 << 20, 1000 << 20));
    // 10 MB/s so far: 900 MB left, 90 s
    expect(pr.eta, const Duration(seconds: 90));
    // it slows down: the recent window follows
    now = const Duration(seconds: 40);
    pr.update(const ZxProgress(130 << 20, 1000 << 20));
    expect(pr.speed, closeTo((30 << 20) / 30, 1));
    expect(pr.eta!.inMinutes, 870 ~/ 60);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ProgressDialog(progress: pr)),
      ),
    );
    expect(find.text('Elapsed 0:40'), findsOneWidget);
    expect(find.text('about 15 min left'), findsOneWidget);
    expect(find.byKey(const Key('progress-speed')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
