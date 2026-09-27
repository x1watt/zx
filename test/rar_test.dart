import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/codec/rar/rar5_decoder.dart';
import 'package:zx/src/codec/rar/rar5_encoder.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/crypto/blake2sp.dart';
import 'package:zx/src/crypto/rar5_kdf.dart';
import 'package:zx/src/crypto/rar_legacy_cipher.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/split.dart';
import 'package:zx/src/format/rar/rar5_recovery.dart';
import 'package:zx/src/format/rar/rar_handler.dart';
import 'package:zx/src/format/rar/rar_volumes.dart';
import 'package:zx/src/io/streams.dart';
import 'package:zx/src/util/crc.dart';

// The reference tools: rar 7.00 (creates RAR5 archives) and unrar.
const String _rarPath = 'ref/tools/root/usr/bin/rar';
final bool haveRar = File(_rarPath).existsSync();
final bool haveUnrar = File('/usr/bin/unrar').existsSync();

// libarchive's RAR test archives (RAR 2.9 / 3.x, made by old rar
// versions: rar 7 can not create RAR 4.x archives any more)
const String _laTests = 'ref/libarchive/libarchive/test';
final bool haveLaTests = Directory(_laTests).existsSync();

Uint8List gen(int n, int seed) {
  var st = seed;
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    st = (st * 1103515245 + 12345) & 0x7fffffff;
    b[i] = (st >> 16) & 0xff;
  }
  return b;
}

// compressible text like data
Uint8List text(int n, int seed) {
  const words = [
    'alpha', 'beta', 'gamma', 'delta', 'archive', 'volume', 'solid', //
    'window', 'filter', 'match', 'literal', 'table', '\n', ' ', ', ',
  ];
  final r = gen(n, seed);
  final b = BytesBuilder();
  var i = 0;
  while (b.length < n) {
    b.add(utf8.encode(words[r[i++ % n] % words.length]));
  }
  return Uint8List.sublistView(b.toBytes(), 0, n);
}

// 16 bit stereo samples: a job for the DELTA filter
Uint8List audio(int frames) {
  final b = Uint8List(frames * 4);
  var a = 0, c = 0;
  for (var i = 0; i < frames; i++) {
    a = (a + 37 + (i % 7)) & 0xFFFF;
    c = (c + 11 + (i % 5)) & 0xFFFF;
    b[i * 4] = a & 0xFF;
    b[i * 4 + 1] = a >> 8;
    b[i * 4 + 2] = c & 0xFF;
    b[i * 4 + 3] = c >> 8;
  }
  return b;
}

class _Collect extends ArchiveExtractCallback implements CryptoGetTextPassword {
  final String? password;
  final Map<int, MemoryOutStream> outs = {};
  final Map<int, int> results = {};
  int _cur = -1;
  _Collect([this.password]);

  @override
  OutStream? getStream(int index, int askMode) {
    _cur = index;
    return outs[index] = MemoryOutStream();
  }

  @override
  void setOperationResult(int opRes) => results[_cur] = opRes;

  @override
  String cryptoGetTextPassword() =>
      password ?? (throw const SevenZipException('no password'));

  Uint8List data(int i) => outs[i]!.toBytes();
}

/// Checks the data without keeping it.
class _Check extends ArchiveExtractCallback {
  final Map<int, int> results = {};
  int _cur = -1;
  @override
  OutStream? getStream(int index, int askMode) {
    _cur = index;
    return NullOutStream();
  }

  @override
  void setOperationResult(int opRes) => results[_cur] = opRes;
}

/// An output without seeking (a pipe).
class _NoSeek implements OutStream {
  final OutStream base;
  _NoSeek(this.base);
  @override
  void write(Uint8List buf, int off, int len) => base.write(buf, off, len);
  @override
  void flush() {}
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

class _UpdateCb extends ArchiveUpdateCallback
    implements CryptoGetTextPassword2 {
  final List<_Up> ups;
  final String? password;
  _UpdateCb(this.ups, [this.password]);

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
  String? cryptoGetTextPassword2() => password;
}

// FILETIME of a Unix time
int ft(int sec) => (sec + 11644473600) * 10000000;

List<MapEntry<String, PropVariant>> props(String s) => [
      for (final p in s.split(',').where((x) => x.isNotEmpty))
        convertCliProperty(
            p.split('=')[0], p.contains('=') ? p.split('=')[1] : '')
    ];

Uint8List _writeRar(List<_Up> ups,
    {String opts = '', String? password, RarHandler? old}) {
  final h = old ?? RarHandler(rar5: true);
  h.setProperties(props(opts));
  final out = MemoryOutStream();
  h.updateItems(out, ups.length, _UpdateCb(ups, password));
  return Uint8List.fromList(out.toBytes());
}

RarHandler openRar(Uint8List b, {String? password, bool rar5 = true}) {
  final h = RarHandler(rar5: rar5);
  expect(h.open(MemoryInStream(b), getPassword: () => password), isTrue);
  return h;
}

RarHandler openFile(String path, {String? password, bool rar5 = true}) {
  final h = RarHandler(rar5: rar5);
  final dir = File(path).parent.path;
  expect(
      h.open(FileInStream.open(path),
          name: path.split('/').last,
          openVolume: (n) {
            final f = File('$dir/$n');
            return f.existsSync() ? FileInStream.open(f.path) : null;
          },
          getPassword: () => password),
      isTrue);
  return h;
}

// the items by path, extracted with [password]
Map<String, Uint8List> extractAll(RarHandler h, [String? password]) {
  final cb = _Collect(password);
  h.extract(null, false, cb);
  final r = <String, Uint8List>{};
  for (var i = 0; i < h.numberOfItems; i++) {
    expect(cb.results[i], OperationResult.ok,
        reason: '${h.getProperty(i, Kpid.path)}');
    if (h.getProperty(i, Kpid.isDir) != true) {
      r[h.getProperty(i, Kpid.path) as String] = cb.data(i);
    }
  }
  return r;
}

void main() {
  group('crypto', () {
    test('PBKDF2-HMAC-SHA256 (RFC 7914 vector)', () {
      final k =
          Rar5Keys.derive('passwd', Uint8List.fromList(utf8.encode('salt')), 0);
      expect(
          k.key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          '55ac046e56e3089fec1691c22544b605'
          'f94185216dde0465e68b9d57c20dacbc');
    });

    test('BLAKE2sp streaming equals one shot', () {
      final d = gen(5000, 3);
      final a = Blake2sp.hash(d);
      final s = Blake2sp();
      for (var i = 0; i < d.length; i += 77) {
        s.update(d, i, i + 77 > d.length ? d.length - i : 77);
      }
      expect(s.digest(), a);
    });
  });

  group('volume names', () {
    test('new and old numbering', () {
      expect(rarNextVolumeName('a.part1.rar', true), 'a.part2.rar');
      expect(rarNextVolumeName('a.part09.rar', true), 'a.part10.rar');
      expect(rarNextVolumeName('a.part99.rar', true), 'a.part100.rar');
      expect(rarNextVolumeName('a.rar', false), 'a.r00');
      expect(rarNextVolumeName('a.r00', false), 'a.r01');
      expect(rarNextVolumeName('a.r99', false), 'a.s00');
      expect(rarFirstVolumeName('x.part03.rar'), 'x.part01.rar');
    });
  });

  group('RAR5 codec', () {
    for (final method in [1, 3, 5]) {
      test('encoder and decoder round trip, method $method', () {
        for (final data in [
          text(100000, 1),
          gen(20000, 2),
          Uint8List(70000),
          audio(20000),
          Uint8List(1),
        ]) {
          final enc = Rar5Encoder(method, 1 << 20);
          enc.start(MemoryInStream(data),
              expectedSize: data.length, fileSizes: [data.length]);
          final packed = MemoryOutStream();
          enc.encodeFile(data.length, packed);
          final out = MemoryOutStream();
          Rar5Decoder().decodeFile(
              MemoryInStream(Uint8List.fromList(packed.toBytes())),
              out,
              data.length,
              Rar5Decoder.windowSizeFor(1 << 20, data.length),
              false);
          expect(out.toBytes(), data);
        }
      });
    }

    test('the DELTA filter pays off on sampled data', () {
      final data = audio(50000);
      int packedSize(bool filters) {
        final enc = Rar5Encoder(3, 1 << 20);
        enc.start(MemoryInStream(data),
            expectedSize: data.length,
            fileSizes: [data.length],
            filters: filters);
        final packed = NullOutStream();
        enc.encodeFile(data.length, packed);
        return packed.count;
      }

      expect(packedSize(true), lessThan(packedSize(false) ~/ 2));
    });
  });

  group('RAR5 archives', () {
    final files = <_Up>[
      _Up.add('dir', isDir: true, posix: 0x41ED, mTime: ft(1600000000)),
      _Up.add('dir/a.txt',
          data: text(50000, 5), posix: 0x81A4, mTime: ft(1600000001)),
      _Up.add('dir/b.bin', data: gen(3000, 6), posix: 0x81ED),
      _Up.add('empty', data: Uint8List(0), posix: 0x81A4),
      _Up.add('dir/c.txt', data: text(20000, 7), posix: 0x81A4),
      _Up.add('link', symLink: 'dir/a.txt', posix: 0xA1FF),
      _Up.add('ünï €.txt', data: utf8.encode('unicode')),
    ];

    void checkContent(Map<String, Uint8List> got) {
      expect(got['dir/a.txt'], files[1].data);
      expect(got['dir/b.bin'], files[2].data);
      expect(got['empty'], isEmpty);
      expect(got['dir/c.txt'], files[4].data);
      expect(utf8.decode(got['link']!), 'dir/a.txt');
      expect(utf8.decode(got['ünï €.txt']!), 'unicode');
    }

    for (final opts in [
      'x=0',
      'x=1',
      'x=5',
      'x=9,s=on',
      'x=5,crc=blake2',
      'x=5,s=on,crc=blake2,d=1m',
    ]) {
      test('write and read back ($opts)', () {
        final b = _writeRar(files, opts: opts);
        final h = openRar(b);
        expect(h.numberOfItems, files.length);
        checkContent(extractAll(h));
        final li = [
          for (var i = 0; i < h.numberOfItems; i++) h.getProperty(i, Kpid.path)
        ].indexOf('link');
        expect(h.getProperty(li, Kpid.symLink), 'dir/a.txt');
        expect(h.getProperty(1, Kpid.mTime), ft(1600000001));
        expect(h.getArchiveProperty(Kpid.solid), opts.contains('s=on'));
      });
    }

    test('single items of a solid archive', () {
      final b = _writeRar(files, opts: 'x=5,s=on');
      final h = openRar(b);
      for (final i in [4, 1, 4, 2]) {
        final cb = _Collect();
        h.extract([i], false, cb);
        expect(cb.results[i], OperationResult.ok);
        expect(cb.data(i), files[i].data);
      }
    });

    test('encrypted data and headers', () {
      final b = _writeRar(files, opts: 'x=3', password: 'pw');
      checkContent(extractAll(openRar(b), 'pw'));
      // a wrong password is detected by the password check value
      final h = openRar(b);
      final cb = _Collect('bad');
      h.extract(null, false, cb);
      expect(cb.results[1], OperationResult.wrongPassword);

      final e = _writeRar(files, opts: 'x=3,he=on,s=on', password: 'pw');
      expect(openRar(e, password: 'pw').getArchiveProperty(Kpid.encrypted),
          isTrue);
      checkContent(extractAll(openRar(e, password: 'pw'), 'pw'));
      expect(
          () => openRar(e, password: 'bad'), throwsA(isA<SevenZipException>()));
    });

    test('update: keep, rename, delete, add', () {
      for (final solid in [false, true]) {
        final b = _writeRar(files, opts: solid ? 's=on' : '');
        final old = openRar(b);
        final u = _writeRar([
          _Up.keep(0),
          _Up.keep(1, 'dir/renamed.txt'),
          _Up.keep(4),
          _Up.keep(5),
          _Up.add('new.txt', data: text(10000, 9)),
        ], old: old);
        final got = extractAll(openRar(u));
        expect(got.keys.toSet(),
            {'dir/renamed.txt', 'dir/c.txt', 'link', 'new.txt'});
        expect(got['dir/renamed.txt'], files[1].data);
        expect(got['dir/c.txt'], files[4].data);
        expect(got['new.txt'], text(10000, 9));
      }
    });

    test('a RAR 4.x style handler writes RAR5 too', () {
      final h = RarHandler(rar5: false);
      h.setProperties(props('x=1'));
      final out = MemoryOutStream();
      h.updateItems(out, files.length, _UpdateCb(files));
      final b = Uint8List.fromList(out.toBytes());
      expect(b.sublist(0, 8), [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0]);
      // and the Rar handler opens RAR5 archives
      checkContent(extractAll(openRar(b, rar5: false)));
    });
  });

  group('interop with rar and unrar', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_rar_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    // a small tree: text, an ELF executable, sampled data, random bytes
    Map<String, Uint8List> makeTree() {
      final src = Directory('${tmp.path}/src')..createSync();
      final t = <String, Uint8List>{
        'src/a.txt': text(60000, 11),
        'src/sub/b.txt': text(5000, 12),
        'src/audio.raw': audio(30000),
        'src/random.dat': gen(40000, 13),
        'src/empty': Uint8List(0),
      };
      final ls = File('/usr/bin/ls');
      if (ls.existsSync()) t['src/ls'] = ls.readAsBytesSync();
      for (final e in t.entries) {
        File('${tmp.path}/${e.key}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(e.value);
      }
      Link('${src.path}/link').createSync('a.txt');
      return t;
    }

    ProcessResult rar(List<String> args) =>
        Process.runSync(File(_rarPath).absolute.path, ['-idq', ...args],
            workingDirectory: tmp.path);

    test('archives made by rar 7 (RAR5) extract', () {
      final t = makeTree();
      final cases = <String, List<String>>{
        'm0.rar': ['-m0'],
        'm1.rar': ['-m1'],
        'm3.rar': ['-m3'],
        'm5.rar': ['-m5', '-s'],
        'b2.rar': ['-htb', '-s'],
        'p.rar': ['-ppw'],
        'hp.rar': ['-hppw', '-s'],
        'rr.rar': ['-rr5%', '-ts+'],
        'v.rar': ['-v60k', '-m3'],
        'sv.rar': ['-v50k', '-s'],
        'cmt.rar': ['-zcmt.txt'],
      };
      File('${tmp.path}/cmt.txt').writeAsStringSync('the comment');
      for (final c in cases.entries) {
        final r = rar(['a', '-ol', ...c.value, c.key, 'src']);
        expect(r.exitCode, 0, reason: '${c.key}: ${r.stdout}');
        var name = c.key;
        if (c.value.any((s) => s.startsWith('-v'))) {
          name = c.key.replaceFirst('.rar', '.part1.rar');
        }
        final pw = c.value.any((s) => s.contains('pw')) ? 'pw' : null;
        final h = openFile('${tmp.path}/$name', password: pw);
        final got = extractAll(h, pw);
        for (final e in t.entries) {
          expect(got[e.key], e.value, reason: '${c.key} ${e.key}');
        }
        expect(utf8.decode(got['src/link']!), 'a.txt');
        if (c.key == 'cmt.rar') {
          expect(h.getArchiveProperty(Kpid.comment), 'the comment');
        }
      }
    }, skip: haveRar ? false : 'no rar tool');

    test('our archives pass rar t and unrar t and extract the same', () {
      final t = makeTree();
      final ups = <_Up>[
        _Up.add('src', isDir: true, posix: 0x41ED),
        for (final e in t.entries)
          _Up.add(e.key, data: e.value, posix: 0x81A4, mTime: ft(1700000000)),
        _Up.add('src/link', symLink: 'a.txt', posix: 0xA1FF),
      ];
      final cases = <String, (String, String?)>{
        'x0.rar': ('x=0', null),
        'x1.rar': ('x=1', null),
        'x5.rar': ('x=5', null),
        'x9s.rar': ('x=9,s=on', null),
        'b2.rar': ('crc=blake2,s=on', null),
        'enc.rar': ('x=3', 'pw'),
        'henc.rar': ('x=5,he=on,s=on,crc=blake2', 'pw'),
      };
      for (final c in cases.entries) {
        final b = _writeRar(ups, opts: c.value.$1, password: c.value.$2);
        final path = '${tmp.path}/${c.key}';
        File(path).writeAsBytesSync(b);
        final pwArg = c.value.$2 == null ? '-p-' : '-p${c.value.$2}';
        if (haveUnrar) {
          final r = Process.runSync('unrar', ['t', pwArg, path]);
          expect(r.stdout, contains('All OK'), reason: '${c.key} ${r.stdout}');
          final out = Directory('${tmp.path}/x_${c.key}')..createSync();
          Process.runSync('unrar', ['x', '-inul', pwArg, path],
              workingDirectory: out.path);
          for (final e in t.entries) {
            expect(File('${out.path}/${e.key}').readAsBytesSync(), e.value,
                reason: '${c.key} ${e.key}');
          }
          expect(Link('${out.path}/src/link').targetSync(), 'a.txt');
        }
        final r = rar(['t', pwArg, path]);
        expect(r.stdout, isNot(contains('ERROR')), reason: '${r.stdout}');
        expect(r.exitCode, 0, reason: '${c.key} ${r.stdout}');
      }
    }, skip: haveRar ? false : 'no rar tool');

    test('update of an archive made by rar keeps the packed data', () {
      makeTree();
      expect(rar(['a', '-ol', '-m3', 'old.rar', 'src']).exitCode, 0);
      final old = openFile('${tmp.path}/old.rar');
      final n = old.numberOfItems;
      final u = _writeRar([
        for (var i = 0; i < n; i++) _Up.keep(i),
        _Up.add('added.txt', data: text(3000, 21)),
      ], old: old);
      File('${tmp.path}/new.rar').writeAsBytesSync(u);
      final r = rar(['t', 'new.rar']);
      expect(r.exitCode, 0, reason: '${r.stdout}');
      final h = openRar(u);
      expect(h.numberOfItems, n + 1);
      extractAll(h);
    }, skip: haveRar ? false : 'no rar tool');
  });

  group('RAR 2.9 / 3.x archives (libarchive test files)', () {
    // the .uu files of libarchive's test suite, decoded here
    Uint8List uudecode(String path) {
      final out = BytesBuilder();
      for (final line in File(path).readAsLinesSync()) {
        if (line.startsWith('begin') || line.isEmpty) continue;
        if (line == 'end') break;
        final n = (line.codeUnitAt(0) - 32) & 63;
        final d = <int>[];
        for (var i = 1; i + 3 < line.length + 3; i += 4) {
          int c(int k) =>
              i + k < line.length ? (line.codeUnitAt(i + k) - 32) & 63 : 0;
          final v = (c(0) << 18) | (c(1) << 12) | (c(2) << 6) | c(3);
          d.addAll([(v >> 16) & 255, (v >> 8) & 255, v & 255]);
        }
        out.add(d.sublist(0, n < d.length ? n : d.length));
      }
      return out.toBytes();
    }

    void checkAll(String name, {int? items}) {
      final b = uudecode('$_laTests/$name.uu');
      final h = openRar(b, rar5: false);
      if (items != null) expect(h.numberOfItems, items);
      final cb = _Check();
      h.extract(null, true, cb);
      for (var i = 0; i < h.numberOfItems; i++) {
        expect(cb.results[i], OperationResult.ok,
            reason: '$name ${h.getProperty(i, Kpid.path)}');
      }
    }

    test('LZSS, PPMd, filters, unicode names, links', () {
      checkAll('test_read_format_rar.rar');
      checkAll('test_read_format_rar_compress_normal.rar');
      checkAll('test_read_format_rar_compress_best.rar');
      checkAll('test_read_format_rar_filter.rar');
      checkAll('test_read_format_rar_filter_incomplete_block.rar');
      checkAll('test_read_format_rar3_lowdist_reset.rar');
      checkAll('test_read_format_rar_unicode.rar');
      checkAll('test_read_format_rar_windows.rar');
      checkAll('test_read_format_rar_binary_data.rar');
      checkAll('test_read_format_rar_multi_lzss_blocks.rar');
      checkAll('test_read_format_rar_subblock.rar');
      checkAll('test_read_format_rar_noeof.rar');
    });

    test('names and properties', () {
      final h = openRar(
          uudecode('$_laTests/test_read_format_rar_unicode.rar.uu'),
          rar5: false);
      final names = [
        for (var i = 0; i < h.numberOfItems; i++)
          h.getProperty(i, Kpid.path) as String
      ];
      expect(
          names,
          contains(
              '\u8868\u3060\u3088/\u65B0\u3057\u3044\u30D5\u30A9\u30EB\u30C0/\u65B0\u898F\u30C6\u30AD\u30B9\u30C8 \u30C9\u30AD\u30E5\u30E1\u30F3\u30C8.txt'));
      final c = openRar(
          uudecode('$_laTests/test_read_format_rar_compress_best.rar.uu'),
          rar5: false);
      expect(c.getProperty(0, Kpid.method), startsWith('m5:'));
      expect(c.getProperty(0, Kpid.unpackVer), 29);
    });

    test('RAR 3.x encryption: data and headers', () {
      Map<String, String> texts(String name, String pw) {
        final h =
            openRar(uudecode('$_laTests/$name.uu'), password: pw, rar5: false);
        final cb = _Collect(pw);
        h.extract(null, false, cb);
        return {
          for (var i = 0; i < h.numberOfItems; i++)
            h.getProperty(i, Kpid.path) as String:
                cb.results[i] == OperationResult.ok
                    ? utf8.decode(cb.data(i))
                    : 'error ${cb.results[i]}'
        };
      }

      String from(String n) => 'This is from $n';
      // d.txt has the password "password2"
      final plain = texts('test_read_format_rar4_encrypted.rar', 'password');
      expect(plain['a.txt'], from('a.txt'));
      expect(plain['b.txt'], from('b.txt'));
      expect(plain['c.txt'], from('c.txt'));
      expect(plain['d.txt'], startsWith('error'));
      for (final name in [
        'test_read_format_rar4_encrypted_filenames.rar',
        'test_read_format_rar4_solid_encrypted.rar',
        'test_read_format_rar4_solid_encrypted_filenames.rar',
      ]) {
        expect(
            texts(name, 'password'),
            {
              for (final n in ['a.txt', 'b.txt', 'c.txt', 'd.txt']) n: from(n)
            },
            reason: name);
      }
      for (final name in [
        'test_read_format_rar_encryption_data.rar',
        'test_read_format_rar_encryption_header.rar',
        'test_read_format_rar_encryption_partially.rar',
      ]) {
        final t = texts(name, '12345678');
        expect(t.keys, ['foo.txt', 'bar.txt'], reason: name);
        expect(t.values.every((v) => !v.startsWith('error')), isTrue,
            reason: '$name $t');
      }
      final hp = openRar(
          uudecode(
              '$_laTests/test_read_format_rar4_encrypted_filenames.rar.uu'),
          password: 'password',
          rar5: false);
      expect(hp.getArchiveProperty(Kpid.characts), 'BlockEncryption');
    });

    test('RAR 3.x encrypted headers with a wrong password', () {
      final h = RarHandler(rar5: false);
      expect(
          () => h.open(
              MemoryInStream(uudecode(
                  '$_laTests/test_read_format_rar_encryption_header.rar.uu')),
              getPassword: () => 'wrong'),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.wrongPassword)));
    });
  }, skip: haveLaTests ? false : 'no libarchive test files in ref/');

  group('RAR 1.5, 2.0 and 3.x archives (test/data/rar_legacy)', () {
    // made by tool/rar_legacy_fixtures.sh: RAR 1.55 for DOS (unpack
    // version 15, RAR 1.5 cipher), RAR 2.90 (unpack version 20, with audio
    // blocks, RAR 2.0 cipher) and rar 3.93 (AES, -p and -hp)
    const dir = 'test/data/rar_legacy';
    const unicodePw = 'p\u00E4ss\u20AC';

    // the files of [path] as unrar extracts them
    Map<String, Uint8List> unrarAll(String path, String pw) {
      final tmp = Directory.systemTemp.createTempSync('zx_unrar');
      try {
        final r = Process.runSync(
            'unrar', ['x', '-inul', '-y', '-p$pw', path, '${tmp.path}/']);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        return {
          for (final f in tmp.listSync(recursive: true).whereType<File>())
            f.path.substring(tmp.path.length + 1): f.readAsBytesSync()
        };
      } finally {
        tmp.deleteSync(recursive: true);
      }
    }

    void check(String name, {String pw = 'password', int? items}) {
      final path = '$dir/$name';
      final h = openFile(path, password: pw, rar5: false);
      if (items != null) expect(h.numberOfItems, items);
      final got = extractAll(h, pw);
      if (haveUnrar) expect(got, unrarAll(path, pw), reason: name);
    }

    test('RAR 2.0 LZ and audio blocks, solid', () {
      check('rar20_lz.rar', items: 2);
      check('rar20_audio_solid.rar', items: 3);
      check('rar20_audio4.rar', items: 1);
      final h = openFile('$dir/rar20_lz.rar', rar5: false);
      expect(h.getProperty(0, Kpid.unpackVer), 20);
      // the old style archive comment, compressed with the RAR 2.0 method
      final c = openFile('$dir/rar20_comment.rar', rar5: false);
      expect(c.getArchiveProperty(Kpid.comment),
          startsWith('An archive comment of RAR 2.90, long enough'));
      check('rar20_comment.rar', items: 1);
    });

    // the sources of tool/rar_legacy_fixtures.sh that need no floating
    // point rounding (the other ones are compared with unrar only)
    Map<String, Uint8List> sources() {
      var st = 7;
      int next() {
        st = (st * 1103515245 + 12345) & 0x7fffffff;
        return (st >> 16) & 0xff;
      }

      for (var i = 0; i < 12000 + 20000; i++) {
        next(); // st16.pcm and ch4.pcm
      }
      const words = [
        'alpha', 'beta', 'gamma', 'archive', 'volume', ' ', '\n', //
        'solid', 'window', 'filter',
      ];
      final t = BytesBuilder();
      while (t.length < 30000) {
        t.add(utf8.encode(words[next() % words.length]));
      }
      final rand = Uint8List(5000);
      for (var i = 0; i < rand.length; i++) {
        rand[i] = next();
      }
      return {'text.txt': t.toBytes(), 'rand.bin': rand};
    }

    // the items of [name] against the sources (names of DOS are upper case)
    void checkSources(String name, {String pw = 'password'}) {
      final src = sources();
      final got =
          extractAll(openFile('$dir/$name', password: pw, rar5: false), pw);
      var n = 0;
      got.forEach((k, v) {
        final s = src[k.toLowerCase()];
        if (s == null) return;
        expect(v, s, reason: '$name: $k');
        n++;
      });
      expect(n, greaterThan(0), reason: name);
    }

    test('RAR 1.5 method (unpack version 15), solid, comment', () {
      check('rar15_lz.rar', items: 2);
      check('rar15_solid.rar', items: 4);
      check('rar15_comment.rar', items: 1);
      checkSources('rar15_lz.rar');
      checkSources('rar15_solid.rar');
      final h = openFile('$dir/rar15_solid.rar', rar5: false);
      expect(h.getProperty(0, Kpid.unpackVer), 15);
      expect(h.getArchiveProperty(Kpid.solid), isTrue);
      // the last file of the solid stream alone: the files before it are
      // decoded for the state
      final cb = _Collect();
      h.extract([3], false, cb);
      expect(cb.results[3], OperationResult.ok);
      expect(cb.data(3), sources()['text.txt']);
      // the old style archive comment, compressed with the RAR 1.5 method
      final c = openFile('$dir/rar15_comment.rar', rar5: false);
      expect(c.getArchiveProperty(Kpid.comment),
          startsWith('An archive comment of RAR 1.55, long enough'));
    });

    test('RAR 1.5 and RAR 2.0 ciphers', () {
      check('rar15_crypt.rar', items: 2);
      check('rar15_crypt_stored.rar', items: 1);
      check('rar20_crypt.rar', items: 1);
      check('rar20_crypt_stored.rar', items: 1);
      check('rar20_crypt_solid.rar', pw: 'a longer password', items: 3);
      checkSources('rar15_crypt.rar');
      checkSources('rar20_crypt.rar');
      checkSources('rar20_crypt_solid.rar', pw: 'a longer password');
      for (final name in ['rar15_crypt.rar', 'rar20_crypt.rar']) {
        final h = openFile('$dir/$name', rar5: false);
        expect(h.getProperty(0, Kpid.encrypted), isTrue);
        final cb = _Collect('wrong');
        h.extract(null, true, cb);
        expect(cb.results[0], isNot(OperationResult.ok), reason: name);
      }
    });

    test('RAR 1.5 and RAR 2.0 ciphers: encrypt and decrypt', () {
      final pw = Uint8List.fromList(utf8.encode('seventeen chars!!'));
      final data = gen(64, 3);
      final b = Uint8List.fromList(data);
      final e = Rar20Cipher(pw);
      for (var i = 0; i < 64; i += 16) {
        e.encryptBlock(b, i);
      }
      expect(b, isNot(data));
      final d = Rar20Cipher(pw);
      for (var i = 0; i < 64; i += 16) {
        d.decryptBlock(b, i);
      }
      expect(b, data);
      Rar15Cipher(pw).crypt(b, 0, 64);
      expect(b, isNot(data));
      Rar15Cipher(pw).crypt(b, 0, 64);
      expect(b, data);
      // the OEM code page of the DOS and console versions
      expect(rarLegacyPasswordBytes('p\u00E4ss'), [0x70, 0x84, 0x73, 0x73]);
    });

    test('RAR 3.x AES: data, stored data, unicode password', () {
      check('rar3_p.rar', items: 2);
      check('rar3_p_stored.rar', items: 1);
      check('rar3_p_unicode.rar', pw: unicodePw, items: 1);
      // a wrong password gives bad data (RAR 3.x has no password check)
      final h = openFile('$dir/rar3_p.rar', rar5: false);
      final cb = _Collect('wrong');
      h.extract(null, true, cb);
      expect(cb.results[0], isNot(OperationResult.ok));
      expect(h.getProperty(0, Kpid.encrypted), isTrue);
    });

    test('RAR 3.x AES: encrypted headers, solid, volumes', () {
      check('rar3_hp_solid.rar', items: 3);
      check('rar3_hp_vol.part1.rar', items: 2);
      final h = openFile('$dir/rar3_hp_vol.part1.rar',
          password: 'password', rar5: false);
      expect(h.getArchiveProperty(Kpid.numVolumes), 2);
      expect(
          () => openFile('$dir/rar3_hp_solid.rar',
              password: 'wrong', rar5: false),
          throwsA(isA<SevenZipException>()
              .having((e) => e.kind, 'kind', SevenZipError.wrongPassword)));
    });
  },
      skip: Directory('test/data/rar_legacy').existsSync()
          ? false
          : 'no test/data/rar_legacy');

  test('an output that can not seek', () {
    final data = text(30000, 31);
    final h = RarHandler(rar5: true);
    h.setProperties(props('x=3'));
    final mem = MemoryOutStream();
    h.updateItems(
        _NoSeek(mem),
        2,
        _UpdateCb([
          _Up.add('a', data: data),
          _Up.add('b', data: gen(100, 1)),
        ], 'pw'));
    final got = extractAll(openRar(Uint8List.fromList(mem.toBytes())), 'pw');
    expect(got['a'], data);
    expect(got['b'], gen(100, 1));
  });

  test('CRC of stored data is checked', () {
    final data = text(1000, 30);
    final b = _writeRar([_Up.add('a', data: data)], opts: 'x=0');
    // flip one data byte (the data follows the last header before the end)
    final i = b.length - 20;
    b[i] ^= 1;
    final h = openRar(b);
    final cb = _Collect();
    h.extract(null, false, cb);
    expect(cb.results[0], OperationResult.crcError);
    expect(Crc32.of(data), isNot(Crc32.of(cb.data(0))));
  });

  group('RAR 7 streams (compression algorithm version 1)', () {
    test('encoder and decoder round trip with 80 distance slots', () {
      for (final data in [text(80000, 41), audio(10000), gen(5000, 42)]) {
        final enc = Rar5Encoder(3, 1 << 20, algoVersion: 1);
        enc.start(MemoryInStream(data),
            expectedSize: data.length, fileSizes: [data.length]);
        final packed = MemoryOutStream();
        enc.encodeFile(data.length, packed);
        final out = MemoryOutStream();
        Rar5Decoder().decodeFile(
            MemoryInStream(Uint8List.fromList(packed.toBytes())),
            out,
            data.length,
            Rar5Decoder.windowSizeFor(1 << 20, data.length),
            false,
            1);
        expect(out.toBytes(), data);
      }
    });

    test('a dictionary above 4 GB with a fraction needs a small window', () {
      // 128 KB << 17 = 16 GB, plus 5/32 of it
      final data = text(50000, 43);
      final b = _writeRar([_Up.add('a.txt', data: data)], opts: 'x=5,algo=1');
      final ci = 1 | (3 << 7) | (17 << 10) | (5 << 15);
      final patched = _patchCompInfo(b, ci);
      final h = openRar(patched);
      expect(h.items[0].algoVersion, 1);
      expect(h.items[0].dictSize, (16 << 30) + (16 << 30) ~/ 32 * 5);
      expect(extractAll(h)['a.txt'], data);
      expect(Rar5Decoder.windowSizeFor(h.items[0].dictSize, data.length),
          lessThanOrEqualTo(1 << 17));
    });

    test('unrar and rar accept our version 1 archives', () {
      final tmp = Directory.systemTemp.createTempSync('zx_rar7_');
      try {
        final data = text(60000, 44);
        for (final opts in ['x=5,algo=1', 'x=9,s=on,algo=1', 'x=1,algo=1']) {
          final b = _writeRar([
            _Up.add('a.txt', data: data),
            _Up.add('b.bin', data: audio(3000)),
          ], opts: opts);
          final path = '${tmp.path}/v1.rar';
          File(path).writeAsBytesSync(b);
          final l = Process.runSync(File(_rarPath).absolute.path, ['lt', path]);
          expect('${l.stdout}', contains('v70'), reason: opts);
          for (final t in [File(_rarPath).absolute.path, 'unrar']) {
            final r = Process.runSync(t, ['t', path]);
            expect(r.exitCode, 0, reason: '$t $opts ${r.stdout}');
          }
        }
      } finally {
        tmp.deleteSync(recursive: true);
      }
    }, skip: haveRar && haveUnrar ? false : 'no rar or unrar');
  });

  group('RAR5 volumes', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zx_rarv_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    final files = <_Up>[
      _Up.add('d', isDir: true, posix: 0x41ED),
      _Up.add('d/a.txt', data: text(30000, 51), posix: 0x81A4),
      _Up.add('d/r.bin', data: gen(25000, 52), posix: 0x81A4),
      _Up.add('d/e', data: Uint8List(0), posix: 0x81A4),
      _Up.add('d/s.txt', data: text(300, 53), posix: 0x81A4),
    ];

    // writes the volumes of [opts] into tmp as v.partN.rar, returns the
    // paths
    List<String> writeVolumes(String opts, List<int> sizes,
        {String? password}) {
      final ms = MultiOutStream('${tmp.path}/v.', sizes)
        ..volumeName = ((i) => '${tmp.path}/v.part${i + 1}.rar')
        ..singleVolumeName = '${tmp.path}/v.rar';
      final h = RarHandler(rar5: true)..setProperties(props(opts));
      h.updateItems(ms, files.length, _UpdateCb(files, password));
      final n = ms.finalFlushAndCloseFiles();
      return n == 1
          ? ['${tmp.path}/v.rar']
          : [for (var i = 0; i < n; i++) '${tmp.path}/v.part${i + 1}.rar'];
    }

    for (final c in [
      ('x=0', null),
      ('x=5', null),
      ('x=5,s=on,crc=blake2', null),
      ('x=3', 'pw'),
      ('x=5,he=on,s=on', 'pw'),
      ('x=3,rr=10', null),
      ('x=5,he=on,rr=5', 'pw'),
    ]) {
      test('write and read back (${c.$1}${c.$2 != null ? ', password' : ''})',
          () {
        final paths = writeVolumes(c.$1, [9000], password: c.$2);
        expect(paths.length, greaterThan(2));
        for (var i = 0; i < paths.length - 1; i++) {
          expect(File(paths[i]).lengthSync(), 9000);
        }
        final h = openFile(paths.first, password: c.$2);
        final got = extractAll(h, c.$2);
        for (final f in files) {
          if (f.data != null) expect(got[f.name], f.data, reason: f.name);
        }
        final pw = c.$2 == null ? '-p-' : '-p${c.$2}';
        if (haveUnrar) {
          final r = Process.runSync('unrar', ['t', pw, paths.first]);
          expect(r.stdout, contains('All OK'), reason: '${r.stdout}');
        }
        if (haveRar) {
          final r = Process.runSync(
              File(_rarPath).absolute.path, ['t', pw, paths.first]);
          expect(r.exitCode, 0, reason: '${r.stdout}');
          if (c.$1.contains('rr=')) {
            expect('${r.stdout}', contains('recovery record'));
          }
        }
      });
    }

    test('a set that fits in one volume is a plain archive', () {
      final paths = writeVolumes('x=5', [1 << 20]);
      expect(paths, ['${tmp.path}/v.rar']);
      final h = openFile(paths.first);
      expect(h.archive!.isVolume, isFalse);
      expect(extractAll(h)['d/a.txt'], files[1].data);
    });

    test('a volume too small for a header fails', () {
      expect(
          () => writeVolumes('x=0', [40]), throwsA(isA<SevenZipException>()));
    });
  });

  group('RAR5 recovery record', () {
    final data = gen(60000, 61);

    test('the record repairs damaged chunks, and fails beyond its size', () {
      final b = _writeRar([
        _Up.add('r.bin', data: data),
        _Up.add('t.txt', data: text(9000, 62))
      ], opts: 'x=0,rr=5');
      expect(openRar(b).archive!.recovery, isTrue);
      // G = 60 chunks of 1 KiB, 3 recovery blocks
      final damaged = Uint8List.fromList(b);
      for (final at in [100, 5000, 30000]) {
        for (var i = 0; i < 50; i++) {
          damaged[at + i] ^= 0x5A;
        }
      }
      final r = rar5Repair(damaged);
      expect(r.repaired, 3);
      expect(damaged, b);
      for (final at in [100, 5000, 30000, 50000]) {
        damaged[at] ^= 1;
      }
      expect(rar5Repair(damaged).unrecoverable, 4);
    });

    test('rar tests and repairs with our record, we repair with rar\'s', () {
      final tmp = Directory.systemTemp.createTempSync('zx_rarrr_');
      try {
        final rarExe = File(_rarPath).absolute.path;
        final b = _writeRar([_Up.add('r.bin', data: data)], opts: 'x=3,rr=10');
        File('${tmp.path}/o.rar').writeAsBytesSync(b);
        var r =
            Process.runSync(rarExe, ['t', 'o.rar'], workingDirectory: tmp.path);
        expect('${r.stdout}', contains('recovery record'));
        expect(r.exitCode, 0, reason: '${r.stdout}');
        final damaged = Uint8List.fromList(b);
        for (var i = 3000; i < 3600; i++) {
          damaged[i] ^= 0x33;
        }
        File('${tmp.path}/d.rar').writeAsBytesSync(damaged);
        r = Process.runSync(rarExe, ['r', '-y', 'd.rar'],
            workingDirectory: tmp.path);
        expect(File('${tmp.path}/fixed.d.rar').readAsBytesSync(), b,
            reason: '${r.stdout}');
        // an archive made by rar -rr, repaired here
        File('${tmp.path}/r.bin').writeAsBytesSync(data);
        r = Process.runSync(
            rarExe, ['a', '-idq', '-m0', '-rr5%', 'm.rar', 'r.bin'],
            workingDirectory: tmp.path);
        expect(r.exitCode, 0);
        final m = File('${tmp.path}/m.rar').readAsBytesSync();
        final md = Uint8List.fromList(m);
        for (var i = 20000; i < 20300; i++) {
          md[i] ^= 0x99;
        }
        expect(rar5Repair(md).repaired, 1);
        expect(md, m);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    }, skip: haveRar ? false : 'no rar tool');
  });
}

// rewrites the compression information of the first file header of a
// RAR5 archive made by _writeRar (a test of dictionary sizes rar only
// writes for gigabytes of data)
Uint8List _patchCompInfo(Uint8List b, int ci) {
  (int, int) vint(int p) {
    var v = 0, s = 0;
    for (;;) {
      final c = b[p++];
      v |= (c & 0x7F) << s;
      s += 7;
      if (c < 0x80) return (v, p);
    }
  }

  Uint8List enc(int v) {
    final o = BytesBuilder();
    while (v >= 0x80) {
      o.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    o.addByte(v);
    return o.toBytes();
  }

  // the main header, then the file header
  var p = 8;
  var (size, q) = vint(p + 4);
  p = q + size;
  final hStart = p;
  (size, q) = vint(p + 4);
  final bodyStart = q, bodyEnd = q + size;
  var r = bodyStart;
  int flags, ff;
  (_, r) = vint(r); // type
  (flags, r) = vint(r);
  if ((flags & 1) != 0) (_, r) = vint(r);
  if ((flags & 2) != 0) (_, r) = vint(r);
  (ff, r) = vint(r);
  (_, r) = vint(r); // unpacked size
  (_, r) = vint(r); // attributes
  if ((ff & 2) != 0) r += 4;
  if ((ff & 4) != 0) r += 4;
  final ciStart = r;
  (_, r) = vint(r);
  final body = BytesBuilder()
    ..add(b.sublist(bodyStart, ciStart))
    ..add(enc(ci))
    ..add(b.sublist(r, bodyEnd));
  final nb = body.toBytes();
  final sizeBytes = enc(nb.length);
  final hb = Uint8List(4 + sizeBytes.length + nb.length);
  hb.setRange(4, 4 + sizeBytes.length, sizeBytes);
  hb.setRange(4 + sizeBytes.length, hb.length, nb);
  setUint32LE(hb, 0, Crc32.of(hb, 4, hb.length));
  return Uint8List.fromList([
    ...b.sublist(0, hStart),
    ...hb,
    ...b.sublist(bodyEnd, b.length),
  ]);
}
