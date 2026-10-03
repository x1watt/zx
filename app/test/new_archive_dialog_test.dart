// The web "New archive" dialog (src/web/new_archive_dialog.dart): Auto vs
// Manual fields, the LSTM toggle (zcm level 9 only), and the wire shape
// sent to the engine. No engine or browser needed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zx_app/src/web/new_archive_dialog.dart';

void main() {
  testWidgets('Auto, balanced, is the default', (tester) async {
    NewArchiveResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed: () async {
                result = await showNewArchiveDialog(
                  context,
                  fileCount: 2,
                  totalBytes: 2048,
                  suggestedName: 'bundle',
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('web-new-ok')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.name, 'bundle.zx');
    expect(result!.solid, true);
    expect(result!.password, isNull);
    expect(result!.compression.toWire(), {'auto': true, 'speed': 'balanced'});
  });

  testWidgets('name, solid and password reach the result', (tester) async {
    NewArchiveResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed: () async {
                result = await showNewArchiveDialog(
                  context,
                  fileCount: 3,
                  totalBytes: 4096,
                  suggestedName: 'bundle',
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('3 files, 4 KiB'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('web-new-name')), 'notes');
    await tester.tap(find.byKey(const Key('web-new-solid'))); // off
    await tester.enterText(find.byKey(const Key('web-new-password')), 'secret');
    await tester.tap(find.byKey(const Key('web-new-ok')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.name, 'notes.zx');
    expect(result!.solid, false);
    expect(result!.password, 'secret');
    expect(result!.compression.toWire(), {'auto': true, 'speed': 'balanced'});
  });

  testWidgets('Manual store sends a plain chain', (tester) async {
    NewArchiveResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed: () async {
                result = await showNewArchiveDialog(
                  context,
                  fileCount: 1,
                  totalBytes: 10,
                  suggestedName: 'a',
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('web-new-mode')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('web-new-method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Store (no compression)').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web-new-lstm')), findsNothing);

    await tester.tap(find.byKey(const Key('web-new-ok')));
    await tester.pumpAndSettle();

    expect(result!.compression.toWire(), {'auto': false, 'chain': 'store'});
  });

  testWidgets('Manual zcm:9 shows LSTM, which reaches the result', (
    tester,
  ) async {
    NewArchiveResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed: () async {
                result = await showNewArchiveDialog(
                  context,
                  fileCount: 1,
                  totalBytes: 10,
                  suggestedName: 'a',
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('web-new-method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('zcm ultra (+ optional LSTM)').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web-new-lstm')), findsOneWidget);

    await tester.tap(find.byKey(const Key('web-new-lstm')));
    await tester.tap(find.byKey(const Key('web-new-ok')));
    await tester.pumpAndSettle();

    expect(result!.compression.toWire(), {
      'auto': false,
      'zcmLevel': 9,
      'zcmMemoryMiB': 0,
      'lstm': true,
    });
  });

  testWidgets('Create is disabled with no files', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed: () => showNewArchiveDialog(
                context,
                fileCount: 0,
                totalBytes: 0,
                suggestedName: 'a',
              ),
              child: const Text('open'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final ok = tester.widget<FilledButton>(find.byKey(const Key('web-new-ok')));
    expect(ok.onPressed, isNull);
  });
}
