// The wire format of the web engine (lib/src/web/wire.dart): every value
// comes back as it was, through JSON text.

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/db/sql/sql_result.dart';
import 'package:zx/src/db/storage_api.dart';
import 'package:zx/src/format/zx/zx_seal_types.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/readme/readme.dart';
import 'package:zx/src/web/wire.dart';
import 'package:zx/src/zx_types.dart';

T _json<T>(Object? v) => jsonDecode(jsonEncode(v)) as T;

void main() {
  test('listing', () {
    final t = DateTime.utc(2024, 5, 6, 7, 8, 9, 10, 11);
    final l = ZxListing(
      format: 'zx',
      outerFormats: const ['gzip'],
      physicalSize: 123456789012,
      method: 'zcm',
      solid: true,
      encryptedHeaders: false,
      comment: 'c',
      errors: const ['e'],
      warnings: const [],
      volumes: const [],
      capabilities: const ZxCapabilities(canAdd: true, canEncrypt: true),
      items: [
        ZxItem(
            index: 0,
            path: 'a/b.txt',
            isDir: false,
            size: 5,
            modified: t,
            crc: 0xFFFFFFFF,
            sha256: 'ab' * 32,
            tlsh: 'T1${'0' * 70}',
            generation: 3,
            encrypted: true),
        const ZxItem(index: -1, path: 'a', isDir: true, isImplied: true),
        const ZxItem(
            index: 2,
            path: 'n',
            isDir: true,
            nestChain: [1, 4],
            nestedFormat: 'tar'),
      ],
      password: null,
      sequential: true,
      versions: [ZxVersion(1, t, 2, 0, 99)],
      numVersions: 1,
    );
    final w = _json<Map<String, Object?>>(listingToWire(l));
    // fields without a value are not sent
    expect((w['items'] as Map).containsKey('sl'), isFalse);
    final r = listingFromWire(w);
    expect(r.format, 'zx');
    expect(r.outerFormats, ['gzip']);
    expect(r.physicalSize, 123456789012);
    expect(r.capabilities.canAdd, isTrue);
    expect(r.capabilities.canDelete, isFalse);
    expect(r.capabilities.canEncrypt, isTrue);
    expect(r.sequential, isTrue);
    expect(r.versions.single.time, t);
    expect(r.items, hasLength(3));
    final a = r.items[0];
    expect([a.index, a.path, a.isDir, a.size, a.crc, a.generation],
        [0, 'a/b.txt', false, 5, 0xFFFFFFFF, 3]);
    expect(a.modified, t);
    expect(a.encrypted, isTrue);
    expect(a.sha256, 'ab' * 32);
    expect(r.items[1].isImplied, isTrue);
    expect(r.items[2].nestChain, [1, 4]);
    expect(r.items[2].nestedFormat, 'tar');
  });

  test('extract result, progress, password request', () {
    const e = ZxExtractResult(
        3, 1, 100, 0, [ZxItemError('x', SevenZipError.crc, 'bad')]);
    final r = extractResultFromWire(_json(extractResultToWire(e)));
    expect([r.files, r.dirs, r.bytes, r.skipped], [3, 1, 100, 0]);
    expect(r.errors.single.kind, SevenZipError.crc);
    expect(r.errors.single.message, 'bad');
    const q = ZxPasswordRequest('/upload/1/a.7z', ZxPasswordReason.extract,
        itemPath: 'f', retry: true, attempt: 2);
    final q2 = passwordRequestFromWire(_json(passwordRequestToWire(q)));
    expect([q2.archivePath, q2.reason, q2.itemPath, q2.retry, q2.attempt],
        [q.archivePath, q.reason, q.itemPath, q.retry, q.attempt]);
  });

  test('seals', () {
    final k = Uint8List.fromList(List.generate(32, (i) => i));
    final policy = ZxPolicy(k, maintainers: [k], seq: 2);
    final s = ZxSeal(4, 10, k, k, null, k, policy, null, k, Uint8List(64), k);
    final g = ZxGenerationSeal(4, 999, s, ZxSealState.sealed)
      ..role = 'admin'
      ..covered = true;
    final p = ZxGenerationSeal(5, 1200, null, ZxSealState.pending);
    final r = sealsFromWire(_json(sealsToWire([g, p])));
    expect(r[0].state, ZxSealState.sealed);
    expect(r[0].role, 'admin');
    expect(r[0].covered, isTrue);
    expect(r[0].seal!.signer, k);
    expect(r[0].seal!.prevRoot, isNull);
    expect(r[0].policy!.maintainers.single, k);
    expect(r[0].policy!.seq, 2);
    expect(r[1].seal, isNull);
    expect(zxSealSummary(r), zxSealSummary([g, p]));
  });

  test('sql result and parameters', () {
    final res = ZxSqlResult(
        ['a', 'b'],
        [
          [1, 'x'],
          [
            2.5,
            Uint8List.fromList([1, 2, 3])
          ],
          [null, -7]
        ],
        0,
        0,
        types: ['INTEGER', null]);
    final r = sqlResultFromWire(_json(sqlResultToWire(res)));
    expect(r.columns, ['a', 'b']);
    expect(r.rows[1][1], [1, 2, 3]);
    expect(r.rows[1][1], isA<Uint8List>());
    expect(r.rows[2], [null, -7]);
    expect(r.types, ['INTEGER', null]);
    expect(sqlParamsFromWire(_json(sqlParamsToWire([1, 'a']))), [1, 'a']);
    expect(sqlParamsFromWire(_json(sqlParamsToWire({'x': 2}))), {'x': 2});
  });

  test('errors', () {
    final a = errorFromWire(_json(
        errorToWire(const SevenZipException('m', SevenZipError.isNotArc))));
    expect(a, isA<SevenZipException>());
    expect((a as SevenZipException).kind, SevenZipError.isNotArc);
    final d = errorFromWire(
        _json(errorToWire(const ZxDbException('q', ZxDbError.syntax))));
    expect((d as ZxDbException).kind, ZxDbError.syntax);
    expect(
        errorFromWire(_json(errorToWire(StateError('s')))), isA<StateError>());
  });

  test('README documents', () {
    const md = '''# Title *em* **strong** ~~del~~ `code`

> quote with [a link](docs/a.md "t") and ![img](i.png)

1. one
2. two

- [x] done
- [ ] open

| a | b |
|:--|--:|
| 1 | 2 |

```dart
void main() {}
```

---
line  
break
''';
    final doc = parseReadme('README.md', Uint8List.fromList(utf8.encode(md)));
    final w = markdownToWire(doc);
    final back = markdownFromWire(_json(w));
    expect(jsonEncode(markdownToWire(back)), jsonEncode(w));
    expect(back.blocks.length, doc.blocks.length);
    expect(back.blocks.length, greaterThan(6));
  });
}
