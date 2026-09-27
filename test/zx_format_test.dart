// Tests of the .zx format (docs/zx-format.md): every codec and chain,
// solid and non solid blocks, streamed and seekable files, the
// compatibility refusals, the SHA-256 lookup table, TLSH digests,
// encryption, damaged blocks, detection and parallel coding.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/cli/main.dart';
import 'package:zx/src/crypto/sha256.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zx/zx_codecs.dart';
import 'package:zx/src/format/zx/zx_crypto.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_handler.dart';
import 'package:zx/src/format/zx/zx_reader.dart';
import 'package:zx/src/format/zx/zx_writer.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc32c.dart';
import 'package:zx/src/util/tlsh.dart';
import 'package:zx/src/util/xxhash.dart';
import 'package:zx/src/version.dart';

import 'codec_test_util.dart' show findTool, runTool;
import 'zx_test_util.dart';

Map<String, Uint8List?> _files() => {
      'dir': null,
      'dir/a.txt': textBytes(150000, 1),
      'b.bin': lcgBytes(30000, 2),
      'empty': Uint8List(0),
      'dir/c.txt': textBytes(5000, 3),
      'x86.bin': _x86Like(40000),
    };

// bytes with E8/E9 call opcodes, so that BCJ changes them
Uint8List _x86Like(int n) {
  final b = textBytes(n, 9);
  for (var i = 0; i + 5 < n; i += 37) {
    b[i] = 0xE8;
    b[i + 1] = i & 0xFF;
    b[i + 2] = (i >> 8) & 0xFF;
    b[i + 3] = 0;
    b[i + 4] = 0;
  }
  return b;
}

void _expectSame(Map<String, Uint8List?> got, Map<String, Uint8List?> want) {
  expect(got.keys.toSet(), want.keys.toSet());
  for (final e in want.entries) {
    if (e.value == null) continue;
    expect(got[e.key], isNotNull, reason: e.key);
    expect(got[e.key], e.value, reason: e.key);
  }
}

// ---------------------------------------------------------------------------
// hand made files (as another implementation would write them)

class _Hand {
  final ZxHeader header = ZxHeader()
    ..archiveId = Uint8List(16)
    ..required = ZxFeature.appendable;
  final List<Uint8List> blocks = [];
  final List<ZxBlockRef> refs = [];
  final ZxIndex index = ZxIndex();
  int _pos = 0;
  Uint8List? _head;

  void block(ZxChain chain, Uint8List payload, Uint8List plain) {
    index.chains[chain.id] = chain;
    final h = ZxBlockHeader.encode(
        ZxBlockType.data,
        chain.id,
        plain.length,
        payload.length,
        ZxCheck.crc32c,
        (Uint8List(4)
          ..buffer.asByteData().setUint32(0, Crc32c.of(plain), Endian.little)));
    blocks.add(Uint8List.fromList([...h, ...payload]));
    refs.add(
        ZxBlockRef(0, 0, h.length, payload.length, plain.length, chain.id));
  }

  Uint8List build() {
    _head = header.encode();
    _pos = _head!.length;
    final out = BytesBuilder()..add(_head!);
    final fixed = <ZxBlockRef>[];
    for (var i = 0; i < blocks.length; i++) {
      final r = refs[i];
      fixed.add(ZxBlockRef(
          0, _pos, r.headerSize, r.packedSize, r.unpackedSize, r.chainId));
      out.add(blocks[i]);
      _pos += blocks[i].length;
    }
    index.blocks = fixed;
    index.generation ??= const ZxGeneration(1, 1790000000000000000, '');
    final content = index.encode(multiVolume: false);
    final h = ZxBlockHeader.encode(ZxBlockType.index, 0, content.length,
        content.length, ZxCheck.none, Uint8List(0));
    final start = _pos;
    out.add(h);
    out.add(content);
    _pos += h.length + content.length;
    out.add(ZxFooter(start, _pos - start, fixed.length).encode());
    return out.toBytes();
  }
}

ZxEntry _fileEntry(String path, Uint8List data, int block) => ZxEntry(
    path, ZxKind.file,
    size: data.length,
    extents: Int64List.fromList(data.isEmpty ? [] : [block, 0, data.length]))
  ..sha256 = Sha256.hash(data);

Uint8List _handMade(
    int codecId, Uint8List props, Uint8List payload, Uint8List plain,
    {void Function(_Hand h)? tweak}) {
  final h = _Hand();
  h.block(ZxChain(2, [ZxCoder(codecId, props)]), payload, plain);
  h.index.entries.add(_fileEntry('f', plain, 0));
  tweak?.call(h);
  return h.build();
}

Matcher _refused(String text) => throwsA(isA<SevenZipException>()
    .having((e) => e.message, 'message', contains(text)));

void main() {
  group('codecs and chains', () {
    final files = _files();
    const chains = [
      ['store'],
      ['LZMA2'],
      ['LZMA2:d=1m:fb=64'],
      ['LZMA'],
      ['PPMd'],
      ['PPMd:o=4:mem=16m'],
      ['PPMd8'],
      ['PPMd8:o=6:mem=8m'],
      ['BZip2'],
      ['Deflate'],
      ['zpaq'],
      ['zpaq:3'],
      ['BCJ', 'LZMA2'],
      ['ARM', 'LZMA2'],
      ['ARMT', 'LZMA2'],
      ['ARM64', 'LZMA2'],
      ['PPC', 'LZMA2'],
      ['SPARC', 'LZMA2'],
      ['IA64', 'LZMA2'],
      ['RISCV', 'LZMA2'],
      ['Delta:4', 'LZMA2'],
      ['BCJ', 'Delta:2', 'Deflate'],
    ];
    for (final chain in chains) {
      test(chain.join(' '), () {
        final o = testOptions();
        if (chain.length == 1 && chain.first == 'store') {
          o.level = 0;
        } else {
          o.coders = [for (final c in chain) zxParseCoder(c, 5)];
        }
        final a = makeArchive(files, o);
        final h = openMem(a);
        _expectSame(extractAll(h), files);
        expect(testAll(h).values.every((r) => r == OperationResult.ok), true);
        final m = h.getArchiveProperty(Kpid.method) as String;
        final first = chain.first.split(':').first;
        if (first == 'store') {
          expect(m, 'store');
        } else {
          expect(m.toLowerCase(), contains(first.toLowerCase()));
        }
      });
    }

    test('the registry', () {
      for (final c in zxCodecs()) {
        expect(zxCodecByName(c.name), same(c));
        expect(c.introducedIn, (0, 5, 0));
      }
      // decode only codecs are refused for writing
      for (final n in ['zstd', 'LZ4', 'LZO1X']) {
        expect(zxCodecByName(n)!.canEncode, false);
        expect(() => zxParseCoder(n, 5), throwsA(isA<SevenZipException>()));
      }
      expect(
          () => registerZxCodec(ZxCodecInfo(
              id: ZxCodecId.lzma2, name: 'x', decode: (a, b, c) => a)),
          throwsArgumentError);
    });

    test('an experimental codec sets min_reader_version and warns', () {
      final info = ZxCodecInfo(
          id: 0x1FFF0,
          name: 'test-rev',
          introducedIn: zxVersion,
          encode: (input, cfg) => ZxEncoded(
              Uint8List.fromList(input.reversed.toList().sublist(
                  0, input.length > 10 ? input.length - 1 : input.length)),
              Uint8List(0)),
          decode: (p, props, n) => p);
      // this codec loses a byte: only its registration is tested here
      registerZxCodec(info);
      final o = testOptions()..coders = [const ZxCoderSpec(0x1FFF0)];
      final out = MemoryOutStream();
      final w = ZxWriter.create(o, (h) => ZxStreamSink(out));
      expect(o.warnings.single, contains('experimental'));
      w.finish();
      final r = ZxArchiveReader.open(
          MemoryInStream(Uint8List.fromList(out.toBytes())),
          const ZxOpenParams())!;
      expect(r.header.minReaderVersion, zxVersion);
    });

    test('decode only codecs: zstd, LZ4, LZO1X', () {
      final plain = Uint8List.fromList(utf8.encode('hello world, hello zx'));
      // LZ4 frame: one compressed block of literals
      final lz4 = BytesBuilder()..add([0x04, 0x22, 0x4D, 0x18, 0x60, 0x40]);
      final hc = _xxh32([0x60, 0x40]);
      lz4.addByte((hc >> 8) & 0xFF);
      final blk = [0xF0, plain.length - 15, ...plain];
      lz4.add([blk.length & 0xFF, 0, 0, 0, ...blk, 0, 0, 0, 0]);
      var h =
          openMem(_handMade(ZxCodecId.lz4, Uint8List(0), lz4.toBytes(), plain));
      expect(extractAll(h)['f'], plain);
      // LZO1X: literals and the end marker
      final lzo =
          Uint8List.fromList([17 + plain.length, ...plain, 0x11, 0x00, 0x00]);
      h = openMem(_handMade(ZxCodecId.lzo1x, Uint8List(0), lzo, plain));
      expect(extractAll(h)['f'], plain);
      final zstd = findTool('zstd');
      if (zstd != null) {
        final data = textBytes(200000, 5);
        final tmp = Directory.systemTemp.createTempSync('zx_zstd_');
        try {
          final f = File('${tmp.path}/in')..writeAsBytesSync(data);
          final c = runTool(zstd, ['-c', '-q', '-19', f.path]);
          h = openMem(_handMade(ZxCodecId.zstd, zxVint(27), c, data));
          expect(extractAll(h)['f'], data);
        } finally {
          tmp.deleteSync(recursive: true);
        }
      }
    });
  });

  group('structure', () {
    test('solid and non solid', () {
      final files = {
        for (var i = 0; i < 20; i++) 'f$i.txt': textBytes(3000, i)
      };
      final solid = openMem(makeArchive(files, testOptions()));
      expect(solid.getArchiveProperty(Kpid.solid), true);
      expect(solid.reader!.index.blocks.length, 1);
      final o = testOptions()..solid = false;
      final ns = openMem(makeArchive(files, o));
      expect(ns.getArchiveProperty(Kpid.solid), false);
      expect(ns.reader!.index.blocks.length, 20);
      _expectSame(extractAll(solid), files);
      _expectSame(extractAll(ns), files);
    });

    test('blocks split at the block size, extents across blocks', () {
      final big = textBytes(300000, 7);
      final files = {'a': textBytes(10000, 1), 'big': big, 'z': lcgBytes(5, 1)};
      // without dedup the blocks are filled to the block size (with it a
      // chunk is never cut by a block boundary)
      final h = openMem(makeArchive(
          files, testOptions(blockSize: 64 << 10)..dedup = false));
      final idx = h.reader!.index;
      expect(idx.blocks.length, 5);
      for (final b in idx.blocks) {
        expect(b.unpackedSize, lessThanOrEqualTo(64 << 10));
      }
      final e = idx.entries.firstWhere((e) => e.path == 'big');
      expect(e.numExtents, greaterThan(4));
      _expectSame(extractAll(h), files);
      // random access through the extents
      final s = h.getStream(idx.entries.indexOf(e))!;
      s.position = 100000;
      final part = Uint8List(70000);
      expect(readFully(s, part, 0, part.length), part.length);
      expect(part, big.sublist(100000, 170000));
    });

    test('headers: magic, records, footer', () {
      final a = makeArchive({'x': textBytes(100, 1)}, testOptions());
      expect(a.sublist(0, 8), zxMagic);
      expect(getUint32LE(a, a.length - 4), zxFooterMagic);
      final r = ZxArchiveReader.open(MemoryInStream(a), const ZxOpenParams())!;
      expect(r.header.writerName, 'zx $zxVersionString (Dart)');
      expect(r.header.required & ZxFeature.appendable, isNot(0));
      expect(r.lastIndex.generation!.number, 1);
      expect(r.lastIndex.minReaderVersion, (0, 5, 0));
      expect(r.header.optional & ZxOptFeature.hashTable, isNot(0));
    });

    test('vint and CRC-32C', () {
      for (final v in [0, 1, 127, 128, 300, 1 << 40, (1 << 62) + 5]) {
        expect(ZxRead(zxVint(v)).vint(), v);
      }
      // shortest form
      expect(zxVint(127).length, 1);
      expect(zxVint(128).length, 2);
      // longer than 10 bytes, or above 64 bits
      expect(() => ZxRead(Uint8List.fromList(List.filled(11, 0x80))).vint(),
          throwsA(isA<SevenZipException>()));
      expect(
          () => ZxRead(Uint8List.fromList([...List.filled(9, 0xFF), 0x02]))
              .vintBits(),
          throwsA(isA<SevenZipException>()));
      final z = ZxBytes()..svint(-5);
      expect(ZxRead(z.toBytes()).svint(), -5);
      // RFC 3720 B.4
      expect(Crc32c.of(Uint8List(32)), 0x8A9136AA);
      expect(Crc32c.of(Uint8List.fromList(List.filled(32, 0xFF))), 0x62A8AB43);
      expect(Crc32c.of(Uint8List.fromList(List.generate(32, (i) => i))),
          0x46DD794E);
    });
  });

  group('compatibility', () {
    final plain = Uint8List.fromList(utf8.encode('some data'));
    Uint8List stored([void Function(_Hand h)? tweak]) =>
        _handMade(ZxCodecId.store, Uint8List(0), plain, plain, tweak: tweak);

    test('a hand made file reads', () {
      expect(extractAll(openMem(stored()))['f'], plain);
    });

    test('newer format_version', () {
      expect(() => openMem(stored((h) => h.header.formatVersion = 2)),
          _refused('format version 2 is newer'));
    });

    test('newer min_reader_version', () {
      expect(
          () => openMem(stored((h) => h.header.minReaderVersion = (9, 1, 0))),
          _refused('needs zx 9.1.0 or later'));
      // the requirements of a generation (Index record 0x46)
      expect(() => openMem(stored((h) => h.index.minReaderVersion = (7, 0, 0))),
          _refused('needs zx 7.0.0 or later'));
    });

    test('unknown required feature', () {
      expect(() => openMem(stored((h) => h.header.required |= 1 << 40)),
          _refused('required feature bit 40'));
      // an unknown optional feature is ignored
      expect(
          extractAll(openMem(stored((h) => h.header.optional |= 1 << 50)))['f'],
          plain);
    });

    test('unknown critical records', () {
      expect(
          () => openMem(stored(
              (h) => h.header.otherRecords.add(ZxRecord(0x7F, Uint8List(3))))),
          _refused('critical header record 0x7F'));
      // non critical ones are skipped
      expect(
          extractAll(openMem(stored((h) =>
              h.header.otherRecords.add(ZxRecord(0x7E, Uint8List(3))))))['f'],
          plain);
      expect(
          () => openMem(
              stored((h) => h.index.other.add(ZxRecord(0x7B, Uint8List(1))))),
          _refused('critical Index record 0x7B'));
      // in an entry: that entry only is refused
      final a = stored((h) {
        final e = h.index.entries.first;
        e.other = [ZxRecord(0x99, Uint8List(2))];
        h.index.entries.add(ZxEntry('g', ZxKind.file,
            size: plain.length, extents: Int64List.fromList([0, 0, 9])));
      });
      final h = openMem(a);
      expect(h.reader!.index.entries.first.unsupported, contains('0x99'));
      final r = testAll(h);
      expect(r['f'], OperationResult.unsupportedMethod);
      expect(r['g'], OperationResult.ok);
    });

    test('unknown codec id', () {
      final a = _handMade(0x3FF, Uint8List(0), plain, plain);
      final h = openMem(a);
      expect(testAll(h)['f'], OperationResult.unsupportedMethod);
    });

    test('unknown block type outside the extents is skipped', () {
      final a = stored((h) {
        final pad = ZxBlockHeader.encode(
            ZxBlockType.padding, 0, 4, 4, ZxCheck.none, Uint8List(0));
        h.blocks.add(Uint8List.fromList([...pad, 1, 2, 3, 4]));
        h.refs.add(ZxBlockRef(0, 0, pad.length, 4, 4, 0));
      });
      expect(extractAll(openMem(a))['f'], plain);
    });
  });

  group('streamed', () {
    final files = {
      'a.txt': textBytes(90000, 1),
      'dir': null,
      'dir/b.bin': lcgBytes(20000, 2),
      'dir/empty': Uint8List(0),
      'c.txt': textBytes(150000, 3),
    };

    test('seekable and sequential reading of a streamed file', () {
      final o = testOptions()..streamed = true;
      final a = makeArchive(files, o);
      final r = ZxArchiveReader.open(MemoryInStream(a), const ZxOpenParams())!;
      expect(r.header.streamed, true);
      _expectSame(extractAll(openMem(a)), files);
      final h = ZxHandler();
      expect(h.openSeq(MemoryInStream(a)), true);
      _expectSame(extractAll(h), files);
      // the same data as the seekable file (blocks are identical)
      final plain = makeArchive(files, testOptions()..dedup = false);
      expect(a.length, greaterThan(plain.length));
    });

    test('an entry of unknown size (a pipe)', () {
      final o = testOptions()..streamed = true;
      final out = MemoryOutStream();
      final w = ZxWriter.create(o, (h) => ZxStreamSink(out));
      final d1 = textBytes(100000, 4), d2 = textBytes(3000, 5);
      w.addNew(ZxEntry('first', ZxKind.file), MemoryInStream(d1));
      w.addNew(ZxEntry('second', ZxKind.file), MemoryInStream(d2),
          knownSize: d2.length);
      w.finish();
      final a = Uint8List.fromList(out.toBytes());
      final h = ZxHandler()..openSeq(MemoryInStream(a));
      final got = extractAll(h);
      expect(got['first'], d1);
      expect(got['second'], d2);
    });

    test('a non-seekable output makes a streamed file', () {
      final out = _PipeOut();
      final h = ZxHandler();
      h.options.write
        ..threads = 1
        ..blockSize = 64 << 10;
      h.updateItems(out, 1, _OneFile('p.txt', textBytes(1000, 1)));
      final a = out.bytes();
      expect(ZxArchiveReader.readHeader(MemoryInStream(a))!.streamed, true);
      expect(extractAll(openMem(a))['p.txt'], textBytes(1000, 1));
    });
  });

  group('hashes', () {
    test('per entry SHA-256 and the sorted lookup table', () {
      final files = {
        for (var i = 0; i < 30; i++) 'f$i': textBytes(500 + i * 37, i),
        'dup1': textBytes(777, 99),
        'dup2': textBytes(777, 99),
      };
      final h = openMem(makeArchive(files, testOptions()));
      final idx = h.reader!.index;
      final t = idx.shaTable!;
      expect(t.length, files.length);
      for (var i = 1; i < t.length; i++) {
        expect(zxHex(t[i - 1].$1).compareTo(zxHex(t[i].$1)) <= 0, true);
      }
      for (final e in files.entries) {
        final sha = Sha256.hash(e.value);
        final found = h.findBySha256(sha);
        final paths = [for (final i in found) idx.entries[i].path];
        expect(paths, contains(e.key));
        expect(h.getProperty(found.first, Kpid.sha256), zxHex(sha));
      }
      expect(h.findBySha256(Sha256.hash(textBytes(777, 99))).length, 2);
      expect(h.findBySha256(Uint8List(32)), isEmpty);
    });

    test('TLSH digests and similar entries', () {
      final base = textBytes(20000, 4);
      final near = Uint8List.fromList(base);
      for (var i = 0; i < near.length; i += 500) {
        near[i] = 0x41;
      }
      final files = {
        'base': base,
        'near': near,
        'other': lcgBytes(20000, 8),
        'tiny': textBytes(20, 1),
      };
      final h = openMem(makeArchive(files, testOptions()));
      final idx = h.reader!.index;
      for (final e in idx.entries) {
        expect(e.tlsh, Tlsh.of(files[e.path]!), reason: e.path);
      }
      expect(idx.entries.firstWhere((e) => e.path == 'tiny').tlsh, isNull);
      expect(idx.tlshList!.length, 3);
      final sim = h.findSimilar(Tlsh.of(base)!, maxDistance: 60);
      final names = [for (final (i, _) in sim) idx.entries[i].path];
      expect(names.first, 'base');
      expect(names, contains('near'));
      expect(names, isNot(contains('other')));
    });
  });

  group('encryption', () {
    final files = {'secret.txt': textBytes(50000, 1), 'b': lcgBytes(9000, 2)};

    test('data encrypted, names visible', () {
      final o = testOptions()
        ..password = 'pass word'
        ..encryptMetadata = false
        ..scryptLog2N = 10;
      final a = makeArchive(files, o);
      // no plaintext in the file
      expect(_contains(a, files['secret.txt']!.sublist(0, 40)), false);
      final h = openMem(a);
      expect(h.numberOfItems, 2);
      expect(h.getProperty(0, Kpid.encrypted), true);
      // a clear Index holds no hash of the encrypted content, and the
      // blocks no check of their plaintext
      final r = h.reader!;
      expect(r.index.entries.every((e) => e.sha256 == null && e.tlsh == null),
          true);
      expect(r.index.shaTable, isNull);
      for (var i = 0; i < r.index.blocks.length; i++) {
        final raw = r.rawBlock(r.index, i);
        expect(ZxBlockHeader.tryParse(raw, 0, raw.length)!.checkType,
            ZxCheck.none);
      }
      _expectSame(extractAll(h, password: 'pass word'), files);
      final bad = openMem(a);
      final res = testAll(bad, password: 'wrong');
      expect(res.values.toSet(), {OperationResult.wrongPassword});
    });

    test('encrypted metadata: a wrong password is refused at once', () {
      final o = testOptions()
        ..password = 'pw'
        ..encryptMetadata = true
        ..scryptLog2N = 10;
      final a = makeArchive(files, o);
      expect(_contains(a, utf8.encode('secret.txt')), false);
      final sw = Stopwatch()..start();
      expect(
          () => openMem(a, password: 'nope'),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.wrongPassword)));
      expect(sw.elapsedMilliseconds, lessThan(5000));
      expect(() => openMem(a), throwsA(isA<ZxNeedPasswordException>()));
      _expectSame(
          extractAll(openMem(a, password: 'pw'), password: 'pw'), files);
    });

    test('a changed byte of an encrypted block fails its MAC', () {
      final o = testOptions()
        ..password = 'pw'
        ..scryptLog2N = 10
        ..solid = false;
      final a = makeArchive(files, o);
      final r = ZxArchiveReader.open(
          MemoryInStream(a), ZxOpenParams(password: () => 'pw'))!;
      final b = r.lastIndex.blocks.first;
      a[b.offset + b.headerSize + 20] ^= 1;
      final res = testAll(openMem(a, password: 'pw'), password: 'pw');
      expect(res['secret.txt'], OperationResult.crcError);
      expect(res['b'], OperationResult.ok);
    });

    test('scrypt and the password check', () {
      final (kdf, keys) = zxNewKdf('x', log2N: 10);
      expect(zxCheckPassword('x', kdf), isNotNull);
      expect(zxCheckPassword('y', kdf), isNull);
      expect(keys.aesKey.length, 32);
      expect(ZxKdfParams.decode(kdf.encode()).salt, kdf.salt);
    });
  });

  group('damage', () {
    final files = {
      'one': textBytes(40000, 1),
      'two': textBytes(40000, 2),
      'three': textBytes(40000, 3),
    };

    test('a damaged block fails only its entries', () {
      final o = testOptions()..solid = false;
      final a = makeArchive(files, o);
      final r = ZxArchiveReader.open(MemoryInStream(a), const ZxOpenParams())!;
      final b = r.lastIndex.blocks[1];
      a[b.offset + b.headerSize + 50] ^= 0x55;
      final res = testAll(openMem(a));
      expect(res['one'], OperationResult.ok);
      expect(res['two'], isNot(OperationResult.ok));
      expect(res['three'], OperationResult.ok);
    });

    test(
        'a streamed file without its Footer is read by its inline records '
        'and resynchronized after a damaged block', () {
      final o = testOptions()
        ..streamed = true
        ..solid = false;
      final a = makeArchive(files, o);
      final r = ZxArchiveReader.open(MemoryInStream(a), const ZxOpenParams())!;
      final b = r.lastIndex.blocks[1];
      // a damaged block header, and no Index nor Footer
      a[b.offset + 5] ^= 0xFF;
      final cut = Uint8List.fromList(a.sublist(0, r.lastIndexLoc.offset));
      final h = ZxHandler();
      expect(h.open(MemoryInStream(cut)), true);
      expect(h.getArchiveProperty(Kpid.warning), contains('inline records'));
      final got = extractAll(h);
      expect(got['one'], files['one']);
      expect(got['two'], isNull);
      expect(got['three'], files['three']);
    });

    test('the last valid Footer is used (an interrupted update)', () {
      final a = makeArchive(files, testOptions());
      final garbage = Uint8List.fromList([...a, ...lcgBytes(5000, 5)]);
      final h = openMem(garbage);
      _expectSame(extractAll(h), files);
      expect(h.getArchiveProperty(Kpid.warning), contains('ignored'));
    });
  });

  group('detection and CLI', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_det_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<(int, String)> cli(List<String> args) async {
      final out = BytesBuilder();
      final err = BytesBuilder();
      final code = await runSevenZipCli(args,
          stdout: out.add, stderr: err.add, workingDirectory: tmp.path);
      return (
        code,
        utf8.decode(out.takeBytes()) + utf8.decode(err.takeBytes())
      );
    }

    test('wrong or no extension', () async {
      final a = makeArchive({'x.txt': textBytes(1000, 1)}, testOptions());
      File('${tmp.path}/noext').writeAsBytesSync(a);
      File('${tmp.path}/wrong.7z').writeAsBytesSync(a);
      File('${tmp.path}/w.zip').writeAsBytesSync(a);
      for (final n in ['noext', 'wrong.7z', 'w.zip']) {
        final (code, out) = await cli(['l', n]);
        expect(code, 0, reason: out);
        expect(out, contains('Type = zx'));
        expect(out, contains('x.txt'));
      }
    });

    test('a, l -slt, t, x, u, d, rn', () async {
      Directory('${tmp.path}/src/sub').createSync(recursive: true);
      File('${tmp.path}/src/a.txt').writeAsBytesSync(textBytes(20000, 1));
      File('${tmp.path}/src/sub/b.bin').writeAsBytesSync(lcgBytes(5000, 2));
      var (code, out) = await cli(['a', '-mmt1', 'x.zx', 'src']);
      expect(code, 0, reason: out);
      (code, out) = await cli(['l', '-slt', 'x.zx']);
      expect(out, contains('Type = zx'));
      expect(out, contains('SHA-256 = '));
      expect(out, contains('TLSH = T1'));
      expect(out, contains('Versions = 1'));
      (code, out) = await cli(['t', 'x.zx']);
      expect(code, 0, reason: out);
      File('${tmp.path}/src/a.txt').writeAsBytesSync(textBytes(21000, 3));
      (code, out) = await cli(['u', '-mmt1', 'x.zx', 'src']);
      expect(code, 0, reason: out);
      (code, out) = await cli(['rn', 'x.zx', 'src/sub/b.bin', 'src/b2.bin']);
      expect(code, 0, reason: out);
      (code, out) = await cli(['d', 'x.zx', 'src/a.txt']);
      expect(code, 0, reason: out);
      (code, out) = await cli(['l', '-slt', 'x.zx']);
      expect(out, contains('Versions = 4'));
      expect(out, contains('src/b2.bin'));
      expect(out, isNot(contains('src/a.txt')));
      (code, out) = await cli(['x', '-oout', '-mversion=2', 'x.zx']);
      expect(code, 0, reason: out);
      expect(File('${tmp.path}/out/src/a.txt').readAsBytesSync(),
          textBytes(21000, 3));
      (code, out) = await cli(['l', '-mtimeline=src/a.txt', 'x.zx']);
      expect(out, contains('2 files'));
      (code, out) = await cli(['a', '-mcompact', 'x.zx']);
      expect(code, 0, reason: out);
      (code, out) = await cli(['l', '-slt', 'x.zx']);
      expect(out, contains('Versions = 1'));
      expect(out, contains('src/b2.bin'));
    });

    test('symbolic links (-snl) and folders', () async {
      if (Platform.isWindows) return;
      Directory('${tmp.path}/s/empty').createSync(recursive: true);
      File('${tmp.path}/s/t.txt').writeAsStringSync('target');
      Link('${tmp.path}/s/l').createSync('t.txt');
      var (code, out) = await cli(['a', '-snl', '-mmt1', 'l.zx', 's']);
      expect(code, 0, reason: out);
      (code, out) = await cli(['l', '-slt', 'l.zx']);
      expect(out, contains('Symbolic Link = t.txt'));
      (code, out) = await cli(['x', '-snl', '-oo', 'l.zx']);
      expect(code, 0, reason: out);
      expect(Link('${tmp.path}/o/s/l').targetSync(), 't.txt');
      expect(Directory('${tmp.path}/o/s/empty').existsSync(), true);
      expect(File('${tmp.path}/o/s/t.txt').readAsStringSync(), 'target');
    });

    test('-m switches', () async {
      File('${tmp.path}/a.txt').writeAsBytesSync(textBytes(30000, 1));
      for (final (sw, want) in [
        (['-mx0'], 'store'),
        (['-m0=PPMd8:o=6'], 'PPMd8'),
        (['-mf=BCJ', '-m0=Deflate'], 'BCJ Deflate'),
        (['-m0=zpaq:2'], 'zpaq'),
        (['-mx9', '-mcheck=sha256', '-ms=off'], 'LZMA2'),
      ]) {
        final m = File('${tmp.path}/m.zx');
        if (m.existsSync()) m.deleteSync();
        final (code, out) = await cli(['a', '-mmt1', ...sw, 'm.zx', 'a.txt']);
        expect(code, 0, reason: out);
        final (_, l) = await cli(['l', '-slt', 'm.zx']);
        expect(l, contains('Method = $want'), reason: sw.join(' '));
        final (tc, t) = await cli(['t', 'm.zx']);
        expect(tc, 0, reason: t);
      }
    });

    test('-so and -si', () async {
      File('${tmp.path}/a.txt').writeAsBytesSync(textBytes(3000, 1));
      final out = BytesBuilder();
      final code = await runSevenZipCli(['a', '-tzx', '-so', 'x.zx', 'a.txt'],
          stdout: out.add, workingDirectory: tmp.path);
      expect(code, 0);
      final a = out.takeBytes();
      expect(ZxArchiveReader.readHeader(MemoryInStream(a))!.streamed, true);
      final got = BytesBuilder();
      final c2 = await runSevenZipCli(['x', '-tzx', '-si', '-so'],
          stdin: a, stdout: got.add, workingDirectory: tmp.path);
      expect(c2, 0);
      expect(got.takeBytes(), textBytes(3000, 1));
    });
  });

  group('parallel', () {
    test('parallel output equals sequential output', () {
      final files = {
        for (var i = 0; i < 6; i++) 'f$i': textBytes(200000, i + 1),
        'r': lcgBytes(100000, 3),
      };
      final seq = makeArchive(files, testOptions(threads: 1));
      final par = makeArchive(files, testOptions(threads: 4));
      expect(par, seq);
      final h = openMem(par);
      h.options.threads = 4;
      _expectSame(extractAll(h), files);
    });
  });
}

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

int _xxh32(List<int> b) => xxh32(Uint8List.fromList(b));

// a stream that is not seekable
class _PipeOut implements OutStream {
  final BytesBuilder _b = BytesBuilder();
  @override
  void write(Uint8List buf, int off, int len) =>
      _b.add(Uint8List.sublistView(buf, off, off + len));
  @override
  void flush() {}
  Uint8List bytes() => _b.toBytes();
}

// an update callback with one new file
class _OneFile extends ArchiveUpdateCallback {
  final String path;
  final Uint8List data;
  _OneFile(this.path, this.data);
  @override
  UpdateItemInfo getUpdateItemInfo(int index) =>
      const UpdateItemInfo(true, true, -1);
  @override
  Object? getProperty(int index, int propId) => switch (propId) {
        Kpid.path => path,
        Kpid.size => data.length,
        Kpid.isDir => false,
        _ => null,
      };
  @override
  InStream? getStream(int index) => MemoryInStream(data);
}
