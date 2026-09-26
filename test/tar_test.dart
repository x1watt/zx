import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/tar/tar_handler.dart';
import 'package:zx/src/format/tar/tar_header.dart';
import 'package:zx/src/format/tar/tar_in.dart';
import 'package:zx/src/format/tar/tar_out.dart';
import 'package:zx/src/io/streams.dart';

Uint8List gen(int n, int seed) {
  var st = seed;
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    b[i] = (st >> 16) & 0xff;
  }
  return b;
}

final bool haveTar = File('/usr/bin/tar').existsSync();
final bool have7z = File('/usr/bin/7z').existsSync();

class _Collect extends ArchiveExtractCallback {
  final Map<int, MemoryOutStream> outs = {};
  final Map<int, int> results = {};
  int _cur = -1;
  @override
  OutStream? getStream(int index, int askMode) {
    _cur = index;
    return outs[index] = MemoryOutStream();
  }

  @override
  void setOperationResult(int opRes) => results[_cur] = opRes;

  Uint8List data(int i) => outs[i]!.toBytes();
}

/// A non seekable view of bytes (a pipe).
class _Pipe implements InStream {
  final Uint8List b;
  int p = 0;
  _Pipe(this.b);
  @override
  int read(Uint8List buf, int off, int len) {
    var n = b.length - p;
    if (n > len) n = len;
    if (n > 700) n = 700; // short reads
    buf.setRange(off, off + n, b, p);
    p += n;
    return n;
  }
}

/// One entry of an update: keep item [keep] of the old archive (renamed
/// when [name] is set), or a new item.
class _Up {
  final int keep;
  final String? name;
  final bool isDir;
  final Uint8List? data;
  final int? posix;
  final int? mTime;
  final String? symLink;
  _Up.keep(this.keep, [this.name])
      : isDir = false,
        data = null,
        posix = null,
        mTime = null,
        symLink = null;
  _Up.add(String this.name,
      {this.isDir = false, this.data, this.posix, this.mTime, this.symLink})
      : keep = -1;
}

class _UpdateCb extends ArchiveUpdateCallback {
  final List<_Up> ups;
  int opResults = 0;
  _UpdateCb(this.ups);

  @override
  UpdateItemInfo getUpdateItemInfo(int index) {
    final u = ups[index];
    if (u.keep >= 0) return UpdateItemInfo(false, u.name != null, u.keep);
    return const UpdateItemInfo(true, true, -1);
  }

  @override
  Object? getProperty(int index, int propId) {
    final u = ups[index];
    switch (propId) {
      case Kpid.path:
        return u.name;
      case Kpid.isDir:
        return u.keep >= 0 ? null : u.isDir;
      case Kpid.size:
        return u.data?.length ?? 0;
      case Kpid.posixAttrib:
        return u.posix;
      case Kpid.mTime:
        return u.mTime;
      case Kpid.symLink:
        return u.symLink;
    }
    return null;
  }

  @override
  InStream? getStream(int index) =>
      MemoryInStream(ups[index].data ?? Uint8List(0));

  @override
  void setOperationResult(int opRes) => opResults++;
}

// FILETIME of a Unix time
int ft(int sec, [int ns = 0]) => tarTimeToFileTime(sec, ns);

TarHandler openBytes(Uint8List b) {
  final h = TarHandler();
  expect(h.open(MemoryInStream(b)), isTrue);
  return h;
}

Uint8List writeTar(void Function(TarArchiveWriter w) body,
    {TarWriteFormat format = TarWriteFormat.pax, TarTimeOptions? times}) {
  final out = MemoryOutStream();
  final w = TarArchiveWriter(out, format: format, times: times);
  body(w);
  w.close();
  return Uint8List.fromList(out.toBytes());
}

// a header block with the given fields, v7 style (no magic)
Uint8List rawHeader(String name, int size,
    {int type = 0x30, bool ustar = true, int mtime = 0}) {
  final h = Uint8List(512);
  final nb = ascii.encode(name);
  h.setRange(0, nb.length, nb);
  tarFormatOctal(0x1A4, h, 100, 7);
  tarFormatOctal(0, h, 108, 7);
  tarFormatOctal(0, h, 116, 7);
  tarFormatOctal(size, h, 124, 11);
  tarFormatOctal(mtime, h, 136, 11);
  h[156] = type;
  if (ustar) {
    h.setRange(257, 263, kUstarMagic);
    h[263] = 0x30;
    h[264] = 0x30;
  }
  tarSetChecksum(h);
  return h;
}

Uint8List concat(List<Uint8List> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

Uint8List padded(Uint8List d) {
  final n = (d.length + 511) & ~511;
  return Uint8List(n)..setRange(0, d.length, d);
}

void main() {
  group('numbers', () {
    test('octal, base-256, negative base-256', () {
      final f = Uint8List(12);
      tarFormatNumberGnu(10 << 30, f, 0, 11, 12);
      expect(f[0] & 0x80, 0x80);
      expect(tarAtol(f, 0, 12), 10 << 30);
      tarFormatNumberGnu(0x1234, f, 0, 11, 12);
      expect(tarAtol(f, 0, 12), 0x1234);
      tarFormat256(-2, f, 0, 12);
      expect(tarAtol(f, 0, 12), -2);
      // leading spaces, NUL and space terminators
      final g = Uint8List.fromList(ascii.encode('  755 \x00'));
      expect(tarAtol(g, 0, g.length), 493);
      // non strict ustar: 8 octal digits before base-256
      final m = Uint8List(8);
      tarFormatNumberUstar(1 << 22, m, 0, 7, 8);
      expect(m[0] & 0x80, 0);
      expect(tarAtol(m, 0, 8), 1 << 22);
      tarFormatNumberUstar(1 << 30, m, 0, 7, 8);
      expect(m[0] & 0x80, 0x80);
      expect(tarAtol(m, 0, 8), 1 << 30);
    });

    test('pax time', () {
      final t = ascii.encode('1709292896.123456789');
      expect(tarPaxTime(Uint8List.fromList(t), 0, t.length),
          (1709292896, 123456789));
      final u = ascii.encode('-5.5');
      expect(tarPaxTime(Uint8List.fromList(u), 0, u.length), (-5, 500000000));
      final bad = ascii.encode('12x');
      expect(tarPaxTime(Uint8List.fromList(bad), 0, bad.length), isNull);
    });

    test('pax record length includes its own digits', () {
      final b = BytesBuilder();
      tarAddPaxAttr(b, 'path', ascii.encode('x' * 89)); // 99 + 2 digits
      final s = ascii.decode(b.toBytes());
      expect(s.length, int.parse(s.substring(0, s.indexOf(' '))));
    });
  });

  group('synthetic headers', () {
    test('base-256 size over 8 GiB (GNU) and pax size', () {
      for (final fmt in TarWriteFormat.values) {
        final out = MemoryOutStream();
        final w = TarWriter(out, format: fmt);
        w.writeHeader(TarOutItem('big.bin', size: 9 << 30, uid: 1 << 22));
        final r = TarReader(MemoryInStream(out.toBytes()));
        final item = TarItem();
        expect(r.readItem(item), TarReadResult.item);
        expect(item.name, 'big.bin');
        expect(item.size, 9 << 30);
        expect(item.packSize, 9 << 30);
        expect(item.uid, 1 << 22);
        if (fmt == TarWriteFormat.pax) {
          expect(item.paxKeys, containsAll(['size', 'uid']));
        }
      }
    });

    test('signed checksum of old tars', () {
      final h = rawHeader('xxx', 0, ustar: false);
      // Latin-1 name bytes >= 128 and a signed checksum
      h[0] = 0xE9;
      h[1] = 0x74;
      h[2] = 0xE9;
      for (var i = 148; i < 156; i++) {
        h[i] = 0x20;
      }
      var sum = 0;
      for (var i = 0; i < 512; i++) {
        final b = h[i];
        sum += b >= 128 ? b - 256 : b;
      }
      tarFormatOctal(sum, h, 148, 6);
      h[154] = 0;
      final h2 = openBytes(concat([h, Uint8List(1024)]));
      expect(h2.numberOfItems, 1);
      expect(h2.getProperty(0, Kpid.path), '\u00e9t\u00e9');
      expect(h2.errorFlags, 0);
    });

    test('v7, end marker, trailing garbage, missing end, bad header', () {
      final data = gen(700, 1);
      final a = concat([
        rawHeader('a.bin', 700, ustar: false, mtime: 1000),
        padded(data),
        rawHeader('dir/', 0, ustar: false, type: 0),
        Uint8List(512 * 3),
        ascii.encode('junk'),
      ]);
      var h = openBytes(a);
      expect(h.numberOfItems, 2);
      expect(h.getProperty(1, Kpid.isDir), isTrue);
      expect(h.getProperty(1, Kpid.path), 'dir');
      expect(h.getArchiveProperty(Kpid.phySize), a.length - 4);
      expect(h.errorFlags, 0);
      expect(h.getProperty(0, Kpid.mTime), ft(1000));
      final c = _Collect();
      h.extract(null, false, c);
      expect(c.data(0), data);
      expect(c.results[0], OperationResult.ok);

      // no end marker
      h = openBytes(Uint8List.sublistView(a, 0, 512 * 4));
      expect(h.numberOfItems, 2);
      expect(h.errorFlags, ErrorFlags.unexpectedEnd);

      // truncated data
      h = openBytes(Uint8List.sublistView(a, 0, 1000));
      expect(h.numberOfItems, 1);
      expect(h.errorFlags & ErrorFlags.unexpectedEnd, isNot(0));
      final c2 = _Collect();
      h.extract(null, false, c2);
      expect(c2.results[0], OperationResult.unexpectedEnd);

      // a broken second header
      final b = Uint8List.fromList(a);
      b[512 * 3 + 10] ^= 0x55;
      h = openBytes(b);
      expect(h.numberOfItems, 1);
      expect(h.errorFlags, ErrorFlags.headersError);
      expect(h.getArchiveProperty(Kpid.phySize), 512 * 3);

      // not a tar
      expect(TarHandler().open(MemoryInStream(gen(2048, 3))), isFalse);
    });

    test('ustar hard link without body, pax hard link with body', () {
      final a = concat([
        rawHeader('f', 3),
        padded(ascii.encode('abc')),
        (rawHeader('l', 3, type: 0x31)
          ..setRange(157, 158, [0x66])
          ..setRange(148, 156, List.filled(8, 0x20))),
        rawHeader('g', 0),
        Uint8List(1024),
      ]);
      tarSetChecksum(Uint8List.sublistView(a, 1024, 1536));
      final h = openBytes(a);
      expect(h.numberOfItems, 3);
      expect(h.getProperty(1, Kpid.hardLink), 'f');
      expect(h.getProperty(1, Kpid.size), 0);
      expect(h.getProperty(2, Kpid.path), 'g');
    });

    test('pax records: path, linkpath, times, names, hdrcharset', () {
      final pax = BytesBuilder();
      tarAddPaxAttr(pax, 'path', utf8.encode('d\u00fcr/${'x' * 150}'));
      tarAddPaxAttr(pax, 'mtime', ascii.encode('1700000000.25'));
      tarAddPaxAttr(pax, 'atime', ascii.encode('1700000001'));
      tarAddPaxAttr(pax, 'uname', utf8.encode('j\u00f6rg'));
      tarAddPaxAttr(pax, 'uid', ascii.encode('70000'));
      tarAddPaxAttr(pax, 'SCHILY.xattr.user.a', ascii.encode('v'));
      final body = pax.toBytes();
      final a = concat([
        rawHeader('PaxHeader/x', body.length, type: 0x78),
        padded(body),
        rawHeader('short', 2),
        padded(ascii.encode('hi')),
        Uint8List(1024),
      ]);
      final h = openBytes(a);
      expect(h.numberOfItems, 1);
      expect(h.getProperty(0, Kpid.path), 'd\u00fcr/${'x' * 150}');
      expect(h.getProperty(0, Kpid.mTime), ft(1700000000, 250000000));
      expect(h.getProperty(0, Kpid.aTime), ft(1700000001));
      expect(h.getProperty(0, Kpid.user), 'j\u00f6rg');
      expect(h.getProperty(0, Kpid.userId), 70000);
      expect(h.timePrec, 16 + 7);
      final c = _Collect();
      h.extract(null, true, c);
      expect(ascii.decode(c.data(0)), 'hi');
    });

    test('GNU volume header is skipped', () {
      final a = concat([
        rawHeader('label', 0, type: 0x56),
        rawHeader('f', 1),
        padded(Uint8List.fromList([7])),
        Uint8List(1024),
      ]);
      final h = openBytes(a);
      expect(h.numberOfItems, 1);
      expect(h.getProperty(0, Kpid.path), 'f');
    });
  });

  group('writer and reader round trip', () {
    for (final fmt in TarWriteFormat.values) {
      test(fmt.name, () {
        final long = 'dir/${'sub/' * 40}${'n' * 120}.txt';
        final data = gen(3000, 7);
        final tar = writeTar((w) {
          w.add(TarOutItem('dir',
              fileType: PosixMode.directory,
              mode: 0x1ED,
              mTime: const TarTime(1600000000, 0)));
          w.add(
              TarOutItem(long,
                  size: data.length,
                  mode: 0x180,
                  mTime: const TarTime(1600000001, 0)),
              MemoryInStream(data));
          w.add(
              TarOutItem('dir/\u00fcn\u00efc\u00f6d\u00e9 \u4e2d.txt',
                  size: 3, user: 'm\u00e4x', group: 'staff'),
              MemoryInStream(Uint8List.fromList([1, 2, 3])));
          w.add(TarOutItem('dir/link',
              fileType: PosixMode.symLink,
              symLink: '${'../' * 50}target',
              mode: 0x1FF));
          w.add(TarOutItem('dir/hard', hardLink: long));
          w.add(TarOutItem('neg', mTime: const TarTime(-100, 0)));
        }, format: fmt);
        expect(tar.length % 512, 0);
        final h = openBytes(tar);
        expect(h.numberOfItems, 6);
        expect(h.errorFlags, 0);
        expect(h.getProperty(0, Kpid.isDir), isTrue);
        expect(h.getProperty(0, Kpid.posixAttrib), 0x41ED);
        expect(h.getProperty(1, Kpid.path), long);
        expect(h.getProperty(1, Kpid.posixAttrib), 0x8180);
        expect(h.getProperty(1, Kpid.mTime), ft(1600000001));
        expect(h.getProperty(2, Kpid.path), 'dir/\u00fcn\u00efc\u00f6d\u00e9 \u4e2d.txt');
        expect(h.getProperty(2, Kpid.user), 'm\u00e4x');
        expect(h.getProperty(3, Kpid.symLink), '${'../' * 50}target');
        expect(h.getProperty(3, Kpid.posixAttrib), 0xA1FF);
        expect(h.getProperty(4, Kpid.hardLink), long);
        if (fmt == TarWriteFormat.pax) {
          expect(h.getProperty(5, Kpid.mTime), ft(-100));
        }
        final c = _Collect();
        h.extract(null, false, c);
        expect(c.data(1), data);
        expect(c.data(2), [1, 2, 3]);
        expect(c.results.values.every((r) => r == OperationResult.ok), isTrue);
      });
    }

    test('pax sub-second times with -mtp digits', () {
      final times = TarTimeOptions()
        ..numDigits = 7
        ..writeATime = true
        ..writeCTime = true;
      final tar = writeTar((w) {
        w.add(TarOutItem('t',
            mTime: const TarTime(1700000000, 123456700),
            aTime: const TarTime(1700000001, 500000000),
            cTime: const TarTime(1700000002, 0)));
      }, times: times);
      final h = openBytes(tar);
      expect(h.getProperty(0, Kpid.mTime), ft(1700000000, 123456700));
      expect(h.getProperty(0, Kpid.aTime), ft(1700000001, 500000000));
      expect(h.getProperty(0, Kpid.cTime), ft(1700000002));
    });
  });

  group('update', () {
    test('keep, delete, rename, add', () {
      final d1 = gen(1000, 1);
      final d2 = gen(10, 2);
      final old = writeTar((w) {
        w.add(TarOutItem('a', size: d1.length), MemoryInStream(d1));
        w.add(TarOutItem('b', size: d2.length), MemoryInStream(d2));
        w.add(TarOutItem('c', size: 0));
      });
      final h = openBytes(old);
      final out = MemoryOutStream();
      final cb = _UpdateCb([
        _Up.keep(0),
        _Up.keep(1, 'b2'),
        _Up.add('new',
            data: Uint8List.fromList([9, 9]),
            posix: 0x81ED,
            mTime: ft(1600000000)),
        _Up.add('newdir', isDir: true, posix: 0x41C0),
        _Up.add('sl', symLink: 'a', posix: 0xA1FF),
      ]);
      h.updateItems(out, 5, cb);
      final nb = Uint8List.fromList(out.toBytes());
      // the kept item is copied byte for byte
      expect(Uint8List.sublistView(nb, 0, 1536),
          Uint8List.sublistView(old, 0, 1536));
      final h2 = openBytes(nb);
      expect(h2.numberOfItems, 5);
      expect([for (var i = 0; i < 5; i++) h2.getProperty(i, Kpid.path)],
          ['a', 'b2', 'new', 'newdir', 'sl']);
      expect(h2.getProperty(2, Kpid.posixAttrib), 0x81ED);
      expect(h2.getProperty(2, Kpid.mTime), ft(1600000000));
      expect(h2.getProperty(3, Kpid.isDir), isTrue);
      expect(h2.getProperty(3, Kpid.posixAttrib), 0x41C0);
      expect(h2.getProperty(4, Kpid.symLink), 'a');
      final c = _Collect();
      h2.extract(null, false, c);
      expect(c.data(0), d1);
      expect(c.data(1), d2);
      expect(c.data(2), [9, 9]);
    });

    test('options', () {
      final h = TarHandler();
      expect(
          () => h.setProperties([MapEntry('m', const PropVariant.bstr('foo'))]),
          throwsA(isA<SevenZipException>()));
      h.setProperties([MapEntry('m', const PropVariant.bstr('posix'))]);
      expect(h.writeFormat, TarWriteFormat.pax);
    });
  });

  group('OpenSeq', () {
    test('list and extract from a pipe', () {
      final data = gen(5000, 4);
      final tar = writeTar((w) {
        w.add(TarOutItem('d', fileType: PosixMode.directory));
        w.add(TarOutItem('d/f', size: data.length), MemoryInStream(data));
        w.add(TarOutItem('d/g', size: 1), MemoryInStream(Uint8List(1)));
      });
      var h = TarHandler();
      expect(h.openSeq(_Pipe(tar)), isTrue);
      final c = _Collect();
      h.extract(null, false, c);
      expect(c.data(1), data);
      expect(c.results.length, 3);
      expect(h.getArchiveProperty(Kpid.phySize), tar.length);

      h = TarHandler();
      expect(h.openSeq(_Pipe(tar)), isTrue);
      expect(h.numberOfItems, 3);
      expect(h.getProperty(2, Kpid.path), 'd/g');

      expect(TarHandler().openSeq(_Pipe(gen(1024, 9))), isFalse);
    });
  });

  group('GNU tar interop', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_tar_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String p(String rel) => '${tmp.path}/$rel';

    void makeTree(String root, {bool longNames = true}) {
      Directory(p('$root/sub/deeper')).createSync(recursive: true);
      File(p('$root/a.txt')).writeAsStringSync('hello\n');
      File(p('$root/sub/b.bin')).writeAsBytesSync(gen(1500, 5));
      File(p('$root/sub/deeper/\u00fcni.txt')).writeAsStringSync('u');
      Link(p('$root/sub/link')).createSync('../a.txt');
      if (longNames) {
        final dir = List.filled(20, 'long_directory').join('/');
        Directory(p('$root/$dir')).createSync(recursive: true);
        File(p('$root/$dir/${'f' * 110}')).writeAsStringSync('deep');
        Link(p('$root/longlink')).createSync('$dir/${'f' * 110}');
      }
      Process.runSync('chmod', ['750', p('$root/sub')]);
      Process.runSync(
          'touch', ['-h', '-d', '2020-05-06 07:08:09', p('$root/a.txt')]);
    }

    Map<String, String> readTree(String root) {
      final m = <String, String>{};
      final dir = Directory(root);
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        final rel = e.path.substring(root.length + 1);
        final st = e.statSync();
        if (e is Link) {
          m[rel] = 'L ${e.targetSync()}';
        } else if (e is Directory) {
          m[rel] = 'D ${(st.mode & 0x1FF).toRadixString(8)}';
        } else {
          final f = File(e.path);
          m[rel] = 'F ${(st.mode & 0x1FF).toRadixString(8)} '
              '${base64.encode(f.readAsBytesSync())} '
              '${st.modified.millisecondsSinceEpoch ~/ 1000}';
        }
      }
      return m;
    }

    test('read archives of every format', () {
      makeTree('src', longNames: false);
      makeTree('srcl');
      File(p('srcl/sparse')).writeAsBytesSync([]);
      Process.runSync('dd', [
        'if=/dev/urandom',
        'of=${p('srcl/sparse')}',
        'bs=1k',
        'count=8',
        'seek=200',
        'conv=notrunc'
      ]);
      Process.runSync('truncate', ['-s', '1M', p('srcl/sparse')]);
      final variants = <String, List<String>>{
        'v7': ['--format=v7', '-C', p('src')],
        'ustar': ['--format=ustar', '-C', p('src')],
        'gnu': ['--format=gnu', '-S', '-C', p('srcl')],
        'oldgnu': ['--format=oldgnu', '-S', '-C', p('srcl')],
        'pax': ['--format=pax', '-S', '-C', p('srcl')],
        'pax01': [
          '--format=pax',
          '-S',
          '--sparse-version=0.1',
          '-C',
          p('srcl')
        ],
        'pax00': [
          '--format=pax',
          '-S',
          '--sparse-version=0.0',
          '-C',
          p('srcl')
        ],
      };
      for (final e in variants.entries) {
        final arc = p('${e.key}.tar');
        final r = Process.runSync('tar', ['-cf', arc, ...e.value, '.']);
        expect(r.exitCode, 0, reason: '${e.key}: ${r.stderr}');
        final h = TarHandler();
        final s = FileInStream.open(arc);
        try {
          expect(h.open(s), isTrue, reason: e.key);
          expect(h.errorFlags, 0, reason: e.key);
          final listing = Process.runSync('tar', ['-tf', arc])
              .stdout
              .toString()
              .split('\n')
              .where((l) => l.isNotEmpty)
              .map((l) => l.endsWith('/') && l.length > 1
                  ? l.substring(0, l.length - 1)
                  : l)
              .toList();
          expect([
            for (var i = 0; i < h.numberOfItems; i++)
              h.getProperty(i, Kpid.path)
          ], listing, reason: e.key);
          final c = _Collect();
          h.extract(null, true, c);
          final srcRoot = e.value.last;
          for (var i = 0; i < h.numberOfItems; i++) {
            expect(c.results[i], OperationResult.ok, reason: '${e.key} $i');
            final path = h.getProperty(i, Kpid.path) as String;
            if (h.getProperty(i, Kpid.isDir) == true) continue;
            final sl = h.getProperty(i, Kpid.symLink);
            final full = '$srcRoot/$path';
            if (sl != null) {
              expect(Link(full).targetSync(), sl, reason: path);
              continue;
            }
            expect(c.data(i), File(full).readAsBytesSync(), reason: path);
            final mt = h.getProperty(i, Kpid.mTime) as int;
            expect(fileTimeToTarTime(mt).$1,
                File(full).lastModifiedSync().millisecondsSinceEpoch ~/ 1000,
                reason: path);
          }
        } finally {
          s.close();
        }
      }
    }, skip: !haveTar);

    test('GNU tar reads what the writer makes', () {
      makeTree('src');
      final m0 = readTree(p('src'));
      for (final fmt in TarWriteFormat.values) {
        final out = FileOutStream.create(p('w.tar'));
        final w = TarArchiveWriter(out, format: fmt);
        final root = p('src');
        final entries = Directory(root)
            .listSync(recursive: true, followLinks: false)
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final e in entries) {
          final rel = e.path.substring(root.length + 1);
          final st = e.statSync();
          final mt = st.modified.millisecondsSinceEpoch;
          final t = TarTime(mt ~/ 1000, (mt % 1000) * 1000000);
          if (e is Link) {
            w.add(TarOutItem(rel,
                fileType: PosixMode.symLink,
                symLink: e.targetSync(),
                mode: 0x1FF,
                mTime: t));
          } else if (e is Directory) {
            w.add(TarOutItem(rel,
                fileType: PosixMode.directory,
                mode: st.mode & 0xFFF,
                mTime: t));
          } else {
            final b = File(e.path).readAsBytesSync();
            w.add(
                TarOutItem(rel,
                    size: b.length, mode: st.mode & 0xFFF, mTime: t),
                MemoryInStream(b));
          }
        }
        w.close();
        out.close();
        final list = Process.runSync('tar', ['-tvf', p('w.tar')]);
        expect(list.exitCode, 0, reason: '${fmt.name}: ${list.stderr}');
        final dest = Directory(p('x_${fmt.name}'))..createSync();
        final x = Process.runSync('tar', ['-xf', p('w.tar'), '-C', dest.path]);
        expect(x.exitCode, 0, reason: '${fmt.name}: ${x.stderr}');
        expect(readTree(dest.path), m0, reason: fmt.name);
        if (have7z) {
          final t = Process.runSync('7z', ['t', p('w.tar')]);
          expect(t.exitCode, 0, reason: t.stdout.toString());
        }
      }
    }, skip: !haveTar);
  });
}
