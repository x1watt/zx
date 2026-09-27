// Reolink PAK firmware files: synthetic 32 and 64-bit files built here, and
// the real D340W firmware (skipped when absent) checked against pakler
// (the section list of `pakler -l`, the bytes of `pakler -e`).

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/pak/pak_handler.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc.dart';
import 'package:zx/zx.dart';

const _fwDir = '/home/brito/code/xprs/firmware/models/reolink-d340w/firmware';
const _realFiles = [
  '$_fwDir/stock/DB_566128M5MP_W.4662_2508071282.Reolink-Video-Doorbell-WiFi.OV05A10.5MP.WIFI8812.REOLINK.pak',
  '$_fwDir/tool/work/reobell_baked.pak',
];

String? _pakler() {
  for (final p in [
    '${Platform.environment['HOME']}/.local/bin/pakler',
    '/usr/local/bin/pakler',
    '/usr/bin/pakler',
  ]) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void _putStr(Uint8List b, int off, String s) {
  for (var i = 0; i < s.length; i++) {
    b[off + i] = s.codeUnitAt(i);
  }
}

/// A PAK file with [sections] (name, data; null data for an empty entry)
/// and the MTD table, in the 32 or 64-bit layout, with a valid CRC.
Uint8List buildPak(List<(String, Uint8List?)> sections, {bool is64 = false}) {
  final n = sections.length;
  final hh = is64 ? 24 : 12;
  final ss = is64 ? 72 : 64;
  final headerSize = hh + n * ss + n * 76;
  var total = headerSize;
  for (final s in sections) {
    total += s.$2?.length ?? 0;
  }
  final b = Uint8List(total);
  setUint32LE(b, 0, kPakMagic);
  setUint32LE(b, is64 ? 16 : 8, 0x3602);
  var pos = headerSize;
  for (var i = 0; i < n; i++) {
    final (name, data) = sections[i];
    final o = hh + i * ss;
    if (data != null) {
      _putStr(b, o, name);
      _putStr(b, o + 32, 'v1.0.0.1');
      if (is64) {
        setUint64LE(b, o + 56, pos);
        setUint64LE(b, o + 64, data.length);
      } else {
        setUint32LE(b, o + 56, pos);
        setUint32LE(b, o + 60, data.length);
      }
      b.setRange(pos, pos + data.length, data);
      pos += data.length;
    }
    final m = hh + n * ss + i * 76;
    _putStr(b, m, name.isEmpty ? 'part$i' : name);
    _putStr(b, m + 36, '/dev/mtd12');
    setUint32LE(b, m + 32, i * 0x40000);
    setUint32LE(b, m + 68, i * 0x40000);
    setUint32LE(b, m + 72, 0x40000);
  }
  // the first MTD name must repeat the first section name
  var v = crc32Update(0, b, headerSize, b.length);
  v = crc32Update(v, Uint8List.fromList([2, 0, 0, 0]), 0, 4);
  v = crc32Update(v, b, hh, hh + n * ss);
  setUint32LE(b, is64 ? 8 : 4, v & 0xFFFFFFFF);
  return b;
}

List<(String, Uint8List?)> _sample() => [
      ('loader', Uint8List.fromList(List.generate(300, (i) => i & 0xFF))),
      ('fdt', Uint8List.fromList(List.generate(77, (i) => 255 - i))),
      ('', null),
      ('kernel', Uint8List.fromList(List.generate(1000, (i) => i * 3))),
      ('', null),
    ];

void main() {
  for (final is64 in [false, true]) {
    test('synthetic ${is64 ? 64 : 32}-bit PAK', () {
      final data = buildPak(_sample(), is64: is64);
      final h = PakHandler();
      expect(h.open(MemoryInStream(data)), isTrue);
      expect(h.is64, is64);
      expect(h.sections.length, 5);
      expect(h.crcOk, isTrue);
      expect(h.numberOfItems, 3);
      expect([for (var i = 0; i < 3; i++) h.getProperty(i, Kpid.path)],
          ['loader', 'fdt', 'kernel']);
      final s = _sample();
      for (final (i, k) in [(0, 0), (1, 1), (2, 3)]) {
        expect(readAll(h.getStream(i)!), s[k].$2);
        expect(h.getProperty(i, Kpid.size), s[k].$2!.length);
      }
      expect(h.getProperty(2, Kpid.comment), contains('section 3'));
      expect(h.getArchiveProperty(Kpid.warningFlags), isNull);

      // a changed data byte is a CRC warning, the listing stays
      data[data.length - 1] ^= 1;
      expect(h.open(MemoryInStream(data)), isTrue);
      expect(h.crcOk, isFalse);
      expect(h.getArchiveProperty(Kpid.warningFlags), ErrorFlags.crcError);
      expect(h.numberOfItems, 3);
    });
  }

  test('detection of a PAK with no extension and a wrong one', () async {
    final tmp = Directory.systemTemp.createTempSync('zx_pak_test');
    try {
      for (final name in ['fw', 'fw.zip', 'fw.pak']) {
        final p = '${tmp.path}/$name';
        File(p).writeAsBytesSync(buildPak(_sample()));
        final z = await ZxArchive.open(p);
        expect(z.format, 'Pak', reason: name);
        expect(z.items.map((e) => e.path), ['loader', 'fdt', 'kernel']);
        expect((await z.test()).ok, isTrue);
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  final pakler = _pakler();
  for (final path in _realFiles) {
    final present = File(path).existsSync();
    test('real firmware ${path.split('/').last}', () async {
      // pakler -l
      final r = Process.runSync(pakler!, ['-l', path]);
      expect(r.exitCode, 0);
      final out = r.stdout as String;
      expect(out, contains('File passes CRC check'));
      final re = RegExp(r'Section\s+(\d+) name="([^"]*)"\s+version="([^"]*)"'
          r'\s+start=0x([0-9a-f]+)\s+len=0x([0-9a-f]+)');
      final expected = <(int, String, int, int)>[];
      for (final m in re.allMatches(out)) {
        final len = int.parse(m.group(5)!, radix: 16);
        if (len == 0) continue;
        expected.add((
          int.parse(m.group(1)!),
          m.group(2)!,
          int.parse(m.group(4)!, radix: 16),
          len
        ));
      }
      expect(expected, isNotEmpty);

      final fs = FileInStream.open(path);
      final h = PakHandler();
      try {
        expect(h.open(fs), isTrue);
        expect(h.crcOk, isTrue);
        expect(h.numberOfItems, expected.length);
        for (var i = 0; i < expected.length; i++) {
          final (_, name, start, len) = expected[i];
          expect(h.getProperty(i, Kpid.path), name);
          expect(h.getProperty(i, Kpid.offset), start);
          expect(h.getProperty(i, Kpid.size), len);
        }
      } finally {
        fs.close();
      }

      // pakler -e, compared with zx's extraction
      final tmp = Directory.systemTemp.createTempSync('zx_pak_real');
      try {
        final e =
            Process.runSync(pakler, ['-e', '-d', '${tmp.path}/pakler', path]);
        expect(e.exitCode, 0);
        final z = await ZxArchive.open(path);
        expect(z.format, 'Pak');
        final res = await z.extract('${tmp.path}/zx');
        expect(res.errors, isEmpty);
        for (final (num, name, _, _) in expected) {
          final a = '${tmp.path}/pakler/${num.toString().padLeft(2, '0')}'
              '_$name.bin';
          final b = '${tmp.path}/zx/$name';
          expect(_sameFile(a, b), isTrue, reason: name);
        }
      } finally {
        tmp.deleteSync(recursive: true);
      }
    }, skip: !present || pakler == null ? 'firmware or pakler missing' : false);
  }
}

bool _sameFile(String a, String b) {
  final fa = File(a).openSync();
  final fb = File(b).openSync();
  try {
    if (fa.lengthSync() != fb.lengthSync()) return false;
    final ba = Uint8List(1 << 16);
    final bb = Uint8List(1 << 16);
    for (;;) {
      final na = fa.readIntoSync(ba);
      final nb = fb.readIntoSync(bb);
      if (na != nb) return false;
      if (na == 0) return true;
      for (var i = 0; i < na; i++) {
        if (ba[i] != bb[i]) return false;
      }
    }
  } finally {
    fa.closeSync();
    fb.closeSync();
  }
}
